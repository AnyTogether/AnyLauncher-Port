import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// The GNU C library a Linux engine needs against the one this system has. Upstream builds its
/// Linux system libraries on a recent distribution, so they can ask for a newer glibc than an
/// older one (Ubuntu 22.04 has 2.35) offers: the launcher installs games with them there, but
/// the games would not start. This says so before it comes to that.
abstract final class Glibc {
  /// This system's glibc version (2.35), null where there is none (musl, macOS, Windows).
  static String? host() {
    if (!Platform.isLinux) return null;
    try {
      final version = DynamicLibrary.process().lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'gnu_get_libc_version',
      )();
      final text = version.toDartString();
      if (RegExp(r'^\d+\.\d+').hasMatch(text)) return text;
    } on Object {
      // Not glibc, or the symbol is hidden: ldd says which.
    }
    try {
      final result = Process.runSync('ldd', ['--version']);
      return parseLddVersion('${result.stdout}\n${result.stderr}');
    } on ProcessException {
      return null;
    }
  }

  /// The version from `ldd --version`'s first line ("ldd (Ubuntu GLIBC 2.35-0ubuntu3.13) 2.35"),
  /// null for another C library (musl's ldd prints no GNU line).
  static String? parseLddVersion(String output) {
    final first = output.trim().split('\n').first;
    if (!RegExp('GNU|GLIBC|glibc', caseSensitive: false).hasMatch(first)) return null;
    return RegExp(r'(\d+\.\d+(?:\.\d+)?)\s*$').firstMatch(first)?.group(1);
  }

  /// Orders versions number by number: 2.38 after 2.4.
  static int compare(String a, String b) {
    final left = a.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final right = b.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    for (var index = 0; index < left.length || index < right.length; index++) {
      final x = index < left.length ? left[index] : 0;
      final y = index < right.length ? right[index] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// The newest GLIBC_x.y symbol version [file] asks for (its ELF version needs), null when it
  /// asks for none or is not a 64-bit little-endian ELF.
  static String? required(String file) {
    RandomAccessFile? handle;
    try {
      handle = File(file).openSync();
      return _required(handle);
    } on FileSystemException {
      return null;
    } on RangeError {
      return null;
    } finally {
      handle?.closeSync();
    }
  }

  /// The newest glibc any of [files] asks for, null when none asks.
  static String? requiredByAll(Iterable<String> files) {
    String? newest;
    for (final file in files) {
      final version = required(file);
      if (version != null && (newest == null || compare(version, newest) > 0)) newest = version;
    }
    return newest;
  }

  static final Map<String, String?> _cache = {};

  /// What [files] need and this system lacks: ('2.38', '2.35'), or null when it is enough or
  /// either side is unknown. [key] remembers the answer for a toolkit that does not change.
  static ({String needed, String host})? shortfall(Iterable<String> files, {String? host, String? key}) {
    final have = host;
    if (have == null) return null;
    final String? needed;
    if (key != null && _cache.containsKey(key)) {
      needed = _cache[key];
    } else {
      needed = requiredByAll(files);
      if (key != null) _cache[key] = needed;
    }
    if (needed == null || compare(needed, have) <= 0) return null;
    return (needed: needed, host: have);
  }

  static Uint8List _read(RandomAccessFile handle, int offset, int length) {
    handle.setPositionSync(offset);
    final bytes = handle.readSync(length);
    if (bytes.length != length) throw RangeError('short read');
    return bytes;
  }

  static String? _required(RandomAccessFile handle) {
    final header = ByteData.sublistView(_read(handle, 0, 64));
    // \x7fELF, 64-bit, little-endian.
    if (header.getUint32(0, Endian.big) != 0x7f454c46 || header.getUint8(4) != 2 || header.getUint8(5) != 1) {
      return null;
    }
    final sectionsAt = header.getUint64(0x28, Endian.little);
    final entrySize = header.getUint16(0x3a, Endian.little);
    final count = header.getUint16(0x3c, Endian.little);
    if (sectionsAt == 0 || count == 0 || entrySize < 64 || count > 4096) return null;
    final sections = ByteData.sublistView(_read(handle, sectionsAt, entrySize * count));
    ({int type, int offset, int size, int link}) section(int index) {
      final at = index * entrySize;
      return (
        type: sections.getUint32(at + 4, Endian.little),
        offset: sections.getUint64(at + 0x18, Endian.little),
        size: sections.getUint64(at + 0x20, Endian.little),
        link: sections.getUint32(at + 0x28, Endian.little),
      );
    }

    const versionNeeds = 0x6ffffffe; // SHT_GNU_verneed
    String? newest;
    for (var index = 0; index < count; index++) {
      final needs = section(index);
      if (needs.type != versionNeeds || needs.link >= count || needs.size > 1 << 20) continue;
      final names = section(needs.link);
      if (names.size > 16 << 20) continue;
      final data = ByteData.sublistView(_read(handle, needs.offset, needs.size));
      final strings = _read(handle, names.offset, names.size);
      String name(int at) {
        var end = at;
        while (end < strings.length && strings[end] != 0) {
          end++;
        }
        return String.fromCharCodes(strings, at, end);
      }

      // Verneed entries, each with its Vernaux list of version names.
      var entry = 0;
      for (var guard = 0; guard < 1024 && entry + 16 <= data.lengthInBytes; guard++) {
        final auxCount = data.getUint16(entry + 2, Endian.little);
        var aux = entry + data.getUint32(entry + 8, Endian.little);
        for (var n = 0; n < auxCount && aux + 16 <= data.lengthInBytes; n++) {
          final version = name(data.getUint32(aux + 8, Endian.little));
          final match = RegExp(r'^GLIBC_(\d+(?:\.\d+)+)$').firstMatch(version);
          if (match != null && (newest == null || compare(match.group(1)!, newest) > 0)) newest = match.group(1);
          final next = data.getUint32(aux + 12, Endian.little);
          if (next == 0) break;
          aux += next;
        }
        final next = data.getUint32(entry + 12, Endian.little);
        if (next == 0) break;
        entry += next;
      }
    }
    return newest;
  }
}
