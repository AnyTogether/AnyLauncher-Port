import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The key held to talk in party voice (or pressed to turn the microphone on and off), by USB HID
/// usage as the controls name keys, with what the system calls it: a Windows virtual-key code
/// and an X11 keysym. Letters, digits, F1-F12 and a few keys a hand rests near.
abstract final class TalkKeys {
  /// V, as the macOS launcher's ⌥V; the default controls leave it free.
  static const standard = 0x19;

  static final Map<int, (int, int)> _keys = {
    for (var index = 0; index < 26; index++) 0x04 + index: (0x41 + index, 0x61 + index),
    for (var index = 0; index < 9; index++) 0x1E + index: (0x31 + index, 0x31 + index),
    0x27: (0x30, 0x30),
    for (var index = 0; index < 12; index++) 0x3A + index: (0x70 + index, 0xFFBE + index),
    0x2B: (0x09, 0xFF09), // Tab
    0x2C: (0x20, 0x20), // Space
    0x35: (0xC0, 0x60), // `
    0x39: (0x14, 0xFFE5), // Caps Lock
    0xE0: (0xA2, 0xFFE3), // Left Ctrl
    0xE1: (0xA0, 0xFFE1), // Left Shift
    0xE2: (0xA4, 0xFFE9), // Left Alt
    0xE4: (0xA3, 0xFFE4), // Right Ctrl
    0xE5: (0xA1, 0xFFE2), // Right Shift
    0xE6: (0xA5, 0xFFEA), // Right Alt
  };

  static bool supported(int usage) => _keys.containsKey(usage & 0xFFFF);

  static int? virtualKey(int usage) => _keys[usage & 0xFFFF]?.$1;

  static int? keysym(int usage) => _keys[usage & 0xFFFF]?.$2;
}

/// Whether a key is down anywhere on the desktop, the game in front or not.
abstract class KeyStateReader {
  bool isDown(int usage);
  void close() {}

  /// Windows: GetAsyncKeyState. Linux: XQueryKeymap on the X server (X11, or XWayland while an
  /// X11 window such as the game is in front). null where neither is there; then the talk key
  /// works only while the launcher has the keyboard.
  static KeyStateReader? system() {
    try {
      if (Platform.isWindows) return _WindowsKeys();
      if (Platform.isLinux && (Platform.environment['DISPLAY'] ?? '').isNotEmpty) return _X11Keys.open();
    } on Object {
      return null;
    }
    return null;
  }
}

class _WindowsKeys extends KeyStateReader {
  _WindowsKeys()
    : _state = DynamicLibrary.open('user32.dll')
          .lookupFunction<Int16 Function(Int32), int Function(int)>('GetAsyncKeyState');

  final int Function(int) _state;

  @override
  bool isDown(int usage) {
    final key = TalkKeys.virtualKey(usage);
    return key != null && _state(key) & 0x8000 != 0;
  }
}

class _X11Keys extends KeyStateReader {
  _X11Keys(this._display, this._query, this._keycode, this._closeDisplay);

  static _X11Keys? open() {
    final library = DynamicLibrary.open('libX11.so.6');
    final openDisplay = library
        .lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>('XOpenDisplay');
    final display = openDisplay(nullptr);
    if (display == nullptr) return null;
    return _X11Keys(
      display,
      library
          .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>), int Function(Pointer<Void>, Pointer<Uint8>)>(
            'XQueryKeymap',
          ),
      library.lookupFunction<Uint8 Function(Pointer<Void>, UnsignedLong), int Function(Pointer<Void>, int)>(
        'XKeysymToKeycode',
      ),
      library.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XCloseDisplay'),
    );
  }

  final Pointer<Void> _display;
  final int Function(Pointer<Void>, Pointer<Uint8>) _query;
  final int Function(Pointer<Void>, int) _keycode;
  final int Function(Pointer<Void>) _closeDisplay;
  final Pointer<Uint8> _keys = calloc<Uint8>(32);
  bool _closed = false;

  @override
  bool isDown(int usage) {
    final keysym = TalkKeys.keysym(usage);
    if (keysym == null || _closed) return false;
    final code = _keycode(_display, keysym);
    if (code == 0) return false;
    _query(_display, _keys);
    return _keys[code >> 3] & (1 << (code & 7)) != 0;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closeDisplay(_display);
    calloc.free(_keys);
  }
}

/// Watches the talk key [every] while voice is on and says when it goes down or up; [ignore]
/// keeps it quiet (while typing in the launcher).
class TalkKeyWatch {
  TalkKeyWatch({
    required this.reader,
    required this.onChange,
    this.every = const Duration(milliseconds: 30),
    this.ignore,
  });

  final KeyStateReader reader;
  final void Function(bool down) onChange;
  final Duration every;
  final bool Function()? ignore;
  int usage = TalkKeys.standard;
  Timer? _timer;
  bool _down = false;

  bool get running => _timer != null;

  void start() {
    _timer ??= Timer.periodic(every, (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_down) {
      _down = false;
      onChange(false);
    }
  }

  void _poll() {
    final down = !(ignore?.call() ?? false) && reader.isDown(usage);
    if (down == _down) return;
    _down = down;
    onChange(down);
  }
}
