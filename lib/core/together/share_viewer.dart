import 'dart:async';
import 'dart:typed_data';

import '../controllers/pad_info.dart';
import 'share_audio.dart';
import 'share_play.dart';

/// A viewer's connection as the watcher needs it; the launcher's flutter_webrtc one makes real
/// ones (lib/ui/share_webrtc.dart), tests make fakes. Descriptions and candidates are JSON as a
/// browser's toJSON() gives them. The host makes the data channels ("pad", "audio").
abstract class WatchLink {
  Future<void> setRemote(Map<String, dynamic> description);
  Future<Map<String, dynamic>> createAnswer();
  Future<void> setLocal(Map<String, dynamic> description);
  Future<void> addCandidate(Map<String, dynamic> candidate);
  bool get hasRemote;

  /// new, connecting, connected, disconnected, failed, closed.
  String get connectionState;

  set onCandidate(void Function(Map<String, dynamic> candidate) handler);
  set onState(void Function() handler);

  /// A data channel the host made is open now.
  set onOpen(void Function(String label) handler);

  /// A binary message on a channel: StreamPacket audio on "audio", the game's answer on "pad".
  set onBinary(void Function(String label, Uint8List bytes) handler);

  /// Whether [label]'s channel is open and not backed up past [most] bytes; then [bytes] go.
  bool sendBinary(String label, Uint8List bytes, {int most});
  bool sendText(String label, String text);

  /// Round trip, the picture's rate and height, from WebRTC's statistics.
  Future<WatchStats> stats();
  Future<void> close();
}

/// What the watcher's chip says about the link.
class WatchStats {
  const WatchStats({this.roundTripMs, this.framesPerSecond, this.height, this.relayed});
  final double? roundTripMs;
  final double? framesPerSecond;
  final int? height;
  final bool? relayed;
}

/// Makes a viewer's connections, and says whether an Opus track it gets is heard (asked for in
/// the hello).
abstract class WatchEngine {
  Future<WatchLink> link(List<Map<String, dynamic>> iceServers);

  /// The sound codecs this launcher takes, best first: Opus where an audio track plays out.
  List<ShareAudioCodec> get codecs;
}

/// A viewer's side of share play, as the macOS launcher's SharePlayWatcher and the website's
/// ShareConnection: answers the host's offer (stereo Opus asked for), asks for the game's sound
/// as an Opus track (the hello) and meanwhile hands on the PCM from the "audio" channel (from
/// hosts that send nothing else), and sends pad packets on the "pad" channel. Asks the host for
/// an offer when it starts, again a moment later and every few seconds while nothing connects,
/// and when its link breaks.
class ShareWatchSession {
  ShareWatchSession({
    required this.id,
    required this.hostId,
    required this.hostDevice,
    required this.engine,
    required this.iceServers,
    required this.signal,
    required this.onSound,
    this.onPadOutput,
    required this.changed,
  });

  final String id;
  final String hostId;

  /// The host's device: where the signals go (it follows the host's own signals).
  String hostDevice;
  final WatchEngine engine;
  List<Map<String, dynamic>> iceServers;
  final void Function(String to, String device, String kind, Object? data) signal;

  /// StreamPacket audio from a host that sends PCM.
  final void Function(Uint8List packet) onSound;
  final void Function(Uint8List packet)? onPadOutput;
  final void Function() changed;

  /// How long after joining the viewer waits for the host's own offer before asking again, and
  /// how often it asks while nothing connects (the website's).
  static const askAfter = Duration(milliseconds: 1500);
  static const askEvery = Duration(seconds: 5);

  WatchLink? _link;
  final _queued = <Map<String, dynamic>>[];
  Future<void> _chain = Future.value();
  Timer? _asker;
  bool _closed = false;
  final _greeted = <String>{};

  /// waiting, connecting, connected, reconnecting, closed.
  String state = 'waiting';

  bool get connected => state == 'connected';

  void start() {
    _ask();
    _schedule(askAfter);
  }

  void _ask() {
    if (!_closed) signal(hostId, hostDevice, 'renegotiate', null);
  }

  void _schedule(Duration wait) {
    _asker?.cancel();
    _asker = Timer(wait, () {
      if (_closed || connected) return;
      _ask();
      _schedule(askEvery);
    });
  }

  void _set(String next) {
    if (state == next) return;
    state = next;
    changed();
  }

  /// A signal from the host, one at a time: a second offer waits for the first answer.
  Future<void> receive(ShareSignal signal) {
    if (_closed || signal.sharePlayId != id || signal.from != hostId) return Future.value();
    hostDevice = signal.device;
    return _chain = _chain.then((_) => _handle(signal)).catchError((Object _) {});
  }

  Future<void> _handle(ShareSignal message) async {
    switch (message.kind) {
      case 'bye':
        await _drop();
        _set('waiting');
        _schedule(askEvery);
      case 'offer':
        final data = message.data;
        if (data is! Map) return;
        var link = _link;
        if (link == null || link.connectionState == 'failed' || link.connectionState == 'closed') {
          link = await _open();
        }
        await link.setRemote({'type': 'offer', 'sdp': data['sdp']});
        for (final candidate in List.of(_queued)) {
          await link.addCandidate(candidate);
        }
        _queued.clear();
        final answer = await link.createAnswer();
        final sdp = answer['sdp'] as String? ?? '';
        // Stereo asked for, or WebRTC decodes the game's sound as mono.
        var sent = {'type': 'answer', 'sdp': ShareAudioSdp.stereoOpus(sdp)};
        try {
          await link.setLocal(sent);
        } on Object {
          sent = {'type': 'answer', 'sdp': sdp};
          await link.setLocal(sent);
        }
        signal(hostId, hostDevice, 'answer', sent);
        if (!connected) _set('connecting');
      case 'candidate':
        final data = message.data;
        if (data is! Map) return;
        final candidate = Map<String, dynamic>.from(data);
        final link = _link;
        if (link != null && link.hasRemote) {
          await link.addCandidate(candidate);
        } else {
          _queued.add(candidate);
        }
    }
  }

  Future<WatchLink> _open() async {
    await _drop();
    final link = await engine.link(iceServers);
    _link = link;
    link.onCandidate = (candidate) => signal(hostId, hostDevice, 'candidate', candidate);
    link.onState = () => _linkState(link);
    link.onOpen = (label) => _opened(link, label);
    link.onBinary = (label, bytes) {
      if (_link != link) return;
      if (label == 'audio') onSound(bytes);
      if (label == 'pad') onPadOutput?.call(bytes);
    };
    return link;
  }

  void _linkState(WatchLink link) {
    if (link != _link) return;
    switch (link.connectionState) {
      case 'connected':
        _asker?.cancel();
        _set('connected');
      case 'disconnected':
        _set('reconnecting');
      case 'failed':
        // A broken path: the host restarts ICE (through the relay if it must) when asked.
        _set('reconnecting');
        _ask();
        _schedule(askEvery);
    }
  }

  /// The hello, once per channel as soon as it is open.
  void _opened(WatchLink link, String label) {
    if (link != _link) return;
    if (label == 'audio' && engine.codecs.isNotEmpty && !_greeted.contains(label)) {
      if (link.sendText('audio', ShareAudioHello(engine.codecs).text)) _greeted.add(label);
    }
    changed();
  }

  /// One pad packet; skipped while the channel is backed up, as the next one carries everything.
  bool sendPad(Uint8List packet) => _link?.sendBinary('pad', packet, most: 8 * 1024) ?? false;

  Future<WatchStats?> stats() async => _link == null ? null : await _link!.stats();

  /// New relay credentials for the next connection.
  void renew(List<Map<String, dynamic>> servers) => iceServers = servers;

  Future<void> _drop() async {
    final link = _link;
    _link = null;
    _greeted.clear();
    _queued.clear();
    await link?.close();
  }

  Future<void> close({bool sayBye = true}) async {
    if (_closed) return;
    if (sayBye && _link != null) signal(hostId, hostDevice, 'bye', null);
    _closed = true;
    _asker?.cancel();
    await _drop();
    state = 'closed';
  }
}

/// The viewer's controller to the host while the host lets them play: the pad read 120 times a
/// second, sent when it changed and at least every 8 ms, with one session for the whole watch.
/// The Mac's ShareWatchSession pad pump.
class SharePadPump {
  SharePadPump({required this.read, required this.send, int? session, DateTime Function()? now})
    : session = session ?? DateTime.now().microsecondsSinceEpoch | 1,
      _now = now ?? DateTime.now;

  /// The controller now; null without one.
  final PadState? Function() read;

  /// One packet out; false when it could not go (the channel is not open yet).
  final bool Function(Uint8List packet) send;
  final int session;
  final DateTime Function() _now;

  static const every = Duration(microseconds: 8333);
  static const keepAlive = Duration(milliseconds: 8);

  Timer? _timer;
  int _sequence = 0;
  PadState? _last;
  DateTime? _lastSent;

  bool get running => _timer != null;

  void start() => _timer ??= Timer.periodic(every, (_) => tick());

  void stop() {
    _timer?.cancel();
    _timer = null;
    _last = null;
  }

  /// One look at the controller.
  void tick() {
    final state = read();
    if (state == null) return;
    final now = _now();
    if (state == _last && _lastSent != null && now.difference(_lastSent!) < keepAlive) return;
    _sequence = (_sequence + 1) & 0xFFFFFFFF;
    final packet = SharePadPacket.packet(
      state,
      sequence: _sequence,
      sentMicros: now.microsecondsSinceEpoch,
      session: session,
    );
    if (send(packet)) {
      _last = state;
      _lastSent = now;
    }
  }
}
