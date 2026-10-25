import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'pad_navigation.dart';

typedef _XInputGetStateNative = Uint32 Function(Uint32 index, Pointer<Uint8> state);
typedef _XInputGetState = int Function(int index, Pointer<Uint8> state);
typedef _GetProcAddressNative = Pointer<Void> Function(Pointer<Void> module, Pointer<Void> name);
typedef _GetProcAddress = Pointer<Void> Function(Pointer<Void> module, Pointer<Void> name);
typedef _LoadLibraryNative = Pointer<Void> Function(Pointer<Utf16> name);
typedef _JoyGetPosExNative = Uint32 Function(Uint32 id, Pointer<Uint32> info);
typedef _JoyGetPosEx = int Function(int id, Pointer<Uint32> info);
typedef _JoyGetDevCapsNative = Uint32 Function(IntPtr id, Pointer<Uint8> caps, Uint32 size);
typedef _JoyGetDevCaps = int Function(int id, Pointer<Uint8> caps, int size);
typedef _JoyConfigChangedNative = Uint32 Function(Uint32 flags);
typedef _JoyConfigChanged = int Function(int flags);

/// Controllers on Windows, polled 60 times a second: Xbox and other XInput pads through XInput
/// (with the Guide button from XInputGetStateEx), PlayStation pads (DualSense, DualShock 4),
/// which XInput does not see, through winmm's joystick API. A slot with nothing in it is only
/// asked again every two seconds (asking an empty slot is slow), which is also how a controller
/// plugged in later is found.
class WindowsPadSource implements PadSource {
  WindowsPadSource({this.every = const Duration(milliseconds: 16)});

  final Duration every;
  static const _rescan = Duration(seconds: 2);
  static const _sonyVendor = 0x054C;

  Timer? _timer;
  void Function(PadEvent)? _onEvent;
  _XInputGetState? _xinput;
  _JoyGetPosEx? _joyGetPosEx;
  _JoyGetDevCaps? _joyGetDevCaps;
  _JoyConfigChanged? _joyConfigChanged;
  Pointer<Uint8>? _state;
  Pointer<Uint32>? _joyInfo;
  Pointer<Uint8>? _caps;
  final Map<String, PadSnapshot> _last = {};
  final Set<int> _xinputConnected = {};
  final Map<int, ({int xMin, int xMax, int yMin, int yMax})> _sony = {};
  DateTime _lastRescan = DateTime.fromMillisecondsSinceEpoch(0);
  String _description = 'not started';

  @override
  String get description => _description;

  @override
  void start(void Function(PadEvent event) onEvent) {
    if (_timer != null) return;
    _onEvent = onEvent;
    final found = <String>[];
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final load = kernel.lookupFunction<_LoadLibraryNative, _LoadLibraryNative>('LoadLibraryW');
      final address = kernel.lookupFunction<_GetProcAddressNative, _GetProcAddress>('GetProcAddress');
      for (final name in ['xinput1_4.dll', 'xinput1_3.dll', 'xinput9_1_0.dll']) {
        final module = using((arena) => load(name.toNativeUtf16(allocator: arena)));
        if (module == nullptr) continue;
        // Ordinal 100 is XInputGetStateEx: XInputGetState with the Guide button.
        var function = address(module, Pointer.fromAddress(100));
        final ex = function != nullptr;
        if (!ex) {
          function = using((arena) => address(module, 'XInputGetState'.toNativeUtf8(allocator: arena).cast()));
        }
        if (function == nullptr) continue;
        _xinput = function.cast<NativeFunction<_XInputGetStateNative>>().asFunction<_XInputGetState>();
        found.add('$name${ex ? ' (Guide)' : ''}');
        break;
      }
    } on Object catch (error) {
      found.add('no XInput ($error)');
    }
    try {
      final winmm = DynamicLibrary.open('winmm.dll');
      _joyGetPosEx = winmm.lookupFunction<_JoyGetPosExNative, _JoyGetPosEx>('joyGetPosEx');
      _joyGetDevCaps = winmm.lookupFunction<_JoyGetDevCapsNative, _JoyGetDevCaps>('joyGetDevCapsW');
      _joyConfigChanged = winmm.lookupFunction<_JoyConfigChangedNative, _JoyConfigChanged>('joyConfigChanged');
      found.add('winmm');
    } on Object catch (error) {
      found.add('no winmm ($error)');
    }
    _state = calloc<Uint8>(16);
    _joyInfo = calloc<Uint32>(13);
    _caps = calloc<Uint8>(_capsSize);
    _description = found.join(', ');
    _timer = Timer.periodic(every, (_) => _poll());
  }

  /// sizeof(JOYCAPSW).
  static const _capsSize = 728;

  void _poll() {
    final now = DateTime.now();
    final rescan = now.difference(_lastRescan) >= _rescan;
    if (rescan) _lastRescan = now;
    try {
      _pollXInput(rescan);
    } on Object {
      // A reader that fails stays quiet; the keyboard still works.
    }
    try {
      _pollSony(rescan);
    } on Object {
      // As above.
    }
  }

  void _pollXInput(bool rescan) {
    final read = _xinput;
    final state = _state;
    if (read == null || state == null) return;
    for (var index = 0; index < 4; index++) {
      final connected = _xinputConnected.contains(index);
      if (!connected && !rescan) continue;
      final result = read(index, state);
      final id = 'xinput$index';
      if (result != 0) {
        if (connected) _gone(id);
        _xinputConnected.remove(index);
        continue;
      }
      _xinputConnected.add(index);
      // XINPUT_STATE: dwPacketNumber, then wButtons at 4, the triggers, sThumbLX at 8, sThumbLY at 10.
      final bytes = ByteDataView(state.asTypedList(16));
      _report(id, PadMaps.xinput(bytes.u16(4), _deadZone(bytes.s16(8)), _deadZone(bytes.s16(10))));
    }
  }

  void _pollSony(bool rescan) {
    final getPos = _joyGetPosEx;
    final info = _joyInfo;
    if (getPos == null || info == null) return;
    if (rescan) _findSony();
    for (final entry in _sony.entries.toList()) {
      final id = entry.key;
      info[0] = 52; // dwSize
      info[1] = 0xFF | 0x200; // JOY_RETURNALL | JOY_RETURNPOVCTS
      if (getPos(id, info) != 0) {
        _sony.remove(id);
        _gone('winmm$id');
        continue;
      }
      final range = entry.value;
      final x = PadMaps.scale(info[2], range.xMin, range.xMax);
      final y = PadMaps.scale(info[3], range.yMin, range.yMax);
      _report('winmm$id', PadMaps.sonyWinmm(info[8], info[10] & 0xFFFF, _dead(x), _dead(y)));
    }
  }

  /// XInput's own dead zone for the left stick (XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE).
  static int _deadZone(int value) => value.abs() < 7849 ? 0 : value;

  /// A resting stick is rarely at exactly its middle.
  static double _dead(double value) => value.abs() < 0.12 ? 0 : value;

  /// Looks through winmm's joystick slots for PlayStation controllers (only those: an XInput
  /// pad shows there too, and XInput reads it better).
  void _findSony() {
    final getCaps = _joyGetDevCaps;
    final getPos = _joyGetPosEx;
    final caps = _caps;
    final info = _joyInfo;
    if (getCaps == null || getPos == null || caps == null || info == null) return;
    // winmm keeps the list it read first; this makes it look again for controllers plugged in.
    _joyConfigChanged?.call(0);
    for (var id = 0; id < 16; id++) {
      if (_sony.containsKey(id)) continue;
      if (getCaps(id, caps, _capsSize) != 0) continue;
      final bytes = ByteDataView(caps.asTypedList(_capsSize));
      if (bytes.u16(0) != _sonyVendor) continue;
      info[0] = 52;
      info[1] = 0xFF;
      if (getPos(id, info) != 0) continue;
      // JOYCAPSW: wXmin at 68, wXmax 72, wYmin 76, wYmax 80.
      _sony[id] = (xMin: bytes.u32(68), xMax: bytes.u32(72), yMin: bytes.u32(76), yMax: bytes.u32(80));
    }
  }

  void _report(String id, PadSnapshot now) {
    final before = _last[id] ?? PadSnapshot.idle;
    _last[id] = now;
    for (final event in PadSnapshot.diff(id, before, now)) {
      _onEvent?.call(event);
    }
  }

  void _gone(String id) {
    if (_last.remove(id) != null) _onEvent?.call(PadGone(id));
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final pointer in [_state, _joyInfo, _caps]) {
      if (pointer != null) calloc.free(pointer);
    }
    _state = null;
    _joyInfo = null;
    _caps = null;
  }
}

/// Little-endian reads from native memory copied into Dart.
class ByteDataView {
  ByteDataView(List<int> bytes) : _bytes = bytes;
  final List<int> _bytes;

  int u16(int offset) => _bytes[offset] | _bytes[offset + 1] << 8;
  int s16(int offset) {
    final value = u16(offset);
    return value >= 0x8000 ? value - 0x10000 : value;
  }

  int u32(int offset) => u16(offset) | u16(offset + 2) << 16;
}
