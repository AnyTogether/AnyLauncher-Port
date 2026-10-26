import 'dart:io';

import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/profiles/profile_saves.dart';
import 'package:anyps5_desktop/core/profiles/profiles.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// Profiles in the launcher: the first start's mode, the migration of a launcher set up before,
/// "Who's playing?", switching (never over a game), each profile's settings, saves and session,
/// and the friends-only names.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  // The widget binding answers every HTTP request with 400; these talk to a local fake server.
  setUp(() => HttpOverrides.global = null);

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  SavedSession session(String id, String handle, String name) => SavedSession(
    accessToken: 'access-$id',
    accessExpiry: DateTime.now().add(const Duration(minutes: 10)),
    refreshToken: 'refresh-$id',
    user: TogetherUser(id: id, handle: handle, displayName: name),
  );

  group('migration', () {
    test('a launcher set up before profiles is its first profile: no welcome, no picker', () {
      fixture = makeFixture();
      final model = fixture.model;
      expect(model.profiles.book.profiles, hasLength(1));
      expect(model.profiles.book.profiles.single.id, LauncherProfile.legacyId);
      expect(model.profiles.launchScreen, const LaunchScreen.home(LauncherProfile.legacyId));
      model.startProfiles();
      expect(model.overlay, isNull);
    });

    test('a signed-in launcher keeps its session in the first profile, online', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      fixture = makeFixture(
        together: server.base,
        togetherStore: MemoryTokenStore(session('u-me', 'utku', 'Utku Halis')),
      );
      final model = fixture.model;
      await model.together.start();
      final profile = model.profiles.book.profiles.single;
      expect(profile.mode, ProfileMode.online);
      expect(profile.account?.handle, 'utku');
      expect(model.together.signedIn, isTrue);
      model.dispose();
    });
  });

  group('the first start', () {
    test('offline: the last step makes the profile and goes home', () {
      fixture = makeFixture(onboarded: false);
      final model = fixture.model;
      expect(model.profiles.book.profiles, isEmpty);
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 0;
      model.handle(Command.select);
      expect(model.preferences.onboarded, isTrue);
      expect(model.profiles.book.profiles.single.mode, ProfileMode.offline);
      expect(model.profiles.book.profiles.single.name, 'Utku');
    });

    test('online: the sign-in comes up, and signing in makes the profile and goes home', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      fixture = makeFixture(onboarded: false, together: server.base);
      final model = fixture.model;
      model.onboardingStep = 4;
      model.handle(Command.right);
      model.handle(Command.select);
      await until(() => model.overlay == Layer.signIn);
      expect(model.panelCategories().single.rows.map((row) => row.id), containsAll(['together-email', 'together-web']));
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.preferences.onboarded);
      final profile = model.profiles.book.profiles.single;
      expect(profile.mode, ProfileMode.online);
      expect(profile.account?.handle, 'utku');
      expect(model.overlay, isNull);
      model.dispose();
    });

    test('back on the sign-in goes back to the cards, nothing made', () async {
      fixture = makeFixture(onboarded: false);
      final model = fixture.model;
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 1;
      model.handle(Command.select);
      await until(() => model.overlay == Layer.signIn);
      model.handle(Command.back);
      await until(() => model.overlay == null);
      expect(model.profiles.book.profiles, isEmpty);
      expect(model.preferences.onboarded, isFalse);
    });
  });

  group('switching', () {
    test(
      'Options/Start on Home opens the menu with Switch Profile and online or offline; Triangle stays the game\'s',
      () {
        fixture = makeFixture();
        final model = fixture.model;
        model.padCommand(PadCommand.options);
        expect(model.overlay, Layer.gameSettings);
        model.closeOverlay();
        model.padCommand(PadCommand.menu);
        expect(model.overlay, Layer.profileMenu);
        expect(model.panelCategories().single.rows.map((row) => row.id), [
          'menu-game',
          'menu-switch',
          'menu-mode',
          'menu-profiles',
        ]);
      },
    );

    test('Switch Profile in the PS menu opens the picker; not while a game starts', () async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      model.homeHeld();
      final row = model.panelCategories().single.rows.firstWhere((row) => row.id == 'switchProfile');
      (row.kind as ActionRow).run();
      expect(model.overlay, Layer.profilePicker);
      model.closeOverlay();
      model.starting = model.games.first;
      model.homeHeld();
      ((model.panelCategories().single.rows.firstWhere((row) => row.id == 'switchProfile')).kind as ActionRow).run();
      expect(model.overlay, isNot(Layer.profilePicker));
      expect(model.toast, 'Close ${model.games.first.name} first');
      final selin = model.profiles.book.profiles.last.id;
      await model.switchProfile(selin);
      expect(model.currentProfile?.name, 'Utku', reason: 'never over a game');
    });

    test('each profile has its own settings, and comes back with them', () async {
      fixture = makeFixture();
      final model = fixture.model;
      model.preferences
        ..theme = 2
        ..sounds = false;
      final selin = model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      await model.switchProfile(selin.id);
      expect(model.currentProfile?.name, 'Selin');
      expect(model.preferences.theme, 0, reason: 'a new profile starts from the defaults');
      expect(model.preferences.sounds, isTrue);
      expect(model.preferences.profileName, 'Selin');
      expect(model.preferences.gamesFolder, isNotNull, reason: "the computer's settings stay");
      model.preferences.theme = 1;
      await model.switchProfile(LauncherProfile.legacyId);
      expect(model.preferences.theme, 2);
      expect(model.preferences.sounds, isFalse);
      await model.switchProfile(selin.id);
      expect(model.preferences.theme, 1);
    });

    test("each profile's saves and trophies are its own", () async {
      fixture = makeFixture();
      final model = fixture.model;
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      expect(model.trophies[orbit.id]?.unlockedCount, 2);
      final selin = model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      await model.switchProfile(selin.id);
      expect(Directory(p.join(installed, '_trophy')).existsSync(), isFalse);
      expect(model.trophies[orbit.id]?.unlockedCount ?? 0, 0, reason: "Selin has none of Utku's trophies");
      expect(ProfileSaves.owner(installed, legacyOwner: LauncherProfile.legacyId), selin.id);
      await model.switchProfile(LauncherProfile.legacyId);
      expect(model.trophies[orbit.id]?.unlockedCount, 2);
    });

    test('a new online profile signs in with its own session; the first one keeps its own', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      final first = MemoryTokenStore(session('u-me', 'utku', 'Utku'));
      final others = <String, MemoryTokenStore>{};
      fixture = makeFixture(
        together: server.base,
        togetherStore: first,
        togetherStoreFor: (id) => others[id] ??= MemoryTokenStore(),
      );
      final model = fixture.model;
      await model.together.start();
      expect(model.together.user?.handle, 'utku');
      model.openAddProfile();
      model.profileFlow.modeChoice = 1;
      model.handle(Command.select);
      await until(() => model.overlay == Layer.signIn);
      expect(model.together.signedIn, isFalse, reason: 'the new profile starts signed out');
      server.me = {'id': 'u-selin', 'handle': 'selin', 'displayName': 'Selin'};
      model.together.email = 'selin@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.overlay == null);
      expect(model.currentProfile?.name, 'Selin');
      expect(model.together.user?.handle, 'selin');
      expect(first.session?.user.handle, 'utku', reason: "signing Selin in did not touch Utku's session");
      expect(others.values.single.session?.user.handle, 'selin');
      await model.switchProfile(LauncherProfile.legacyId);
      await until(() => model.together.user?.handle == 'utku');
      expect(others.values.single.session?.user.handle, 'selin', reason: 'switching signs nobody out');
      model.dispose();
    });

    test('going offline keeps the session; going online brings it back', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      final store = MemoryTokenStore(session('u-me', 'utku', 'Utku'));
      fixture = makeFixture(together: server.base, togetherStore: store);
      final model = fixture.model;
      await model.together.start();
      await model.toggleProfileMode();
      expect(model.together.signedIn, isFalse);
      expect(model.currentProfile?.mode, ProfileMode.offline);
      expect(store.session, isNotNull, reason: 'offline is not a sign-out');
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'together');
      expect(model.panelCategories()[model.panelCategory].rows.map((row) => row.id), [
        'together-offline',
        'together-go-online',
      ]);
      await model.toggleProfileMode();
      await until(() => model.together.signedIn);
      expect(model.currentProfile?.mode, ProfileMode.online);
      model.dispose();
    });

    test('deleting asks first, backs the saves up and keeps the others', () async {
      fixture = makeFixture();
      final model = fixture.model;
      final selin = model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      await model.switchProfile(selin.id);
      await model.switchProfile(LauncherProfile.legacyId);
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'profiles');
      List<PanelRow> rows() => model.panelCategories()[model.panelCategory].rows;
      (rows().firstWhere((row) => row.id == 'profile-delete-${selin.id}').kind as ActionRow).run();
      expect(rows().map((row) => row.id), contains('profile-delete-${selin.id}-cancel'));
      (rows().firstWhere((row) => row.id == 'profile-delete-${selin.id}-yes').kind as ActionRow).run();
      await until(() => model.profiles.book.profiles.length == 1);
      expect(model.toast, 'Selin was deleted');
    });
  });

  group('friends-only names', () {
    test('a friend shows with their private name and the handle beside', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      server.friend('f1', 'mira', 'NightOwl', presence: {'state': 'online'});
      server.friends.last['privateName'] = 'Mira Kaya';
      server.friend('f2', 'sol', 'Sol');
      fixture = makeFixture(together: server.base);
      final model = fixture.model;
      await model.together.start();
      await model.together.account.startEmail('utku@example.com');
      await model.together.account.verifyEmail(server.emailCode);
      await model.together.hub.friends.refresh();
      final rows = model.together.friendRows();
      final mira = rows.firstWhere((row) => row.id == 'friend-f1');
      expect(mira.title, 'Mira Kaya');
      expect(mira.detail, startsWith('@mira · NightOwl'));
      expect(rows.firstWhere((row) => row.id == 'friend-f2').title, 'Sol');
      model.dispose();
    });
  });

  group('golden', () {
    testWidgets("who's playing", (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles
        ..add(
          name: 'Mira',
          mode: ProfileMode.online,
          account: const ProfileAccount(userId: 'u7', handle: 'mira.k'),
        )
        ..add(name: 'Deniz', mode: ProfileMode.offline);
      model.openProfilePicker(atLaunch: true);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_picker.png'));
    });

    testWidgets('the first start: offline or online, in Turkish', (tester) async {
      fixture = makeFixture(onboarded: false, language: Language.turkish);
      final model = fixture.model;
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 1;
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_welcome_tr.png'));
    });

    testWidgets('the Options menu', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      model.padCommand(PadCommand.menu);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_menu.png'));
    });

    testWidgets('Settings › Profiles', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles.add(
        name: 'Selin',
        mode: ProfileMode.online,
        account: const ProfileAccount(userId: 'u2', handle: 'selin'),
      );
      model.openProfileSettings();
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_settings.png'));
    });

    testWidgets('Add Profile', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.openAddProfile();
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_add.png'));
    });
  });
}
