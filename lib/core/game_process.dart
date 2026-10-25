import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';

/// A game the launcher started, with its output going to its log file.
class RunningGame {
  RunningGame._(this.process, this.exitCode, this.started);

  final Process process;

  /// Completes with the game's exit code once it ended and its log is written.
  final Future<int> exitCode;
  final DateTime started;

  int get pid => process.pid;

  /// Asks the game to end (SIGTERM on Linux, TerminateProcess on Windows).
  bool stop() => process.kill();

  /// Asks the game to close as closing its window would, so it can save first: SIGTERM on
  /// Linux, taskkill without /F on Windows (which sends its windows WM_CLOSE).
  Future<void> close() async {
    if (!Platform.isWindows) {
      process.kill(ProcessSignal.sigterm);
      return;
    }
    try {
      await Process.run('taskkill', ['/PID', '$pid', '/T']);
    } on ProcessException {
      // The kill after the grace period still ends it.
    }
  }

  /// Ends the game at once (SIGKILL, TerminateProcess).
  bool kill() => process.kill(ProcessSignal.sigkill);
}

/// Starts installed games.
abstract final class GameProcess {
  /// Starts the installed game in [installed] with its folder as the working directory (AnyPS5
  /// maps /app0 under it) and [environment] on top of the launcher's; its output is appended to
  /// [logFile].
  static Future<RunningGame> start({
    required String installed,
    required Map<String, String> environment,
    required String logFile,
    HostSystem? system,
    List<String> arguments = const [],
    DateTime Function()? clock,
  }) async {
    final host = system ?? HostSystem.current;
    final executable = p.join(installed, host.executableName);
    if (!File(executable).existsSync()) {
      throw ProcessException(executable, arguments, 'the game is not installed', 2);
    }
    Directory(p.dirname(logFile)).createSync(recursive: true);
    final log = File(logFile).openWrite(mode: FileMode.append);
    final started = (clock ?? DateTime.now)();
    log.writeln('--- ${started.toIso8601String()} ${p.basename(installed)}');
    final process = await Process.start(executable, arguments, workingDirectory: installed, environment: environment);
    final done = Completer<int>();
    final out = process.stdout.listen(log.add).asFuture<void>();
    final err = process.stderr.listen(log.add).asFuture<void>();
    unawaited(() async {
      final code = await process.exitCode;
      await Future.wait([out, err])
          .timeout(const Duration(seconds: 5), onTimeout: () => const [])
          .catchError((_) => <void>[]);
      log.writeln('--- exit $code');
      await log.flush();
      await log.close();
      done.complete(code);
    }());
    return RunningGame._(process, done.future, started);
  }
}
