import 'package:flutter/services.dart';

import '../core/desktop/launcher_window.dart';

/// The launcher's window through the runner's "anyps5/window" channel (windows/runner/
/// flutter_window.cpp, linux/runner/my_application.cc).
class ChannelLauncherWindow implements LauncherWindow {
  const ChannelLauncherWindow();

  static const _channel = MethodChannel('anyps5/window');

  @override
  Future<bool> setFullscreen(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setFullscreen', on) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
