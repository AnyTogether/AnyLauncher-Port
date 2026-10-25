import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'feel.dart';
import 'pad_navigation.dart';

typedef _OpenNative = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _Open = int Function(Pointer<Utf8> path, int flags);
typedef _IoctlNative = Int32 Function(Int32 fd, UnsignedLong request, VarArgs<(Pointer<Void>,)>);
typedef _Ioctl = int Function(int fd, int request, Pointer<Void> argument);
typedef _CloseNative = Int32 Function(Int32 fd);
typedef _Close = int Function(int fd);
typedef _WriteNative = IntPtr Function(Int32 fd, Pointer<Uint8> buffer, IntPtr count);
typedef _Write = int Function(int fd, Pointer<Uint8> buffer, int count);

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
/// systems), one found later is picked up within two seconds, one unplugged is let go. A pad
/// with force feedback (FF_RUMBLE) gives the launcher's pulses through the same node opened for
/// writing; one without, or a node the user may not write, stays still.
class LinuxPadSource implements PadSource, PadRumble {
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
    _rumblers.remove(event)?.close();
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

  /// Each pad's force feedback, opened the first time a pulse goes to it; null where it has none.
  final Map<String, EvdevRumbler?> _rumblers = {};

  @override
  PadRumble? get motors => this;

  @override
  bool canRumble(String pad) =>
      _reading.containsKey(pad) && (_rumblers.putIfAbsent(pad, () => EvdevRumbler.open('$inputFolder/$pad')) != null);

  @override
  void rumble(String pad, double strong, double weak, Duration length) {
    if (!canRumble(pad)) return;
    _rumblers[pad]?.rumble(strong, weak, length);
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final rumbler in _rumblers.values) {
      rumbler?.close();
    }
    _rumblers.clear();
    for (final subscription in _reading.values) {
      unawaited(subscription.cancel());
    }
    _reading.clear();
  }
}

/// Force feedback through an evdev node: one FF_RUMBLE effect uploaded (EVIOCSFF) and played by
/// writing an EV_FF event; the kernel stops it after its own length, and a pulse of zero stops it
/// at once.
class EvdevRumbler {
  EvdevRumbler._(this._fd, this._id, this._write, this._ioctl, this._closeFd);

  final int _fd;
  int _id;
  final _Write _write;
  final _Ioctl _ioctl;
  final _Close _closeFd;
  bool _closed = false;

  /// EVIOCSFF: _IOW('E', 0x80, struct ff_effect), 48 bytes on 64-bit systems.
  static const uploadRequest = 0x40304580;
  static const effectSize = 48;
  static const _rumbleType = 0x50; // FF_RUMBLE
  static const _forceFeedback = 0x15; // EV_FF

  /// struct ff_effect for a rumble: type, id (-1 asks for a new one), the replay's length in
  /// ms, then the strong and weak magnitudes at offset 16.
  static Uint8List effect(int id, double strong, double weak, Duration length) {
    final bytes = ByteData(effectSize);
    bytes.setUint16(0, _rumbleType, Endian.little);
    bytes.setInt16(2, id, Endian.little);
    bytes.setUint16(10, length.inMilliseconds.clamp(0, 0xFFFF), Endian.little);
    bytes.setUint16(16, (strong.clamp(0.0, 1.0) * 0xFFFF).round(), Endian.little);
    bytes.setUint16(18, (weak.clamp(0.0, 1.0) * 0xFFFF).round(), Endian.little);
    return bytes.buffer.asUint8List();
  }

  /// struct input_event that plays (1) or stops (0) effect [id].
  static Uint8List playEvent(int id, {required bool play}) {
    final bytes = ByteData(EvdevDecoder.size);
    bytes.setUint16(16, _forceFeedback, Endian.little);
    bytes.setUint16(18, id, Endian.little);
    bytes.setInt32(20, play ? 1 : 0, Endian.little);
    return bytes.buffer.asUint8List();
  }

  /// Opens [path] for writing and uploads a silent rumble; null when the node cannot be written
  /// or the pad has no rumble.
  static EvdevRumbler? open(String path) {
    try {
      final libc = DynamicLibrary.process();
      final openFd = libc.lookupFunction<_OpenNative, _Open>('open');
      final ioctl = libc.lookupFunction<_IoctlNative, _Ioctl>('ioctl');
      final close = libc.lookupFunction<_CloseNative, _Close>('close');
      final write = libc.lookupFunction<_WriteNative, _Write>('write');
      final fd = using((arena) => openFd(path.toNativeUtf8(allocator: arena), 2 | 0x800 /* O_RDWR | O_NONBLOCK */));
      if (fd < 0) return null;
      final id = _upload(ioctl, fd, -1, 0, 0, Duration.zero);
      if (id == null) {
        close(fd);
        return null;
      }
      return EvdevRumbler._(fd, id, write, ioctl, close);
    } on Object {
      return null;
    }
  }

  static int? _upload(_Ioctl ioctl, int fd, int id, double strong, double weak, Duration length) => using((arena) {
    final buffer = arena<Uint8>(effectSize);
    buffer.asTypedList(effectSize).setAll(0, effect(id, strong, weak, length));
    if (ioctl(fd, uploadRequest, buffer.cast()) != 0) return null;
    return ByteData.sublistView(buffer.asTypedList(effectSize)).getInt16(2, Endian.little);
  });

  void rumble(double strong, double weak, Duration length) {
    if (_closed) return;
    final play = (strong > 0 || weak > 0) && length > Duration.zero;
    if (play) {
      final id = _upload(_ioctl, _fd, _id, strong, weak, length);
      if (id == null) return;
      _id = id;
    }
    using((arena) {
      final event = playEvent(_id, play: play);
      final buffer = arena<Uint8>(event.length);
      buffer.asTypedList(event.length).setAll(0, event);
      _write(_fd, buffer, event.length);
    });
  }

  void close() {
    if (_closed) return;
    rumble(0, 0, Duration.zero);
    _closed = true;
    _closeFd(_fd);
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
