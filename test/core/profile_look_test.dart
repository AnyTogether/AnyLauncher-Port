import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/profile_look.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/core/together/self.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// A profile's look (a cover, an accent, a Theme Hub theme worn) and its showcase of up to six
/// pins, as AnyTogether's API sends and takes them.
void main() {
  const nightDrive = {
    'id': '7d0f4a52-3b1e-4c8a-9f61-2a5b8c9d0e11',
    'name': 'Night Drive',
    'colors': {'deep': '#05060f', 'middle': '#2a1458', 'bright': '#ff5fa2', 'accent': '#ffb347'},
    'preview': 'https://anytogether.net/api/v1/themes/7d0f/preview.webp?v=2',
    'thumb': 'https://anytogether.net/api/v1/themes/7d0f/thumb.webp?v=2',
    'maker': {'handle': 'ana', 'displayName': 'Ana'},
  };

  group('parsing', () {
    test('a profile wearing a theme: its colours, stills and maker', () {
      final profile = TogetherProfile.fromJson({
        'userId': 'u-ana',
        'handle': 'ana',
        'displayName': 'Ana',
        'cover': null,
        'accent': null,
        'theme': nightDrive,
      });
      final theme = profile.look.theme!;
      expect(theme.id, '7d0f4a52-3b1e-4c8a-9f61-2a5b8c9d0e11');
      expect(theme.name, 'Night Drive');
      expect((theme.deep, theme.middle, theme.bright, theme.accent), ('#05060f', '#2a1458', '#ff5fa2', '#ffb347'));
      expect(theme.preview, nightDrive['preview']);
      expect(theme.thumb, nightDrive['thumb']);
      expect(theme.makerName, 'Ana');
      expect(theme.makerHandle, 'ana');
      // The rule every client draws by: the theme's still and accent when nothing else is chosen.
      expect(profile.look.picture, nightDrive['preview']);
      expect(profile.look.accentHex, '#ffb347');
    });

    test('a cover and an accent picked win over the theme', () {
      final look = ProfileLook.fromJson({
        'cover': {
          'kind': 'preset',
          'id': 'cosmic-ribbons',
          'url': 'https://anytogether.net/covers/cosmic-ribbons.webp',
        },
        'accent': 'mint',
        'theme': nightDrive,
      });
      expect(look.cover?.kind, 'preset');
      expect(look.cover?.id, 'cosmic-ribbons');
      expect(look.picture, 'https://anytogether.net/covers/cosmic-ribbons.webp');
      expect(look.accentHex, '#5cebbd');
      expect(look.theme?.name, 'Night Drive', reason: 'the theme still tints the header');
    });

    test('an older server leaves them out; anything odd is no look', () {
      final profile = TogetherProfile.fromJson({'userId': 'u-bo', 'handle': 'bo', 'displayName': 'Bo'});
      expect(profile.look.cover, isNull);
      expect(profile.look.accent, isNull);
      expect(profile.look.theme, isNull);
      expect(profile.look.picture, isNull);
      expect(profile.look.accentHex, isNull);
      expect(profile.look.empty, isTrue);
      final odd = ProfileLook.fromJson({
        'cover': {'kind': 'preset'},
        'accent': 'plaid',
        'theme': {'id': 42, 'name': 'x'},
      });
      expect(odd.empty, isTrue);
      expect(ProfileTheme.fromJson({'id': 'x', 'name': 'No colours'})?.accent, isNull);
      expect(
        ProfileTheme.fromJson({
          'id': 'x',
          'name': 'Bad',
          'colors': {'accent': 'red'},
        })?.accent,
        isNull,
      );
    });

    test('every accent the server offers has its colour', () {
      expect(profileAccents, {
        'blue': '#4f94ff',
        'mint': '#5cebbd',
        'coral': '#ff8066',
        'violet': '#a885ff',
        'gold': '#ffcc5c',
        'white': '#f0f0f0',
      });
    });
  });

  group('six pins', () {
    final showcase = Showcase.fromJson({
      'trophies': [
        {'titleId': 'PPSA02002', 'trophyId': 3, 'gameNames': <String, String>{}, 'earnedAt': '2026-10-20T21:00:00Z'},
      ],
      'games': [
        {'titleId': 'PPSA01001', 'names': <String, String>{}},
      ],
    });

    test('pins start from the showcase and count trophies and games together', () {
      final pins = ShowcasePins.of(showcase);
      expect(pins.count, 2);
      expect(pins.hasTrophy('PPSA02002', 3), isTrue);
      expect(pins.hasGame('PPSA01001'), isTrue);
      expect(pins.full, isFalse);
      expect(ShowcasePins.of(null).count, 0);
    });

    test('adding stops at six in all; taking one off makes room again', () {
      var pins = ShowcasePins.of(showcase);
      for (final id in [4, 5, 6]) {
        pins = pins.toggleTrophy('PPSA02002', id)!;
      }
      pins = pins.toggleGame('PPSA07007')!;
      expect(pins.count, 6);
      expect(pins.full, isTrue);
      expect(pins.toggleTrophy('PPSA02002', 7), isNull, reason: 'a seventh pin is refused');
      expect(pins.toggleGame('PPSA09009'), isNull);
      pins = pins.toggleGame('PPSA01001')!;
      expect(pins.count, 5);
      expect(pins.hasGame('PPSA01001'), isFalse);
      expect(pins.toggleGame('PPSA09009')?.count, 6);
    });

    test('a showcase saved before the shared limit is cut to six, trophies first', () {
      final old = Showcase.fromJson({
        'trophies': [
          for (var id = 0; id < 5; id++)
            {
              'titleId': 'PPSA02002',
              'trophyId': id,
              'gameNames': <String, String>{},
              'earnedAt': '2026-10-20T21:00:00Z',
            },
        ],
        'games': [
          for (final id in ['PPSA01001', 'PPSA03003', 'PPSA04004']) {'titleId': id, 'names': <String, String>{}},
        ],
      });
      final pins = ShowcasePins.of(old);
      expect(pins.count, 6);
      expect(pins.trophies.length, 5);
      expect(pins.games, ['PPSA01001']);
    });

    test('the body always carries both lists', () {
      expect(const ShowcasePins().toJson(), {'trophies': <Object>[], 'games': <Object>[]});
      expect(ShowcasePins.of(showcase).toJson(), {
        'trophies': [
          {'titleId': 'PPSA02002', 'trophyId': 3},
        ],
        'games': ['PPSA01001'],
      });
    });
  });

  group('client', () {
    late FakeTogether server;
    late TogetherAccount account;
    late Profiles profiles;

    setUp(() async {
      server = await FakeTogether.start();
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      profiles = Profiles(account);
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('a profile page carries its look', () async {
      server.profiles['ana'] = {
        'userId': 'u-ana',
        'handle': 'ana',
        'displayName': 'Ana',
        'cover': null,
        'accent': 'coral',
        'theme': nightDrive,
      };
      final page = await profiles.page('ana');
      expect(page.profile.look.theme?.name, 'Night Drive');
      expect(page.profile.look.accentHex, '#ff8066');
    });

    test('saving the showcase: PUT /me/showcase with both lists, the showcase back', () async {
      server.libraries['utku'] = [
        {
          'titleId': 'PPSA01001',
          'names': {'en': 'Orbit Runner'},
          'secondsPlayed': 60,
        },
      ];
      final saved = await profiles.saveShowcase(const ShowcasePins(games: ['PPSA01001']));
      expect(server.callsTo('me/showcase', method: 'PUT').single.body, {
        'trophies': <Object>[],
        'games': ['PPSA01001'],
      });
      expect(saved.games!.single.name('en'), 'Orbit Runner');
    });

    test('more than six is never sent; the server refusing is an error', () async {
      final seven = ShowcasePins(games: [for (var n = 1; n <= 7; n++) 'PPSA0${n}00$n']);
      await expectLater(profiles.saveShowcase(seven), throwsArgumentError);
      expect(server.callsTo('me/showcase', method: 'PUT'), isEmpty);
      server.answers['PUT me/showcase'] = FakeTogether.problem(400, 'bad_request');
      await expectLater(profiles.saveShowcase(const ShowcasePins()), throwsA(isA<TogetherProblem>()));
    });

    test('wearing a theme and taking it off: PATCH /me/look, the look back', () async {
      server.hubThemes.add(nightDrive);
      final worn = await profiles.wearTheme(nightDrive['id']! as String);
      expect(server.callsTo('me/look', method: 'PATCH').last.body, {'theme': nightDrive['id']});
      expect(worn.theme?.name, 'Night Drive');
      final off = await profiles.wearTheme(null);
      expect(server.callsTo('me/look', method: 'PATCH').last.body, {'theme': null});
      expect(off.theme, isNull);
    });

    test('an unknown theme or an older server: the error comes through', () async {
      await expectLater(
        profiles.wearTheme('00000000-0000-4000-8000-000000000000'),
        throwsA(isA<TogetherProblem>().having((problem) => problem.status, 'status', 400)),
      );
    });

    test('the themes to choose from: the popular ones', () async {
      server.hubThemes.add(nightDrive);
      final themes = await profiles.popularThemes();
      expect(server.calls.where((call) => call.path == 'themes?sort=popular&limit=24'), hasLength(1));
      expect(themes.single.name, 'Night Drive');
      expect(themes.single.thumb, nightDrive['thumb']);
    });

    test('/me says which theme the user wears', () async {
      server.me['theme'] = nightDrive;
      final socket = TogetherSocket(account: account);
      final self = SelfProfile(account: account, socket: socket);
      addTearDown(() {
        self.dispose();
        socket.dispose();
      });
      await self.refresh();
      expect(self.wornTheme?.name, 'Night Drive');
      server.me['theme'] = null;
      await self.refresh();
      expect(self.wornTheme, isNull);
      self.wornTheme = ProfileTheme.fromJson(nightDrive);
      self.clear();
      expect(self.wornTheme, isNull);
    });
  });
}
