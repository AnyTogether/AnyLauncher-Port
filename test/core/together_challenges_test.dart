import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/challenges.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// Challenges as AnyTogether's API sends them (packages/shared/src/challenges.ts): a time-boxed
/// race on one game's board, its standings, joining and leaving. A server before them answers
/// 404 on the lists, which reads as none.
void main() {
  Map<String, dynamic> person(String id, String name) => {
    'userId': id,
    'handle': name.toLowerCase(),
    'displayName': name,
    'avatar': null,
  };

  Map<String, dynamic> view(String id, {String state = 'active', bool joined = true, bool mine = false}) => {
    'id': id,
    'title': 'Weekend race',
    'description': 'Most points by Sunday night',
    'game': {
      'titleId': 'PPSA01234',
      'names': {'en': 'Cat Quest', 'tr': 'Kedi Macerası'},
      'iconUrl': null,
    },
    'metric': 'points',
    'audience': 'community',
    'community': {'id': 'c-1', 'name': 'Night Owls', 'icon': 'owl', 'iconUrl': 'https://example.com/owl.png'},
    'creator': person('u-ana', 'Ana'),
    'startsAt': '2026-11-06T18:00:00.000Z',
    'endsAt': '2026-11-08T22:00:00.000Z',
    'state': state,
    'final': false,
    'entrants': 7,
    'joined': joined,
    'mine': mine,
    'canCancel': mine,
    'leader': {'rank': 1, 'user': person('u-bora', 'Bora'), 'value': 420, 'me': false},
    'myStanding': joined ? {'rank': 3, 'value': 135} : null,
    'createdAt': '2026-11-05T10:00:00.000Z',
  };

  group('decoding', () {
    test('a challenge: its game, what counts, for whom, the window, the leader and the reader\'s place', () {
      final challenge = Challenge.fromJson(view('ch-1'))!;
      expect(challenge.id, 'ch-1');
      expect(challenge.title, 'Weekend race');
      expect(challenge.description, 'Most points by Sunday night');
      expect(challenge.game.titleId, 'PPSA01234');
      expect(challenge.game.name('tr'), 'Kedi Macerası');
      expect(challenge.game.name('de'), 'Cat Quest');
      expect(challenge.metric, ChallengeMetric.points);
      expect(challenge.audience, ChallengeAudience.community);
      expect(challenge.community!.name, 'Night Owls');
      expect(challenge.creator!.handle, 'ana');
      expect(challenge.startsAt, DateTime.utc(2026, 11, 6, 18));
      expect(challenge.endsAt, DateTime.utc(2026, 11, 8, 22));
      expect(challenge.state, ChallengeState.active);
      expect(challenge.isFinal, isFalse);
      expect(challenge.entrants, 7);
      expect(challenge.joined, isTrue);
      expect(challenge.mine, isFalse);
      expect(challenge.leader!.user!.displayName, 'Bora');
      expect(challenge.leader!.value, 420);
      expect(challenge.myStanding!.rank, 3);
      expect(challenge.myStanding!.value, 135);
    });

    test('a later server\'s fields and words are no failure; nulls where the server may send them', () {
      final challenge = Challenge.fromJson({
        ...view('ch-2', joined: false),
        'metric': 'speedrun',
        'audience': 'guild',
        'state': 'paused',
        'community': null,
        'creator': null,
        'leader': {'rank': 1, 'user': null, 'value': 90, 'me': false, 'badge': 'gold'},
        'description': null,
        'prize': {'kind': 'badge'},
        'tags': ['weekend'],
      })!;
      expect(challenge.metric, ChallengeMetric.other);
      expect(challenge.audience, ChallengeAudience.other);
      expect(challenge.state, ChallengeState.other);
      expect(challenge.community, isNull);
      expect(challenge.creator, isNull, reason: 'the maker\'s account is gone');
      expect(challenge.leader!.user, isNull, reason: 'a hidden player still holds the place');
      expect(challenge.leader!.value, 90);
      expect(challenge.myStanding, isNull);
      expect(challenge.description, isNull);
      expect(Challenge.fromJson({'title': 'no id'}), isNull);
      expect(Challenge.fromJson('odd'), isNull);
    });

    test('a challenge\'s standings: the first rows, the reader\'s neighbours past them, hidden players', () {
      final detail = ChallengeDetail.fromJson({
        ...view('ch-3', state: 'ended'),
        'final': true,
        'standings': [
          {'rank': 1, 'user': person('u-bora', 'Bora'), 'value': 420, 'me': false},
          {'rank': 2, 'user': null, 'value': 300, 'me': false},
          {'rank': 2, 'user': person('u-cem', 'Cem'), 'value': 300, 'me': false},
          {'rank': 4, 'user': person('u-me', 'Utku'), 'value': 135, 'me': true},
          'broken',
        ],
        'around': <Object>[],
        'updatedAt': '2026-11-08T23:00:00.000Z',
        'nextRefresh': 30,
      })!;
      expect(detail.challenge.state, ChallengeState.ended);
      expect(detail.challenge.isFinal, isTrue);
      expect(detail.standings.map((row) => row.rank), [1, 2, 2, 4], reason: 'shared ranks on ties; a broken row is left out');
      expect(detail.standings[1].user, isNull);
      expect(detail.standings[3].me, isTrue);
      expect(detail.around, isEmpty);
      expect(detail.updatedAt, DateTime.utc(2026, 11, 8, 23));
      expect(ChallengeDetail.fromJson({'standings': []}), isNull);
    });
  });

  group('client', () {
    late FakeTogether server;
    late TogetherAccount account;
    late Challenges challenges;

    setUp(() async {
      server = await FakeTogether.start();
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      challenges = Challenges(account);
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('a game\'s and the reader\'s own lists', () async {
      server.answers['challenges?titleId=PPSA01234'] = (
        200,
        {
          'challenges': [view('ch-1'), view('ch-2', state: 'upcoming'), 'broken'],
        },
      );
      server.answers['me/challenges'] = (
        200,
        {
          'challenges': [view('ch-9')],
        },
      );
      expect((await challenges.forGame('PPSA01234')).map((item) => item.id), ['ch-1', 'ch-2']);
      expect((await challenges.mine()).single.id, 'ch-9');
    });

    test('a server before challenges answers 404: none, not a failure; another failure is thrown', () async {
      expect(await challenges.forGame('PPSA01234'), isEmpty);
      expect(await challenges.mine(), isEmpty);
      server.answers['me/challenges'] = FakeTogether.problem(500, 'internal');
      await expectLater(challenges.mine(), throwsA(isA<TogetherProblem>()));
    });

    test('one challenge with its standings; joining and leaving send an empty body', () async {
      server.answers['challenges/ch-1'] = (
        200,
        {
          ...view('ch-1'),
          'standings': [
            {'rank': 1, 'user': person('u-bora', 'Bora'), 'value': 420, 'me': false},
          ],
          'around': [
            {'rank': 140, 'user': person('u-me', 'Utku'), 'value': 3, 'me': true},
          ],
          'updatedAt': '2026-11-07T12:00:00.000Z',
        },
      );
      final detail = await challenges.detail('ch-1');
      expect(detail.standings.single.user!.displayName, 'Bora');
      expect(detail.around.single.me, isTrue);

      server.answers['POST challenges/ch-1/join'] = (200, view('ch-1'));
      server.answers['POST challenges/ch-1/leave'] = (200, view('ch-1', joined: false));
      expect((await challenges.join('ch-1')).joined, isTrue);
      expect((await challenges.leave('ch-1')).joined, isFalse);
      expect(server.callsTo('challenges/ch-1/join', method: 'POST').single.body, isEmpty);
      expect(server.callsTo('challenges/ch-1/leave', method: 'POST').single.body, isEmpty);

      server.answers['POST challenges/ch-1/join'] = FakeTogether.problem(409, 'full');
      await expectLater(
        challenges.join('ch-1'),
        throwsA(isA<TogetherProblem>().having((problem) => problem.code, 'code', 'full')),
      );
    });
  });
}
