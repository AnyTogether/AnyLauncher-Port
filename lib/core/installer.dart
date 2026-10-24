import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'binary.dart';
import 'file_links.dart';
import 'game_library.dart';
import 'game_settings.dart';
import 'host.dart';
import 'self_unwrap.dart';
import 'toolkit.dart';

/// What an installed game records about itself (anyps5-install.json beside its executable).
class InstallRecord {
  InstallRecord({
    required this.source,
    required this.titleId,
    required this.toolkit,
    required this.system,
    required this.date,
    this.resolution,
  });

  factory InstallRecord.fromJson(Map<String, dynamic> json) => InstallRecord(
    source: json['source'] as String,
    titleId: json['titleID'] as String,
    toolkit: json['toolkit'] as String,
    system: json['system'] as String? ?? 'linux',
    date: DateTime.parse(json['date'] as String),
    resolution: json['resolution'] as String?,
  );

  final String source;
  final String titleId;
  final String toolkit;
  final String system;
  final DateTime date;

  /// The resolution written into the executable by the title's patch file, if any.
  final String? resolution;

  Map<String, Object> toJson() => {
    'resolution': ?resolution,
    'date': date.toUtc().toIso8601String(),
    'source': source,
    'system': system,
    'titleID': titleId,
    'toolkit': toolkit,
  };
}

class InstallError implements Exception {
  InstallError(this.message);
  final String message;

  @override
  String toString() => message;
}

class InstallCancelled implements Exception {
  @override
  String toString() => 'cancelled';
}

/// The steps of an install, in order.
enum InstallStep { unwrap, relink, copy, layout, finish }

/// Unlocks a game for Windows or Linux: unwraps its executable and modules, relinks them with the
/// upstream relinker for the host, and lays the game out as upstream's runtime layout says:
///
/// ```text
/// <root>/.AnyPS5/Games/<TITLE>-<hash>/
///     app.elf | app.exe       the relinked executable
///     libs/*.prx              the toolkit's system libraries
///     app0/                   the game's files (linked to the dump) and its relinked modules
///     anyps5-install.json     the record
///     launch.sh | launch.cmd  starts the game without the launcher
/// ```
///
/// The game runs with that folder as its working directory, so what it writes (saves in _sd,
/// trophies in _trophy, data/) lands there and is carried over when the game is installed again.
class Installer {
  Installer({
    required this.game,
    required this.toolkit,
    required this.root,
    this.onProgress,
    this.onLog,
    this.linkMode,
    this.resolution,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Game game;
  final Toolkit toolkit;

  /// The games folder, which holds the store.
  final String root;
  final void Function(InstallStep step, double fraction)? onProgress;
  final void Function(String line)? onLog;

  /// How the game's files reach app0; probed on the first file when null.
  final LinkMode? linkMode;

  /// The WIDTHxHEIGHT to write through the title's resolution patch, null for the title's own.
  final String? resolution;
  final DateTime Function() _clock;

  bool _cancelled = false;
  Process? _running;

  static const recordName = 'anyps5-install.json';

  /// The installed folder of a game, inside the games folder's store. The name keeps the title
  /// ID and a hash of the dump's path, so two dumps of one title do not collide.
  static String installedFolder(Game game, String root) {
    var hash = 0xCBF29CE484222325;
    for (final byte in utf8.encode(p.normalize(p.absolute(game.folder)))) {
      hash ^= byte;
      hash *= 0x100000001B3;
    }
    final name = '${game.titleId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}-${(hash & 0xFFFFFF).toRadixString(16)}';
    return p.join(root, GameLibrary.storeName, 'Games', name);
  }

  /// The record of an installed game, null when it is not (completely) installed.
  static InstallRecord? record(String installed, {HostSystem? system}) {
    final host = system ?? HostSystem.current;
    if (!File(p.join(installed, host.executableName)).existsSync()) return null;
    try {
      final json = jsonDecode(File(p.join(installed, recordName)).readAsStringSync());
      return json is Map<String, dynamic> ? InstallRecord.fromJson(json) : null;
    } on Object {
      return null;
    }
  }

  /// The work folders and half-made games an interrupted install left in the store.
  static void removeLeftovers(String root) {
    final store = p.join(root, GameLibrary.storeName);
    _delete(p.join(store, 'Work'));
    final games = Directory(p.join(store, 'Games'));
    if (!games.existsSync()) return;
    for (final entry in games.listSync(followLinks: false)) {
      if (entry.path.endsWith('.partial')) _delete(entry.path);
    }
  }

  /// Removes an installed game and everything it wrote.
  static void uninstall(Game game, String root) => _delete(installedFolder(game, root));

  void cancel() {
    _cancelled = true;
    _running?.kill();
  }

  void _checkCancelled() {
    if (_cancelled) throw InstallCancelled();
  }

  void _log(String line) => onLog?.call(line);
  void _progress(InstallStep step, double fraction) => onProgress?.call(step, fraction.clamp(0, 1));

  /// Installs the game; returns its installed folder.
  Future<String> run() async {
    final problem = toolkit.problem;
    if (problem != null) {
      throw InstallError(switch (problem) {
        ToolkitProblem.noRelinker => 'the toolkit has no relinker at ${toolkit.relinker}',
        ToolkitProblem.noLibraries => 'the toolkit has no system libraries in ${toolkit.libraries}',
      });
    }
    final system = toolkit.system;
    final installed = installedFolder(game, root);
    final store = p.join(root, GameLibrary.storeName);
    final work = p.join(store, 'Work', '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}');
    final partial = '$installed.partial';
    try {
      // 1. The executable and every guest module as plain ELF files, in the dump's layout.
      _progress(InstallStep.unwrap, 0);
      final source = p.join(work, 'source');
      Directory(source).createSync(recursive: true);
      final found = modules(game.folder);
      final inputs = ['eboot.bin', ...found];
      for (var index = 0; index < inputs.length; index++) {
        _checkCancelled();
        final relative = inputs[index];
        final target = p.join(source, p.joinAll(relative.split('/')));
        Directory(p.dirname(target)).createSync(recursive: true);
        _unwrap(p.join(game.folder, p.joinAll(relative.split('/'))), target);
        _progress(InstallStep.unwrap, (index + 1) / inputs.length);
        await _yield();
      }

      // 2. The relinker turns them into the host's executable and guest modules.
      _progress(InstallStep.relink, 0);
      final relinked = p.join(work, 'out');
      Directory(relinked).createSync(recursive: true);
      final executable = p.join(relinked, system.executableName);
      final estimate = RelinkProgress();
      final patches = toolkit.patchFile(game.titleId);
      String? appliedResolution;
      final patchOptions = <String>[];
      if (patches != null) {
        var text = File(patches).readAsStringSync();
        final chosen = resolution;
        if (chosen != null && ResolutionPatch.supports(text) && ResolutionPatch.parse(chosen) != null) {
          text = ResolutionPatch.apply(text, chosen);
          appliedResolution = chosen;
        }
        final copy = p.join(work, 'relinker-patches.toml');
        File(copy).writeAsStringSync(text);
        patchOptions.addAll(['--patches', copy]);
        _log(
          '${game.titleId}: patches from ${p.basename(patches)}'
          '${appliedResolution == null ? '' : ', resolution $appliedResolution'}',
        );
      }
      await _runTool(
        toolkit.relinker,
        [
          ...system.relinkerOptions,
          ...patchOptions,
          for (final directory in moduleDirectories(found)) ...['--module-dir', directory],
          'eboot.bin',
          executable,
        ],
        workingDirectory: source,
        status: (segment) {
          final fraction = estimate.read(segment);
          if (fraction != null) _progress(InstallStep.relink, fraction);
        },
      );
      if (!File(executable).existsSync()) throw InstallError('relinker wrote no executable');
      _progress(InstallStep.relink, 1);

      // 3. The game's files, linked (or copied where no link works), with the relinked modules
      // copied over them.
      _checkCancelled();
      _delete(partial);
      final app0 = p.join(partial, 'app0');
      Directory(app0).createSync(recursive: true);
      await _linkTree(game.folder, app0, (fraction) => _progress(InstallStep.copy, fraction));
      final guestModules = p.join(relinked, 'app0');
      if (Directory(guestModules).existsSync()) {
        await copyTree(guestModules, app0, LinkMode.copy, isCancelled: () => _cancelled);
      }

      // 4. The executable, the libraries, the launch script and the record.
      _checkCancelled();
      _progress(InstallStep.layout, 0);
      final placed = p.join(partial, system.executableName);
      File(executable).copySync(placed);
      await _makeExecutable(placed);
      final libraries = p.join(partial, 'libs');
      Directory(libraries).createSync(recursive: true);
      final libraryFiles = toolkit.libraryFiles;
      final libraryMode = libraryFiles.isEmpty ? LinkMode.copy : FileLinks.probe(libraryFiles.first, libraries);
      for (final library in libraryFiles) {
        FileLinks.place(
          library,
          p.join(libraries, p.basename(library)),
          libraryMode == LinkMode.hard ? LinkMode.hard : LinkMode.copy,
        );
      }
      _progress(InstallStep.layout, 0.6);
      final script = p.join(partial, system.launchScriptName);
      File(script).writeAsStringSync(launchScript(system, game));
      await _makeExecutable(script);
      final record = InstallRecord(
        source: game.folder,
        titleId: game.titleId,
        toolkit: toolkit.version,
        system: system.name,
        date: _clock(),
        resolution: appliedResolution,
      );
      File(p.join(partial, recordName)).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(record.toJson()));
      _progress(InstallStep.layout, 1);

      // 5. It takes the old one's place, with what the game wrote there.
      _progress(InstallStep.finish, 0);
      placeInstalled(partial, installed);
      _progress(InstallStep.finish, 1);
      return installed;
    } finally {
      _delete(work);
      _delete(partial);
      _running = null;
    }
  }

  /// Puts a finished game in place. What the game wrote beside app0 in the old one (saves in _sd,
  /// trophies in _trophy, its data and download folders) moves into the new one.
  static void placeInstalled(String partial, String installed) {
    if (Directory(installed).existsSync()) {
      carryOver(installed, partial);
      _delete(installed);
    }
    Directory(p.dirname(installed)).createSync(recursive: true);
    Directory(partial).renameSync(installed);
  }

  /// The items of [source] the new game does not have move into [target]; links stay behind.
  static void carryOver(String source, String target) {
    for (final entry in Directory(source).listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      final destination = p.join(target, name);
      if (FileSystemEntity.typeSync(destination, followLinks: false) != FileSystemEntityType.notFound) continue;
      if (entry is Link) continue;
      entry.renameSync(destination);
    }
  }

  /// Every .prx and .sprx of the dump outside sce_sys, at most three levels down, relative to its
  /// folder with / separators, sorted.
  static List<String> modules(String folder) {
    final found = <String>[];
    void visit(String directory, List<String> parts) {
      List<FileSystemEntity> entries;
      try {
        entries = Directory(directory).listSync(followLinks: true);
      } on FileSystemException {
        return;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        final relative = [...parts, name];
        if (entry is Directory) {
          if (parts.isEmpty && name == 'sce_sys') continue;
          if (relative.length < 3) visit(entry.path, relative);
        } else if (entry is File) {
          final lower = name.toLowerCase();
          if (lower.endsWith('.prx') || lower.endsWith('.sprx')) found.add(relative.join('/'));
        }
      }
    }

    visit(folder, const []);
    found.sort();
    return found;
  }

  /// The folders besides sce_module whose modules the relinker converts too (Unity's
  /// Media/Modules and Media/Plugins, prx next to eboot.bin). fakelib holds a dump tool's
  /// stand-ins for system libraries, which AnyPS5 implements itself.
  static List<String> moduleDirectories(List<String> modules) {
    final directories = ['.'];
    for (final module in modules) {
      if (!module.toLowerCase().endsWith('.prx')) continue;
      final slash = module.lastIndexOf('/');
      final directory = slash < 0 ? '.' : module.substring(0, slash);
      final first = directory.split('/').first;
      if (const ['sce_module', 'sce_modules', 'prx', 'fakelib'].contains(first.toLowerCase())) continue;
      if (directories.contains(directory)) continue;
      directories.add(directory);
    }
    return directories;
  }

  /// An ELF as it is, a re-signed one from its .esbak, a SELF container unwrapped.
  void _unwrap(String original, String target) {
    final name = p.basename(original);
    if (Binary.isElf(original)) {
      File(original).copySync(target);
    } else if (Binary.isElf('$original.esbak')) {
      File('$original.esbak').copySync(target);
      _log('$name: from .esbak');
    } else if (SelfUnwrap.isContainer(original)) {
      try {
        final size = SelfUnwrap.unwrapFile(original, target);
        _log('$name: unwrapped, $size bytes');
      } on SelfRefused catch (error) {
        throw InstallError('$name: ${error.reason}');
      }
    } else {
      throw InstallError('$name is neither an ELF nor a decrypted SELF container (an encrypted dump cannot be used)');
    }
  }

  Future<void> _linkTree(String source, String target, void Function(double) progress) async {
    var mode = linkMode;
    if (mode == null) {
      final sample = File(p.join(source, 'eboot.bin'));
      mode = FileLinks.probe(sample.path, target);
      if (mode != LinkMode.hard) {
        _log(
          mode == LinkMode.symbolic
              ? '${game.titleId}: the store is on another volume than the dump, so the game links to it'
              : '${game.titleId}: the store cannot link to the dump, so the game is copied',
        );
      }
    }
    await copyTree(source, target, mode, isCancelled: () => _cancelled, progress: progress);
  }

  /// The files of [source] in [target], folder by folder, each placed as [mode] says; the store
  /// is left out. Reports the share of bytes done.
  static Future<void> copyTree(
    String source,
    String target,
    LinkMode mode, {
    bool Function()? isCancelled,
    void Function(double)? progress,
  }) async {
    final base = p.normalize(p.absolute(source));
    final files = <(String, String, int)>[];
    var total = 0;
    final entries = Directory(base).listSync(recursive: true, followLinks: true);
    for (final entry in entries) {
      final relative = p.relative(entry.path, from: base);
      final first = p.split(relative).first;
      if (first == GameLibrary.storeName) continue;
      if (entry is Directory) {
        Directory(p.join(target, relative)).createSync(recursive: true);
      } else if (entry is File) {
        final size = entry.lengthSync();
        files.add((entry.path, relative, size));
        total += size;
      }
    }
    var done = 0;
    for (var index = 0; index < files.length; index++) {
      if (isCancelled?.call() ?? false) throw InstallCancelled();
      final (path, relative, size) = files[index];
      final destination = p.join(target, relative);
      Directory(p.dirname(destination)).createSync(recursive: true);
      FileLinks.place(path, destination, mode);
      done += size;
      progress?.call(total == 0 ? 1 : done / total);
      if (index % 64 == 63) await _yield();
    }
    progress?.call(1);
  }

  /// The script that starts the installed game from its folder without the launcher.
  static String launchScript(HostSystem system, Game game) {
    if (system == HostSystem.windows) {
      return '@echo off\r\n'
          'rem Starts ${game.name} (${game.titleId}) from its folder: AnyPS5 maps /app0 under the working directory.\r\n'
          'cd /d "%~dp0"\r\n'
          '"%~dp0app.exe" %*\r\n';
    }
    return '#!/bin/sh\n'
        '# Starts ${game.name} (${game.titleId}) from its folder: AnyPS5 maps /app0 under the working directory.\n'
        'cd "\$(dirname "\$0")" || exit 1\n'
        'exec ./app.elf "\$@"\n';
  }

  Future<void> _runTool(
    String tool,
    List<String> arguments, {
    required String workingDirectory,
    void Function(String segment)? status,
  }) async {
    _checkCancelled();
    final Process process;
    try {
      process = await Process.start(tool, arguments, workingDirectory: workingDirectory);
    } on ProcessException catch (error) {
      throw InstallError('${p.basename(tool)} could not start: ${error.message}');
    }
    _running = process;
    if (_cancelled) process.kill();
    final collector = OutputCollector(log: _log, status: status);
    final out = process.stdout.forEach(collector.add);
    final err = process.stderr.forEach(collector.add);
    final code = await process.exitCode;
    // A child the tool left behind can hold its output open; the tool's own output is in by now.
    await Future.wait([out, err])
        .timeout(const Duration(seconds: 2), onTimeout: () => const [])
        .catchError((_) => const <void>[]);
    collector.flush();
    _running = null;
    _checkCancelled();
    if (code != 0) {
      throw InstallError(
        '${p.basename(tool)} failed ($code)${collector.lines.isEmpty ? '' : ': ${collector.lines.last}'}',
      );
    }
  }

  static Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['755', path]);
  }

  static Future<void> _yield() => Future<void>.delayed(Duration.zero);

  static void _delete(String path) {
    try {
      FileLinks.remove(path);
    } on FileSystemException {
      // Gone or busy; a later install cleans up.
    }
  }
}

/// Splits a tool's output into lines for the log as it arrives. A progress display rewrites its
/// line with carriage returns: every rewrite goes to [status], only the line's last state to the
/// log.
class OutputCollector {
  OutputCollector({this.log, this.status});

  final void Function(String line)? log;
  final void Function(String segment)? status;
  final List<int> _pending = [];
  String? _rewritten;
  final List<String> lines = [];

  void add(List<int> data) {
    _pending.addAll(data);
    final complete = <String>[];
    final segments = <String>[];
    while (true) {
      final end = _pending.indexWhere((byte) => byte == 0x0A || byte == 0x0D);
      if (end < 0) break;
      final text = utf8.decode(_pending.sublist(0, end), allowMalformed: true);
      final newline = _pending[end] == 0x0A;
      _pending.removeRange(0, end + 1);
      if (text.isNotEmpty) {
        segments.add(text);
        _rewritten = text;
      }
      if (newline) {
        if (_rewritten != null) complete.add(_rewritten!);
        _rewritten = null;
      }
    }
    lines.addAll(complete);
    if (lines.length > 400) lines.removeRange(0, lines.length - 400);
    segments.forEach(status ?? (_) {});
    complete.forEach(log ?? (_) {});
  }

  void flush() {
    final rest = _pending.isEmpty ? _rewritten : utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    _rewritten = null;
    if (rest != null && rest.isNotEmpty) {
      lines.add(rest);
      log?.call(rest);
    }
  }
}

/// Turns the relinker's progress display ("Instruction scan | eboot.bin | 42%") into one rising
/// fraction of the relink step.
class RelinkProgress {
  double _reached = 0;

  double? read(String segment) {
    final fields = segment.split('|').map((field) => field.trim()).toList();
    if (fields.length < 3) return null;
    final phase = fields[0];
    final file = fields[1];
    final value = fields[2];
    final percent = double.tryParse(value.split('%').first.trim());
    if (percent == null) return null;
    final done = (percent / 100).clamp(0.0, 1.0);
    double estimate;
    switch (phase) {
      case 'Instruction scan' when file == 'eboot.bin':
        estimate = 0.2 * done;
      case 'Instruction conversion' when file == 'eboot.bin':
        estimate = 0.2 + 0.25 * done;
      case 'Syscall scan' when file == 'eboot.bin':
        estimate = 0.45 + 0.1 * done;
      case 'PRX conversion':
        // "100% (3/7)": modules converted of all.
        final match = RegExp(r'\((\d+)/(\d+)\)').firstMatch(value);
        final converted = match == null ? null : double.parse(match.group(1)!);
        final all = match == null ? null : double.parse(match.group(2)!);
        estimate = converted != null && all != null && all > 0 ? 0.55 + 0.3 * converted / all : 0.55;
      case 'Output image':
        estimate = 0.85 + 0.1 * done;
      case 'Write output':
        estimate = 0.95 + 0.05 * done;
      default:
        return null;
    }
    if (estimate <= _reached) return null;
    _reached = estimate;
    return estimate;
  }
}
