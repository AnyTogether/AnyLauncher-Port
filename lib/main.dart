import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/soloud_audio.dart';
import 'core/desktop/linux_desktop.dart';
import 'core/desktop/windows_desktop.dart';
import 'core/gamepad/linux_pads.dart';
import 'core/gamepad/windows_pads.dart';
import 'core/app_update.dart';
import 'core/host.dart';
import 'core/release_signing.dart';
import 'core/toolkit_download.dart';
import 'ui/app_model.dart';
import 'ui/crash_model.dart';
import 'ui/launcher.dart';
import 'ui/theme.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final options = LaunchOptions.parse(arguments);
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
      pads: () => Platform.isWindows ? WindowsPadSource() : LinuxPadSource(),
      desktop: Platform.isWindows ? WindowsDesktop() : LinuxDesktop(),
    ),
  );
  model.crash.traceAll = options.trace;
  unawaited(model.startAudio());
  model.startPads();
  if (model.preferences.onboarded) model.rescan();
  model.watchGamesFolder();
  unawaited(model.startPhoneServer());
  unawaited(model.together.start());
  unawaited(model.engine.startupCheck());
  unawaited(model.updates.startupCheck());
  runApp(AnyPS5App(model: model));
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
        scaffoldBackgroundColor: Colors.black,
        splashFactory: NoSplash.splashFactory,
      ),
      home: Scaffold(
        body: LauncherShell(model: model, time: time, now: now),
      ),
    );
  }
}
