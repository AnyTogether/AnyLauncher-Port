import 'dart:io';

import 'package:path/path.dart' as p;

/// The files the launcher was started with: a `.anyps5theme` double-clicked in the file manager
/// comes as a path on Windows and as a path or a `file://` URI (a desktop entry's %U) on Linux.
/// A launcher already open is handed them over the link relay (link_relay.dart).
abstract final class OpenedFiles {
  /// The files among [arguments] that exist, as absolute paths, each once; options and the title
  /// ID after `--play` are left out.
  static List<String> of(List<String> arguments) {
    final found = <String>[];
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--play') {
        index++;
        continue;
      }
      if (argument.startsWith('-')) continue;
      var path = argument;
      if (argument.startsWith('file:')) {
        try {
          path = Uri.parse(argument).toFilePath();
        } on Object {
          continue;
        }
      }
      final absolute = p.absolute(path);
      if (File(absolute).existsSync() && !found.contains(absolute)) found.add(absolute);
    }
    return found;
  }
}
