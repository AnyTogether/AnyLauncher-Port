import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'theme_design.dart';

/// Why a theme could not be saved or installed.
class ThemeFailure implements Exception {
  const ThemeFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The themes on this computer, one folder each (theme.json and its files) under the config
/// folder's Themes: made in the Studio, or installed from a file or the Hub. The macOS
/// launcher's ThemeLibrary.swift, with the same folders and files.
class ThemeLibrary {
  ThemeLibrary(this.folder);

  /// The largest background or music file a theme may bring.
  static const largestFile = 300 * 1024 * 1024;

  final String folder;

  /// Every theme, by name.
  List<ThemeDesign> get all {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync();
    } on FileSystemException {
      return const [];
    }
    final designs = [
      for (final entry in entries)
        if (entry is Directory && !p.basename(entry.path).startsWith('.')) ?_read(p.join(entry.path, 'theme.json')),
    ];
    return designs..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  ThemeDesign? design(String id) {
    final safe = plainName(id);
    return safe == null ? null : _read(p.join(_home(safe), 'theme.json'));
  }

  /// One of a theme's files, if it has it.
  String? file(String? name, ThemeDesign design) {
    if (name == null) return null;
    final safe = plainName(name), id = plainName(design.id);
    if (safe == null || id == null) return null;
    final path = p.join(_home(id), safe);
    return File(path).existsSync() ? path : null;
  }

  /// Writes [design], with a new background or music file when given (copied in as
  /// `background.<ext>` or `music.<ext>`); files not given stay as they were.
  ThemeDesign save(ThemeDesign design, {String? background, String? music}) {
    var saved = design.copyWith(id: plainName(design.id) ?? newId());
    final home = _home(saved.id);
    try {
      Directory(home).createSync(recursive: true);
      if (background != null) {
        final name = _copy(background, 'background', home, replacing: saved.background);
        saved = saved.copyWith(background: () => name);
      }
      if (music != null) {
        final name = _copy(music, 'music', home, replacing: saved.music);
        saved = saved.copyWith(music: () => name);
      }
      final json = File(p.join(home, 'theme.json'));
      final partial = File('${json.path}.partial');
      partial.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(saved.toJson()));
      partial.renameSync(json.path);
    } on FileSystemException catch (error) {
      throw ThemeFailure('${saved.name} could not be saved: ${error.message}');
    }
    return saved;
  }

  void remove(String id) {
    final safe = plainName(id);
    if (safe == null) return;
    final home = Directory(_home(safe));
    if (home.existsSync()) home.deleteSync(recursive: true);
  }

  /// The theme as one file to share: theme.json and its files at the top of a zip, as the
  /// macOS launcher's `ditto -c -k` makes it.
  Future<void> export(ThemeDesign design, String file) async {
    final id = plainName(design.id);
    if (id == null) throw ThemeFailure('${design.name} has no folder');
    final home = _home(id);
    final partial = '$file.partial';
    final encoder = ZipFileEncoder();
    try {
      encoder.create(partial);
      await encoder.addFile(File(p.join(home, 'theme.json')), 'theme.json');
      for (final name in [design.background, design.music]) {
        final path = this.file(name, design);
        if (path != null) await encoder.addFile(File(path), p.basename(path));
      }
      await encoder.close();
      File(partial).renameSync(file);
    } on Object catch (error) {
      try {
        File(partial).deleteSync();
      } on FileSystemException {
        // Never made.
      }
      throw ThemeFailure('${design.name} could not be saved as a file: $error');
    }
  }

  /// Installs a theme file, replacing a theme with the same id. Only theme.json and the files
  /// it names come in, by plain names, and none larger than [largestFile].
  ThemeDesign install(String file) {
    final shown = p.basename(file);
    final stage = Directory(p.join(folder, '.install-${newId()}'));
    InputFileStream? input;
    try {
      try {
        input = InputFileStream(file);
      } on Object {
        throw ThemeFailure('$shown cannot be read');
      }
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } on Object {
        throw ThemeFailure('$shown is not a theme file');
      }
      // The zip may hold the folder itself or its contents: the theme.json nearest the top.
      final candidates = archive.files.where((entry) {
        final parts = p.posix.split(entry.name.replaceAll(r'\', '/'));
        return entry.isFile && parts.last == 'theme.json' && !parts.any((part) => part == '__MACOSX');
      }).toList()..sort((a, b) => a.name.split('/').length.compareTo(b.name.split('/').length));
      final json = candidates.firstOrNull;
      if (json == null || json.size > 1024 * 1024) throw ThemeFailure('$shown is not a theme file');
      ThemeDesign? read;
      try {
        read = ThemeDesign.fromJson(jsonDecode(utf8.decode(json.readBytes() ?? const [])));
      } on FormatException {
        read = null;
      }
      if (read == null) throw ThemeFailure('$shown is not a theme file');
      final base = p.posix.dirname(json.name.replaceAll(r'\', '/'));
      stage.createSync(recursive: true);
      String? take(String? name) {
        final safe = name == null ? null : plainName(name);
        if (safe == null) return null;
        final wanted = base == '.' ? safe : '$base/$safe';
        final entry = archive.files.where((entry) => entry.name.replaceAll(r'\', '/') == wanted).firstOrNull;
        if (entry == null || !entry.isFile || entry.isSymbolicLink || entry.size > largestFile) return null;
        final target = p.join(stage.path, safe);
        final output = OutputFileStream(target);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        return File(target).lengthSync() > largestFile ? null : target;
      }

      final background = take(read.background), music = take(read.music);
      final design = read.copyWith(id: plainName(read.id) ?? newId(), background: () => null, music: () => null);
      remove(design.id);
      return save(design, background: background, music: music);
    } finally {
      input?.closeSync();
      try {
        if (stage.existsSync()) stage.deleteSync(recursive: true);
      } on FileSystemException {
        // Left for the next install's tidy-up.
      }
    }
  }

  String _home(String id) => p.join(folder, id);

  ThemeDesign? _read(String json) {
    try {
      return ThemeDesign.fromJson(jsonDecode(File(json).readAsStringSync()));
    } on Object {
      return null;
    }
  }

  String _copy(String source, String stem, String home, {String? replacing}) {
    final extension = p.extension(source).toLowerCase();
    final name = '$stem$extension';
    final target = p.join(home, name);
    final old = replacing == null ? null : plainName(replacing);
    if (old != null && old != name) {
      final file = File(p.join(home, old));
      if (file.existsSync()) file.deleteSync();
    }
    if (!p.equals(p.canonicalize(source), p.canonicalize(target))) {
      if (File(source).lengthSync() > largestFile) throw ThemeFailure('${p.basename(source)} is larger than 300 MB');
      File(source).copySync(target);
    }
    return name;
  }

  /// A name with no folders in it, or null.
  static String? plainName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains(r'\') || trimmed.startsWith('.')) return null;
    if (trimmed.length > 128 || trimmed.contains(':')) return null;
    return trimmed;
  }

  static final _random = math.Random.secure();

  /// A new theme's id, a lowercase UUID as the macOS launcher makes them.
  static String newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
