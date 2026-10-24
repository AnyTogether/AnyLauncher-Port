import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'binary.dart';
import 'self_unwrap.dart';

/// What a dump's eboot.bin is.
enum ExecutableKind {
  /// A plain ELF (an unwrapped dump).
  elf,

  /// A SELF container, or a re-signed one with its ELF kept as eboot.bin.esbak.
  container,

  /// Neither: an encrypted or unknown file.
  unreadable,
}

/// A PS5 game dump found in the games folder: a folder with sce_sys/param.json and an eboot.bin.
class Game {
  Game({
    required this.folder,
    required this.titleId,
    required this.name,
    required this.names,
    required this.defaultLanguage,
    required this.version,
    required this.executable,
    this.icon,
    this.background,
    this.music,
  });

  /// The dump's folder, as the scan found it.
  final String folder;
  final String titleId;

  /// The name in the dump's default language.
  final String name;

  /// Every language's name, by locale tag (en-US, tr-TR...).
  final Map<String, String> names;
  final String defaultLanguage;
  final String version;
  final ExecutableKind executable;

  /// sce_sys/icon0.png, pic0.png and snd0.at9 when the dump has them.
  final String? icon;
  final String? background;
  final String? music;

  String get id => folder;

  /// The name in the first of [languages] the dump has (a tag such as tr-TR, or just tr),
  /// else the default name.
  String nameFor(List<String> languages) {
    for (final language in languages) {
      final exact = names[language];
      if (exact != null && exact.isNotEmpty) return exact;
      final prefix = language.split('-').first.toLowerCase();
      for (final entry in names.entries) {
        if (entry.key.split('-').first.toLowerCase() == prefix && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
    }
    return name;
  }

  /// The title ID as a file name and identifier part: letters and digits only, lower case.
  String get slug => titleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  @override
  bool operator ==(Object other) => other is Game && other.folder == folder;

  @override
  int get hashCode => folder.hashCode;

  @override
  String toString() => 'Game($titleId, $name, $folder)';
}

abstract final class GameLibrary {
  /// Where the launcher keeps what it makes inside the games folder.
  static const storeName = '.AnyPS5';
  static const _skipped = {storeName, 'sce_sys', 'sce_module', 'sce_modules', 'prx', 'out', 'rel'};

  /// Finds every game folder under [root], down to three levels, sorted by name.
  static List<Game> scan(String root) {
    final found = <Game>[];
    _visit(root, 0, found);
    found.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.folder.compareTo(b.folder);
    });
    return found;
  }

  static void _visit(String folder, int depth, List<Game> found) {
    final game = inspect(folder);
    if (game != null) {
      found.add(game);
      return;
    }
    if (depth >= 3) return;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: true);
    } on FileSystemException {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.') || _skipped.contains(name)) continue;
      if (entry is Directory) _visit(entry.path, depth + 1, found);
    }
  }

  /// The game in [folder], or null when it is not a dump.
  static Game? inspect(String folder) {
    final system = p.join(folder, 'sce_sys');
    final eboot = p.join(folder, 'eboot.bin');
    if (!File(eboot).existsSync()) return null;
    final Map<String, dynamic> parameters;
    try {
      final decoded = jsonDecode(_text(File(p.join(system, 'param.json')).readAsBytesSync()));
      if (decoded is! Map<String, dynamic>) return null;
      parameters = decoded;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    final titleId = _string(parameters['titleId']) ?? p.basename(folder);
    final localized = parameters['localizedParameters'] is Map<String, dynamic>
        ? parameters['localizedParameters'] as Map<String, dynamic>
        : <String, dynamic>{};
    final language =
        _string(localized['defaultLanguage']) ?? _string(parameters['defaultLanguage']) ?? 'en-US';
    final names = <String, String>{};
    for (final entry in localized.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        final title = _string(value['titleName']);
        if (title != null) names[entry.key] = title;
      }
    }
    final name = names[language] ?? names['en-US'] ?? titleId;
    final version = _string(parameters['contentVersion']) ?? '1.0';
    String? existing(String name) {
      final path = p.join(system, name);
      return File(path).existsSync() ? path : null;
    }

    final ExecutableKind executable;
    if (Binary.isElf(eboot)) {
      executable = ExecutableKind.elf;
    } else if (SelfUnwrap.isContainer(eboot) || Binary.isElf('$eboot.esbak')) {
      executable = ExecutableKind.container;
    } else {
      executable = ExecutableKind.unreadable;
    }
    return Game(
      folder: folder,
      titleId: titleId,
      name: name,
      names: names,
      defaultLanguage: language,
      version: version,
      executable: executable,
      icon: existing('icon0.png'),
      background: existing('pic0.png'),
      music: existing('snd0.at9'),
    );
  }

  /// The total size of the files in a folder, in bytes.
  static int size(String folder) {
    var total = 0;
    try {
      for (final entity in Directory(folder).listSync(recursive: true, followLinks: false)) {
        if (entity is File) total += entity.lengthSync();
      }
    } on FileSystemException {
      // What could be read counts.
    }
    return total;
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

  /// UTF-8 text without a byte order mark.
  static String _text(List<int> bytes) {
    final start = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
    return utf8.decode(bytes.sublist(start), allowMalformed: true);
  }
}
