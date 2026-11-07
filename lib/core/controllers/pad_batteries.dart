import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pad_info.dart';

/// A controller's battery as the system measures it, where SDL2 gives only four levels: Linux's
/// power supply class (/sys/class/power_supply, which hid-playstation, hid-sony and other drivers
/// fill with a percentage), and on Windows the DualSense's and DualShock 4's own input report,
/// read beside SDL. The Mac shows a percentage from the GameController framework; this is the
/// same number where the system has one, and SDL2's level stays where it has none.
abstract class PadBatteryProbe {
  /// The battery of the pad with these USB numbers and (when SDL has it) serial, or null when
  /// the system has no percentage for it.
  PadBattery? battery({int? vendor, int? product, String? serial});

  void dispose() {}

  /// The probe for this system: Linux's power supplies, Windows' PlayStation pads, else none.
  static PadBatteryProbe? forSystem() {
    if (Platform.isLinux) return LinuxPadBatteries();
    if (Platform.isWindows) return WindowsSonyBatteries();
    return null;
  }
}

/// One battery the system lists for a controller.
class SystemBattery {
  const SystemBattery({required this.vendor, required this.product, required this.battery, this.serial});
  final int vendor;
  final int product;

  /// The pad's serial as the system has it (its Bluetooth address for a PlayStation pad).
  final String? serial;
  final PadBattery battery;

  /// A serial in one form for comparing: its hex digits, lowercase ("A0:AB:51" and "a0ab51" are
  /// the same pad).
  static String? normalize(String? serial) {
    if (serial == null) return null;
    final digits = serial.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');
    return digits.isEmpty ? null : digits;
  }

  /// The battery of the pad with [vendor] and [product]: the one with its [serial], else the only
  /// one of that kind; null when none or several could be it.
  static PadBattery? pick(List<SystemBattery> batteries, {int? vendor, int? product, String? serial}) {
    if (vendor == null || product == null) return null;
    final same = [
      for (final battery in batteries)
        if (battery.vendor == vendor && battery.product == product) battery,
    ];
    final wanted = normalize(serial);
    if (wanted != null) {
      // A Bluetooth address may come in either byte order (SDL reads it from the pad's report).
      final reversed = wanted.length == 12
          ? [for (var at = 10; at >= 0; at -= 2) wanted.substring(at, at + 2)].join()
          : wanted;
      final match = same.where((battery) {
        final have = normalize(battery.serial);
        return have == wanted || have == reversed;
      }).firstOrNull;
      if (match != null) return match.battery;
    }
    return same.length == 1 && (wanted == null || normalize(same.single.serial) == null) ? same.single.battery : null;
  }
}

/// Linux: the power supplies a controller's driver adds (scope Device, type Battery), with their
/// capacity in percent and whether they charge, matched to the pad by the HID device they belong
/// to (its vendor and product, and its Bluetooth address).
class LinuxPadBatteries implements PadBatteryProbe {
  LinuxPadBatteries({this.root = '/sys/class/power_supply', this.every = const Duration(seconds: 5)});

  final String root;

  /// How long one look at the folder holds.
  final Duration every;

  List<SystemBattery> _batteries = const [];
  DateTime? _read;

  @override
  PadBattery? battery({int? vendor, int? product, String? serial}) {
    final now = DateTime.now();
    if (_read == null || now.difference(_read!) >= every) {
      _read = now;
      _batteries = scan(root);
    }
    return SystemBattery.pick(_batteries, vendor: vendor, product: product, serial: serial);
  }

  @override
  void dispose() {}

  /// Every controller battery under [root] with a percentage.
  static List<SystemBattery> scan(String root) {
    final batteries = <SystemBattery>[];
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(root).listSync(followLinks: false);
    } on FileSystemException {
      return batteries;
    }
    for (final entry in entries) {
      final folder = entry.path;
      String? read(String name) {
        try {
          return File('$folder/$name').readAsStringSync().trim();
        } on FileSystemException {
          return null;
        }
      }

      if (read('type') != 'Battery' || read('scope') != 'Device') continue;
      final capacity = int.tryParse(read('capacity') ?? '');
      if (capacity == null) continue;
      final hid = hidOf(read('device/uevent') ?? '');
      if (hid == null) continue;
      final status = read('status');
      batteries.add(
        SystemBattery(
          vendor: hid.vendor,
          product: hid.product,
          serial: hid.serial,
          battery: PadBattery(capacity, charging: status == null || status == 'Unknown' ? null : status == 'Charging'),
        ),
      );
    }
    return batteries;
  }

  /// A HID device's uevent: HID_ID=0005:0000054C:00000CE6 and HID_UNIQ=a0:ab:51:…
  static ({int vendor, int product, String? serial})? hidOf(String uevent) {
    String? value(String key) {
      for (final line in uevent.split('\n')) {
        if (line.startsWith('$key=')) return line.substring(key.length + 1).trim();
      }
      return null;
    }

    final id = value('HID_ID')?.split(':');
    if (id == null || id.length != 3) return null;
    final vendor = int.tryParse(id[1], radix: 16);
    final product = int.tryParse(id[2], radix: 16);
    if (vendor == null || product == null) return null;
    final serial = value('HID_UNIQ');
    return (vendor: vendor, product: product, serial: serial == null || serial.isEmpty ? null : serial);
  }
}

/// The battery byte in a PlayStation pad's input report, as Linux's hid-playstation reads it.
abstract final class SonyReports {
  static const vendor = 0x054C;
  static const dualSense = {0x0CE6, 0x0DF2};
  static const dualShock4 = {0x05C4, 0x09CC, 0x0BA0};

  /// The battery in [report] (its report ID first, as Windows gives it) from a pad of [product];
  /// null for a report without one (a Bluetooth pad still in its short mode) or a state that
  /// is an error.
  static PadBattery? battery(int product, Uint8List report) {
    if (report.isEmpty) return null;
    if (dualSense.contains(product)) {
      final at = switch (report[0]) {
        0x01 when report.length >= 64 => 53,
        0x31 when report.length >= 78 => 54,
        _ => null,
      };
      if (at == null) return null;
      final status = report[at];
      final level = status & 0x0F;
      return switch (status >> 4) {
        0x0 => PadBattery(level * 10 + 5 > 100 ? 100 : level * 10 + 5, charging: false),
        0x1 => PadBattery(level * 10 + 5 > 100 ? 100 : level * 10 + 5, charging: true),
        0x2 => PadBattery(100, charging: false),
        _ => null,
      };
    }
    if (dualShock4.contains(product)) {
      final at = switch (report[0]) {
        0x01 when report.length >= 64 => 30,
        0x11 when report.length >= 78 => 32,
        _ => null,
      };
      if (at == null) return null;
      final status = report[at];
      final level = status & 0x0F;
      if (status & 0x10 == 0) return PadBattery(level < 10 ? level * 10 + 5 : 100, charging: false);
      return switch (level) {
        < 10 => PadBattery(level * 10 + 5, charging: true),
        10 => PadBattery(100, charging: true),
        11 => PadBattery(100, charging: false),
        _ => null,
      };
    }
    return null;
  }
}

/// Windows: the DualSense's and DualShock 4's batteries from their own input reports, every
/// half minute in a background isolate: each Sony HID device opened for reading (shared, beside
/// SDL, which keeps its own reports), one report read with a short wait, closed again. Xbox pads
/// keep XInput's four levels.
class WindowsSonyBatteries implements PadBatteryProbe {
  WindowsSonyBatteries({this.every = const Duration(seconds: 30)});

  final Duration every;
  List<SystemBattery> _batteries = const [];
  Timer? _timer;
  bool _reading = false;

  @override
  PadBattery? battery({int? vendor, int? product, String? serial}) {
    if (vendor != SonyReports.vendor) return null;
    if (_timer == null) {
      _timer = Timer.periodic(every, (_) => _refresh());
      _refresh();
    }
    return SystemBattery.pick(_batteries, vendor: vendor, product: product, serial: serial);
  }

  void _refresh() {
    if (_reading) return;
    _reading = true;
    Isolate.run(_WindowsHid.scan)
        .then((found) => _batteries = found, onError: (Object _) {})
        .whenComplete(() => _reading = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// The few Win32 calls reading a HID device takes (setupapi, hid, kernel32), for 64-bit Windows.
abstract final class _WindowsHid {
  static const _presentInterfaces = 0x00000002 | 0x00000010; // DIGCF_PRESENT | DIGCF_DEVICEINTERFACE
  static const _genericRead = 0x80000000;
  static const _shareReadWrite = 0x00000003;
  static const _openExisting = 3;
  static const _overlapped = 0x40000000;
  static const _waitMs = 250;

  static List<SystemBattery> scan() {
    final setup = DynamicLibrary.open('setupapi.dll');
    final hid = DynamicLibrary.open('hid.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final getHidGuid = hid.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>(
      'HidD_GetHidGuid',
    );
    final getClassDevs = setup
        .lookupFunction<
          IntPtr Function(Pointer<Uint8>, Pointer<Utf16>, IntPtr, Uint32),
          int Function(Pointer<Uint8>, Pointer<Utf16>, int, int)
        >('SetupDiGetClassDevsW');
    final enumInterfaces = setup
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint8>),
          int Function(int, Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>)
        >('SetupDiEnumDeviceInterfaces');
    final interfaceDetail = setup
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
          int Function(int, Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
        >('SetupDiGetDeviceInterfaceDetailW');
    final destroyList = setup.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetupDiDestroyDeviceInfoList');
    final createFile = kernel
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
        >('CreateFileW');
    final closeHandle = kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
    final getAttributes = hid.lookupFunction<Uint8 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>(
      'HidD_GetAttributes',
    );
    final getSerial = hid
        .lookupFunction<Uint8 Function(IntPtr, Pointer<Uint16>, Uint32), int Function(int, Pointer<Uint16>, int)>(
          'HidD_GetSerialNumberString',
        );
    final createEvent = kernel
        .lookupFunction<
          IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
          int Function(Pointer<Void>, int, int, Pointer<Utf16>)
        >('CreateEventW');
    final readFile = kernel
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>)
        >('ReadFile');
    final waitFor = kernel.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
      'WaitForSingleObject',
    );
    final overlappedResult = kernel
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Pointer<Uint32>, Int32),
          int Function(int, Pointer<Uint8>, Pointer<Uint32>, int)
        >('GetOverlappedResult');
    final cancelIo = kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CancelIo');

    final found = <SystemBattery>[];
    using((arena) {
      final guid = arena<Uint8>(16);
      getHidGuid(guid);
      final list = getClassDevs(guid, nullptr, 0, _presentInterfaces);
      if (list == -1 || list == 0) return;
      try {
        // SP_DEVICE_INTERFACE_DATA: cbSize, the class GUID, flags, a pointer: 32 bytes.
        final data = arena<Uint8>(32);
        final required = arena<Uint32>();
        for (var index = 0; index < 128; index++) {
          data.asTypedList(32).fillRange(0, 32, 0);
          data.cast<Uint32>().value = 32;
          if (enumInterfaces(list, nullptr, guid, index, data) == 0) break;
          required.value = 0;
          interfaceDetail(list, data, nullptr, 0, required, nullptr);
          final size = required.value;
          if (size < 8 || size > 4096) continue;
          final detail = calloc<Uint8>(size);
          try {
            // SP_DEVICE_INTERFACE_DETAIL_DATA_W: cbSize 8 on 64-bit, the path from byte 4.
            detail.cast<Uint32>().value = 8;
            if (interfaceDetail(list, data, detail, size, nullptr, nullptr) == 0) continue;
            final path = (detail + 4).cast<Utf16>();
            final battery = _read(
              path,
              createFile: createFile,
              closeHandle: closeHandle,
              getAttributes: getAttributes,
              getSerial: getSerial,
              createEvent: createEvent,
              readFile: readFile,
              waitFor: waitFor,
              overlappedResult: overlappedResult,
              cancelIo: cancelIo,
            );
            if (battery != null) found.add(battery);
          } finally {
            calloc.free(detail);
          }
        }
      } finally {
        destroyList(list);
      }
    });
    return found;
  }

  static SystemBattery? _read(
    Pointer<Utf16> path, {
    required int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) createFile,
    required int Function(int) closeHandle,
    required int Function(int, Pointer<Uint8>) getAttributes,
    required int Function(int, Pointer<Uint16>, int) getSerial,
    required int Function(Pointer<Void>, int, int, Pointer<Utf16>) createEvent,
    required int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>) readFile,
    required int Function(int, int) waitFor,
    required int Function(int, Pointer<Uint8>, Pointer<Uint32>, int) overlappedResult,
    required int Function(int) cancelIo,
  }) {
    // Asked first without access: what the device is, before reading anything from it.
    final probe = createFile(path, 0, _shareReadWrite, nullptr, _openExisting, 0, 0);
    if (probe == -1) return null;
    int vendor;
    int product;
    try {
      final attributes = calloc<Uint8>(12);
      try {
        attributes.cast<Uint32>().value = 12;
        if (getAttributes(probe, attributes) == 0) return null;
        vendor = (attributes + 4).cast<Uint16>().value;
        product = (attributes + 6).cast<Uint16>().value;
      } finally {
        calloc.free(attributes);
      }
    } finally {
      closeHandle(probe);
    }
    if (vendor != SonyReports.vendor ||
        !(SonyReports.dualSense.contains(product) || SonyReports.dualShock4.contains(product))) {
      return null;
    }
    final device = createFile(path, _genericRead, _shareReadWrite, nullptr, _openExisting, _overlapped, 0);
    if (device == -1) return null;
    final event = createEvent(nullptr, 1, 0, nullptr);
    final serialBuffer = calloc<Uint16>(128);
    final buffer = calloc<Uint8>(1024);
    // OVERLAPPED on 64-bit: Internal, InternalHigh, the offset, hEvent at byte 24. Zeroed, so a
    // read that never started is never waited for.
    final overlapped = calloc<Uint8>(32);
    final count = calloc<Uint32>();
    try {
      String? serial;
      if (getSerial(device, serialBuffer, 256) != 0) {
        serial = serialBuffer.cast<Utf16>().toDartString();
      }
      if (event == 0) return null;
      (overlapped + 24).cast<IntPtr>().value = event;
      Uint8List? report;
      for (var attempt = 0; attempt < 3 && report == null; attempt++) {
        overlapped.asTypedList(24).fillRange(0, 24, 0);
        final done = readFile(device, buffer, 1024, nullptr, overlapped);
        if (done == 0 && waitFor(event, _waitMs) != 0) {
          // Nothing within the wait: the read is called off, and waited for until it is.
          cancelIo(device);
          overlappedResult(device, overlapped, count, 1);
          break;
        }
        if (overlappedResult(device, overlapped, count, 0) == 0) break;
        final bytes = Uint8List.fromList(buffer.asTypedList(count.value));
        if (SonyReports.battery(product, bytes) != null) report = bytes;
      }
      final battery = report == null ? null : SonyReports.battery(product, report);
      return battery == null ? null : SystemBattery(vendor: vendor, product: product, serial: serial, battery: battery);
    } finally {
      calloc.free(count);
      calloc.free(overlapped);
      calloc.free(buffer);
      calloc.free(serialBuffer);
      if (event != 0) closeHandle(event);
      closeHandle(device);
    }
  }
}
