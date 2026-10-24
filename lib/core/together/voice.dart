import 'dart:async';

import 'account.dart';
import 'notifier.dart';
import 'parties.dart';
import 'socket.dart';
import 'voice_mesh.dart';

enum VoiceProblem { microphone, failed }

/// Voice in the party, the way the website does it: the call from /calls with its ICE servers
/// (renewed from /ice-servers before they run out), the offers and candidates through the
/// gateway, a mesh of peer connections. The microphone sends while it is on, or, with
/// push-to-talk, while the talk key is held; turning it off tells the others (call.updated).
class Voice with Notifier {
  Voice({
    required this.account,
    required this.socket,
    required this.parties,
    required this.engine,
    this.measureEvery = const Duration(milliseconds: 250),
  }) {
    _events = socket.events.listen(_event);
    parties.addListener(_partyChanged);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  final Parties parties;

  /// Makes the microphone and the connections (flutter_webrtc in the launcher, fakes in tests).
  final VoiceEngine Function() engine;
  final Duration measureEvery;
  late final StreamSubscription<TogetherEvent> _events;

  VoiceMesh? _mesh;
  Timer? _levels;
  Timer? _renew;
  String? callId;
  String? _partyId;
  bool joining = false;

  /// The microphone is off (the others see it muted).
  bool muted = false;

  /// Push-to-talk: the microphone sends only while [held].
  bool pushToTalk = false;
  bool held = false;
  VoiceProblem? problem;

  bool get active => _mesh != null;

  /// Whether the microphone goes to the others now.
  bool get sending => active && !muted && (!pushToTalk || held);

  /// This launcher's microphone is heard right now.
  bool get speaking => sending && (_mesh?.speaking ?? false);

  List<PeerVoice> get peers => _mesh?.peers ?? const [];

  bool speakingOf(String userId) => peers.any((peer) => peer.userId == userId && peer.speaking);

  /// Joins the party's voice (starting it if no one talks yet).
  Future<void> join() async {
    final party = parties.party;
    final me = account.user?.id;
    if (party == null || me == null || joining || active) return;
    joining = true;
    problem = null;
    notifyListeners();
    final engine = this.engine();
    try {
      await engine.start();
    } on Object {
      problem = VoiceProblem.microphone;
      joining = false;
      notifyListeners();
      return;
    }
    try {
      final joined = await account.call('POST', 'calls', {'partyId': party.id});
      final call = joined['call'] as Map<String, dynamic>;
      final id = call['id'] as String;
      final mesh = VoiceMesh(
        me: me,
        engine: engine,
        iceServers: _servers(joined['iceServers']),
        signal: (to, device, kind, data) =>
            socket.send({'op': 'signal', 'to': to, 'device': device, 'call': id, 'kind': kind, 'data': data}),
        onChange: notifyListeners,
      );
      _mesh = mesh;
      callId = id;
      _partyId = party.id;
      _apply();
      _levels = Timer.periodic(measureEvery, (_) => unawaited(mesh.measure()));
      _renewBefore(joined['expiresAt']);
      if (muted) unawaited(_tellMuted());
      // The newcomer calls everyone already in.
      for (final peer in (call['in'] as List<dynamic>? ?? const [])) {
        if (peer is! Map) continue;
        final userId = peer['userId'] as String;
        if (userId != me) unawaited(mesh.connectTo(userId, peer['device'] as String).catchError((Object _) {}));
      }
    } on Object {
      await engine.stop();
      problem = VoiceProblem.failed;
    } finally {
      joining = false;
      notifyListeners();
    }
  }

  static List<Map<String, dynamic>> _servers(Object? list) => [
    for (final server in (list as List<dynamic>? ?? const [])) Map<String, dynamic>.from(server as Map),
  ];

  /// Out of the voice; the server is told unless it already knows (the party or call ended).
  Future<void> leave({bool tell = true}) async {
    final id = callId;
    await _stop();
    if (tell && id != null) {
      try {
        await account.call('POST', 'calls/$id/leave');
      } on Object {
        // The call ends for the others when this launcher stops answering.
      }
    }
  }

  /// Fresh relay credentials ten minutes before these run out (a call can outlast them).
  void _renewBefore(Object? expiresAt) {
    final expiry = DateTime.tryParse(expiresAt as String? ?? '');
    _renew?.cancel();
    if (expiry == null) return;
    final wait = expiry.difference(DateTime.now()) - const Duration(minutes: 10);
    _renew = Timer(wait.isNegative ? Duration.zero : wait, () async {
      try {
        final fresh = await account.call('GET', 'ice-servers');
        _mesh?.iceServers = _servers(fresh['iceServers']);
        if (_mesh != null) _renewBefore(fresh['expiresAt']);
      } on Object {
        // The ones held still work until they expire.
      }
    });
  }

  /// The microphone off or on; the others are told.
  void setMuted(bool on) {
    if (muted == on) return;
    muted = on;
    _apply();
    if (active) unawaited(_tellMuted());
  }

  Future<void> _tellMuted() async {
    final id = callId;
    if (id == null) return;
    try {
      await account.call('POST', 'calls/$id/mute', {'muted': muted});
    } on Object {
      // Only the mute mark is lost; the microphone itself is off.
    }
  }

  void setPushToTalk(bool on) {
    pushToTalk = on;
    held = false;
    _apply();
  }

  /// The talk key: held to talk with push-to-talk, else a press turns the microphone on and off.
  void talkKey(bool pressed) {
    if (pushToTalk) {
      if (held == pressed) return;
      held = pressed;
      _apply();
    } else if (pressed) {
      setMuted(!muted);
    }
  }

  void _apply() {
    _mesh?.talking = sending;
    notifyListeners();
  }

  Future<void> _stop() async {
    final mesh = _mesh;
    _mesh = null;
    callId = null;
    _partyId = null;
    held = false;
    _levels?.cancel();
    _renew?.cancel();
    notifyListeners();
    await mesh?.close();
  }

  /// Out of the party, out of its voice: the server took this launcher out of the call already.
  void _partyChanged() {
    if (!active) return;
    final party = parties.party;
    if (party == null || party.id != _partyId) unawaited(_stop());
  }

  void _event(TogetherEvent event) {
    final mesh = _mesh;
    final data = event.json;
    if (mesh == null) return;
    switch (event.type) {
      case 'signal' when data['call'] == callId:
        unawaited(
          mesh
              .onSignal(data['from'] as String, data['device'] as String, data['kind'] as String, data['data'])
              .catchError((Object _) {}),
        );
      case 'call.left' when data['callId'] == callId:
        unawaited(mesh.drop(data['userId'] as String, sayBye: false).catchError((Object _) {}));
      case 'call.ended' when data['callId'] == callId:
        unawaited(_stop());
    }
  }

  void dispose() {
    unawaited(_events.cancel());
    parties.removeListener(_partyChanged);
    unawaited(_stop());
  }
}
