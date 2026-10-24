import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

class SaveBackupFailure implements Exception {
  SaveBackupFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A game's saves and trophies as one zip: the save data (_sd), the save memory (_sd_mem) and
/// the earned trophies (_trophy) from its installed folder, and nothing else. The Dart form of
/// the macOS launcher's SaveBackup.swift; the zips are the same layout, so a backup moves
/// between the two.
abstract final class SaveBackup {
  static const parts = ['_sd', '_sd_mem', '_trophy'];

  /// Where a game's backups go: one folder per game.
  static String folderFor(String backups, String name, String titleId) =>
      p.join(backups, '${name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '-')} ($titleId)');

  /// Zips the saves of the installed game in [game] into [folder], named after [date].
  static String backUp(String game, String folder, DateTime date) {
    final present = parts.where((part) => Directory(p.join(game, part)).existsSync()).toList();
    if (present.isEmpty) throw SaveBackupFailure('the game has no saves yet');
    Directory(folder).createSync(recursive: true);
    String two(int value) => value.toString().padLeft(2, '0');
    final name =
        '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}.${two(date.minute)}.${two(date.second)}';
    var zip = p.join(folder, '$name.zip');
    var copy = 2;
    while (File(zip).existsSync()) {
      zip = p.join(folder, '$name $copy.zip');
      copy++;
    }
    final archive = Archive();
    for (final part in present) {
      final base = Directory(p.join(game, part)).resolveSymbolicLinksSync();
      for (final entity in Directory(base).listSync(recursive: true, followLinks: true)) {
        if (entity is! File) continue;
        final relative = p.posix.joinAll([part, ...p.split(p.relative(entity.path, from: base))]);
        final bytes = entity.readAsBytesSync();
        archive.addFile(ArchiveFile.bytes(relative, bytes));
      }
      // An empty folder is kept as one.
      if (Directory(base).listSync().isEmpty) archive.addFile(ArchiveFile.directory('$part/'));
    }
    final temporary = '$zip.partial';
    File(temporary).writeAsBytesSync(ZipEncoder().encode(archive));
    File(temporary).renameSync(zip);
    return zip;
  }

  /// The game's backups, newest first.
  static List<String> backups(String folder) {
    final List<File> files;
    try {
      files = Directory(folder).listSync().whereType<File>().where((file) => file.path.endsWith('.zip')).toList();
    } on FileSystemException {
      return const [];
    }
    files.sort((a, b) {
      final byDate = b.lastModifiedSync().compareTo(a.lastModifiedSync());
      return byDate != 0 ? byDate : p.basename(b.path).compareTo(p.basename(a.path));
    });
    return [for (final file in files) file.path];
  }

  /// The files a backup holds, relative to the game folder.
  static List<String> contents(String backup) => [
    for (final file in _open(backup).files)
      if (file.isFile) file.name,
  ];

  /// The zip in [backup]; anything else is not a backup.
  static Archive _open(String backup) {
    try {
      final bytes = File(backup).readAsBytesSync();
      final zip = bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && (bytes[2] == 3 || bytes[2] == 5);
      if (!zip) throw SaveBackupFailure('not a backup');
      return ZipDecoder().decodeBytes(bytes);
    } on SaveBackupFailure {
      rethrow;
    } on Object {
      throw SaveBackupFailure('not a backup');
    }
  }

  /// Puts the backup's saves in place of the game's. What the game had is backed up into
  /// [keepingIn] first, so a restore never loses anything.
  static void restore(String backup, String game, String keepingIn, DateTime date) {
    final archive = _open(backup);
    final restored = parts.where((part) => archive.files.any((file) => file.name.startsWith('$part/'))).toList();
    if (restored.isEmpty) throw SaveBackupFailure('the file holds no saves');
    if (parts.any((part) => Directory(p.join(game, part)).existsSync())) backUp(game, keepingIn, date);
    final unpacked = Directory(p.join(game, '.anyps5-restore-${DateTime.now().microsecondsSinceEpoch}'));
    try {
      for (final file in archive.files) {
        final name = p.posix.normalize(file.name);
        if (name.startsWith('..') || p.posix.isAbsolute(name)) continue;
        final target = p.joinAll([unpacked.path, ...p.posix.split(name)]);
        if (file.isFile) {
          File(target)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(file.content);
        } else {
          Directory(target).createSync(recursive: true);
        }
      }
      for (final part in restored) {
        final target = Directory(p.join(game, part));
        if (target.existsSync()) target.deleteSync(recursive: true);
        Directory(p.join(unpacked.path, part)).renameSync(target.path);
      }
    } finally {
      if (unpacked.existsSync()) unpacked.deleteSync(recursive: true);
    }
  }
}
