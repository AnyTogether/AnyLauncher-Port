import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'strings.dart';
import 'theme.dart';

/// The interface is laid out for a 1600x900 window and scaled with it.
class LayoutScale extends InheritedWidget {
  const LayoutScale({super.key, required this.scale, required super.child});

  final double scale;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LayoutScale>()?.scale ?? 1;

  @override
  bool updateShouldNotify(LayoutScale oldWidget) => oldWidget.scale != scale;
}

/// A dark, frosted panel.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, required this.radius, this.opacity = 0.38, this.padding});

  final Widget child;
  final double radius;
  final double opacity;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: opacity),
            borderRadius: shape,
            border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The white ring and glow a focused element wears. The glow is drawn around the ring only, so
/// the element itself keeps its colors.
class FocusRing extends StatelessWidget {
  const FocusRing({super.key, required this.focused, required this.radius, required this.child, this.width = 3});

  final bool focused;
  final double radius;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          left: -width * 1.6,
          top: -width * 1.6,
          right: -width * 1.6,
          bottom: -width * 1.6,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: focused ? 1 : 0,
              duration: Motion.focus,
              curve: Motion.settle,
              child: CustomPaint(
                painter: _RingPainter(radius: radius + width * 1.6, width: width),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.radius, required this.width});
  final double radius;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final ring = RRect.fromRectAndRadius((Offset.zero & size).deflate(width / 2), Radius.circular(radius));
    canvas
      ..drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 2.5
          ..color = Colors.white.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 9),
      )
      ..drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = Colors.white.withValues(alpha: 0.95),
      );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => oldDelegate.radius != radius || oldDelegate.width != width;
}

/// A console button: translucent until focused, then solid white.
class ConsoleButton extends StatefulWidget {
  const ConsoleButton({
    super.key,
    required this.title,
    required this.focused,
    required this.onPressed,
    this.icon,
    this.prominent = false,
    this.destructive = false,
    this.minWidth = 0,
  });

  final String title;
  final IconData? icon;
  final bool focused;
  final bool prominent;
  final bool destructive;
  final double minWidth;
  final VoidCallback onPressed;

  @override
  State<ConsoleButton> createState() => _ConsoleButtonState();
}

class _ConsoleButtonState extends State<ConsoleButton> {
  bool _hovering = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final focused = widget.focused;
    final foreground = focused ? Colors.black : (widget.destructive ? Palette.danger : Colors.white);
    final fill = focused
        ? Colors.white
        : Colors.white.withValues(alpha: widget.prominent ? 0.2 : (_hovering ? 0.16 : 0.1));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (focused ? 1.05 : 1),
          duration: _pressed ? const Duration(milliseconds: 90) : Motion.focus,
          curve: Motion.settle,
          child: AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            constraints: BoxConstraints(minWidth: widget.minWidth * scale, minHeight: 54 * scale),
            padding: EdgeInsets.symmetric(horizontal: (widget.title.isEmpty ? 18 : 30) * scale),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(14 * scale),
              border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.12)),
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withValues(alpha: focused ? 0.28 : 0),
                  blurRadius: 18 * scale,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) Icon(widget.icon, size: 20 * scale, color: foreground),
                if (widget.icon != null && widget.title.isNotEmpty) SizedBox(width: 10 * scale),
                if (widget.title.isNotEmpty)
                  Text(
                    widget.title,
                    style: AppText.display(19 * scale, weight: FontWeight.w600, color: foreground),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin capsule progress bar.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.fraction, required this.color, this.height = 4});

  final double fraction;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(height, constraints.maxWidth * fraction.clamp(0, 1));
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                width: width,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(height),
                  boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// An endless sweep for steps whose length is not known (the relinker's run).
class IndeterminateLine extends StatefulWidget {
  const IndeterminateLine({super.key, required this.color, this.height = 4});

  final Color color;
  final double height;

  @override
  State<IndeterminateLine> createState() => _IndeterminateLineState();
}

class _IndeterminateLineState extends State<IndeterminateLine> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height),
        child: LayoutBuilder(
          builder: (context, constraints) => AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final phase = -0.4 + 1.45 * Motion.inOut.transform(_controller.value);
              return Stack(
                children: [
                  Container(color: Colors.white.withValues(alpha: 0.16)),
                  Positioned(
                    left: constraints.maxWidth * phase,
                    width: constraints.maxWidth * 0.35,
                    top: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [widget.color.withValues(alpha: 0), widget.color, widget.color.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The time, updated every minute.
class Clock extends StatefulWidget {
  const Clock({super.key, this.now});

  /// A fixed time, for previews and tests.
  final DateTime? now;

  @override
  State<Clock> createState() => _ClockState();
}

class _ClockState extends State<Clock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.now == null) {
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final now = widget.now ?? DateTime.now();
    final text = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Text(
      text,
      style: AppText.display(20 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.92)),
    );
  }
}

/// One of the PlayStation face buttons, drawn (the font has no glyphs for them).
class PadGlyphIcon extends StatelessWidget {
  const PadGlyphIcon(this.glyph, {super.key, required this.size, required this.color});

  final PadGlyph glyph;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _GlyphPainter(glyph, color));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final PadGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final inset = size.width * 0.18;
    final box = Rect.fromLTWH(inset, inset, size.width - inset * 2, size.height - inset * 2);
    switch (glyph) {
      case PadGlyph.cross:
        canvas
          ..drawLine(box.topLeft, box.bottomRight, paint)
          ..drawLine(box.topRight, box.bottomLeft, paint);
      case PadGlyph.circle:
        canvas.drawCircle(box.center, box.width / 2, paint);
      case PadGlyph.square:
        canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(size.width * 0.05)), paint);
      case PadGlyph.triangle:
        final path = Path()
          ..moveTo(box.center.dx, box.top)
          ..lineTo(box.right, box.bottom - box.height * 0.08)
          ..lineTo(box.left, box.bottom - box.height * 0.08)
          ..close();
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) => oldDelegate.glyph != glyph || oldDelegate.color != color;
}

/// A key or button with what it does.
class Hint extends StatelessWidget {
  const Hint({super.key, required this.keys, required this.label, this.glyph});

  final String keys;
  final PadGlyph? glyph;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = Colors.white.withValues(alpha: 0.72);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 3 * scale),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(5 * scale),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                keys,
                style: AppText.display(12 * scale, weight: FontWeight.w700, color: color),
              ),
              if (glyph != null) ...[
                Text(
                  ' / ',
                  style: AppText.display(12 * scale, weight: FontWeight.w700, color: color),
                ),
                PadGlyphIcon(glyph!, size: 12 * scale, color: color),
              ],
            ],
          ),
        ),
        SizedBox(width: 8 * scale),
        Text(
          label,
          style: AppText.display(13 * scale, weight: FontWeight.w500, color: color),
        ),
      ],
    );
  }
}

class HintBar extends StatelessWidget {
  const HintBar({super.key, this.options = true});

  final bool options;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Wrap(
      spacing: 22 * scale,
      runSpacing: 8 * scale,
      children: [
        Hint(keys: '← → ↑ ↓', label: T.text('hintMove')),
        Hint(keys: 'Q E / L1 R1', label: T.text('hintGame')),
        Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('hintSelect')),
        Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack')),
        if (options) Hint(keys: 'O', glyph: PadGlyph.triangle, label: T.text('hintOptions')),
      ],
    );
  }
}

/// A game's picture from its file, decoded at about the size it is shown. The file is read once
/// and kept (icons are small, backgrounds a few megabytes), so the picture is not decoded again
/// on every rebuild.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({super.key, required this.path, this.fit = BoxFit.cover, this.cacheWidth});

  final String path;
  final BoxFit fit;
  final int? cacheWidth;

  static final Map<String, ImageProvider?> _providers = {};

  static ImageProvider? provider(String path, int? cacheWidth) {
    final key = '$path@$cacheWidth';
    return _providers.putIfAbsent(key, () {
      if (_providers.length > 200) _providers.clear();
      try {
        final image = MemoryImage(File(path).readAsBytesSync());
        return cacheWidth == null ? image : ResizeImage(image, width: cacheWidth, policy: ResizeImagePolicy.fit);
      } on FileSystemException {
        return null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = provider(path, cacheWidth);
    if (image == null) return const SizedBox.shrink();
    return Image(
      image: image,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );
  }
}

/// Bytes as a size people read: 12.3 GB.
String byteText(int? bytes) {
  if (bytes == null || bytes < 0) return '…';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Scrolls its child into view whenever [active] turns true, so a keyboard focus that moves
/// down a long list stays on screen.
class KeepVisible extends StatefulWidget {
  const KeepVisible({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<KeepVisible> createState() => _KeepVisibleState();
}

class _KeepVisibleState extends State<KeepVisible> {
  @override
  void didUpdateWidget(KeepVisible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: Motion.focus,
          curve: Motion.settle,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
