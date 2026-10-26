import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/soloud_audio.dart';
import 'core/desktop/desktop.dart';
import 'core/desktop/linux_desktop.dart';
import 'core/desktop/window_backdrop.dart';
import 'core/desktop/windows_desktop.dart';
import 'core/controllers/pad_reader.dart';
import 'core/controllers/troubleshooter.dart';
import 'core/app_update.dart';
import 'core/host.dart';
import 'core/release_signing.dart';
import 'core/steam/steam_launch.dart';
import 'core/toolkit_download.dart';
import 'ui/app_model.dart';
import 'ui/crash_model.dart';
import 'ui/launcher.dart';
import 'ui/launcher_window_channel.dart';
import 'ui/theme.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final options = LaunchOptions.parse(arguments);
  final padLog = Platform.environment['ANYPS5_PAD_LOG'];
  final DesktopWindows desktop = Platform.isWindows
      ? WindowsDesktop(
          log: padLog == null || padLog.isEmpty
              ? null
              : (line) {
                  try {
                    File(padLog)
                        .writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
                  } on FileSystemException {
                    // The log is a help, never a reason to stop.
                  }
                },
        )
      : LinuxDesktop();
  final WindowBackdrop backdrop = switch (desktop) {
    final LinuxDesktop linux => LinuxBackdrop(linux),
    _ => Platform.isWindows ? WindowsBackdrop() : const NoBackdrop(),
  };
  final model = AppModel(
    paths: AppPaths.forSystem(HostSystem.current),
    services: LauncherServices(
      pickFolder: (title) => getDirectoryPath(confirmButtonText: title),
      openFolder: (folder) => unawaited(Process.run(Platform.isWindows ? 'explorer' : 'xdg-open', [folder])),
      openUrl: (url) => unawaited(
        Platform.isWindows
            ? Process.run('rundll32', ['url.dll,FileProtocolHandler', url.toString()])
            : Process.run('xdg-open', [url.toString()]),
      ),
      copyText: (text) => unawaited(Clipboard.setData(ClipboardData(text: text))),
      pickImage: () async => (await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Pictures', extensions: ['png', 'jpg', 'jpeg']),
        ],
      ))?.path,
      saveFile: (name) async => (await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Text', extensions: ['txt']),
        ],
      ))?.path,
      engineReleases: GitHubReleases(),
      launcherReleases: LauncherUpdates.source(),
      audio: SoloudAudio.new,
      armEngineReleases: GitHubReleases(
        repository: ArmToolkitPackage.repository,
        signingKeys: ReleaseSigning.trustedKeys,
      ),
      // SDL2 (beside the launcher on Windows, the system's on Linux), else XInput and winmm or evdev.
      pads: () => PadReader.open(arguments: arguments),
      systemProbe: () => HostProbe(HostSystem.current),
      desktop: desktop,
      backdrop: backdrop,
      window: const ChannelLauncherWindow(),
    ),
  );
  // An update left for this launch (Later) goes in first: its installer opens the launcher again.
  if (await model.updates.applyPendingAtLaunch()) exit(0);
  model.crash.traceAll = options.trace;
  model.steamLaunch = SteamLaunch.detect(arguments, Platform.environment);
  // Full screen the first time, then as the user left it (F11, Settings › Appearance); Steam's
  // --fullscreen and Game Mode keep the whole screen whatever the choice.
  if (!options.fullscreen && !model.steamLaunch.gameMode) unawaited(model.applyLauncherWindow());
  unawaited(model.startAudio());
  model.startPads();
  if (model.preferences.onboarded) model.rescan();
  model.watchGamesFolder();
  unawaited(model.startPhoneServer());
  // Several profiles (or Ask every time): "Who's playing?" first, the session waiting for the pick.
  model.startProfiles();
  unawaited(model.together.start());
  unawaited(model.engine.startupCheck());
  unawaited(model.updates.startupCheck());
  runApp(AnyPS5App(model: model));
  // A game's Steam shortcut: straight into the game.
  if (options.play case final String titleId when model.preferences.onboarded) {
    unawaited(model.playAtLaunch(titleId, quitAfter: model.steamLaunch.fromSteam));
  }
}

class AnyPS5App extends StatelessWidget {
  const AnyPS5App({super.key, required this.model, this.time, this.now});

  final AppModel model;
  final double? time;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AnyPS5',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: AppText.family,
        // The launcher paints its own base (LauncherShell): clear here, so Glass's see-through
        // window shows the desktop.
        scaffoldBackgroundColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: LauncherShell(model: model, time: time, now: now),
      ),
    );
  }
}
