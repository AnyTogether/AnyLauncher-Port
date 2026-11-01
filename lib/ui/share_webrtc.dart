import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/together/share_host.dart';

/// Share play's picture and sound with flutter_webrtc on Windows and Linux: the game's window
/// from its desktop capturer (picked by the window's title), the computer's sound from its
/// loopback capture as an Opus track in a stream of its own (in the picture's, a viewer's
/// WebRTC would hold the picture back to keep lips in sync), and one RTCPeerConnection per
/// viewer with the "pad" and "audio" data channels the viewers expect (unordered, never sent
/// again).
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
    if (_sound case final sound? when _soundStream != null) {
      await pc.addTransceiver(
        track: sound,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: [_soundStream!]),
      );
    }
    RTCDataChannelInit lossy() => RTCDataChannelInit()
      ..ordered = false
      ..maxRetransmits = 0;
    final pad = await pc.createDataChannel('pad', lossy());
    await pc.createDataChannel('audio', lossy());
    return _Link(pc, pad, sender);
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
  _Link(this.pc, this.pad, this.sender) {
    pc.onConnectionState = (_) => _onState?.call();
    pad.onMessage = (message) {
      if (message.isBinary) _onPad?.call(message.binary);
    };
  }

  final RTCPeerConnection pc;
  final RTCDataChannel pad;
  final RTCRtpSender? sender;
  void Function()? _onState;
  void Function(Uint8List)? _onPad;

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
    await pc.close();
  }
}
