import 'dart:typed_data';

import 'online_wire.dart';

/// AnyTogether's API as the online pieces call it: JSON in, JSON out (TogetherAccount.call in the
/// launcher, fakes in tests), so they stay testable without a server. Problems come as
/// TogetherProblem.
typedef OnlineCall = Future<Map<String, dynamic>> Function(String method, String path, [Map<String, dynamic>? body]);

/// Sends a signal to another player's launcher in a game session: (to user, their device, session
/// ID, kind, data as JSON-ready value). The launcher sends it on the gateway socket as
/// `{"op":"signal","session":…}`.
typedef OnlineSignal = void Function(String to, String device, String sessionId, String kind, Object? data);

/// A signal between two players' launchers in a game session (`game_session.signal`): an offer,
/// an answer, an ICE candidate, a renegotiation request or a goodbye, in the shapes a browser's
/// toJSON() gives them.
class OnlinePeerSignal {
  const OnlinePeerSignal({required this.from, required this.device, required this.kind, this.data});

  final String from;
  final String device;
  final String kind;

  /// The signal's data (null for none).
  final Object? data;

  /// From a socket event's data: {sessionId, from, device, kind, data}; null when it is not one.
  static OnlinePeerSignal? fromEvent(Map<String, dynamic> json) {
    final from = json['from'];
    final device = json['device'];
    final kind = json['kind'];
    if (from is! String || device is! String || kind is! String) return null;
    return OnlinePeerSignal(from: from, device: device, kind: kind, data: json['data']);
  }

  /// What the gateway wants for a game session's signal.
  static Map<String, dynamic> frame({
    required String to,
    required String device,
    required String sessionId,
    required String kind,
    Object? data,
  }) => {'op': 'signal', 'to': to, 'device': device, 'session': sessionId, 'kind': kind, 'data': data};

  @override
  bool operator ==(Object other) =>
      other is OnlinePeerSignal && other.from == from && other.device == device && other.kind == kind;

  @override
  int get hashCode => Object.hash(from, device, kind);

  @override
  String toString() => 'OnlinePeerSignal($from/$device $kind)';
}

/// What a transport is told about the session: who this launcher is, every player's virtual
/// address, and the devices their signals go to.
class OnlinePeerSession {
  const OnlinePeerSession({required this.id, required this.me, required this.addresses, required this.devices});

  final String id;
  final String me;
  final Map<String, int> addresses;
  final Map<String, String> devices;

  int get ownAddress => addresses[me] ?? 0;

  @override
  bool operator ==(Object other) =>
      other is OnlinePeerSession &&
      other.id == id &&
      other.me == me &&
      _sameMap(other.addresses, addresses) &&
      _sameMap(other.devices, devices);

  @override
  int get hashCode => Object.hash(id, me, addresses.length, devices.length);

  static bool _sameMap<V>(Map<String, V> left, Map<String, V> right) =>
      left.length == right.length && left.entries.every((entry) => right[entry.key] == entry.value);
}

/// Carries game packets between this launcher and the other players of the session. The WebRTC
/// mesh ([OnlinePeerMesh] over flutter_webrtc) is the real one.
abstract class OnlinePeerTransport {
  /// The session as it is now; null when there is none.
  void update(OnlinePeerSession? session);

  /// A packet from the engine to another player (or to every other player, for a broadcast);
  /// false when nobody could be reached now.
  bool send(WireDatagram datagram);

  /// A message of the game's streams (`OnlineStreamRelay`) to another player, carried reliably and
  /// in order; false when they cannot be reached that way now.
  bool sendStream(int peer, Uint8List message);

  /// A signal from another player's launcher.
  void receive(OnlinePeerSignal signal);

  void stop();
}

/// What a transport is made with: where packets for the game go, AnyTogether (for ICE servers),
/// and how to signal another player's launcher.
class OnlinePeerContext {
  const OnlinePeerContext({
    required this.deliver,
    required this.call,
    required this.signal,
    this.deliverStream,
    this.peerGone,
  });

  final void Function(WireDatagram datagram) deliver;
  final OnlineCall call;
  final OnlineSignal signal;

  /// A stream message from the player at a virtual address.
  final void Function(int peer, Uint8List message)? deliverStream;

  /// The connection to the player at a virtual address is gone (their streams break).
  final void Function(int peer)? peerGone;
}

/// No transport: packets to other players are dropped (online play without a way to reach them).
class OnlineNoTransport implements OnlinePeerTransport {
  @override
  void update(OnlinePeerSession? session) {}

  @override
  bool send(WireDatagram datagram) => false;

  @override
  bool sendStream(int peer, Uint8List message) => false;

  @override
  void receive(OnlinePeerSignal signal) {}

  @override
  void stop() {}
}
