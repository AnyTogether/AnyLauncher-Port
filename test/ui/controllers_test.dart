import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controllers/sdl_pads.dart';
import 'package:anyps5_desktop/core/controllers/troubleshooter.dart';
import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/steam/steam_launch.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/strings_controllers.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_sdl.dart';
import '../support/ui_support.dart';

void main() {
  Fixture? current;
  Fixture start(Fixture made) => current = made;

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    Hint.circleConfirms = false;
    current?.dispose();
    current = null;
  });

  final shell = find.byType(LauncherShell);

  final sense = PadInfo(
    id: 'sdl0',
    name: 'DualSense Wireless Controller',
    kind: PadKind.dualSense,
    connection: PadConnection.bluetooth,
    battery: PadBattery(55, approximate: true, charging: false),
    driver: 'SDL HIDAPI',
    vendor: 0x054C,
    product: 0x0CE6,
    hasRumble: true,
    hasLight: true,
  );
  const xbox = PadInfo(
    id: 'sdl1',
    name: 'Xbox Wireless Controller',
    kind: PadKind.xbox,
    connection: PadConnection.usb,
    driver: 'SDL XInput',
    hasRumble: true,
  );

  void openControllers(AppModel model, {String row = 'padTest'}) {
    model.open(Layer.settings);
    final categories = model.panelCategories();
    final index = categories.indexWhere((category) => category.id == 'controllers');
    model.selectCategory(index);
    model.panelRow = model.panelCategories()[index].rows.indexWhere((candidate) => candidate.id.startsWith(row));
    model.refresh();
  }

  group('golden', () {
    testWidgets('controllers: two pads, Player 1 a DualSense over Bluetooth', (tester) async {
      final fixture = start(makeFixture(system: HostSystem.windows));
      final model = fixture.model;
      model.controllers.preview([sense, xbox], playerOne: 'sdl0', facts: PadFacts(system: HostSystem.windows, pads: [sense, xbox]));
      openControllers(model, row: 'padLight');
      await pumpLauncher(tester, model);
      expect(find.text('DualSense Wireless Controller · Player 1'), findsOneWidget);
      expect(find.text('DualSense · Bluetooth · about 55%'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/controllers_two_en.png'));
    });

    testWidgets('controllers: nothing connected on Windows, Steam and DS4Windows in the way, in Turkish', (tester) async {
      final fixture = start(makeFixture(system: HostSystem.windows, language: Language.turkish));
      final model = fixture.model;
      model.controllers.preview(
        const [],
        facts: const PadFacts(
          system: HostSystem.windows,
          processes: {'steam.exe', 'ds4windows.exe'},
          services: {'hidhide'},
          steamPlayStationSupport: 2,
          executable: r'C:\Users\Utku\AppData\Local\Programs\AnyPS5 Desktop\anyps5_desktop.exe',
        ),
      );
      openControllers(model);
      await pumpLauncher(tester, model);
      expect(find.text('Bağlı kumanda yok'), findsOneWidget);
      // Down to what is in the way: Steam's PlayStation support, DS4Windows, HidHide.
      for (var row = 0; row < 7; row++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await expectLater(shell, matchesGoldenFile('goldens/controllers_none_tr.png'));
    });

    testWidgets('controllers: Linux without permission, a low battery, Circle confirming', (tester) async {
      final fixture = start(makeFixture());
      final model = fixture.model;
      model.preferences
        ..confirmCircle = true
        ..stickDeadzone = 8
        ..controllerLight = 'purple';
      model.savePreferences();
      final low = PadInfo(id: 'sdl2', name: 'PS4 Controller', kind: PadKind.dualShock4, connection: PadConnection.usb,
          battery: PadBattery(5, approximate: true, charging: false), driver: 'SDL evdev');
      model.controllers.preview(
        [low],
        facts: PadFacts(
          system: HostSystem.linux,
          pads: [low],
          refused: const ['Nintendo Switch Pro Controller'],
          hidrawDenied: true,
        ),
      );
      openControllers(model, row: 'padDeadzone');
      await pumpLauncher(tester, model);
      // Down past the heading to the findings: the list follows.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await expectLater(shell, matchesGoldenFile('goldens/controllers_trouble_en.png'));
    });

    testWidgets('controller test: buttons held, a stick pushed, a trigger half in', (tester) async {
      final fixture = start(makeFixture());
      final model = fixture.model;
      model.preferences.stickDeadzone = 10;
      model.controllers.preview(
        [sense, xbox],
        playerOne: 'sdl0',
        states: {
          'sdl0': const PadState(
            pressed: {PadButton.south, PadButton.r1, PadButton.dpadLeft, PadButton.touchpad},
            leftX: 0.62,
            leftY: -0.35,
            rightX: -0.2,
            rightY: 0.1,
            r2: 0.55,
          ),
        },
      );
      model.openControllerTest();
      await pumpLauncher(tester, model);
      expect(find.text('Controller Test'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/controller_test_en.png'));
    });

    testWidgets('controller test: an Xbox pad, in Turkish', (tester) async {
      final fixture = start(makeFixture(language: Language.turkish));
      final model = fixture.model;
      model.controllers.preview(
        [xbox],
        states: {'sdl1': const PadState(pressed: {PadButton.north, PadButton.l1, PadButton.guide}, rightX: 0.9, rightY: -0.3, l2: 1)},
      );
      model.openControllerTest();
      await pumpLauncher(tester, model);
      expect(find.text('Kumanda Testi'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/controller_test_xbox_tr.png'));
    });

    testWidgets('home: a controller nearly empty says so in the top bar', (tester) async {
      final fixture = start(makeFixture());
      final model = fixture.model;
      model.controllers.preview([sense.copyWith(battery: PadBattery(9))]);
      await pumpLauncher(tester, model);
      expect(find.text('DualSense Wireless Controller · 9%'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/home_pad_battery.png'));
    });
  });

  group('behaviour', () {
    test('a pad plugged in is logged, listed and becomes Player 1; its light gets the setting', () {
      final sdl = FakeSdl()..leds.add(0);
      final fixture = start(makeFixture(pads: () => SdlPadSource(sdl)));
      final model = fixture.model;
      model.preferences.controllerLight = 'red';
      model.startPads();
      expect(model.controllers.pads, isEmpty);
      sdl.plug(dualSense(0), power: 3);
      (model.controllers.inventory! as SdlPadSource).poll();
      expect(model.controllers.pads.single.kind, PadKind.dualSense);
      expect(model.controllers.log.lines.single, contains('controller connected: PS5 Controller (DualSense, Bluetooth, battery about 100%, SDL HIDAPI, 054c:0ce6)'));
      expect(sdl.calls, contains('led 0 255 13 13'));
      expect(sdl.calls, contains('player 0 0'));
      sdl.plug(xbox360(1));
      final source = model.controllers.inventory! as SdlPadSource;
      source.poll();
      expect(model.controllers.playerOne!.id, 'sdl0');
      // A press on the Xbox pad: it is Player 1 now, and goes first.
      sdl.hold(1, {0});
      source.poll();
      expect(model.controllers.playerOne!.id, 'sdl1');
      expect(model.controllers.reportLines.first, startsWith('Player 1: Xbox 360 Controller'));
      sdl.unplug(1);
      source.poll();
      expect(model.controllers.log.lines.last, contains('controller disconnected: Xbox 360 Controller'));
      expect(model.controllers.playerOne!.id, 'sdl0');
      model.dispose();
    });

    test('Circle confirms: the pad selects with Circle and the hints swap their glyphs', () {
      final sdl = FakeSdl()..plug(dualSense(0));
      final fixture = start(makeFixture(pads: () => SdlPadSource(sdl)));
      final model = fixture.model;
      model.preferences.confirmCircle = true;
      model.savePreferences();
      expect(Hint.circleConfirms, isTrue);
      model.startPads();
      final source = model.controllers.inventory! as SdlPadSource;
      model.open(Layer.library);
      // East (Circle) selects: the library closes on the game picked.
      sdl.hold(0, {1});
      source.poll();
      expect(model.overlay, isNull);
      model.dispose();
    });

    testWidgets('the controller test keeps the pad to itself; Esc and a held Circle leave it', (tester) async {
      final sdl = FakeSdl()..plug(dualSense(0));
      final fixture = start(makeFixture(pads: () => SdlPadSource(sdl)));
      final model = fixture.model;
      model.startPads();
      final source = model.controllers.inventory! as SdlPadSource;
      model.openControllerTest();
      await pumpLauncher(tester, model);
      // Cross is tried, not used.
      sdl.hold(0, {0});
      source.poll();
      sdl.hold(0, {});
      source.poll();
      expect(model.overlay, Layer.controllerTest);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, Layer.settings);
      expect(model.panelCategories()[model.panelCategory].id, 'controllers');
      // Held Circle for a second leaves too.
      model.openControllerTest();
      await settle(tester);
      sdl.hold(0, {1});
      source.poll();
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(model.overlay, Layer.settings);
      sdl.hold(0, {});
      source.poll();
      // The pulses and toasts started meanwhile run out before the launcher goes.
      await tester.pump(const Duration(seconds: 5));
      model.dispose();
    });

    test('settings rows: the light, the dead zone, a command copied', () {
      final sdl = FakeSdl()
        ..plug(dualSense(0))
        ..leds.add(0);
      final fixture = start(makeFixture(pads: () => SdlPadSource(sdl)));
      final model = fixture.model;
      model.startPads();
      List<PanelRow> rows() => model.panelCategories().firstWhere((category) => category.id == 'controllers').rows;
      model.open(Layer.settings);
      final light = rows().firstWhere((row) => row.id == 'padLight').kind as ChoiceRow;
      light.set(PadLight.values.indexOf(PadLight.green));
      expect(model.preferences.controllerLight, 'green');
      expect(sdl.calls.last, 'led 0 13 230 51');
      final deadzone = rows().firstWhere((row) => row.id == 'padDeadzone').kind as StepperRow;
      deadzone.set(12);
      expect(model.preferences.stickDeadzone, 12);
      expect(Preferences.fromJson(model.preferences.toJson()).stickDeadzone, 12);
      model.controllers.preview(
        model.controllers.pads,
        facts: const PadFacts(system: HostSystem.linux, refused: ['Wireless Controller']),
      );
      final finding = rows().firstWhere((row) => row.id.contains('linuxPermission'));
      (finding.kind as ActionRow).run();
      expect(fixture.copied.last, 'sudo usermod -aG input "\$USER"');
      model.dispose();
    });

    test("in Steam's Game Mode the launcher counts as in front while no game runs", () {
      final fixture = start(makeFixture());
      final model = fixture.model;
      model.setActive(false);
      expect(model.launcherInFront, isFalse);
      model.steamLaunch = const SteamLaunch(fromSteam: true, gameMode: true);
      expect(model.launcherInFront, isTrue);
    });

    test('preferences keep the controller settings', () {
      final preferences = Preferences.fromJson({'controllerLight': 'pink', 'confirmCircle': true, 'stickDeadzone': 99});
      expect(preferences.controllerLight, 'pink');
      expect(preferences.confirmCircle, isTrue);
      expect(preferences.stickDeadzone, StickDeadzone.maximum);
      final old = Preferences.fromJson({});
      expect(old.controllerLight, isNull);
      expect(old.confirmCircle, isFalse);
      expect(old.stickDeadzone, 0);
    });

    test('the crash report carries the controllers', () {
      final report = SessionReport(
        gameName: 'Orbit Runner',
        titleId: 'PPSA01001',
        gameVersion: '01.000',
        settings: const GameSettings(),
        system: const SystemInfo(os: 'Windows 11', memoryGB: 16),
        launcherVersion: '0.1.6',
        platform: 'Windows',
        session: 'log',
        privacy: const ReportPrivacy(home: r'C:\Users\nobody'),
        controllers: const ['Player 1: DualSense Wireless Controller (DualSense, USB, SDL HIDAPI)'],
      );
      expect(report.text(), contains('Controllers:\n  Player 1: DualSense Wireless Controller (DualSense, USB, SDL HIDAPI)'));
      expect(IssueDraft.launcher(report).preview, contains('Controller: Player 1: DualSense'));
    });

    test('every controller text has its Turkish', () {
      expect(controllersTurkish.keys.toSet(), controllersEnglish.keys.toSet());
      for (final light in PadLight.values) {
        expect(controllersEnglish.containsKey('padLight_${light.name}'), isTrue, reason: light.name);
      }
      const ids = [
        'noControllers', 'usbCable', 'bluetoothPairing', 'dualShock3Windows', 'dualShock3Linux', 'unmapped', 'lowBattery',
        'steamPlayStation', 'steamRunning', 'steamLaunched', 'ds4windows', 'dualSenseX', 'hidHide', 'vigem',
        'linuxPermission', 'linuxHidraw', 'sdlMissingWindows', 'sdlMissingLinux', //
      ];
      for (final id in ids) {
        expect(controllersEnglish.containsKey('padFinding_$id'), isTrue, reason: id);
        expect(controllersEnglish.containsKey('padFinding_${id}Detail'), isTrue, reason: id);
      }
    });
  });
}
