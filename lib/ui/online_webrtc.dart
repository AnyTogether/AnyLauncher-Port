import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/online/online_peer_mesh.dart';

/// Online play's peer connections with flutter_webrtc on Windows and Linux: data only (no
/// microphone, no media), one `game` channel per connection, unordered and without resends, the
/// way the Mac launcher opens it, so a PC and a Mac connect to each other.
class WebRtcGameLinks implements GameLinks {
  @override
  Future<GameLink> link(List<Map<String, dynamic>> iceServers) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    return _GameLink(pc);
  }
}

/// RTCDataChannelInit leaves maxRetransmits out unless it is above 0, which would make the
/// channel reliable; the game channel needs it at 0 (no resends), as the Mac launcher sets it.
class _Unreliable extends RTCDataChannelInit {
  _Unreliable() {
    ordered = false;
    binaryType = 'binary';
  }

  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'maxRetransmits': 0};
}

class _GameLink implements GameLink {
  _GameLink(this.pc) {
    pc.onConnectionState = (state) => _onState?.call(_name(state));
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) _onCandidate?.call(Map<String, dynamic>.from(candidate.toMap() as Map));
    };
    pc.onDataChannel = (channel) {
      if (channel.label == OnlinePeerMesh.label) _use(channel);
    };
  }

  final RTCPeerConnection pc;
  RTCDataChannel? _channel;
  bool _open = false;
  void Function(Map<String, dynamic>)? _onCandidate;
  void Function(Uint8List)? _onMessage;
  void Function(String)? _onState;

  static String _name(RTCPeerConnectionState state) => switch (state) {
    RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'connecting',
    RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'disconnected',
    RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
    RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
    _ => 'new',
  };

  void _use(RTCDataChannel channel) {
    _channel = channel;
    _open = channel.state == RTCDataChannelState.RTCDataChannelOpen;
    channel.onDataChannelState = (state) => _open = state == RTCDataChannelState.RTCDataChannelOpen;
    channel.onMessage = (message) {
      if (message.isBinary) _onMessage?.call(message.binary);
    };
  }

  @override
  Future<void> openChannel() async => _use(await pc.createDataChannel(OnlinePeerMesh.label, _Unreliable()));

  @override
  bool send(Uint8List data) {
    final channel = _channel;
    if (channel == null || !_open) return false;
    unawaited(channel.send(RTCDataChannelMessage.fromBinary(data)).catchError((Object _) {}));
    return true;
  }

  @override
  Future<Map<String, dynamic>> createOffer() async {
    final offer = await pc.createOffer({});
    return {'type': offer.type, 'sdp': offer.sdp};
  }

  @override
  Future<Map<String, dynamic>> createAnswer() async {
    final answer = await pc.createAnswer({});
    return {'type': answer.type, 'sdp': answer.sdp};
  }

  @override
  Future<void> setLocal(Map<String, dynamic> description) =>
      pc.setLocalDescription(RTCSessionDescription(description['sdp'] as String?, description['type'] as String?));

  @override
  Future<void> setRemote(Map<String, dynamic> description) =>
      pc.setRemoteDescription(RTCSessionDescription(description['sdp'] as String?, description['type'] as String?));

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) => pc.addCandidate(
    RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    ),
  );

  @override
  set onCandidate(void Function(Map<String, dynamic> candidate) handler) => _onCandidate = handler;

  @override
  set onMessage(void Function(Uint8List data) handler) => _onMessage = handler;

  @override
  set onState(void Function(String state) handler) => _onState = handler;

  @override
  Future<void> close() async {
    _onState = null;
    _onMessage = null;
    _onCandidate = null;
    _open = false;
    await _channel?.close().catchError((Object _) {});
    await pc.close();
  }
}
