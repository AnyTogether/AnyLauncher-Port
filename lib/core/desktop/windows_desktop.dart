import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'desktop.dart';

// user32, gdi32 and kernel32, as far as the launcher needs them. Every handle is an IntPtr.
typedef _H = IntPtr;

final class _Win32 {
  _Win32() {
    final user = DynamicLibrary.open('user32.dll');
    final gdi = DynamicLibrary.open('gdi32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    findWindowEx = user
        .lookupFunction<
          _H Function(_H, _H, Pointer<Utf16>, Pointer<Utf16>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowExW');
    getWindowThreadProcessId = user
        .lookupFunction<Uint32 Function(_H, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
          'GetWindowThreadProcessId',
        );
    isWindowVisible = user.lookupFunction<Int32 Function(_H), int Function(int)>('IsWindowVisible');
    isIconic = user.lookupFunction<Int32 Function(_H), int Function(int)>('IsIconic');
    getWindow = user.lookupFunction<_H Function(_H, Uint32), int Function(int, int)>('GetWindow');
    getWindowRect = user.lookupFunction<Int32 Function(_H, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
      'GetWindowRect',
    );
    getClientRect = user.lookupFunction<Int32 Function(_H, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
      'GetClientRect',
    );
    clientToScreen = user.lookupFunction<Int32 Function(_H, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
      'ClientToScreen',
    );
    getClassName = user
        .lookupFunction<Int32 Function(_H, Pointer<Utf16>, Int32), int Function(int, Pointer<Utf16>, int)>(
          'GetClassNameW',
        );
    getForegroundWindow = user.lookupFunction<_H Function(), int Function()>('GetForegroundWindow');
    setForegroundWindow = user.lookupFunction<Int32 Function(_H), int Function(int)>('SetForegroundWindow');
    bringWindowToTop = user.lookupFunction<Int32 Function(_H), int Function(int)>('BringWindowToTop');
    showWindow = user.lookupFunction<Int32 Function(_H, Int32), int Function(int, int)>('ShowWindow');
    setWindowPos = user
        .lookupFunction<
          Int32 Function(_H, _H, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)
        >('SetWindowPos');
    attachThreadInput = user.lookupFunction<Int32 Function(Uint32, Uint32, Int32), int Function(int, int, int)>(
      'AttachThreadInput',
    );
    sendInput = user
        .lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>(
          'SendInput',
        );
    postMessage = user.lookupFunction<Int32 Function(_H, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>(
      'PostMessageW',
    );
    monitorFromWindow = user.lookupFunction<_H Function(_H, Uint32), int Function(int, int)>('MonitorFromWindow');
    getMonitorInfo = user.lookupFunction<Int32 Function(_H, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
      'GetMonitorInfoW',
    );
    getDC = user.lookupFunction<_H Function(_H), int Function(int)>('GetDC');
    releaseDC = user.lookupFunction<Int32 Function(_H, _H), int Function(int, int)>('ReleaseDC');
    printWindow = user.lookupFunction<Int32 Function(_H, _H, Uint32), int Function(int, int, int)>('PrintWindow');
    registerClassEx = user.lookupFunction<Uint16 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'RegisterClassExW',
    );
    createWindowEx = user
        .lookupFunction<
          _H Function(
            Uint32,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Uint32,
            Int32,
            Int32,
            Int32,
            Int32,
            _H,
            _H,
            _H,
            Pointer<Void>,
          ),
          int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int, int, int, int, Pointer<Void>)
        >('CreateWindowExW');
    destroyWindow = user.lookupFunction<Int32 Function(_H), int Function(int)>('DestroyWindow');
    updateLayeredWindow = user
        .lookupFunction<
          Int32 Function(_H, _H, Pointer<Int32>, Pointer<Int32>, _H, Pointer<Int32>, Uint32, Pointer<Uint8>, Uint32),
          int Function(int, int, Pointer<Int32>, Pointer<Int32>, int, Pointer<Int32>, int, Pointer<Uint8>, int)
        >('UpdateLayeredWindow');
    peekMessage = user
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, _H, Uint32, Uint32, Uint32),
          int Function(Pointer<Uint8>, int, int, int, int)
        >('PeekMessageW');
    translateMessage = user.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'TranslateMessage',
    );
    dispatchMessage = user.lookupFunction<IntPtr Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'DispatchMessageW',
    );
    defWindowProc = user.lookup<Void>('DefWindowProcW');
    getDpiForWindow = _optional(() => user.lookupFunction<Uint32 Function(_H), int Function(int)>('GetDpiForWindow'));
    createCompatibleDC = gdi.lookupFunction<_H Function(_H), int Function(int)>('CreateCompatibleDC');
    deleteDC = gdi.lookupFunction<Int32 Function(_H), int Function(int)>('DeleteDC');
    createDIBSection = gdi
        .lookupFunction<
          _H Function(_H, Pointer<Uint8>, Uint32, Pointer<Pointer<Uint8>>, _H, Uint32),
          int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, int, int)
        >('CreateDIBSection');
    selectObject = gdi.lookupFunction<_H Function(_H, _H), int Function(int, int)>('SelectObject');
    deleteObject = gdi.lookupFunction<Int32 Function(_H), int Function(int)>('DeleteObject');
    bitBlt = gdi
        .lookupFunction<
          Int32 Function(_H, Int32, Int32, Int32, Int32, _H, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int, int, int)
        >('BitBlt');
    getCurrentThreadId = kernel.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
    getCurrentProcessId = kernel.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
    getModuleHandle = kernel.lookupFunction<_H Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>(
      'GetModuleHandleW',
    );
  }

  static T? _optional<T>(T Function() lookup) {
    try {
      return lookup();
    } on ArgumentError {
      return null;
    }
  }

  late final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>) findWindowEx;
  late final int Function(int, Pointer<Uint32>) getWindowThreadProcessId;
  late final int Function(int) isWindowVisible;
  late final int Function(int) isIconic;
  late final int Function(int, int) getWindow;
  late final int Function(int, Pointer<Int32>) getWindowRect;
  late final int Function(int, Pointer<Int32>) getClientRect;
  late final int Function(int, Pointer<Int32>) clientToScreen;
  late final int Function(int, Pointer<Utf16>, int) getClassName;
  late final int Function() getForegroundWindow;
  late final int Function(int) setForegroundWindow;
  late final int Function(int) bringWindowToTop;
  late final int Function(int, int) showWindow;
  late final int Function(int, int, int, int, int, int, int) setWindowPos;
  late final int Function(int, int, int) attachThreadInput;
  late final int Function(int, Pointer<Uint8>, int) sendInput;
  late final int Function(int, int, int, int) postMessage;
  late final int Function(int, int) monitorFromWindow;
  late final int Function(int, Pointer<Uint32>) getMonitorInfo;
  late final int Function(int) getDC;
  late final int Function(int, int) releaseDC;
  late final int Function(int, int, int) printWindow;
  late final int Function(Pointer<Uint8>) registerClassEx;
  late final int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int, int, int, int, Pointer<Void>)
  createWindowEx;
  late final int Function(int) destroyWindow;
  late final int Function(int, int, Pointer<Int32>, Pointer<Int32>, int, Pointer<Int32>, int, Pointer<Uint8>, int)
  updateLayeredWindow;
  late final int Function(Pointer<Uint8>, int, int, int, int) peekMessage;
  late final int Function(Pointer<Uint8>) translateMessage;
  late final int Function(Pointer<Uint8>) dispatchMessage;
  late final Pointer<Void> defWindowProc;
  late final int Function(int)? getDpiForWindow;
  late final int Function(int) createCompatibleDC;
  late final int Function(int) deleteDC;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, int, int) createDIBSection;
  late final int Function(int, int) selectObject;
  late final int Function(int) deleteObject;
  late final int Function(int, int, int, int, int, int, int, int, int) bitBlt;
  late final int Function() getCurrentThreadId;
  late final int Function() getCurrentProcessId;
  late final int Function(Pointer<Utf16>) getModuleHandle;
}

/// The desktop on Windows, through Win32 called from Dart (no code in the runner): windows
/// found by process, brought in front with the foreground lock worked around (the launcher's
/// input joined to the window in front's for the moment), the game's picture copied from the
/// screen (or asked of the window with PrintWindow when it is covered), and the trophy card as
/// a layered, click-through, never-activated topmost window drawn with UpdateLayeredWindow.
class WindowsDesktop implements DesktopWindows {
  WindowsDesktop();

  late final _Win32 _w = _Win32();

  static const _topmost = -1;
  static const _notTopmost = -2;
  static const _noSize = 0x0001;
  static const _noMove = 0x0002;
  static const _noZOrder = 0x0004;
  static const _noActivate = 0x0010;
  static const _showWindow = 0x0040;

  bool _launcherOnTop = false;

  /// The top-level, visible, unowned window of [pid] with the largest area (a game may open a
  /// small console or splash first), or 0. [except] skips one (the card).
  int windowOf(int pid, {int except = 0}) => using((arena) {
    final owner = arena<Uint32>();
    final rect = arena<Int32>(4);
    var best = 0;
    var bestArea = -1;
    var window = 0;
    for (var guard = 0; guard < 20000; guard++) {
      window = _w.findWindowEx(0, window, nullptr, nullptr);
      if (window == 0) break;
      if (window == except || window == _card) continue;
      _w.getWindowThreadProcessId(window, owner);
      if (owner.value != pid || _w.isWindowVisible(window) == 0 || _w.getWindow(window, 4 /* GW_OWNER */) != 0) {
        continue;
      }
      _w.getWindowRect(window, rect);
      final area = (rect[2] - rect[0]) * (rect[3] - rect[1]);
      if (area > bestArea) {
        best = window;
        bestArea = area;
      }
    }
    return best;
  });

  int get _launcher => windowOf(_w.getCurrentProcessId());

  /// SetForegroundWindow from a process that is not in front works once its input is joined to
  /// the window in front's.
  bool _bringToFront(int window) {
    if (window == 0) return false;
    if (_w.isIconic(window) != 0) _w.showWindow(window, 9 /* SW_RESTORE */);
    final front = _w.getForegroundWindow();
    final frontThread = front == 0 ? 0 : _w.getWindowThreadProcessId(front, nullptr);
    final ours = _w.getCurrentThreadId();
    final joined = frontThread != 0 && frontThread != ours && _w.attachThreadInput(ours, frontThread, 1) != 0;
    try {
      _w.bringWindowToTop(window);
      return _w.setForegroundWindow(window) != 0;
    } finally {
      if (joined) _w.attachThreadInput(ours, frontThread, 0);
    }
  }

  @override
  Future<bool> raiseLauncher() async {
    final launcher = _launcher;
    if (launcher == 0) return false;
    // A full-screen SDL window is topmost: the launcher goes above it until the game is back.
    _w.setWindowPos(launcher, _topmost, 0, 0, 0, 0, _noMove | _noSize);
    _launcherOnTop = true;
    return _bringToFront(launcher);
  }

  @override
  Future<bool> focusGame(int pid) async {
    final launcher = _launcher;
    if (_launcherOnTop && launcher != 0) {
      _w.setWindowPos(launcher, _notTopmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate);
      _launcherOnTop = false;
    }
    return _bringToFront(windowOf(pid));
  }

  /// Waits for the game's first window: a game can take a while to open it.
  Future<int> _waitForWindow(int pid, {Duration timeout = const Duration(minutes: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final window = windowOf(pid);
      if (window != 0) return window;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return 0;
  }

  /// The work area (without the taskbar) and the whole area of the screen [window] is on, as
  /// left, top, right, bottom.
  (List<int> work, List<int> screen)? _screenOf(int window) => using((arena) {
    final monitor = _w.monitorFromWindow(window, 2 /* MONITOR_DEFAULTTONEAREST */);
    final info = arena<Uint32>(10); // MONITORINFO: cbSize, rcMonitor, rcWork, dwFlags
    info[0] = 40;
    if (monitor == 0 || _w.getMonitorInfo(monitor, info) == 0) return null;
    final ints = info.cast<Int32>();
    return ([ints[5], ints[6], ints[7], ints[8]], [ints[1], ints[2], ints[3], ints[4]]);
  });

  @override
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize}) async {
    final window = await _waitForWindow(pid);
    if (window == 0) return false;
    // Let SDL finish creating its window and swapchain first.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (windowOf(pid) != window) return false;
    if (fullscreen) return _pressF11(window);
    final screens = _screenOf(window);
    if (screens == null) return false;
    final (work, _) = screens;
    return using((arena) {
      final outer = arena<Int32>(4);
      final inner = arena<Int32>(4);
      _w.getWindowRect(window, outer);
      _w.getClientRect(window, inner);
      final frameWidth = (outer[2] - outer[0]) - inner[2];
      final frameHeight = (outer[3] - outer[1]) - inner[3];
      final size = windowArea(
        workWidth: work[2] - work[0],
        workHeight: work[3] - work[1],
        percent: windowSize,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );
      final x = work[0] + (work[2] - work[0] - size.width) ~/ 2;
      final y = work[1] + (work[3] - work[1] - size.height) ~/ 2;
      return _w.setWindowPos(window, 0, x, y, size.width, size.height, _noZOrder | _noActivate) != 0;
    });
  }

  /// F11 in the game's window, as if typed: upstream's engine toggles full screen on it.
  bool _pressF11(int window) {
    _bringToFront(window);
    if (_w.getForegroundWindow() == window) {
      return using((arena) {
        // Two INPUTs (40 bytes each on 64-bit Windows): F11 down and up, by virtual key and scan code.
        final inputs = arena<Uint8>(80);
        for (final (index, flags) in [(0, 0), (1, 2 /* KEYEVENTF_KEYUP */)]) {
          final input = (inputs + index * 40);
          input.cast<Uint32>().value = 1; // INPUT_KEYBOARD
          (input + 8).cast<Uint16>().value = 0x7A; // VK_F11
          (input + 10).cast<Uint16>().value = 0x57; // scan code
          (input + 12).cast<Uint32>().value = flags;
        }
        return _w.sendInput(2, inputs, 40) == 2;
      });
    }
    // Not in front: the key goes to the window's queue, which SDL reads the same way.
    const keyDown = 1 | 0x57 << 16;
    const keyUp = keyDown | 1 << 30 | 1 << 31;
    return _w.postMessage(window, 0x0100, 0x7A, keyDown) != 0 && _w.postMessage(window, 0x0101, 0x7A, keyUp) != 0;
  }

  @override
  Future<RgbaImage?> captureGame(int pid) async {
    final window = windowOf(pid);
    if (window == 0 || _w.isIconic(window) != 0) return null;
    return using((arena) {
      final rect = arena<Int32>(4);
      final corner = arena<Int32>(2);
      _w.getClientRect(window, rect);
      _w.clientToScreen(window, corner);
      final width = rect[2];
      final height = rect[3];
      if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return null;
      final screen = _w.getDC(0);
      final memory = _w.createCompatibleDC(screen);
      final bits = arena<Pointer<Uint8>>();
      final bitmap = _w.createDIBSection(memory, _bitmapInfo(arena, width, height), 0, bits, 0, 0);
      if (bitmap == 0) {
        _w.deleteDC(memory);
        _w.releaseDC(0, screen);
        return null;
      }
      final previous = _w.selectObject(memory, bitmap);
      try {
        // In front, the screen has the game as the player sees it; covered, the window is asked
        // to draw itself (PW_CLIENTONLY | PW_RENDERFULLCONTENT).
        final copied = _w.getForegroundWindow() == window
            ? _w.bitBlt(memory, 0, 0, width, height, screen, corner[0], corner[1], 0x00CC0020 /* SRCCOPY */)
            : _w.printWindow(window, memory, 3);
        if (copied == 0) return null;
        final pixels = Uint8List.fromList(bits.value.asTypedList(width * height * 4));
        return RgbaImage.fromBgra(width, height, pixels);
      } finally {
        _w.selectObject(memory, previous);
        _w.deleteObject(bitmap);
        _w.deleteDC(memory);
        _w.releaseDC(0, screen);
      }
    });
  }

  /// A BITMAPINFOHEADER for a top-down 32-bit picture.
  static Pointer<Uint8> _bitmapInfo(Arena arena, int width, int height) {
    final header = arena<Uint8>(44);
    final ints = header.cast<Int32>();
    ints[0] = 40; // biSize
    ints[1] = width;
    ints[2] = -height; // top-down
    (header + 12).cast<Uint16>().value = 1; // biPlanes
    (header + 14).cast<Uint16>().value = 32; // biBitCount
    return header;
  }

  @override
  double cardScale(int? pid) {
    final window = pid == null ? _w.getForegroundWindow() : windowOf(pid);
    final dpi = window == 0 ? 0 : (_w.getDpiForWindow?.call(window) ?? 0);
    return dpi <= 0 ? 1 : dpi / 96;
  }

  int _card = 0;
  bool _registered = false;
  static const _className = 'AnyPS5TrophyCard';

  int _makeCardWindow(int width, int height) {
    final instance = _w.getModuleHandle(nullptr);
    final className = _className.toNativeUtf16();
    if (!_registered) {
      using((arena) {
        // WNDCLASSEXW (80 bytes); messages go straight to DefWindowProcW: nothing to draw on
        // request, the layered window keeps its own picture.
        final type = arena<Uint8>(80);
        type.cast<Uint32>().value = 80;
        (type + 8).cast<IntPtr>().value = _w.defWindowProc.address;
        (type + 24).cast<IntPtr>().value = instance;
        (type + 64).cast<Pointer<Utf16>>().value = className;
        _registered = _w.registerClassEx(type) != 0;
      });
    }
    // WS_EX_LAYERED | WS_EX_TRANSPARENT (clicks pass through) | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
    // (not in the taskbar or Alt-Tab) | WS_EX_NOACTIVATE; WS_POPUP.
    const exStyle = 0x80000 | 0x20 | 0x8 | 0x80 | 0x8000000;
    final title = 'AnyPS5'.toNativeUtf16();
    try {
      return _w.createWindowEx(exStyle, className, title, 0x80000000, 0, 0, width, height, 0, 0, instance, nullptr);
    } finally {
      calloc.free(title);
    }
  }

  /// Takes the messages Windows posts to the card (it is the launcher's thread's), so it is
  /// never seen as not responding.
  void _pumpCard(Pointer<Uint8> message) {
    for (var guard = 0; guard < 32 && _w.peekMessage(message, _card, 0, 0, 1 /* PM_REMOVE */) != 0; guard++) {
      _w.translateMessage(message);
      _w.dispatchMessage(message);
    }
  }

  @override
  Future<bool> showCard(RgbaImage card, {int? pid}) async {
    if (_card != 0) return false;
    final game = pid == null ? 0 : windowOf(pid);
    final anchor = game != 0 ? game : _w.getForegroundWindow();
    final screens = _screenOf(anchor);
    if (screens == null) return false;
    final (_, screen) = screens;
    final window = _makeCardWindow(card.width, card.height);
    if (window == 0) return false;
    _card = window;
    final screenDc = _w.getDC(0);
    final memory = _w.createCompatibleDC(screenDc);
    final bitsOut = calloc<Pointer<Uint8>>();
    final header = calloc<Uint8>(44);
    final ints = header.cast<Int32>();
    ints[0] = 40;
    ints[1] = card.width;
    ints[2] = -card.height;
    (header + 12).cast<Uint16>().value = 1;
    (header + 14).cast<Uint16>().value = 32;
    final bitmap = _w.createDIBSection(memory, header, 0, bitsOut, 0, 0);
    final previous = bitmap == 0 ? 0 : _w.selectObject(memory, bitmap);
    final point = calloc<Int32>(2);
    final size = calloc<Int32>(2)
      ..[0] = card.width
      ..[1] = card.height;
    final source = calloc<Int32>(2);
    final blend = calloc<Uint8>(4);
    final message = calloc<Uint8>(48);
    final scale = cardScale(pid);
    try {
      if (bitmap == 0) return false;
      bitsOut.value.asTypedList(card.pixels.length).setAll(0, card.premultipliedBgra());
      final started = DateTime.now();
      var shown = false;
      while (true) {
        final phase = cardPhase(DateTime.now().difference(started));
        if (phase.done) break;
        final place = cardPosition(
          screenLeft: screen[0],
          screenTop: screen[1],
          screenWidth: screen[2] - screen[0],
          cardWidth: card.width,
          margin: (18 * scale).round(),
          slide: (22 * scale).round(),
          t: phase.t,
        );
        point
          ..[0] = place.x
          ..[1] = place.y;
        blend
          ..[0] =
              0 // AC_SRC_OVER
          ..[1] = 0
          ..[2] = (phase.opacity * 255).round().clamp(0, 255)
          ..[3] = 1; // AC_SRC_ALPHA
        _w.updateLayeredWindow(window, screenDc, point, size, memory, source, 0, blend, 2 /* ULW_ALPHA */);
        if (!shown) {
          shown = true;
          _w.showWindow(window, 4 /* SW_SHOWNOACTIVATE */);
          _w.setWindowPos(window, _topmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate | _showWindow);
        }
        _pumpCard(message);
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return true;
    } finally {
      _w.destroyWindow(window);
      _card = 0;
      if (bitmap != 0) {
        _w.selectObject(memory, previous);
        _w.deleteObject(bitmap);
      }
      _w.deleteDC(memory);
      _w.releaseDC(0, screenDc);
      for (final pointer in [bitsOut, header, point, size, source, blend, message]) {
        calloc.free(pointer);
      }
    }
  }

  @override
  Future<bool> notify(String title, String body, {String? icon}) async => false;

  @override
  void dispose() {}
}

/// A game window's outer size for [percent] of the screen's work area: the picture (16:9) as large
/// as fits in that share, plus the window's frame.
({int width, int height}) windowArea({
  required int workWidth,
  required int workHeight,
  required int percent,
  int frameWidth = 0,
  int frameHeight = 0,
}) {
  final share = percent.clamp(30, 100) / 100;
  final boundsWidth = workWidth * share - frameWidth;
  final boundsHeight = workHeight * share - frameHeight;
  var width = boundsWidth;
  var height = width * 9 / 16;
  if (height > boundsHeight) {
    height = boundsHeight;
    width = height * 16 / 9;
  }
  return (width: width.round() + frameWidth, height: height.round() + frameHeight);
}
