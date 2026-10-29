import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'engine_checkout.dart';
import 'host.dart';

/// The tools a game is made with, for one system: the relinker and the system libraries built
/// for it, as upstream's release archives and build tree lay them out.
///
/// ```text
/// toolkit/
///     relinker | relinker.exe
///     libs/*.prx          (and the mingw runtime DLLs on Windows)
///     version.txt         changes when the relinker or libraries change (a fingerprint without it)
///     patches/<TITLE>.toml  per-title byte patches (optional)
/// ```
///
/// Or a git checkout of the engine's source built in place ([EngineCheckout]): the relinker and
/// the libraries then come from its build folder.
class Toolkit {
  Toolkit(this.root, {this.system = HostSystem.linux, this.relinkerOverride});

  /// The toolkit in the first of [candidates] that has a relinker; ANYPS5_TOOLKIT comes first.
  static Toolkit? locate(List<String> candidates, {HostSystem? system, Map<String, String>? environment}) {
    final host = system ?? HostSystem.current;
    final env = environment ?? Platform.environment;
    final all = [if (env['ANYPS5_TOOLKIT'] case final String path when path.isNotEmpty) path, ...candidates];
    for (final candidate in all) {
      final toolkit = Toolkit(candidate, system: host);
      if (toolkit.problem == null) return toolkit;
    }
    return null;
  }

  final String root;
  final HostSystem system;

  /// A relinker set apart from the toolkit (a setting), null for the toolkit's own.
  final String? relinkerOverride;

  /// The engine's source tree when [root] is one (no relinker and no version.txt at its top),
  /// null for a toolkit folder. Read once per Toolkit.
  late final EngineCheckout? checkout =
      File(p.join(root, system.relinkerName)).existsSync() || File(p.join(root, 'version.txt')).existsSync()
      ? null
      : EngineCheckout.at(root, system: system);

  /// The relinker: the toolkit's own unless another was set.
  String get relinker => relinkerOverride ?? checkout?.relinker ?? p.join(root, system.relinkerName);
  String get libraries => checkout?.libraries ?? p.join(root, 'libs');

  /// Folders the relinker needs on PATH (a checkout's compiler, for its runtime DLLs).
  List<String> get toolFolders => checkout?.pathFolders ?? const [];

  /// Per-title patch files for the relinker, patches/<TITLE ID>.toml.
  String get patches => p.join(root, 'patches');

  /// The title's patch file, null when the toolkit has none.
  String? patchFile(String titleId) {
    final file = p.join(patches, '$titleId.toml');
    return File(file).existsSync() ? file : null;
  }

  /// Changes whenever the relinker or the libraries change: a game installed with another toolkit
  /// can be installed again. version.txt, or for a folder someone put together without one (a
  /// build of their own), "local-" and a fingerprint of the relinker, libs/ and patches/: built
  /// again in place, its games offer Update and Play. Read once per Toolkit.
  late final String version = () {
    try {
      final text = File(p.join(root, 'version.txt')).readAsStringSync().trim();
      if (text.isNotEmpty) return text;
    } on FileSystemException {
      // A folder of the user's own.
    }
    return fingerprint() ?? 'unknown';
  }();

  /// "local-" and 12 hex digits from the name, size and modification time of the relinker, each
  /// library and each patch (no file is read: a build's libraries are hundreds of megabytes);
  /// null without a relinker.
  String? fingerprint() {
    final relinkerFile = File(relinker);
    if (!relinkerFile.existsSync()) return null;
    final lines = <String>[];
    void add(File file) {
      try {
        final stat = file.statSync();
        lines.add('${p.relative(file.path, from: root)} ${stat.size} ${stat.modified.microsecondsSinceEpoch}');
      } on FileSystemException {
        lines.add(p.basename(file.path));
      }
    }

    add(relinkerFile);
    libraryFiles.map(File.new).forEach(add);
    try {
      final patchFiles = Directory(patches).listSync().whereType<File>().where((file) => file.path.endsWith('.toml'));
      (patchFiles.toList()..sort((a, b) => a.path.compareTo(b.path))).forEach(add);
    } on FileSystemException {
      // No patches.
    }
    return 'local-${sha256.convert(utf8.encode(lines.join('\n'))).toString().substring(0, 12)}';
  }

  /// What is wrong with the toolkit, null when it can be used.
  ToolkitProblem? get problem {
    if (!File(relinker).existsSync()) return ToolkitProblem.noRelinker;
    if (!Directory(libraries).existsSync() || libraryFiles.isEmpty) return ToolkitProblem.noLibraries;
    return null;
  }

  /// The files an installed game's libs/ gets: every .prx, and on Windows the DLLs beside them
  /// (for a checkout, also the MinGW runtime from the compiler's folder).
  List<String> get libraryFiles {
    try {
      final files = Directory(libraries).listSync().whereType<File>().map((file) => file.path).where((path) {
        final extension = p.extension(path).toLowerCase();
        return extension == '.prx' || (system == HostSystem.windows && extension == '.dll');
      }).toList()..sort();
      final runtime = checkout?.runtimeLibraries ?? const <String>[];
      if (runtime.isNotEmpty && files.isNotEmpty) {
        final names = {for (final file in files) p.basename(file).toLowerCase()};
        files.addAll(runtime.where((file) => !names.contains(p.basename(file).toLowerCase())));
      }
      return files;
    } on FileSystemException {
      return const [];
    }
  }
}

enum ToolkitProblem { noRelinker, noLibraries }
