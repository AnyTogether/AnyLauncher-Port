import 'dart:async';
import 'dart:typed_data';

import 'share_play.dart';

/// One viewer's connection as the host needs it; the launcher's flutter_webrtc one makes real
/// ones (lib/ui/share_webrtc.dart), tests make fakes. Descriptions and candidates are JSON as a
/// browser's toJSON() gives them.
abstract class ShareLink {
  Future<Map<String, dynamic>> createOffer({bool restart = false});
  Future<void> setLocal(Map<String, dynamic> description);
  Future<void> setRemote(Map<String, dynamic> description);
  Future<void> addCandidate(Map<String, dynamic> candidate);

  /// stable, have-local-offer, have-remote-offer.
  String get signalingState;

  /// new, connecting, connected, disconnected, failed, closed.
  String get connectionState;
  bool get hasRemote;
  Map<String, dynamic>? get localDescription;

  set onCandidate(void Function(Map<String, dynamic> candidate) handler);
  set onState(void Function() handler);

  /// The viewer's pad packets, on the "pad" channel.
  set onPad(void Function(Uint8List packet) handler);

  /// The game's answer on the viewer's pad (vibration, light bar).
  void sendPad(Uint8List packet);

  /// What the viewer's stream may take.
  Future<void> setEncoding({required int maxBitrate, required int maxFramerate, required double scaleDown});
  Future<void> close();
}

/// The game's picture and sound, captured once and sent on every viewer's connection.
abstract class ShareEngine {
  /// Captures the game's window, by its title; false when it cannot be found or read.
  Future<bool> start({required String windowTitle});

  /// Whether the game's sound goes with the picture (an Opus track).
  bool get hasSound;
  Future<ShareLink> link(List<Map<String, dynamic>> iceServers);
  Future<void> stop();
}

class _Viewer {
  _Viewer(this.userId, this.device, this.link);
  final String userId;
  final String device;
  final ShareLink link;
  final queued = <Map<String, dynamic>>[];
}

/// The host's side of a running share play, as the macOS launcher's SharePlayHost: each viewer
/// gets a connection of their own carrying the captured game, the host always makes the offers,
/// the viewers' answers get WebRTC's bit rate hints, and a viewer's pad goes to [router], which
/// lets it reach the game only when the host handed them a pad.
class ShareHostSession {
  ShareHostSession({
    required this.id,
    required this.engine,
    required this.iceServers,
    required this.signal,
    required this.router,
    required this.changed,
  });

  final String id;
  final ShareEngine engine;
  List<Map<String, dynamic>> iceServers;

  /// Sends a signal to one device of a viewer, through the gateway.
  final void Function(String to, String device, String kind, Object? data) signal;
  final SharePadRouter router;
  final void Function() changed;

  final _viewers = <String, _Viewer>{};
  List<ShareViewer> viewers = const [];

  /// Each viewer's connection state, by user ID.
  Map<String, String> get links => {for (final viewer in _viewers.values) viewer.userId: viewer.link.connectionState};

  /// The share play as the server has it now: newcomers are called, leavers hung up on, and the
  /// pads follow who holds them.
  Future<void> apply(SharePlay sharePlay) async {
    if (sharePlay.id != id) return;
    final plan = ShareRoster.plan(viewers, sharePlay.viewers);
    viewers = sharePlay.viewers;
    for (final userId in plan.hangUp) {
      await hangUp(userId, sayBye: false);
    }
    router.update(ShareRoster.padsOf(sharePlay.viewers));
    for (final viewer in plan.call) {
      await call(viewer.user.id, viewer.device);
    }
    changed();
  }

  /// Calls a viewer on [device] (again, if they were on another device or their link broke).
  Future<void> call(String userId, String device) async {
    final known = _viewers[userId];
    if (known != null && known.device == device && known.link.connectionState != 'failed' && known.link.connectionState != 'closed') {
      return;
    }
    if (known != null) await hangUp(userId, sayBye: false);
    final link = await engine.link(iceServers);
    final viewer = _Viewer(userId, device, link);
    _viewers[userId] = viewer;
    link.onCandidate = (candidate) => signal(userId, device, 'candidate', candidate);
    link.onState = changed;
    link.onPad = (packet) => router.receive(packet, userId);
    await _retune();
    await _offer(viewer);
    changed();
  }

  Future<void> _offer(_Viewer viewer, {bool restart = false}) async {
    try {
      final offer = await viewer.link.createOffer(restart: restart);
      if (_viewers[viewer.userId] != viewer) return;
      await viewer.link.setLocal(offer);
      signal(viewer.userId, viewer.device, 'offer', offer);
    } on Object {
      // The connection went while the offer was made: the viewer asks again.
    }
  }

  Future<void> hangUp(String userId, {bool sayBye = true}) async {
    final viewer = _viewers.remove(userId);
    if (viewer == null) return;
    if (sayBye) signal(userId, viewer.device, 'bye', null);
    await viewer.link.close();
    await _retune();
    changed();
  }

  /// A signal from a viewer.
  Future<void> receive(ShareSignal signal) async {
    if (signal.sharePlayId != id) return;
    final viewer = _viewers[signal.from];
    switch (signal.kind) {
      case 'renegotiate':
        // A viewer asks for a connection: after joining, again while waiting for the offer, or
        // with a fresh connection after its link broke. An offer still waiting for its answer
        // is sent again; otherwise the old connection goes and a new one is offered.
        final pending = viewer?.link.localDescription;
        if (viewer != null && viewer.device == signal.device && viewer.link.signalingState == 'have-local-offer' && pending != null) {
          this.signal(viewer.userId, viewer.device, 'offer', pending);
        } else {
          if (viewer != null) await hangUp(signal.from, sayBye: false);
          await call(signal.from, signal.device);
        }
      case 'answer':
        final data = signal.data;
        if (viewer == null || viewer.device != signal.device || viewer.link.signalingState != 'have-local-offer' || data is! Map<String, dynamic>) {
          return;
        }
        final encoding = ShareRoster.encoding(_viewers.length);
        final sdp = data['sdp'] as String? ?? '';
        try {
          await viewer.link.setRemote({
            'type': 'answer',
            'sdp': ShareRoster.tuneVideo(sdp, startKbps: encoding.startKbps, maxKbps: encoding.maxBitrate ~/ 1000),
          });
        } on Object {
          await viewer.link.setRemote({'type': 'answer', 'sdp': sdp});
        }
        for (final candidate in List.of(viewer.queued)) {
          await viewer.link.addCandidate(candidate);
        }
        viewer.queued.clear();
      case 'candidate':
        final data = signal.data;
        if (viewer == null || viewer.device != signal.device || data is! Map<String, dynamic>) return;
        if (viewer.link.hasRemote) {
          await viewer.link.addCandidate(data);
        } else {
          viewer.queued.add(data);
        }
      case 'bye':
        if (viewer?.device == signal.device) await hangUp(signal.from, sayBye: false);
    }
  }

  /// The game's answer on a bridge goes back to the viewer whose pad it carries.
  void padOutput(int bridge, Uint8List packet) {
    final userId = router.viewerOn(bridge);
    if (userId != null) _viewers[userId]?.link.sendPad(packet);
  }

  /// New relay credentials: every connection is offered again with them.
  Future<void> renew(List<Map<String, dynamic>> servers) async {
    iceServers = servers;
    for (final viewer in _viewers.values.toList()) {
      await _offer(viewer, restart: true);
    }
  }

  /// Each viewer's stream as the number of viewers allows.
  Future<void> _retune() async {
    final encoding = ShareRoster.encoding(_viewers.isEmpty ? 1 : _viewers.length);
    for (final viewer in _viewers.values) {
      try {
        await viewer.link.setEncoding(
          maxBitrate: encoding.maxBitrate,
          maxFramerate: encoding.maxFramerate,
          scaleDown: encoding.scaleDown,
        );
      } on Object {
        // Before the first offer some engines have no encodings yet: the answer's hints hold.
      }
    }
  }

  Future<void> close() async {
    for (final userId in _viewers.keys.toList()) {
      await hangUp(userId);
    }
    router.releaseAll();
    await engine.stop();
  }
}
