import 'dart:convert';

import 'package:anyps5_desktop/core/online/online_identity.dart';
import 'package:anyps5_desktop/core/online/online_peer.dart';
import 'package:anyps5_desktop/core/online/online_play.dart';
import 'package:anyps5_desktop/core/online/online_player_sessions.dart';
import 'package:anyps5_desktop/core/online/online_web_router.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:test/test.dart';

import '../../support/online_fakes.dart';

const me = TogetherUser(id: '0190a0b1-0000-7000-8000-00000000000a', handle: 'alice', displayName: 'Alice');
const context = '6f1c2b9a-4d3e-4f5a-8b6c-7d8e9fa0b1c2';

WireWebRequest request(String method, String path, [String body = '']) => WireWebRequest(
  userId: 0x10000000,
  apiGroup: 'sessionManager',
  path: path,
  method: method,
  headers: const [WirePair('Content-Type', 'application/json; charset=utf-8')],
  body: utf8.encode(body),
);

Map<String, dynamic> json(WireWebReply? reply) => reply!.json! as Map<String, dynamic>;

/// The `sessionManager` group answered by the launcher, driven the way Human Fall Flat
/// (PPSA02429) hosts: the checks it makes as it starts, a push context, a Player Session made with
/// it, news of another player pushed to that context, leaving it and a stale session.
void main() {
  test('a game hosts a Player Session, gets news of another player and leaves', () async {
    final together = FakeOnlineTogether();
    final play = OnlinePlay(
      call: together.call,
      user: me,
      game: const OnlineGame(titleId: 'PPSA02429', gameVersion: '01.017', engineBuild: 'x'),
      transport: (_) => OnlineNoTransport(),
    );
    final environment = await play.start();
    addTearDown(play.stop);
    final engine = (await FakeEngine.fromEnvironment(environment))!;
    addTearDown(engine.close);
    final mine = OnlineIdentity.account(me.id);

    // What the game asks as soon as it starts is answered from the first request on.
    final restriction = await engine.web(
      WireWebRequest(
        userId: 0x10000000,
        apiGroup: 'communicationRestrictionStatus',
        path: '/v3/users/$mine/communication/restriction/status',
        method: 'GET',
      ),
    );
    expect(restriction?.status, 200);
    expect(json(restriction)['restricted'], false);
    final blocks = await engine.web(
      WireWebRequest(
        userId: 0x10000000,
        apiGroup: 'userProfile',
        path: '/v1/users/me/blocks?offset=0&limit=0',
        method: 'GET',
      ),
    );
    expect(blocks?.status, 200);

    final created = await engine.web(
      request('POST', '/v1/playerSessions', '''
{"playerSessions":[{"maxPlayers":8,"maxSpectators":0,"joinDisabled":false,"supportedPlatforms":["PS5"],
"localizedSessionName":{"defaultLanguage":"en-US","localizedText":{"en-US":"Human Fall Flat"}},"joinableUserType":"ANYONE",
"invitableUserType":"MEMBER","leaderPrivileges":["KICK"],"swapSupported":false,"customData1":"cm9vbQ==",
"member":{"players":[{"accountId":"me","platform":"me","pushContexts":[{"pushContextId":"$context"}]}]}}]}'''),
    );
    // 201, as the platform answers it: the game's libSceNpCppWebApi.prx reads the body of a
    // created session only from a 201 reply (its executor compares the status with 201).
    expect(created?.status, 201, reason: 'Host gets its Player Session');
    expect(created?.headers, [
      const WirePair('Content-Type', 'application/json'),
      WirePair('Content-Length', '${created?.body.length}'),
    ]);
    final made = (json(created)['playerSessions'] as List).single as Map<String, dynamic>;
    final sessionId = made['sessionId'] as String;
    expect(sessionId, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(
      utf8.decode(created!.body),
      '{"playerSessions":[{"member":{"players":[{"accountId":"$mine","platform":"PS5"}]},"sessionId":"$sessionId"}]}',
      reason: 'the platform\'s shape: sessionId and member.players ("me" is the signed-in player), nothing else',
    );

    final session =
        (json(await engine.web(request('GET', '/v1/playerSessions/$sessionId?fields=@default')))['playerSessions']
                    as List)
                .single
            as Map<String, dynamic>;
    expect(session['sessionId'], sessionId);
    expect(session['maxPlayers'], 8);
    expect(session['customData1'], 'cm9vbQ==');
    expect(session['joinableUserType'], 'ANYONE');
    expect((session['leader'] as Map)['accountId'], mine);
    final players = (session['member'] as Map)['players'] as List;
    expect([for (final player in players) player['onlineId']], ['alice']);
    expect(players.single['joinTimestamp'], isA<String>());

    expect(
      (await engine.web(
        request(
          'PATCH',
          '/v1/playerSessions/$sessionId',
          '{"joinableUserType":"FRIENDS","maxPlayers":4,"sessionId":"x"}',
        ),
      ))?.status,
      204,
    );
    final patched =
        (json(await engine.web(request('GET', '/v1/playerSessions/$sessionId')))['playerSessions'] as List).single
            as Map;
    expect(patched['joinableUserType'], 'FRIENDS');
    expect(patched['maxPlayers'], 4);
    expect(patched['sessionId'], sessionId, reason: 'PATCH only changes what a game may set');

    final listed = json(await engine.web(request('GET', '/v1/users/me/playerSessions')));
    expect([for (final entry in listed['playerSessions'] as List) entry['sessionId']], [sessionId]);
    expect((await engine.web(request('GET', '/v1/users/$mine/playerSessionsInvitations')))?.status, 200);

    expect(
      (await engine.web(
        request('PUT', '/v1/playerSessions/$sessionId/leader', '{"accountId":"$mine","platform":"PS5"}'),
      ))?.status,
      204,
    );
    expect(
      (await engine.web(request('PUT', '/v1/playerSessions/$sessionId/leader', '{"accountId":"123","platform":"PS5"}')))
          ?.status,
      400,
      reason: 'only a player can lead',
    );
    final invited = json(
      await engine.web(
        request('POST', '/v1/playerSessions/$sessionId/invitations', '{"invitations":[{"to":{"accountId":"123"}}]}'),
      ),
    );
    expect(invited['invitations'] as List, hasLength(1));
    expect(
      (await engine.web(
        request(
          'POST',
          '/v1/playerSessions/$sessionId/joinableSpecifiedUsers',
          '{"joinableSpecifiedUsers":[{"accountId":"123"}]}',
        ),
      ))?.status,
      201,
    );
    expect(
      (await engine.web(request('DELETE', '/v1/playerSessions/$sessionId/joinableSpecifiedUsers?accountIds=123')))
          ?.status,
      204,
    );
    expect(
      (await engine.web(request('POST', '/v1/playerSessions/$sessionId/sessionMessage', '{"payload":"hi"}')))?.status,
      204,
    );

    // News of another player goes to the push context the game made the session with.
    final sessions = play.router.playerSessions!;
    expect(sessions.playerJoined(sessionId: sessionId, account: 77, onlineId: 'bob'), isTrue);
    final joined = (await engine.nextPushEvent())!;
    expect(joined.service, 'sessionManager');
    expect(joined.pushContextId, context);
    expect(joined.dataType, 'psn:sessionManager:ps:m:players:created');
    expect(joined.from, 77);
    expect(joined.fromOnlineId, 'bob');
    expect(joined.to, OnlineIdentity.accountId(me.id));
    expect((jsonDecode(utf8.decode(joined.data)) as Map)['playerSessionId'], sessionId);
    sessions.playerLeft(sessionId: sessionId, account: 77);
    expect((await engine.nextPushEvent())?.dataType, 'psn:sessionManager:ps:m:players:deleted');
    expect(sessions.playerJoined(sessionId: 'missing', account: 77, onlineId: 'bob'), isFalse);

    // Leaving: a stale session from an earlier lobby is already left; the last player closes it.
    expect(
      (await engine.web(request('DELETE', '/v1/playerSessions/cb8a5af3-067c-4fbc-87c3-f96b20fb4f33/members/$mine')))
          ?.status,
      204,
    );
    expect((await engine.web(request('DELETE', '/v1/playerSessions/$sessionId/members/$mine')))?.status, 204);
    expect((await engine.web(request('GET', '/v1/playerSessions/$sessionId')))?.status, 404);
    expect(sessions.sessionIds, isEmpty);
    expect(together.calls, isEmpty, reason: 'Player Sessions are kept here; nothing goes anywhere');
    expect(play.router.notOffered, isEmpty);
  });

  test('joining members, leaders, bad requests', () async {
    final pushed = <WirePushEvent>[];
    final sessions = OnlinePlayerSessions(account: 42, onlineId: 'alice', push: pushed.add);
    final created = sessions.handle(request('POST', '/v1/playerSessions', '{"playerSessions":[{"maxPlayers":2}]}'));
    expect(created.status, 201);
    final id = ((json(created)['playerSessions'] as List).single as Map)['sessionId'] as String;
    String? leader() =>
        (((json(sessions.handle(request('GET', '/v1/playerSessions/$id')))['playerSessions'] as List).single
                    as Map)['leader']
                as Map)['accountId']
            as String?;
    expect(leader(), '42', reason: 'without members the creator plays and leads');

    final joined = sessions.handle(
      request('POST', '/v1/playerSessions/$id/member/players', '{"players":[{"accountId":"77","platform":"PS5"}]}'),
    );
    expect(joined.status, 201, reason: 'joining makes a member: 201, which the game\'s web API library needs');
    expect(((json(joined)['players'] as List).single as Map)['accountId'], '77');
    expect(
      sessions
          .handle(request('POST', '/v1/playerSessions/$id/member/spectators', '{"spectators":[{"accountId":88}]}'))
          .status,
      201,
    );
    final view =
        (json(sessions.handle(request('GET', '/v1/playerSessions/$id')))['playerSessions'] as List).single as Map;
    expect([for (final player in (view['member'] as Map)['spectators'] as List) player['accountId']], ['88']);
    expect(sessions.handle(request('DELETE', '/v1/playerSessions/$id/members/me')).status, 204);
    expect(leader(), '77', reason: 'the next player leads when the leader leaves');
    expect(pushed, isEmpty, reason: 'a game\'s own changes push nothing');

    // Without a push context the news goes to the plain callbacks.
    expect(sessions.playerJoined(sessionId: id, account: 99, onlineId: 'carol.with.a.long.name'), isTrue);
    expect(pushed.single.pushContextId, '');
    expect(pushed.single.fromOnlineId, 'carol.with.a.lon');
    sessions.playerLeft(sessionId: id, account: 77);
    expect(pushed.map((event) => event.dataType), [
      'psn:sessionManager:ps:m:players:created',
      'psn:sessionManager:ps:m:players:deleted',
      'psn:sessionManager:ps:leader:updated',
    ], reason: 'the leader leaving passes the lead on, and says so');

    expect(sessions.handle(request('POST', '/v1/playerSessions', '[1]')).status, 400);
    expect(sessions.handle(request('POST', '/v1/playerSessions', '{}')).status, 400);
    expect(sessions.handle(request('PATCH', '/v1/playerSessions/nope', '{}')).status, 404);
    expect(sessions.handle(request('GET', '/v1/playerSessions')).status, 404);
    expect(sessions.handle(request('GET', '/v1/users/123/playerSessions')).status, 403);
    expect(sessions.handle(request('GET', '/v2/playerSessions')).status, 404);
    expect(sessions.handle(request('DELETE', '/v1/playerSessions/$id')).status, 204);
    expect(sessions.handle(request('DELETE', '/v1/playerSessions/$id')).status, 404);
    expect(sessions.openSessions, isEmpty);

    for (var index = 0; index < OnlinePlayerSessions.maxSessions; index++) {
      sessions.handle(request('POST', '/v1/playerSessions', '{"playerSessions":[{}]}'));
    }
    expect(sessions.handle(request('POST', '/v1/playerSessions', '{"playerSessions":[{}]}')).status, 429);

    final quiet = OnlineWebRouter(
      call: FakeOnlineTogether().call,
      game: const OnlineGame(titleId: 'PPSA02429', gameVersion: '01.017', engineBuild: 'x'),
      playerSessions: sessions,
      platformGroups: false,
    );
    expect(
      await quiet.handle(request('POST', '/v1/playerSessions', '{"playerSessions":[{}]}')),
      WireWebReply.notOffered,
      reason: 'with platform groups off, Player Sessions are not offered either',
    );
  });

  test('replies carry the platform\'s statuses and headers', () {
    final sessions = OnlinePlayerSessions(account: 42, onlineId: 'alice');
    final created = sessions.handle(
      request(
        'POST',
        '/v1/playerSessions',
        '{"playerSessions":[{"member":{"players":[{"accountId":"me","platform":"PS5"}],"spectators":[{"accountId":"88","platform":"PS5"}]}}]}',
      ),
    );
    expect(created.status, 201);
    final made = (json(created)['playerSessions'] as List).single as Map<String, dynamic>;
    expect(made.keys.toSet(), {'sessionId', 'member'});
    expect(
      [for (final player in (made['member'] as Map)['spectators'] as List) player['accountId']],
      ['88'],
      reason: 'spectators appear when there are any',
    );
    final id = made['sessionId'] as String;
    final statuses = [
      ('GET', '/v1/playerSessions/$id', '', 200),
      ('GET', '/v1/users/me/playerSessions', '', 200),
      ('GET', '/v1/users/me/playerSessionsInvitations', '', 200),
      ('POST', '/v1/playerSessions/$id/member/players', '{"players":[{"accountId":"77","platform":"PS5"}]}', 201),
      ('POST', '/v1/playerSessions/$id/member/spectators', '{"spectators":[{"accountId":"99","platform":"PS5"}]}', 201),
      ('POST', '/v1/playerSessions/$id/invitations', '{"invitations":[{"to":{"accountId":"123"}}]}', 201),
      (
        'POST',
        '/v1/playerSessions/$id/joinableSpecifiedUsers',
        '{"joinableSpecifiedUsers":[{"accountId":"123"}]}',
        201,
      ),
      ('GET', '/v1/playerSessions/nope', '', 404),
    ];
    for (final (method, path, body, status) in statuses) {
      final reply = sessions.handle(request(method, path, body));
      expect(reply.status, status, reason: '$method $path');
      expect(reply.headers, [
        const WirePair('Content-Type', 'application/json'),
        WirePair('Content-Length', '${reply.body.length}'),
      ], reason: '$method $path');
    }
  });

  // Join in Human Fall Flat: the room comes from Photon's public list, and its Player Session was
  // made by the host's own console (or launcher), so it is not here. A 404 makes the game's
  // libSceNpCppWebApi finish without a body and the game crashes reading it (SIGSEGV at 0x10,
  // libSceNpCppWebApi.prx +0x1daa84), so joining a session made elsewhere is taken.
  test('joining a session made elsewhere is taken', () {
    final sessions = OnlinePlayerSessions(account: 42, onlineId: 'alice');
    const elsewhere = 'e12bb290-d6fc-4027-aac1-2bfb09fbe59b';
    final joined = sessions.handle(
      request(
        'POST',
        '/v1/playerSessions/$elsewhere/member/players',
        '{"players":[{"accountId":"42","platform":"PS5","pushContexts":[{"pushContextId":"$context"}]}]}',
      ),
    );
    expect(joined.status, 201);
    expect(utf8.decode(joined.body), '{"players":[{"accountId":"42","platform":"PS5"}]}');
    expect(sessions.sessionIds, [elsewhere]);
    final got =
        (json(sessions.handle(request('GET', '/v1/playerSessions/$elsewhere')))['playerSessions'] as List).single;
    expect([for (final player in ((got as Map)['member'] as Map)['players'] as List) player['accountId']], ['42']);
    expect(
      sessions
          .handle(
            request('POST', '/v1/playerSessions/not-a-session/member/players', '{"players":[{"accountId":"42"}]}'),
          )
          .status,
      404,
      reason: 'only a session ID (a UUID) is taken',
    );
    expect(
      sessions
          .handle(
            request('POST', '/v1/playerSessions/0190a0b1-0000-7000-8000-00000000000b/member/players', '{"players":[]}'),
          )
          .status,
      400,
      reason: 'joining needs a player',
    );
    expect(sessions.handle(request('DELETE', '/v1/playerSessions/$elsewhere/members/me')).status, 204);
    expect(sessions.sessionIds, isEmpty, reason: 'leaving it closes it here');
    expect(
      sessions
          .handle(
            request(
              'POST',
              '/v1/playerSessions/0190a0b1-0000-7000-8000-00000000000c/invitations',
              '{"invitations":[]}',
            ),
          )
          .status,
      404,
      reason: 'other calls on an unknown session still find nothing',
    );
  });
}
