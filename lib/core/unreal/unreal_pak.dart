import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Why a pak or a file in it cannot be read.
class UnrealPakFailure implements Exception {
  const UnrealPakFailure(this.description);
  final String description;

  @override
  String toString() => description;
}

/// A file's place in the pak: its header's offset, its sizes, how it is stored, and its
/// compressed blocks (from and to, from the entry's start).
class UnrealPakEntry {
  const UnrealPakEntry({
    required this.offset,
    required this.size,
    required this.uncompressedSize,
    required this.method,
    required this.encrypted,
    required this.blocks,
    required this.headerSize,
  });

  final int offset;
  final int size;
  final int uncompressedSize;
  final int method;
  final bool encrypted;
  final List<(int, int)> blocks;
  final int headerSize;
}

/// Reads files out of an Unreal Engine .pak (versions 3 to 11, UE 4.x and 5.x): the footer, the
/// index (the old list, or the path hash and full directory indexes of 4.26 and later) and the
/// files, stored or compressed with zlib. An encrypted index, encrypted files and compression
/// other than zlib (Oodle) cannot be read without what the game keeps to itself.
class UnrealPak {
  UnrealPak._(this.path, this.version, this._methods, this._entries);

  static const magic = 0x5A6F12E1;

  /// The pak file on disk.
  final String path;
  final int version;
  final List<String> _methods;
  final Map<String, UnrealPakEntry> _entries;

  /// The paths of the files in the pak, mount point included.
  List<String> get paths => _entries.keys.toList();

  /// Reads the pak's footer and index; throws an [UnrealPakFailure] when it is not a pak or
  /// its index cannot be read.
  factory UnrealPak.open(String path) {
    final file = File(path).openSync();
    try {
      return _open(path, file);
    } on FileSystemException catch (error) {
      throw UnrealPakFailure('the pak cannot be read: ${error.message}');
    } finally {
      file.closeSync();
    }
  }

  static UnrealPak _open(String path, RandomAccessFile file) {
    final length = file.lengthSync();
    final tailLength = length < 1024 ? length : 1024;
    final tail = ByteData.sublistView(_read(file, length - tailLength, tailLength));
    // The footer's length differs between versions: its magic is looked for from the end.
    int? footer;
    var version = 0;
    for (var position = tail.lengthInBytes - 4; position >= 0 && footer == null; position--) {
      if (tail.getUint32(position, Endian.little) == magic && position + 8 <= tail.lengthInBytes) {
        final found = tail.getUint32(position + 4, Endian.little);
        if (found >= 3 && found <= 11 && position + 44 <= tail.lengthInBytes) {
          footer = position;
          version = found;
        }
      }
    }
    if (footer == null) throw const UnrealPakFailure('not an Unreal pak');
    if (version >= 4 && footer >= 1 && tail.getUint8(footer - 1) != 0) {
      throw const UnrealPakFailure("the pak's index is encrypted");
    }
    final indexOffset = tail.getInt64(footer + 8, Endian.little);
    final indexSize = tail.getInt64(footer + 16, Endian.little);
    final names = <String>[];
    var cursor = footer + 44 + (version == 9 ? 1 : 0);
    if (version >= 8) {
      while (cursor + 32 <= tail.lengthInBytes) {
        final slot = Uint8List.sublistView(tail, cursor, cursor + 32);
        final end = slot.indexOf(0);
        names.add(utf8.decode(end < 0 ? slot : slot.sublist(0, end), allowMalformed: true));
        cursor += 32;
      }
    }
    if (indexOffset < 0 || indexSize <= 0 || indexOffset + indexSize > length || indexSize >= 1 << 30) {
      throw const UnrealPakFailure("the pak's index is out of the file");
    }
    final index = PakReader(_read(file, indexOffset, indexSize));
    final mount = index.string();
    if (version < 10) {
      final count = index.int32();
      final entries = <String, UnrealPakEntry>{};
      for (var i = 0; i < count; i++) {
        final name = index.string();
        entries[join(mount, name)] = entry(index, version: version);
      }
      return UnrealPak._(path, version, names, entries);
    }
    index.int32();
    index.uint64();
    if (index.uint32() != 0) {
      index.int64();
      index.int64();
      index.skip(20);
    }
    if (index.uint32() == 0) throw const UnrealPakFailure('the pak has no directory index');
    final directoryOffset = index.int64();
    final directorySize = index.int64();
    index.skip(20);
    final encoded = index.bytes(index.int32());
    final unencodedCount = index.int32();
    final unencoded = <UnrealPakEntry>[for (var i = 0; i < unencodedCount; i++) entry(index, version: version)];
    if (directoryOffset < 0 ||
        directorySize <= 0 ||
        directoryOffset + directorySize > length ||
        directorySize >= 1 << 30) {
      throw const UnrealPakFailure("the pak's directory index is out of the file");
    }
    final directory = PakReader(_read(file, directoryOffset, directorySize));
    final entries = <String, UnrealPakEntry>{};
    final folders = directory.int32();
    for (var f = 0; f < folders; f++) {
      final folder = directory.string();
      final files = directory.int32();
      for (var i = 0; i < files; i++) {
        final name = directory.string();
        final location = directory.int32();
        UnrealPakEntry? found;
        if (location >= 0) {
          try {
            found = decode(PakReader(encoded, location), version: version);
          } on UnrealPakFailure {
            found = null;
          }
        } else {
          final at = -location - 1;
          found = at < unencoded.length ? unencoded[at] : null;
        }
        if (found != null) entries[join(mount, folder + name)] = found;
      }
    }
    return UnrealPak._(path, version, names, entries);
  }

  /// The file whose path ends with [suffix] (no matter the case), null when there is none or it
  /// cannot be read.
  Uint8List? fileEndingWith(String suffix) {
    final lower = suffix.toLowerCase();
    final matches = _entries.keys.where((path) => path.toLowerCase().endsWith(lower)).toList()
      ..sort((a, b) => a.length != b.length ? a.length.compareTo(b.length) : a.compareTo(b));
    if (matches.isEmpty) return null;
    try {
      return file(matches.first);
    } on UnrealPakFailure {
      return null;
    }
  }

  /// The bytes of the file at [name] (a path from [paths]); throws an [UnrealPakFailure] when it
  /// is not there, is encrypted or is compressed with something other than zlib.
  Uint8List file(String name) {
    final entry = _entries[name];
    if (entry == null) throw UnrealPakFailure('$name is not in the pak');
    if (entry.encrypted) throw UnrealPakFailure('$name is encrypted');
    final handle = File(path).openSync();
    try {
      if (entry.method == 0) return _read(handle, entry.offset + entry.headerSize, entry.size);
      final method = entry.method >= 1 && entry.method - 1 < _methods.length
          ? _methods[entry.method - 1].toLowerCase()
          : (version < 8 && entry.method == 1 ? 'zlib' : '');
      if (method != 'zlib') {
        throw UnrealPakFailure('$name is compressed with ${method.isEmpty ? 'an unknown method' : method}');
      }
      final data = BytesBuilder(copy: false);
      for (final (start, end) in entry.blocks) {
        final block = _read(handle, entry.offset + start, end - start);
        data.add(inflate(block, limit: entry.uncompressedSize - data.length));
      }
      return data.takeBytes();
    } on FileSystemException catch (error) {
      throw UnrealPakFailure('$name cannot be read: ${error.message}');
    } finally {
      handle.closeSync();
    }
  }

  /// An entry as the old index and every file's own header write it.
  static UnrealPakEntry entry(PakReader reader, {required int version}) {
    final offset = reader.int64();
    final size = reader.int64();
    final uncompressed = reader.int64();
    final method = version < 8 ? reader.int32() & 0x0F : reader.uint32();
    if (version <= 1) reader.int64();
    reader.skip(20);
    var blocks = <(int, int)>[];
    if (method != 0) {
      final count = reader.int32();
      for (var i = 0; i < count; i++) {
        blocks.add((reader.int64(), reader.int64()));
      }
    }
    final flags = reader.uint8();
    reader.uint32();
    // Before version 5 block positions count from the start of the pak.
    if (version < 5) blocks = [for (final (start, end) in blocks) (start - offset, end - offset)];
    return UnrealPakEntry(
      offset: offset,
      size: size,
      uncompressedSize: uncompressed,
      method: method,
      encrypted: flags & 1 != 0,
      blocks: blocks,
      headerSize: headerSize(version: version, compressed: method != 0, blocks: blocks.length),
    );
  }

  /// An entry packed into a few bytes, as the index of 4.26 and later keeps most of them.
  static UnrealPakEntry decode(PakReader reader, {required int version}) {
    final bits = reader.uint32();
    if (bits & 0x3F == 0x3F) reader.uint32();
    final blockCount = (bits >> 6) & 0xFFFF;
    final encrypted = (bits >> 22) & 1 != 0;
    final method = (bits >> 23) & 0x3F;
    final offset = bits & (1 << 31) != 0 ? reader.uint32() : reader.int64();
    final uncompressed = bits & (1 << 30) != 0 ? reader.uint32() : reader.int64();
    final size = method == 0 ? uncompressed : (bits & (1 << 29) != 0 ? reader.uint32() : reader.int64());
    final header = headerSize(version: version, compressed: method != 0, blocks: blockCount);
    final blocks = <(int, int)>[];
    if (blockCount == 1 && !encrypted) {
      blocks.add((header, header + size));
    } else if (blockCount > 0) {
      var start = header;
      for (var i = 0; i < blockCount; i++) {
        final length = reader.uint32();
        blocks.add((start, start + length));
        start += encrypted ? (length + 15) & ~15 : length;
      }
    }
    return UnrealPakEntry(
      offset: offset,
      size: size,
      uncompressedSize: uncompressed,
      method: method,
      encrypted: encrypted,
      blocks: blocks,
      headerSize: header,
    );
  }

  /// The length of the header written before each file's bytes.
  static int headerSize({required int version, required bool compressed, required int blocks}) {
    var size = 8 + 8 + 8 + 4 + 20;
    if (version <= 1) size += 8;
    if (compressed) size += 4 + 16 * blocks;
    return size + 1 + 4;
  }

  static String join(String mount, String path) {
    var start = mount;
    while (start.startsWith('../')) {
      start = start.substring(3);
    }
    if (start.startsWith('/')) start = start.substring(1);
    return start + path;
  }

  static Uint8List _read(RandomAccessFile file, int offset, int count) {
    file.setPositionSync(offset);
    final data = file.readSync(count);
    if (data.length != count) throw const UnrealPakFailure('the pak ends early');
    return data;
  }

  /// Unreal's zlib blocks carry the zlib header and checksum around raw deflate.
  static Uint8List inflate(Uint8List block, {required int limit}) {
    if (block.length <= 6 || limit <= 0) throw const UnrealPakFailure('a broken compressed block');
    List<int> output;
    try {
      output = ZLibDecoder(raw: true).convert(Uint8List.sublistView(block, 2));
    } on FormatException {
      throw const UnrealPakFailure('a broken compressed block');
    }
    if (output.isEmpty) throw const UnrealPakFailure('a broken compressed block');
    final bytes = output is Uint8List ? output : Uint8List.fromList(output);
    return bytes.length > limit ? Uint8List.sublistView(bytes, 0, limit) : bytes;
  }
}

/// Little-endian reading through bytes, failing past their end.
class PakReader {
  PakReader(this.data, [this.position = 0]) : _view = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData _view;
  int position;

  void skip(int count) {
    if (count < 0 || position < 0 || position + count > data.length) {
      throw const UnrealPakFailure('the index ends early');
    }
    position += count;
  }

  Uint8List bytes(int count) {
    final start = position;
    skip(count);
    return Uint8List.sublistView(data, start, position);
  }

  int _at(int count) {
    final start = position;
    skip(count);
    return start;
  }

  int uint8() => _view.getUint8(_at(1));
  int uint32() => _view.getUint32(_at(4), Endian.little);
  int int32() => _view.getInt32(_at(4), Endian.little);
  int uint64() => _view.getUint64(_at(8), Endian.little);
  int int64() => _view.getInt64(_at(8), Endian.little);

  /// Unreal's FString: a length counting the final zero, negative for UTF-16.
  String string() {
    final length = int32();
    if (length == 0) return '';
    if (length > 0) {
      if (length >= 1 << 16) throw UnrealPakFailure('a name of $length bytes');
      final raw = bytes(length);
      return utf8.decode(Uint8List.sublistView(raw, 0, raw.length - 1), allowMalformed: true);
    }
    if (-length >= 1 << 16) throw UnrealPakFailure('a name of ${-length} characters');
    final raw = bytes(-length * 2);
    final units = [for (var i = 0; i < raw.length - 2; i += 2) raw[i] | raw[i + 1] << 8];
    return String.fromCharCodes(units);
  }
}
