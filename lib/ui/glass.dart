import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/desktop/window_backdrop.dart';
import 'components.dart' show LayoutScale;
import 'theme.dart';

/// The Glass look's recipe: frosted ice over a cold background. Every surface is layered glass
/// (a blur of what is behind it, a navy base for contrast, a sheen, a rim of refracted light,
/// a still frost grain and a soft shadow); the focused one turns into a bright ice chip. The
/// macOS launcher draws the same numbers.
abstract final class GlassRecipe {
  /// The blur behind full-screen layers (the only blur Glass draws live; see IceSurface).
  static const layerBlur = 30.0;

  /// The navy under the glass that keeps white text readable, and how much of it.
  static const base = Color(0xFF06121F);
  static const baseOpacity = 0.48;

  /// Floating surfaces over anything (toasts) keep up to this much.
  static const floatingOpacity = 0.8;

  /// The sheen across a surface, top left to bottom right, ending in a breath of cyan.
  static const sheenFrom = 0.09;
  static const sheenTo = 0.03;
  static const sheenCyan = 0.045;

  /// The rim's light: white at the top, fading, then a cold cyan at the bottom right.
  static const cyan = Color.fromRGBO(153, 230, 255, 1);
  static const rimTop = 0.55;
  static const rimMiddle = 0.12;
  static const rimBottom = 0.25;

  /// The line of light just inside the top edge.
  static const specular = 0.25;

  /// The frost's strength over a surface.
  static const grain = 0.035;

  /// The shadow under a surface.
  static const shadowOpacity = 0.35;
  static const shadowBlur = 24.0;
  static const shadowOffset = 12.0;

  /// The focused element: a bright frosted ice chip (white at the top, a pale ice at the
  /// bottom) with dark ink and an icy glow.
  static const chipFrom = 0.97;
  static const chipTo = 0.88;
  static const chipIce = Color(0xFFDBF0FF);
  static const ink = Contrast.darkInk;
  static const glowOpacity = 0.35;
  static const glowBlur = 18.0;
  static const focusScale = 1.04;
  static const sweep = Duration(milliseconds: 600);

  /// Surfaces with no transparency (Reduce Transparency, or a GPU too slow for the blur).
  static const solid = Color(0xFF0A1A2A);

  /// Full-screen layers (settings, library, profile…): a frosted navy, lit a little from the
  /// top left.
  static const layer = Color(0xFF04101C);
  static const layerOpacity = 0.62;
  static const layerLight = 0.075;

  /// The selected game's picture, frosted: decoded small, blurred, a little more saturated,
  /// its colors pulled towards ice (a cool gradient in the `color` blend mode, which keeps each
  /// pixel's lightness), under a navy veil.
  static const artworkBlur = 24.0;
  static const artworkWidth = 480;
  static const artworkSaturation = 1.3;
  static const iceTop = Color(0xFFDBF0FF);
  static const iceBottom = Color(0xFF528FD1);
  static const iceOpacity = 0.32;

  /// The veil: navy everywhere, more from the left edge (to 0 at 80 % across) and from the
  /// bottom (from half way down), where the hero text and the cards sit.
  static const veil = 0.42;
  static const veilLeft = [0.5, 0.18, 0.0];
  static const veilLeftStops = [0.0, 0.45, 0.8];
  static const veilBottom = 0.72;

  /// How much navy the veil lays at [x], [y] (fractions of the screen).
  static double veilAt(double x, double y) {
    double left;
    if (x <= veilLeftStops[1]) {
      left = veilLeft[0] + (veilLeft[1] - veilLeft[0]) * x / veilLeftStops[1];
    } else if (x <= veilLeftStops[2]) {
      left = veilLeft[1] + (veilLeft[2] - veilLeft[1]) * (x - veilLeftStops[1]) / (veilLeftStops[2] - veilLeftStops[1]);
    } else {
      left = 0;
    }
    final bottom = y <= 0.5 ? 0.0 : veilBottom * (y - 0.5) / 0.5;
    return 1 - (1 - veil) * (1 - left) * (1 - bottom);
  }

  /// Saturation [artworkSaturation], as a color matrix.
  static List<double> get saturation {
    const s = artworkSaturation;
    const r = 0.2126, g = 0.7152, b = 0.0722;
    return [
      r * (1 - s) + s, g * (1 - s), b * (1 - s), 0, 0, //
      r * (1 - s), g * (1 - s) + s, b * (1 - s), 0, 0, //
      r * (1 - s), g * (1 - s), b * (1 - s) + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }

  /// The frosted picture's brightest possible pixel: white (the `color` blend keeps lightness).
  static const artworkCeiling = Color(0xFFFFFFFF);

  /// [top] at [opacity] over the opaque [bottom].
  static Color over(Color top, double opacity, Color bottom) => Color.lerp(bottom, top.withValues(alpha: 1), opacity)!;

  /// What an unfocused surface looks like over the opaque [backdrop], at its brightest (the
  /// top-left corner of the sheen); the blur only averages the backdrop, so it never brightens it.
  static Color surfaceOver(Color backdrop) =>
      over(const Color(0xFFFFFFFF), sheenFrom, over(base, baseOpacity, backdrop));
}

/// The Glass look's window: see-through to the desktop and the windows behind it (blurred by the
/// system where it blurs) under a light navy tint, so the wallpaper's colors glow through. The
/// text is kept readable where it sits, not by darkening the whole window: on plates (a soft dark
/// plate behind bare text, the cards' and buttons' own glass), each dark enough on its own. The
/// macOS launcher keeps the same numbers.
class GlassWindow {
  const GlassWindow._(this.seeThrough, this.tint, this.blurred);

  static const opaque = GlassWindow._(false, 1, false);

  /// Lets the desktop through (else the window is opaque, as in the other looks).
  final bool seeThrough;

  /// The navy tint's opacity over the desktop.
  final double tint;

  /// The system blurs what is behind the window.
  final bool blurred;

  /// Settings → Appearance → Glass Transparency when it has not been moved, in percent.
  static const defaultTransparency = 90;

  /// The tint at 100 % over a blurred desktop: a breath of navy, so the glass still reads blue.
  static const minimumTint = 0.04;

  /// Over a desktop the system does not blur, its detail stays sharp: more tint calms it.
  static const sharpMinimumTint = 0.3;

  /// The least a plate under text lays over the desktop: white text keeps WCAG AA (4.5:1) and
  /// 70 % white text 3:1 over a pure white desktop (a white window behind, a snowy wallpaper),
  /// counting nothing for the window's tint or the blur, so the screen behind never has to be
  /// read.
  static final double plateFloor = () {
    const white = Color(0xFFFFFFFF);
    bool reads(double plate) {
      final behind = GlassRecipe.over(GlassRecipe.layer, plate, white);
      return Contrast.ratio(white, behind) >= 4.5 && Contrast.ratio(GlassRecipe.over(white, 0.7, behind), behind) >= 3;
    }

    var steps = 0;
    while (!reads(steps / 100)) {
      steps++;
    }
    return steps / 100;
  }();

  /// The plates' core as drawn: over the floor, for a soft plate's fading edge.
  static const plateOpacity = 0.62;

  /// The tint at [transparency] percent: 100 is the minimum, 0 a solid pane.
  static double tintAt(int transparency, {bool blurred = true}) {
    final floor = blurred ? minimumTint : sharpMinimumTint;
    final fraction = transparency.clamp(0, 100) / 100;
    return floor + (1 - floor) * (1 - fraction);
  }

  /// See-through in Glass where the system can show the desktop, unless its surfaces are solid
  /// (Reduce Transparency, a slow GPU) or the slider is at 0 %.
  static GlassWindow make({
    required bool glass,
    required bool solid,
    required int? transparency,
    required BackdropKind kind,
  }) {
    final percent = transparency ?? defaultTransparency;
    if (!glass || solid || !kind.seeThrough || percent <= 0) return opaque;
    return GlassWindow._(true, tintAt(percent, blurred: kind.blurs), kind.blurs);
  }

  @override
  bool operator ==(Object other) =>
      other is GlassWindow && other.seeThrough == seeThrough && other.tint == tint && other.blurred == blurred;

  @override
  int get hashCode => Object.hash(seeThrough, tint, blurred);
}

/// The bottom of Glass's see-through window, over the desktop the system shows: the light navy
/// tint, light from the top left, a breath of cyan at the bottom and the still frost. No veil:
/// the text reads on its plates (Legible, the glass).
class GlassTintPainter extends CustomPainter {
  const GlassTintPainter(this.tint);

  final double tint;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = GlassRecipe.layer.withValues(alpha: tint));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.76, -1.2),
          radius: 1.2,
          colors: [const Color(0xFFFFFFFF).withValues(alpha: 0.07), const Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [GlassRecipe.cyan.withValues(alpha: 0), GlassRecipe.cyan.withValues(alpha: 0.03)],
        ).createShader(rect),
    );
    FrostGrain.paint(canvas, rect, 0.03);
  }

  @override
  bool shouldRepaint(GlassTintPainter oldDelegate) => oldDelegate.tint != tint;
}

/// Bare text on Glass's see-through window (a title, the clock, the hints): a soft dark plate
/// behind it, dark enough at its core for the text on its own over a white desktop
/// (GlassWindow.plateFloor), fading out beyond it. Elsewhere nothing changes.
class Legible extends StatelessWidget {
  const Legible({super.key, this.softness = 18, required this.child});

  final double softness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!LookScope.isSeeThrough(context)) return child;
    final soft = softness * LayoutScale.of(context);
    // A plate reaching 1.8 soft past the text, blurred with a sigma of 1.15 soft: its edge is
    // halved, under the text it is still over 0.94 of its fill.
    final reach = soft * 1.8;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: -reach,
          top: -reach,
          right: -reach,
          bottom: -reach,
          // The plate is a blurred rounded box drawn with a mask filter, which the GPU draws in
          // one cheap step; filtering a layer (as it was) cost a pass for every plate on screen.
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: PlatePainter(reach: reach, sigma: soft * 1.15),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Legible's plate: a soft dark rounded box.
class PlatePainter extends CustomPainter {
  const PlatePainter({required this.reach, required this.sigma});

  final double reach;
  final double sigma;

  /// Its fill at the core.
  static final fill = GlassRecipe.layer.withValues(alpha: GlassWindow.plateOpacity + 0.04);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(reach)),
      Paint()
        ..color = fill
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
  }

  @override
  bool shouldRepaint(PlatePainter old) => old.reach != reach || old.sigma != sigma;
}

/// Below it, what is behind has been frosted already (a full-screen layer's blur): a surface
/// there needs no blur of its own. Nested blurs each read and blur the screen again, and they
/// were what made opening and scrolling a panel crawl on an integrated GPU.
class FrostedBehind extends InheritedWidget {
  const FrostedBehind({super.key, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<FrostedBehind>() != null;

  @override
  bool updateShouldNotify(FrostedBehind oldWidget) => false;
}

/// How the interface below is drawn: the Glass look, whether its glass is solid, and whether the
/// window lets the desktop through.
class LookScope extends InheritedWidget {
  const LookScope({super.key, required this.glass, required this.solid, this.seeThrough = false, required super.child});

  /// The Glass look is in use.
  final bool glass;

  /// Surfaces are drawn without transparency or blur (Reduce Transparency, a slow GPU).
  final bool solid;

  /// Glass's window shows the desktop behind it (GlassWindow).
  final bool seeThrough;

  static LookScope? _of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LookScope>();

  static bool isGlass(BuildContext context) => _of(context)?.glass ?? false;
  static bool isSolid(BuildContext context) => _of(context)?.solid ?? false;
  static bool isSeeThrough(BuildContext context) => _of(context)?.seeThrough ?? false;

  /// The ink for words on [accent]: in Glass, and on the light Ice accent anywhere, it follows
  /// the fill's lightness; the older looks keep [otherwise], as they were drawn.
  static Color inkOnAccent(BuildContext context, Color accent, Color otherwise) =>
      isGlass(context) || accent == Accent.ice.color ? Contrast.inkOn(accent) : otherwise;

  /// The ink of a focused element: Glass's navy, black elsewhere.
  static Color focusedInk(BuildContext context) => isGlass(context) ? GlassRecipe.ink : Colors.black;

  @override
  bool updateShouldNotify(LookScope oldWidget) =>
      oldWidget.glass != glass || oldWidget.solid != solid || oldWidget.seeThrough != seeThrough;
}

/// The frost: a still grain of light and dark specks laid over glass at a few percent. It is a
/// small tile made once and repeated as an image shader (the GPU's cheapest fill); the per-pixel
/// shader it used to be cost a few milliseconds a frame over a panel.
abstract final class FrostGrain {
  static const tile = 128;
  static Future<void>? _loading;
  static ui.Image? _tile;

  static Future<void> preload() => _loading ??= Future(() => _tile ??= _make());

  /// The tile at full strength: every pixel a speck of white or black whose opacity is how far
  /// its random value is from the middle (the same recipe as the shader's).
  static ui.Image _make() {
    final random = math.Random(1977);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint();
    for (var y = 0; y < tile; y++) {
      for (var x = 0; x < tile; x++) {
        final n = random.nextDouble() - 0.5;
        final alpha = (n.abs() * 2).clamp(0.0, 1.0);
        if (alpha < 0.02) continue;
        paint.color = (n > 0 ? Colors.white : Colors.black).withValues(alpha: alpha);
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), paint);
      }
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(tile, tile);
    picture.dispose();
    return image;
  }

  /// Paints the grain over [rect] at [strength].
  static void paint(Canvas canvas, Rect rect, double strength) {
    final image = _tile ??= _make();
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white.withValues(alpha: strength.clamp(0.0, 1.0))
        ..shader = ImageShader(image, TileMode.repeated, TileMode.repeated, Matrix4.identity().storage),
    );
  }
}

/// Glass that is not changing (a surface at rest, focused or not) drawn once and kept as an
/// image, then laid down as one picture per frame: drawn live, every gradient, rim and speck of
/// every card and row was worked out again on every frame anything on screen moved, 29 ms a
/// frame for Glass's home on an integrated GPU.
abstract final class _IceCache {
  static final Map<Object, ui.Image> _images = {};

  /// At most this many images and this many bytes of them are kept, the longest unused going
  /// first (a window being resized makes new sizes on every frame).
  static const limit = 160;
  static const byteLimit = 48 << 20;
  static int _bytes = 0;

  /// Draws what [draw] draws over [size] (and up to [margin] around it), from the image kept for
  /// [key] (made at [ratio] pixels a point the first time).
  static void paint(
    Canvas canvas,
    Size size,
    double ratio,
    Object key,
    void Function(Canvas canvas) draw, {
    double margin = 0,
  }) {
    final area = (Offset.zero & size).inflate(margin);
    final width = (area.width * ratio).ceil();
    final height = (area.height * ratio).ceil();
    if (width <= 0 || height <= 0 || width * height > 4096 * 4096) return draw(canvas);
    final full = (key, width, height, margin);
    var image = _images.remove(full);
    if (image == null) {
      final recorder = ui.PictureRecorder();
      draw(
        Canvas(recorder)
          ..scale(width / area.width, height / area.height)
          ..translate(margin, margin),
      );
      final picture = recorder.endRecording();
      image = picture.toImageSync(width, height);
      picture.dispose();
      _bytes += width * height * 4;
      while (_images.isNotEmpty && (_images.length >= limit || _bytes > byteLimit)) {
        final old = _images.remove(_images.keys.first)!;
        _bytes -= old.width * old.height * 4;
        old.dispose();
      }
    }
    _images[full] = image;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      area,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  /// How many images, and bytes of them, are kept (tests).
  static int get length => _images.length;
  static int get bytes => _bytes;
}

/// How many pictures of resting glass are kept, and their bytes (tests).
int get iceCacheLength => _IceCache.length;
int get iceCacheBytes => _IceCache.bytes;

/// A surface of frosted ice: the base, the sheen, the frost and the rim over what is behind it.
/// [focused] turns it into the bright ice chip (the caller switches its ink to [GlassRecipe.ink]
/// and scales it); [sweep] runs a sheen across it as it gains focus.
///
/// A surface blurs nothing itself (but a [blur] one floating over sharp content): everything
/// Glass puts behind its surfaces is soft already (the slow background, the frosted picture, the
/// desktop the system blurs behind the window, a full-screen layer's one blur), where a blur of
/// its own changed nothing visible and cost a pass over the screen for every card, button and
/// pill: on an integrated GPU a panel full of them drew at 3 to 13 frames a second.
class IceSurface extends StatelessWidget {
  const IceSurface({
    super.key,
    required this.radius,
    this.child,
    this.padding,
    this.focused = false,
    this.blur = false,
    this.shadow = true,
    this.sweep = false,
    this.opacity = GlassRecipe.baseOpacity,
    this.rim = 1,
    this.sheen = true,
    this.hover = false,
    this.width,
    this.height,
    this.constraints,
  });

  final double radius;
  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final bool focused;

  /// A surface floating over sharp content (a menu over the messages) blurs it itself.
  final bool blur;
  final bool shadow;
  final bool sweep;
  final bool hover;

  /// The navy base's opacity: more for large panels full of text.
  final double opacity;

  /// How much of the rim shows unfocused (quieter for rows inside a panel), and whether the
  /// sheen does.
  final double rim;
  final bool sheen;
  final double? width;
  final double? height;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final solid = LookScope.isSolid(context);
    // On the see-through window a surface is a plate that its text reads on alone.
    final base = LookScope.isSeeThrough(context) ? math.max(opacity, GlassWindow.plateOpacity) : opacity;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: focused ? 1 : 0),
      duration: Motion.focus,
      curve: Motion.settle,
      child: Container(width: width, height: height, constraints: constraints, padding: padding, child: child),
      builder: (context, t, content) {
        Widget body = CustomPaint(
          painter: _IceFill(
            radius: radius,
            focus: t,
            solid: solid,
            opacity: base,
            hover: hover,
            sheen: sheen,
            ratio: ratio,
          ),
          foregroundPainter: rim == 0 && t == 0 ? null : _IceRim(radius: radius, focus: t, strength: rim, ratio: ratio),
          child: content,
        );
        if (sweep) body = SheenSweep(active: focused, child: body);
        final clip = ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: blur && !solid
              ? BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: body)
              : body,
        );
        if (!shadow && t == 0) return clip;
        return CustomPaint(
          painter: _IceHalo(radius: radius, focus: t, shadow: shadow, ratio: ratio),
          child: clip,
        );
      },
    );
  }
}

/// The base, sheen and frost of a surface, or the ice chip's bright fill when focused.
class _IceFill extends CustomPainter {
  _IceFill({
    required this.radius,
    required this.focus,
    required this.solid,
    required this.opacity,
    required this.hover,
    required this.sheen,
    this.ratio = 1,
  });

  final double radius;
  final double focus;
  final bool solid;
  final double opacity;
  final bool hover;
  final bool sheen;
  final double ratio;

  @override
  void paint(Canvas canvas, Size size) {
    // At rest (not halfway through gaining or losing focus): the kept picture.
    if (focus == 0 || focus == 1) {
      return _IceCache.paint(canvas, size, ratio, (
        'fill',
        size,
        radius,
        focus,
        solid,
        opacity,
        hover,
        sheen,
      ), (canvas) => _draw(canvas, size));
    }
    _draw(canvas, size);
  }

  void _draw(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final white = Colors.white;
    if (focus < 1) {
      if (opacity > 0) {
        // Solid, a surface is opaque navy; a pane inside a panel stays clear over the panel's.
        final base = solid && opacity >= GlassRecipe.baseOpacity
            ? GlassRecipe.solid
            : GlassRecipe.base.withValues(alpha: opacity);
        canvas.drawRRect(shape, Paint()..color = base);
      }
      if (sheen) {
        canvas.drawRRect(
          shape,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                white.withValues(alpha: GlassRecipe.sheenFrom + (hover ? 0.05 : 0)),
                white.withValues(alpha: GlassRecipe.sheenTo + (hover ? 0.03 : 0)),
                GlassRecipe.cyan.withValues(alpha: GlassRecipe.sheenCyan),
              ],
            ).createShader(rect),
        );
      }
    }
    if (focus > 0) {
      canvas.drawRRect(
        shape,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              white.withValues(alpha: GlassRecipe.chipFrom * focus),
              GlassRecipe.chipIce.withValues(alpha: GlassRecipe.chipTo * focus),
            ],
          ).createShader(rect),
      );
    }
    canvas
      ..save()
      ..clipRRect(shape);
    FrostGrain.paint(canvas, rect, GlassRecipe.grain);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IceFill old) =>
      old.radius != radius ||
      old.focus != focus ||
      old.solid != solid ||
      old.opacity != opacity ||
      old.hover != hover ||
      old.sheen != sheen ||
      old.ratio != ratio;
}

/// The rim of refracted light around a surface and the specular line inside its top edge.
class _IceRim extends CustomPainter {
  _IceRim({required this.radius, required this.focus, required this.strength, this.ratio = 1});

  final double radius;
  final double focus;
  final double strength;
  final double ratio;

  @override
  void paint(Canvas canvas, Size size) {
    if (focus == 0 || focus == 1) {
      return _IceCache.paint(canvas, size, ratio, (
        'rim',
        size,
        radius,
        focus,
        strength,
      ), (canvas) => _draw(canvas, size));
    }
    _draw(canvas, size);
  }

  void _draw(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    double lerp(double a, double b) => a * strength + (b - a * strength) * focus;
    final white = Colors.white;
    final edge = RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(math.max(0, radius - 0.5)));
    canvas
      // White light from above: top to bottom whatever the shape (a diagonal across a wide
      // row would run mostly sideways).
      ..drawRRect(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              white.withValues(alpha: lerp(GlassRecipe.rimTop, 1)),
              white.withValues(alpha: lerp(GlassRecipe.rimMiddle, 0.6)),
              white.withValues(alpha: lerp(0.04, 0.35)),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(rect),
      )
      // And the cold light it bends into the bottom right corner.
      ..drawRRect(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = RadialGradient(
            center: Alignment.bottomRight,
            radius: 1,
            colors: [
              GlassRecipe.cyan.withValues(alpha: lerp(GlassRecipe.rimBottom, 0.85)),
              GlassRecipe.cyan.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: rect.bottomRight, radius: math.max(size.height * 1.4, 36))),
      );
    if (size.height <= 4) return;
    // Just inside the top edge, following the corners' curve and gone by the middle.
    final reach = math.min(1.0, math.max(radius, 8) / size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1.5), Radius.circular(math.max(0, radius - 1.5))),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            white.withValues(alpha: lerp(GlassRecipe.specular, 0.9)),
            white.withValues(alpha: 0),
          ],
          stops: [0, reach],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_IceRim old) =>
      old.radius != radius || old.focus != focus || old.strength != strength || old.ratio != ratio;
}

/// The shadow under a surface (outside its shape only, so the glass is not darkened through)
/// and, focused, its icy glow. At rest it is drawn once and kept as an image (_IceCache), so the
/// cut-out shape costs nothing on the frames after.
class _IceHalo extends CustomPainter {
  _IceHalo({required this.radius, required this.focus, required this.shadow, this.ratio = 1});

  final double radius;
  final double focus;
  final bool shadow;
  final double ratio;

  /// How far the shadow and the glow reach past the box.
  static const reach = GlassRecipe.shadowOffset + GlassRecipe.shadowBlur * 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    if (focus == 0 || focus == 1) {
      return _IceCache.paint(
        canvas,
        size,
        ratio,
        ('halo', size, radius, focus, shadow),
        (canvas) => _draw(canvas, size),
        margin: reach,
      );
    }
    _draw(canvas, size);
  }

  void _draw(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(box, Radius.circular(radius));
    if (shadow) {
      final outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(box.inflate(reach))
        ..addRRect(shape);
      canvas
        ..save()
        ..clipPath(outside)
        ..drawRRect(
          shape.shift(const Offset(0, GlassRecipe.shadowOffset)),
          Paint()
            ..color = Colors.black.withValues(alpha: GlassRecipe.shadowOpacity * (1 - 0.3 * focus))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, GlassRecipe.shadowBlur / 2),
        )
        ..restore();
    }
    if (focus > 0) {
      canvas.drawRRect(
        shape,
        Paint()
          ..color = GlassRecipe.cyan.withValues(alpha: GlassRecipe.glowOpacity * focus)
          ..maskFilter = const MaskFilter.blur(BlurStyle.outer, GlassRecipe.glowBlur / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_IceHalo old) =>
      old.radius != radius || old.focus != focus || old.shadow != shadow || old.ratio != ratio;
}

/// A band of light that sweeps once across its child when [active] turns on: the glint of a
/// pane catching the light. Not with reduced motion.
class SheenSweep extends StatefulWidget {
  const SheenSweep({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<SheenSweep> createState() => _SheenSweepState();
}

class _SheenSweepState extends State<SheenSweep> with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(vsync: this, duration: GlassRecipe.sweep);

  @override
  void didUpdateWidget(SheenSweep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && !Motion.reduced) {
      _run.forward(from: 0);
    } else if (!widget.active) {
      _run.value = 0;
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _run,
      child: widget.child,
      builder: (context, child) => CustomPaint(
        foregroundPainter: _run.isAnimating ? _SweepPainter(Curves.easeOut.transform(_run.value)) : null,
        child: child,
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // The band's centre crosses from beyond the left edge to beyond the right one; it fades in
    // and out so it never pops at either end.
    final centre = -0.35 + 1.7 * progress;
    final strength = math.sin(math.pi * progress) * 0.32;
    final band = 0.16;
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = LinearGradient(
          begin: const Alignment(-1, -0.6),
          end: const Alignment(1, 0.6),
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: strength),
            Colors.white.withValues(alpha: 0),
          ],
          stops: [(centre - band).clamp(0.0, 1.0), centre.clamp(0.0, 1.0), (centre + band).clamp(0.0, 1.0)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.progress != progress;
}

/// A full-screen layer over the home screen: blurred and darkened, as it always was; in Glass a
/// frosted navy with a faint light along its top and the frost over it.
class LayerScrim extends StatelessWidget {
  const LayerScrim({super.key, required this.opacity, required this.child});

  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The layer's blur is the only one under it: its panels and buttons sit on it unblurred.
    final frosted = FrostedBehind(child: child);
    if (!LookScope.isGlass(context)) {
      return ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: ColoredBox(
            color: Colors.black.withValues(alpha: opacity),
            child: frosted,
          ),
        ),
      );
    }
    final solid = LookScope.isSolid(context);
    // On the see-through window the layer is a pane over the desktop the system already blurs,
    // and the home screen fades out under it (LauncherShell) instead of being blurred: a blur of
    // the whole window on every frame kept scrolling a panel there under 30 frames a second.
    final seeThrough = LookScope.isSeeThrough(context);
    return ClipRect(
      child: BackdropFilter(
        enabled: !solid && !seeThrough,
        filter: ui.ImageFilter.blur(sigmaX: GlassRecipe.layerBlur, sigmaY: GlassRecipe.layerBlur),
        child: CustomPaint(
          painter: _LayerPainter(solid ? 0.94 : math.max(GlassRecipe.layerOpacity, opacity)),
          child: frosted,
        ),
      ),
    );
  }
}

class _LayerPainter extends CustomPainter {
  _LayerPainter(this.opacity);

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas
      ..drawRect(rect, Paint()..color = GlassRecipe.layer.withValues(alpha: opacity))
      ..drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: Alignment.topLeft,
            radius: 1.1,
            colors: [
              Colors.white.withValues(alpha: GlassRecipe.layerLight),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    FrostGrain.paint(canvas, rect, 0.03);
  }

  @override
  bool shouldRepaint(_LayerPainter old) => old.opacity != opacity;
}

/// The navy veil over the frosted game picture, darker where the words are.
class ArtworkScrim extends StatelessWidget {
  const ArtworkScrim({super.key});

  @override
  Widget build(BuildContext context) => const CustomPaint(painter: _ArtworkScrimPainter(), size: Size.infinite);
}

class _ArtworkScrimPainter extends CustomPainter {
  const _ArtworkScrimPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const navy = GlassRecipe.layer;
    canvas
      ..drawRect(rect, Paint()..color = navy.withValues(alpha: GlassRecipe.veil))
      ..drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            colors: [for (final alpha in GlassRecipe.veilLeft) navy.withValues(alpha: alpha)],
            stops: GlassRecipe.veilLeftStops,
          ).createShader(rect),
      )
      ..drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              navy.withValues(alpha: 0),
              navy.withValues(alpha: GlassRecipe.veilBottom),
            ],
            stops: const [0.5, 1],
          ).createShader(rect),
      );
    FrostGrain.paint(canvas, rect, 0.03);
  }

  @override
  bool shouldRepaint(_ArtworkScrimPainter oldDelegate) => false;
}

/// Watches how long frames take on the GPU and gives up on Glass's transparency when it is too
/// slow: if most frames of two windows in a row take over [budget] to draw, or [severeRun]
/// frames in a row take over [severe] (under 25 a second: a launcher that visibly drags),
/// [onSlow] runs (once). The launcher draws frames only while something moves, so the windows
/// are short: a few seconds of use are enough to tell.
class RasterWatch {
  RasterWatch({
    required this.onSlow,
    this.budget = const Duration(milliseconds: 12),
    this.window = 30,
    this.share = 0.6,
    this.windows = 2,
    this.severe = const Duration(milliseconds: 40),
    this.severeRun = 8,
  });

  final VoidCallback onSlow;
  final Duration budget;
  final int window;
  final double share;
  final int windows;
  final Duration severe;
  final int severeRun;

  int _frames = 0;
  int _slow = 0;
  int _strikes = 0;
  int _severe = 0;
  bool _done = false;

  bool get tripped => _done;

  /// Counts frames that took [raster] to draw.
  void add(Iterable<Duration> raster) {
    for (final duration in raster) {
      if (_done) return;
      _severe = duration > severe ? _severe + 1 : 0;
      if (_severe >= severeRun) return _trip();
      _frames++;
      if (duration > budget) _slow++;
      if (_frames < window) continue;
      _strikes = _slow >= window * share ? _strikes + 1 : 0;
      _frames = 0;
      _slow = 0;
      if (_strikes >= windows) return _trip();
    }
  }

  void _trip() {
    _done = true;
    onSlow();
  }

  /// Starts over, frames before now forgotten (a game ran, the look changed).
  void reset() {
    _frames = 0;
    _slow = 0;
    _strikes = 0;
    _severe = 0;
  }
}

/// A row of a list on a full-screen layer (trophies, a profile's games): a filled rounded box
/// that turns white when focused, as the older looks draw it; in Glass a thin pane of ice that
/// turns into the bright chip.
class PaneRow extends StatelessWidget {
  const PaneRow({
    super.key,
    required this.focused,
    required this.radius,
    required this.padding,
    required this.margin,
    required this.child,
  });

  final bool focused;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (LookScope.isGlass(context)) {
      return Padding(
        padding: margin,
        child: IceSurface(
          radius: radius,
          focused: focused,
          shadow: false,
          sweep: true,
          opacity: 0.16,
          rim: 0.45,
          padding: padding,
          child: child,
        ),
      );
    }
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: focused ? Colors.white : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}
