import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/together/levels.dart';
import 'components.dart';
import 'strings.dart';
import 'theme.dart';

/// The colours of a level's tier: the metal of its frame and the bright edge of its number.
abstract final class LevelColors {
  static Color metal(LevelTier tier) => switch (tier) {
    LevelTier.bronze => const Color(0xFFC88B57),
    LevelTier.silver => const Color(0xFFA9B0BA),
    LevelTier.gold => const Color(0xFFD9A93A),
    LevelTier.platinum => const Color(0xFF8EA6D6),
  };

  static Color bright(LevelTier tier) => switch (tier) {
    LevelTier.bronze => const Color(0xFFF0C49A),
    LevelTier.silver => const Color(0xFFEEF1F5),
    LevelTier.gold => const Color(0xFFFFE39A),
    LevelTier.platinum => const Color(0xFFE8F0FF),
  };

  static String tierName(LevelTier tier) => T.text(switch (tier) {
    LevelTier.bronze => 'levelTierBronze',
    LevelTier.silver => 'levelTierSilver',
    LevelTier.gold => 'levelTierGold',
    LevelTier.platinum => 'levelTierPlatinum',
  });

  /// 1,234 in English, 1.234 in Turkish.
  static String number(int value) {
    final digits = value.abs().toString();
    final separator = T.language == Language.turkish ? '.' : ',';
    final out = StringBuffer(value < 0 ? '-' : '');
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) out.write(separator);
      out.write(digits[index]);
    }
    return out.toString();
  }
}

/// A trophy level as the website draws it: the number in a hexagon of its tier's metal, with a
/// frame that grows every 100 levels (an inner ring from 100, a crest from 300, a star from 600,
/// a halo at 900).
class LevelBadgeView extends StatelessWidget {
  const LevelBadgeView({super.key, required this.level, required this.size});

  final LevelBadge level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bright = LevelColors.bright(level.tier);
    final digits = '${level.level}'.length;
    return Semantics(
      label: T.format('levelUp', [level.level]),
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _HexagonPainter(level),
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(top: size * 0.02),
              child: Text(
                '${level.level}',
                style: AppText.display(
                  size * (digits >= 3 ? 0.27 : 0.36),
                  weight: FontWeight.w700,
                  color: bright,
                ).copyWith(letterSpacing: -0.03 * size * 0.3, height: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HexagonPainter extends CustomPainter {
  _HexagonPainter(this.level);

  final LevelBadge level;

  Path _polygon(List<(double, double)> points, double unit) {
    final path = Path()..moveTo(points.first.$1 * unit, points.first.$2 * unit);
    for (final point in points.skip(1)) {
      path.lineTo(point.$1 * unit, point.$2 * unit);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on the website's 32-unit grid.
    final unit = size.width / 32;
    final metal = LevelColors.metal(level.tier);
    final bright = LevelColors.bright(level.tier);
    final hexagon = _polygon(const [
      (16, 2.5),
      (27.7, 9.25),
      (27.7, 22.75),
      (16, 29.5),
      (4.3, 22.75),
      (4.3, 9.25),
    ], unit);
    if (level.tier == LevelTier.platinum || level.frame >= 10) {
      canvas.drawPath(
        hexagon,
        Paint()
          ..color = metal.withValues(alpha: 0.55)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, unit * 2.4),
      );
    }
    canvas.drawPath(hexagon, Paint()..color = Color.lerp(const Color(0xFF0C0E14), metal, 0.22)!);
    canvas.drawPath(
      hexagon,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * (size.width > 40 ? 1.3 : 1.6)
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [bright, metal],
        ).createShader(Offset.zero & size),
    );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = bright;
    if (level.frame >= 2) {
      canvas.drawPath(
        _polygon(const [(16, 6.2), (24.5, 11.1), (24.5, 20.9), (16, 25.8), (7.5, 20.9), (7.5, 11.1)], unit),
        Paint.from(line)
          ..color = bright.withValues(alpha: 0.45)
          ..strokeWidth = unit * 0.9,
      );
    }
    if (level.frame >= 4) {
      canvas.drawPath(
        Path()
          ..moveTo(12.5 * unit, 3.9 * unit)
          ..lineTo(16 * unit, 1.2 * unit)
          ..lineTo(19.5 * unit, 3.9 * unit),
        Paint.from(line)..strokeWidth = unit * 1.4,
      );
    }
    if (level.frame >= 7) {
      final star = Path();
      for (var point = 0; point < 10; point++) {
        final radius = (point.isEven ? 2.4 : 1.0) * unit;
        final angle = -math.pi / 2 + point * math.pi / 5;
        final at = Offset(16 * unit + radius * math.cos(angle), 2.6 * unit + radius * math.sin(angle));
        point == 0 ? star.moveTo(at.dx, at.dy) : star.lineTo(at.dx, at.dy);
      }
      canvas.drawPath(star..close(), Paint()..color = bright);
    }
    if (level.frame >= 10) {
      final halo = Paint.from(line)
        ..color = bright.withValues(alpha: 0.35)
        ..strokeWidth = unit * 0.8;
      // Dashed: short arcs around the badge.
      const dashes = 24;
      for (var dash = 0; dash < dashes; dash++) {
        canvas.drawArc(
          Rect.fromCircle(center: Offset(16 * unit, 16 * unit), radius: 15 * unit),
          dash * 2 * math.pi / dashes,
          math.pi / dashes * 0.75,
          false,
          halo,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HexagonPainter oldDelegate) => oldDelegate.level != level;
}

/// The level on a profile: the badge, "Trophy level 12" with its tier, how far to the next level
/// and all the points.
class LevelCard extends StatelessWidget {
  const LevelCard({super.key, required this.level, required this.accent});

  final TrophyLevel level;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final metal = LevelColors.metal(level.tier);
    final muted = Colors.white.withValues(alpha: 0.6);
    final toNext = level.toNext;
    final meta = [
      if (level.top)
        T.text('levelTop')
      else if (toNext != null)
        T.format('levelNext', [LevelColors.number(toNext), LevelColors.number(level.level + 1)]),
      if (level.points > 0) T.format('levelPoints', [LevelColors.number(level.points)]),
    ].join(' · ');
    return Container(
      padding: EdgeInsets.fromLTRB(14 * scale, 12 * scale, 18 * scale, 12 * scale),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16 * scale),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [metal.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.03)],
        ),
      ),
      child: Row(
        children: [
          LevelBadgeView(level: level, size: 58 * scale),
          SizedBox(width: 14 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(T.text('levelTitle'), style: AppText.display(15 * scale, color: muted)),
                    SizedBox(width: 6 * scale),
                    Text(LevelColors.number(level.level), style: AppText.display(17 * scale, weight: FontWeight.w700)),
                    SizedBox(width: 10 * scale),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 3 * scale),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6 * scale),
                        border: Border.all(color: metal.withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        LevelColors.tierName(level.tier).toUpperCase(),
                        style: AppText.display(
                          10.5 * scale,
                          weight: FontWeight.w700,
                          color: LevelColors.bright(level.tier),
                        ).copyWith(letterSpacing: 0.9 * scale),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 9 * scale),
                ProgressLine(fraction: level.progress / 100, color: accent, height: 5 * scale),
                if (meta.isNotEmpty) ...[
                  SizedBox(height: 8 * scale),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(13 * scale, color: muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
