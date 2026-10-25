import 'dart:io';

import '../gamepad/linux_pads.dart';
import '../gamepad/pad_navigation.dart';
import '../gamepad/windows_pads.dart';
import '../steam/steam_launch.dart';
import 'sdl_pads.dart';

/// Picks the launcher's controller reader: SDL2 when it loads (shipped beside the launcher on
/// Windows, the system's on Linux), else the older readers (XInput and winmm, evdev). What
/// happened is kept for the troubleshooter and the log.
abstract final class PadReader {
  /// Why SDL2 was not used; null when it is (or nothing was tried yet).
  static String? sdlFailure;

  /// DS4Windows or DualSenseX runs (the troubleshooter's last look): their virtual Xbox pad is
  /// then left out while the real PlayStation pad is read.
  static bool remapperRunning = false;

  /// The reader for this launch; [arguments] and [environment] tell a launch from Steam.
  static PadSource open({required List<String> arguments, Map<String, String>? environment}) {
    final steam = SteamLaunch.detect(arguments, environment ?? Platform.environment);
    final sdl = SdlLibrary.load(failure: (why) => sdlFailure = why);
    if (sdl != null) {
      sdlFailure = null;
      return SdlPadSource(
        sdl,
        steam: steam.fromSteam,
        steamTookOver: steam.skipPhysicalPad,
        remapperRunning: () => remapperRunning,
        platformDriver: Platform.isWindows ? 'SDL DirectInput' : 'SDL evdev',
      );
    }
    return Platform.isWindows ? WindowsPadSource(steam: steam.fromSteam) : LinuxPadSource();
  }
}
