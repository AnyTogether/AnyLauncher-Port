import 'package:flutter/widgets.dart';

/// A padlock that reads as one at any size: a solid body with its keyhole cut out under a bold
/// shackle. Material's lock_rounded, small on a game's tile, was taken for a shopping bag.
///
/// The outline is Hugeicons' "square-lock-02" (Hugeicons Free, MIT licence, © 2025 Hugeicons,
/// https://github.com/hugeicons), drawn here with a filled body and a heavier shackle.
class Padlock extends StatelessWidget {
  const Padlock({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: PadlockPainter(color)),
    ),
  );
}

class PadlockPainter extends CustomPainter {
  const PadlockPainter(this.color);

  final Color color;

  /// The shackle, on Hugeicons' 24-unit grid.
  static Path get shackle => Path()
    ..moveTo(16.5, 10)
    ..lineTo(16.5, 6.5)
    ..cubicTo(16.5, 4.01472, 14.4853, 2, 12, 2)
    ..cubicTo(9.51471, 2, 7.5, 4.01472, 7.5, 6.5)
    ..lineTo(7.5, 10);

  /// The body: a squircle a little wider than tall.
  static Path get body => Path()
    ..moveTo(4.2678, 18.8447)
    ..cubicTo(4.49268, 20.515, 5.87612, 21.8235, 7.55965, 21.9009)
    ..cubicTo(8.97627, 21.966, 10.4153, 22, 12, 22)
    ..cubicTo(13.5847, 22, 15.0237, 21.966, 16.4403, 21.9009)
    ..cubicTo(18.1239, 21.8235, 19.5073, 20.515, 19.7322, 18.8447)
    ..cubicTo(19.8789, 17.7547, 20, 16.6376, 20, 15.5)
    ..cubicTo(20, 14.3624, 19.8789, 13.2453, 19.7322, 12.1553)
    ..cubicTo(19.5073, 10.485, 18.1239, 9.17649, 16.4403, 9.09909)
    ..cubicTo(15.0237, 9.03397, 13.5847, 9, 12, 9)
    ..cubicTo(10.4153, 9, 8.97627, 9.03397, 7.55965, 9.09909)
    ..cubicTo(5.87612, 9.17649, 4.49268, 10.485, 4.2678, 12.1553)
    ..cubicTo(4.12104, 13.2453, 4, 14.3624, 4, 15.5)
    ..cubicTo(4, 16.6376, 4.12104, 17.7547, 4.2678, 18.8447)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / 24;
    canvas
      ..save()
      ..scale(unit);
    // The shackle a little heavier than the 1.5 of the outline set: it is what says "lock".
    canvas.drawPath(
      shackle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    canvas.saveLayer(const Rect.fromLTWH(0, 0, 24, 24), Paint());
    canvas.drawPath(body, Paint()..color = color);
    // The keyhole, cut through the body.
    final cut = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xFF000000);
    canvas
      ..drawCircle(const Offset(12, 14.6), 1.75, cut)
      ..drawLine(
        const Offset(12, 14.6),
        const Offset(12, 18),
        cut
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round,
      )
      ..restore()
      ..restore();
  }

  @override
  bool shouldRepaint(PadlockPainter oldDelegate) => oldDelegate.color != color;
}
