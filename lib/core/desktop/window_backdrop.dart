/// What the system can put behind a see-through launcher window (the Glass look): the desktop
/// and the windows behind it, blurred where the system blurs.
enum BackdropKind {
  /// Windows 11 22H2 and later: DWM's Acrylic system backdrop (DWMWA_SYSTEMBACKDROP_TYPE).
  acrylic,

  /// Windows 10 1803 and later, and Windows 11 before 22H2: the accent policy's acrylic blur
  /// behind the window (SetWindowCompositionAttribute).
  accentAcrylic,

  /// KDE Plasma on X11: KWin blurs behind a window that asks (_KDE_NET_WM_BLUR_BEHIND_REGION).
  kwinBlur,

  /// A compositor that shows what is behind a window but does not blur it (GNOME, Wayland, other
  /// X11 compositors): more tint keeps the text readable over the sharp desktop.
  transparent,

  /// The window cannot be see-through (Windows before 10 1803, X11 with no compositor, a
  /// window without an alpha channel): Glass draws its own background, opaque.
  none;

  bool get seeThrough => this != none;
  bool get blurs => this == acrylic || this == accentAcrylic || this == kwinBlur;

  /// `ANYPS5_BACKDROP=name` picks a kind by hand (to try the Windows 10 path on Windows 11, or
  /// to turn the see-through window off); null for anything else.
  static BackdropKind? named(String? name) => switch (name?.trim().toLowerCase()) {
    'acrylic' => acrylic,
    'accent' || 'accentacrylic' => accentAcrylic,
    'kwin' || 'kwinblur' => kwinBlur,
    'transparent' => transparent,
    'none' || 'off' => none,
    _ => null,
  };
}

/// The backdrop Windows offers at [build] (the OS build number, 22621 is 11 22H2).
BackdropKind windowsBackdropKind(int build, {String? override}) {
  final chosen = BackdropKind.named(override);
  if (chosen != null && chosen != BackdropKind.kwinBlur && chosen != BackdropKind.transparent) return chosen;
  if (build >= 22621) return BackdropKind.acrylic;
  if (build >= 17134) return BackdropKind.accentAcrylic;
  return BackdropKind.none;
}

/// The backdrop a Linux desktop offers: Wayland compositors always composite, X11 needs a
/// compositing manager (_NET_WM_CM_Sn has an owner), KWin advertises its blur in _NET_SUPPORTED;
/// none of it counts unless the runner gave the window an RGBA visual.
BackdropKind linuxBackdropKind({
  required bool wayland,
  required bool x11,
  required bool rgbaVisual,
  required bool compositor,
  required bool kwinBlur,
  String? override,
}) {
  if (!rgbaVisual) return BackdropKind.none;
  final chosen = BackdropKind.named(override);
  if (chosen == BackdropKind.none || chosen == BackdropKind.transparent) return chosen!;
  if (wayland) return BackdropKind.transparent;
  if (!x11 || !compositor) return BackdropKind.none;
  return kwinBlur ? BackdropKind.kwinBlur : BackdropKind.transparent;
}

/// The launcher window's own backdrop.
abstract class WindowBackdrop {
  BackdropKind get kind;

  /// Lets the desktop through, with the system's blur where it has one, or makes the window
  /// opaque again. False while the launcher's window cannot be found (before it first shows).
  bool apply({required bool seeThrough});
}

/// A window that stays opaque (tests, other systems).
class NoBackdrop implements WindowBackdrop {
  const NoBackdrop();

  @override
  BackdropKind get kind => BackdropKind.none;

  @override
  bool apply({required bool seeThrough}) => true;
}
