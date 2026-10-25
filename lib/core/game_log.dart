import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The game logs the launcher keeps in its logs folder: one per game, appended to by each
/// start and each unlock, kept bounded; and the output of the game's last unlock, for crash
/// reports.
abstract final class GameLog {
  /// A log past this is set aside before the next start.
  static const rollLimit = 32 << 20;

  /// A running game's log past this starts again, the earlier part kept beside it: at most
  /// twice this stays on disk while it runs.
  static const cap = 256 << 20;

  /// `<TID>.previous.log` beside `<TID>.log`: the log set aside before a start.
  static String previousFile(String file) => '${p.withoutExtension(file)}.previous.log';

  /// `<TID>.earlier.log` beside `<TID>.log`: what a running game wrote before its log started again.
  static String earlierFile(String file) => '${p.withoutExtension(file)}.earlier.log';

  /// What the last unlock of the game printed (unwrapping, relinking, patching).
  static String unlockFile(String logs, String titleId) => p.join(logs, '$titleId-unlock.log');

  /// A log grown past [limit] becomes `<TID>.previous.log` before the next start, so one log never
  /// grows without end; the one before that is dropped.
  static bool rollForStart(String file, {int limit = rollLimit}) {
    try {
      if (File(file).lengthSync() <= limit) return false;
      final previous = File(previousFile(file));
      if (previous.existsSync()) previous.deleteSync();
      File(file).renameSync(previous.path);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Keeps what the unlock printed, and the error it stopped on, for the next report.
  static void writeUnlockLog(String file, List<String> lines, {String? failure}) {
    try {
      File(file).parent.createSync(recursive: true);
      File(file).writeAsStringSync([...lines, ?failure].map((line) => '$line\n').join());
    } on FileSystemException {
      // The report goes without it.
    }
  }

  static String? read(String file) {
    try {
      return File(file).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  /// The last [bytes] of a log, as text (a character cut at the start is replaced).
  static String tail(String file, int bytes) {
    RandomAccessFile? handle;
    try {
      handle = File(file).openSync();
      final length = handle.lengthSync();
      handle.setPositionSync(length > bytes ? length - bytes : 0);
      return utf8.decode(handle.readSync(bytes), allowMalformed: true);
    } on FileSystemException {
      return '';
    } finally {
      handle?.closeSync();
    }
  }

  /// The line written before each start: `--- <time> <installed folder>`, with ` trace` at the
  /// end for a start with detailed logging.
  static String startLine(DateTime started, String folder, {bool traced = false}) =>
      '--- ${started.toIso8601String()} $folder${traced ? ' trace' : ''}';

  static final _startLines = RegExp(r'^--- \d{4}-\d{2}-\d{2}T\S+ .*$', multiLine: true);

  /// The log of the last start: from the last start line on, or the end of the log when it has
  /// none (a start that went on in a log started again).
  static String lastSession(String log) {
    final last = _startLines.allMatches(log).lastOrNull;
    if (last != null) return log.substring(last.start);
    return log.length > 64 * 1024 ? log.substring(log.length - 64 * 1024) : log;
  }

  /// Whether the start [session] begins with ran with detailed logging, as its start line says.
  static bool tracedStart(String session) {
    final newline = session.indexOf('\n');
    final first = newline < 0 ? session : session.substring(0, newline);
    return _startLines.hasMatch(first) && first.trimRight().endsWith(' trace');
  }
}

/// The log a running game's output is appended to: past [cap] it is kept as `<TID>.earlier.log`
/// and starts again, so a game that writes without end cannot fill the disk.
class CappedLog {
  CappedLog(this.path, {this.cap = GameLog.cap}) {
    File(path).parent.createSync(recursive: true);
    _open();
  }

  final String path;
  final int cap;
  late RandomAccessFile _file;
  int _size = 0;
  bool _closed = false;

  /// After a cut that failed (the file held open elsewhere on Windows), the size to try again at.
  int _retryAt = 0;

  void _open() {
    _file = File(path).openSync(mode: FileMode.append);
    _size = _file.lengthSync();
  }

  void add(List<int> bytes) {
    if (_closed) return;
    try {
      _file.writeFromSync(bytes);
      _size += bytes.length;
      if (_size > cap && _size >= _retryAt) _rotate();
    } on FileSystemException {
      // The log is a help, not a need.
    }
  }

  void writeln(String line) => add(utf8.encode('$line\n'));

  void _rotate() {
    _file.closeSync();
    final earlier = GameLog.earlierFile(path);
    try {
      if (File(earlier).existsSync()) File(earlier).deleteSync();
      File(path).renameSync(earlier);
    } on FileSystemException {
      _open();
      _retryAt = _size + (cap >> 4);
      return;
    }
    _open();
    final note =
        '[anyps5-launcher] log rotated at ${cap >> 20 > 0 ? '${cap >> 20} MiB' : '$cap bytes'}; '
        'the lines before are in ${p.basename(earlier)}\n';
    final bytes = utf8.encode(note);
    _file.writeFromSync(bytes);
    _size += bytes.length;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _file.closeSync();
    } on FileSystemException {
      // Nothing left to keep.
    }
  }
}

/// Detailed logging: the engine's most talkative runtime switches that are safe to leave on
/// for a whole session, as upstream's Windows and Linux builds read them (docs/dev/TRACING.md,
/// docs/dev/ENVIRONMENT.md). The engine has no single log level: its debug lines are compiled
/// out unless it is built with APS5_DEBUG_LOG.
abstract final class TraceMode {
  static const environment = <String, String>{
    // Every line written as it comes, none coalesced and none lost in the queue at a crash.
    'APS5_LOG_SYNC': '1',
    'APS5_LOG_TIMESTAMPS': '1',
    // Who called exit() or _Exit() and with which status, and the process-exit backtrace.
    'APS5_TRACE_EXIT': '1',
    // The code that checked a guest address it could not read, before it stops on it.
    'APS5_TRACE_UNREADABLE': '1',
    // The game's direct memory maps, unmaps and protections.
    'APS5_TRACE_MEMORY': '1',
    // Every save data call instead of the first three.
    'APS5_SAVEDATA_TRACE': '1',
    // The Windows crash report adds the memory each register's pointers point at.
    'APS5_CRASH_INDIRECT_MEMORY': '1',
    // The last system library calls in a crash or abort report; recorded only by an executable
    // relinked with --trace-imports, ignored by the others.
    'APS5_TRACE_CALLS': 'all',
    // Presented frames every ten seconds (AnyPS5-ARM's engine; upstream's ignores it).
    'APS5_PROFILE_PRESENT': '1',
  };
}
