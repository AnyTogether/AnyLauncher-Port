import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

import 'strings.dart';

/// The three built-in looks: an animated background (shaders/background.frag) with the colors
/// the interface draws over it.
enum LookStyle {
  cosmic(Color.fromRGBO(3, 6, 23, 1), Color.fromRGBO(10, 38, 107, 1), Color.fromRGBO(107, 163, 255, 1), Accent.blue),
  aurora(Color.fromRGBO(2, 8, 11, 1), Color.fromRGBO(5, 77, 77, 1), Color.fromRGBO(143, 255, 199, 1), Accent.mint),
  sunset(Color.fromRGBO(15, 3, 10, 1), Color.fromRGBO(133, 28, 56, 1), Color.fromRGBO(255, 163, 84, 1), Accent.coral);

  const LookStyle(this.deep, this.middle, this.bright, this.defaultAccent);

  /// Deep, middle and bright tones the shader blends.
  final Color deep;
  final Color middle;
  final Color bright;
  final Accent defaultAccent;

  String get title => T.text(switch (this) {
    LookStyle.cosmic => 'themeCosmic',
    LookStyle.aurora => 'themeAurora',
    LookStyle.sunset => 'themeSunset',
  });

  /// The theme's colors as #RRGGBB, for the phone to wear.
  static String hex(Color color) =>
      '#${[color.r, color.g, color.b].map((c) => (c * 255).round().toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
}

enum Accent {
  blue(Color.fromRGBO(79, 148, 255, 1)),
  mint(Color.fromRGBO(92, 235, 189, 1)),
  coral(Color.fromRGBO(255, 128, 102, 1)),
  violet(Color.fromRGBO(168, 133, 255, 1)),
  gold(Color.fromRGBO(255, 204, 92, 1)),
  white(Color.fromRGBO(240, 240, 240, 1));

  const Accent(this.color);
  final Color color;

  String get title {
    final turkish = T.language == Language.turkish;
    return switch (this) {
      Accent.blue => turkish ? 'Mavi' : 'Blue',
      Accent.mint => turkish ? 'Nane' : 'Mint',
      Accent.coral => turkish ? 'Mercan' : 'Coral',
      Accent.violet => turkish ? 'Mor' : 'Violet',
      Accent.gold => turkish ? 'Altın' : 'Gold',
      Accent.white => turkish ? 'Beyaz' : 'White',
    };
  }
}

/// Timings used across the interface: quick to respond, no wobble on small moves. The springs
/// of the macOS launcher, as curves.
abstract final class Motion {
  static bool reduced = false;

  static Duration get focus => Duration(milliseconds: reduced ? 120 : 260);
  static Duration get layout => Duration(milliseconds: reduced ? 150 : 380);
  static Duration get fade => Duration(milliseconds: reduced ? 150 : 550);
  static Duration get overlay => Duration(milliseconds: reduced ? 150 : 340);

  /// A strong ease-out: starts fast, settles softly.
  static const Curve settle = Cubic(0.22, 1, 0.36, 1);
  static const Curve inOut = Cubic(0.65, 0, 0.35, 1);
}

/// Text styles: Figtree, white over the background.
abstract final class AppText {
  static const family = 'Figtree';

  static TextStyle display(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: weight,
        color: color ?? const Color(0xFFFFFFFF),
        height: height,
        letterSpacing: size >= 40 ? -0.02 * size : (size <= 13 ? 0.1 : 0),
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

/// Colors that mean something everywhere.
abstract final class Palette {
  static const warning = Color.fromRGBO(255, 209, 102, 1);
  static const danger = Color.fromRGBO(255, 153, 140, 1);
  static const success = Color.fromRGBO(77, 217, 115, 1);
  static const connecting = Color.fromRGBO(255, 158, 51, 1);
}

/// The PlayStation face buttons.
enum PadGlyph { cross, circle, square, triangle }
