import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// How the game's files reach an installed game's app0/.
enum LinkMode {
  /// A hard link: no space taken, the game sees a real file. Needs the same volume.
  hard,

  /// A symbolic link to the dump's file: no space taken, works across volumes. Windows makes
  /// them without administrator rights only with Developer Mode on.
  symbolic,

  /// A full copy, where neither link works.
  copy,
}

/// The system calls that make links, replaceable in tests (a Windows without Developer Mode, a
/// store on another volume than the dump).
class LinkCalls {
  const LinkCalls({required this.hardLink, required this.symbolicLink});

  /// Makes `created` a hard link to `existing`; false when the system refuses.
  final bool Function(String existing, String created) hardLink;

  /// Makes `created` a symbolic link to the file `existing` (an absolute path); false when the
  /// system refuses.
  final bool Function(String existing, String created) symbolicLink;
}

/// Links through the system calls, which dart:io does not offer: link(2) on POSIX,
/// CreateHardLinkW and CreateSymbolicLinkW on Windows.
abstract final class FileLinks {
  /// This system's own calls.
  static final LinkCalls system = LinkCalls(hardLink: _loadHardLink(), symbolicLink: _loadSymbolicLink());

  /// The calls links are made with; [system] unless a test put others in.
  static LinkCalls calls = system;

  static bool Function(String, String) _loadHardLink() {
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

  /// SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE: with Developer Mode on, no administrator
  /// rights are needed (Windows 10 1703 and later).
  static const _allowUnprivileged = 0x2;

  static bool Function(String, String) _loadSymbolicLink() {
    if (!Platform.isWindows) {
      return (existing, created) {
        try {
          Link(created).createSync(existing);
          return true;
        } on FileSystemException {
          return false;
        }
      };
    }
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final create = kernel
          .lookupFunction<
            Uint8 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Utf16>, int)
          >('CreateSymbolicLinkW');
      return (existing, created) {
        final link = _windowsPath(created).toNativeUtf16();
        final target = _windowsTarget(existing).toNativeUtf16();
        try {
          if (create(link, target, _allowUnprivileged) != 0) return true;
          // Windows 10 before 1703 refuses the flag; an elevated launcher needs none.
          return create(link, target, 0) != 0;
        } finally {
          calloc.free(link);
          calloc.free(target);
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

  /// A symbolic link's target: the plain absolute path (what dir and Explorer show), the \\?\
  /// form only where it is too long for that.
  static String _windowsTarget(String path) {
    final absolute = p.windows.normalize(p.windows.absolute(path));
    return absolute.length < 248 ? absolute : _windowsPath(absolute);
  }

  /// Makes [created] a hard link to [existing]; false when the system refuses (another volume,
  /// a file system without links).
  static bool hardLink(String existing, String created) => calls.hardLink(existing, created);

  /// Makes [created] a symbolic link to the file [existing]; false when the system refuses
  /// (Windows without Developer Mode or administrator rights, a file system without links).
  static bool symbolicLink(String existing, String created) =>
      calls.symbolicLink(File(existing).absolute.path, created);

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
        if (!symbolicLink(source, destination)) {
          throw FileSystemException('cannot make a symbolic link', destination);
        }
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

  /// Whether [path] is a symbolic link whose target is gone (the dump moved or was deleted).
  static bool isBroken(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.link) return false;
    try {
      final target = Link(path).targetSync();
      final resolved = p.isAbsolute(target) ? target : p.join(p.dirname(path), target);
      return FileSystemEntity.typeSync(resolved) == FileSystemEntityType.notFound;
    } on FileSystemException {
      return true;
    }
  }

  /// The best mode from [sampleFile]'s folder into [targetFolder]: a hard link where one works
  /// (the same volume), else a symbolic link where one can be made and read through, else a
  /// copy. Tried with a real file of the source.
  static LinkMode probe(String sampleFile, String targetFolder) {
    Directory(targetFolder).createSync(recursive: true);
    final probe = p.join(targetFolder, '.anyps5-link-probe-$pid');
    try {
      remove(probe);
      if (hardLink(sampleFile, probe)) return LinkMode.hard;
      remove(probe);
      if (symbolicLink(sampleFile, probe) && _readable(probe, sampleFile)) return LinkMode.symbolic;
      return LinkMode.copy;
    } on FileSystemException {
      return LinkMode.copy;
    } finally {
      try {
        remove(probe);
      } on FileSystemException {
        // Left behind at worst; the next install removes it.
      }
    }
  }

  /// Whether the link at [probe] reads as [sample] does (a link Windows will not follow, one
  /// to a remote volume with that evaluation off, does not).
  static bool _readable(String probe, String sample) {
    try {
      if (FileSystemEntity.typeSync(probe, followLinks: false) != FileSystemEntityType.link) return false;
      return File(probe).lengthSync() == File(sample).lengthSync();
    } on FileSystemException {
      return false;
    }
  }
}
