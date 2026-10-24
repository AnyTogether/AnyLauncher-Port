import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core/host.dart';
import 'ui/app_model.dart';
import 'ui/launcher.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
    ),
  );
  if (model.preferences.onboarded) model.rescan();
  model.watchGamesFolder();
  unawaited(model.startPhoneServer());
  unawaited(model.together.start());
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
