import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/power_profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// Settings › Battery & Heat: the readings, the profiles, what a game starts with and hears while
/// it runs, the note over a hot game and Undo in the quick menu.
void main() {
  late Fixture fixture;
  late AppModel model;
  late DateTime clock;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
    clock = DateTime.utc(2026, 11, 1, 12);
    model.powerWatch.now = () => clock;
  });

  tearDown(() {
    Motion.reduced = false;
    model.dispose();
    fixture.dispose();
  });

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  List<PanelRow> powerRows() {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'power');
    return model.panelCategories()[model.panelCategory].rows;
  }

  PanelRow row(String id) =>
      powerRows().firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));
  bool hasRow(String id) => powerRows().any((row) => row.id == id);

  const laptop = PowerReading(hasBattery: true, onBattery: false, batteryPercent: 90, thermal: ThermalLevel.nominal);
  const onBattery = PowerReading(
    hasBattery: true,
    onBattery: true,
    batteryPercent: 64,
    minutesToEmpty: 125,
    thermal: ThermalLevel.nominal,
  );

  test('a laptop plugged in: the profiles shown, nothing in force', () {
    model.powerWatch.take(laptop);
    powerRows();
    expect(model.panelCategories()[model.panelCategory].title, 'Battery & Heat');
    expect(row('powerStatus').title, 'Plugged in');
    expect(row('powerStatus').detail, 'Games run as you set them\nTemperature: normal');
    expect(row('powerStatus').detail, startsWith('Games run as you set them'));
    expect(hasRow('powerUndo'), isFalse);
    expect((row('batteryOn').kind as ToggleRow).value, isTrue);
    expect((row('batteryCap').kind as ChoiceRow).options, ['Off', '30 FPS', '40 FPS', '45 FPS']);
    expect((row('batteryCap').kind as ChoiceRow).selected, 2);
    expect(hasRow('hotOn'), isTrue);
    expect(hasRow('powerUpstream'), isTrue, reason: 'the fixture runs upstream\'s engine');
  });

  test('on battery the battery profile holds: the line, Undo, the dimmed launcher', () {
    model.powerWatch.take(onBattery);
    expect(row('powerStatus').title, 'On battery at 64%, about 2 h 5 min left');
    expect(row('powerStatus').detail, startsWith('In force now: Battery profile with a 40 FPS cap'));
    expect(model.powerWatch.dimmed, isTrue);
    expect(model.solidGlass, isTrue);
    expect(Motion.reduced, isTrue);
    expect(row('powerUndo').title, 'Undo Battery Profile');
    (row('powerUndo').kind as ActionRow).run();
    expect(model.toast, T.text('powerUndone'));
    expect(hasRow('powerUndo'), isFalse);
    expect(row('powerStatus').detail, startsWith('Games run as you set them'));
    expect(row('powerStatus').title, startsWith('On battery'));
    expect(Motion.reduced, isFalse);
  });

  test('changing a profile is saved with the Mac\'s keys and applies at once', () {
    model.powerWatch.take(onBattery);
    (row('batteryCap').kind as ChoiceRow).set(1);
    expect(model.powerWatch.adjustment.frameCap, 30);
    expect(model.preferences.powerProfiles?['battery'], containsPair('frameCap', 30));
    expect(Preferences.fromJson(model.preferences.toJson()).powerProfiles, model.preferences.powerProfiles);
    (row('batteryOn').kind as ToggleRow).set(false);
    expect(hasRow('batteryCap'), isFalse);
    expect(model.powerWatch.adjustment, PowerAdjustment.none);
    // Back to the defaults: nothing kept.
    (row('batteryOn').kind as ToggleRow).set(true);
    (row('batteryCap').kind as ChoiceRow).set(2);
    expect(model.preferences.powerProfiles, isNull);
  });

  test('where the heat cannot be read, only the battery profile is offered, and that is said', () {
    model.powerWatch.take(const PowerReading(hasBattery: true, onBattery: false, batteryPercent: 80));
    expect(row('powerStatus').detail, contains(T.text('powerNoHeat')));
    expect(hasRow('hotOn'), isFalse);
    expect(row('hotUnavailable').title, T.text('powerHeatUnavailable'));
    expect(hasRow('batteryOn'), isTrue);
  });

  test('a desktop without a battery says so; battery saver holds the battery profile', () {
    model.powerWatch.take(PowerReading.pluggedIn);
    expect(row('powerStatus').title, T.text('powerNoBattery'));
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: false, thermal: ThermalLevel.nominal, lowPowerMode: true),
    );
    clock = clock.add(PowerPolicy.sourceSettle);
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: false, thermal: ThermalLevel.nominal, lowPowerMode: true),
    );
    expect(row('powerStatus').detail, contains(T.text('powerLowPowerMode')));
    expect(model.powerWatch.adjustment.frameCap, 40);
  });

  test('a game starts with the cap and the control file, which follows the profile while it runs', () async {
    model.powerWatch.take(onBattery);
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
    expect(environment?['ANYPS5_FPS_CAP'], '40');
    expect(environment?['ANYPS5_POWER_CONTROL'], model.powerWatch.controlFile);
    // The fixture does not write to disk; the text the file would hold follows the adjustment.
    expect(EngineControl.text(model.powerWatch.adjustment), 'fps_cap=40\nframe_gen=0\n');
    // Hot while it plays: a note over the game, and Undo in the quick menu.
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: true, batteryPercent: 63, thermal: ThermalLevel.serious),
    );
    expect(model.toast, 'Your computer is hot. AnyPS5 lowered the frame rate. To undo, open the quick menu with PS.');
    await model.openQuickMenu();
    final quick = model.panelCategories().single.rows;
    expect(quick.map((row) => row.id), contains('powerUndo'));
    final undo = quick.firstWhere((row) => row.id == 'powerUndo');
    expect(undo.title, 'Undo Heat Profile');
    (undo.kind as ActionRow).run();
    expect(model.powerWatch.mode, PowerMode.battery, reason: 'the battery profile still holds');
    process.quit();
    await playing;
  });

  test('the control file is written whole where the launcher keeps its files', () {
    final dir = Directory(fixture.temp.path);
    final file = '${dir.path}/Power/control.txt';
    EngineControl.write(model.powerWatch.adjustment, file);
    expect(File(file).readAsStringSync(), 'fps_cap=0\nframe_gen=1\n');
  });

  testWidgets('golden: Settings › Battery & Heat on battery, the heat unknown', (tester) async {
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: true, batteryPercent: 64, minutesToEmpty: 125),
    );
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'power'));
    await pumpLauncher(tester, model);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/settings_power.png'));
  });

  test('Turkish', () {
    T.language = Language.byCode('tr');
    addTearDown(() => T.language = Language.english);
    model.powerWatch.take(onBattery);
    expect(row('powerStatus').title, 'Pilde, %64, yaklaşık 2 sa 5 dk kaldı');
    expect(model.panelCategories()[model.panelCategory].title, 'Pil ve Isı');
  });
}

/// The environment the last fake start was given.
Map<String, String>? seen;
