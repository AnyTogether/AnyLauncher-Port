import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:test/test.dart';

void main() {
  group('PadKind', () {
    test('USB numbers tell the family', () {
      expect(PadKind.classify(vendor: 0x054C, product: 0x0CE6), PadKind.dualSense);
      expect(PadKind.classify(vendor: 0x054C, product: 0x0DF2), PadKind.dualSense);
      expect(PadKind.classify(vendor: 0x054C, product: 0x05C4), PadKind.dualShock4);
      expect(PadKind.classify(vendor: 0x054C, product: 0x09CC), PadKind.dualShock4);
      expect(PadKind.classify(vendor: 0x054C, product: 0x0268), PadKind.dualShock3);
      expect(PadKind.classify(vendor: 0x045E, product: 0x0B13), PadKind.xbox);
      expect(PadKind.classify(vendor: 0x057E, product: 0x2009), PadKind.switchPro);
      expect(PadKind.classify(vendor: 0x28DE, product: 0x11FF), PadKind.xbox);
      expect(PadKind.classify(vendor: 0x2DC8, product: 0x6101, name: '8BitDo SN30 Pro'), PadKind.generic);
    });

    test('a name alone still tells the family', () {
      expect(PadKind.classify(name: 'DualSense Wireless Controller'), PadKind.dualSense);
      expect(PadKind.classify(vendor: 0x054C, name: 'Wireless Controller'), PadKind.dualShock4);
      expect(PadKind.classify(name: 'Sony PLAYSTATION(R)3 Controller'), PadKind.dualShock3);
      expect(PadKind.classify(name: 'Xbox Series X Controller'), PadKind.xbox);
      expect(PadKind.classify(name: 'Nintendo Switch Pro Controller'), PadKind.switchPro);
      expect(PadKind.classify(name: 'Logitech Dual Action'), PadKind.generic);
    });

    test('light bars and PlayStation glyphs', () {
      expect(PadKind.dualSense.hasLightBar, isTrue);
      expect(PadKind.dualShock4.hasLightBar, isTrue);
      expect(PadKind.dualShock3.hasLightBar, isFalse);
      expect(PadKind.dualShock3.isPlayStation, isTrue);
      expect(PadKind.xbox.isPlayStation, isFalse);
    });
  });

  group('PadRoster', () {
    final sense = PadInfo(
      id: 'a',
      name: 'DualSense Wireless Controller',
      kind: PadKind.dualSense,
      connection: PadConnection.bluetooth,
      battery: PadBattery(80),
      driver: 'SDL HIDAPI',
      vendor: 0x054C,
      product: 0x0CE6,
    );
    const xbox = PadInfo(id: 'b', name: 'Xbox Wireless Controller', kind: PadKind.xbox, connection: PadConnection.usb, driver: 'SDL XInput');

    test('a connect is logged once and the first pad is Player 1', () {
      final roster = PadRoster();
      expect(
        roster.connect(sense),
        'controller connected: DualSense Wireless Controller (DualSense, Bluetooth, battery 80%, SDL HIDAPI, 054c:0ce6)',
      );
      expect(roster.connect(sense), isNull);
      expect(roster.playerOne, 'a');
      roster.connect(xbox);
      expect(roster.playerOne, 'a');
      expect(roster.pads.map((pad) => pad.id), ['a', 'b']);
    });

    test('the last pad used is Player 1, and goes first', () {
      final roster = PadRoster()
        ..connect(sense)
        ..connect(xbox);
      expect(roster.used('b'), isTrue);
      expect(roster.used('b'), isFalse);
      expect(roster.used('nobody'), isFalse);
      expect(roster.ordered.map((pad) => pad.id), ['b', 'a']);
    });

    test('a disconnect hands Player 1 on and says how long it was there', () {
      final start = DateTime(2026, 10, 25, 12);
      final roster = PadRoster()
        ..connect(sense, now: start)
        ..connect(xbox, now: start)
        ..used('b');
      expect(
        roster.disconnect('b', now: start.add(const Duration(seconds: 125))),
        'controller disconnected: Xbox Wireless Controller (Xbox, USB, SDL XInput) after 2 min',
      );
      expect(roster.playerOne, 'a');
      expect(roster.disconnect('b'), isNull);
      roster.disconnect('a');
      expect(roster.playerOne, isNull);
    });

    test('sync finds what came and went; a new battery reading is no connect', () {
      final roster = PadRoster();
      expect(roster.sync([sense]), hasLength(1));
      final lines = roster.sync([xbox]);
      expect(lines, hasLength(2));
      expect(lines[0], startsWith('controller disconnected: DualSense'));
      expect(lines[1], startsWith('controller connected: Xbox'));
      expect(roster.sync([xbox.copyWith(battery: PadBattery(40))]), isEmpty);
      expect(roster.pad('b')!.battery!.percent, 40);
    });

    test('the log keeps the last forty lines with their times, and the report puts Player 1 first', () {
      final log = PadLog();
      for (var index = 0; index < 50; index++) {
        log.add('line $index', at: DateTime(2026, 10, 25, 9, 5, 7));
      }
      expect(log.lines, hasLength(PadLog.capacity));
      expect(log.lines.first, '09:05:07 line 10');
      final roster = PadRoster()
        ..connect(sense)
        ..connect(xbox)
        ..used('b');
      final report = PadLog.report(roster, log);
      expect(report[0], startsWith('Player 1: Xbox Wireless Controller'));
      expect(report[1], startsWith('Also: DualSense'));
      expect(report[2], 'Recent:');
      expect(PadLog.report(PadRoster(), PadLog()), ['none connected']);
    });

    test('battery texts', () {
      expect(PadBattery(80).reportText, '80%');
      expect(PadBattery(55, approximate: true, charging: true).reportText, 'about 55% charging');
      expect(PadBattery(10).low, isTrue);
      expect(PadBattery(10, charging: true).low, isFalse);
      expect(PadBattery(140).percent, 100);
    });
  });

  group('settings', () {
    test('the dead zone centres drift and keeps the edge', () {
      expect(StickDeadzone.apply(0.08, -0.05, 10), (0.0, 0.0));
      expect(StickDeadzone.apply(1, 0, 10).$1, closeTo(1, 1e-9));
      expect(StickDeadzone.apply(0.55, 0, 10).$1, closeTo(0.5, 1e-9));
      expect(StickDeadzone.apply(0.03, 0.02, 0), (0.03, 0.02));
    });

    test('games keep their own dead zones', () {
      final tuning = StickDeadzone.tuning(const InputTuning(leftDeadzone: 20), 8);
      expect(tuning.leftDeadzone, 20);
      expect(tuning.rightDeadzone, 8);
      expect(StickDeadzone.tuning(null, 0).leftDeadzone, 0);
    });

    test('the dead zone stage passes both axes on together', () {
      final out = <PadEvent>[];
      final stage = DeadzoneStage(out.add)..percent = 10;
      stage.handle(const PadAxisEvent('p', PadAxis.leftX, 0.05));
      expect(out, isEmpty, reason: 'drift stays inside');
      stage.handle(const PadAxisEvent('p', PadAxis.leftX, 1));
      expect(out.single, isA<PadAxisEvent>().having((event) => event.value, 'value', closeTo(1, 1e-9)));
      stage.handle(const PadButtonEvent('p', PadButton.south, down: true));
      expect(out.last, isA<PadButtonEvent>());
      stage.handle(const PadGone('p'));
      expect(out.last, isA<PadGone>());
    });

    test('Circle confirming swaps select and back and the hint glyphs', () {
      expect(ConfirmButton.command(PadCommand.select, circleConfirms: true), PadCommand.back);
      expect(ConfirmButton.command(PadCommand.back, circleConfirms: true), PadCommand.select);
      expect(ConfirmButton.command(PadCommand.options, circleConfirms: true), PadCommand.options);
      expect(ConfirmButton.command(PadCommand.select, circleConfirms: false), PadCommand.select);
      expect(ConfirmButton.glyphs('Enter / ✕', circleConfirms: true), 'Enter / ○');
      expect(ConfirmButton.glyphs('Esc / ○', circleConfirms: false), 'Esc / ○');
    });

    test('the navigator selects with Circle when it confirms', () {
      final commands = <PadCommand>[];
      final navigator = PadNavigator(commands.add)..circleConfirms = true;
      navigator.handle(const PadButtonEvent('p', PadButton.east, down: true));
      navigator.handle(const PadButtonEvent('p', PadButton.south, down: true));
      expect(commands, [PadCommand.select, PadCommand.back]);
      navigator.dispose();
    });

    test('light colours', () {
      expect(PadLight.theme.rgb, isNull);
      expect(PadLight.off.rgb, (0, 0, 0));
      expect(PadLight.parse('red'), PadLight.red);
      expect(PadLight.parse('nonsense'), PadLight.theme);
      expect(PadLight.parse(null), PadLight.theme);
    });
  });
}
