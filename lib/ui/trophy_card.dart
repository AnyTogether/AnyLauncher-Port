import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/desktop/desktop.dart';
import '../core/trophies.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';

/// The card that drops in over the game when a trophy is earned, as the PS5 shows it (the macOS
/// launcher's TrophyBanner): the trophy's picture with a glow in its grade's colour, "Trophy
/// earned", its name and text, the grade's cup. Drawn straight onto a canvas into pixels, for a
/// window of the system's own above the game.
abstract final class TrophyCard {
  /// The card's size at scale 1, its shadow included.
  static const width = 560.0;
  static const height = 140.0;
  static const _margin = 24.0;

  static Future<RgbaImage> render(Trophy trophy, {double scale = 1}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    final grade = TrophyView.gradeColor(trophy.grade);
    final card = RRect.fromRectAndRadius(
      const Rect.fromLTWH(_margin, _margin * 0.6, width - _margin * 2, height - _margin * 1.6),
      const Radius.circular(20),
    );
    canvas.drawRRect(
      card.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawRRect(card, Paint()..color = const Color(0xF0121212));
    canvas.drawRRect(
      card.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [grade.withValues(alpha: 0.6), Colors.white.withValues(alpha: 0.08)],
        ).createShader(card.outerRect),
    );
    // The picture, with its glow.
    final iconRect = Rect.fromLTWH(card.left + 16, card.center.dy - 30, 60, 60);
    canvas.drawCircle(
      iconRect.center,
      34,
      Paint()
        ..color = grade.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    final picture = trophy.hidden && trophy.name.isEmpty ? null : await _decode(trophy.icon);
    final iconShape = RRect.fromRectAndRadius(iconRect, const Radius.circular(12));
    if (picture != null) {
      canvas
        ..save()
        ..clipRRect(iconShape)
        ..drawImageRect(
          picture,
          Rect.fromLTWH(0, 0, picture.width.toDouble(), picture.height.toDouble()),
          iconRect,
          Paint()..filterQuality = FilterQuality.medium,
        )
        ..restore();
      picture.dispose();
    } else {
      canvas.drawRRect(iconShape, Paint()..color = Colors.white.withValues(alpha: 0.08));
      _icon(canvas, Icons.emoji_events_rounded, iconRect.center, 30, grade);
    }
    // The words.
    final left = iconRect.right + 16;
    final textWidth = card.right - 56 - left;
    _icon(canvas, Icons.emoji_events_rounded, Offset(left + 7, card.top + 30), 14, grade);
    _text(canvas, T.text('trophyEarned'), Offset(left + 20, card.top + 21), textWidth - 20, 13, FontWeight.w600, grade);
    _text(
      canvas,
      trophy.name.isEmpty ? T.text('trophyHidden') : trophy.name,
      Offset(left, card.top + 40),
      textWidth,
      19,
      FontWeight.w600,
      Colors.white,
    );
    _text(canvas, trophy.detail, Offset(left, card.top + 66), textWidth, 13, FontWeight.w400, Colors.white60);
    _icon(canvas, Icons.emoji_events_rounded, Offset(card.right - 32, card.center.dy), 28, grade);
    final image = await recorder.endRecording().toImage((width * scale).ceil(), (height * scale).ceil());
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      return RgbaImage(image.width, image.height, bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }

  static Future<ui.Image?> _decode(Uint8List? png) async {
    if (png == null || png.isEmpty) return null;
    try {
      final codec = await ui.instantiateImageCodec(png, targetWidth: 128);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } on Object {
      return null;
    }
  }

  static void _text(Canvas canvas, String text, Offset at, double width, double size, FontWeight weight, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: AppText.display(size, weight: weight, color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: width);
    painter.paint(canvas, at);
    painter.dispose();
  }

  static void _icon(Canvas canvas, IconData icon, Offset center, double size, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: size, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
    painter.dispose();
  }
}
