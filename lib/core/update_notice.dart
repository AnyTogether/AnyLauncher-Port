/// Where the launcher's own update stands, as About shows it: never asked yet, asking, up to
/// date, a newer one (not downloaded yet, or the download failed), its download, or downloaded,
/// checked and ready. The macOS launcher's LauncherUpdateState (UpdateNotice.swift), the same
/// rules.
sealed class LauncherUpdateState {
  const LauncherUpdateState();

  /// The state from what the launcher knows: a ready update wins over a check on its way, a
  /// download over the check.
  static LauncherUpdateState of({
    required bool checking,
    String? newer,
    double? progress,
    String? ready,
    DateTime? lastCheck,
    bool failed = false,
  }) {
    if (ready != null) return UpdateReady(ready);
    if (newer != null && progress != null) return UpdateDownloading(newer, progress);
    if (checking) return const UpdateChecking();
    if (newer != null) return UpdateAvailable(newer);
    if (failed) return const UpdateCheckFailed();
    if (lastCheck != null) return UpdateCurrent(lastCheck);
    return const UpdateIdle();
  }
}

class UpdateIdle extends LauncherUpdateState {
  const UpdateIdle();
  @override
  bool operator ==(Object other) => other is UpdateIdle;
  @override
  int get hashCode => 0;
}

class UpdateChecking extends LauncherUpdateState {
  const UpdateChecking();
  @override
  bool operator ==(Object other) => other is UpdateChecking;
  @override
  int get hashCode => 1;
}

class UpdateCheckFailed extends LauncherUpdateState {
  const UpdateCheckFailed();
  @override
  bool operator ==(Object other) => other is UpdateCheckFailed;
  @override
  int get hashCode => 2;
}

class UpdateCurrent extends LauncherUpdateState {
  const UpdateCurrent(this.checked);
  final DateTime checked;
  @override
  bool operator ==(Object other) => other is UpdateCurrent && other.checked == checked;
  @override
  int get hashCode => checked.hashCode;
}

class UpdateAvailable extends LauncherUpdateState {
  const UpdateAvailable(this.version);
  final String version;
  @override
  bool operator ==(Object other) => other is UpdateAvailable && other.version == version;
  @override
  int get hashCode => version.hashCode;
}

class UpdateDownloading extends LauncherUpdateState {
  const UpdateDownloading(this.version, this.fraction);
  final String version;
  final double fraction;

  /// The download's percent, 0 to 100.
  int get percent => (fraction.clamp(0.0, 1.0) * 100).floor();

  @override
  bool operator ==(Object other) =>
      other is UpdateDownloading && other.version == version && other.fraction == fraction;
  @override
  int get hashCode => Object.hash(version, fraction);
}

class UpdateReady extends LauncherUpdateState {
  const UpdateReady(this.version);
  final String version;
  @override
  bool operator ==(Object other) => other is UpdateReady && other.version == version;
  @override
  int get hashCode => version.hashCode;
}

/// The quiet notice on the home screen once an update is ready: Restart Now, or Later (the
/// update then goes in at the next launch, and the notice does not come back for that version).
class UpdateNotice {
  final Set<String> deferred = {};

  bool shows(LauncherUpdateState state) => state is UpdateReady && !deferred.contains(state.version);

  void later(LauncherUpdateState state) {
    if (state is UpdateReady) deferred.add(state.version);
  }
}

/// Restart Now never interrupts a game: with one running, the restart waits for it to close.
enum UpdateRestart {
  now,
  afterGame;

  static UpdateRestart decide({required bool gameRunning}) => gameRunning ? afterGame : now;
}

/// How this copy of the launcher puts a downloaded update in place: Windows runs the installer
/// silently (it closes the launcher, installs and opens it again), an AppImage is swapped for
/// the new one; an archive or a package is left for the user, who is shown the file.
enum SelfApply {
  installer,
  appImage,
  manual;

  static SelfApply of({required bool windows, required bool appImage, required String file}) {
    if (windows && file.toLowerCase().endsWith('.exe')) return SelfApply.installer;
    if (!windows && appImage && file.endsWith('.AppImage')) return SelfApply.appImage;
    return SelfApply.manual;
  }

  /// The installer's switches for an update without questions, opening the launcher after it
  /// (/relaunch=1, read by the installer's [Run] entry).
  static const installerArguments = ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/relaunch=1'];
}
