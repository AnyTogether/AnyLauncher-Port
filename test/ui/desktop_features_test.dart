import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/signing.dart';
import '../support/trophy_fixture.dart';
import '../support/ui_support.dart';

/// What the launcher asked of the desktop.
class FakeDesktop implements DesktopWindows {
  final List<String> calls = [];
  final List<RgbaImage> cards = [];
  bool cardsWork = true;

  @override
  Future<bool> raiseLauncher() async {
    calls.add('raise');
    return true;
  }

  @override
  Future<bool> focusGame(int pid) async {
    calls.add('focus');
    return true;
  }

  @override
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize}) async {
    calls.add('display ${fullscreen ? 'fullscreen' : '$windowSize%'}');
    return true;
  }

  @override
  Future<RgbaImage?> captureGame(int pid) async {
    calls.add('capture');
    return RgbaImage(2, 1, Uint8List.fromList([10, 20, 30, 255, 40, 50, 60, 255]));
  }

  @override
  double cardScale(int? pid) => 1;

  @override
  Future<bool> showCard(RgbaImage card, {int? pid}) async {
    calls.add('card');
    cards.add(card);
    return cardsWork;
  }

  @override
  Future<bool> notify(String title, String body, {String? icon}) async {
    calls.add('notify $body');
    return true;
  }

  @override
  void dispose() {}
}

class FakePads implements PadSource {
  void Function(PadEvent)? send;

  @override
  void start(void Function(PadEvent event) onEvent) => send = onEvent;
  @override
  void stop() => send = null;
  @override
  String get description => 'fake';

  void press(PadButton button) {
    send!(PadButtonEvent('pad', button, down: true));
    send!(PadButtonEvent('pad', button, down: false));
  }
}

void main() {
  tearDown(() => T.language = Language.english);

  Future<void> until(bool Function() condition, {int tries = 500}) async {
    for (var index = 0; index < tries && !condition(); index++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  group('controller', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      fixture = makeFixture(pads: () => pads, desktop: desktop);
      model = fixture.model..startPads();
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('the pad moves through the launcher as the keys do', () {
      final first = model.selected;
      pads.press(PadButton.r1);
      expect(model.selected, first + 1);
      pads.press(PadButton.l1);
      expect(model.selected, first);
      pads.press(PadButton.north);
      expect(model.overlay, Layer.gameSettings, reason: 'Triangle opens the options');
      pads.press(PadButton.dpadDown);
      expect(model.panelRow, 1);
      pads.press(PadButton.east);
      expect(model.overlay, isNull, reason: 'Circle goes back');
    });

    test('L1 and R1 move between the settings\' categories', () {
      model.open(Layer.settings);
      pads.press(PadButton.r1);
      expect(model.panelCategory, 1);
    });

    test('behind another window only PS counts, and it brings the launcher in front', () {
      model.setActive(false);
      final selected = model.selected;
      pads.press(PadButton.r1);
      pads.press(PadButton.south);
      expect(model.selected, selected);
      expect(desktop.calls, isEmpty);
      pads.press(PadButton.guide);
      expect(desktop.calls, ['raise']);
    });

    test('while a game runs, PS goes from the game to the launcher and back', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 2\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      model.setActive(false);
      pads.press(PadButton.guide);
      model.setActive(true);
      pads.press(PadButton.guide);
      expect(desktop.calls.where((call) => call == 'raise' || call == 'focus'), ['raise', 'focus']);
      expect(desktop.calls.first, 'display 75%', reason: 'upstream\'s engine: the launcher sizes the window');
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  group('trophies while playing', () {
    late Fixture fixture;
    late AppModel model;
    late FakeDesktop desktop;

    setUp(() {
      desktop = FakeDesktop();
      fixture = makeFixture(
        desktop: desktop,
        renderTrophyCard: (trophy, scale) async => RgbaImage(1, 1, Uint8List.fromList([1, 2, 3, 4])),
      );
      model = fixture.model;
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('a trophy earned in the game: a picture of the game first, then the card over it', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 6\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      await until(() => model.running != null);
      writeTrophies(orbit.folder, installed: installed, earned: [1, 2, 3]);
      await until(() => desktop.calls.contains('card'), tries: 400);
      expect(desktop.calls.where((call) => call == 'capture' || call == 'card'), ['capture', 'card']);
      final shots = Screenshots.list(model.paths.pictures, orbit);
      expect(shots, hasLength(1));
      expect(p.basename(shots.single), startsWith('PPSA01001-trophy0_3-'));
      expect(File(shots.single).readAsBytesSync().sublist(1, 4), 'PNG'.codeUnits);
      expect(model.trophyShots['0/3'], shots.single);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('where no card can be shown, a notification says it', () async {
      desktop.cardsWork = false;
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final trophy = model.trophies[orbit.id]!.trophies.first;
      await model.celebrate(orbit, trophy, 1);
      expect(desktop.calls.last, 'notify ${trophy.name}');
    });
  });

  group('AnyPS5-ARM engine', () {
    final key = TestReleaseKey('release');
    late FakeGitHub upstream;
    late FakeGitHub arm;
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      upstream = await FakeGitHub.start();
      arm = await FakeGitHub.start(repository: ArmToolkitPackage.repository);
      fixture = makeFixture(engine: upstream.api, armEngine: arm.api, armKeys: [key.key]);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await upstream.close();
      await arm.close();
      fixture.dispose();
    });

    PanelRow row(String id) => model
        .panelCategories()
        .expand((category) => category.rows)
        .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

    test(
      'chosen in Settings, downloaded from AnyPS5-ARM\'s releases, in use; the game\'s window settings are its own',
      () async {
        arm.releases.add(signed(armRelease('v0.2.17-arm', '26d785b'), [key]));
        final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
        model.select(model.games.indexOf(orbit));
        model.open(Layer.gameSettings);
        expect(row('display').detail, T.text('displayUpstream'), reason: 'upstream\'s engine is in use');
        model.closeOverlay();

        model.open(Layer.settings);
        model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
        final source = row('engineSource').kind as ChoiceRow;
        expect(source.selected, 0);
        source.set(1);
        expect(model.preferences.engineSource, 'arm');
        await until(() => model.engine.armChecked);
        expect(model.engine.armPackage?.commit, '26d785b');
        (row('engineDownload').kind as ActionRow).run();
        await until(() => model.engine.downloading == null && model.toolkitVersion == 'arm-26d785b');
        expect(model.engine.readsDisplaySettings, isTrue);
        expect(row('engineCurrent').kind, isA<InfoRow>().having((info) => info.text, 'text', 'AnyPS5-ARM 26d785b'));

        model.open(Layer.gameSettings);
        expect(row('display').detail, isNull);
        model.closeOverlay();

        // Back to upstream: the settings offer it again, the ARM engine stays downloaded.
        model.open(Layer.settings);
        model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
        (row('engineSource').kind as ChoiceRow).set(0);
        expect(model.preferences.engineSource, 'upstream');
        expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), contains('arm-26d785b'));
      },
    );

    test('no engine for this system yet: the settings say so', () async {
      arm.releases.add(signed(armRelease('v0.2.17-arm', '26d785b', linux: false), [key]));
      model.engine.chooseSource(true);
      await until(() => model.engine.armChecked);
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
      expect(row('engineCheck').detail, T.text('engineArmNone'));
    });
  });
}
