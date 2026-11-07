import 'dart:async';
import 'dart:typed_data';

import 'media.dart';
import 'share_audio.dart';
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

  /// A text message on the "audio" channel: the viewer's hello ([ShareAudioHello]).
  set onHello(void Function(String text) handler);

  /// Adds the game's sound to this connection as an Opus track in a stream of its own; false
  /// when the engine has none. The host offers again after.
  Future<bool> addSound();

  /// StreamPacket audio on the "audio" channel, when it is open and not backed up past [most]
  /// bytes (a viewer behind skips sound rather than fall further behind).
  bool sendSound(Uint8List packet, {int most});

  /// How the connection is doing, from WebRTC's statistics; null when it cannot say.
  Future<ShareLinkStats?> stats();

  /// What the viewer's stream may take.
  Future<void> setEncoding({required int maxBitrate, required int maxFramerate, required double scaleDown});
  Future<void> close();
}

/// A viewer's connection as the host's list shows it: the path, its round trip, the picture.
class ShareLinkStats {
  const ShareLinkStats({this.roundTripMs, this.relayed, this.framesPerSecond, this.frameHeight});
  final double? roundTripMs;
  final bool? relayed;
  final double? framesPerSecond;
  final int? frameHeight;
}

/// The game's picture and sound, captured once and sent on every viewer's connection.
abstract class ShareEngine {
  /// Captures the game's window, by its title; false when it cannot be found or read.
  Future<bool> start({required String windowTitle});

  /// Whether the game's sound can go as an Opus track (to viewers who ask for it).
  bool get hasSound;
  Future<ShareLink> link(List<Map<String, dynamic>> iceServers);

  /// The captured picture and sound published once to the media server, for a share play that
  /// went through it; null when there is no picture to publish. [changed] hears it connect or
  /// fail.
  SfuPublisher? mediaServer(void Function() changed);
  Future<void> stop();
}

/// The host's side of a share play through the media server: the captured game published once to
/// the room as the video track "game", and its sound as "game-audio" when there is one. Viewers
/// holding a pad keep the direct mesh connection; everyone else watches from there. The Mac's
/// SfuShareHost; LiveKit in the launcher (lib/ui/livekit_room.dart), fakes in tests.
abstract class SfuPublisher {
  /// Into the room with the host's token, then the tracks published.
  Future<void> start(SfuAccess access);

  /// The tracks are out.
  bool get connected;

  /// Out of the room; the capture itself goes on for the mesh.
  Future<void> close();
}

class _Viewer {
  _Viewer(this.userId, this.device, this.link);
  final String userId;
  final String device;
  final ShareLink link;
  final queued = <Map<String, dynamic>>[];

  /// How the game's sound reaches them: PCM on the "audio" channel until an answer takes the
  /// Opus track they asked for.
  var audio = ShareAudioCodec.pcm;
  bool soundAdded = false;
  ShareLinkStats? stats;
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

  /// The share play as the server said last.
  SharePlay? sharePlay;

  /// The viewers with a direct (mesh) connection here: everyone on the mesh; through the media
  /// server, pad holders and the older viewer apps in [asked].
  List<ShareViewer> mesh = const [];

  /// Viewers without a pad who asked for a mesh connection while the share play went through the
  /// media server (viewer apps from before it), and were served.
  Set<String> asked = {};

  /// Each viewer's connection state, by user ID.
  Map<String, String> get links => {for (final viewer in _viewers.values) viewer.userId: viewer.link.connectionState};

  /// How the game's sound reaches each viewer, by user ID.
  Map<String, ShareAudioCodec> get sound => {for (final viewer in _viewers.values) viewer.userId: viewer.audio};

  /// Each connected viewer's last measured link, by user ID.
  Map<String, ShareLinkStats> get stats => {
    for (final viewer in _viewers.values)
      if (viewer.stats != null && viewer.link.connectionState == 'connected') viewer.userId: viewer.stats!,
  };

  /// The share play as the server has it now: newcomers are called, leavers hung up on, and the
  /// pads follow who holds them. Through the media server only the viewers holding a pad (and
  /// older viewer apps that asked) are called here; the rest watch from the media server.
  Future<void> apply(SharePlay sharePlay) async {
    if (sharePlay.id != id) return;
    asked = {
      for (final userId in asked)
        if (sharePlay.viewers.any((viewer) => viewer.user.id == userId)) userId,
    };
    final next = ShareMedia.meshViewers(sharePlay, asked);
    final plan = ShareRoster.plan(mesh, next);
    viewers = sharePlay.viewers;
    mesh = next;
    this.sharePlay = sharePlay;
    for (final userId in plan.hangUp) {
      await hangUp(userId, sayBye: false);
    }
    router.update(ShareRoster.padsOf(sharePlay.viewers));
    for (final viewer in plan.call) {
      await call(viewer.user.id, viewer.device);
    }
    changed();
  }

  /// Whether a viewer's ask for a connection here is answered: always on the mesh; through the
  /// media server for a pad holder, or an older viewer app while there is room.
  bool _admits(String userId) {
    final share = sharePlay;
    if (share == null) return true;
    if (!ShareMedia.servesAsk(share, userId, meshPeers: _viewers.length)) return false;
    final viewer = share.viewers.where((viewer) => viewer.user.id == userId).firstOrNull;
    if (share.media == MediaRoute.sfu && viewer?.slot == null) {
      asked = {...asked, userId};
      mesh = ShareMedia.meshViewers(share, asked);
    }
    return true;
  }

  /// Calls a viewer on [device] (again, if they were on another device or their link broke).
  Future<void> call(String userId, String device) async {
    final known = _viewers[userId];
    if (known != null &&
        known.device == device &&
        known.link.connectionState != 'failed' &&
        known.link.connectionState != 'closed') {
      return;
    }
    if (known != null) await hangUp(userId, sayBye: false);
    final link = await engine.link(iceServers);
    final viewer = _Viewer(userId, device, link);
    _viewers[userId] = viewer;
    link.onCandidate = (candidate) => signal(userId, device, 'candidate', candidate);
    link.onState = changed;
    link.onPad = (packet) => router.receive(packet, userId);
    link.onHello = (text) => unawaited(_hello(viewer, text));
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
        if (viewer != null &&
            viewer.device == signal.device &&
            viewer.link.signalingState == 'have-local-offer' &&
            pending != null) {
          this.signal(viewer.userId, viewer.device, 'offer', pending);
        } else if (viewer != null || _admits(signal.from)) {
          if (viewer != null) await hangUp(signal.from, sayBye: false);
          await call(signal.from, signal.device);
        }
      case 'answer':
        final data = signal.data;
        if (viewer == null ||
            viewer.device != signal.device ||
            viewer.link.signalingState != 'have-local-offer' ||
            data is! Map<String, dynamic>) {
          return;
        }
        final encoding = ShareRoster.encoding(_viewers.length);
        final sdp = data['sdp'] as String? ?? '';
        final video = ShareRoster.tuneVideo(sdp, startKbps: encoding.startKbps, maxKbps: encoding.maxBitrate ~/ 1000);
        try {
          await viewer.link.setRemote({
            'type': 'answer',
            'sdp': ShareAudioSdp.stereoOpus(video, kbps: ShareAudioSdp.kbps, frameMs: ShareAudioSdp.frameMs),
          });
        } on Object {
          await viewer.link.setRemote({'type': 'answer', 'sdp': sdp});
        }
        // The Opus track taken: no more PCM for this viewer.
        if (viewer.soundAdded && ShareAudioSdp.takesOpus(sdp) && viewer.audio != ShareAudioCodec.opus) {
          viewer.audio = ShareAudioCodec.opus;
          changed();
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

  /// A viewer's hello: the Opus track added to their connection and offered, if they take it
  /// and the game's sound can go as one.
  Future<void> _hello(_Viewer viewer, String text) async {
    final hello = ShareAudioHello.parse(text);
    if (hello == null || hello.chosen != ShareAudioCodec.opus || !engine.hasSound || viewer.soundAdded) return;
    if (_viewers[viewer.userId] != viewer) return;
    viewer.soundAdded = true;
    if (!await viewer.link.addSound()) {
      viewer.soundAdded = false;
      return;
    }
    if (_viewers[viewer.userId] == viewer) await _offer(viewer);
  }

  /// The game's sound as StreamPacket audio: to every viewer it reaches as PCM.
  void pushSound(Uint8List packet) {
    for (final viewer in _viewers.values) {
      if (viewer.audio == ShareAudioCodec.pcm) viewer.link.sendSound(packet, most: 64 * 1024);
    }
  }

  /// Reads every connected viewer's link once (every two seconds while hosting).
  Future<void> measure() async {
    for (final viewer in _viewers.values.toList()) {
      if (viewer.link.connectionState != 'connected') continue;
      try {
        viewer.stats = await viewer.link.stats() ?? viewer.stats;
      } on Object {
        // The connection went meanwhile.
      }
    }
    changed();
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
