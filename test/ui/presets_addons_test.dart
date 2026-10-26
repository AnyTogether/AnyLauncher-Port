import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_presets.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import '../support/ui_support.dart';

/// Settings › Game Presets and a game's dumped update and add-ons, from the settings rows to the
/// environment the game starts with.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
  });

  tearDown(() {
    model.dispose();
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  int indexOf(String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

  Future<String> playAndReadLog(String titleId) async {
    final game = model.games[indexOf(titleId)];
    final installed = Installer.installedFolder(game, model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_ | sort\nsleep 0.3\n');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    await model.play(game);
    await until(() => model.stateOf(game) is Installed);
    return File(model.paths.logFile(game.titleId)).readAsStringSync();
  }

  PanelCategory presetsCategory() {
    model.open(Layer.settings);
    return model.panelCategories().firstWhere((category) => category.id == 'presets');
  }

  test('Settings has Game Presets with every setting, all at the game default at first', () {
    final category = presetsCategory();
    expect(category.title, 'Game Presets');
    expect(category.rows.map((row) => row.id), [
      'presetsIntro',
      'presetDifficulty',
      'presetPriority',
      'presetInvertVerticalFirst',
      'presetInvertHorizontalFirst',
      'presetInvertVerticalThird',
      'presetInvertHorizontalThird',
      'presetSubtitles',
      'presetAudioLanguage',
    ]);
    final difficulty = category.rows[1].kind as ChoiceRow;
    expect(difficulty.options, ['Game Default', 'Easiest', 'Easy', 'Normal', 'Hard', 'Hardest']);
    expect(difficulty.selected, 0);
    expect((category.rows[8].kind as ChoiceRow).options.first, 'Game Default');
  });

  test('choosing presets changes them, offers a reset, and the game starts with them', () async {
    var category = presetsCategory();
    (category.rows.firstWhere((row) => row.id == 'presetDifficulty').kind as ChoiceRow).set(4);
    category = presetsCategory();
    (category.rows.firstWhere((row) => row.id == 'presetPriority').kind as ChoiceRow).set(1);
    category = presetsCategory();
    (category.rows.firstWhere((row) => row.id == 'presetInvertVerticalThird').kind as ToggleRow).set(true);
    category = presetsCategory();
    final audio = category.rows.firstWhere((row) => row.id == 'presetAudioLanguage').kind as ChoiceRow;
    audio.set(audio.options.indexOf('Deutsch'));
    expect(model.gamePresets, const GamePresets(
      difficulty: PresetDifficulty.hard,
      priority: PresetPriority.performance,
      invertVerticalThirdPerson: true,
      audioLanguage: 4,
    ));
    expect(presetsCategory().rows.last.id, 'presetsReset');
    model.open(Layer.settings);
    final log = await playAndReadLog('PPSA01001');
    expect(log, contains('ANYPS5_GAME_PRESETS=difficulty=hard,priority=performance,invert_1st_v=0,invert_1st_h=0,invert_3rd_v=1,invert_3rd_h=0,subtitles=default,audio_language=4'));
    (presetsCategory().rows.last.kind as ActionRow).run();
    expect(model.gamePresets.isEmpty, isTrue);
    expect(presetsCategory().rows.map((row) => row.id), isNot(contains('presetsReset')));
  });

  test('a game without presets, update or add-ons starts without their variables', () async {
    final log = await playAndReadLog('PPSA01001');
    expect(log, isNot(contains('ANYPS5_GAME_PRESETS')));
    expect(log, isNot(contains('ANYPS5_ADDCONT_DIRS')));
    expect(log, isNot(contains('ANYPS5_UPDATE_DIR')));
  });

  test("an add-on dumped beside a game reaches the engine; an update waits for the game's next unlock", () async {
    final orbit = model.games[indexOf('PPSA01001')];
    final addon = p.join(p.dirname(orbit.folder), 'astro-DLC', 'EXPANSION0000001');
    Directory(p.join(addon, 'sce_sys')).createSync(recursive: true);
    File(p.join(addon, 'sce_sys', 'param.json')).writeAsStringSync(jsonEncode({
      'localizedParameters': {'en-US': {'titleName': 'The Island'}},
    }));
    File(p.join(addon, 'island.pak')).writeAsStringSync('island');
    model.rescan();
    final withAddon = model.games[indexOf('PPSA01001')];
    expect(withAddon.addons.map((addon) => addon.name), ['The Island']);
    expect(model.stateOf(withAddon), isA<Installed>(), reason: 'an add-on needs no new unlock');
    final log = await playAndReadLog('PPSA01001');
    expect(log, contains('ANYPS5_ADDCONT_DIRS=$addon'));

    makeDump(p.dirname(orbit.folder), 'astro-UPDATE', titleId: 'PPSA01001', version: '01.004.000');
    model.rescan();
    final updated = model.games[indexOf('PPSA01001')];
    expect(updated.update?.version, '01.004.000');
    expect(model.games.where((game) => game.titleId == 'PPSA01001'), hasLength(1), reason: 'the update is not a game of its own');
    expect(model.stateOf(updated), isA<Locked>(), reason: "the update's executable is relinked by the next unlock");
  });

  group('golden', () {
    final shell = find.byType(LauncherShell);

    testWidgets('Settings › Game Presets with a few set', (tester) async {
      model.setGamePresets(const GamePresets(
        difficulty: PresetDifficulty.hard,
        priority: PresetPriority.performance,
        invertVerticalThirdPerson: true,
        subtitles: PresetSubtitles.on,
      ));
      model.open(Layer.settings);
      model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'presets'));
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/settings_presets.png'));
    });

    testWidgets("a game's page with its add-ons and the update it was unlocked with", (tester) async {
      final orbit = model.games[indexOf('PPSA01001')];
      final parent = p.dirname(orbit.folder);
      for (final (label, name) in [('EXPANSION0000001', 'The Lost Island'), ('COSTUMEPACK00002', 'Retro Costumes'), ('SOUNDTRACK000003', 'Soundtrack')]) {
        final addon = p.join(parent, 'astro-DLC', label);
        Directory(p.join(addon, 'sce_sys')).createSync(recursive: true);
        File(p.join(addon, 'sce_sys', 'param.json')).writeAsStringSync(jsonEncode({
          'localizedParameters': {'en-US': {'titleName': name}},
        }));
      }
      makeDump(parent, 'astro-UPDATE', titleId: 'PPSA01001', version: '01.004.000');
      model.rescan();
      final record = model.records[orbit.id]!;
      model.records[orbit.id] = InstallRecord(
        source: record.source,
        titleId: record.titleId,
        toolkit: record.toolkit,
        system: record.system,
        date: record.date,
        update: '01.004.000',
      );
      model.select(indexOf('PPSA01001'));
      await pumpLauncher(tester, model);
      expect(find.text('DLC (3)'), findsOneWidget);
      expect(find.text('Update v01.004 applied'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/home_addons.png'));
    });
  });
}
