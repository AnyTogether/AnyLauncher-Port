import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// How the game's files reach an installed game's app0/.
enum LinkMode {
  /// A hard link: no space taken, the game sees a real file. Needs the same volume.
  hard,

  /// A symbolic link to the dump's file (POSIX only; Windows needs privileges for them).
  symbolic,

  /// A full copy, where neither link works.
  copy,
}

/// Hard links through the system call, which dart:io does not offer: link(2) on POSIX,
/// CreateHardLinkW on Windows.
abstract final class FileLinks {
  static final bool Function(String existing, String created) _hardLink = _load();

  static bool Function(String, String) _load() {
    try {
      if (Platform.isWindows) {
        final kernel = DynamicLibrary.open('kernel32.dll');
        final create = kernel
            .lookupFunction<
              Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
              int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
            >('CreateHardLinkW');
        return (existing, created) {
          final from = _windowsPath(existing).toNativeUtf16();
          final to = _windowsPath(created).toNativeUtf16();
          try {
            return create(to, from, nullptr) != 0;
          } finally {
            calloc.free(from);
            calloc.free(to);
          }
        };
      }
      final link = DynamicLibrary.process()
          .lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>), int Function(Pointer<Utf8>, Pointer<Utf8>)>(
            'link',
          );
      return (existing, created) {
        final from = existing.toNativeUtf8();
        final to = created.toNativeUtf8();
        try {
          return link(from, to) == 0;
        } finally {
          calloc.free(from);
          calloc.free(to);
        }
      };
    } on Object {
      return (_, _) => false;
    }
  }

  /// An absolute Windows path in the \\?\ form, which is not limited to 260 characters.
  static String _windowsPath(String path) {
    final absolute = p.windows.normalize(p.windows.absolute(path));
    if (absolute.startsWith(r'\\?\')) return absolute;
    if (absolute.startsWith(r'\\')) return '\\\\?\\UNC\\${absolute.substring(2)}';
    return '\\\\?\\$absolute';
  }

  /// Makes [created] a hard link to [existing]; false when the system refuses (another volume,
  /// a file system without links).
  static bool hardLink(String existing, String created) => _hardLink(existing, created);

  /// Puts [source] at [destination] the way [mode] says, replacing what is there. Something at
  /// the destination is removed first, never written through: it may be a link to the dump.
  static void place(String source, String destination, LinkMode mode) {
    remove(destination);
    switch (mode) {
      case LinkMode.hard:
        if (!hardLink(source, destination)) {
          throw FileSystemException('cannot hard link', destination);
        }
      case LinkMode.symbolic:
        Link(destination).createSync(File(source).absolute.path);
      case LinkMode.copy:
        File(source).copySync(destination);
    }
  }

  /// Removes a file or link at [path], if there is one; never follows a link.
  static void remove(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.link:
        Link(path).deleteSync();
      case FileSystemEntityType.file:
        File(path).deleteSync();
      case FileSystemEntityType.directory:
        Directory(path).deleteSync(recursive: true);
      default:
        break;
    }
  }

  /// The best mode from [source] files into [target]: a hard link where one works, else a
  /// symbolic link on POSIX, else a copy. Tried with a real file of the source.
  static LinkMode probe(String sampleFile, String targetFolder) {
    Directory(targetFolder).createSync(recursive: true);
    final probe = p.join(targetFolder, '.anyps5-link-probe-$pid');
    try {
      remove(probe);
      if (hardLink(sampleFile, probe)) return LinkMode.hard;
      if (!Platform.isWindows) return LinkMode.symbolic;
      return LinkMode.copy;
    } finally {
      try {
        remove(probe);
      } on FileSystemException {
        // Left behind at worst; the next install removes it.
      }
    }
  }
}
