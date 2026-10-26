import 'dart:io';

import 'package:path/path.dart' as p;

import '../save_backup.dart';

/// Each profile's saves and trophies for a game, the macOS launcher's ProfileSaves rule for
/// rule (the same mark file and parking folder, so a game folder means the same to both). The
/// engine reads and writes them in the installed game's folder (_sd, _sd_mem, _trophy, one
/// engine user for everyone); the launcher keeps the playing profile's there and every other
/// profile's parked in `_profiles/<id>`, and swaps them with renames before the profile plays.
/// A folder without a mark holds the saves from before profiles: the first profile's.
///
/// A swap cut short is put right by the next one: the in-place parts are parked under their
/// owner first, then the mark changes, then the profile's parts come back.
abstract final class ProfileSaves {
  static const parts = SaveBackup.parts;
  static const markName = '.anyps5-profile';
  static const parkName = '_profiles';

  static String owner(String game, {required String legacyOwner}) {
    try {
      final mark = File(p.join(game, markName)).readAsStringSync().trim();
      return mark.isEmpty ? legacyOwner : mark;
    } on FileSystemException {
      return legacyOwner;
    }
  }

  /// Where a profile's saves wait while another plays.
  static String parked(String profile, String game) => p.join(game, parkName, profile);

  static bool _exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

  /// Puts [profile]'s saves in the game folder, parking the ones there now under their owner.
  static void activate(String profile, String game, {required String legacyOwner}) {
    if (!Directory(game).existsSync()) return;
    final current = owner(game, legacyOwner: legacyOwner);
    if (current != profile) {
      _park(current, game);
      _mark(game, profile);
    } else if (!File(p.join(game, markName)).existsSync()) {
      _mark(game, profile);
    }
    final place = parked(profile, game);
    for (final part in parts) {
      final from = p.join(place, part);
      if (!_exists(from)) continue;
      final target = p.join(game, part);
      // Something of the profile's own already in place: it stays, the parked copy goes aside.
      if (_exists(target)) {
        _rename(from, _aside(from));
        continue;
      }
      _rename(from, target);
    }
    _removeIfEmpty(place);
    _removeIfEmpty(p.join(game, parkName));
  }

  /// Deletes a profile's saves for the game, in place or parked (back them up first).
  static void remove(String profile, String game, {required String legacyOwner}) {
    if (owner(game, legacyOwner: legacyOwner) == profile) _park(profile, game);
    final place = Directory(parked(profile, game));
    if (place.existsSync()) place.deleteSync(recursive: true);
    _removeIfEmpty(p.join(game, parkName));
  }

  static void _park(String profile, String game) {
    final present = parts.where((part) => _exists(p.join(game, part))).toList();
    if (present.isEmpty) return;
    final place = parked(profile, game);
    Directory(place).createSync(recursive: true);
    for (final part in present) {
      final target = p.join(place, part);
      if (_exists(target)) _rename(target, _aside(target));
      _rename(p.join(game, part), target);
    }
  }

  static void _mark(String game, String profile) {
    final temporary = File(p.join(game, '$markName.tmp'))..writeAsStringSync(profile);
    temporary.renameSync(p.join(game, markName));
  }

  static void _rename(String from, String to) {
    if (FileSystemEntity.isDirectorySync(from)) {
      Directory(from).renameSync(to);
    } else {
      File(from).renameSync(to);
    }
  }

  /// `_sd.<date>` beside it: never overwritten, never lost.
  static String _aside(String path) {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    var candidate = '$path.$stamp';
    var count = 1;
    while (_exists(candidate)) {
      count++;
      candidate = '$path.$stamp-$count';
    }
    return candidate;
  }

  static void _removeIfEmpty(String folder) {
    final directory = Directory(folder);
    try {
      if (directory.existsSync() && directory.listSync().isEmpty) directory.deleteSync();
    } on FileSystemException {
      // Left as it is.
    }
  }
}
