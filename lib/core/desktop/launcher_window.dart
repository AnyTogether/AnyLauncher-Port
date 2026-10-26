/// The launcher's own window, as far as the launcher changes it: full screen or not (the
/// runner's "anyps5/window" channel on Windows and Linux).
abstract class LauncherWindow {
  /// Full screen ([on]) or back to the window it was; whether it could.
  Future<bool> setFullscreen(bool on);
}
