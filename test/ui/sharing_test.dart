import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/deep_link.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:anyps5_desktop/core/shared_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/sharing_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// Game Settings' Frame Generation, Export and Import Settings and Copy Link, anyps5:// links
/// opening the launcher, and Settings › Captures › Screenshots Folder.
void main() {
  late Fixture fixture;
  late AppModel model;
  String? savedTo;
  String? picked;
  String? folderPicked;

  setUp(() {
    savedTo = null;
    picked = null;
    folderPicked = null;
    fixture = makeFixture(
      saveFileAs: (name, label, extensions) async {
        expect(extensions, ['json']);
        return savedTo == null ? null : p.join(savedTo!, name);
      },
      pickFile: (label, extensions) async => picked,
      pickFolder: (_) async => folderPicked,
    );
    model = fixture.model;
  });

  tearDown(() {
    model.dispose();
    fixture.dispose();
  });

  Game titled(String titleId) => model.games.firstWhere((game) => game.titleId == titleId);
  Game orbit() => titled('PPSA01001');
  PanelRow row(String id) => model
      .panelCategories()
      .expand((category) => category.rows)
      .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

  void openGame(Game game) {
    model.select(model.games.indexOf(game));
    model.open(Layer.gameSettings);
  }

  group('frame generation', () {
    test('a switch in Game Settings, said to need AnyPS5-ARM\'s engine on upstream\'s', () {
      openGame(orbit());
      final frames = row('frameGeneration');
      expect(frames.title, 'Frame Generation');
      expect(frames.detail, T.text('frameGenerationUpstream'));
      expect((frames.kind as ToggleRow).value, isFalse);
      (frames.kind as ToggleRow).set(true);
      expect(model.currentSettings(orbit()).frameGeneration, isTrue);
      expect((row('frameGeneration').kind as ToggleRow).value, isTrue);
      // Vertical sync is on while frame generation is, whatever was chosen.
      (row('vsync').kind as ChoiceRow).set(2);
      expect((row('vsync').kind as ChoiceRow).selected, 1);
      final environment = model.launchSettings(orbit()).environment(launcherLanguage: 1);
      expect(environment['ANYPS5_FRAME_GEN'], '1');
      expect(environment['ANYPS5_PRESENT_MODE'], 'fifo');
      (row('frameGeneration').kind as ToggleRow).set(false);
      expect(model.currentSettings(orbit()).frameGeneration, isNull, reason: 'off is no key in the file');
      expect((row('vsync').kind as ChoiceRow).selected, 2);
    });
  });

  group('settings files', () {
    test('Export writes the game\'s settings as the macOS launcher does', () async {
      final folder = Directory(p.join(fixture.temp.path, 'out'))..createSync();
      savedTo = folder.path;
      model.saveSettings(orbit(), const GameSettings(frameGeneration: true, overlay: OverlayCorner.topLeft));
      openGame(orbit());
      expect(row('export').title, 'Export Settings');
      await model.exportSettings(orbit());
      final file = File(p.join(folder.path, 'Orbit Runner - AnyPS5.json'));
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(json['format'], 'anyps5-settings');
      expect(json['titleID'], 'PPSA01001');
      expect(json['game'], 'Orbit Runner');
      expect((json['settings'] as Map<String, dynamic>)['frameGeneration'], isTrue);
      expect(model.toast, T.text('settingsExported'));
    });

    test('Cancel in the save dialog writes nothing', () async {
      await model.exportSettings(orbit());
      expect(model.toast, isNot(T.text('settingsExported')));
    });

    test('Import applies a file made for another game, without a resolution this game cannot set', () async {
      final file = File(p.join(fixture.temp.path, 'shared.json'))
        ..writeAsStringSync(
          const SharedSettings(
            titleId: 'PPSA02002',
            game: 'Neon Alley',
            settings: GameSettings(resolution: '1920x1080', frameGeneration: true, language: 19),
          ).encode(),
        );
      picked = file.path;
      await model.importSettings(orbit());
      final settings = model.currentSettings(orbit());
      expect(settings.frameGeneration, isTrue);
      expect(settings.language, 19);
      expect(settings.resolution, isNull, reason: 'Orbit Runner has no resolution patch');
      expect(model.toast, T.format('settingsImportedOther', ['Neon Alley']));
    });

    test('Import of this game\'s own file says so; another kind of file is refused', () async {
      final file = File(p.join(fixture.temp.path, 'own.json'))
        ..writeAsStringSync(
          const SharedSettings(
            titleId: 'PPSA01001',
            game: 'Orbit Runner',
            settings: GameSettings(vsync: false),
          ).encode(),
        );
      picked = file.path;
      await model.importSettings(orbit());
      expect(model.toast, T.text('settingsImported'));
      expect(model.currentSettings(orbit()).ownVsync, isFalse);
      File(file.path).writeAsStringSync('{"hello": "world"}');
      await model.importSettings(orbit());
      expect(model.toast, T.text('settingsFileFailed'));
      expect(model.currentSettings(orbit()).ownVsync, isFalse, reason: 'nothing changed');
    });

    test('a game name with characters Windows refuses becomes a file name it takes', () {
      final game = orbit();
      expect(GameSharing.settingsFileName(game), 'Orbit Runner - AnyPS5.json');
    });
  });

  group('links', () {
    test('Copy Link puts the game\'s anyps5:// link on the clipboard', () {
      openGame(orbit());
      final link = row('link');
      expect(link.title, 'Copy Link');
      expect(link.detail, 'anyps5://game/PPSA01001');
      (link.kind as ActionRow).run();
      expect(fixture.copied.last, 'anyps5://game/PPSA01001');
      expect(model.toast, T.text('linkCopied'));
    });

    test('a game link selects the game; a link to a game not in the library says so', () {
      model.open(Layer.settings);
      model.followLink(const ShowGameLink('PPSA03003'));
      expect(model.overlay, isNull);
      expect(model.selectedGame?.titleId, 'PPSA03003');
      model.followLink(const ShowGameLink('PPSA09999'));
      expect(model.toast, T.format('linkNoGame', ['PPSA09999']));
      expect(model.selectedGame?.titleId, 'PPSA03003');
    });

    test('a play link does what Play does: an installed game starts, a locked one unlocks', () async {
      final starts = FakeGameStarts();
      model.startGame = starts.call;
      model.followLink(const PlayLink('PPSA01001'));
      expect(model.stateOf(orbit()), isA<Starting>());
      for (var tries = 0; tries < 400 && model.running == null; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(model.running?.$1, orbit());
      starts.last.quit();
    });

    test('the library and settings links open those screens; nothing opens before the setup', () {
      model.followLink(const SettingsLink());
      expect(model.overlay, Layer.settings);
      model.followLink(const LibraryLink());
      expect(model.overlay, Layer.library);
      model.closeOverlay();
      model.preferences.onboarded = false;
      model.followLink(const SettingsLink());
      expect(model.overlay, isNull);
    });
  });

  group('screenshots folder', () {
    test('Settings › Captures chooses where pictures go; games and the gallery use it', () async {
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'captures');
      expect(row('screenshotsFolder').detail, model.paths.pictures);
      final chosen = Directory(p.join(fixture.temp.path, 'Shots'))..createSync();
      final shot = File(Screenshots.shotPath(chosen.path, orbit(), DateTime(2026, 11, 1, 10)));
      shot.parent.createSync(recursive: true);
      shot.writeAsBytesSync(png(4, 4, (_, _) => 0xFFFFFFFF));
      folderPicked = chosen.path;
      (row('screenshotsFolder').kind as ActionRow).run();
      await Future<void>.delayed(Duration.zero);
      expect(model.preferences.screenshotsFolder, chosen.path);
      expect(model.picturesFolder, chosen.path);
      expect(row('screenshotsFolder').detail, chosen.path);
      expect(Preferences.fromJson(model.preferences.toJson()).screenshotsFolder, chosen.path);
      expect(model.screenshotsOf(orbit()), [shot.path]);
      // A game starts with it as ANYPS5_SCREENSHOTS.
      Map<String, String>? environment;
      final process = FakeGameProcess();
      model.startGame =
          ({
            required String installed,
            required Map<String, String> environment,
            required String logFile,
            HostSystem? system,
            bool traced = false,
            List<String> notes = const [],
          }) async {
            seen = environment;
            return RunningGame(process, process.exitCode, DateTime(2026, 11, 1));
          };
      final playing = model.play(orbit());
      for (var tries = 0; tries < 400 && model.running == null; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      environment = seen;
      process.quit();
      await playing;
      expect(environment?['ANYPS5_SCREENSHOTS'], chosen.path);
      (row('showScreenshots').kind as ActionRow).run();
      expect(fixture.folders.last, chosen.path);
    });
  });
}

/// The environment the last fake start was given.
Map<String, String>? seen;
