import 'dart:convert';
import 'dart:typed_data';

/// Steam's binary KeyValues, as in `userdata/<id>/config/shortcuts.vdf`: a type byte, a key ended
/// by a zero byte, then the value; a map's entries end with 0x08. Every value is kept as the
/// bytes it was read from (strings undecoded, floats and 64-bit numbers as raw bytes), so a file
/// read and written again is the same file to the byte.
abstract final class BinaryVdf {
  static const typeMap = 0x00;
  static const typeString = 0x01;
  static const typeInt32 = 0x02;
  static const typeFloat32 = 0x03;
  static const typePointer = 0x04;
  static const typeWideString = 0x05;
  static const typeColor = 0x06;
  static const typeUint64 = 0x07;
  static const typeEnd = 0x08;
  static const typeInt64 = 0x0A;
  static const typeEndAlternate = 0x0B;

  /// Reads a whole file: the root map's entries up to its 0x08 and any bytes after it.
  static VdfDocument decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    final root = reader.map();
    return VdfDocument(root, trailing: Uint8List.fromList(bytes.sublist(reader.at)));
  }

  static Uint8List encode(VdfDocument document) {
    final out = BytesBuilder(copy: false);
    _writeMap(out, document.root);
    out.add(document.trailing);
    return out.takeBytes();
  }

  /// One entry as its bytes (type, key and value), as it sits inside its map.
  static Uint8List encodeEntry(VdfEntry entry) {
    final out = BytesBuilder(copy: false);
    _writeEntry(out, entry);
    return out.takeBytes();
  }

  static void _writeMap(BytesBuilder out, VdfMap map) {
    for (final entry in map.entries) {
      _writeEntry(out, entry);
    }
    out.addByte(map.end);
  }

  static void _writeEntry(BytesBuilder out, VdfEntry entry) {
    out
      ..addByte(entry.type)
      ..add(entry.key)
      ..addByte(0);
    switch (entry.value) {
      case final VdfMap map:
        _writeMap(out, map);
      case final int number:
        out.add((ByteData(4)..setInt32(0, number, Endian.little)).buffer.asUint8List());
      case final Uint8List raw:
        out.add(raw);
        if (entry.type == typeString) {
          out.addByte(0);
        } else if (entry.type == typeWideString) {
          out
            ..addByte(0)
            ..addByte(0);
        }
    }
  }
}

/// A whole binary VDF file.
class VdfDocument {
  VdfDocument(this.root, {Uint8List? trailing}) : trailing = trailing ?? Uint8List(0);

  final VdfMap root;

  /// Whatever followed the root map's end (nothing in the files Steam writes).
  final Uint8List trailing;
}

/// A map's entries in file order; keys may repeat, as the format allows.
class VdfMap {
  VdfMap([List<VdfEntry>? entries, this.end = BinaryVdf.typeEnd]) : entries = entries ?? [];

  final List<VdfEntry> entries;

  /// The byte that ended the map (0x08, or 0x0B in some files).
  final int end;

  /// The first entry named [key], ignoring case as Steam does.
  VdfEntry? entry(String key) {
    final wanted = key.toLowerCase();
    for (final entry in entries) {
      if (entry.name.toLowerCase() == wanted) return entry;
    }
    return null;
  }

  String? string(String key) => switch (entry(key)) {
    VdfEntry(type: BinaryVdf.typeString, value: final Uint8List raw) => utf8.decode(raw, allowMalformed: true),
    _ => null,
  };

  int? int32(String key) => switch (entry(key)) {
    VdfEntry(type: BinaryVdf.typeInt32, value: final int number) => number,
    _ => null,
  };

  VdfMap? map(String key) => switch (entry(key)) {
    VdfEntry(value: final VdfMap map) => map,
    _ => null,
  };

  /// The string values of a map such as a shortcut's tags ("0": "Tag", "1": …).
  List<String> strings(String key) => [
    for (final entry in map(key)?.entries ?? const <VdfEntry>[])
      if (entry case VdfEntry(type: BinaryVdf.typeString, value: final Uint8List raw))
        utf8.decode(raw, allowMalformed: true),
  ];

  void add(VdfEntry entry) => entries.add(entry);
}

/// One key and its value: a [VdfMap], an int (int32), or the raw bytes of the rest.
class VdfEntry {
  VdfEntry(this.type, this.key, this.value);

  VdfEntry.string(String name, String text)
    : this(BinaryVdf.typeString, _bytes(name), Uint8List.fromList(utf8.encode(text)));

  VdfEntry.int32(String name, int number) : this(BinaryVdf.typeInt32, _bytes(name), number.toSigned(32));

  VdfEntry.map(String name, VdfMap map) : this(BinaryVdf.typeMap, _bytes(name), map);

  final int type;

  /// The key's bytes as read (UTF-8 in practice).
  final Uint8List key;
  final Object value;

  String get name => utf8.decode(key, allowMalformed: true);

  /// The same value under another key: what renumbering a list of shortcuts changes.
  VdfEntry renamed(String name) => VdfEntry(type, _bytes(name), value);

  static Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int at = 0;

  Never _fail(String why) => throw FormatException('binary VDF: $why', bytes, at);

  int _byte() {
    if (at >= bytes.length) _fail('ends early');
    return bytes[at++];
  }

  Uint8List _take(int count) {
    if (at + count > bytes.length) _fail('ends early');
    final slice = Uint8List.fromList(bytes.sublist(at, at + count));
    at += count;
    return slice;
  }

  Uint8List _cString() {
    final start = at;
    while (at < bytes.length && bytes[at] != 0) {
      at++;
    }
    if (at >= bytes.length) _fail('a text without its end');
    final text = Uint8List.fromList(bytes.sublist(start, at));
    at++;
    return text;
  }

  Uint8List _wideString() {
    final start = at;
    while (at + 1 < bytes.length && (bytes[at] != 0 || bytes[at + 1] != 0)) {
      at += 2;
    }
    if (at + 1 >= bytes.length) _fail('a wide text without its end');
    final text = Uint8List.fromList(bytes.sublist(start, at));
    at += 2;
    return text;
  }

  VdfMap map() {
    final entries = <VdfEntry>[];
    while (true) {
      final type = _byte();
      if (type == BinaryVdf.typeEnd || type == BinaryVdf.typeEndAlternate) return VdfMap(entries, type);
      final key = _cString();
      final Object value = switch (type) {
        BinaryVdf.typeMap => map(),
        BinaryVdf.typeString => _cString(),
        BinaryVdf.typeInt32 => ByteData.sublistView(_take(4)).getInt32(0, Endian.little),
        BinaryVdf.typeFloat32 || BinaryVdf.typePointer || BinaryVdf.typeColor => _take(4),
        BinaryVdf.typeUint64 || BinaryVdf.typeInt64 => _take(8),
        BinaryVdf.typeWideString => _wideString(),
        _ => _fail('unknown type 0x${type.toRadixString(16)}'),
      };
      entries.add(VdfEntry(type, key, value));
    }
  }
}
