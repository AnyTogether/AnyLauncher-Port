import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'glass.dart';
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
    if (LookScope.isGlass(context)) {
      // A darker panel (a full panel, a toast floating over anything) keeps more of its navy.
      return IceSurface(
        radius: radius,
        padding: padding,
        opacity: math.min(GlassRecipe.floatingOpacity, GlassRecipe.baseOpacity + math.max(0, opacity - 0.38) * 1.15),
        child: child,
      );
    }
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
    final glass = LookScope.isGlass(context);
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
                painter: glass
                    ? _IceRingPainter(radius: radius + width * 1.6, width: width)
                    : _RingPainter(radius: radius + width * 1.6, width: width),
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

/// Glass's focus ring: a thinner ring of ice, white at the top and cyan below, in an icy glow.
class _IceRingPainter extends CustomPainter {
  _IceRingPainter({required this.radius, required this.width});
  final double radius;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final ring = RRect.fromRectAndRadius((Offset.zero & size).deflate(width / 2), Radius.circular(radius));
    final rect = Offset.zero & size;
    canvas
      ..drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 2.5
          ..color = GlassRecipe.cyan.withValues(alpha: GlassRecipe.glowOpacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.outer, GlassRecipe.glowBlur / 2),
      )
      ..drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 0.8
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomRight,
            colors: [Colors.white, Colors.white.withValues(alpha: 0.85), GlassRecipe.cyan],
            stops: const [0, 0.5, 1],
          ).createShader(rect),
      );
  }

  @override
  bool shouldRepaint(_IceRingPainter oldDelegate) => oldDelegate.radius != radius || oldDelegate.width != width;
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
    final glass = LookScope.isGlass(context);
    final foreground = focused ? LookScope.focusedInk(context) : (widget.destructive ? Palette.danger : Colors.white);
    final fill = focused
        ? Colors.white
        : Colors.white.withValues(alpha: widget.prominent ? 0.2 : (_hovering ? 0.16 : 0.1));
    final constraints = BoxConstraints(minWidth: widget.minWidth * scale, minHeight: 54 * scale);
    final padding = EdgeInsets.symmetric(horizontal: (widget.title.isEmpty ? 18 : 30) * scale);
    final content = Row(
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
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (event) {
        setState(() => _hovering = true);
        HoverTicks.arrive(context, this, event);
      },
      onExit: (_) {
        setState(() => _hovering = false);
        HoverTicks.leave(context, this);
      },
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (focused ? (glass ? GlassRecipe.focusScale : 1.05) : 1),
          duration: _pressed ? const Duration(milliseconds: 90) : Motion.focus,
          curve: Motion.settle,
          child: glass
              // Glass: a pane of frosted ice that becomes a bright ice chip when focused.
              ? IceSurface(
                  radius: 14 * scale,
                  focused: focused,
                  hover: _hovering || widget.prominent,
                  sweep: true,
                  constraints: constraints,
                  padding: padding,
                  child: content,
                )
              : AnimatedContainer(
                  duration: Motion.focus,
                  curve: Motion.settle,
                  constraints: constraints,
                  padding: padding,
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
                  child: content,
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

/// What a hint pill does when it is clicked: the same as its key.
enum HintAction { previousGame, nextGame, select, back, options }

/// Runs a hint pill's action, given by the launcher's shell; without one the pills only show.
class HintScope extends InheritedWidget {
  const HintScope({super.key, required this.onAction, required super.child});

  final void Function(HintAction action) onAction;

  static void Function(HintAction)? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HintScope>()?.onAction;

  @override
  bool updateShouldNotify(HintScope oldWidget) => oldWidget.onAction != onAction;
}

/// Where the hover tick goes: the soft navigation sound when the pointer arrives on a control,
/// tile, row or card (the launcher's shell gives it; nothing without one).
class HoverTicks extends InheritedWidget {
  const HoverTicks({super.key, required this.onArrive, required this.onLeave, required super.child});

  final void Function(Object id, PointerEvent event) onArrive;
  final void Function(Object id) onLeave;

  static void arrive(BuildContext context, Object id, PointerEvent event) =>
      context.getInheritedWidgetOfExactType<HoverTicks>()?.onArrive(id, event);

  static void leave(BuildContext context, Object id) =>
      context.getInheritedWidgetOfExactType<HoverTicks>()?.onLeave(id);

  @override
  bool updateShouldNotify(HoverTicks oldWidget) => false;
}

/// A child that reacts to the pointer: the click cursor, a hover state for [builder], a press
/// that shrinks it a little, and [onTap]. [onHover] runs when the pointer moves over it (not
/// when a list scrolls it under a still pointer), so a hover can move the keyboard's focus
/// without fighting the keys.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    this.onTap,
    this.onDoubleTap,
    this.onHover,
    this.pressScale = 0.97,
  });

  final Widget Function(BuildContext context, bool hovering) builder;
  final VoidCallback? onTap;

  /// A second click on it soon after the first; the first click still runs [onTap] at once.
  final VoidCallback? onDoubleTap;
  final VoidCallback? onHover;
  final double pressScale;

  /// How close two clicks must be to count as a double click.
  static const doubleClick = Duration(milliseconds: 400);

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovering = false;
  bool _pressed = false;

  /// When the pointer went down for this click and for the one before (the events' own times).
  Duration? _down;
  Duration? _lastTap;

  void _tap() {
    final now = _down;
    final last = _lastTap;
    if (widget.onDoubleTap != null && now != null && last != null && now - last <= Pressable.doubleClick) {
      _lastTap = null;
      widget.onDoubleTap!();
      return;
    }
    _lastTap = now;
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onDoubleTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (event) {
        setState(() => _hovering = true);
        if (enabled || widget.onHover != null) HoverTicks.arrive(context, this, event);
      },
      onExit: (_) {
        setState(() => _hovering = false);
        HoverTicks.leave(context, this);
      },
      onHover: widget.onHover == null ? null : (_) => widget.onHover!(),
      child: Listener(
        onPointerDown: (event) => _down = event.timeStamp,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTap: enabled ? _tap : null,
          child: AnimatedScale(
            scale: _pressed ? widget.pressScale : 1,
            duration: const Duration(milliseconds: 90),
            curve: Motion.settle,
            child: widget.builder(context, _hovering && enabled),
          ),
        ),
      ),
    );
  }
}

/// A key or button with what it does; clicked, it does the same as the key.
class Hint extends StatelessWidget {
  const Hint({super.key, required this.keys, required this.label, this.glyph, this.action});

  final String keys;
  final PadGlyph? glyph;
  final String label;
  final HintAction? action;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final run = action == null ? null : HintScope.of(context);
    Widget pill(bool hovering) {
      final color = Colors.white.withValues(alpha: hovering ? 1 : 0.72);
      return AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 4 * scale),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: hovering ? 0.12 : 0),
          borderRadius: BorderRadius.circular(8 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 3 * scale),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: hovering ? 0.26 : 0.16),
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
        ),
      );
    }

    if (run == null) return pill(false);
    return Pressable(onTap: () => run(action!), builder: (context, hovering) => pill(hovering));
  }
}

class HintBar extends StatelessWidget {
  const HintBar({super.key, this.options = true, this.games = true});

  final bool options;

  /// Whether Q and E (L1 and R1) move between games here.
  final bool games;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Wrap(
      spacing: 10 * scale,
      runSpacing: 8 * scale,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Hint(keys: '← → ↑ ↓', label: T.text('hintMove')),
        if (games) ...[
          Hint(keys: 'Q / L1', label: T.text('hintPreviousGame'), action: HintAction.previousGame),
          Hint(keys: 'E / R1', label: T.text('hintNextGame'), action: HintAction.nextGame),
        ],
        Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('hintSelect'), action: HintAction.select),
        Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
        if (options)
          Hint(keys: 'O', glyph: PadGlyph.triangle, label: T.text('hintOptions'), action: HintAction.options),
      ],
    );
  }
}

/// The way out of a panel or a screen over the home screen, for the mouse: Esc / ○ Back.
class BackPill extends StatelessWidget {
  const BackPill({super.key, required this.onTap, this.close = false});

  final VoidCallback onTap;

  /// Shown as a close button (×) instead of Back.
  final bool close;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Semantics(
      button: true,
      label: T.text(close ? 'close' : 'back'),
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => LookScope.isGlass(context)
            ? IceSurface(
                key: const ValueKey('back-pill'),
                radius: 30 * scale,
                hover: hovering,
                backdrop: false,
                shadow: false,
                padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 9 * scale),
                child: _backContent(scale, hovering),
              )
            : AnimatedContainer(
                key: const ValueKey('back-pill'),
                duration: Motion.focus,
                curve: Motion.settle,
                padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 9 * scale),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: hovering ? 0.22 : 0.1),
                  borderRadius: BorderRadius.circular(30 * scale),
                  border: Border.all(color: Colors.white.withValues(alpha: hovering ? 0.3 : 0.12)),
                ),
                child: _backContent(scale, hovering),
              ),
      ),
    );
  }

  Widget _backContent(double scale, bool hovering) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        close ? Icons.close_rounded : Icons.arrow_back_rounded,
        size: 17 * scale,
        color: Colors.white.withValues(alpha: hovering ? 1 : 0.85),
      ),
      SizedBox(width: 8 * scale),
      Text(
        T.text(close ? 'close' : 'back'),
        style: AppText.display(15 * scale, weight: FontWeight.w600, color: Colors.white),
      ),
      SizedBox(width: 10 * scale),
      Text(
        'Esc',
        style: AppText.display(12 * scale, weight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.5)),
      ),
    ],
  );
}

/// A full-screen layer with its way out for the mouse in the top right corner.
class WithBackPill extends StatelessWidget {
  const WithBackPill({super.key, required this.onBack, required this.child});

  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: 18 * scale,
          right: 24 * scale,
          child: BackPill(onTap: onBack),
        ),
      ],
    );
  }
}

/// A game's picture from its file, decoded at about the size it is shown. The file is read and
/// decoded away from the interface (FileImage), and the decoded picture stays in the image cache,
/// so going back to a game shows it at once, without a disk read in the middle of a frame.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({super.key, required this.path, this.fit = BoxFit.cover, this.cacheWidth});

  final String path;
  final BoxFit fit;
  final int? cacheWidth;

  /// Tests read the file on the spot: their fake clock never lets a file read in the
  /// background finish while a frame waits for it.
  @visibleForTesting
  static bool readSynchronously = false;

  static final Map<String, MemoryImage?> _read = {};

  static ImageProvider provider(String path, int? cacheWidth) {
    final ImageProvider image;
    if (readSynchronously) {
      final memory = _read.putIfAbsent(path, () {
        try {
          return MemoryImage(File(path).readAsBytesSync());
        } on FileSystemException {
          return null;
        }
      });
      image = memory ?? FileImage(File(path));
    } else {
      image = FileImage(File(path));
    }
    return cacheWidth == null ? image : ResizeImage(image, width: cacheWidth, policy: ResizeImagePolicy.fit);
  }

  /// Decodes [path] ahead of time (the games beside the selected one), so its picture is ready
  /// when the selection gets there.
  static void warm(BuildContext context, String? path, {int? cacheWidth}) {
    if (path == null) return;
    unawaited(precacheImage(provider(path, cacheWidth), context, onError: (_, _) {}));
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      image: provider(path, cacheWidth),
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
