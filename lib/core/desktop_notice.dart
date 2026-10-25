import 'dart:io';

/// A notification on the desktop, over the game being played: notify-send on Linux, a toast
/// through PowerShell on Windows. Best effort: nothing is said when the system cannot show one.
abstract final class DesktopNotice {
  /// [urgent] (Linux) keeps the notice up until it is seen: for what stops the game.
  static void show(String title, String body, {bool urgent = true}) {
    final Future<Process> started;
    try {
      if (Platform.isLinux) {
        started = Process.start('notify-send', [
          '--app-name=AnyPS5',
          '--urgency=${urgent ? 'critical' : 'normal'}',
          title,
          body,
        ]);
      } else if (Platform.isWindows) {
        // The texts go in the environment, not the script, so nothing in them is run.
        started = Process.start(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', _toast],
          environment: {'ANYPS5_NOTICE_TITLE': title, 'ANYPS5_NOTICE_BODY': body},
        );
      } else {
        return;
      }
    } on Object {
      return;
    }
    started.then((process) => process.exitCode, onError: (Object _) => 0);
  }

  static const _toast =
      r'[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; '
      r'$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); '
      r"$x = $t.GetElementsByTagName('text'); "
      r'$x.Item(0).AppendChild($t.CreateTextNode($env:ANYPS5_NOTICE_TITLE)) > $null; '
      r'$x.Item(1).AppendChild($t.CreateTextNode($env:ANYPS5_NOTICE_BODY)) > $null; '
      r"[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new($t))";
}
