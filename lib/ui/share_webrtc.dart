import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/together/share_audio.dart';
import '../core/together/share_host.dart';
import '../core/together/share_viewer.dart';
import 'livekit_room.dart';

/// Share play's picture and sound with flutter_webrtc on Windows and Linux: the game's window
/// from its desktop capturer (picked by the window's title), and one RTCPeerConnection per
/// viewer with the "pad" and "audio" data channels the viewers expect (unordered, never sent
/// again). The game's sound goes as the Mac sends it: PCM on the "audio" channel to everyone
/// (from the launcher's own capture of the game, SharePlayModel), and, to a viewer whose hello
/// asks for it, the loopback capture's track as Opus in a stream of its own (in the picture's, a
/// viewer's WebRTC would hold the picture back to keep lips in sync). The loopback is the game's
/// process on Windows, the default output's monitor on Linux (with libpulse).
class WebRtcShare implements ShareEngine {
  MediaStream? _stream;
  MediaStream? _soundStream;
  MediaStreamTrack? _video;
  MediaStreamTrack? _sound;

  @override
  bool get hasSound => _sound != null;

  @override
  Future<bool> start({required String windowTitle}) async {
    final List<DesktopCapturerSource> sources;
    try {
      sources = await desktopCapturer.getSources(types: [SourceType.Window]);
    } on Object {
      return false;
    }
    final source =
        sources.where((source) => source.name == windowTitle).firstOrNull ??
        sources.where((source) => source.name.isNotEmpty && windowTitle.startsWith(source.name)).firstOrNull;
    if (source == null) return false;
    try {
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': {'exact': source.id},
          'mandatory': {'frameRate': 60.0},
          'cursor': 'never',
        },
        'audio': true,
      });
      _stream = stream;
      _video = stream.getVideoTracks().firstOrNull;
      _sound = stream.getAudioTracks().firstOrNull;
      if (_sound != null) {
        final soundStream = await createLocalMediaStream('game-sound');
        await soundStream.addTrack(_sound!);
        _soundStream = soundStream;
      }
      return _video != null;
    } on Object {
      return false;
    }
  }

  @override
  Future<ShareLink> link(List<Map<String, dynamic>> iceServers) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    RTCRtpSender? sender;
    if (_video case final video? when _stream != null) {
      final transceiver = await pc.addTransceiver(
        track: video,
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: [_stream!]),
      );
      sender = transceiver.sender;
    }
    RTCDataChannelInit lossy() => RTCDataChannelInit()
      ..ordered = false
      ..maxRetransmits = 0;
    final pad = await pc.createDataChannel('pad', lossy());
    final audio = await pc.createDataChannel('audio', lossy());
    return _Link(pc, pad, audio, sender, () async {
      final sound = _sound;
      final stream = _soundStream;
      if (sound == null || stream == null) return false;
      await pc.addTransceiver(
        track: sound,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: [stream]),
      );
      return true;
    });
  }

  /// The same captured window and sound, published once to the media server (LiveKit) when the
  /// share play goes through it.
  @override
  SfuPublisher? mediaServer(void Function() changed) {
    final stream = _stream;
    final video = _video;
    if (stream == null || video == null) return null;
    return LiveKitShareHost(stream: stream, video: video, sound: _sound, soundStream: _soundStream, changed: changed);
  }

  @override
  Future<void> stop() async {
    final stream = _stream;
    _stream = null;
    _video = null;
    _sound = null;
    for (final track in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await stream?.dispose();
    await _soundStream?.dispose();
    _soundStream = null;
  }
}

class _Link implements ShareLink {
  _Link(this.pc, this.pad, this.audio, this.sender, this._addSound) {
    pc.onConnectionState = (_) => _onState?.call();
    pad.onMessage = (message) {
      if (message.isBinary) _onPad?.call(message.binary);
    };
    audio.onMessage = (message) {
      if (!message.isBinary) _onHello?.call(message.text);
    };
  }

  final RTCPeerConnection pc;
  final RTCDataChannel pad;
  final RTCDataChannel audio;
  final RTCRtpSender? sender;
  final Future<bool> Function() _addSound;
  void Function()? _onState;
  void Function(Uint8List)? _onPad;
  void Function(String)? _onHello;

  /// Kept here, not read from the plugin, which hears of changes a moment late.
  String _signaling = 'stable';
  bool _hasRemote = false;
  Map<String, dynamic>? _local;

  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) => pc.onIceCandidate = (candidate) {
    if (candidate.candidate != null) handler(Map<String, dynamic>.from(candidate.toMap() as Map));
  };

  @override
  set onState(void Function() handler) => _onState = handler;

  @override
  set onPad(void Function(Uint8List packet) handler) => _onPad = handler;

  @override
  String get signalingState => _signaling;

  @override
  bool get hasRemote => _hasRemote;

  @override
  Map<String, dynamic>? get localDescription => _local;

  @override
  String get connectionState => switch (pc.connectionState) {
    RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'connecting',
    RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'disconnected',
    RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
    RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
    _ => 'new',
  };

  @override
  Future<Map<String, dynamic>> createOffer({bool restart = false}) async {
    if (restart) await pc.restartIce();
    final offer = await pc.createOffer();
    return {'type': offer.type, 'sdp': offer.sdp};
  }

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    final type = description['type'] as String?;
    await pc.setLocalDescription(RTCSessionDescription(description['sdp'] as String?, type));
    _local = description;
    _signaling = type == 'offer' ? 'have-local-offer' : 'stable';
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    final type = description['type'] as String?;
    await pc.setRemoteDescription(RTCSessionDescription(description['sdp'] as String?, type));
    _hasRemote = true;
    _signaling = type == 'offer' ? 'have-remote-offer' : 'stable';
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) => pc.addCandidate(
    RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    ),
  );

  @override
  void sendPad(Uint8List packet) {
    if (pad.state == RTCDataChannelState.RTCDataChannelOpen) unawaitedSend(packet);
  }

  void unawaitedSend(Uint8List packet) => pad.send(RTCDataChannelMessage.fromBinary(packet)).catchError((Object _) {});

  @override
  set onHello(void Function(String text) handler) => _onHello = handler;

  @override
  Future<bool> addSound() => _addSound();

  @override
  bool sendSound(Uint8List packet, {int most = 64 * 1024}) {
    if (audio.state != RTCDataChannelState.RTCDataChannelOpen || (audio.bufferedAmount ?? 0) > most) return false;
    audio.send(RTCDataChannelMessage.fromBinary(packet)).catchError((Object _) {});
    return true;
  }

  @override
  Future<ShareLinkStats?> stats() async {
    final reports = await pc.getStats();
    return ShareWebRtcStats.host(reports);
  }

  @override
  Future<void> setEncoding({required int maxBitrate, required int maxFramerate, required double scaleDown}) async {
    final sender = this.sender;
    if (sender == null) return;
    final parameters = sender.parameters;
    final encodings = parameters.encodings;
    if (encodings == null || encodings.isEmpty) return;
    for (final encoding in encodings) {
      encoding
        ..maxBitrate = maxBitrate
        ..maxFramerate = maxFramerate
        ..scaleResolutionDownBy = scaleDown;
    }
    parameters.degradationPreference = RTCDegradationPreference.BALANCED;
    await sender.setParameters(parameters);
  }

  @override
  Future<void> close() async {
    _onState = null;
    _onPad = null;
    _onHello = null;
    await pc.close();
  }
}

/// WebRTC's statistics as share play reads them, for the host's list and the viewer's chip.
abstract final class ShareWebRtcStats {
  static ({double? roundTripMs, bool? relayed}) _path(List<StatsReport> reports) {
    final byId = {for (final report in reports) report.id: report};
    StatsReport? pair;
    for (final report in reports) {
      if (report.type == 'transport' && report.values['selectedCandidatePairId'] is String) {
        pair = byId[report.values['selectedCandidatePairId']];
      }
    }
    pair ??= reports
        .where(
          (report) =>
              report.type == 'candidate-pair' &&
              (report.values['nominated'] == true || report.values['nominated'] == 'true') &&
              report.values['state'] == 'succeeded',
        )
        .firstOrNull;
    if (pair == null) return (roundTripMs: null, relayed: null);
    final seconds = _number(pair.values['currentRoundTripTime']);
    final local = byId[pair.values['localCandidateId']];
    final remote = byId[pair.values['remoteCandidateId']];
    return (
      roundTripMs: seconds == null ? null : seconds * 1000,
      relayed: local == null && remote == null
          ? null
          : local?.values['candidateType'] == 'relay' || remote?.values['candidateType'] == 'relay',
    );
  }

  static double? _number(Object? value) => value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

  static ({double? fps, int? height}) _video(List<StatsReport> reports, String type) {
    for (final report in reports) {
      final kind = report.values['kind'] ?? report.values['mediaType'];
      if (report.type == type && kind == 'video') {
        return (fps: _number(report.values['framesPerSecond']), height: _number(report.values['frameHeight'])?.round());
      }
    }
    return (fps: null, height: null);
  }

  static ShareLinkStats host(List<StatsReport> reports) {
    final path = _path(reports);
    final video = _video(reports, 'outbound-rtp');
    return ShareLinkStats(
      roundTripMs: path.roundTripMs,
      relayed: path.relayed,
      framesPerSecond: video.fps,
      frameHeight: video.height,
    );
  }

  static WatchStats viewer(List<StatsReport> reports) {
    final path = _path(reports);
    final video = _video(reports, 'inbound-rtp');
    return WatchStats(
      roundTripMs: path.roundTripMs,
      relayed: path.relayed,
      framesPerSecond: video.fps,
      height: video.height,
    );
  }
}

/// A viewer's connections with flutter_webrtc: receive-only, the host's picture drawn by an
/// RTCVideoRenderer, the Opus track played out by WebRTC's own audio device (as the party's
/// voice is), the channels the host made handed on as they open.
class WebRtcWatch implements WatchEngine {
  /// The picture of the connection now, for RTCVideoView.
  final renderer = RTCVideoRenderer();

  /// Whether a picture has come.
  final picture = ValueNotifier(false);
  bool _ready = false;

  @override
  List<ShareAudioCodec> get codecs => const [ShareAudioCodec.opus, ShareAudioCodec.pcm];

  @override
  Future<WatchLink> link(List<Map<String, dynamic>> iceServers) async {
    if (!_ready) {
      await renderer.initialize();
      _ready = true;
    }
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    return _WatchLink(pc, this);
  }

  void _show(MediaStream? stream) {
    renderer.srcObject = stream;
    picture.value = stream != null;
  }

  Future<void> dispose() async {
    picture.value = false;
    if (!_ready) return;
    renderer.srcObject = null;
    await renderer.dispose();
  }
}

class _WatchLink implements WatchLink {
  _WatchLink(this.pc, this.engine) {
    pc.onConnectionState = (_) => _onState?.call();
    pc.onTrack = (event) {
      if (event.track.kind != 'video') return;
      engine._show(event.streams.firstOrNull);
    };
    pc.onDataChannel = (channel) {
      final label = channel.label ?? '';
      _channels[label] = channel;
      channel.onMessage = (message) {
        if (message.isBinary) _onBinary?.call(label, message.binary);
      };
      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) _onOpen?.call(label);
      };
      if (channel.state == RTCDataChannelState.RTCDataChannelOpen) _onOpen?.call(label);
    };
  }

  final RTCPeerConnection pc;
  final WebRtcWatch engine;
  final _channels = <String, RTCDataChannel>{};
  void Function()? _onState;
  void Function(String)? _onOpen;
  void Function(String, Uint8List)? _onBinary;
  bool _hasRemote = false;

  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) => pc.onIceCandidate = (candidate) {
    if (candidate.candidate != null) handler(Map<String, dynamic>.from(candidate.toMap() as Map));
  };

  @override
  set onState(void Function() handler) => _onState = handler;
  @override
  set onOpen(void Function(String label) handler) => _onOpen = handler;
  @override
  set onBinary(void Function(String label, Uint8List bytes) handler) => _onBinary = handler;
  @override
  bool get hasRemote => _hasRemote;

  @override
  String get connectionState => switch (pc.connectionState) {
    RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'connecting',
    RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'disconnected',
    RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
    RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
    _ => 'new',
  };

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    await pc.setRemoteDescription(RTCSessionDescription(description['sdp'] as String?, description['type'] as String?));
    _hasRemote = true;
  }

  @override
  Future<Map<String, dynamic>> createAnswer() async {
    final answer = await pc.createAnswer();
    return {'type': answer.type, 'sdp': answer.sdp};
  }

  @override
  Future<void> setLocal(Map<String, dynamic> description) =>
      pc.setLocalDescription(RTCSessionDescription(description['sdp'] as String?, description['type'] as String?));

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) => pc.addCandidate(
    RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    ),
  );

  @override
  bool sendBinary(String label, Uint8List bytes, {int most = 64 * 1024}) {
    final channel = _channels[label];
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return false;
    if ((channel.bufferedAmount ?? 0) > most) return false;
    channel.send(RTCDataChannelMessage.fromBinary(bytes)).catchError((Object _) {});
    return true;
  }

  @override
  bool sendText(String label, String text) {
    final channel = _channels[label];
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return false;
    channel.send(RTCDataChannelMessage(text)).catchError((Object _) {});
    return true;
  }

  @override
  Future<WatchStats> stats() async => ShareWebRtcStats.viewer(await pc.getStats());

  @override
  Future<void> close() async {
    _onState = null;
    _onOpen = null;
    _onBinary = null;
    engine._show(null);
    await pc.close();
  }
}
