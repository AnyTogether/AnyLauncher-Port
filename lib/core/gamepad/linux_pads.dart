import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pad_navigation.dart';

typedef _OpenNative = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _Open = int Function(Pointer<Utf8> path, int flags);
typedef _IoctlNative = Int32 Function(Int32 fd, UnsignedLong request, VarArgs<(Pointer<Void>,)>);
typedef _Ioctl = int Function(int fd, int request, Pointer<Void> argument);
typedef _CloseNative = Int32 Function(Int32 fd);
typedef _Close = int Function(int fd);

/// A controller the kernel lists: its event node and what it is.
class LinuxPadDevice {
  const LinuxPadDevice({required this.event, required this.name, required this.vendor});

  /// event5 for /dev/input/event5.
  final String event;
  final String name;
  final int vendor;

  /// Microsoft's pads, whose X and Y the xpad driver reports swapped.
  bool get xbox => vendor == 0x045E;
}

/// Controllers on Linux through evdev: every input device the kernel gives a joystick handler
/// (js*) is read from its /dev/input/event* node (the logged-in user may read them on desktop
/// systems), one found later is picked up within two seconds, one unplugged is let go.
class LinuxPadSource implements PadSource {
  LinuxPadSource({this.devicesFile = '/proc/bus/input/devices', this.inputFolder = '/dev/input'});

  final String devicesFile;
  final String inputFolder;

  final Map<String, StreamSubscription<List<int>>> _reading = {};
  final Set<String> _refused = {};
  Timer? _timer;
  void Function(PadEvent)? _onEvent;
  String _description = 'not started';

  @override
  String get description => _description;

  /// The controllers in /proc/bus/input/devices' text: blocks whose handlers have a js node.
  static List<LinuxPadDevice> parseDevices(String text) {
    final found = <LinuxPadDevice>[];
    for (final block in text.split(RegExp(r'\n\s*\n'))) {
      final handlers = RegExp(r'^H: Handlers=(.*)$', multiLine: true).firstMatch(block)?.group(1) ?? '';
      final names = handlers.split(RegExp(r'\s+'));
      final event = names.where((name) => RegExp(r'^event\d+$').hasMatch(name)).firstOrNull;
      if (event == null || !names.any((name) => RegExp(r'^js\d+$').hasMatch(name))) continue;
      final name = RegExp(r'^N: Name="(.*)"$', multiLine: true).firstMatch(block)?.group(1) ?? event;
      final vendor = int.tryParse(RegExp(r'Vendor=([0-9a-fA-F]{4})').firstMatch(block)?.group(1) ?? '', radix: 16) ?? 0;
      found.add(LinuxPadDevice(event: event, name: name, vendor: vendor));
    }
    return found;
  }

  @override
  void start(void Function(PadEvent event) onEvent) {
    if (_timer != null) return;
    _onEvent = onEvent;
    _scan();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _scan());
  }

  void _scan() {
    List<LinuxPadDevice> devices;
    try {
      devices = parseDevices(File(devicesFile).readAsStringSync());
    } on FileSystemException {
      devices = const [];
    }
    for (final device in devices) {
      if (_reading.containsKey(device.event) || _refused.contains(device.event)) continue;
      _open(device);
    }
    _description = [
      for (final device in devices) '${device.name} (${_reading.containsKey(device.event) ? 'read' : 'no permission'})',
    ].join(', ');
  }

  void _open(LinuxPadDevice device) {
    final path = '$inputFolder/${device.event}';
    final decoder = EvdevDecoder(device.event, xbox: device.xbox, ranges: _ranges(path));
    try {
      _reading[device.event] = File(path).openRead().listen(
        (chunk) {
          for (final event in decoder.add(chunk)) {
            _onEvent?.call(event);
          }
        },
        onError: (Object _) => _close(device.event, refused: true),
        onDone: () => _close(device.event),
        cancelOnError: true,
      );
    } on FileSystemException {
      _refused.add(device.event);
    }
  }

  void _close(String event, {bool refused = false}) {
    unawaited(_reading.remove(event)?.cancel());
    // A node that could not be read is not tried again until it goes away and comes back.
    if (refused && File('$inputFolder/$event').existsSync()) _refused.add(event);
    _onEvent?.call(PadGone(event));
  }

  /// The left stick's range (EVIOCGABS on ABS_X and ABS_Y), null when the kernel cannot be asked.
  static Map<int, (int, int)>? _ranges(String path) {
    try {
      final libc = DynamicLibrary.process();
      final open = libc.lookupFunction<_OpenNative, _Open>('open');
      final ioctl = libc.lookupFunction<_IoctlNative, _Ioctl>('ioctl');
      final close = libc.lookupFunction<_CloseNative, _Close>('close');
      return using((arena) {
        final fd = open(path.toNativeUtf8(allocator: arena), 0 /* O_RDONLY */);
        if (fd < 0) return null;
        try {
          final info = arena<Int32>(6);
          final ranges = <int, (int, int)>{};
          for (final axis in [0, 1]) {
            // EVIOCGABS(axis) = _IOR('E', 0x40 + axis, struct input_absinfo): value, minimum, maximum...
            if (ioctl(fd, 0x80184540 + axis, info.cast()) == 0) ranges[axis] = (info[1], info[2]);
          }
          return ranges;
        } finally {
          close(fd);
        }
      });
    } on Object {
      return null;
    }
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final subscription in _reading.values) {
      unawaited(subscription.cancel());
    }
    _reading.clear();
  }
}

/// struct input_event (64-bit: a 16-byte time, then type, code and value) as pad events.
class EvdevDecoder {
  EvdevDecoder(this.pad, {this.xbox = false, Map<int, (int, int)>? ranges}) : _ranges = {...?ranges};

  final String pad;
  final bool xbox;
  final Map<int, (int, int)> _ranges;
  final BytesBuilder _pending = BytesBuilder();

  static const size = 24;
  static const _key = 1;
  static const _absolute = 3;

  List<PadEvent> add(List<int> chunk) {
    _pending.add(chunk);
    final bytes = _pending.takeBytes();
    final whole = bytes.length - bytes.length % size;
    if (whole < bytes.length) _pending.add(bytes.sublist(whole));
    final data = ByteData.sublistView(bytes);
    final events = <PadEvent>[];
    for (var offset = 0; offset < whole; offset += size) {
      final type = data.getUint16(offset + 16, Endian.little);
      final code = data.getUint16(offset + 18, Endian.little);
      final value = data.getInt32(offset + 20, Endian.little);
      events.addAll(decode(type, code, value));
    }
    return events;
  }

  /// One event: a key (a value of 2 is the key repeating, not a press), or the left stick or the
  /// hat (a D-pad reported as an axis).
  List<PadEvent> decode(int type, int code, int value) {
    if (type == _key && value != 2) {
      final button = PadMaps.evdevKey(code, xbox: xbox);
      return button == null ? const [] : [PadButtonEvent(pad, button, down: value != 0)];
    }
    if (type != _absolute) return const [];
    switch (code) {
      case 0 || 1:
        final (minimum, maximum) = _ranges[code] ?? _guess(value);
        final scaled = PadMaps.scale(value, minimum, maximum);
        return [PadAxisEvent(pad, code == 0 ? PadAxis.leftX : PadAxis.leftY, scaled.abs() < 0.12 ? 0 : scaled)];
      case 0x10 || 0x11:
        final (negative, positive) = code == 0x10
            ? (PadButton.dpadLeft, PadButton.dpadRight)
            : (PadButton.dpadUp, PadButton.dpadDown);
        return [PadButtonEvent(pad, negative, down: value < 0), PadButtonEvent(pad, positive, down: value > 0)];
    }
    return const [];
  }

  bool _signed = false;

  /// Without the kernel's range: a stick seen outside 0 to 255 is signed 16-bit from then on.
  (int, int) _guess(int value) {
    if (value < 0 || value > 255) _signed = true;
    return _signed ? (-32768, 32767) : (0, 255);
  }
}
