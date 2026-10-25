import 'dart:async';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/friends.dart';
import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/core/together/self.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// Trophy levels, the showcase and comparing trophies, and appearing offline, as AnyTogether's
/// API sends them.
void main() {
  group('parsing', () {
    test('a level badge: the number, its tier and frame; worked out when the server leaves them out', () {
      expect(LevelBadge.fromJson({'level': 12, 'tier': 'bronze', 'frame': 1}), LevelBadge.of(12));
      expect(
        LevelBadge.fromJson({'level': 345, 'tier': 'gold', 'frame': 4}),
        const LevelBadge(level: 345, tier: LevelTier.gold, frame: 4),
      );
      expect(LevelBadge.fromJson({'level': 640}), const LevelBadge(level: 640, tier: LevelTier.platinum, frame: 7));
      expect(LevelBadge.of(99).tier, LevelTier.bronze);
      expect(LevelBadge.of(100), const LevelBadge(level: 100, tier: LevelTier.silver, frame: 2));
      expect(LevelBadge.of(999).frame, 10);
      expect(LevelBadge.fromJson(null), isNull);
      expect(LevelBadge.fromJson({'tier': 'gold'}), isNull);
      expect(LevelBadge.fromJson('12'), isNull);
    });

    test('a trophy level: points, where the level starts, the next one, and how far along', () {
      final level = TrophyLevel.fromJson({
        'level': 12,
        'tier': 'bronze',
        'frame': 1,
        'points': 700,
        'levelPoints': 660,
        'nextLevelPoints': 720,
        'progress': 66,
      })!;
      expect(level.level, 12);
      expect(level.progress, 66);
      expect(level.toNext, 20);
      expect(level.top, isFalse);
      final top = TrophyLevel.fromJson({
        'level': 999,
        'tier': 'platinum',
        'frame': 10,
        'points': 2000000,
        'levelPoints': 1999000,
        'nextLevelPoints': null,
        'progress': 100,
      })!;
      expect(top.top, isTrue);
      expect(top.toNext, isNull);
      expect(TrophyLevel.fromJson(null), isNull);
    });

    test('a profile with its level, and one from an older server or with trophies kept private', () {
      final profile = TogetherProfile.fromJson({
        'userId': 'u-ana',
        'handle': 'ana',
        'displayName': 'Ana',
        'friendship': 'friends',
        'trophyLevel': {
          'level': 140,
          'tier': 'silver',
          'frame': 2,
          'points': 9000,
          'levelPoints': 8940,
          'nextLevelPoints': 9030,
          'progress': 66,
        },
        'cover': null,
        'accent': 'mint',
      });
      expect(profile.trophyLevel?.tier, LevelTier.silver);
      expect(
        TogetherProfile.fromJson({'userId': 'u', 'handle': 'h', 'displayName': 'H', 'trophyLevel': null}).trophyLevel,
        isNull,
      );
      expect(TogetherProfile.fromJson({'userId': 'u', 'handle': 'h', 'displayName': 'H'}).trophyLevel, isNull);
    });

    test('a showcase: pinned trophies and favourite games; a part kept private is null', () {
      final showcase = Showcase.fromJson({
        'trophies': [
          {
            'titleId': 'PPSA01001',
            'gameNames': {'en': 'Orbit Runner'},
            'trophyId': 0,
            'grade': 'platinum',
            'hidden': false,
            'texts': {
              'en': {'name': 'Grand Tour', 'detail': 'Every trophy'},
            },
            'earnedAt': '2026-10-02T20:00:00Z',
            'rarity': 0.031,
            'rarityLabel': 'ultra_rare',
          },
        ],
        'games': null,
      });
      expect(showcase.trophies!.single.name('en'), 'Grand Tour');
      expect(showcase.trophies!.single.grade, 'platinum');
      expect(showcase.games, isNull);
      expect(showcase.private, isFalse);
      expect(Showcase.fromJson({'trophies': null, 'games': null}).private, isTrue);
      final games = Showcase.fromJson({
        'trophies': <Object>[],
        'games': [
          {
            'titleId': 'PPSA02002',
            'names': {'en': 'Neon Alley'},
            'iconUrl': null,
            'secondsPlayed': 3600,
            'trophiesEarned': 18,
            'trophiesTotal': 42,
            'progress': 43,
          },
        ],
      });
      expect(games.games!.single.name('en'), 'Neon Alley');
      expect(games.games!.single.progress, 43);
      expect(games.empty, isFalse);
      expect(Showcase.fromJson({'trophies': <Object>[], 'games': <Object>[]}).empty, isTrue);
    });

    test('compared games: both sides, or one where the other has none', () {
      final game = ComparedGame.fromJson({
        'titleId': 'PPSA02002',
        'names': {'en': 'Neon Alley', 'tr': 'Neon Sokak'},
        'iconUrl': null,
        'mine': {'earned': 12, 'total': 42, 'progress': 28, 'points': 300},
        'theirs': {'earned': 18, 'total': 42, 'progress': 43, 'points': 690},
      });
      expect(game.both, isTrue);
      expect(game.name('tr'), 'Neon Sokak');
      expect(game.theirs!.earned, 18);
      final alone = ComparedGame.fromJson({
        'titleId': 'PPSA07007',
        'names': {'en': 'Harbor Lights'},
        'mine': null,
        'theirs': {'earned': 3, 'total': null, 'progress': null, 'points': 45},
      });
      expect(alone.both, isFalse);
      expect(alone.mine, isNull);
      expect(alone.theirs!.total, isNull);
    });

    test("one game's trophies side by side: who earned what and when, the totals", () {
      final view = TrophyComparison.fromJson({
        'titleId': 'PPSA02002',
        'game': {
          'names': {'en': 'Neon Alley'},
          'iconUrl': null,
        },
        'setHash': 'abc',
        'me': {
          'userId': 'u-me',
          'handle': 'utku',
          'displayName': 'Utku',
          'avatar': null,
          'level': {'level': 12, 'tier': 'bronze', 'frame': 1},
        },
        'them': {
          'userId': 'u-bora',
          'handle': 'bora',
          'displayName': 'Bora',
          'avatar': null,
          'level': {'level': 140, 'tier': 'silver', 'frame': 2},
        },
        'trophies': [
          {
            'id': 0,
            'grade': 'gold',
            'hidden': false,
            'texts': {
              'en': {'name': 'Last Light', 'detail': 'Finish the story'},
            },
            'rarity': 0.12,
            'rarityLabel': 'rare',
            'mine': null,
            'theirs': '2026-10-20T21:00:00Z',
          },
          {
            'id': 1,
            'grade': 'bronze',
            'hidden': true,
            'texts': null,
            'rarity': null,
            'rarityLabel': null,
            'mine': '2026-10-21T20:00:00Z',
            'theirs': '2026-10-19T20:00:00Z',
          },
        ],
        'totals': {'mine': 1, 'theirs': 2, 'both': 1, 'total': 2},
      });
      expect(view.gameName('en'), 'Neon Alley');
      expect(view.me.level, LevelBadge.of(12));
      expect(view.them.person.displayName, 'Bora');
      expect(view.trophies.first.name('en'), 'Last Light');
      expect(view.trophies.first.mine, isNull);
      expect(view.trophies.first.theirs, DateTime.utc(2026, 10, 20, 21));
      expect(view.trophies.last.name('en'), isNull);
      expect((view.mine, view.theirs, view.both, view.total), (1, 2, 1, 2));
    });
  });

  group('client', () {
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
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
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

    test('a profile page reads the showcase beside the library and trophies', () async {
      server.profiles['ana'] = {
        'userId': 'u-ana',
        'handle': 'ana',
        'displayName': 'Ana',
        'friendship': 'friends',
        'trophyLevel': {'level': 7, 'tier': 'bronze', 'frame': 1, 'points': 400},
      };
      server.showcases['ana'] = {
        'trophies': null,
        'games': [
          {
            'titleId': 'PPSA02002',
            'names': {'en': 'Neon Alley'},
            'secondsPlayed': 60,
          },
        ],
      };
      final page = await Profiles(account).page('ana');
      expect(page.profile.trophyLevel?.level, 7);
      expect(page.showcase.value!.trophies, isNull);
      expect(page.showcase.value!.games!.single.titleId, 'PPSA02002');
      expect(server.callsTo('users/ana/showcase'), hasLength(1));

      // An older server without the showcase: the page still comes.
      server.showcases.remove('ana');
      final older = await Profiles(account).page('ana');
      expect(older.showcase, isA<SectionFailed<Showcase>>());
      server.privateParts['ana'] = {'showcase'};
      expect((await Profiles(account).page('ana')).showcase, isA<SectionPrivate<Showcase>>());
    });

    test('comparing: the games list, one game, and trophies kept private', () async {
      server.compareLists['bora'] = [
        {
          'titleId': 'PPSA02002',
          'names': {'en': 'Neon Alley'},
          'iconUrl': null,
          'mine': {'earned': 12, 'total': 42, 'progress': 28, 'points': 300},
          'theirs': {'earned': 18, 'total': 42, 'progress': 43, 'points': 690},
        },
      ];
      server.compareViews['bora/PPSA02002'] = {
        'titleId': 'PPSA02002',
        'game': {
          'names': {'en': 'Neon Alley'},
          'iconUrl': null,
        },
        'setHash': 'abc',
        'me': {'userId': 'u-me', 'handle': 'utku', 'displayName': 'Utku', 'avatar': null, 'level': null},
        'them': {'userId': 'u-bora', 'handle': 'bora', 'displayName': 'Bora', 'avatar': null, 'level': null},
        'trophies': <Object>[],
        'totals': {'mine': 0, 'theirs': 0, 'both': 0, 'total': 0},
      };
      final profiles = Profiles(account);
      final games = await profiles.compareGames('@bora');
      expect(games.value!.single.theirs!.earned, 18);
      expect(server.callsTo('users/bora/trophies/compare'), hasLength(1));
      final view = await profiles.compareGame('bora', 'PPSA02002');
      expect(view.value!.titleId, 'PPSA02002');
      expect(server.callsTo('users/bora/trophies/compare?titleId=PPSA02002'), hasLength(1));

      server.privateParts['bora'] = {'compare'};
      expect(await profiles.compareGames('bora'), isA<SectionPrivate<List<ComparedGame>>>());
      expect(await profiles.compareGame('bora', 'PPSA02002'), isA<SectionPrivate<TrophyComparison>>());
      server.privateParts.remove('bora');
      expect(await profiles.compareGame('bora', 'PPSA09999'), isA<SectionFailed<TrophyComparison>>());
    });

    test('my own level and appearing offline come from /me; an older server has neither', () async {
      final self = SelfProfile(account: account, socket: socket);
      await self.refresh();
      expect(self.level, isNull);
      expect(self.appearOffline, isFalse);
      server.me['trophyLevel'] = {
        'level': 12,
        'tier': 'bronze',
        'frame': 1,
        'points': 700,
        'levelPoints': 660,
        'nextLevelPoints': 720,
        'progress': 66,
      };
      server.me['appearOffline'] = true;
      await self.refresh();
      expect(self.level?.level, 12);
      expect(self.level?.progress, 66);
      expect(self.appearOffline, isTrue);
      self.dispose();
    });

    test('appearing offline: sent, kept, and turned back when the server cannot', () async {
      final self = SelfProfile(account: account, socket: socket);
      var changes = 0;
      self.addListener(() => changes++);
      await self.setAppearOffline(true);
      expect(self.appearOffline, isTrue);
      expect(server.callsTo('me/presence', method: 'PATCH').single.body, {'appearOffline': true});
      expect(changes, greaterThan(0));

      server.answers['PATCH me/presence'] = FakeTogether.problem(404, 'not_found');
      await expectLater(self.setAppearOffline(false), throwsA(isA<TogetherProblem>()));
      expect(self.appearOffline, isTrue, reason: 'turned back to what it was');
      self.dispose();
    });

    test('level.up for me and presence.mode from another device; level.up for a friend', () async {
      server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
      server.friends.last['level'] = {'level': 9, 'tier': 'bronze', 'frame': 1};
      server.friend('u-cem', 'cem', 'Cem');
      final self = SelfProfile(account: account, socket: socket);
      final friends = Friends(account: account, socket: socket);
      final reached = <LevelBadge>[];
      self.onLevelUp = reached.add;
      socket.start();
      await until(() => friends.loaded && self.loaded);
      expect(friends.byId('u-ana')!.level, LevelBadge.of(9));
      expect(friends.byId('u-cem')!.level, isNull);

      server.me['trophyLevel'] = {
        'level': 12,
        'tier': 'bronze',
        'frame': 1,
        'points': 670,
        'levelPoints': 660,
        'nextLevelPoints': 720,
        'progress': 16,
      };
      server.push('level.up', {
        'userId': 'u-me',
        'handle': 'utku',
        'displayName': 'Utku',
        'level': 12,
        'tier': 'bronze',
        'frame': 1,
      });
      await until(() => reached.isNotEmpty);
      expect(reached.single, LevelBadge.of(12));
      expect(self.level?.level, 12);
      // Read again for the way to the next level.
      await until(() => self.level?.progress == 16);

      server.push('level.up', {
        'userId': 'u-ana',
        'handle': 'ana',
        'displayName': 'Ana',
        'level': 10,
        'tier': 'bronze',
        'frame': 1,
      });
      await until(() => friends.byId('u-ana')!.level?.level == 10);
      expect(reached, hasLength(1), reason: "a friend's level is not mine");

      // Presence keeps the level.
      server.push('presence.updated', {'userId': 'u-ana', 'state': 'in_game', 'titleId': 'PPSA01001'});
      await until(() => friends.byId('u-ana')!.presence.playing);
      expect(friends.byId('u-ana')!.level?.level, 10);

      server.push('presence.mode', {'appearOffline': true});
      await until(() => self.appearOffline);
      server.push('presence.mode', {'appearOffline': false});
      await until(() => !self.appearOffline);
      friends.dispose();
      self.dispose();
    });
  });
}
