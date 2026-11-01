import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/discover.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// Find Players as AnyTogether's API sends it (the macOS launcher's TogetherDiscover): the
/// looking-for-group board, posts and their requests, public parties, discovery and game hubs.
void main() {
  Map<String, dynamic> person(String id, String name) => {
    'userId': id,
    'handle': name.toLowerCase(),
    'displayName': name,
    'avatar': null,
  };

  Map<String, dynamic> post(
    String id, {
    bool mine = false,
    Map<String, dynamic>? myRequest,
    String status = 'open',
    int filled = 0,
    String? startsAt,
    List<Map<String, dynamic>>? requests,
  }) => {
    'id': id,
    'author': person('u-bora', 'Bora'),
    'titleId': 'PPSA02002',
    'game': {
      'names': {'en': 'Neon Alley'},
      'iconUrl': null,
    },
    'purpose': 'coop',
    'startsAt': startsAt,
    'languages': ['en', 'tr'],
    'region': null,
    'slots': 3,
    'filled': filled,
    'note': 'Chill run',
    'expiresAt': DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String(),
    'status': status,
    'createdAt': '2026-10-24T20:00:00Z',
    'mine': mine,
    'myRequest': myRequest,
    'requests': ?requests,
  };

  group('parsing', () {
    test('where the user stands with a post', () {
      expect(LfgPost.fromJson(post('p'))!.standing(), LfgStanding.canAsk);
      expect(LfgPost.fromJson(post('p', mine: true))!.standing(), LfgStanding.own);
      expect(
        LfgPost.fromJson(post('p', myRequest: {'status': 'pending', 'invite': null}))!.standing(),
        LfgStanding.waiting,
      );
      final accepted = LfgPost.fromJson(
        post(
          'p',
          myRequest: {
            'status': 'accepted',
            'invite': {'kind': 'party', 'id': 'party-1'},
          },
        ),
      )!;
      expect(accepted.standing(), LfgStanding.accepted);
      expect(accepted.myInvite!.id, 'party-1');
      expect(LfgPost.fromJson(post('p', myRequest: {'status': 'declined'}))!.standing(), LfgStanding.declined);
      expect(LfgPost.fromJson(post('p', filled: 3))!.standing(), LfgStanding.closed);
      expect(LfgPost.fromJson(post('p', status: 'closed'))!.standing(), LfgStanding.closed);
      expect(
        LfgPost.fromJson(post('p', status: 'closed', myRequest: {'status': 'pending'}))!.standing(),
        LfgStanding.closed,
        reason: 'waiting on a post that closed',
      );
    });

    test('when a post starts, and who waits on the user\'s own', () {
      final now = DateTime.utc(2026, 10, 24, 20);
      expect(LfgPost.fromJson(post('p'))!.startsIn(now), 0);
      expect(LfgPost.fromJson(post('p', startsAt: '2026-10-24T20:30:00Z'))!.startsIn(now), 30);
      expect(
        LfgPost.fromJson(post('p', startsAt: '2026-10-24T20:01:00Z'))!.startsIn(now),
        0,
        reason: 'a minute is now',
      );
      final mine = LfgPost.fromJson(
        post(
          'p',
          mine: true,
          requests: [
            {'user': person('u-ana', 'Ana'), 'status': 'pending', 'invite': null, 'createdAt': '2026-10-24T20:00:00Z'},
            {
              'user': person('u-cem', 'Cem'),
              'status': 'accepted',
              'invite': {'kind': 'party', 'id': 'x'},
            },
          ],
        ),
      )!;
      expect(mine.pending.single.user.displayName, 'Ana');
      expect(mine.requests, hasLength(2));
      expect(mine.name('tr'), 'Neon Alley');
    });

    test('the filter as a query, and the topics a screen listens to', () {
      expect(const LfgFilter().query(), '');
      expect(
        const LfgFilter(
          titleId: 'PPSA02002',
          purpose: LfgPurpose.online,
          language: 'tr',
          now: true,
        ).query(before: 'p9'),
        '?titleId=PPSA02002&purpose=online&language=tr&now=1&before=p9',
      );
      expect(const LfgFilter(titleId: 'PPSA02002').copyWith(titleId: () => null), const LfgFilter());
      expect(DiscoverTopics.of(null), ['lfg', 'discover']);
      expect(DiscoverTopics.of('PPSA02002'), ['lfg:PPSA02002', 'discover:PPSA02002']);
      expect(DiscoverTopics.clean(['lfg', 'lfg', 'bad', 'discover:ppsa1']), ['lfg']);
    });

    test('a draft: slots within what the purpose allows, the stay within a day, the body', () {
      final draft = LfgDraft(titleId: 'PPSA02002', languages: ['tr', 'en', 'de', 'fr'], slots: 3, note: '  hi  ');
      draft.setPurpose(LfgPurpose.party);
      draft.slots = 7;
      draft.setPurpose(LfgPurpose.coop);
      expect(draft.slots, 3, reason: 'co-op holds pads 2 to 4');
      draft.hours = 24;
      draft.setStart(120);
      expect(draft.maxStay, 22);
      expect(draft.hours, 22);
      final now = DateTime.utc(2026, 10, 24, 20);
      final body = draft.body(now);
      expect(body['languages'], ['tr', 'en', 'de']);
      expect(body['startsAt'], '2026-10-24T22:00:00.000Z');
      expect(body['expiresAt'], '2026-10-25T20:00:00.000Z', reason: 'never more than a day from now');
      expect(body['note'], 'hi');
      expect(LfgDraft(titleId: 'PPSA02002', languages: ['en']).body(now).containsKey('startsAt'), isFalse);
    });

    test('discovery languages: on and off, five at most; people and their reasons', () {
      const discovery = Discovery(discoverable: true, languages: ['en', 'tr', 'de', 'fr', 'es']);
      expect(discovery.toggling('tr'), ['en', 'de', 'fr', 'es']);
      expect(discovery.toggling('it'), isNull);
      final found = DiscoveredPerson.fromJson({
        'user': person('u-deniz', 'Deniz'),
        'friendship': 'none',
        'presence': {'state': 'in_game', 'titleId': 'PPSA02002'},
        'reasons': [
          {
            'kind': 'game',
            'titleId': 'PPSA02002',
            'names': {'en': 'Neon Alley'},
          },
          {'kind': 'friends', 'count': 2},
          {'kind': 'language', 'language': 'tr'},
          {'kind': 'new_kind'},
        ],
      })!;
      expect(found.canAsk, isTrue);
      expect(found.state, 'in_game');
      expect(found.reasons.map((reason) => reason.kind), ['game', 'friends', 'language', 'new_kind']);
      expect(DiscoverLanguages.name('tr'), 'Türkçe');
      expect(DiscoverLanguages.name('xx'), 'xx');
    });

    test('a game hub: who plays now, posts, parties and players', () {
      final hub = GameHub.fromJson({
        'game': {
          'titleId': 'PPSA02002',
          'names': {'en': 'Neon Alley'},
        },
        'players': 42,
        'playing': {
          'total': 3,
          'people': [
            {'user': person('u-ana', 'Ana'), 'since': '2026-10-24T19:00:00Z'},
          ],
        },
        'lfg': [post('p1')],
        'parties': [
          {'id': 'pa', 'host': person('u-cem', 'Cem'), 'join': 'open', 'size': 8, 'max': 8, 'requested': false},
        ],
        'sharePlays': <Object>[],
        'recentPlayers': [
          {'user': person('u-eren', 'Eren'), 'friendship': 'friends', 'lastPlayedAt': '2026-10-20T19:00:00Z'},
        ],
      });
      expect(hub.players, 42);
      expect(hub.playingTotal, 3);
      expect(hub.playing.single.user.handle, 'ana');
      expect(hub.parties.single.full, isTrue);
      expect(hub.parties.single.join, PublicJoin.open);
      expect(hub.recentPlayers.single.canAsk, isFalse);
      final closed = LfgPost.fromJson(post('p1', status: 'closed'))!;
      expect(hub.withPost(closed).lfg.single.status, 'closed');
    });
  });

  group('client', () {
    late FakeTogether server;
    late TogetherAccount account;
    late Discover discover;

    setUp(() async {
      server = await FakeTogether.start();
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      discover = Discover(account);
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('the board, my posts, "I\'m in", taking it back, answering and closing', () async {
      server.answers['lfg?purpose=coop'] = (
        200,
        {
          'posts': [post('p2'), post('p1')],
          'more': true,
        },
      );
      final (posts, more) = await discover.board(const LfgFilter(purpose: LfgPurpose.coop));
      expect(posts.map((post) => post.id), ['p2', 'p1']);
      expect(more, isTrue);

      server.answers['POST lfg/p2/requests'] = (201, post('p2', myRequest: {'status': 'pending'}));
      expect((await discover.join('p2'))!.standing(), LfgStanding.waiting);
      server.answers['DELETE lfg/p2/requests/me'] = (204, null);
      await discover.takeBack('p2');
      expect(server.callsTo('lfg/p2/requests/me', method: 'DELETE'), hasLength(1));

      server.answers['me/lfg'] = (
        200,
        {
          'posts': [post('p9', mine: true)],
          'asked': [
            post('p2', myRequest: {'status': 'pending'}),
          ],
        },
      );
      final (mine, asked) = await discover.mine();
      expect(mine.single.mine, isTrue);
      expect(asked.single.id, 'p2');

      server.answers['POST lfg/p9/requests/u-ana/accept'] = (200, post('p9', mine: true, filled: 1));
      expect((await discover.answer('p9', 'u-ana', accept: true))!.filled, 1);
      server.answers['DELETE lfg/p9'] = (204, null);
      await discover.close('p9');

      server.answers['POST lfg'] = (201, post('p10', mine: true));
      final draft = LfgDraft(titleId: 'PPSA02002', languages: ['en'], purpose: LfgPurpose.trophies, slots: 2);
      expect((await discover.post(draft))!.id, 'p10');
      final sent = server.callsTo('lfg', method: 'POST').single.body;
      expect(sent['purpose'], 'trophies');
      expect(sent['slots'], 2);
    });

    test('public parties: listed, asked to join, the ask taken back; listing the own party', () async {
      server.answers['parties/public'] = (
        200,
        {
          'parties': [
            {
              'id': 'pa',
              'host': person('u-cem', 'Cem'),
              'titleId': 'PPSA02002',
              'game': {
                'names': {'en': 'Neon Alley'},
              },
              'language': 'tr',
              'join': 'request',
              'size': 2,
              'max': 8,
              'requested': false,
            },
          ],
        },
      );
      final parties = await discover.parties();
      expect(parties.single.language, 'tr');
      expect(parties.single.join, PublicJoin.request);
      server.answers['POST parties/pa/requests'] = (202, null);
      await discover.askToJoin('pa');
      server.answers['DELETE parties/pa/requests/me'] = (204, null);
      await discover.cancelAsk('pa');
      server.answers['PATCH parties/mine'] = (200, {'id': 'mine'});
      await discover.listParty('mine', join: PublicJoin.open, titleId: 'PPSA02002', language: 'en');
      await discover.listParty('mine');
      final patches = server.callsTo('parties/mine', method: 'PATCH').map((call) => call.body).toList();
      expect(patches.first, {
        'public': {'join': 'open', 'titleId': 'PPSA02002', 'language': 'en'},
      });
      expect(patches.last, {'public': null});
    });

    test('discovery: read, chosen, languages', () async {
      server.answers['me/discovery'] = (200, {'discoverable': false, 'chosen': null, 'languages': <String>[]});
      expect((await discover.discovery()).chosen, isNull);
      server.answers['PATCH me/discovery'] = (
        200,
        {
          'discoverable': true,
          'chosen': true,
          'languages': ['tr'],
        },
      );
      final now = await discover.setDiscovery(discoverable: () => true, languages: ['tr']);
      expect(now.discoverable, isTrue);
      expect(server.callsTo('me/discovery', method: 'PATCH').single.body, {
        'discoverable': true,
        'languages': ['tr'],
      });
      await discover.setDiscovery(discoverable: () => null);
      expect(server.callsTo('me/discovery', method: 'PATCH').last.body, {'discoverable': null});
    });
  });
}
