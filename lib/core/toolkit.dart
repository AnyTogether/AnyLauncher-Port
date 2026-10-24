import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';

/// The tools a game is made with, for one system: the relinker and the system libraries built
/// for it, as upstream's release archives and build tree lay them out.
///
/// ```text
/// toolkit/
///     relinker | relinker.exe
///     libs/*.prx          (and the mingw runtime DLLs on Windows)
///     version.txt         changes when the relinker or libraries change
/// ```
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

  /// The relinker: the toolkit's own unless another was set.
  String get relinker => relinkerOverride ?? p.join(root, system.relinkerName);
  String get libraries => p.join(root, 'libs');

  /// Changes whenever the relinker or the libraries change: a game installed with another toolkit
  /// can be installed again.
  String get version {
    try {
      final text = File(p.join(root, 'version.txt')).readAsStringSync().trim();
      return text.isEmpty ? 'unknown' : text;
    } on FileSystemException {
      return 'unknown';
    }
  }

  /// What is wrong with the toolkit, null when it can be used.
  ToolkitProblem? get problem {
    if (!File(relinker).existsSync()) return ToolkitProblem.noRelinker;
    if (!Directory(libraries).existsSync() || libraryFiles.isEmpty) return ToolkitProblem.noLibraries;
    return null;
  }

  /// The files an installed game's libs/ gets: every .prx, and on Windows the DLLs beside them.
  List<String> get libraryFiles {
    try {
      final files = Directory(libraries).listSync().whereType<File>().map((file) => file.path).where((path) {
        final extension = p.extension(path).toLowerCase();
        return extension == '.prx' || (system == HostSystem.windows && extension == '.dll');
      }).toList()..sort();
      return files;
    } on FileSystemException {
      return const [];
    }
  }
}

enum ToolkitProblem { noRelinker, noLibraries }
