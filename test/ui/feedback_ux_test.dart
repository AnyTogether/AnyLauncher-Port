import 'dart:io';

import 'package:anyps5_desktop/core/desktop/launcher_window.dart';
import 'package:anyps5_desktop/core/gamepad/guide_switch.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/gamepad/shortcuts.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../core/replay_buffer_test.dart' show FakeProcess;
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop, FakePads;

/// The window's full screen as asked.
class FakeWindow implements LauncherWindow {
  final List<bool> asked = [];

  @override
  Future<bool> setFullscreen(bool on) async {
    asked.add(on);
    return true;
  }
}

void main() {
  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
  });

  Future<void> until(bool Function() condition, {int tries = 500}) async {
    for (var index = 0; index < tries && !condition(); index++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  group('full screen', () {
    test('full screen at the first launch; the choice is kept after', () async {
      final window = FakeWindow();
      final fixture = makeFixture(window: window);
      final model = fixture.model;
      addTearDown(fixture.dispose);
      expect(model.preferences.launcherFullscreen, isNull);
      await model.applyLauncherWindow();
      expect(window.asked, [true]);
      await model.toggleFullscreen();
      expect(window.asked, [true, false]);
      expect(model.preferences.launcherFullscreen, isFalse);
      expect(Preferences.fromJson(model.preferences.toJson()).launcherFullscreen, isFalse);
      await model.applyLauncherWindow();
      expect(window.asked.last, isFalse, reason: 'the next start keeps the window');
    });

    testWidgets('F11 switches it; Settings › Appearance has it', (tester) async {
      final window = FakeWindow();
      final fixture = makeFixture(window: window);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.f11);
      expect(window.asked, [false], reason: 'full screen by default: F11 goes back to a window');
      model.open(Layer.settings);
      final appearance = model.panelCategories().first.rows.map((row) => row.id);
      expect(appearance, contains('fullscreen'));
      await settle(tester);
      expect(find.text('Full Screen'), findsWidgets);
    });
  });

  group('settings with a controller', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;

    setUp(() {
      pads = FakePads();
      fixture = makeFixture(pads: () => pads);
      model = fixture.model..startPads();
      model.open(Layer.settings);
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('← goes to the sections, ↑ ↓ change the section there, → goes back into its rows', () {
      expect(model.panelSections, isFalse);
      pads.press(PadButton.dpadLeft);
      expect(model.panelSections, isTrue);
      pads.press(PadButton.dpadDown);
      expect(model.panelCategory, 1);
      pads.press(PadButton.dpadDown);
      expect(model.panelCategory, 2);
      pads.press(PadButton.dpadUp);
      expect(model.panelCategory, 1);
      pads.press(PadButton.dpadRight);
      expect(model.panelSections, isFalse);
      pads.press(PadButton.dpadDown);
      expect(model.panelRow, greaterThan(0), reason: 'in the rows ↓ moves between rows');
      expect(model.panelCategory, 1);
    });

    test('the left stick does the same as the D-pad', () {
      pads.send!(const PadAxisEvent('pad', PadAxis.leftX, -0.9));
      pads.send!(const PadAxisEvent('pad', PadAxis.leftX, 0));
      expect(model.panelSections, isTrue);
      pads.send!(const PadAxisEvent('pad', PadAxis.leftY, 0.9));
      pads.send!(const PadAxisEvent('pad', PadAxis.leftY, 0));
      expect(model.panelCategory, 1);
    });

    test('L1 and R1 still change the section from anywhere; Circle on the sections closes', () {
      pads.press(PadButton.r1);
      expect(model.panelCategory, 1);
      pads.press(PadButton.dpadLeft);
      pads.press(PadButton.l1);
      expect(model.panelCategory, 0);
      pads.press(PadButton.east);
      expect(model.overlay, isNull);
    });

    test('a value row does not change when highlighted or on ← →; ✕ edits it, ✕ or ○ leaves', () {
      final theme = model.preferences.theme;
      expect(model.panelCategories().first.rows[model.panelRow].id, 'theme');
      pads.press(PadButton.dpadRight);
      expect(model.preferences.theme, theme, reason: '→ on the row changes nothing');
      expect(model.editingValue, isNull);
      pads.press(PadButton.south);
      expect(model.editingValue, 'theme');
      pads.press(PadButton.dpadRight);
      expect(model.preferences.theme, theme + 1);
      pads.press(PadButton.dpadLeft);
      expect(model.preferences.theme, theme);
      expect(model.panelSections, isFalse, reason: 'in edit mode ← is the value, not the sections');
      pads.press(PadButton.dpadRight);
      pads.press(PadButton.east);
      expect(model.editingValue, isNull);
      expect(model.overlay, Layer.settings, reason: 'Circle leaves edit mode, not the settings');
      expect(model.preferences.theme, theme + 1, reason: 'the value stays');
      pads.press(PadButton.dpadRight);
      expect(model.preferences.theme, theme + 1);
      pads.press(PadButton.south);
      pads.press(PadButton.south);
      expect(model.editingValue, isNull, reason: 'Cross leaves it too');
    });

    test('↓ in edit mode leaves it and moves on; a toggle still flips with ✕', () {
      pads.press(PadButton.south);
      expect(model.editingValue, 'theme');
      pads.press(PadButton.dpadDown);
      expect(model.editingValue, isNull);
      expect(model.panelRow, 1);
      final rows = model.panelCategories().first.rows;
      final toggle = rows.indexWhere((row) => row.kind is ToggleRow);
      while (model.panelRow < toggle) {
        pads.press(PadButton.dpadDown);
      }
      final before = (rows[toggle].kind as ToggleRow).value;
      pads.press(PadButton.south);
      expect((model.panelCategories().first.rows[toggle].kind as ToggleRow).value, !before);
    });

    test('the keyboard keeps its ways: → changes the value at once, ← on an action row changes the section', () {
      final theme = model.preferences.theme;
      model.usedKeyboard();
      model.command(Command.right);
      expect(model.preferences.theme, theme + 1);
      expect(model.editingValue, isNull);
      expect(model.panelSections, isFalse);
    });

    test('game settings: the window mode only changes in edit mode', () {
      model.closeOverlay();
      model.open(Layer.gameSettings);
      final game = model.selectedGame!;
      expect(model.panelCategories().first.rows.first.id, 'display');
      pads.press(PadButton.dpadRight);
      pads.press(PadButton.dpadLeft);
      expect(model.currentSettings(game).fullscreen, isFalse);
      pads.press(PadButton.south);
      pads.press(PadButton.dpadRight);
      expect(model.currentSettings(game).fullscreen, isTrue);
    });
  });

  group('input-aware hints', () {
    testWidgets('a controller hides the keys, the keys hide the controller\'s glyphs, live', (tester) async {
      final pads = FakePads();
      final fixture = makeFixture(pads: () => pads);
      addTearDown(fixture.dispose);
      final model = fixture.model..startPads();
      addTearDown(model.dispose);
      await pumpLauncher(tester, model);
      expect(model.inputMode, InputMode.keyboardMouse);
      expect(find.text('Enter'), findsOneWidget);
      expect(find.text('Q'), findsOneWidget);
      expect(find.byType(PadGlyphIcon), findsNothing, reason: 'no pad glyphs while the keys are in use');
      pads.press(PadButton.dpadDown);
      await settle(tester);
      expect(model.inputMode, InputMode.pad);
      expect(find.text('Enter'), findsNothing);
      expect(find.text('Q'), findsNothing);
      expect(find.text('L1'), findsOneWidget);
      expect(find.byType(PadGlyphIcon), findsWidgets);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.inputMode, InputMode.keyboardMouse);
      expect(find.text('Enter'), findsOneWidget);
    });

    testWidgets('with a controller the ‹ › arrows show only in edit mode; Back shows ○, not Esc', (tester) async {
      final pads = FakePads();
      final fixture = makeFixture(pads: () => pads);
      addTearDown(fixture.dispose);
      final model = fixture.model..startPads();
      addTearDown(model.dispose);
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      expect(find.byKey(const ValueKey('theme-next')), findsOneWidget);
      expect(find.text('Esc'), findsWidgets);
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.dpadUp);
      await settle(tester);
      expect(find.byKey(const ValueKey('theme-next')), findsNothing);
      expect(find.text('Esc'), findsNothing);
      pads.press(PadButton.south);
      await settle(tester);
      expect(find.byKey(const ValueKey('theme-next')), findsOneWidget, reason: 'edit mode shows them');
    });
  });

  group('PS', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;
    late List<int> quits;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      quits = [];
      fixture = makeFixture(pads: () => pads, desktop: desktop, quit: quits.add);
      model = fixture.model..startPads();
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Future<({Future<void> done})> startOrbit() async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      desktop.calls.clear();
      return (done: playing);
    }

    Future<void> holdGuide() async {
      pads.hold(PadButton.guide);
      await Future<void>.delayed(ShortcutTiming.hold + const Duration(milliseconds: 50));
      pads.release(PadButton.guide);
    }

    test('held in the launcher: the home menu, Switch Profile shown for later, Quit AnyPS5', () async {
      desktop.focused = true;
      await holdGuide();
      expect(model.overlay, Layer.homeMenu);
      final rows = model.panelCategories().single.rows;
      expect(rows.map((row) => row.id), ['switchProfile', 'quit']);
      expect(rows.first.focusable, isFalse, reason: 'no profiles yet');
      expect(model.panelRow, 1);
      pads.press(PadButton.south);
      expect(quits, [0]);
    });

    test('a short press in the launcher does not open the home menu', () async {
      desktop.focused = true;
      model.open(Layer.settings);
      pads.press(PadButton.guide);
      expect(model.overlay, isNull, reason: 'PS closes the layer, as before');
    });

    test('in a game: the game\'s Options pressed, then the launcher with the quick menu', () async {
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => desktop.calls.contains('raise'));
      expect(desktop.calls, ['key Escape', 'raise'], reason: 'Options is Escape by default, pressed first');
      expect(model.overlay, Layer.quickMenu);
      expect(model.panelCategories().single.rows.map((row) => row.id), ['resume', 'gameSettings', 'closeGame']);
      desktop.focused = true;
      pads.press(PadButton.south);
      expect(model.overlay, isNull);
      await until(() => desktop.calls.contains('focus'));
      expect(model.running, isNotNull, reason: 'Resume keeps the game');
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('Pause Game When Opening the Menu off: no key; Circle resumes; Close Game closes', () async {
      model.preferences.pauseOnMenu = false;
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => model.overlay == Layer.quickMenu);
      expect(desktop.calls, ['raise']);
      desktop.focused = true;
      pads.press(PadButton.east);
      expect(model.overlay, isNull);
      desktop.focused = false;
      await Future<void>.delayed(GuideSwitch.defaultDebounce);
      pads.press(PadButton.guide);
      await until(() => model.overlay == Layer.quickMenu);
      desktop.focused = true;
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.south);
      expect(model.overlay, Layer.closeGame, reason: 'Close Game asks first');
      pads.press(PadButton.south);
      await playing;
      expect(model.running, isNull);
      expect(model.overlay, isNull);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a remapped Options key is the one pressed', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.saveSettings(
        orbit,
        model
            .currentSettings(orbit)
            .copyWith(
              controls: {
                'Options': ['KEY:P'],
              },
            ),
      );
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => desktop.calls.contains('raise'));
      expect(desktop.calls.first, 'key P');
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('held in a game: Close Game? straight away; Cancel goes back to the game', () async {
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      await holdGuide();
      expect(model.overlay, Layer.closeGame);
      expect(desktop.calls, ['raise'], reason: 'no pause key for the question');
      desktop.focused = true;
      expect(model.panelCategories().single.rows.map((row) => row.id), ['confirmClose', 'cancel']);
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.south);
      expect(model.overlay, isNull);
      await until(() => desktop.calls.contains('focus'));
      desktop.focused = false;
      await holdGuide();
      expect(model.overlay, Layer.closeGame);
      desktop.focused = true;
      pads.press(PadButton.south);
      await playing;
      expect(model.running, isNull);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  group('Share and the replay buffer', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;
    late List<String> saved;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      saved = [];
      fixture = makeFixture(
        pads: () => pads,
        desktop: desktop,
        replay: (seconds) => ReplayBuffer(
          ffmpeg: 'ffmpeg',
          folder: p.join(Directory.systemTemp.path, 'anyps5-replay-test-${DateTime.now().microsecondsSinceEpoch}'),
          seconds: seconds,
          system: HostSystem.linux,
          start: (_, _) async => FakeProcess(),
          run: (_, arguments) async {
            if (arguments.contains('concat')) saved.add(arguments.last);
            File(arguments.last)
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('mp4');
            return ProcessResult(1, 0, '', '');
          },
        ),
      );
      model = fixture.model..startPads();
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Future<({Future<void> done})> startOrbit() async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      desktop.calls.clear();
      return (done: playing);
    }

    test('off by default; with it off Share takes a screenshot into the game\'s gallery', () async {
      expect(model.preferences.replayBuffer, isFalse);
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.misc);
      await until(() => desktop.calls.contains('capture'));
      final game = model.running!.$1;
      await until(() => model.screenshotsOf(game).any((shot) => !shot.contains('trophy')));
      expect(model.replayRecording, isFalse);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('on: Share saves the last minute as a clip in the gallery, held a screenshot', () async {
      model.preferences.replayBuffer = true;
      final playing = (await startOrbit()).done;
      await until(() => model.replayRecording);
      final game = model.running!.$1;
      // A segment recorded, as ffmpeg would.
      final folder = Directory.systemTemp.listSync().whereType<Directory>().firstWhere(
        (directory) => p.basename(directory.path).startsWith('anyps5-replay-test-'),
      );
      File(p.join(folder.path, 'segment000.ts')).writeAsStringSync('ts');
      desktop.focused = false;
      pads.press(PadButton.misc);
      await until(() => saved.isNotEmpty);
      expect(p.basename(saved.single), matches(RegExp(r'^PPSA01001-clip-\d{8}-\d{6}\.mp4$')));
      expect(p.dirname(saved.single), Screenshots.folderFor(model.paths.pictures, game));
      expect(model.screenshotsOf(game).where(Screenshots.isClip), hasLength(1));
      pads.hold(PadButton.misc);
      await Future<void>.delayed(ShortcutTiming.hold + const Duration(milliseconds: 50));
      pads.release(PadButton.misc);
      await until(() => desktop.calls.contains('capture'));
      model.stopGame();
      await playing;
      await until(() => !model.replayRecording);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('the setting shows the cost and its lengths; kept', () {
      model.open(Layer.settings);
      final captures = model.panelCategories().firstWhere((category) => category.id == 'captures');
      expect(captures.rows.first.detail, contains('CPU'));
      expect(captures.rows.map((row) => row.id), isNot(contains('replayLength')));
      model.preferences.replayBuffer = true;
      final lengths = model.panelCategories().firstWhere((category) => category.id == 'captures').rows[1];
      expect((lengths.kind as ChoiceRow).options, ['30 s', '1 min', '3 min', '5 min']);
      final json = Preferences.fromJson(model.preferences.toJson());
      expect(json.replayBuffer, isTrue);
      expect(json.replaySeconds, 60);
    });

    testWidgets('a clip shows in the gallery and opens in the system player', (tester) async {
      final game = model.selectedGame!;
      final clip = Screenshots.clipPath(model.paths.pictures, game, DateTime(2026, 10, 26, 12));
      File(clip)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('mp4');
      model.open(Layer.gallery);
      expect(model.galleryShots, contains(clip));
      model.galleryIndex = model.galleryShots.indexOf(clip);
      model.handle(Command.select);
      expect(fixture.opened.last, Uri.file(clip));
      expect(model.galleryViewing, isFalse);
      await pumpLauncher(tester, model);
      expect(find.byKey(const ValueKey('clip-badge')), findsWidgets);
    });
  });

  group('shortcuts', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeWindow window;

    setUp(() {
      pads = FakePads();
      window = FakeWindow();
      fixture = makeFixture(pads: () => pads, window: window);
      model = fixture.model..startPads();
      model.open(Layer.settings);
      model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'shortcuts'));
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    int rowOf(LauncherAction action) =>
        model.panelCategories()[model.panelCategory].rows.indexWhere((row) => row.id == 'shortcut-${action.name}');

    testWidgets('a key: chosen, pressed, kept, and run in the launcher', (tester) async {
      await pumpLauncher(tester, model);
      model.activateRow(rowOf(LauncherAction.toggleFullscreen));
      expect(model.shortcutCapture, LauncherAction.toggleFullscreen);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(model.shortcutCapture, isNull);
      expect(
        model.preferences.shortcuts[LauncherAction.toggleFullscreen].key,
        KeyCombo(LogicalKeyboardKey.keyF.keyId, control: true),
      );
      expect(find.text('Ctrl+F'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.f11);
      expect(window.asked, isEmpty, reason: 'F11 is free now');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(window.asked, [false]);
    });

    testWidgets('a key another action has, or one AnyPS5 moves with, is refused and said', (tester) async {
      await pumpLauncher(tester, model);
      model.activateRow(rowOf(LauncherAction.screenshot));
      await press(tester, LogicalKeyboardKey.f11);
      expect(model.preferences.shortcuts[LauncherAction.screenshot].key, isNull);
      expect(model.toast, 'Already used by Full Screen');
      model.activateRow(rowOf(LauncherAction.screenshot));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.toast, contains('AnyPS5 moves with'));
      model.activateRow(rowOf(LauncherAction.screenshot));
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.shortcutCapture, isNull, reason: 'Esc cancels');
      expect(model.overlay, Layer.settings, reason: 'and does not close the settings');
      model.activateRow(rowOf(LauncherAction.nextSection));
      await press(tester, LogicalKeyboardKey.backspace);
      expect(model.shortcutCapture, isNull);
      expect(model.preferences.shortcuts[LauncherAction.nextSection].key, isNull, reason: 'Backspace clears the key');
      expect(model.preferences.shortcuts[LauncherAction.nextSection].pad, PadChord.of(PadButton.r1));
      await tester.pump(const Duration(seconds: 5));
    });

    test('buttons together: a chord, held a long press; Circle alone cancels; it acts at once', () async {
      model.panelRow = rowOf(LauncherAction.quickMenu);
      pads.press(PadButton.south);
      expect(model.shortcutCapture, LauncherAction.quickMenu);
      pads.release(PadButton.south);
      pads.hold(PadButton.select);
      pads.hold(PadButton.start);
      pads.release(PadButton.start);
      pads.release(PadButton.select);
      expect(model.preferences.shortcuts[LauncherAction.quickMenu].pad, PadChord({PadButton.select, PadButton.start}));
      expect(model.overlay, Layer.settings, reason: 'Options in the chord did not also act');

      model.panelRow = rowOf(LauncherAction.screenshot);
      pads.press(PadButton.south);
      pads.press(PadButton.east);
      expect(model.shortcutCapture, isNull);
      expect(model.preferences.shortcuts[LauncherAction.screenshot].pad, PadChord.of(PadButton.misc, hold: true));

      pads.press(PadButton.south);
      pads.hold(PadButton.r3);
      await Future<void>.delayed(ShortcutTiming.hold + const Duration(milliseconds: 50));
      pads.release(PadButton.r3);
      expect(model.preferences.shortcuts[LauncherAction.screenshot].pad, PadChord.of(PadButton.r3, hold: true));
      expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].kind, isA<ShortcutRow>());

      // Triangle alone while waiting clears the controller's binding; the key stays.
      model.panelRow = rowOf(LauncherAction.previousSection);
      pads.press(PadButton.south);
      pads.press(PadButton.north);
      expect(model.shortcutCapture, isNull);
      expect(model.preferences.shortcuts[LauncherAction.previousSection].pad, isNull);
      expect(model.preferences.shortcuts[LauncherAction.previousSection].key, const KeyCombo(KeyIds.q));
    });

    test('a chord another action has is refused; Triangle clears the binding of the input in use', () {
      model.panelRow = rowOf(LauncherAction.quickMenu);
      pads.press(PadButton.south);
      pads.press(PadButton.misc);
      expect(model.preferences.shortcuts[LauncherAction.quickMenu].pad, isNull);
      expect(model.toast, 'Already used by Save Clip');
      model.panelRow = rowOf(LauncherAction.nextSection);
      pads.press(PadButton.north);
      expect(
        model.preferences.shortcuts[LauncherAction.nextSection].pad,
        isNull,
        reason: 'the pad was in use: R1 goes',
      );
      expect(model.preferences.shortcuts[LauncherAction.nextSection].key, const KeyCombo(KeyIds.e), reason: 'E stays');
      expect(model.overlay, Layer.settings);
    });

    test('reset to defaults; the game\'s own buttons are linked', () {
      model.preferences.shortcuts = ShortcutMap().withBinding(LauncherAction.home, const ShortcutBinding());
      final rows = model.panelCategories()[model.panelCategory].rows;
      expect(rows.map((row) => row.id), containsAll(['gameControls', 'shortcutsReset']));
      model.activateRow(rows.indexWhere((row) => row.id == 'shortcutsReset'));
      expect(model.preferences.shortcuts.isDefault, isTrue);
      model.activateRow(rows.indexWhere((row) => row.id == 'gameControls'));
      expect(model.overlay, Layer.controls);
    });

    test('a remapped section shortcut moves the settings and the home screen', () {
      model.preferences.shortcuts = model.preferences.shortcuts.withBinding(
        LauncherAction.nextSection,
        ShortcutBinding(pad: PadChord.of(PadButton.r2)),
      );
      model.savePreferences();
      final category = model.panelCategory;
      pads.press(PadButton.r1);
      expect(model.panelCategory, category, reason: 'R1 is nothing now');
      pads.press(PadButton.r2);
      expect(model.panelCategory, category + 1);
    });

    test('kept in the preferences', () {
      model.preferences.shortcuts = model.preferences.shortcuts.withBinding(
        LauncherAction.quickMenu,
        ShortcutBinding(pad: PadChord({PadButton.l3, PadButton.r3})),
      );
      final back = Preferences.fromJson(model.preferences.toJson());
      expect(back.shortcuts[LauncherAction.quickMenu].pad, PadChord({PadButton.l3, PadButton.r3}));
    });
  });

  test('every new text is in both languages', () {
    final keys = [
      'quickResume',
      'quickCloseGame',
      'closeGameTitle',
      'switchProfile',
      'quitLauncher',
      'launcherFullscreen',
      'pauseOnMenu',
      'replayBuffer',
      'shortcuts',
      'shortcutHeld',
      'captures',
    ];
    for (final language in Language.values) {
      T.language = language;
      for (final key in keys) {
        expect(T.text(key), isNot(key), reason: '$key in ${language.code}');
      }
    }
    T.language = Language.turkish;
    expect(T.text('quickResume'), 'Devam Et');
    expect(AppModel.padLabel(PadChord.of(PadButton.misc, hold: true)), 'Share (basılı)');
  });
}
