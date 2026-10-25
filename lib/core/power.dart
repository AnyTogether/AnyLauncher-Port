import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The computer's power: on its battery, and how full that is.
class PowerState {
  const PowerState({required this.onBattery, this.level});

  /// On mains power (or a computer without a battery).
  static const mains = PowerState(onBattery: false);

  /// Below this, on battery, nothing is prepared in the background.
  static const lowLevel = 30;

  final bool onBattery;

  /// Percent, null when the battery does not say.
  final int? level;

  /// Running on a battery below [lowLevel] (or one that does not say how full it is).
  bool get low => onBattery && (level ?? 0) < lowLevel;

  @override
  bool operator ==(Object other) => other is PowerState && other.onBattery == onBattery && other.level == level;

  @override
  int get hashCode => Object.hash(onBattery, level);

  @override
  String toString() => onBattery ? 'battery ${level ?? '?'}%' : 'mains';
}

/// Reads the power: GetSystemPowerStatus on Windows, /sys/class/power_supply on Linux; anything
/// else counts as mains.
abstract final class Power {
  static PowerState current() {
    try {
      if (Platform.isWindows) return _windows();
      if (Platform.isLinux) return fromSysfs('/sys/class/power_supply');
    } on Object {
      // Not known: as on mains, the old behaviour.
    }
    return PowerState.mains;
  }

  /// The power from a power_supply folder: a mains or USB supply online means plugged in; else
  /// a battery discharging is on battery, with the capacity of the fullest one.
  static PowerState fromSysfs(String root) {
    final folder = Directory(root);
    if (!folder.existsSync()) return PowerState.mains;
    var plugged = false;
    var discharging = false;
    int? level;
    for (final entry in folder.listSync()) {
      String read(String name) {
        try {
          return File(p.join(entry.path, name)).readAsStringSync().trim();
        } on FileSystemException {
          return '';
        }
      }

      final type = read('type');
      if (type == 'Mains' || type == 'USB' || type == 'USB_C' || type == 'USB_PD') {
        if (read('online') == '1') plugged = true;
      } else if (type == 'Battery') {
        // A peripheral's battery (a mouse, a pad) says scope=Device: not the computer's.
        if (read('scope') == 'Device') continue;
        if (read('status') == 'Discharging') discharging = true;
        final capacity = int.tryParse(read('capacity'));
        if (capacity != null && (level == null || capacity > level)) level = capacity;
      }
    }
    if (plugged || !discharging) return PowerState(onBattery: false, level: level);
    return PowerState(onBattery: true, level: level);
  }

  /// SYSTEM_POWER_STATUS: ACLineStatus 0 offline, 1 online, 255 unknown; BatteryFlag 128 no
  /// battery; BatteryLifePercent 255 unknown.
  static PowerState fromWindowsStatus({required int acLine, required int batteryFlag, required int percent}) {
    if (batteryFlag == 128 || acLine != 0) return PowerState(onBattery: false, level: percent == 255 ? null : percent);
    return PowerState(onBattery: true, level: percent == 255 ? null : percent);
  }

  static PowerState _windows() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final status = kernel.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'GetSystemPowerStatus',
    );
    final buffer = calloc<Uint8>(12);
    try {
      if (status(buffer) == 0) return PowerState.mains;
      return fromWindowsStatus(acLine: buffer[0], batteryFlag: buffer[1], percent: buffer[2]);
    } finally {
      calloc.free(buffer);
    }
  }
}
