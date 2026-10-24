import 'dart:async';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/friends.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

void main() {
  late FakeTogether server;
  late TogetherAccount account;
  late TogetherSocket socket;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    server = await FakeTogether.start();
    account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0 (Linux)');
    await account.startEmail('utku@example.com');
    await account.verifyEmail('123456');
    socket = TogetherSocket(
      account: account,
      retryBase: const Duration(milliseconds: 10),
      retryMost: const Duration(milliseconds: 40),
    );
  });

  tearDown(() async {
    socket.dispose();
    account.close();
    await server.close();
  });

  test('says hello with the token and the client, then beats with the presence', () async {
    server.heartbeatSeconds = 1;
    final events = <String>[];
    socket.events.listen((event) => events.add(event.type));
    socket.start();
    final hello = await server.nextFrame('hello');
    expect(hello['token'], startsWith('access-'));
    expect(hello['client'], 'launcher-linux/0.1.0 (Linux)');
    expect(hello.containsKey('resume'), isFalse);
    await until(() => socket.status == SocketStatus.ready);
    expect(socket.session, 'session-1');
    expect(events, ['live.ready']);
    expect((await server.nextFrame('heartbeat'))['presence'], {'state': 'online'});

    // In a game: at once, and with every beat after.
    socket.presence = PresenceInGame('PPSA01001', DateTime.utc(2026, 10, 24, 20));
    final playing = await server.nextFrame('heartbeat');
    expect(playing['presence'], {'state': 'in_game', 'titleId': 'PPSA01001', 'since': '2026-10-24T20:00:00.000Z'});
    final beat = await server.nextFrame('heartbeat');
    expect((beat['presence'] as Map)['state'], 'in_game');
  });

  test('events go on; after a drop it comes back and resumes after the last one it had', () async {
    final events = <TogetherEvent>[];
    socket.events.listen(events.add);
    socket.start();
    await server.nextFrame('hello');
    await until(() => socket.status == SocketStatus.ready);
    const id = '01920000-0000-7000-8000-000000000001';
    server.push('friend.removed', {'userId': 'u-ana'}, id: id);
    server.push('presence.updated', {'userId': 'u-ana', 'state': 'online'}, id: 'presence-1');
    await until(() => events.length == 3);
    expect(events[1].json['userId'], 'u-ana');
    await server.dropSockets();
    final again = await server.nextFrame('hello');
    expect(again['resume'], id, reason: 'presence events are never replayed');
    await until(() => socket.status == SocketStatus.ready);
  });

  test('a refused token is renewed; a session signed out elsewhere ends here', () async {
    socket.start();
    await server.nextFrame('hello');
    await until(() => socket.status == SocketStatus.ready);
    final refreshes = server.callsTo('auth/token').length;
    await server.dropSockets(TogetherSocket.unauthorized);
    await server.nextFrame('hello');
    expect(server.callsTo('auth/token').length, refreshes + 1);
    await until(() => socket.status == SocketStatus.ready);

    await server.dropSockets(TogetherSocket.signedOut);
    await until(() => socket.status == SocketStatus.signedOut);
    expect(account.user, isNull);
  });

  test('friends: loaded when the socket is ready, live presence and requests, asking and answering', () async {
    server
      ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
      ..friend(
        'u-bora',
        'bora',
        'Bora',
        presence: {
          'state': 'in_game',
          'titleId': 'PPSA02002',
          'since': '2026-10-24T20:00:00Z',
          'party': {'id': 'p1', 'size': 2, 'max': 8, 'open': true},
          'game': {'sessionId': 's1', 'titleId': 'PPSA02002', 'joinable': true, 'players': 1, 'capacity': 4},
        },
      )
      ..friend('u-cem', 'cem', 'Cem')
      ..person('u-deniz', 'deniz', 'Deniz');
    final friends = Friends(account: account, socket: socket);
    final asked = <String>[];
    friends.onRequest = (person) => asked.add(person.handle);
    socket.start();
    await until(() => friends.loaded);
    expect(friends.friends.map((friend) => friend.person.handle), ['bora', 'ana', 'cem']);
    final bora = friends.friends.first.presence;
    expect(bora.playing, isTrue);
    expect(bora.party?.open, isTrue);
    expect(bora.game?.joinable, isTrue);
    expect(friends.online, 2);

    server.push('presence.updated', {'userId': 'u-cem', 'state': 'in_game', 'titleId': 'PPSA01001'});
    await until(() => friends.friends.first.person.handle == 'cem' || friends.byId('u-cem')!.presence.playing);
    expect(friends.byId('u-cem')!.presence.state, PresenceState.inGame);

    server.incoming.add(FakeTogether.card('u-eda', 'eda', 'Eda'));
    server.push('friend.request', FakeTogether.card('u-eda', 'eda', 'Eda'));
    await until(() => friends.incoming.isNotEmpty);
    expect(asked, ['eda']);
    await friends.answer('u-eda', accept: true);
    expect(friends.byId('u-eda'), isNotNull);

    expect(await friends.add(' @deniz '), isFalse);
    expect(server.callsTo('me/friends/requests', method: 'POST').single.body, {'handle': 'deniz'});
    expect(friends.outgoing.single.handle, 'deniz');
    await expectLater(friends.add('nobody'), throwsA(isA<TogetherProblem>()));

    await friends.remove('u-ana');
    expect(friends.byId('u-ana'), isNull);
    server.push('friend.removed', {'userId': 'u-cem'});
    await until(() => friends.byId('u-cem') == null);
    friends.dispose();
  });
}
