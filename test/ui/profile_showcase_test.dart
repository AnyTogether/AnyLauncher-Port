import 'package:anyps5_desktop/core/together/profile_look.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme_hub_model.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_audio.dart';
import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// Profile themes and the showcase in the launcher, against the fake AnyTogether: the look a
/// profile wears, Edit showcase (six pins in all) and Profile theme on the user's own profile,
/// and Wear on my profile in the Theme Hub. (Their screens are in
/// profile_showcase_interface_test.dart.)
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakeAudio audio;

  const nightDrive = {
    'id': '7d0f4a52-3b1e-4c8a-9f61-2a5b8c9d0e11',
    'name': 'Night Drive',
    'colors': {'deep': '#05060f', 'middle': '#2a1458', 'bright': '#ff5fa2', 'accent': '#ffb347'},
    'preview': 'https://anytogether.net/api/v1/themes/7d0f/preview.webp?v=2',
    'thumb': 'https://anytogether.net/api/v1/themes/7d0f/thumb.webp?v=2',
    'maker': {'handle': 'ana', 'displayName': 'Ana'},
  };
  const meadow = {
    'id': '1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d',
    'name': 'Meadow',
    'colors': {'deep': '#03140a', 'middle': '#0f4d2a', 'bright': '#b8f28c', 'accent': '#5cebbd'},
    'preview': 'https://anytogether.net/api/v1/themes/1b2c/preview.webp?v=1',
    'thumb': 'https://anytogether.net/api/v1/themes/1b2c/thumb.webp?v=1',
    'maker': null,
  };

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  List<PanelRow> rows() => model.panelCategories()[model.panelCategory].rows;
  PanelRow row(String id) => rows().firstWhere((row) => row.id == id);
  void toggle(String id) => (row(id).kind as ToggleRow).set(!(row(id).kind as ToggleRow).value);

  Map<String, dynamic> trophy(String titleId, int id, String name) => {
    'titleId': titleId,
    'gameNames': {'en': titleId == 'PPSA02002' ? 'Neon Alley' : 'Orbit Runner'},
    'trophyId': id,
    'grade': 'bronze',
    'hidden': false,
    'texts': {
      'en': {'name': name},
    },
    'earnedAt': '2026-10-2${id % 10}T21:00:00Z',
    'rarity': 0.4,
    'rarityLabel': 'common',
  };

  setUp(() async {
    server = await FakeTogether.start();
    server.profiles['utku'] = {
      'userId': 'u-me',
      'handle': 'utku',
      'displayName': 'Utku',
      'friendship': 'me',
      'cover': null,
      'accent': null,
      'theme': null,
    };
    server.trophyLists['utku'] = [for (var id = 1; id <= 5; id++) trophy('PPSA02002', id, 'Trophy $id')];
    server.libraries['utku'] = [
      {
        'titleId': 'PPSA01001',
        'names': {'en': 'Orbit Runner'},
        'secondsPlayed': 3600,
      },
      {
        'titleId': 'PPSA02002',
        'names': {'en': 'Neon Alley'},
        'secondsPlayed': 7200,
      },
      {
        'titleId': 'PPSA07007',
        'names': {'en': 'Harbor Lights'},
        'secondsPlayed': 600,
      },
    ];
    // A trophy pinned before that the recent list no longer has: it stays pickable.
    server.showcases['utku'] = {
      'trophies': [trophy('PPSA01001', 9, 'Long Ago')],
      'games': <Object>[],
    };
    server.hubThemes.addAll([nightDrive, meadow]);
    audio = FakeAudio();
    fixture = makeFixture(together: server.base, audio: audio);
    model = fixture.model;
    await model.startAudio();
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.friends.loaded && model.together.hub.self.loaded);
  });

  tearDown(() async {
    ThemeHubModel.basesInstead = null;
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  group('the look', () {
    test("someone's profile wears their theme; an older server's has no look", () async {
      server.profiles['bora'] = {
        'userId': 'u-bora',
        'handle': 'bora',
        'displayName': 'Bora',
        'friendship': 'friends',
        'theme': nightDrive,
      };
      await model.together.openProfile('bora');
      expect(model.together.profile!.profile.look.theme?.name, 'Night Drive');
      expect(model.together.profileAccent?.toARGB32(), 0xFFFFB347);
      expect(model.together.profileActions, [ProfileAction.theme, ProfileAction.compare]);
      expect(model.together.profileIndex, 1, reason: 'Compare trophies is still first to be chosen');
      model.handle(launcher.Command.select);
      expect(model.overlay, Layer.compare);

      server.profiles['cem'] = {'userId': 'u-cem', 'handle': 'cem', 'displayName': 'Cem', 'friendship': 'none'};
      await model.together.openProfile('cem');
      expect(model.together.profile!.profile.look.empty, isTrue);
      expect(model.together.profileAccent, isNull);
      expect(model.together.profileActions, [ProfileAction.compare]);
    });

    test('Theme: name goes to the theme in the Hub, and back to the profile', () async {
      server.profiles['bora'] = {
        'userId': 'u-bora',
        'handle': 'bora',
        'displayName': 'Bora',
        'friendship': 'friends',
        'theme': nightDrive,
      };
      await model.together.openProfile('bora');
      model.handle(launcher.Command.up);
      expect(model.together.profileIndex, 0);
      model.handle(launcher.Command.select);
      expect(model.overlay, Layer.themes);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.profile);
      expect(model.together.profile?.profile.handle, 'bora');
      expect(model.together.profileIndex, 0);
    });
  });

  group('Edit showcase', () {
    Future<void> openEditor() async {
      await model.together.openMyProfile();
      expect(model.together.profileActions, [ProfileAction.editShowcase, ProfileAction.profileTheme]);
      expect(model.together.profileIndex, 0);
      model.handle(launcher.Command.select);
      expect(model.overlay, Layer.showcaseEdit);
    }

    test('trophies and games to pin together, the pinned one kept, "n of 6 pinned"', () async {
      await openEditor();
      expect(model.panelCategories().single.title, '1 of 6 pinned');
      final ids = rows().map((row) => row.id).toList();
      expect(ids.first, 'pins-trophies');
      expect(row('pins-trophies').title, 'Trophies');
      expect((row('pins-trophies').kind as InfoRow).text, 'Pin up to six trophies and games.');
      expect(ids.indexOf('pin-trophy-PPSA01001-9'), 1, reason: 'pinned before, kept first');
      expect((row('pin-trophy-PPSA01001-9').kind as ToggleRow).value, isTrue);
      expect(row('pin-trophy-PPSA01001-9').title, 'Long Ago');
      expect(row('pin-trophy-PPSA02002-1').detail, contains('Neon Alley'));
      expect(ids, containsAllInOrder(['pins-games', 'pin-game-PPSA01001', 'pin-game-PPSA02002', 'pin-game-PPSA07007']));
      expect(model.panelRow, 1, reason: 'the keys start on the first pin, past the heading');
    });

    test('each change is saved with both lists; the profile shows it after', () async {
      await openEditor();
      toggle('pin-game-PPSA02002');
      await until(() => server.callsTo('me/showcase', method: 'PUT').isNotEmpty);
      expect(server.callsTo('me/showcase', method: 'PUT').last.body, {
        'trophies': [
          {'titleId': 'PPSA01001', 'trophyId': 9},
        ],
        'games': ['PPSA02002'],
      });
      expect(model.panelCategories().single.title, '2 of 6 pinned');
      toggle('pin-trophy-PPSA01001-9');
      await until(() => server.callsTo('me/showcase', method: 'PUT').length == 2);
      expect(server.callsTo('me/showcase', method: 'PUT').last.body, {
        'trophies': <Object>[],
        'games': ['PPSA02002'],
      });
      await until(() => model.together.profile!.showcase.value?.games?.length == 1);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.profile);
      expect(model.together.profile!.showcase.value!.games!.single.titleId, 'PPSA02002');
      expect(model.together.profileIndex, 0, reason: 'back on Edit showcase');
    });

    test('six is the most: a seventh is refused with the reason, nothing sent', () async {
      await openEditor();
      for (final id in [
        'pin-trophy-PPSA02002-1',
        'pin-trophy-PPSA02002-2',
        'pin-game-PPSA01001',
        'pin-game-PPSA02002',
      ]) {
        toggle(id);
      }
      toggle('pin-game-PPSA07007');
      await until(() => model.panelCategories().single.title == '6 of 6 pinned');
      await until(() => !model.together.savingPins);
      final sent = server.callsTo('me/showcase', method: 'PUT').length;
      toggle('pin-trophy-PPSA02002-3');
      expect((row('pin-trophy-PPSA02002-3').kind as ToggleRow).value, isFalse);
      expect(model.toast, 'Pin up to six trophies and games.');
      expect(audio.cues.last, 'bump');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.callsTo('me/showcase', method: 'PUT').length, sent);
      for (final call in server.callsTo('me/showcase', method: 'PUT')) {
        final body = call.body;
        expect((body['trophies'] as List).length + (body['games'] as List).length, lessThanOrEqualTo(6));
      }
    });

    test('a refused save goes back to what was saved, and says so', () async {
      server.answers['PUT me/showcase'] = FakeTogether.problem(400, 'bad_request');
      await openEditor();
      toggle('pin-game-PPSA07007');
      await until(() => model.toast == 'The showcase could not be saved');
      expect((row('pin-game-PPSA07007').kind as ToggleRow).value, isFalse);
      expect(model.panelCategories().single.title, '1 of 6 pinned');
    });

    test('a friend\'s profile offers no editing', () async {
      server.profiles['bora'] = {'userId': 'u-bora', 'handle': 'bora', 'displayName': 'Bora', 'friendship': 'friends'};
      await model.together.openProfile('bora');
      expect(model.together.profileActions, isNot(contains(ProfileAction.editShowcase)));
      model.together.openShowcaseEditor();
      expect(model.overlay, Layer.profile);
    });
  });

  group('Profile theme', () {
    Future<void> openChooser() async {
      await model.together.openMyProfile();
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      expect(model.overlay, Layer.profileTheme);
      await until(() => model.together.themeChoices != null);
    }

    test('the popular themes; choosing one wears it, the profile shows it', () async {
      await openChooser();
      expect(model.panelCategories().single.title, 'AnyPS5 Hub');
      expect(rows().map((row) => row.id), ['theme-${nightDrive['id']}', 'theme-${meadow['id']}']);
      expect(row('theme-${nightDrive['id']}').detail, 'by Ana');
      (row('theme-${nightDrive['id']}').kind as ActionRow).run();
      await until(() => model.overlay == Layer.profile);
      expect(server.callsTo('me/look', method: 'PATCH').single.body, {'theme': nightDrive['id']});
      expect(model.together.profile!.profile.look.theme?.name, 'Night Drive');
      expect(model.together.hub.self.wornTheme?.id, nightDrive['id']);
      expect(model.toast, 'Night Drive is on your profile now');
      expect(model.together.profileIndex, 2, reason: 'back on Profile theme, after Theme: Night Drive');
    });

    test('Take it off, for the one worn', () async {
      server.profiles['utku']!['theme'] = nightDrive;
      server.me['theme'] = nightDrive;
      await openChooser();
      expect(rows().first.id, 'theme-off');
      expect(rows().first.title, 'Take it off');
      expect(rows().first.detail, 'Theme: Night Drive');
      expect(row('theme-${nightDrive['id']}').detail, 'On your profile');
      (rows().first.kind as ActionRow).run();
      await until(() => model.overlay == Layer.profile);
      expect(server.callsTo('me/look', method: 'PATCH').single.body, {'theme': null});
      expect(model.together.profile!.profile.look.theme, isNull);
      expect(model.toast, 'Your profile theme is off');
    });

    test('a server that refuses: a plain failure, the look as it was', () async {
      server.answers['PATCH me/look'] = FakeTogether.problem(404, 'not_found');
      await openChooser();
      (row('theme-${meadow['id']}').kind as ActionRow).run();
      await until(() => model.toast == 'The profile theme could not be changed');
      expect(model.overlay, Layer.profileTheme);
      expect(model.together.profile!.profile.look.theme, isNull);
    });

    test('the list fails to come: Try again', () async {
      server.answers['themes?sort=popular&limit=24'] = FakeTogether.problem(500, 'internal');
      await openChooser();
      expect(rows().single.id, 'theme-retry');
      server.answers.remove('themes?sort=popular&limit=24');
      (rows().single.kind as ActionRow).run();
      await until(() => rows().length == 2);
    });

    test('in Turkish', () async {
      T.language = Language.byCode('tr');
      await openChooser();
      expect(rows().first.detail, 'yapan: Ana');
    });
  });

  group('the Theme Hub', () {
    test('Wear on my profile under a Hub theme, Take it off under the one worn', () async {
      ThemeHubModel.basesInstead = [server.base.resolve('/api/v1/hub/')];
      server.answers['hub/themes.json'] = (
        200,
        {
          'themes': [
            for (final theme in [nightDrive, meadow])
              {
                'id': theme['id'],
                'name': theme['name'],
                'author': 'Ana',
                'version': 1,
                ...(theme['colors']! as Map<String, dynamic>),
                'package': 'https://anytogether.net/x.anyps5theme',
              },
            // One from the GitHub folder: no server id, nothing to wear.
            {'id': 'forest-hub', 'name': 'Forest', 'package': 'forest.anyps5theme'},
          ],
        },
      );
      model.together.hub.self.wornTheme = ProfileTheme.fromJson(meadow);
      model.open(Layer.themes);
      await until(() => model.hubList is HubShown);
      final ids = rows().map((row) => row.id).toList();
      expect(ids.indexOf('hub-wear-${nightDrive['id']}'), ids.indexOf('hub-${nightDrive['id']}') + 1);
      expect(row('hub-wear-${nightDrive['id']}').title, 'Wear on my profile');
      expect(row('hub-wear-${meadow['id']}').title, 'Take it off');
      expect(ids, isNot(contains('hub-wear-forest-hub')));
      (row('hub-wear-${nightDrive['id']}').kind as ActionRow).run();
      await until(() => model.together.hub.self.wornTheme?.id == nightDrive['id']);
      expect(server.callsTo('me/look', method: 'PATCH').single.body, {'theme': nightDrive['id']});
      expect(row('hub-wear-${nightDrive['id']}').title, 'Take it off');
      expect(row('hub-wear-${meadow['id']}').title, 'Wear on my profile');
      expect(model.overlay, Layer.themes, reason: 'the Hub stays open');
    });

    test('signed out: no Wear on my profile', () async {
      ThemeHubModel.basesInstead = [server.base.resolve('/api/v1/hub/')];
      server.answers['hub/themes.json'] = (
        200,
        {
          'themes': [
            {'id': nightDrive['id'], 'name': 'Night Drive', 'package': 'https://anytogether.net/x.anyps5theme'},
          ],
        },
      );
      await model.together.signOut();
      model.open(Layer.themes);
      await until(() => model.hubList is HubShown);
      expect(rows().map((row) => row.id), isNot(contains('hub-wear-${nightDrive['id']}')));
    });
  });

  test('signing out closes the editors', () async {
    await model.together.openMyProfile();
    model.handle(launcher.Command.select);
    expect(model.overlay, Layer.showcaseEdit);
    await model.together.signOut();
    expect(model.overlay, isNull);
    expect(model.together.showcasePins, isNull);
  });

  test('ProfilePage keeps the rest when the look or the showcase changes', () {
    const page = ProfilePage(
      profile: TogetherProfile(userId: 'u', handle: 'h', displayName: 'H', friendship: 'me'),
      library: SectionShown([]),
      trophies: SectionPrivate(),
      detailsPrivate: true,
    );
    final changed = page.copyWith(profile: page.profile.withLook(const ProfileLook(accent: 'gold')));
    expect(changed.profile.look.accentHex, '#ffcc5c');
    expect(changed.trophies, isA<SectionPrivate<List<EarnedTrophy>>>());
    expect(changed.detailsPrivate, isTrue);
    expect(changed.profile.friendship, 'me');
  });
}
