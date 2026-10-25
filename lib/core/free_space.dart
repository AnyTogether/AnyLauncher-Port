import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The free space on the volume of a folder: GetDiskFreeSpaceExW on Windows, statvfs(3) on 64-bit
/// Linux, `df` elsewhere (or where statvfs cannot be called).
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
      if (Platform.isWindows) return _windows(folder);
      if (Platform.isLinux) return _statvfs(folder) ?? _posix(folder);
      return _posix(folder);
    } on Object {
      return null;
    }
  }

  /// The bytes free to an unprivileged user from statvfs(3) (f_bavail × f_frsize), null where it
  /// fails or this is not a 64-bit glibc/musl layout.
  static int? _statvfs(String folder) {
    if (sizeOf<IntPtr>() != 8) return null;
    final call = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Uint8>), int Function(Pointer<Utf8>, Pointer<Uint8>)>(
          'statvfs',
        );
    final path = folder.toNativeUtf8();
    final buffer = calloc<Uint8>(statvfsBytes);
    try {
      if (call(path, buffer) != 0) return null;
      return parseStatvfs(Uint8List.fromList(buffer.asTypedList(statvfsBytes)));
    } finally {
      calloc.free(path);
      calloc.free(buffer);
    }
  }

  /// Room for struct statvfs, larger than any 64-bit Linux layout (112 bytes on glibc).
  static const statvfsBytes = 256;

  /// The available bytes in a 64-bit Linux struct statvfs: f_bsize, f_frsize, f_blocks, f_bfree,
  /// f_bavail, each eight bytes in that order; f_frsize is the unit of the counts (f_bsize where a
  /// file system leaves it 0).
  static int? parseStatvfs(Uint8List bytes) {
    if (bytes.length < 40) return null;
    final data = ByteData.sublistView(bytes);
    final blockSize = data.getUint64(0, Endian.host);
    final fragmentSize = data.getUint64(8, Endian.host);
    final available = data.getUint64(32, Endian.host);
    final unit = fragmentSize != 0 ? fragmentSize : blockSize;
    if (unit == 0) return null;
    return available * unit;
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
