import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../core/steam/steam_shortcuts.dart';
import 'theme.dart';

/// The pictures AnyPS5's Steam shortcuts wear, drawn with the launcher's own renderer in its
/// Cosmic look: the deep blue field with its glow, the dust and the waves of the app icon, the
/// ring and play mark, the name in Figtree. A game's own come from its sce_sys art (pic0 as the
/// backdrop, icon0 as the cover) with the same finish.
abstract final class SteamArtist {
  static const _look = LookStyle.cosmic;
  static const _white = Color(0xFFF4F6FB);

  /// AnyPS5's own five pictures.
  static Future<Map<SteamArt, Uint8List>> launcher({Color accent = const Color(0xFF4F94FF)}) async => {
    SteamArt.portrait: await _png(600, 900, (canvas, size) {
      _field(canvas, Offset.zero & size, accent, seed: 1);
      _mark(canvas, Offset(size.width / 2, 372), 132);
      _text(canvas, 'AnyPS5', Offset(size.width / 2, 580), size: 88, width: size.width);
      _caption(canvas, 'PS5 GAMES · NATIVELY', Offset(size.width / 2, 668), width: size.width);
    }),
    SteamArt.wide: await _png(920, 430, (canvas, size) {
      _field(canvas, Offset.zero & size, accent, seed: 2);
      _mark(canvas, const Offset(250, 215), 112);
      _text(canvas, 'AnyPS5', const Offset(615, 196), size: 104, width: 520);
      _caption(canvas, 'PS5 GAMES · NATIVELY', const Offset(615, 272), width: 520);
    }),
    SteamArt.hero: await _png(1920, 620, (canvas, size) {
      _field(canvas, Offset.zero & size, accent, seed: 3);
      // The ring large and faint on the right, where Steam's logo never sits.
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 46
        ..color = _white.withValues(alpha: 0.07);
      canvas.drawCircle(const Offset(1530, 330), 360, ring);
      canvas.drawCircle(const Offset(1530, 330), 250, ring..color = accent.withValues(alpha: 0.10));
    }),
    SteamArt.logo: await _logo(
      (canvas, size) {
        _mark(canvas, Offset(size.height / 2, size.height / 2), size.height * 0.42, glow: false);
        _text(
          canvas,
          'AnyPS5',
          Offset(size.height + (size.width - size.height) / 2, size.height / 2),
          size: 200,
          width: size.width - size.height,
        );
      },
      width: 1280,
      height: 340,
    ),
    SteamArt.icon: await _png(256, 256, (canvas, size) {
      final shape = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(56));
      canvas.save();
      canvas.clipRRect(shape);
      _field(canvas, Offset.zero & size, accent, seed: 4, stars: 18);
      canvas.restore();
      _mark(canvas, const Offset(128, 128), 76, glow: false);
    }),
  };

  /// A game's five pictures from its sce_sys art ([background] pic0, [cover] icon0, either may
  /// be missing).
  static Future<Map<SteamArt, Uint8List>> game({
    required String name,
    String? background,
    String? cover,
    Color accent = const Color(0xFF4F94FF),
  }) async {
    final backdrop = await _image(background);
    final icon = await _image(cover);
    void base(Canvas canvas, Rect rect, {double blur = 0, double alignY = 0.4, int seed = 5}) {
      if (backdrop == null) {
        _field(canvas, rect, accent, seed: seed);
        return;
      }
      _cover(canvas, backdrop, rect, alignY: alignY, blur: blur);
    }

    try {
      return {
        SteamArt.portrait: await _png(600, 900, (canvas, size) {
          final rect = Offset.zero & size;
          base(canvas, rect, blur: 22);
          canvas.drawRect(
            rect,
            Paint()
              ..shader = ui.Gradient.linear(
                Offset.zero,
                Offset(0, size.height),
                [
                  _look.deep.withValues(alpha: 0.35),
                  _look.deep.withValues(alpha: 0.55),
                  _look.deep.withValues(alpha: 0.92),
                ],
                [0, 0.5, 1],
              ),
          );
          const square = Rect.fromLTWH(70, 110, 460, 460);
          if (icon != null) {
            _rounded(canvas, icon, square, 36);
          } else {
            _mark(canvas, square.center, 150);
          }
          _text(canvas, name, Offset(size.width / 2, 700), size: 46, width: 520, lines: 3);
          _badge(canvas, Offset(size.width / 2, 852));
        }),
        SteamArt.wide: await _png(920, 430, (canvas, size) {
          final rect = Offset.zero & size;
          base(canvas, rect);
          canvas.drawRect(
            rect,
            Paint()
              ..shader = ui.Gradient.linear(
                Offset.zero,
                Offset(size.width, 0),
                [
                  _look.deep.withValues(alpha: 0.88),
                  _look.deep.withValues(alpha: 0.55),
                  _look.deep.withValues(alpha: 0.05),
                ],
                [0, 0.55, 1],
              ),
          );
          const square = Rect.fromLTWH(44, 65, 300, 300);
          if (icon != null) {
            _rounded(canvas, icon, square, 26);
          } else {
            _mark(canvas, square.center, 110);
          }
          _text(canvas, name, const Offset(620, 200), size: 44, width: 500, lines: 3);
          _badge(canvas, const Offset(620, 330));
        }),
        SteamArt.hero: await _png(1920, 620, (canvas, size) {
          final rect = Offset.zero & size;
          if (backdrop != null) {
            base(canvas, rect, alignY: 0.35);
          } else {
            _field(canvas, rect, accent, seed: 6);
            if (icon != null) _cover(canvas, icon, rect, blur: 40, alignY: 0.5);
          }
        }),
        SteamArt.logo: await _logo(
          (canvas, size) {
            _text(canvas, name, Offset(size.width / 2, size.height / 2), size: 132, width: size.width, lines: 2);
          },
          width: 1280,
          height: 340,
        ),
        SteamArt.icon: await _png(256, 256, (canvas, size) {
          final rect = Offset.zero & size;
          if (icon != null) {
            _cover(canvas, icon, rect);
          } else {
            _field(canvas, rect, accent, seed: 7, stars: 18);
            _mark(canvas, rect.center, 76, glow: false);
          }
        }),
      };
    } finally {
      backdrop?.dispose();
      icon?.dispose();
    }
  }

  // Drawing.

  static Future<Uint8List> _png(int width, int height, void Function(Canvas, Size) paint) async {
    final recorder = ui.PictureRecorder();
    final size = Size(width.toDouble(), height.toDouble());
    final canvas = Canvas(recorder, Offset.zero & size);
    paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  static Future<Uint8List> _logo(void Function(Canvas, Size) paint, {required int width, required int height}) =>
      _png(width, height, paint);

  static Future<ui.Image?> _image(String? path) async {
    if (path == null) return null;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } on Object {
      return null;
    }
  }

  /// The Cosmic field: deep blue rising from the bottom, a glow up right, dust, and the waves
  /// running across the app icon.
  static void _field(Canvas canvas, Rect rect, Color accent, {required int seed, int stars = 140}) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.bottomLeft,
          rect.topRight,
          [_look.deep, _look.middle, const Color(0xFF2E57C9)],
          [0, 0.62, 1],
        ),
    );
    final glowAt = Offset(rect.left + rect.width * 0.78, rect.top + rect.height * 0.18);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          glowAt,
          math.max(rect.width, rect.height) * 0.6,
          [_look.bright.withValues(alpha: 0.42), accent.withValues(alpha: 0.10), accent.withValues(alpha: 0)],
          [0, 0.45, 1],
        ),
    );
    final random = math.Random(seed);
    final dust = Paint();
    final scale = math.sqrt(rect.width * rect.height) / 700;
    for (var i = 0; i < stars; i++) {
      final at = Offset(rect.left + random.nextDouble() * rect.width, rect.top + random.nextDouble() * rect.height);
      final bright = random.nextDouble();
      dust.color = _white.withValues(alpha: 0.12 + bright * bright * 0.6);
      canvas.drawCircle(at, (0.5 + bright * 1.3) * scale, dust);
    }
    // The waves.
    final wave = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      final y = rect.top + rect.height * (0.62 + i * 0.022);
      final lift = rect.height * (0.07 - i * 0.012);
      final path = Path()
        ..moveTo(rect.left - 10, y + lift * 0.4)
        ..cubicTo(
          rect.left + rect.width * 0.3,
          y - lift,
          rect.left + rect.width * 0.62,
          y + lift * 1.2,
          rect.right + 10,
          y - lift * 0.5,
        );
      wave
        ..strokeWidth = math.max(1, scale * (i == 1 ? 2.2 : 1.3))
        ..color = _white.withValues(alpha: i == 1 ? 0.34 : 0.14);
      canvas.drawPath(path, wave);
    }
    // A shade at the bottom so text there reads.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [_look.deep.withValues(alpha: 0), _look.deep.withValues(alpha: 0.55)],
          [0.55, 1],
        ),
    );
  }

  /// The ring and play mark of the app icon.
  static void _mark(Canvas canvas, Offset center, double radius, {bool glow = true}) {
    if (glow) {
      canvas.drawCircle(
        center,
        radius * 1.15,
        Paint()
          ..color = _look.bright.withValues(alpha: 0.30)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.35),
      );
    }
    final shadow = Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.06);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.12
      ..color = _white;
    canvas.drawCircle(
      center + Offset(0, radius * 0.03),
      radius,
      shadow
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.12,
    );
    canvas.drawCircle(center, radius, ring);
    final r = radius * 0.42;
    final triangle = Path()
      ..moveTo(center.dx - r * 0.55, center.dy - r * 0.85)
      ..lineTo(center.dx + r * 0.95, center.dy)
      ..lineTo(center.dx - r * 0.55, center.dy + r * 0.85)
      ..close();
    final fill = Paint()
      ..color = _white
      ..style = PaintingStyle.fill;
    final round = Paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = r * 0.32;
    canvas.drawPath(triangle, fill);
    canvas.drawPath(triangle, round);
  }

  /// [text] centred on [center], up to [lines] lines in [width].
  static void _text(
    Canvas canvas,
    String text,
    Offset center, {
    required double size,
    required double width,
    int lines = 1,
    Color color = _white,
  }) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: TextAlign.center,
              maxLines: lines,
              ellipsis: '…',
              fontFamily: AppText.family,
              fontSize: size,
              fontWeight: FontWeight.w700,
              height: 1.08,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: color,
              fontFamily: AppText.family,
              fontSize: size,
              fontWeight: FontWeight.w700,
              letterSpacing: size * -0.01,
              shadows: [
                Shadow(color: const Color(0x8C000000), blurRadius: size * 0.12, offset: Offset(0, size * 0.03)),
              ],
            ),
          )
          ..addText(text);
    final paragraph = builder.build()..layout(ui.ParagraphConstraints(width: width));
    canvas.drawParagraph(paragraph, Offset(center.dx - width / 2, center.dy - paragraph.height / 2));
    paragraph.dispose();
  }

  static void _caption(Canvas canvas, String text, Offset center, {required double width}) {
    final builder =
        ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: TextAlign.center, maxLines: 1, fontFamily: AppText.family))
          ..pushStyle(
            ui.TextStyle(
              color: _white.withValues(alpha: 0.62),
              fontFamily: AppText.family,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: 5,
            ),
          )
          ..addText(text);
    final paragraph = builder.build()..layout(ui.ParagraphConstraints(width: width));
    canvas.drawParagraph(paragraph, Offset(center.dx - width / 2, center.dy - paragraph.height / 2));
    paragraph.dispose();
  }

  /// The small "AnyPS5" sign on a game's capsules.
  static void _badge(Canvas canvas, Offset center) {
    _mark(canvas, center - const Offset(62, 0), 15, glow: false);
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: AppText.family, maxLines: 1))
      ..pushStyle(
        ui.TextStyle(
          color: _white.withValues(alpha: 0.85),
          fontFamily: AppText.family,
          fontSize: 26,
          fontWeight: FontWeight.w700,
        ),
      )
      ..addText('AnyPS5');
    final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 200));
    canvas.drawParagraph(paragraph, Offset(center.dx - 36, center.dy - paragraph.height / 2));
    paragraph.dispose();
  }

  /// [image] filling [rect], cropped around [alignY] of its height, blurred by [blur].
  static void _cover(Canvas canvas, ui.Image image, Rect rect, {double alignY = 0.5, double blur = 0}) {
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    final scale = math.max(rect.width / width, rect.height / height);
    final source = Size(rect.width / scale, rect.height / scale);
    final left = (width - source.width) / 2;
    final double top = ((height - source.height) * alignY).clamp(0.0, math.max(0.0, height - source.height)).toDouble();
    final paint = Paint()..filterQuality = FilterQuality.high;
    canvas.save();
    canvas.clipRect(rect);
    if (blur > 0) {
      paint.imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.clamp);
      // A touch larger, so the blur's edge stays outside.
      canvas.drawImageRect(image, Offset(left, top) & source, rect.inflate(blur * 2), paint);
    } else {
      canvas.drawImageRect(image, Offset(left, top) & source, rect, paint);
    }
    canvas.restore();
  }

  static void _rounded(Canvas canvas, ui.Image image, Rect rect, double radius) {
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(
      shape.shift(const Offset(0, 10)),
      Paint()
        ..color = const Color(0x99000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );
    canvas.save();
    canvas.clipRRect(shape);
    _cover(canvas, image, rect);
    canvas.restore();
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _white.withValues(alpha: 0.18),
    );
  }
}
