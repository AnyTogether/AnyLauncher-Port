import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'game_library.dart';

/// Which games a scan of the games folder found that the launcher had not seen before, for the
/// "New game" notice. The first scan after launch, or after [reset] (a new games folder), only
/// learns what is there. Games that go away go quietly, and are not new when they come back (a
/// drive unplugged and plugged in again); a folder renamed or moved, whose title went away in the
/// same scan, is not new either.
class LibraryTracker {
  Set<String>? _known;
  Map<String, String> _last = {};

  void reset() {
    _known = null;
    _last = {};
  }

  /// Takes a scan's games and returns the new ones, in the scan's order.
  List<Game> update(List<Game> games) {
    final current = <String, String>{for (final game in games.reversed) game.id: game.titleId};
    final known = _known;
    final gone = {
      for (final entry in _last.entries)
        if (!current.containsKey(entry.key)) entry.value,
    };
    _known = {...?known, ...current.keys};
    _last = current;
    if (known == null) return const [];
    return [
      for (final game in games)
        if (!known.contains(game.id) && !gone.contains(game.titleId)) game,
    ];
  }
}

/// How the watcher waits.
class LibraryTiming {
  const LibraryTiming({
    this.quiet = const Duration(seconds: 1),
    this.maxWait = const Duration(seconds: 4),
    this.recheck = const Duration(seconds: 3),
    this.settle = const Duration(seconds: 90),
    this.missingPoll = const Duration(seconds: 10),
  });

  /// How long the folder must stay still before the scan.
  final Duration quiet;

  /// The longest a scan waits while changes keep coming (a long copy).
  final Duration maxWait;

  /// How often a dump that is not whole is looked at again.
  final Duration recheck;

  /// How long such a dump may stay the same before it is left alone.
  final Duration settle;

  /// How often a games folder that is not there (its drive unplugged) is looked for.
  final Duration missingPoll;
}

/// Watches the games folder and what is in it, and asks for a scan a moment after things stop
/// changing there: a game copied in, in a subfolder too, shows up when its copy is far enough
/// along to be a game. A long copy is still scanned every few seconds, and a dump that is not
/// whole yet is looked at again until it is, or until it has stayed the same for a while. The
/// launcher's own store and hidden files never count, so unlocking a game does not keep
/// rescanning.
///
/// Windows and macOS watch the whole tree at once. Linux (inotify) watches each folder down to
/// the scan's depth, and each game's sce_sys, and adds the folders that appear at every scan.
/// A folder that is not there yet is looked for every few seconds.
class LibraryWatcher {
  LibraryWatcher(
    this.root, {
    required this.onScan,
    bool? recursive,
    this.timing = const LibraryTiming(),
    this.maxFolders = 4096,
  }) : recursive = recursive ?? !Platform.isLinux;

  final String root;

  /// Scans the folder and returns the folders that look like a dump still being copied.
  final List<String> Function() onScan;
  final bool recursive;
  final LibraryTiming timing;

  /// The most folders watched one by one.
  final int maxFolders;

  final Map<String, StreamSubscription<FileSystemEvent>> _watches = {};
  Timer? _pending;
  DateTime? _firstAsk;
  Timer? _missing;
  String _incompleteSignature = '';
  DateTime _incompleteSince = DateTime.now();
  bool _stopped = false;

  /// How many folders are watched (one when the whole tree is).
  int get watchedFolders => _watches.length;

  /// Starts watching; the owner scans for itself first.
  void start() {
    _stopped = false;
    _syncWatches();
  }

  /// A scan soon; several asks close together make one.
  void rescanSoon() => _request(const Duration(milliseconds: 150));

  void stop() {
    _stopped = true;
    _pending?.cancel();
    _pending = null;
    _missing?.cancel();
    _missing = null;
    for (final watch in _watches.values) {
      unawaited(watch.cancel());
    }
    _watches.clear();
  }

  /// Whether an event at [path] can change what the scan finds: anything in the folder but the
  /// launcher's store and hidden files, and the folder itself or what holds it.
  static bool matters(String path, String root) {
    var event = p.normalize(path);
    final folder = p.normalize(root);
    // macOS reports /var and /tmp as /private/var and /private/tmp.
    if (!p.isWithin(folder, event) && event.startsWith('/private/') && p.isWithin(folder, event.substring(8))) {
      event = event.substring(8);
    }
    if (p.equals(event, folder) || p.isWithin(event, folder)) return true;
    if (!p.isWithin(folder, event)) return true;
    return !p.split(p.relative(event, from: folder)).any((part) => part.startsWith('.'));
  }

  void _syncWatches() {
    if (_stopped) return;
    if (!Directory(root).existsSync()) {
      for (final watch in _watches.values) {
        unawaited(watch.cancel());
      }
      _watches.clear();
      _missing ??= Timer.periodic(timing.missingPoll, (_) {
        if (_stopped || !Directory(root).existsSync()) return;
        _missing?.cancel();
        _missing = null;
        _syncWatches();
        _request(Duration.zero);
      });
      return;
    }
    _missing?.cancel();
    _missing = null;
    final wanted = recursive ? {root} : _folders();
    for (final gone in _watches.keys.where((folder) => !wanted.contains(folder)).toList()) {
      unawaited(_watches.remove(gone)?.cancel());
    }
    for (final folder in wanted) {
      if (!_watches.containsKey(folder)) _watch(folder);
    }
  }

  void _watch(String folder) {
    try {
      late final StreamSubscription<FileSystemEvent> subscription;
      subscription = Directory(folder)
          .watch(recursive: recursive)
          .listen(
            (event) {
              if (_stopped || !matters(event.path, root)) return;
              _request(timing.quiet);
            },
            onError: (Object _) {
              if (_watches[folder] == subscription) unawaited(_watches.remove(folder)?.cancel());
              _request(timing.quiet);
            },
            onDone: () {
              if (_watches[folder] == subscription) _watches.remove(folder);
              // The folder went (deleted, moved, its drive unplugged): the scan says what is left.
              _request(timing.quiet);
            },
          );
      _watches[folder] = subscription;
    } on FileSystemException {
      // Not watchable: the scans when the launcher comes to the front still see it.
    }
  }

  /// The folders inotify watches: the games folder and what is in it down to the scan's depth,
  /// and the sce_sys of a dump at the last level.
  Set<String> _folders() {
    final wanted = <String>{};
    void walk(String folder, int depth) {
      if (wanted.length >= maxFolders) return;
      wanted.add(folder);
      List<FileSystemEntity> entries;
      try {
        entries = Directory(folder).listSync(followLinks: true);
      } on FileSystemException {
        return;
      }
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        if (depth < 3) {
          walk(entry.path, depth + 1);
        } else if (name == 'sce_sys' && wanted.length < maxFolders) {
          wanted.add(entry.path);
        }
      }
    }

    walk(root, 0);
    return wanted;
  }

  /// A scan [delay] from now, but never later than `maxWait` after the first unanswered ask.
  void _request(Duration delay) {
    if (_stopped) return;
    final now = DateTime.now();
    final first = _firstAsk ??= now;
    var deadline = now.add(delay);
    final cap = first.add(timing.maxWait);
    if (deadline.isAfter(cap)) deadline = cap;
    _pending?.cancel();
    final wait = deadline.difference(now);
    _pending = Timer(wait.isNegative ? Duration.zero : wait, _scan);
  }

  void _scan() {
    if (_stopped) return;
    _pending = null;
    _firstAsk = null;
    // The watches first: whatever is written from now on is seen, whatever was is in the scan.
    _syncWatches();
    final incomplete = onScan();
    _lookAgain(incomplete);
  }

  /// A dump still being copied is looked at again until it is a game or stops changing; the
  /// folder's own events usually get there first.
  void _lookAgain(List<String> folders) {
    if (folders.isEmpty) {
      _incompleteSignature = '';
      return;
    }
    String stamp(String path) {
      final stat = FileStat.statSync(path);
      return stat.type == FileSystemEntityType.notFound ? '-' : '${stat.size}@${stat.modified.microsecondsSinceEpoch}';
    }

    final signature = [
      for (final folder in folders)
        [
          folder,
          stamp(folder),
          stamp(p.join(folder, 'sce_sys')),
          stamp(p.join(folder, 'sce_sys', 'param.json')),
          stamp(p.join(folder, 'eboot.bin')),
        ].join('|'),
    ].join('\n');
    final now = DateTime.now();
    if (signature != _incompleteSignature) {
      _incompleteSignature = signature;
      _incompleteSince = now;
    }
    if (_pending == null && now.isBefore(_incompleteSince.add(timing.settle))) _request(timing.recheck);
  }
}
