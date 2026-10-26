import 'dart:convert';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:test/test.dart';

/// The reference bytes the engine's test (core/libs/prx/libSceNetCtl/tests/OnlineBridge.cpp) and
/// the Mac launcher's (OnlineBridgeTests.testWireMatchesTheEngineByteForByte) check: the same
/// frames, fields and proofs here, byte for byte.
void main() {
  final secret = Uint8List.fromList(List.generate(32, (i) => i));
  final engineNonce = Uint8List.fromList(List.generate(16, (i) => 0x10 + i));
  final launcherNonce = Uint8List.fromList(List.generate(16, (i) => 0x20 + i));

  test('the header is the engine\'s, and a payload over 16 MiB is refused', () {
    const header = WireHeader(length: 0x00020304, kind: 0x0201, flags: OnlineWire.flagReply, call: 0xA0B0C0D0);
    expect(
      OnlineWire.hex(header.bytes),
      '040302000102'
      '0100'
      'd0c0b0a0',
    );
    expect(WireHeader.parse(header.bytes), header);
    expect(
      WireHeader.parse(const WireHeader(length: OnlineWire.maxPayload + 1, kind: 1, flags: 0, call: 0).bytes),
      isNull,
    );
    expect(WireHeader.parse(Uint8List(11)), isNull, reason: 'twelve bytes or nothing');
  });

  test('fields are packed in order, little-endian', () {
    final writer = WireWriter()
      ..u8(1)
      ..u16(0x0203)
      ..u32(0x04050607)
      ..u64(0x08090A0B0C0D0E0F)
      ..str('hi')
      ..bytes(Uint8List.fromList([9, 8]))
      ..pairs(const [WirePair('a', 'b')]);
    expect(
      OnlineWire.hex(writer.data),
      '01030207060504'
      '0f0e0d0c0b0a0908'
      '02006869'
      '020000000908'
      '0100'
      '010061'
      '010062',
    );
    final reader = WireReader(writer.data);
    expect(reader.u8(), 1);
    expect(reader.u16(), 0x0203);
    expect(reader.u32(), 0x04050607);
    expect(reader.u64(), 0x08090A0B0C0D0E0F);
    expect(reader.str(), 'hi');
    expect(reader.bytes(), [9, 8]);
    expect(reader.pairs(), const [WirePair('a', 'b')]);
    expect(reader.ok, isTrue);
    expect(reader.u8(), 0);
    expect(reader.ok, isFalse, reason: 'reading past the end fails the reader');
  });

  test('a u64 above 2^63 keeps its bits', () {
    final writer = WireWriter()..u64(0xE222F8A6FD35326F);
    expect(OnlineWire.hex(writer.data), '6f3235fda6f822e2');
    expect(WireReader(writer.data).u64(), 0xE222F8A6FD35326F);
    expect(OnlineWire.unsigned(0xE222F8A6FD35326F), '16294859797876257391');
  });

  test('a datagram is the engine\'s, and one outside the virtual network is refused', () {
    final datagram = WireDatagram(
      peer: 0xC6120002,
      peerPort: 3658,
      peerVport: 1,
      localPort: 3658,
      localVport: 2,
      kind: DatagramKind.p2p,
      data: Uint8List.fromList([1, 2, 3]),
    );
    expect(
      OnlineWire.hex(datagram.payload),
      '020012c6'
      '4a0e'
      '0100'
      '4a0e'
      '0200'
      '02'
      '03000000'
      '010203',
    );
    expect(WireDatagram.parse(datagram.payload), datagram);
    expect(WireDatagram.parse(datagram.copyWith(peer: 0x0A000001).payload), isNull);
    expect(
      WireDatagram.parse(datagram.copyWith(peer: 0xFFFFFFFF).payload),
      isNotNull,
      reason: 'a broadcast is carried',
    );
    final badKind = datagram.payload..[12] = 9;
    expect(WireDatagram.parse(badKind), isNull);
  });

  test('a push event is the engine\'s (online_bridge "push events")', () {
    final push = WirePushEvent(
      service: 'sm',
      label: 1,
      pushContextId: 'c',
      dataType: 't:x',
      data: utf8.encode('{}'),
      extended: const [WirePair('k', 'v')],
      to: 2,
      from: 3,
      fromOnlineId: 'b',
    );
    expect(
      OnlineWire.hex(push.payload),
      '0200736d'
      '01000000'
      '010063'
      '0300743a78'
      '020000007b7d'
      '0100'
      '01006b'
      '010076'
      '0200000000000000'
      '0300000000000000'
      '010062',
    );
    expect(WirePushEvent.parse(push.payload), push);
    expect(WirePushEvent.parse(push.copyWith(dataType: '').payload), isNull, reason: 'a push event needs a data type');
    expect(push.copyWith(extended: [WirePair('k' * 33, 'v')]).isValid, isFalse, reason: 'keys hold 32 letters');
    expect(push.copyWith(fromOnlineId: 'x' * 17).isValid, isFalse);
    expect(push.copyWith(pushContextId: 'x' * 37).isValid, isFalse);
  });

  test('the other messages round-trip', () {
    final hello = WireHello(nonce: engineNonce, build: 'engine-test', pid: 77);
    expect(OnlineWire.hex(hello.payload).substring(0, 4), '0100');
    expect(WireHello.parse(hello.payload), hello);
    expect(WireHello.parse(Uint8List(10)), isNull);
    const account = WireAccount(
      signedIn: true,
      accountId: 42,
      onlineId: 'alice',
      country: 'tr',
      language: 'tr',
      address: 0xC6120001,
    );
    expect(
      OnlineWire.hex(account.payload),
      '01'
      '2a00000000000000'
      '0500616c696365'
      '02007472'
      '02007472'
      '00'
      '010012c6'
      '00',
    );
    expect(WireAccount.parse(account.payload), account);
    final request = WireWebRequest(
      userId: 0x10000000,
      apiGroup: 'g',
      path: '/p?x=1',
      method: 'GET',
      headers: const [WirePair('A', 'b')],
      body: utf8.encode('b'),
    );
    expect(WireWebRequest.parse(request.payload), request);
    final reply = WireWebReply(status: 200, headers: const [WirePair('X', 'y')], body: utf8.encode('ok'));
    expect(WireWebReply.parse(reply.payload), reply);
    expect(
      OnlineWire.hex(WireWebReply.notOffered.payload),
      '0000'
      '0000'
      '00000000',
    );
    expect(
      OnlineWire.hex(OnlineWire.refuse(RefuseReason.badProof, 'x')),
      '0100'
      '010078',
    );
  });

  test('the proofs are the engine\'s reference values', () {
    expect(
      OnlineWire.hex(OnlineWire.proof(secret, Side.launcher, engineNonce, launcherNonce)),
      '2f21186674e36ff3b7a3c64d49553ec40d66baf6fb0700e734cc6f09e6af4ab1',
    );
    expect(
      OnlineWire.hex(OnlineWire.proof(secret, Side.engine, engineNonce, launcherNonce)),
      '01c14bd9997ca8a60d1c14d1002ad65161b53ba7499fe653d2f73bc4b6641a4d',
    );
    final proof = OnlineWire.proof(secret, Side.engine, engineNonce, launcherNonce);
    expect(OnlineWire.sameProof(proof, Uint8List.fromList(proof)), isTrue);
    expect(OnlineWire.sameProof(proof, Uint8List.fromList(proof)..[31] ^= 1), isFalse);
    expect(OnlineWire.sameProof(proof, proof.sublist(0, 31)), isFalse);
  });

  test('the virtual network and its groups', () {
    expect(OnlineWire.isVirtual(0xC613FFFF), isTrue);
    expect(OnlineWire.isVirtual(0xC6140000), isFalse);
    expect(OnlineWire.virtualBroadcast, 0xC613FFFF);
    expect(OnlineWire.isGroup(0xFFFFFFFF), isTrue);
    expect(OnlineWire.isGroup(0xC613FFFF), isTrue);
    expect(OnlineWire.isGroup(0xE00000FB), isTrue);
    expect(OnlineWire.isGroup(0xC6120002), isFalse);
    expect(OnlineWire.maxGameDatagram, 65495);
    expect(OnlineWire.randomBytes(16), hasLength(16));
    expect(OnlineWire.fromHex(OnlineWire.hex(secret)), secret);
    expect(OnlineWire.fromHex('zz'), isNull);
  });
}
