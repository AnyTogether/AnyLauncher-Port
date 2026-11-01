import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// A colour as red, green and blue from 0 to 1.
typedef Rgb = ({double r, double g, double b});

/// A look someone made for the launcher (and the phone): one of the animated backgrounds in
/// their own colours, an accent, and maybe a picture or video behind it all and menu music.
/// Shared as one `.anyps5theme` file, a zip of theme.json and the files it names. The same file
/// as the macOS launcher's (ThemeDesign.swift), so a theme moves between the two.
class ThemeDesign {
  const ThemeDesign({
    required this.id,
    required this.name,
    this.author = '',
    this.version = 1,
    this.style = 0,
    required this.deep,
    required this.middle,
    required this.bright,
    required this.accent,
    this.background,
    this.music,
  });

  static const fileExtension = 'anyps5theme';

  final String id;
  final String name;
  final String author;
  final int version;

  /// The animated background: 0 cosmic, 1 aurora, 2 sunset, 3 glass (LookStyle).
  final int style;

  /// Deep, middle and bright tones of the background, and the accent, as #RRGGBB.
  final String deep;
  final String middle;
  final String bright;
  final String accent;

  /// File names inside the theme's folder.
  final String? background;
  final String? music;

  /// The file endings a background video has; anything else is a picture.
  static const videoExtensions = ['mp4', 'mov', 'm4v', 'webm', 'mkv'];
  static const pictureExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'];

  /// The music the launcher plays: what flutter_soloud reads without the Xiph libraries.
  static const musicExtensions = ['mp3', 'm4a', 'wav', 'aac'];

  /// Whether the background file is a video, by its name.
  bool get backgroundIsVideo => isVideo(background);

  static bool isVideo(String? file) {
    if (file == null) return false;
    final extension = p.extension(file).toLowerCase();
    return extension.length > 1 && videoExtensions.contains(extension.substring(1));
  }

  Rgb get deepRgb => rgb(deep) ?? (r: 0.012, g: 0.024, b: 0.09);
  Rgb get middleRgb => rgb(middle) ?? (r: 0.04, g: 0.15, b: 0.42);
  Rgb get brightRgb => rgb(bright) ?? (r: 0.42, g: 0.64, b: 1.0);
  Rgb get accentRgb => rgb(accent) ?? (r: 0.31, g: 0.58, b: 1.0);

  /// A theme.json; null when it is not one (a field missing or of another kind).
  static ThemeDesign? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'], name = json['name'];
    final deep = json['deep'], middle = json['middle'], bright = json['bright'], accent = json['accent'];
    if (id is! String || name is! String || deep is! String || middle is! String) return null;
    if (bright is! String || accent is! String) return null;
    final background = json['background'], music = json['music'];
    return ThemeDesign(
      id: id,
      name: name,
      author: json['author'] is String ? json['author'] as String : '',
      version: json['version'] is num ? (json['version'] as num).toInt() : 1,
      style: json['style'] is num ? (json['style'] as num).toInt() : 0,
      deep: deep,
      middle: middle,
      bright: bright,
      accent: accent,
      background: background is String ? background : null,
      music: music is String ? music : null,
    );
  }

  /// theme.json's fields, sorted by name as the macOS launcher writes them; no file is no key.
  Map<String, Object> toJson() => {
    'accent': accent,
    'author': author,
    'background': ?background,
    'bright': bright,
    'deep': deep,
    'id': id,
    'middle': middle,
    'music': ?music,
    'name': name,
    'style': style,
    'version': version,
  };

  ThemeDesign copyWith({
    String? id,
    String? name,
    String? author,
    int? version,
    int? style,
    String? deep,
    String? middle,
    String? bright,
    String? accent,
    String? Function()? background,
    String? Function()? music,
  }) => ThemeDesign(
    id: id ?? this.id,
    name: name ?? this.name,
    author: author ?? this.author,
    version: version ?? this.version,
    style: style ?? this.style,
    deep: deep ?? this.deep,
    middle: middle ?? this.middle,
    bright: bright ?? this.bright,
    accent: accent ?? this.accent,
    background: background == null ? this.background : background(),
    music: music == null ? this.music : music(),
  );

  @override
  bool operator ==(Object other) =>
      other is ThemeDesign &&
      other.id == id &&
      other.name == name &&
      other.author == author &&
      other.version == version &&
      other.style == style &&
      other.deep == deep &&
      other.middle == middle &&
      other.bright == bright &&
      other.accent == accent &&
      other.background == background &&
      other.music == music;

  @override
  int get hashCode => Object.hash(id, name, author, version, style, deep, middle, bright, accent, background, music);

  /// #RRGGBB (or RRGGBB) as a colour; null for anything else.
  static Rgb? rgb(String hex) {
    final digits = hex.startsWith('#') ? hex.substring(1) : hex;
    if (digits.length != 6) return null;
    final value = int.tryParse(digits, radix: 16);
    if (value == null || value < 0) return null;
    return (r: ((value >> 16) & 0xFF) / 255, g: ((value >> 8) & 0xFF) / 255, b: (value & 0xFF) / 255);
  }

  static String hex(Rgb color) {
    String byte(double value) => (value.clamp(0.0, 1.0) * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${byte(color.r)}${byte(color.g)}${byte(color.b)}'.toUpperCase();
  }

  /// A colour from hue (0-360), saturation and brightness (0-1).
  static Rgb hsb(double hue, double saturation, double brightness) {
    final h = ((hue % 360) + 360) % 360 / 60;
    final c = brightness * saturation;
    final x = c * (1 - ((h % 2) - 1).abs());
    final m = brightness - c;
    final (r, g, b) = switch (h.toInt()) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    return (r: r + m, g: g + m, b: b + m);
  }
}

/// The Theme Studio's knobs (the macOS launcher's ThemeKnobs.swift): the background's hue, how
/// far its highlight turns from it, how light it is, and the accent's hue. They make the four
/// colours, and are read back from any theme's colours, so an installed theme can be changed
/// with them too.
class ThemeKnobs {
  const ThemeKnobs({required this.hue, required this.highlight, required this.depth, required this.accentHue});

  factory ThemeKnobs.of(ThemeDesign design) {
    final middle = _hsb(design.middleRgb), bright = _hsb(design.brightRgb), accent = _hsb(design.accentRgb);
    var turn = bright.hue - middle.hue;
    if (turn > 180) turn -= 360;
    if (turn < -180) turn += 360;
    return ThemeKnobs(
      hue: middle.hue.roundToDouble(),
      highlight: turn.roundToDouble().clamp(-90, 90),
      depth: ((middle.brightness - 0.15) / 0.05).round().clamp(1, 10),
      accentHue: accent.hue.roundToDouble(),
    );
  }

  /// Degrees, 0 to 355.
  final double hue;

  /// Degrees the bright tone turns from the hue, -90 to 90.
  final double highlight;

  /// 1 (dark) to 10 (light).
  final int depth;
  final double accentHue;

  ThemeKnobs copyWith({double? hue, double? highlight, int? depth, double? accentHue}) => ThemeKnobs(
    hue: hue ?? this.hue,
    highlight: highlight ?? this.highlight,
    depth: depth ?? this.depth,
    accentHue: accentHue ?? this.accentHue,
  );

  /// [design] with the four colours these knobs make.
  ThemeDesign applyTo(ThemeDesign design) {
    final level = depth.clamp(1, 10).toDouble();
    return design.copyWith(
      deep: ThemeDesign.hex(ThemeDesign.hsb(hue, 0.85, 0.05 + level * 0.008)),
      middle: ThemeDesign.hex(ThemeDesign.hsb(hue, 0.80, 0.15 + level * 0.05)),
      bright: ThemeDesign.hex(ThemeDesign.hsb(hue + highlight, 0.55, 1)),
      accent: ThemeDesign.hex(ThemeDesign.hsb(accentHue, 0.68, 1)),
    );
  }

  static ({double hue, double saturation, double brightness}) _hsb(Rgb color) {
    final (r, g, b) = (color.r, color.g, color.b);
    final high = math.max(r, math.max(g, b)), low = math.min(r, math.min(g, b)), range = high - low;
    var hue = 0.0;
    if (range > 0) {
      if (high == r) {
        hue = 60 * (((g - b) / range).remainder(6));
      } else if (high == g) {
        hue = 60 * ((b - r) / range + 2);
      } else {
        hue = 60 * ((r - g) / range + 4);
      }
    }
    if (hue < 0) hue += 360;
    return (hue: hue, saturation: high == 0 ? 0 : range / high, brightness: high);
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeKnobs &&
      other.hue == hue &&
      other.highlight == highlight &&
      other.depth == depth &&
      other.accentHue == accentHue;

  @override
  int get hashCode => Object.hash(hue, highlight, depth, accentHue);
}
