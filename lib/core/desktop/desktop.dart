import 'dart:typed_data';

/// Pixels, top row first, four bytes each: red, green, blue, alpha (not premultiplied).
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels) {
    if (pixels.length != width * height * 4) {
      throw ArgumentError('${width}x$height RGBA needs ${width * height * 4} bytes, not ${pixels.length}');
    }
  }

  final int width;
  final int height;
  final Uint8List pixels;

  /// Premultiplied BGRA, as Windows' layered windows and X11's 32-bit visuals take it, with
  /// every alpha scaled by [opacity] (0 to 1).
  Uint8List premultipliedBgra([double opacity = 1]) {
    final out = Uint8List(pixels.length);
    final level = (opacity.clamp(0.0, 1.0) * 255).round();
    for (var index = 0; index < pixels.length; index += 4) {
      final alpha = pixels[index + 3] * level ~/ 255;
      out[index] = pixels[index + 2] * alpha ~/ 255;
      out[index + 1] = pixels[index + 1] * alpha ~/ 255;
      out[index + 2] = pixels[index] * alpha ~/ 255;
      out[index + 3] = alpha;
    }
    return out;
  }

  /// BGRA or BGRX rows from a capture ([stride] bytes each) as opaque RGBA.
  static RgbaImage fromBgra(int width, int height, Uint8List bgra, {int? stride}) {
    final rowBytes = stride ?? width * 4;
    final out = Uint8List(width * height * 4);
    var target = 0;
    for (var y = 0; y < height; y++) {
      var source = y * rowBytes;
      for (var x = 0; x < width; x++) {
        out[target] = bgra[source + 2];
        out[target + 1] = bgra[source + 1];
        out[target + 2] = bgra[source];
        out[target + 3] = 255;
        target += 4;
        source += 4;
      }
    }
    return RgbaImage(width, height, out);
  }
}

/// What the launcher does with windows on the desktop, beside its own: the game's (in front, full
/// screen, its picture) and a card over it that never takes the keyboard or the mouse from it.
abstract class DesktopWindows {
  /// The launcher's window in front of everything, the game's included (PS on a controller).
  Future<bool> raiseLauncher();

  /// The game's window in front again, with the keyboard.
  Future<bool> focusGame(int pid);

  /// For an engine that does not read ANYPS5_FULLSCREEN and ANYPS5_WINDOW_SIZE (upstream's):
  /// once the game's window opens, sizes it to [windowSize] percent of its screen, or presses
  /// F11 for it (upstream's own full-screen key). Returns whether it could.
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize});

  /// The game's window as it is on screen now, null when it cannot be read.
  Future<RgbaImage?> captureGame(int pid);

  /// The size a card's pixels should be drawn at for the screen the game is on (1 at 96 dpi).
  double cardScale(int? pid);

  /// Shows [card] at the top of the game's screen for a few seconds, above the game, never taking
  /// its input; completes when it has gone. False when this desktop cannot (then
  /// [notify] is the way).
  Future<bool> showCard(RgbaImage card, {int? pid});

  /// A system notification, where a card cannot be shown (Wayland); [icon] is a PNG file.
  Future<bool> notify(String title, String body, {String? icon});

  void dispose();
}

/// A desktop the launcher does nothing with (tests, unknown systems).
class NoDesktop implements DesktopWindows {
  const NoDesktop();

  @override
  Future<bool> raiseLauncher() async => false;
  @override
  Future<bool> focusGame(int pid) async => false;
  @override
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize}) async => false;
  @override
  Future<RgbaImage?> captureGame(int pid) async => null;
  @override
  double cardScale(int? pid) => 1;
  @override
  Future<bool> showCard(RgbaImage card, {int? pid}) async => false;
  @override
  Future<bool> notify(String title, String body, {String? icon}) async => false;
  @override
  void dispose() {}
}

/// Where a card goes: centred at the top of a screen, below its edge by [margin] (in pixels
/// already scaled), sliding down by [slide] as it comes in ([t] from 0 to 1).
({int x, int y}) cardPosition({
  required int screenLeft,
  required int screenTop,
  required int screenWidth,
  required int cardWidth,
  required int margin,
  required int slide,
  required double t,
}) {
  final eased = 1 - (1 - t.clamp(0.0, 1.0)) * (1 - t.clamp(0.0, 1.0)) * (1 - t.clamp(0.0, 1.0));
  return (x: screenLeft + (screenWidth - cardWidth) ~/ 2, y: screenTop + margin - (slide * (1 - eased)).round());
}

/// A card's life: comes in, stays, goes; its opacity and slide at [elapsed].
({double opacity, double t, bool done}) cardPhase(
  Duration elapsed, {
  Duration enter = const Duration(milliseconds: 200),
  Duration stay = const Duration(milliseconds: 4600),
  Duration leave = const Duration(milliseconds: 260),
}) {
  final ms = elapsed.inMicroseconds / 1000;
  final enterMs = enter.inMilliseconds;
  final stayMs = stay.inMilliseconds;
  final leaveMs = leave.inMilliseconds;
  if (ms < enterMs) {
    final t = ms / enterMs;
    return (opacity: t, t: t, done: false);
  }
  if (ms < enterMs + stayMs) return (opacity: 1, t: 1, done: false);
  final out = (ms - enterMs - stayMs) / leaveMs;
  if (out >= 1) return (opacity: 0, t: 1, done: true);
  return (opacity: 1 - out, t: 1, done: false);
}
