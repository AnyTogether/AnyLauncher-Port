import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'save_backup.dart';

/// Save Sync could not finish.
class SaveSyncFailure implements Exception {
  const SaveSyncFailure(this.description);
  final String description;

  @override
  String toString() => description;
}

/// What a sync did.
sealed class SyncOutcome {
  const SyncOutcome();
}

class SyncUnchanged extends SyncOutcome {
  const SyncUnchanged();
}

class SyncUploaded extends SyncOutcome {
  const SyncUploaded();
}

/// The folder's saves replaced this computer's (kept in Backups first).
class SyncDownloaded extends SyncOutcome {
  const SyncDownloaded(this.from);

  /// The computer that wrote them.
  final String from;
}

/// A game's saves and trophies kept in step through a folder other computers see too (OneDrive,
/// Dropbox, Syncthing, a shared drive, or iCloud Drive where it is set up). The folder holds the
/// latest saves as one zip with who wrote them, when, and a digest of what they hold; each
/// computer remembers the digest it last synced. A side that alone changed since then is taken;
/// where both did, the newer wins, and the other is kept: a download backs up this computer's
/// saves first, an upload keeps the replaced zip in Older. The macOS launcher's SaveSync, file for
/// file, so a Mac and a PC can share one folder.
class SaveSync {
  SaveSync({required this.game, required this.cloud, required this.backups, required this.device, this.profile});

  /// The installed game folder (its saves in _sd, _sd_mem and _trophy).
  final String game;

  /// The game's folder in the sync folder.
  final String cloud;

  /// Where this computer's saves go before a download replaces them.
  final String backups;

  /// This computer's name, as the folder says who wrote the saves.
  final String device;

  /// The launcher profile whose saves these are; null for the first one (the saves from before
  /// profiles), which keeps the folder and the record it had.
  final String? profile;

  /// The game's folder in a sync folder: `<sync>/AnyPS5/Saves/<title ID>`, or for a profile
  /// after the first `<sync>/AnyPS5/Profiles/<profile>/Saves/<title ID>`.
  static String folder(String sync, String titleId, {String? profile}) => profile == null
      ? p.join(sync, 'AnyPS5', 'Saves', titleId)
      : p.join(sync, 'AnyPS5', 'Profiles', profile, 'Saves', titleId);

  /// iCloud Drive's folder where iCloud for Windows set it up (the user's iCloudDrive folder);
  /// null elsewhere.
  static String? iCloudDrive(Map<String, String> environment, {bool windows = false}) {
    final profile = environment['USERPROFILE'];
    if (!windows || profile == null || profile.isEmpty) return null;
    final folder = p.join(profile, 'iCloudDrive');
    return Directory(folder).existsSync() ? folder : null;
  }

  String get zip => p.join(cloud, 'saves.zip');
  String get infoFile => p.join(cloud, 'info.json');
  String get older => p.join(cloud, 'Older');
  String get stateFile => p.join(p.dirname(game), profile == null ? 'anyps5-sync.json' : 'anyps5-sync-$profile.json');

  SyncOutcome sync(DateTime date) {
    final local = digest(game);
    final info = _readInfo();
    final state = _readState();
    if (local == null && info == null) return const SyncUnchanged();
    if (info == null) return _upload(date);
    if (local == null) return _download(info, date);
    if (local == info.digest) {
      _record(local);
      return const SyncUnchanged();
    }
    final localChanged = local != state;
    final cloudChanged = info.digest != state;
    if (localChanged && !cloudChanged) return _upload(date);
    if (cloudChanged && !localChanged) return _download(info, date);
    return lastChange(game).isAfter(info.date) ? _upload(date) : _download(info, date);
  }

  SyncOutcome _upload(DateTime date) {
    final made = digest(game);
    if (made == null) return const SyncUnchanged();
    Directory(cloud).createSync(recursive: true);
    final stage = Directory.systemTemp.createTempSync('AnyPS5-sync-');
    try {
      final backup = SaveBackup.backUp(game, stage.path, date);
      final current = File(zip);
      if (current.existsSync()) {
        Directory(older).createSync(recursive: true);
        final kept = File(p.join(older, '${stamp(current.lastModifiedSync())}.zip'));
        if (kept.existsSync()) kept.deleteSync();
        current.renameSync(kept.path);
        for (final extra in SaveBackup.backups(older).skip(5)) {
          try {
            File(extra).deleteSync();
          } on FileSystemException {
            // Left for the next time.
          }
        }
      }
      _move(backup, zip);
      _writeAtomically(
        infoFile,
        const JsonEncoder.withIndent('  ').convert({'date': _iso(date), 'digest': made, 'mac': device}),
      );
      _record(made);
      return const SyncUploaded();
    } finally {
      try {
        stage.deleteSync(recursive: true);
      } on FileSystemException {
        // A temporary folder the system clears.
      }
    }
  }

  SyncOutcome _download(({String device, DateTime date, String digest}) info, DateTime date) {
    if (!File(zip).existsSync()) throw const SaveSyncFailure('the sync folder has no saves.zip yet');
    SaveBackup.restore(zip, game, backups, date);
    _record(digest(game) ?? info.digest);
    return SyncDownloaded(info.device);
  }

  ({String device, DateTime date, String digest})? _readInfo() {
    final file = File(infoFile);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync());
      final date = DateTime.tryParse(json['date'] as String);
      if (date == null) throw const FormatException();
      return (device: json['mac'] as String, date: date, digest: json['digest'] as String);
    } on Object {
      throw const SaveSyncFailure("the sync folder's info.json cannot be read");
    }
  }

  String? _readState() {
    try {
      final json = jsonDecode(File(stateFile).readAsStringSync());
      return json is Map && json['digest'] is String ? json['digest'] as String : null;
    } on Object {
      return null;
    }
  }

  void _record(String digest) => _writeAtomically(stateFile, jsonEncode({'digest': digest}));

  static void _writeAtomically(String path, String text) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final temporary = File('$path.tmp')..writeAsStringSync(text, flush: true);
    temporary.renameSync(path);
  }

  /// Moves a file, copying where a rename cannot (another drive).
  static void _move(String from, String to) {
    try {
      File(from).renameSync(to);
    } on FileSystemException {
      File(from).copySync(to);
      File(from).deleteSync();
    }
  }

  /// A date as the Mac's JSONEncoder writes it (ISO 8601, whole seconds, UTC).
  static String _iso(DateTime date) {
    final utc = date.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
        'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
  }

  /// A digest of every save and trophy file, by its path and contents; null without any. The
  /// Mac's, byte for byte: for each part, each file by its path, `<part>/` then the file's path
  /// inside the part from its leading slash, then its bytes.
  static String? digest(String game) {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);
    var any = false;
    for (final part in SaveBackup.parts) {
      final String folder;
      try {
        folder = Directory(p.join(game, part)).resolveSymbolicLinksSync();
      } on FileSystemException {
        continue;
      }
      final files = <(String, File)>[];
      try {
        for (final entity in Directory(folder).listSync(recursive: true, followLinks: true)) {
          if (entity is! File) continue;
          final relative = p.split(p.relative(entity.path, from: folder)).join('/');
          files.add(('/$relative', entity));
        }
      } on FileSystemException {
        continue;
      }
      files.sort((a, b) => a.$1.compareTo(b.$1));
      for (final (relative, file) in files) {
        final List<int> bytes;
        try {
          bytes = file.readAsBytesSync();
        } on FileSystemException {
          continue;
        }
        input
          ..add(utf8.encode('$part/$relative'))
          ..add(bytes);
        any = true;
      }
    }
    input.close();
    return any ? output.value!.toString() : null;
  }

  /// When a save or trophy file last changed.
  static DateTime lastChange(String game) {
    var latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final part in SaveBackup.parts) {
      try {
        final folder = Directory(p.join(game, part)).resolveSymbolicLinksSync();
        for (final entity in Directory(folder).listSync(recursive: true, followLinks: true)) {
          final changed = entity.statSync().modified;
          if (changed.isAfter(latest)) latest = changed;
        }
      } on FileSystemException {
        continue;
      }
    }
    return latest;
  }

  static String stamp(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}.${two(date.minute)}.${two(date.second)}';
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
