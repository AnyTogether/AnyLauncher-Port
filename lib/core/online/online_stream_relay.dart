import 'dart:math';
import 'dart:typed_data';

import 'online_wire.dart';

/// What a message between launchers does to a stream.
enum StreamOp {
  open(1),
  accept(2),
  data(3),
  close(4);

  const StreamOp(this.value);
  final int value;

  static StreamOp? of(int value) => StreamOp.values.where((op) => op.value == value).firstOrNull;
}

/// One message of the game's streams between two players' launchers, on the reliable channel:
/// u8 op, u8 flags (bit 0: the sender opened this stream), u32 stream (the opener's number), then
/// for open u16 source port, u16 source virtual port, u16 destination port, u16 destination
/// virtual port; for data the bytes; for close u8 reason. Little-endian; the Mac launcher's
/// OnlineStreamRelay.Message, byte for byte.
class StreamMessage {
  StreamMessage({
    required this.op,
    required this.senderOpened,
    required this.stream,
    this.sourcePort = 0,
    this.sourceVport = 0,
    this.destinationPort = 0,
    this.destinationVport = 0,
    List<int> data = const [],
    this.reason = StreamCloseReason.closed,
  }) : data = data is Uint8List ? data : Uint8List.fromList(data);

  final StreamOp op;
  final bool senderOpened;
  final int stream;
  final int sourcePort;
  final int sourceVport;
  final int destinationPort;
  final int destinationVport;
  final Uint8List data;
  final StreamCloseReason reason;

  static const headerSize = 6;

  Uint8List get bytes {
    final writer = WireWriter()
      ..u8(op.value)
      ..u8(senderOpened ? 1 : 0)
      ..u32(stream);
    switch (op) {
      case StreamOp.open:
        writer
          ..u16(sourcePort)
          ..u16(sourceVport)
          ..u16(destinationPort)
          ..u16(destinationVport);
      case StreamOp.data:
        writer.raw(data);
      case StreamOp.close:
        writer.u8(reason.value);
      case StreamOp.accept:
        break;
    }
    return writer.data;
  }

  /// Null when it is malformed, of an unknown op, names stream 0, or opens a stream the sender
  /// says it did not open.
  static StreamMessage? parse(List<int> bytes) {
    final reader = WireReader(bytes);
    final op = StreamOp.of(reader.u8());
    final senderOpened = reader.u8() & 1 != 0;
    final stream = reader.u32();
    if (op == null || !reader.ok || stream == 0) return null;
    final StreamMessage message;
    switch (op) {
      case StreamOp.open:
        message = StreamMessage(
          op: op,
          senderOpened: senderOpened,
          stream: stream,
          sourcePort: reader.u16(),
          sourceVport: reader.u16(),
          destinationPort: reader.u16(),
          destinationVport: reader.u16(),
        );
        if (!senderOpened) return null;
      case StreamOp.data:
        message = StreamMessage(op: op, senderOpened: senderOpened, stream: stream, data: bytes.sublist(headerSize));
      case StreamOp.close:
        message = StreamMessage(
          op: op,
          senderOpened: senderOpened,
          stream: stream,
          reason: StreamCloseReason.of(reader.u8()),
        );
      case StreamOp.accept:
        message = StreamMessage(op: op, senderOpened: senderOpened, stream: stream);
    }
    return reader.ok ? message : null;
  }

  @override
  bool operator ==(Object other) =>
      other is StreamMessage &&
      other.op == op &&
      other.senderOpened == senderOpened &&
      other.stream == stream &&
      other.sourcePort == sourcePort &&
      other.sourceVport == sourceVport &&
      other.destinationPort == destinationPort &&
      other.destinationVport == destinationVport &&
      other.reason == reason &&
      other.data.length == data.length &&
      Iterable<int>.generate(data.length).every((index) => other.data[index] == data[index]);

  @override
  int get hashCode => Object.hash(op, senderOpened, stream, data.length);

  @override
  String toString() => 'StreamMessage(${op.name}, $stream, opener: $senderOpened)';
}

typedef _Key = ({int peer, int stream, bool mine});

class _Route {
  _Route(this.key);
  final _Key key;
  bool engineEnded = false;
  bool peerEnded = false;
}

/// Carries the game's streams (stream P2P sockets) between the engine's bridge and the other
/// players' launchers. The engine numbers the streams it opens and the launcher those it opens to
/// the engine ([OnlineWire.launcherStream] set); between launchers a stream is named by the number
/// its opener's engine gave it and by who opened it. The transport carries the messages reliably
/// and in order. The Mac launcher's OnlineStreamRelay, the same behaviour.
class OnlineStreamRelay {
  /// [toEngine] hands a frame to the game (the bridge); [toPeer] sends a message to a player
  /// (false when they cannot be reached now).
  OnlineStreamRelay({required this.toEngine, required this.toPeer});

  final void Function(WireStream frame) toEngine;
  final bool Function(int peer, Uint8List message) toPeer;

  /// The most game bytes in one message between launchers.
  static const maxChunk = 16 * 1024;

  final _routes = <int, _Route>{};
  final _engineIds = <_Key, int>{};
  int _lastLauncherId = 0;

  /// Streams open now.
  int get count => _routes.length;

  /// A stream frame from the engine.
  void fromEngine(WireStream frame) {
    final id = frame.stream;
    switch (frame.kind) {
      case WireKind.streamOpen:
        final key = (peer: frame.peer, stream: id, mine: true);
        if (id & OnlineWire.launcherStream != 0 || _routes.containsKey(id) || _engineIds.containsKey(key)) return;
        _routes[id] = _Route(key);
        _engineIds[key] = id;
        final message = StreamMessage(
          op: StreamOp.open,
          senderOpened: true,
          stream: id,
          sourcePort: frame.localPort,
          sourceVport: frame.localVport,
          destinationPort: frame.peerPort,
          destinationVport: frame.peerVport,
        );
        if (!toPeer(frame.peer, message.bytes)) {
          _remove(id);
          toEngine(WireStream.close(id, StreamCloseReason.reset));
        }
      case WireKind.streamAccept:
        final key = _routes[id]?.key;
        if (key == null) return;
        _send(id, key, StreamMessage(op: StreamOp.accept, senderOpened: key.mine, stream: key.stream));
      case WireKind.streamData:
        final key = _routes[id]?.key;
        if (key == null) return;
        var offset = 0;
        do {
          final end = min(frame.data.length, offset + maxChunk);
          final chunk = Uint8List.sublistView(frame.data, offset, end);
          if (!_send(
            id,
            key,
            StreamMessage(op: StreamOp.data, senderOpened: key.mine, stream: key.stream, data: chunk),
          )) {
            return;
          }
          offset = end;
        } while (offset < frame.data.length);
      case WireKind.streamClose:
        final key = _routes[id]?.key;
        if (key == null) return;
        toPeer(
          key.peer,
          StreamMessage(op: StreamOp.close, senderOpened: key.mine, stream: key.stream, reason: frame.reason).bytes,
        );
        _ended(id, byEngine: true, reason: frame.reason);
      default:
        break;
    }
  }

  /// A message from another player's launcher.
  void fromPeer(int peer, Uint8List bytes) {
    final message = StreamMessage.parse(bytes);
    if (message == null) return;
    final key = (peer: peer, stream: message.stream, mine: !message.senderOpened);
    if (message.op == StreamOp.open) {
      if (_engineIds.containsKey(key)) return;
      var id = _lastLauncherId;
      do {
        id = (id + 1) & ~OnlineWire.launcherStream & 0xFFFFFFFF;
      } while (id == 0 || _routes.containsKey(id | OnlineWire.launcherStream));
      _lastLauncherId = id;
      id |= OnlineWire.launcherStream;
      _routes[id] = _Route(key);
      _engineIds[key] = id;
      toEngine(
        WireStream.open(
          stream: id,
          peer: peer,
          peerPort: message.sourcePort,
          peerVport: message.sourceVport,
          localPort: message.destinationPort,
          localVport: message.destinationVport,
        ),
      );
      return;
    }
    final id = _engineIds[key];
    if (id == null) {
      // A stream this side no longer knows: the other side learns it is gone.
      if (message.op != StreamOp.close) {
        toPeer(
          peer,
          StreamMessage(
            op: StreamOp.close,
            senderOpened: !message.senderOpened,
            stream: message.stream,
            reason: StreamCloseReason.reset,
          ).bytes,
        );
      }
      return;
    }
    switch (message.op) {
      case StreamOp.accept:
        toEngine(WireStream.accept(id));
      case StreamOp.data:
        toEngine(WireStream.data(id, message.data));
      case StreamOp.close:
        toEngine(WireStream.close(id, message.reason));
        _ended(id, byEngine: false, reason: message.reason);
      case StreamOp.open:
        break;
    }
  }

  /// A player's connection is gone: their streams break.
  void peerGone(int peer) {
    final gone = [
      for (final entry in _routes.entries)
        if (entry.value.key.peer == peer) entry.key,
    ];
    for (final id in gone) {
      _remove(id);
      toEngine(WireStream.close(id, StreamCloseReason.reset));
    }
  }

  /// The game's connection is gone (or a new game connected): every stream breaks for the players.
  void engineGone() {
    final gone = [for (final route in _routes.values) route.key];
    _routes.clear();
    _engineIds.clear();
    for (final key in gone) {
      toPeer(
        key.peer,
        StreamMessage(
          op: StreamOp.close,
          senderOpened: key.mine,
          stream: key.stream,
          reason: StreamCloseReason.reset,
        ).bytes,
      );
    }
  }

  bool _send(int id, _Key key, StreamMessage message) {
    if (toPeer(key.peer, message.bytes)) return true;
    // The player cannot be reached (or the channel is full): the stream breaks on both sides.
    _remove(id);
    toEngine(WireStream.close(id, StreamCloseReason.reset));
    toPeer(
      key.peer,
      StreamMessage(
        op: StreamOp.close,
        senderOpened: key.mine,
        stream: key.stream,
        reason: StreamCloseReason.reset,
      ).bytes,
    );
    return false;
  }

  /// A stream is forgotten once both sides ended it, or at once when it was refused or broke.
  void _ended(int id, {required bool byEngine, required StreamCloseReason reason}) {
    final route = _routes[id];
    if (route == null) return;
    if (byEngine) {
      route.engineEnded = true;
    } else {
      route.peerEnded = true;
    }
    if (reason != StreamCloseReason.closed || (route.engineEnded && route.peerEnded)) _remove(id);
  }

  void _remove(int id) {
    final route = _routes.remove(id);
    if (route != null) _engineIds.remove(route.key);
  }
}
