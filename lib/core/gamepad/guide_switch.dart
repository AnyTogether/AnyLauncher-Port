/// What a press of PS/Guide does.
enum GuideAction {
  /// Bring the launcher in front (of the game, or of any other window).
  showLauncher,

  /// Bring the running game back in front, the launcher behind it.
  showGame,

  /// The launcher is in front with no game: PS closes the layer open.
  closeLayer,

  /// Nothing: no layer to close, or the press came too soon after a switch.
  none,
}

/// PS/Guide as a toggle, as on the console: with a game running it goes from the game to the
/// launcher and, pressed again, back to the game; with none it brings the launcher in front.
///
/// One press is one switch: a press within [debounce] of the last switch does nothing. Two
/// readers seeing the same press, or the window in front not yet having told everyone it changed,
/// would otherwise switch there and straight back (to the launcher, then at once to the game).
class GuideSwitch {
  GuideSwitch({this.debounce = defaultDebounce});

  static const defaultDebounce = Duration(milliseconds: 450);

  final Duration debounce;
  Duration? _lastSwitch;

  /// A press at [now] (any steady clock): what it does, given whether a game runs, whether the
  /// launcher's window is the one in front, and whether a layer is open.
  GuideAction press({
    required Duration now,
    required bool gameRunning,
    required bool launcherInFront,
    bool layerOpen = false,
  }) {
    final last = _lastSwitch;
    if (last != null && now - last < debounce && now >= last) return GuideAction.none;
    final GuideAction action;
    if (gameRunning) {
      action = launcherInFront ? GuideAction.showGame : GuideAction.showLauncher;
    } else if (!launcherInFront) {
      action = GuideAction.showLauncher;
    } else {
      action = layerOpen ? GuideAction.closeLayer : GuideAction.none;
    }
    if (action == GuideAction.showGame || action == GuideAction.showLauncher) _lastSwitch = now;
    return action;
  }
}
