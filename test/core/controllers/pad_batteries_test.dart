import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/controllers/pad_batteries.dart';
import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controllers/sdl_pads.dart';
import 'package:test/test.dart';

import '../../support/fake_sdl.dart';

/// A probe that answers what the test says, and counts what it was asked.
class FakeProbe implements PadBatteryProbe {
  final Map<String, PadBattery> bySerial = {};
  final asked = <(int?, int?, String?)>[];
  bool disposed = false;

  @override
  PadBattery? battery({int? vendor, int? product, String? serial}) {
    asked.add((vendor, product, serial));
    return bySerial[serial];
  }

  @override
  void dispose() => disposed = true;
}

/// A report of [length] bytes with [id] first and [status] at [at].
Uint8List report(int id, int length, int at, int status) => Uint8List(length)
  ..[0] = id
  ..[at] = status;

void main() {
  group('a PlayStation pad\'s own report, as hid-playstation reads it', () {
    test('DualSense over USB and Bluetooth', () {
      expect(SonyReports.battery(0x0CE6, report(0x01, 64, 53, 0x05)), PadBattery(55, charging: false));
      expect(SonyReports.battery(0x0CE6, report(0x01, 64, 53, 0x18)), PadBattery(85, charging: true));
      expect(
        SonyReports.battery(0x0CE6, report(0x01, 64, 53, 0x0A)),
        PadBattery(100, charging: false),
        reason: 'never above 100',
      );
      expect(SonyReports.battery(0x0CE6, report(0x01, 64, 53, 0x20)), PadBattery(100, charging: false), reason: 'full');
      expect(
        SonyReports.battery(0x0DF2, report(0x31, 78, 54, 0x03)),
        PadBattery(35, charging: false),
        reason: 'Edge, Bluetooth',
      );
      expect(
        SonyReports.battery(0x0CE6, report(0x01, 10, 5, 0x05)),
        isNull,
        reason: 'Bluetooth\'s short report has none',
      );
      expect(SonyReports.battery(0x0CE6, report(0x01, 64, 53, 0xA5)), isNull, reason: 'a charging error');
    });

    test('DualShock 4: on the cable it charges, then is full', () {
      expect(SonyReports.battery(0x09CC, report(0x01, 64, 30, 0x08)), PadBattery(85, charging: false));
      expect(SonyReports.battery(0x09CC, report(0x01, 64, 30, 0x0B)), PadBattery(100, charging: false));
      expect(SonyReports.battery(0x05C4, report(0x01, 64, 30, 0x14)), PadBattery(45, charging: true));
      expect(SonyReports.battery(0x05C4, report(0x01, 64, 30, 0x1A)), PadBattery(100, charging: true));
      expect(SonyReports.battery(0x05C4, report(0x01, 64, 30, 0x1B)), PadBattery(100, charging: false));
      expect(
        SonyReports.battery(0x09CC, report(0x11, 78, 32, 0x06)),
        PadBattery(65, charging: false),
        reason: 'Bluetooth',
      );
      expect(SonyReports.battery(0x0B13, report(0x01, 64, 30, 0x06)), isNull, reason: 'not a PlayStation pad');
    });
  });

  group('Linux\'s power supplies', () {
    late Directory root;

    void supply(String name, Map<String, String> files) {
      for (final MapEntry(:key, :value) in files.entries) {
        File('${root.path}/$name/$key')
          ..createSync(recursive: true)
          ..writeAsStringSync('$value\n');
      }
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('power_supply');
      supply('ps-controller-battery-a0:ab:51:00:00:01', {
        'type': 'Battery',
        'scope': 'Device',
        'capacity': '72',
        'status': 'Discharging',
        'device/uevent': 'DRIVER=playstation\nHID_ID=0005:0000054C:00000CE6\nHID_NAME=DualSense Wireless Controller\nHID_UNIQ=a0:ab:51:00:00:01',
      });
      supply('sony_controller_battery_00:11:22:33:44:55', {
        'type': 'Battery',
        'scope': 'Device',
        'capacity': '40',
        'status': 'Charging',
        'device/uevent': 'HID_ID=0003:0000054C:000009CC\nHID_UNIQ=00:11:22:33:44:55',
      });
      // The laptop's own battery, and a pad whose driver gives only a level.
      supply('BAT0', {'type': 'Battery', 'capacity': '90', 'status': 'Discharging'});
      supply('nintendo_switch_controller_battery_0', {
        'type': 'Battery',
        'scope': 'Device',
        'capacity_level': 'High',
        'device/uevent': 'HID_ID=0005:0000057E:00002009',
      });
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('each controller battery with a percentage, by its HID device', () {
      final found = LinuxPadBatteries.scan(root.path)..sort((a, b) => a.product.compareTo(b.product));
      expect(found.map((battery) => (battery.vendor, battery.product, battery.serial)), [
        (0x054C, 0x09CC, '00:11:22:33:44:55'),
        (0x054C, 0x0CE6, 'a0:ab:51:00:00:01'),
      ]);
      expect(found.last.battery, PadBattery(72, charging: false));
      expect(found.first.battery, PadBattery(40, charging: true));
    });

    test('matched to the pad by its serial, else as the only one of its kind', () {
      final probe = LinuxPadBatteries(root: root.path);
      expect(
        probe.battery(vendor: 0x054C, product: 0x0CE6, serial: 'A0-AB-51-00-00-01'),
        PadBattery(72, charging: false),
      );
      expect(
        probe.battery(vendor: 0x054C, product: 0x0CE6),
        PadBattery(72, charging: false),
        reason: 'the only DualSense',
      );
      expect(
        probe.battery(vendor: 0x054C, product: 0x0CE6, serial: '01-00-00-51-ab-a0'),
        PadBattery(72, charging: false),
        reason: 'the address in the other byte order',
      );
      expect(
        probe.battery(vendor: 0x054C, product: 0x0CE6, serial: 'ff:ff:ff:ff:ff:ff'),
        isNull,
        reason: 'another one',
      );
      expect(probe.battery(vendor: 0x057E, product: 0x2009), isNull, reason: 'a level only: SDL\'s stays');
      expect(probe.battery(vendor: 0x045E, product: 0x0B13), isNull);
    });

    test('two of a kind without serials are not guessed', () {
      final two = [
        SystemBattery(vendor: 1, product: 2, battery: PadBattery(10)),
        SystemBattery(vendor: 1, product: 2, battery: PadBattery(90)),
      ];
      expect(SystemBattery.pick(two, vendor: 1, product: 2), isNull);
      expect(SystemBattery.normalize('A0:AB:51'), 'a0ab51');
      expect(SystemBattery.normalize(''), isNull);
    });
  });

  group('SdlPadSource', () {
    test('a percentage where the system measures one, SDL\'s level where it does not', () {
      final probe = FakeProbe()..bySerial['a0:ab:51:00:00:01'] = PadBattery(72, charging: false);
      final sdl = FakeSdl()
        ..plug(dualSense(0), power: 2)
        ..plug(dualSense(1), power: 3)
        ..serials[0] = 'a0:ab:51:00:00:01';
      final source = SdlPadSource(sdl, batteries: probe)..poll();
      expect(source.pads.first.battery, PadBattery(72, charging: false));
      expect(source.pads.last.battery, const PadBattery.level(PadBatteryLevel.full, charging: false));
      expect(probe.asked.first, (0x054C, 0x0CE6, 'a0:ab:51:00:00:01'));
      // A second later the percentage moved.
      probe.bySerial['a0:ab:51:00:00:01'] = PadBattery(70, charging: false);
      for (var frame = 0; frame < 60; frame++) {
        source.poll();
      }
      expect(source.pads.first.battery!.percent, 70);
      source.stop();
      expect(probe.disposed, isTrue);
    });
  });
}
