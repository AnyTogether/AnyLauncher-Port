import 'dart:convert';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_bridge_server.dart';
import 'package:anyps5_desktop/core/online/online_stream_relay.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:test/test.dart';

import '../../support/online_fakes.dart';

/// One launcher's stream relay with a recording engine, wired to another's as two players'
/// launchers are over the reliable channel.
class RelayEnd {
  RelayEnd(this.address);

  final int address;
  final engine = <WireStream>[];
  late OnlineStreamRelay relay;
  bool reachable = true;

  List<WireStream> take() {
    final taken = [...engine];
    engine.clear();
    return taken;
  }

  static (RelayEnd, RelayEnd) pair(int a, int b) {
    final left = RelayEnd(a), right = RelayEnd(b);
    left.relay = OnlineStreamRelay(
      toEngine: left.engine.add,
      toPeer: (peer, bytes) {
        if (!left.reachable || peer != right.address) return false;
        right.relay.fromPeer(left.address, bytes);
        return true;
      },
    );
    right.relay = OnlineStreamRelay(
      toEngine: right.engine.add,
      toPeer: (peer, bytes) {
        if (!right.reachable || peer != left.address) return false;
        left.relay.fromPeer(right.address, bytes);
        return true;
      },
    );
    return (left, right);
  }
}

void main() {
  const a = 0xC6120001, b = 0xC6120002;

  test('stream frames and launcher messages are the engine\'s and the Mac launcher\'s, byte for byte', () {
    // The engine's test (online_bridge "streams") and the Mac launcher's
    // (OnlineStreamRelayTests.testStreamFramesMatchTheEngineByteForByte).
    final open = WireStream.open(
      stream: 5,
      peer: 0xC6120002,
      peerPort: 3659,
      peerVport: 1,
      localPort: 3660,
      localVport: 5,
    );
    expect(
      OnlineWire.hex(open.frame),
      '10000000'
      '1103'
      '0000'
      '00000000'
      '05000000'
      '020012c6'
      '4b0e'
      '0100'
      '4c0e'
      '0500',
    );
    expect(
      OnlineWire.hex(WireStream.data(0x80000001, [1, 2, 3]).payload),
      '01000080'
      '03000000'
      '010203',
    );
    expect(
      OnlineWire.hex(WireStream.close(5, StreamCloseReason.refused).payload),
      '05000000'
      '01',
    );
    expect(OnlineWire.hex(WireStream.accept(0x80000001).payload), '01000080');
    for (final frame in [
      open,
      WireStream.accept(9),
      WireStream.data(9, utf8.encode('x')),
      WireStream.close(9, StreamCloseReason.reset),
    ]) {
      expect(WireStream.parse(frame.kind, frame.payload), frame);
    }
    expect(
      WireStream.parse(WireKind.streamClose, [5, 0, 0, 0, 9]),
      WireStream.close(5, StreamCloseReason.reset),
      reason: 'an unknown reason is a break',
    );
    expect(WireStream.parse(WireKind.streamAccept, [0, 0, 0, 0]), isNull, reason: 'stream 0 is never one');
    expect(
      WireStream.parse(
        WireKind.streamOpen,
        WireStream.open(stream: 5, peer: 0x0A000001, peerPort: 1, peerVport: 0, localPort: 1, localVport: 0).payload,
      ),
      isNull,
      reason: 'a stream from outside the virtual network is dropped',
    );
    expect(WireStream.parse(WireKind.datagram, [1, 0, 0, 0]), isNull);

    final message = StreamMessage(
      op: StreamOp.open,
      senderOpened: true,
      stream: 5,
      sourcePort: 3660,
      sourceVport: 5,
      destinationPort: 3659,
      destinationVport: 1,
    );
    expect(
      OnlineWire.hex(message.bytes),
      '01'
      '01'
      '05000000'
      '4c0e'
      '0500'
      '4b0e'
      '0100',
    );
    expect(StreamMessage.parse(message.bytes), message);
    final data = StreamMessage(op: StreamOp.data, senderOpened: false, stream: 5, data: [7, 8]);
    expect(
      OnlineWire.hex(data.bytes),
      '03'
      '00'
      '05000000'
      '0708',
    );
    expect(StreamMessage.parse(data.bytes), data);
    expect(
      OnlineWire.hex(
        StreamMessage(op: StreamOp.close, senderOpened: true, stream: 5, reason: StreamCloseReason.refused).bytes,
      ),
      '04'
      '01'
      '05000000'
      '01',
    );
    expect(
      OnlineWire.hex(StreamMessage(op: StreamOp.accept, senderOpened: false, stream: 5).bytes),
      '02'
      '00'
      '05000000',
    );
    expect(StreamMessage.parse([1, 0, 5, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0]), isNull, reason: 'only the opener opens');
    expect(StreamMessage.parse([9, 0, 5, 0, 0, 0]), isNull, reason: 'an unknown op is dropped');
  });

  test('two relays carry a stream both ways, in chunks, through a half close', () {
    final (alice, bob) = RelayEnd.pair(a, b);
    alice.relay.fromEngine(
      WireStream.open(stream: 1, peer: b, peerPort: 3659, peerVport: 1, localPort: 3660, localVport: 5),
    );
    final opened = bob.take().single;
    expect(opened.kind, WireKind.streamOpen);
    final id = opened.stream;
    expect(id & OnlineWire.launcherStream, isNot(0), reason: 'the launcher numbers its streams with the top bit set');
    expect(
      [opened.peer, opened.peerPort, opened.peerVport, opened.localPort, opened.localVport],
      [a, 3660, 5, 3659, 1],
      reason: 'the other engine gets the opener\'s address, port and virtual port, and its own',
    );
    bob.relay.fromEngine(WireStream.accept(id));
    expect(alice.take(), [WireStream.accept(1)]);

    alice.relay.fromEngine(WireStream.data(1, utf8.encode('ping')));
    expect(bob.take(), [WireStream.data(id, utf8.encode('ping'))]);
    final big = Uint8List.fromList(List.generate(40000, (index) => (index * 7) & 0xFF));
    bob.relay.fromEngine(WireStream.data(id, big));
    final chunks = alice.take();
    expect(chunks, hasLength(3), reason: 'stream data crosses in chunks of at most 16 KiB');
    expect([for (final chunk in chunks) ...chunk.data], big);

    alice.relay.fromEngine(WireStream.close(1, StreamCloseReason.closed));
    expect(bob.take(), [WireStream.close(id, StreamCloseReason.closed)]);
    bob.relay.fromEngine(WireStream.data(id, utf8.encode('late')));
    expect(alice.take(), [WireStream.data(1, utf8.encode('late'))], reason: 'the other way still carries');
    bob.relay.fromEngine(WireStream.close(id, StreamCloseReason.closed));
    expect(alice.take(), [WireStream.close(1, StreamCloseReason.closed)]);
    expect(alice.relay.count + bob.relay.count, 0, reason: 'a stream both sides ended is forgotten');
  });

  test('refused, unreachable and gone streams', () {
    final (alice, bob) = RelayEnd.pair(a, b);
    alice.relay.fromEngine(
      WireStream.open(stream: 1, peer: b, peerPort: 4000, peerVport: 1, localPort: 0, localVport: 0),
    );
    final first = bob.take().single.stream;
    bob.relay.fromEngine(WireStream.close(first, StreamCloseReason.refused));
    expect(alice.take(), [WireStream.close(1, StreamCloseReason.refused)], reason: 'a refusal reaches the opener');
    expect(alice.relay.count + bob.relay.count, 0);

    alice.relay.fromEngine(
      WireStream.open(stream: 2, peer: 0xC6120099, peerPort: 1, peerVport: 0, localPort: 0, localVport: 0),
    );
    expect(alice.take(), [WireStream.close(2, StreamCloseReason.reset)], reason: 'nobody to reach: it breaks at once');

    alice.relay.fromEngine(WireStream.open(stream: 3, peer: b, peerPort: 1, peerVport: 0, localPort: 0, localVport: 0));
    final third = bob.take().single.stream;
    bob.relay.fromEngine(WireStream.accept(third));
    alice.take();
    alice.relay.peerGone(b);
    expect(alice.take(), [
      WireStream.close(3, StreamCloseReason.reset),
    ], reason: 'a player who is gone breaks the streams');
    bob.relay.fromEngine(WireStream.data(third, utf8.encode('x')));
    expect(bob.take(), [WireStream.close(third, StreamCloseReason.reset)], reason: 'the other side learns it is gone');

    alice.relay.fromEngine(WireStream.open(stream: 4, peer: b, peerPort: 1, peerVport: 0, localPort: 0, localVport: 0));
    final fourth = bob.take().single.stream;
    alice.relay.engineGone();
    expect(bob.take(), [
      WireStream.close(fourth, StreamCloseReason.reset),
    ], reason: 'a game that goes breaks its streams');
    expect(alice.relay.count, 0);

    alice.relay.fromEngine(WireStream.open(stream: 5, peer: b, peerPort: 1, peerVport: 0, localPort: 0, localVport: 0));
    final fifth = bob.take().single.stream;
    bob.reachable = false;
    bob.relay.fromEngine(WireStream.accept(fifth));
    expect(bob.take(), [
      WireStream.close(fifth, StreamCloseReason.reset),
    ], reason: 'a message that cannot go breaks it');
  });

  test('the bridge carries stream frames both ways', () async {
    final secret = Uint8List.fromList(List.generate(32, (i) => i));
    final received = <WireStream>[];
    final server = OnlineBridgeServer(
      secret: secret,
      handlers: OnlineBridgeHandlers(stream: received.add),
    );
    await server.start();
    addTearDown(server.stop);
    final engine = (await FakeEngine.connect(server.port, secret))!;
    addTearDown(engine.close);
    engine
      ..sendStream(WireStream.open(stream: 1, peer: b, peerPort: 3659, peerVport: 1, localPort: 3660, localVport: 0))
      ..sendStream(WireStream.data(1, utf8.encode('hi')));
    expect(await eventually(() => received.length == 2), isTrue);
    expect(received, [
      WireStream.open(stream: 1, peer: b, peerPort: 3659, peerVport: 1, localPort: 3660, localVport: 0),
      WireStream.data(1, utf8.encode('hi')),
    ]);
    expect(await eventually(() => server.engine != null), isTrue);
    expect(server.deliverStream(WireStream.accept(1)), isTrue);
    expect(await engine.nextStream(), WireStream.accept(1));
    expect(
      server.deliverStream(WireStream.data(1, Uint8List(OnlineWire.maxStreamData + 1))),
      isFalse,
      reason: 'stream data over 64 KiB is refused',
    );
  });
}
