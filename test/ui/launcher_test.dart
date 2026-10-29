import 'dart:io';

import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/file_links.dart';
import 'package:anyps5_desktop/core/font_download.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:anyps5_desktop/core/system_fonts.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_toolkit.dart';
import '../support/ui_support.dart';

void main() {
  late Fixture fixture;

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    fixture.dispose();
  });

  final shell = find.byType(LauncherShell);

  int indexOf(AppModel model, String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

  group('golden', () {
    testWidgets('home, cosmic, an installed game selected, another installing', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      model.progress[model.games[indexOf(model, 'PPSA03003')].id] = (InstallStep.copy, 0.45);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/home_cosmic.png'));
    });

    testWidgets('home, aurora, in Turkish, a locked game with the play button focused', (tester) async {
      fixture = makeFixture(theme: 1, language: Language.byCode('tr'));
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      expect(find.text('Kilidi Aç'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/home_aurora_tr.png'));
    });

    testWidgets('home, sunset, a game that failed and one that cannot be read', (tester) async {
      fixture = makeFixture(theme: 2);
      final model = fixture.model;
      model.failures[model.games[indexOf(model, 'PPSA02002')].id] =
          'relinker failed (3): relink: unsupported relocation';
      model.select(indexOf(model, 'PPSA02002'));
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/home_sunset_failed.png'));
    });

    testWidgets('library grid', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.open(Layer.library);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/library.png'));
    });

    testWidgets('settings, appearance', (tester) async {
      fixture = makeFixture(theme: 2);
      final model = fixture.model;
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/settings.png'));
    });

    testWidgets('game settings', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.gameSettings);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/game_settings.png'));
    });

    testWidgets('controls, waiting for a key', (tester) async {
      fixture = makeFixture(theme: 1);
      final model = fixture.model;
      model.open(Layer.controls);
      // Past gyro aiming to the second pad action.
      model.handle(Command.down);
      model.handle(Command.down);
      model.handle(Command.select);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/controls.png'));
    });

    testWidgets('onboarding: language, theme and toolkit steps', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_language.png'));
      await press(tester, LogicalKeyboardKey.enter);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_theme.png'));
      model.onboardingStep = 3;
      model.engine.latest = sampleRelease('0.1.3');
      model.refresh();
      await settle(tester);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_toolkit.png'));
    });

    testWidgets('onboarding: the engine downloading, in Turkish', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false, theme: 1, language: Language.byCode('tr'));
      final model = fixture.model;
      model.onboardingStep = 3;
      final release = sampleRelease('0.1.3');
      final package = release.packageFor(model.system)!;
      model.engine
        ..latest = release
        ..downloading = package
        ..progress = ToolkitProgress(ToolkitPhase.download, (package.size * 0.42).round(), package.size);
      await pumpLauncher(tester, model);
      expect(find.text('AnyPS5 motorunu indir'), findsOneWidget);
      expect(find.text('Kendi klasörüm var'), findsOneWidget);
      expect(find.textContaining('/ 106'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_engine_download_tr.png'));
      model.engine
        ..downloading = null
        ..progress = null;
    });

    testWidgets('settings: the AnyPS5 engine', (tester) async {
      fixture = makeFixture(withToolkit: false);
      final model = fixture.model;
      // Two downloaded engines, the newer one in use.
      for (final version in ['0.1.2', '0.1.3']) {
        makeFakeToolkit(p.join(model.paths.toolkits, version), version: 'upstream-v$version');
      }
      model.engine.refresh();
      model.engine
        ..latest = sampleRelease('0.1.3')
        ..releases = [sampleRelease('0.1.4-rc1', prerelease: true), sampleRelease('0.1.3'), sampleRelease('0.1.2')];
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      for (var tab = 0; tab < 2; tab++) {
        await press(tester, LogicalKeyboardKey.keyE);
      }
      expect(model.panelCategories()[model.panelCategory].id, 'engine');
      expect(find.text('Check for engine updates'), findsOneWidget);
      expect(find.text('v0.1.4-rc1 · Pre-release'), findsOneWidget);
      expect(find.text('Downloaded · select to use'), findsOneWidget);
      expect(find.text('Delete other versions'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/settings_engine.png'));
    });

    testWidgets('settings: fonts', (tester) async {
      fixture = makeFixture(builtInFonts: p.absolute(SystemFonts.assetFolder), cjkFonts: FontArchive.notoSansCjk);
      final model = fixture.model;
      model.open(Layer.settings);
      model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'fonts'));
      await pumpLauncher(tester, model);
      expect(find.text('Noto Sans · Built in'), findsOneWidget);
      expect(find.text('Download Japanese, Chinese and Korean Now'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/settings_fonts.png'));
    });

    testWidgets('trophies', (tester) async {
      fixture = makeFixture(theme: 1);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.trophies);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/trophies.png'));
    });

    testWidgets('a new game copied in: its toast with the icon', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final orbit = model.games[indexOf(model, 'PPSA01001')];
      model.select(indexOf(model, 'PPSA01001'));
      model.show(T.format('newGame', [orbit.name]), icon: orbit.icon);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/new_game_toast.png'));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a phone asking to pair', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.pairing = const PairingRequest(id: 'r', deviceName: "Utku's iPhone", code: '4071');
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/pairing.png'));
    });
  });

  group('keyboard', () {
    testWidgets('an unlock that would copy asks first; Enter and the arrows answer it', (tester) async {
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      addTearDown(() => FileLinks.calls = FileLinks.system);
      fixture = makeFixture(system: HostSystem.windows);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      model.sizes[model.selectedGame!.id] = 52000000000;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.copyWarning);
      expect(find.text(T.text('copyWarningTitle')), findsOneWidget);
      expect(find.textContaining('52.0 GB'), findsWidgets);
      expect(find.text(T.text('copyFixFolder')), findsOneWidget);
      expect(find.text(T.text('copyFixDeveloperMode')), findsOneWidget);
      expect(find.text(T.text('copyAnyway')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(fixture.opened, [Uri.parse('ms-settings:developers')]);
      expect(model.overlay, isNull);
      expect(find.text(T.text('copyFixDeveloperModeThen')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('arrows move the tiles and the focus, Escape comes back', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      await pumpLauncher(tester, model);
      expect(model.selected, 0);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.selected, 1);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.selected, 2);
      await press(tester, LogicalKeyboardKey.keyQ);
      expect(model.selected, 1);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(model.focus, const HomeFocus.actions(0));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.focus, const HomeFocus.actions(1), reason: 'Orbit Runner has trophies');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.focus, const HomeFocus.actions(2));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.gameSettings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.focus, HomeFocus.tiles);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.focus, const HomeFocus.top(1));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.settings);
    });

    testWidgets('Escape on the home screen asks "Quit AnyPS5?", Cancel first; elsewhere it keeps its meaning', (
      tester,
    ) async {
      final quits = <int>[];
      fixture = makeFixture(quit: quits.add);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, Layer.confirmQuit);
      expect(model.panelCategories().single.rows.map((row) => row.id), ['cancel', 'quit']);
      expect(model.panelRow, 0, reason: 'Cancel is where the focus starts: a second Enter does not quit');
      expect(find.text(T.text('quitQuestion')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, isNull);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull, reason: 'Escape on the question is Cancel');
      model.handle(Command.back);
      expect(model.overlay, isNull, reason: 'Circle on the home screen asks nothing');
      expect(quits, isEmpty);

      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.focus, HomeFocus.tiles, reason: 'from the top bar Escape still comes back to the games');
      expect(model.overlay, isNull);
      model.open(Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull, reason: 'a panel open: Escape closes it, as before');

      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(quits, [0]);
    });

    testWidgets('with no games, Up still reaches the top bar and its Settings', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      await pumpLauncher(tester, model);
      model.games = [];
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.focus, const HomeFocus.top(1));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(model.focus, HomeFocus.tiles);
    });

    testWidgets('settings: Q and E change the category, arrows change a value', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      expect(model.preferences.theme, 0);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.preferences.theme, 1, reason: 'the first row is the theme');
      expect(model.look, LookStyle.aurora);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.panelCategory, 1);
      // Library, the AnyPS5 engine, the fonts, Profiles, AnyTogether and the phones, then the
      // language.
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.panelCategories()[model.panelCategory].id, 'general');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(T.language, Language.byCode('tr'));
      expect(find.text('Dil'), findsWidgets);
    });

    testWidgets('game settings change and are kept per game', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final game = model.selectedGame!;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.keyO);
      expect(model.overlay, Layer.gameSettings);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.currentSettings(game).fullscreen, isTrue);
      final environment = model.currentSettings(game).environment(launcherLanguage: 1);
      expect(environment['ANYPS5_FULLSCREEN'], '1');
      // Window size is hidden in fullscreen; the next row is vertical sync.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.currentSettings(game).vsync, isFalse);
    });

    testWidgets('a pad action takes the next key pressed', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final game = model.selectedGame!;
      model.open(Layer.controls);
      await pumpLauncher(tester, model);
      // Gyro aiming comes first, then the pad's actions.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.capturing, PadAction.cross);
      expect(find.text(T.text('pressKey')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyZ);
      expect(model.capturing, isNull);
      expect(Controls.sources(PadAction.cross, model.currentSettings(game).controls!), ['KEY:Z']);
      expect(find.text('Z'), findsOneWidget);
    });

    testWidgets('a row moved to below the panel scrolls into view', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.open(Layer.controls);
      await pumpLauncher(tester, model);
      // Gyro aiming's row comes first, then the pad's actions.
      for (var row = 0; row < 23; row++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settle(tester);
      expect(model.panelRow, 23);
      final title = AppModel.padActionTitle(PadAction.values[22]);
      final rect = tester.getRect(find.text(title));
      expect(rect.top, greaterThan(0));
      expect(rect.bottom, lessThan(900));
      expect(
        tester.getRect(find.text(AppModel.padActionTitle(PadAction.cross))).bottom,
        lessThan(200),
        reason: 'the first rows scrolled away',
      );
    });

    testWidgets('the library picks a game', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.library);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, isNull);
      expect(model.selected, 2);
    });

    testWidgets('onboarding: language, theme, folder, toolkit, then the home screen', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false);
      final model = fixture.model;
      model.preferences.gamesFolders = [];
      model.games = [];
      await pumpLauncher(tester, model);
      expect(find.text('Welcome to AnyPS5'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(T.language, Language.byCode('tr'));
      expect(find.text("AnyPS5'e hoş geldin"), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 1);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.preferences.theme, 2);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 2);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(model.preferences.gamesFolders, isNotEmpty, reason: 'the picker answered');
      expect(model.games, hasLength(4));
      expect(model.onboardingChoice, 1);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 3);
      expect(model.onboardingChoice, 0, reason: 'the download is the first choice');
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 4, reason: 'offline or online last');
      expect(find.text('Çevrimdışı Oyna'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.preferences.onboarded, isTrue);
      expect(model.profiles.book.profiles.single.mode.name, 'offline');
      expect(find.text('Oyunlar'), findsOneWidget);
    });

    testWidgets('a locked game without a toolkit says so; with one it is queued', (tester) async {
      fixture = makeFixture(withToolkit: false);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.toast, T.text('noToolkit'));
      expect(find.text(T.text('noToolkit')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(model.toast, isNull);
    });

    testWidgets('the trophy button opens the trophies; L1 and R1 leave them on a game without', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      await pumpLauncher(tester, model);
      expect(find.text('2/5'), findsOneWidget);
      expect(model.actionCount, 3);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.trophies);
      expect(find.text('Liftoff'), findsOneWidget);
      expect(find.text(T.text('trophyHidden')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.overlay, isNull, reason: 'the next game has no trophies');
      expect(model.focus, const HomeFocus.actions(1), reason: 'the settings button of a game without trophies');
    });

    testWidgets('the pairing card answers with Enter', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.pairing = const PairingRequest(id: 'r', deviceName: 'Phone', code: '1234');
      await pumpLauncher(tester, model);
      expect(find.text('1'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.pairing, isNull);
    });
  });

  test('the fixture writes nothing outside its folder', () {
    fixture = makeFixture();
    expect(fixture.model.persist, isFalse);
    expect(fixture.model.paths.config, startsWith(fixture.temp.path));
    expect(Directory(fixture.model.paths.config).existsSync(), isFalse);
  });
}
