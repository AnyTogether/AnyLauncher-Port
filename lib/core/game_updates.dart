import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'game_addons.dart';
import 'game_archives.dart' show UnpackCancel, UnpackCancelled;
import 'game_library.dart';

/// Why a folder cannot be a game's update.
enum UpdateProblem {
  /// No eboot.bin and sce_sys/param.json in it.
  notADump,

  /// The dump of another title.
  otherGame,

  /// The game's own folder, or a dump no newer than the game.
  notNewer,

  /// The game has an update of this version or a newer one already.
  haveNewer,

  /// The game has an older update: its folder has to go first.
  haveOlder,
}

/// A dump of a game's update (its patch package), checked to be newer than the game.
class UpdateCandidate {
  const UpdateCandidate({required this.folder, required this.titleId, required this.version});

  final String folder;
  final String titleId;

  /// param.json's contentVersion, such as 01.005.000.
  final String version;

  String get shortVersion => GameAddons.shortVersion(version);
}

/// A game's update added from a dump the player has: put beside the game as
/// `<game folder>-UPDATE`, the layout [GameAddons.look] reads, so the next unlock applies it and
/// the game's own folder is never written to.
abstract final class GameUpdates {
  /// Where [game]'s update goes: beside it, named as its folder with -UPDATE.
  static String target(Game game) => p.join(p.dirname(game.folder), '${p.basename(game.folder)}-UPDATE');

  /// -1, 0 or 1 as version [a] is older, the same or newer than [b] (01.004.000 against
  /// 01.010.000: number by number).
  static int compareVersions(String a, String b) {
    List<int> numbers(String version) => [
      for (final part in version.split(RegExp(r'[^0-9]+')))
        if (part.isNotEmpty) int.parse(part),
    ];
    final left = numbers(a);
    final right = numbers(b);
    for (var index = 0; index < left.length || index < right.length; index++) {
      final x = index < left.length ? left[index] : 0;
      final y = index < right.length ? right[index] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    return 0;
  }

  /// Whether the dump of title [titleId] at [version] would be [game]'s update.
  static UpdateProblem? problemWith(Game game, {required String titleId, required String version}) {
    if (titleId.toUpperCase() != game.titleId.toUpperCase()) return UpdateProblem.otherGame;
    if (compareVersions(version, game.version) <= 0) return UpdateProblem.notNewer;
    final existing = game.update;
    if (existing != null) {
      return compareVersions(version, existing.version) <= 0 ? UpdateProblem.haveNewer : UpdateProblem.haveOlder;
    }
    if (FileSystemEntity.typeSync(target(game)) != FileSystemEntityType.notFound) return UpdateProblem.haveOlder;
    return null;
  }

  /// The update in [folder] for [game], or why it is not one.
  static ({UpdateCandidate? update, UpdateProblem? problem}) check(String folder, Game game) {
    if (p.equals(folder, game.folder) || p.isWithin(folder, game.folder) || p.isWithin(game.folder, folder)) {
      return (update: null, problem: UpdateProblem.notNewer);
    }
    final parameters = GameAddons.parameters(folder);
    if (parameters == null || !File(p.join(folder, 'eboot.bin')).existsSync()) {
      return (update: null, problem: UpdateProblem.notADump);
    }
    final titleId = parameters['titleId'];
    final version = parameters['contentVersion'];
    if (titleId is! String || version is! String) return (update: null, problem: UpdateProblem.notADump);
    final problem = problemWith(game, titleId: titleId, version: version);
    if (problem != null) return (update: null, problem: problem);
    return (update: UpdateCandidate(folder: folder, titleId: titleId, version: version), problem: null);
  }

  /// Puts [update] beside [game]: moved when it is on the same drive (a rename), copied into a
  /// hidden folder and renamed when it is not, so a half-copied update is never read. Gives
  /// whether it was moved. [progress] hears the bytes copied and the whole.
  static Future<bool> install(
    UpdateCandidate update,
    Game game, {
    void Function(int done, int total)? progress,
    UnpackCancel? cancel,
  }) async {
    final into = target(game);
    if (FileSystemEntity.typeSync(into) != FileSystemEntityType.notFound) {
      throw FileSystemException('The game has an update folder already', into);
    }
    try {
      Directory(update.folder).renameSync(into);
      return true;
    } on FileSystemException {
      // Another drive (or a folder in use): copied instead.
    }
    final partial = p.join(p.dirname(into), '.${p.basename(into)}.copying');
    _remove(partial);
    final port = ReceivePort();
    final listening = port.listen((message) {
      if (message case (final int done, final int total)) progress?.call(done, total);
    });
    try {
      await _copyIsolated(update.folder, partial, port.sendPort, cancel?.marker);
    } finally {
      await listening.cancel();
      port.close();
      final marker = cancel?.marker;
      if (marker != null && File(marker).existsSync()) {
        try {
          File(marker).deleteSync();
        } on FileSystemException {
          // Nothing reads it again.
        }
      }
    }
    Directory(partial).renameSync(into);
    return false;
  }

  static Future<void> _copyIsolated(String from, String into, SendPort sink, String? marker) => Isolate.run(() {
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    copySync(
      from,
      into,
      progress: (done, total) {
        final now = DateTime.now();
        if (done == total || now.difference(last) > const Duration(milliseconds: 200)) {
          last = now;
          sink.send((done, total));
        }
      },
      cancelled: marker == null ? null : () => File(marker).existsSync(),
    );
  });

  /// Copies the folder [from] to [into] (made fresh), files and folders only; [into] is removed
  /// again on a failure or [UnpackCancelled].
  static void copySync(
    String from,
    String into, {
    void Function(int done, int total)? progress,
    bool Function()? cancelled,
  }) {
    try {
      final entries = Directory(from).listSync(recursive: true, followLinks: false);
      final files = entries.whereType<File>().toList();
      final total = files.fold(0, (sum, file) => sum + file.lengthSync());
      Directory(into).createSync(recursive: true);
      for (final folder in entries.whereType<Directory>()) {
        Directory(p.join(into, p.relative(folder.path, from: from))).createSync(recursive: true);
      }
      var done = 0;
      progress?.call(0, total);
      for (final file in files) {
        final target = p.join(into, p.relative(file.path, from: from));
        Directory(p.dirname(target)).createSync(recursive: true);
        final input = file.openSync();
        final output = File(target).openSync(mode: FileMode.writeOnly);
        try {
          while (true) {
            if (cancelled?.call() ?? false) throw const UnpackCancelled();
            final chunk = input.readSync(_chunk);
            if (chunk.isEmpty) break;
            output.writeFromSync(chunk);
            done += chunk.length;
            progress?.call(done, total);
          }
        } finally {
          input.closeSync();
          output.closeSync();
        }
      }
      progress?.call(total, total);
    } on Object {
      _remove(into);
      rethrow;
    }
  }

  static const _chunk = 8 * 1024 * 1024;

  static void _remove(String folder) {
    try {
      if (Directory(folder).existsSync()) Directory(folder).deleteSync(recursive: true);
    } on FileSystemException {
      // Cleared before the next try.
    }
  }
}
