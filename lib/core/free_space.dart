import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The free space on the volume of a folder: GetDiskFreeSpaceExW on Windows, `df` elsewhere.
abstract final class FreeSpace {
  /// The bytes free to this user where [path] is (or would be: its nearest existing parent),
  /// null when the system does not say.
  static int? of(String path) {
    var folder = p.absolute(path);
    while (!Directory(folder).existsSync()) {
      final parent = p.dirname(folder);
      if (parent == folder) return null;
      folder = parent;
    }
    try {
      return Platform.isWindows ? _windows(folder) : _posix(folder);
    } on Object {
      return null;
    }
  }

  static int? _windows(String folder) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final free = kernel
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
          int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
        >('GetDiskFreeSpaceExW');
    final name = folder.toNativeUtf16();
    final available = calloc<Uint64>();
    try {
      return free(name, available, nullptr, nullptr) == 0 ? null : available.value;
    } finally {
      calloc.free(name);
      calloc.free(available);
    }
  }

  static int? _posix(String folder) {
    final result = Process.runSync('df', ['-Pk', folder]);
    if (result.exitCode != 0) return null;
    return parseDf(result.stdout as String);
  }

  /// The available bytes in POSIX `df -Pk` output (its fourth column, in KiB).
  static int? parseDf(String output) {
    final lines = output.trim().split('\n');
    if (lines.length < 2) return null;
    final columns = lines.last.trim().split(RegExp(r'\s+'));
    if (columns.length < 4) return null;
    final kib = int.tryParse(columns[columns.length - 3]);
    return kib == null ? null : kib * 1024;
  }
}
