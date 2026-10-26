import 'dart:convert';

import 'package:anyps5_desktop/core/online/online_identity.dart';
import 'package:anyps5_desktop/core/online/online_user_profile.dart';
import 'package:anyps5_desktop/core/online/online_web_router.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:test/test.dart';

import '../../support/online_fakes.dart';

const me = TogetherUser(
  id: '0190a0b1-0000-7000-8000-00000000000a',
  handle: 'alice.the.great.player',
  displayName: 'Alice',
);
const game = OnlineGame(titleId: 'PPSA00000', gameVersion: '01.000', engineBuild: 'unknown');
const sessionId = '0190a0b1-0000-7000-8000-000000000001';

WireWebRequest get(String group, String path, {String method = 'GET', String body = ''}) =>
    WireWebRequest(userId: 1, apiGroup: group, path: path, method: method, body: utf8.encode(body));

Map<String, dynamic> json(WireWebReply reply) => reply.json! as Map<String, dynamic>;

void main() {
  test('the anyps5 group maps onto AnyTogether\'s game sessions for the running game', () async {
    final together = FakeOnlineTogether(
      answer: FakeOnlineTogether.sessionJson(id: sessionId, players: ['a-id', 'b-id']),
    );
    final changes = <String>[];
    final router = OnlineWebRouter(
      call: together.call,
      game: game,
      sessionChanged: (view) => changes.add(view?.id ?? 'none'),
    )..setEngineBuild('engine-test');

    final opened = await router.handle(
      get('anyps5', '/v1/sessions', method: 'POST', body: '{"capacity":4,"titleId":"OTHER"}'),
    );
    expect(opened.status, 201);
    expect(opened.headers, const [WirePair('Content-Type', 'application/json')]);
    final (method, path, body) = together.calls.last;
    expect((method, path), ('POST', 'game-sessions'));
    expect(body?['titleId'], 'PPSA00000', reason: 'the title is the running game\'s, whatever the game says');
    expect(body?['gameVersion'], '01.000');
    expect(body?['engineBuild'], 'engine-test');
    expect(body?['capacity'], 4);
    expect(changes, [sessionId]);
    expect(json(opened)['id'], sessionId, reason: 'AnyTogether\'s answer reaches the game as it is');

    await router.handle(get('anyps5', '/v1/sessions', method: 'POST'));
    expect(together.calls.last.$3?['capacity'], 2, reason: 'two players unless the game says otherwise');

    final joined = await router.handle(get('anyps5', '/v1/sessions/$sessionId/join', method: 'POST'));
    expect(joined.status, 200);
    expect(together.calls.last.$2, 'game-sessions/$sessionId/join');
    expect(together.calls.last.$3?['engineBuild'], 'engine-test');

    expect((await router.handle(get('anyps5', '/v1/sessions/$sessionId'))).status, 200);
    expect(together.calls.last.$1, 'GET');
    expect(
      (await router.handle(get('anyps5', '/v1/sessions/$sessionId', method: 'PATCH', body: '{"joinable":false}')))
          .status,
      200,
    );
    expect(together.calls.last.$3, {'joinable': false});

    final invites = await router.handle(
      get('anyps5', '/v1/sessions/$sessionId/invites', method: 'POST', body: '{"userIds":["b-id"]}'),
    );
    expect(invites.status, 200);
    expect(together.calls.last.$3?['userIds'], ['b-id']);
    await router.handle(get('anyps5', '/v1/me/session'));
    expect(together.calls.last.$2, 'me/game-session');

    final left = await router.handle(get('anyps5', '/v1/sessions/$sessionId/leave', method: 'POST'));
    expect(left.status, 204);
    expect(changes.last, 'none', reason: 'leaving tells online play');

    final before = together.calls.length;
    final escaped = await router.handle(get('anyps5', '/v1/sessions/..%2Fadmin/join', method: 'POST'));
    expect(escaped.status, 404, reason: 'a session ID that is not one never reaches AnyTogether');
    expect((await router.handle(get('anyps5', '/v1/nothing'))).status, 404);
    expect((await router.handle(get('anyps5', '/v1/sessions', method: 'POST', body: '[1]'))).status, 400);
    expect(together.calls.length, before);

    final platform = await router.handle(get('matchmaking', '/v1/tickets?x=1', method: 'POST', body: '{}'));
    expect(platform, WireWebReply.notOffered, reason: 'platform groups are not offered until their formats are known');
    await router.handle(get('matchmaking', '/v1/tickets', method: 'POST'));
    expect(router.notOffered['matchmaking POST /v1/tickets'], 2);
    final signedOut = await router.handle(get('sessionManager', '/v1/playerSessions', method: 'POST'));
    expect(signedOut, WireWebReply.notOffered, reason: 'signed out there are no Player Sessions');
    expect(together.calls.length, before, reason: 'nothing of a platform group goes anywhere');

    together.failure = const TogetherProblem(409, 'version_mismatch', 'This game needs version 1.02');
    final mismatch = await router.handle(get('anyps5', '/v1/sessions/$sessionId/join', method: 'POST'));
    expect(mismatch.status, 409);
    expect(mismatch.headers.single.value, 'application/problem+json');
    expect(json(mismatch)['code'], 'version_mismatch', reason: 'AnyTogether\'s refusal reaches the game as a problem');
    together.failure = null;
    final broken = OnlineWebRouter(call: (method, path, [body]) async => throw StateError('offline'), game: game);
    expect((await broken.handle(get('anyps5', '/v1/me/session'))).status, 502);
  });

  test('friends, profiles and presence come from AnyTogether', () async {
    final together = FakeOnlineTogether(
      friends: [('b-id', 'bob', 'online'), ('c-id', 'carol', 'offline'), ('d-id', 'dave', 'in_game')],
    );
    var now = DateTime.utc(2027, 1, 15);
    final profile = OnlineUserProfile(call: together.call, me: me, language: 'en', now: () => now);
    final router = OnlineWebRouter(call: together.call, game: game, profile: profile);
    final mine = OnlineIdentity.account(me.id);
    final bob = OnlineIdentity.account('b-id');
    final carol = OnlineIdentity.account('c-id');
    int friendCalls() => together.calls.where((call) => call.$2 == 'me/friends').length;

    // As Minecraft Dungeons II asks: the game's local user and an empty query.
    final friends = await router.handle(get('userProfile', '/v1/users/local_268435456/friends?'));
    expect(friends.status, 200);
    expect(friends.headers, const [WirePair('Content-Type', 'application/json')]);
    expect(json(friends)['friends'], [bob, carol, OnlineIdentity.account('d-id')]);
    expect(json(friends)['totalItemCount'], 3);
    expect(json(friends).containsKey('nextOffset'), isFalse);
    expect(
      utf8.decode(friends.body),
      startsWith('{"friends":'),
      reason: 'keys sorted, as the Mac launcher writes them',
    );

    final page = json(await router.handle(get('userProfile', '/v1/users/me/friends?offset=1&limit=1')));
    expect(page['friends'], [carol]);
    expect(page['nextOffset'], 2);
    expect(page['previousOffset'], 0);
    expect(
      (await router.handle(get('userProfile', '/v1/users/$mine/friends'))).status,
      200,
      reason: 'our own number is us',
    );
    expect(friendCalls(), 1, reason: 'games poll; AnyTogether is asked at most every 30 s');
    now = now.add(const Duration(seconds: 31));
    await router.handle(get('userProfile', '/v1/users/me/friends'));
    expect(friendCalls(), 2);

    expect(
      (await router.handle(get('userProfile', '/v1/users/$bob/friends'))).status,
      403,
      reason: 'only our own friends',
    );

    final shown = json(await router.handle(get('userProfile', '/v1/users/$bob/profiles')));
    expect(shown['onlineId'], 'bob');
    expect(shown['isMe'], false);
    expect(shown['languages'], <String>[]);
    final own = json(await router.handle(get('userProfile', '/v1/users/me/profiles')));
    expect(own['onlineId'], 'alice.the.great.');
    expect(own['isMe'], true);
    expect(own['languages'], ['en']);
    expect(own['isPlus'], false);
    expect(
      (await router.handle(get('userProfile', '/v1/users/12345/profiles'))).status,
      404,
      reason: 'strangers are not shown',
    );

    final presences = json(
      await router.handle(get('userProfile', '/v1/users/basicPresences?type=primary&accountIds=$bob,$carol,999')),
    );
    final found = presences['basicPresences'] as List<dynamic>;
    expect([for (final entry in found) entry['accountId']], [bob, carol]);
    expect([for (final entry in found) entry['availability']], ['availableToPlay', 'unavailable']);
    expect(found.first['primaryPlatformInfo'], {'onlineStatus': 'online', 'platform': 'PS5'});
    final single = json(await router.handle(get('userProfile', '/v1/users/$carol/basicPresences?type=primary')));
    expect((single['basicPresence'] as Map)['primaryPlatformInfo'], {'onlineStatus': 'offline'});
    final mineNow = json(await router.handle(get('userProfile', '/v1/users/me/basicPresences')));
    expect((mineNow['basicPresence'] as Map)['accountId'], mine);

    expect((await router.handle(get('userProfile', '/v1/users/me/friends', method: 'POST'))).status, 405);
    expect((await router.handle(get('userProfile', '/v1/users/me/other'))).status, 404);
    final error = json(await router.handle(get('userProfile', '/v2/x')));
    expect(error['error'], {'code': 404, 'message': 'No such userProfile call'});

    final quiet = OnlineWebRouter(call: together.call, game: game, profile: profile, platformGroups: false);
    expect(await quiet.handle(get('userProfile', '/v1/users/me/friends')), WireWebReply.notOffered);
    expect(quiet.notOffered['userProfile GET /v1/users/me/friends'], 1);
    final signedOut = OnlineWebRouter(call: together.call, game: game);
    expect(await signedOut.handle(get('userProfile', '/v1/users/me/friends')), WireWebReply.notOffered);

    together.failure = const TogetherProblem(401, 'unauthorized', 'Not signed in');
    now = now.add(const Duration(minutes: 5));
    expect((await router.handle(get('userProfile', '/v1/users/me/friends'))).status, 401);
  });

  test('nobody is blocked or restricted', () async {
    // As Human Fall Flat (PPSA02429) asks before it lists online games.
    final together = FakeOnlineTogether(friends: [('b-id', 'bob', 'online')]);
    final profile = OnlineUserProfile(call: together.call, me: me, language: 'en');
    final router = OnlineWebRouter(
      call: together.call,
      game: const OnlineGame(titleId: 'PPSA02429', gameVersion: '01.017', engineBuild: 'x'),
      profile: profile,
    );
    final mine = OnlineIdentity.account(me.id);
    final bob = OnlineIdentity.account('b-id');

    final blocks = await router.handle(get('userProfile', '/v1/users/me/blocks?offset=0&limit=0'));
    expect(blocks.status, 200);
    expect(json(blocks), {'blocks': <String>[], 'totalItemCount': 0});
    expect((await router.handle(get('userProfile', '/v1/users/$bob/blocks'))).status, 403);

    final status = await router.handle(
      get('communicationRestrictionStatus', '/v3/users/$mine/communication/restriction/status'),
    );
    expect(status.status, 200);
    expect(status.headers, const [WirePair('Content-Type', 'application/json')]);
    expect(json(status), {'restricted': false});
    final local = await router.handle(
      get('communicationRestrictionStatus', '/v3/users/local_268435456/communication/restriction/status'),
    );
    expect(local.status, 200);
    expect(
      (await router.handle(get('communicationRestrictionStatus', '/v3/users/$bob/communication/restriction/status')))
          .status,
      403,
    );
    expect((await router.handle(get('communicationRestrictionStatus', '/v3/users/me/other'))).status, 404);
    expect(
      (await router.handle(
        get('communicationRestrictionStatus', '/v3/users/me/communication/restriction/status', method: 'PUT'),
      )).status,
      405,
    );
    expect(together.calls, isEmpty, reason: 'neither answer needs AnyTogether');

    final quiet = OnlineWebRouter(call: together.call, game: game, profile: profile, platformGroups: false);
    expect(
      await quiet.handle(get('communicationRestrictionStatus', '/v3/users/me/communication/restriction/status')),
      WireWebReply.notOffered,
    );
  });

  test('a session as AnyTogether shows it', () {
    final view = OnlineSessionView.fromJson(
      FakeOnlineTogether.sessionJson(
        id: sessionId,
        players: [me.id, 'b-id', 'c-id'],
        devices: {me.id: 'dev-a', 'b-id': 'dev-b'},
      ),
    )!;
    expect(view.players, [me.id, 'b-id', 'c-id']);
    expect(view.devices, {me.id: 'dev-a', 'b-id': 'dev-b'}, reason: 'a player who has not published has no device');
    expect(view.ended, isFalse);
    expect(view.addresses, OnlineIdentity.addresses([me.id, 'b-id', 'c-id']));
    expect(OnlineSessionView.fromJson({'id': 1}), isNull);
    expect(
      OnlineSessionView.fromJson({
        ...FakeOnlineTogether.sessionJson(id: 's', players: ['x']),
        'endedAt': 'x',
      })!.ended,
      isTrue,
    );
  });
}
