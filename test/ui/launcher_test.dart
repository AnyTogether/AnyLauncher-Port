import 'dart:io';

import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
      fixture = makeFixture(theme: 1, language: Language.turkish);
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
      await press(tester, LogicalKeyboardKey.arrowRight);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_toolkit.png'));
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

    testWidgets('a phone asking to pair', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.pairing = const PairingRequest(id: 'r', deviceName: "Utku's iPhone", code: '4071');
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/pairing.png'));
    });
  });

  group('keyboard', () {
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
      // Library, AnyTogether and the phones, then the language.
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.panelCategories()[model.panelCategory].id, 'general');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(T.language, Language.turkish);
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
      for (var row = 0; row < 22; row++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settle(tester);
      expect(model.panelRow, 22);
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
      model.preferences.gamesFolder = null;
      model.games = [];
      await pumpLauncher(tester, model);
      expect(find.text('Welcome to AnyPS5'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(T.language, Language.turkish);
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
      expect(model.preferences.gamesFolder, isNotNull, reason: 'the picker answered');
      expect(model.games, hasLength(4));
      expect(model.onboardingChoice, 1);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 3);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.preferences.onboarded, isTrue);
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
