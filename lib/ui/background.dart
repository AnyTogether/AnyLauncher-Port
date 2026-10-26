import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'components.dart';
import 'glass.dart';
import 'theme.dart';

/// The theme's animated background, drawn by shaders/background.frag (the GLSL form of the macOS
/// launcher's Metal shader). Where the shader cannot load, a painted gradient stands in.
///
/// It is the costliest thing the launcher draws (on an integrated GPU the full-window shader at
/// 60 frames a second kept the GPU 85 % busy with the launcher doing nothing), so it is drawn
/// sparingly: moving, at [rate] steps a second and at half the window's resolution, then scaled
/// up (its light is soft, the half resolution does not show); still ([paused], or under a muted
/// [TickerMode], as while a game is in front), it asks for no frame at all.
class ThemeBackground extends StatefulWidget {
  const ThemeBackground({super.key, required this.style, this.paused = false, this.time});

  /// Loads the shaders ahead of the first background (tests load them outside their fake clock).
  static Future<void> preload() => Future.wait([_ThemeBackgroundState.preload(), FrostGrain.preload()]);

  /// Steps a second while it moves: Glass drifts so slowly that 20 look the same as 60, the
  /// others' ribbons and lights need 30.
  static int rate(LookStyle style) => style == LookStyle.glass ? 20 : 30;

  /// The share of the window's width and height the moving background is drawn at.
  static const resolution = 0.5;

  final LookStyle style;
  final bool paused;

  /// A fixed moment of the animation (previews, tests); null animates.
  final double? time;

  @override
  State<ThemeBackground> createState() => _ThemeBackgroundState();
}

class _ThemeBackgroundState extends State<ThemeBackground> {
  /// Loads the shader ahead of the first background (tests load it outside their fake clock).
  static Future<void> preload() => _program ??= _load();

  static Future<ui.FragmentProgram?>? _program;
  static ui.FragmentProgram? _ready;
  ui.FragmentProgram? _loaded = _ready;

  /// The clock starts somewhere in the middle of the animation, not at its quiet first frame.
  double _clock = 40 + math.Random().nextDouble() * 360;

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(ThemeBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.style != oldWidget.style || widget.paused != oldWidget.paused) _follow();
  }

  /// A timer moves it (a ticker would ask for a frame at every refresh of the screen); paused,
  /// or with tickers muted above it, the timer stops.
  Timer? _steps;
  int _rate = 0;

  void _follow() {
    final moving = widget.time == null && !widget.paused && TickerMode.valuesOf(context).enabled;
    final rate = ThemeBackground.rate(widget.style);
    if (moving && _steps != null && _rate == rate) return;
    _steps?.cancel();
    _steps = null;
    if (!moving) return;
    _rate = rate;
    _steps = Timer.periodic(Duration(microseconds: 1000000 ~/ rate), (_) {
      if (mounted) setState(() => _clock += 1 / rate);
    });
  }

  @override
  void dispose() {
    _steps?.cancel();
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
            : _ShaderPainter(
                program.fragmentShader(),
                widget.style,
                time,
                // A still frame is drawn once: it may as well be sharp.
                resolution: widget.time == null ? ThemeBackground.resolution : 1,
              ),
        size: Size.infinite,
      ),
    );
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter(this.shader, this.style, this.time, {this.resolution = 1});

  final ui.FragmentShader shader;
  final LookStyle style;
  final double time;
  final double resolution;

  void _draw(Canvas canvas, Size size) {
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
  void paint(Canvas canvas, Size size) {
    if (resolution >= 1 || size.isEmpty) return _draw(canvas, size);
    final width = math.max(1, (size.width * resolution).ceil());
    final height = math.max(1, (size.height * resolution).ceil());
    final recorder = ui.PictureRecorder();
    _draw(Canvas(recorder), Size(width.toDouble(), height.toDouble()));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    image.dispose();
  }

  @override
  bool shouldRepaint(_ShaderPainter oldDelegate) =>
      oldDelegate.time != time || oldDelegate.style != style || oldDelegate.resolution != resolution;
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

  /// The width backgrounds are decoded at.
  static const cacheWidth = 1920;

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
  void didUpdateWidget(GameArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated == oldWidget.animated) return;
    widget.animated ? _drift.repeat(reverse: true) : _drift.stop();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (LookScope.isGlass(context)) return _frosted();
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
          child: ArtworkImage(path: widget.path, cacheWidth: GameArtwork.cacheWidth),
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

  /// Glass: the picture frosted behind the ice. Decoded small and blurred hard, cooled, kept
  /// under a ceiling of brightness, under the navy veil; it stays still (drifting, a blur this
  /// soft only costs frames and shows nothing).
  Widget _frosted() {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: GlassRecipe.artworkBlur,
              sigmaY: GlassRecipe.artworkBlur,
              tileMode: TileMode.mirror,
            ),
            child: Transform.scale(
              scale: 1.08,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColorFiltered(
                    colorFilter: ColorFilter.matrix(GlassRecipe.saturation),
                    child: ArtworkImage(path: widget.path, cacheWidth: GlassRecipe.artworkWidth),
                  ),
                  const CustomPaint(painter: _IceTint()),
                ],
              ),
            ),
          ),
        ),
        const ArtworkScrim(),
      ],
    );
  }
}

/// The cool gradient laid over the frosted picture in the `color` blend mode: its hue and
/// saturation, the picture's lightness.
class _IceTint extends CustomPainter {
  const _IceTint();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.color
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            GlassRecipe.iceTop.withValues(alpha: GlassRecipe.iceOpacity),
            GlassRecipe.iceBottom.withValues(alpha: GlassRecipe.iceOpacity),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_IceTint oldDelegate) => false;
}
