import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_identity.dart';
import 'package:anyps5_desktop/core/online/online_peer.dart';
import 'package:anyps5_desktop/core/online/online_play.dart';
import 'package:anyps5_desktop/core/online/online_web_router.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/online_fakes.dart';

const me = TogetherUser(
  id: '0190a0b1-0000-7000-8000-00000000000a',
  handle: 'alice.the.great.player',
  displayName: 'Alice',
);
const game = OnlineGame(titleId: 'PPSA00000', gameVersion: '01.000', engineBuild: 'x');
const sessionId = '0190a0b1-0000-7000-8000-000000000001';

/// A transport that only remembers what it was told.
class RecordingTransport implements OnlinePeerTransport {
  final updates = <OnlinePeerSession?>[];
  final received = <OnlinePeerSignal>[];
  final sent = <WireDatagram>[];
  bool stopped = false;

  @override
  void update(OnlinePeerSession? session) => updates.add(session);

  @override
  bool send(WireDatagram datagram) {
    sent.add(datagram);
    return false;
  }

  @override
  bool sendStream(int peer, Uint8List message) => false;

  @override
  void receive(OnlinePeerSignal signal) => received.add(signal);

  @override
  void stop() => stopped = true;
}

void main() {
  test('identity is the same everywhere (the Mac launcher\'s numbers) and never moves anyone', () {
    expect(OnlineIdentity.accountId('a-id'), OnlineIdentity.accountId('a-id'));
    expect(OnlineIdentity.accountId('a-id'), isNot(OnlineIdentity.accountId('b-id')));
    expect(OnlineIdentity.accountId('a-id'), 0xE222F8A6FD35326F, reason: 'the first 8 bytes of SHA-256 of the user ID');
    expect(OnlineIdentity.account('0190a0b1-0000-7000-8000-00000000000a'), '2102834801040986882');
    expect(OnlineIdentity.onlineId(me.handle), 'alice.the.great.', reason: 'cut to the platform\'s 16 letters');
    expect(OnlineIdentity.onlineId(''), 'player');
    // Worked out by the Mac launcher's OnlineIdentity for the same IDs.
    expect(
      OnlineIdentity.addresses([
        '0190a0b1-0000-7000-8000-00000000000a',
        '0190a0b1-0000-7000-8000-00000000000b',
        'a-id',
        'b-id',
      ]),
      {
        '0190a0b1-0000-7000-8000-00000000000a': 0xc61204e0,
        '0190a0b1-0000-7000-8000-00000000000b': 0xc612bc8e,
        'a-id': 0xc6139530,
        'b-id': 0xc61288af,
      },
    );

    final users = [for (var index = 0; index < 16; index++) 'user-$index'];
    final all = OnlineIdentity.addresses(users);
    expect(all.values.toSet(), hasLength(16), reason: 'everyone gets their own address');
    for (final address in all.values) {
      expect(OnlineWire.isVirtual(address), isTrue);
      expect(address & 0xFF, isNot(0));
      expect(address & 0xFF, isNot(0xFF));
    }
    final fewer = OnlineIdentity.addresses(users.skip(3).toList().reversed);
    for (final entry in fewer.entries) {
      expect(all[entry.key], entry.value, reason: 'leaving or join order moves nobody');
    }
    expect(OnlineIdentity.dotted(0xC6120002), '198.18.0.2');
    expect(OnlineIdentity.before('a', 'b'), isTrue);
    expect(OnlineIdentity.before('b', 'a'), isFalse);
  });

  test('the account a game sees, with the computer\'s country and language', () {
    final account = OnlinePlay.account(me, country: 'TR', language: 'tr');
    expect(account.signedIn, isTrue);
    expect(account.accountId, OnlineIdentity.accountId(me.id));
    expect(account.onlineId, 'alice.the.great.');
    expect(account.country, 'tr');
    expect(OnlinePlay.locale('tr_TR.UTF-8'), (country: 'tr', language: 'tr'));
    expect(OnlinePlay.locale('en-US'), (country: 'us', language: 'en'));
    expect(OnlinePlay.locale('C'), (country: '', language: ''));
    expect(OnlinePlay.locale('de'), (country: '', language: 'de'));
  });

  test('following a session publishes the launcher and hands the players to the transport', () async {
    final together = FakeOnlineTogether(
      session: FakeOnlineTogether.sessionJson(
        id: sessionId,
        players: [me.id, 'b-id', 'c-id'],
        devices: {me.id: 'dev-a', 'b-id': 'dev-b'},
      ),
    );
    final transport = RecordingTransport();
    final play = OnlinePlay(call: together.call, user: me, game: game, transport: (_) => transport);
    final environment = await play.start();
    addTearDown(play.stop);
    final engine = (await FakeEngine.fromEnvironment(environment))!;
    addTearDown(engine.close);
    expect(engine.account?.accountId, OnlineIdentity.accountId(me.id));
    expect(engine.account?.address, 0, reason: 'no virtual address before a session');

    await play.follow(sessionId);
    final (method, path, body) = together.calls.first;
    expect((method, path), ('PUT', 'game-sessions/$sessionId/members/me'), reason: 'the others\' signals reach it');
    expect(body, {
      'properties': {'online': 1},
    });
    final addresses = OnlineIdentity.addresses([me.id, 'b-id', 'c-id']);
    final session = transport.updates.last!;
    expect(session.id, sessionId);
    expect(session.me, me.id);
    expect(session.addresses, addresses);
    expect(session.devices, {
      me.id: 'dev-a',
      'b-id': 'dev-b',
    }, reason: 'a player who has not published yet has no device');
    expect(await engine.addressSoon(addresses[me.id]!), isTrue, reason: 'the game learns its own virtual address');
    expect(play.currentSession?.id, sessionId);

    play.receive(const OnlinePeerSignal(from: 'b-id', device: 'dev-b', kind: 'offer', data: {}), 'another');
    expect(transport.received, isEmpty, reason: 'a signal for another session is dropped');
    const signal = OnlinePeerSignal(
      from: 'b-id',
      device: 'dev-b',
      kind: 'offer',
      data: {'type': 'offer', 'sdp': 'v=0'},
    );
    play.receive(signal, sessionId);
    expect(transport.received, [signal]);

    // The game's packets go to the transport.
    engine.send(
      WireDatagram(
        peer: addresses['b-id']!,
        peerPort: 1,
        peerVport: 0,
        localPort: 2,
        localVport: 0,
        kind: DatagramKind.udp,
        data: [1],
      ),
    );
    expect(await eventually(() => transport.sent.length == 1), isTrue);

    // News of the session reads it again.
    together.calls.clear();
    await play.refresh();
    expect(together.calls.single.$2, 'game-sessions/$sessionId');

    await play.follow(null);
    expect(transport.updates.last, isNull, reason: 'leaving the session tells the transport');
    expect(await engine.addressSoon(0), isTrue);
    await play.stop();
    expect(transport.stopped, isTrue);
  });

  test('the host follows the launcher\'s session and its socket events', () async {
    final together = FakeOnlineTogether(
      session: FakeOnlineTogether.sessionJson(
        id: sessionId,
        players: [me.id, 'b-id'],
        devices: {me.id: 'dev-a', 'b-id': 'dev-b'},
      ),
    );
    final folder = Directory.systemTemp.createTempSync('online-host');
    addTearDown(() => folder.deleteSync(recursive: true));
    final transport = RecordingTransport();
    final host = OnlineHost(
      logFolder: folder.path,
      call: together.call,
      user: () => me,
      signal: (_, _, _, _, _) {},
      transport: (_) => transport,
      locale: 'tr_TR.UTF-8',
    );
    host.follow(sessionId);
    final environment = await host.environment(titleId: 'PPSA01234', gameVersion: '', engineBuild: 'arm-abc');
    expect(environment['ANYPS5_ONLINE'], startsWith('127.0.0.1:'));
    expect(environment['ANYPS5_ONLINE_SECRET'], hasLength(64));
    expect(
      environment['ANYPS5_ONLINE_LOG'],
      p.join(folder.path, 'PPSA01234.jsonl'),
      reason: 'the engine writes the title\'s log',
    );
    final play = host.running!;
    expect(play.router.game.gameVersion, '0');
    expect(play.baseAccount.country, 'tr');
    expect(play.baseAccount.language, 'tr');
    final engine = (await FakeEngine.fromEnvironment(environment, build: 'engine-build-7'))!;
    addTearDown(engine.close);
    expect(
      await eventually(() => play.router.game.engineBuild == 'engine-build-7'),
      isTrue,
      reason: 'the engine says its build',
    );
    expect(await eventually(() => transport.updates.isNotEmpty && transport.updates.last != null), isTrue);

    host.handle(
      const TogetherEvent('1', 'game_session.signal', {
        'sessionId': sessionId,
        'from': 'b-id',
        'device': 'dev-b',
        'kind': 'candidate',
        'data': {'candidate': 'candidate:1 1 udp 1 10.0.0.2 5000 typ host', 'sdpMid': '0', 'sdpMLineIndex': 0},
      }),
    );
    expect(transport.received.single.kind, 'candidate');
    expect((transport.received.single.data as Map)['sdpMid'], '0');
    host.handle(const TogetherEvent('2', 'game_session.signal', {'from': 'b-id'}));
    expect(transport.received, hasLength(1), reason: 'not a signal');
    final before = together.calls.length;
    host.handle(const TogetherEvent('3', 'game_session.updated', {}));
    expect(
      await eventually(() => together.calls.length > before),
      isTrue,
      reason: 'news of the session reads it again',
    );

    host.follow(null);
    expect(await eventually(() => transport.updates.last == null), isTrue);
    await host.stop();
    expect(host.running, isNull);
    expect(transport.stopped, isTrue);
  });

  test('signals go out as the gateway wants them', () {
    final frame = OnlinePeerSignal.frame(
      to: 'b-id',
      device: 'dev-b',
      sessionId: 's1',
      kind: 'offer',
      data: {'type': 'offer', 'sdp': 'v=0'},
    );
    expect(frame, {
      'op': 'signal',
      'to': 'b-id',
      'device': 'dev-b',
      'session': 's1',
      'kind': 'offer',
      'data': {'type': 'offer', 'sdp': 'v=0'},
    });
    expect(OnlinePeerSignal.frame(to: 'b', device: 'd', sessionId: 's', kind: 'bye')['data'], isNull);
    expect(OnlinePeerSignal.fromEvent({'from': 'b-id'}), isNull);
  });

  test('each title has its observation log, a big one is kept aside, and its last lines are read', () {
    final folder = Directory.systemTemp.createTempSync('online-logs');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = OnlineHost.observationLog('PPSA01234', folder.path);
    expect(p.basename(file), 'PPSA01234.jsonl');
    expect(
      p.basename(OnlineHost.observationLog('../x', folder.path)),
      '___x.jsonl',
      reason: 'a title ID never leaves the folder',
    );
    expect(p.basename(OnlineHost.observationLog('', folder.path)), 'game.jsonl');
    File(file).writeAsBytesSync(List.filled(20 * 1024 * 1024 + 1, 0x20));
    OnlineHost.observationLog('PPSA01234', folder.path);
    expect(File(file).existsSync(), isFalse);
    expect(File('$file.1').existsSync(), isTrue);

    File(file).writeAsStringSync([for (var index = 0; index < 50; index++) '{"n":$index}'].join('\n'));
    expect(OnlineHost.lastLines(file, 3), ['{"n":47}', '{"n":48}', '{"n":49}']);
    expect(OnlineHost.lastLines(file, 3, maxBytes: 20), [
      '{"n":48}',
      '{"n":49}',
    ], reason: 'a cut first line is not shown');
    expect(OnlineHost.lastLines(p.join(folder.path, 'none.jsonl'), 3), isEmpty);
  });

  test('observation lines from the game are kept, the newest 2000', () async {
    final play = OnlinePlay(call: FakeOnlineTogether().call, user: null, game: game);
    final environment = await play.start();
    addTearDown(play.stop);
    expect(
      environment.containsKey('ANYPS5_ONLINE_LOG'),
      isFalse,
      reason: 'no observation log unless one was asked for',
    );
    final engine = (await FakeEngine.fromEnvironment(environment))!;
    addTearDown(engine.close);
    expect(engine.account, WireAccount.signedOut, reason: 'signed out, the game sees nobody');
    for (var index = 0; index < 2005; index++) {
      engine.observe('{"n":$index}');
    }
    expect(await eventually(() => play.observed.lastOrNull == '{"n":2004}'), isTrue);
    expect(play.observed, hasLength(OnlinePlay.keptLines));
    expect(play.observed.first, '{"n":5}');
    final friends = await engine.web(
      WireWebRequest(userId: 1, apiGroup: 'userProfile', path: '/v1/users/me/friends', method: 'GET'),
    );
    expect(friends, WireWebReply.notOffered, reason: 'signed out there are no friends to offer');
  });
}
