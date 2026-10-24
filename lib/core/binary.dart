import 'dart:io';
import 'dart:typed_data';

/// Little-endian reads and writes on byte lists, and file magic checks.
abstract final class Binary {
  static int u16(List<int> data, int at) => data[at] | data[at + 1] << 8;

  static int u32(List<int> data, int at) => data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24;

  /// A 64-bit value; Dart's int is 64-bit two's complement, so values at or above 2^63 read as
  /// negative and compare with [ult] and friends.
  static int u64(List<int> data, int at) => u32(data, at) | u32(data, at + 4) << 32;

  static void put16(List<int> data, int at, int value) {
    for (var byte = 0; byte < 2; byte++) {
      data[at + byte] = (value >> (8 * byte)) & 0xFF;
    }
  }

  static void put32(List<int> data, int at, int value) {
    for (var byte = 0; byte < 4; byte++) {
      data[at + byte] = (value >> (8 * byte)) & 0xFF;
    }
  }

  static void put64(List<int> data, int at, int value) {
    for (var byte = 0; byte < 8; byte++) {
      data[at + byte] = (value >>> (8 * byte)) & 0xFF;
    }
  }

  /// Unsigned 64-bit comparisons.
  static int ucompare(int a, int b) => (a ^ _sign).compareTo(b ^ _sign);
  static bool ult(int a, int b) => ucompare(a, b) < 0;
  static bool ule(int a, int b) => ucompare(a, b) <= 0;
  static bool ugt(int a, int b) => ucompare(a, b) > 0;
  static bool uge(int a, int b) => ucompare(a, b) >= 0;
  static int umin(int a, int b) => ult(a, b) ? a : b;
  static int umax(int a, int b) => ugt(a, b) ? a : b;
  static const int _sign = 0x8000000000000000;

  /// The first [count] bytes of a file, fewer when it is shorter, empty when it cannot be read.
  static Uint8List head(String path, int count) {
    RandomAccessFile? file;
    try {
      file = File(path).openSync();
      return file.readSync(count);
    } on FileSystemException {
      return Uint8List(0);
    } finally {
      file?.closeSync();
    }
  }

  static const elfMagic = [0x7F, 0x45, 0x4C, 0x46];

  static bool isElf(String path) {
    final bytes = head(path, 4);
    return bytes.length == 4 &&
        bytes[0] == elfMagic[0] &&
        bytes[1] == elfMagic[1] &&
        bytes[2] == elfMagic[2] &&
        bytes[3] == elfMagic[3];
  }
}
