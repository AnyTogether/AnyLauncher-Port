import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_bridge_server.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:test/test.dart';

import '../../support/online_fakes.dart';

void main() {
  final secret = Uint8List.fromList(List.generate(32, (i) => i));
  const account = WireAccount(signedIn: true, accountId: 42, onlineId: 'alice', country: 'tr', language: 'tr');

  test('handshake, the account first, web requests and observation lines', () async {
    final observed = <String>[];
    final engines = <String?>[];
    final server = OnlineBridgeServer(
      secret: secret,
      account: account,
      handlers: OnlineBridgeHandlers(
        web: (request) async => WireWebReply(
          status: 200,
          headers: [WirePair('X-Path', request.path)],
          body: [...request.body, ...utf8.encode(request.apiGroup)],
        ),
        observation: observed.add,
        engine: (hello) => engines.add(hello?.build),
      ),
    );
    await server.start();
    addTearDown(server.stop);
    expect(server.port, greaterThan(0));
    expect(server.environment['ANYPS5_ONLINE'], '127.0.0.1:${server.port}');
    expect(server.environment['ANYPS5_ONLINE_SECRET'], OnlineWire.hex(secret));
    expect(server.environment['ANYPS5_ONLINE_SECRET'], hasLength(64));

    final engine = (await FakeEngine.connect(server.port, secret))!;
    addTearDown(engine.close);
    expect(engine.launcherProven, isTrue, reason: 'the launcher proves the secret');
    expect(engine.account, account, reason: 'the account is the first frame after the handshake');
    expect(await eventually(() => server.engine?.build == 'engine-test'), isTrue);
    expect(engines, ['engine-test']);

    final reply = (await engine.web(
      WireWebRequest(userId: 1, apiGroup: 'g', path: '/p?x=1', method: 'GET', body: utf8.encode('b')),
    ))!;
    expect(reply.status, 200);
    expect(utf8.decode(reply.body), 'bg');
    expect(reply.headers, const [WirePair('X-Path', '/p?x=1')]);

    engine.observe('{"fn":"sceNpGetState"}');
    expect(await eventually(() => observed.isNotEmpty), isTrue);
    expect(observed.single, '{"fn":"sceNpGetState"}');

    server.setAccount(const WireAccount(signedIn: true, accountId: 42, onlineId: 'alice2'));
    expect((await engine.nextAccount())?.onlineId, 'alice2', reason: 'account changes are pushed');

    engine.write(OnlineWire.frame(WireKind.account, Uint8List(0), call: 77));
    final unsupported = (await engine.readFrame())!;
    expect(unsupported.header.call, 77);
    expect(
      unsupported.header.flags,
      OnlineWire.flagReply | OnlineWire.flagUnsupported,
      reason: 'an unknown call is unsupported',
    );

    engine.write(OnlineWire.frame(WireKind.webRequest, Uint8List.fromList([1, 2]), call: 78));
    final malformed = (await engine.readFrame())!;
    expect(malformed.header.call, 78);
    expect(malformed.header.flags & OnlineWire.flagUnsupported, OnlineWire.flagUnsupported);

    engine.write(OnlineWire.frame(WireKind.of(0x0999) ?? WireKind.observation, Uint8List(0)));
    engine.write(const WireHeader(length: 0, kind: 0x0999, flags: 0, call: 0).bytes);
    final still = await engine.web(WireWebRequest(userId: 1, apiGroup: 'g', path: '/', method: 'GET'));
    expect(still?.status, 200, reason: 'an unknown event is skipped');

    await engine.close();
    expect(await eventually(() => server.engine == null), isTrue);
    expect(engines.last, isNull, reason: 'the engine going is told');
  });

  test('impostors and old engines are refused', () async {
    final server = OnlineBridgeServer(secret: secret);
    await server.start();
    addTearDown(server.stop);
    final wrong = (await FakeEngine.connect(server.port, List.filled(32, 7), expectRefusal: true))!;
    addTearDown(wrong.close);
    expect(wrong.launcherProven, isFalse, reason: 'an engine with another secret sees the launcher cannot prove it');
    expect(wrong.refusalReason, RefuseReason.badProof.value);
    expect(server.engine, isNull);
    final old = (await FakeEngine.connect(server.port, secret, protocolVersion: 9, expectRefusal: true))!;
    addTearDown(old.close);
    expect(old.refusalReason, RefuseReason.protocolVersion.value);
    expect(server.engine, isNull);

    // Silence or garbage instead of a hello is hung up on.
    final raw = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    raw.add(utf8.encode('GET / HTTP/1.1\r\n\r\n'));
    await raw.flush();
    expect(await raw.isEmpty.timeout(const Duration(seconds: 7)), isTrue);
    raw.destroy();
    expect(server.engine, isNull);
  });

  test('a reconnecting game replaces its old connection; packets and push events go both ways', () async {
    final datagrams = <WireDatagram>[];
    final server = OnlineBridgeServer(
      secret: secret,
      account: account,
      handlers: OnlineBridgeHandlers(datagram: datagrams.add),
    );
    await server.start();
    addTearDown(server.stop);
    expect(server.deliver(_datagram(0xC6120002, [1])), isFalse, reason: 'no game connected');
    final first = (await FakeEngine.connect(server.port, secret, build: 'first'))!;
    final second = (await FakeEngine.connect(server.port, secret, build: 'second'))!;
    addTearDown(first.close);
    addTearDown(second.close);
    expect(await eventually(() => server.engine?.build == 'second'), isTrue);
    expect(await first.readFrame(timeout: const Duration(seconds: 2)), isNull, reason: 'the old connection is closed');

    final big = Uint8List.fromList(List.generate(OnlineWire.maxDatagram, (i) => i & 0xFF));
    second.send(_datagram(0xC6120002, big));
    second.send(_datagram(0x0A000001, [9]));
    second.send(_datagram(0xFFFFFFFF, [7]));
    expect(await eventually(() => datagrams.length == 2), isTrue);
    expect(datagrams.first.data, big, reason: 'the largest datagram crosses whole');
    expect(datagrams.last.peer, 0xFFFFFFFF, reason: 'a broadcast is handed on; an address outside is not');

    expect(server.deliver(_datagram(0xC6120003, utf8.encode('hi'))), isTrue);
    final delivered = (await second.nextDatagram())!;
    expect(delivered.peer, 0xC6120003);
    expect(utf8.decode(delivered.data), 'hi');
    expect(server.deliver(_datagram(0xC6120003, Uint8List(OnlineWire.maxDatagram + 1))), isFalse);

    expect(server.push(WirePushEvent(service: 'sessionManager', dataType: 't:x', data: utf8.encode('{}'))), isTrue);
    expect((await second.nextPushEvent())?.dataType, 't:x');
    expect(server.push(WirePushEvent(service: 'sessionManager', dataType: '')), isFalse);
  });

  test('a frame announcing more than 16 MiB drops the connection', () async {
    final server = OnlineBridgeServer(secret: secret);
    await server.start();
    addTearDown(server.stop);
    final engine = (await FakeEngine.connect(server.port, secret))!;
    addTearDown(engine.close);
    expect(await eventually(() => server.engine != null), isTrue);
    engine.write(WireHeader(length: OnlineWire.maxPayload + 1, kind: WireKind.datagram.value, flags: 0, call: 0).bytes);
    expect(await eventually(() => server.engine == null), isTrue);
  });

  test('a stopped bridge lets the game go', () async {
    final server = OnlineBridgeServer(secret: secret);
    await server.start();
    final engine = (await FakeEngine.connect(server.port, secret))!;
    addTearDown(engine.close);
    await server.stop();
    expect(await engine.readFrame(timeout: const Duration(seconds: 2)), isNull);
    expect(server.engine, isNull);
  });

  test('frames split anywhere and run together are read the same', () async {
    final frames = <WireFrame>[];
    final controller = Stream<Uint8List>.fromIterable([
      for (final byte in [
        ...OnlineWire.frame(WireKind.observation, (WireWriter()..str('one')).data),
        ...OnlineWire.frame(WireKind.observation, (WireWriter()..str('two')).data),
      ])
        Uint8List.fromList([byte]),
    ]);
    final inbox = WireInbox(controller);
    frames.add((await inbox.next())!);
    frames.add((await inbox.next())!);
    expect(await inbox.next(), isNull);
    expect([for (final frame in frames) WireReader(frame.payload).str()], ['one', 'two']);
  });
}

WireDatagram _datagram(int peer, List<int> data) => WireDatagram(
  peer: peer,
  peerPort: 9000,
  peerVport: 0,
  localPort: 9001,
  localVport: 0,
  kind: DatagramKind.udp,
  data: data,
);
