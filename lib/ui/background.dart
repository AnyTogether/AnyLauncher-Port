import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'components.dart';
import 'theme.dart';

/// The theme's animated background, drawn by shaders/background.frag (the GLSL form of the macOS
/// launcher's Metal shader). It stops while a game runs, leaving the GPU to the game. Where the
/// shader cannot load, a painted gradient stands in.
class ThemeBackground extends StatefulWidget {
  const ThemeBackground({super.key, required this.style, this.paused = false, this.time});

  /// Loads the shader ahead of the first background (tests load it outside their fake clock).
  static Future<void> preload() => _ThemeBackgroundState.preload();

  final LookStyle style;
  final bool paused;

  /// A fixed moment of the animation (previews, tests); null animates.
  final double? time;

  @override
  State<ThemeBackground> createState() => _ThemeBackgroundState();
}

class _ThemeBackgroundState extends State<ThemeBackground> with SingleTickerProviderStateMixin {
  /// Loads the shader ahead of the first background (tests load it outside their fake clock).
  static Future<void> preload() => _program ??= _load();

  static Future<ui.FragmentProgram?>? _program;
  static ui.FragmentProgram? _ready;
  ui.FragmentProgram? _loaded = _ready;
  Ticker? _ticker;

  /// The clock starts somewhere in the middle of the animation, not at its quiet first frame.
  double _clock = 40 + math.Random().nextDouble() * 360;
  Duration _last = Duration.zero;

  static Future<ui.FragmentProgram?> _load() async {
    try {
      return _ready = await ui.FragmentProgram.fromAsset('shaders/background.frag');
    } on Object {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _program ??= _load();
    _program!.then((program) {
      if (mounted) setState(() => _loaded = program);
    });
    if (widget.time == null) {
      _ticker = createTicker((elapsed) {
        final step = (elapsed - _last).inMicroseconds / 1e6;
        _last = elapsed;
        if (widget.paused) return;
        setState(() => _clock += math.min(0.1, step));
      })..start();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time = widget.time ?? _clock % 3600;
    final program = _loaded;
    return RepaintBoundary(
      child: CustomPaint(
        painter: program == null
            ? _FallbackPainter(widget.style)
            : _ShaderPainter(program.fragmentShader(), widget.style, time),
        size: Size.infinite,
      ),
    );
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter(this.shader, this.style, this.time);

  final ui.FragmentShader shader;
  final LookStyle style;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    var index = 0;
    void set(double value) => shader.setFloat(index++, value);
    set(math.max(1, size.width));
    set(math.max(1, size.height));
    set(time);
    set(style.index.toDouble());
    for (final color in [style.deep, style.middle, style.bright]) {
      set(color.r);
      set(color.g);
      set(color.b);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ShaderPainter oldDelegate) => oldDelegate.time != time || oldDelegate.style != style;
}

/// The theme's tones as a still gradient with its glow, where shaders are missing.
class _FallbackPainter extends CustomPainter {
  _FallbackPainter(this.style);
  final LookStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [style.middle, style.deep],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.6, -0.85),
          radius: 0.9,
          colors: [style.bright.withValues(alpha: 0.28), style.bright.withValues(alpha: 0)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_FallbackPainter oldDelegate) => oldDelegate.style != style;
}

/// pic0.png behind the home screen, drifting slowly, darkened where the text sits.
class GameArtwork extends StatefulWidget {
  const GameArtwork({super.key, required this.path, this.animated = true});

  final String path;
  final bool animated;

  @override
  State<GameArtwork> createState() => _GameArtworkState();
}

class _GameArtworkState extends State<GameArtwork> with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 24));

  @override
  void initState() {
    super.initState();
    if (widget.animated) _drift.repeat(reverse: true);
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: _drift,
          builder: (context, child) => Transform.scale(
            scale: 1.01 + 0.06 * Curves.easeInOut.transform(_drift.value),
            alignment: Alignment.topRight,
            child: child,
          ),
          child: ArtworkImage(path: widget.path, cacheWidth: 1920),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xC7000000), Color(0x59000000), Color(0x00000000)],
              stops: [0, 0.5, 0.85],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x8C000000), Color(0x00000000), Color(0x00000000), Color(0xD9000000)],
              stops: [0, 0.3, 0.55, 1],
            ),
          ),
        ),
      ],
    );
  }
}
