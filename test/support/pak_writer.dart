import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/unreal/unreal_pak.dart';

/// A file to put in a test pak: stored, or compressed with zlib.
typedef PakFile = ({String path, List<int> data, bool zlib});

/// Writes .pak files the way Unreal does, for the tests: the old index (version 8) or the
/// encoded entries and full directory index of 4.26 and later (version 11). The same writer as
/// the Mac launcher's tests (UnrealPakTests.swift).
class PakWriter {
  PakWriter({this.version = 11, this.mount = '../../../', required this.files, this.encryptedIndex = false});

  final int version;
  final String mount;
  final List<PakFile> files;
  final bool encryptedIndex;

  static List<int> le32(int value) =>
      (ByteData(4)..setUint32(0, value & 0xFFFFFFFF, Endian.little)).buffer.asUint8List();
  static List<int> le64(int value) => (ByteData(8)..setInt64(0, value, Endian.little)).buffer.asUint8List();

  static List<int> string(String text) {
    final bytes = utf8.encode(text);
    return [...le32(bytes.length + 1), ...bytes, 0];
  }

  /// Raw deflate in a zlib header, and a checksum of zeros the reader does not look at.
  static List<int> zlib(List<int> data) => [0x78, 0x9C, ...ZLibEncoder(raw: true).convert(data), 0, 0, 0, 0];

  /// The header before a file's bytes, and the old index's entry: the same fields.
  List<int> entry({
    required int offset,
    required int size,
    required int uncompressed,
    required int method,
    required List<(int, int)> blocks,
  }) => [
    ...le64(offset),
    ...le64(size),
    ...le64(uncompressed),
    ...le32(method),
    ...List.filled(20, 0),
    if (method != 0) ...[
      ...le32(blocks.length),
      for (final (start, end) in blocks) ...[...le64(start), ...le64(end)],
    ],
    0,
    ...le32(method != 0 ? 65536 : 0),
  ];

  void write(String path) {
    final pak = <int>[];
    final located = <({String path, int offset, int size, int uncompressed, int method, List<(int, int)> blocks})>[];
    for (final file in files) {
      final offset = pak.length;
      final stored = file.zlib ? zlib(file.data) : file.data;
      final method = file.zlib ? 1 : 0;
      final headerLength = entry(
        offset: 0,
        size: 0,
        uncompressed: 0,
        method: method,
        blocks: file.zlib ? [(0, 0)] : [],
      ).length;
      final blocks = file.zlib ? [(headerLength, headerLength + stored.length)] : <(int, int)>[];
      pak
        ..addAll(
          entry(offset: offset, size: stored.length, uncompressed: file.data.length, method: method, blocks: blocks),
        )
        ..addAll(stored);
      located.add((
        path: file.path,
        offset: offset,
        size: stored.length,
        uncompressed: file.data.length,
        method: method,
        blocks: blocks,
      ));
    }
    final index = [...string(mount)];
    if (version < 10) {
      index.addAll(le32(located.length));
      for (final file in located) {
        index
          ..addAll(string(file.path))
          ..addAll(
            entry(
              offset: file.offset,
              size: file.size,
              uncompressed: file.uncompressed,
              method: file.method,
              blocks: file.blocks,
            ),
          );
      }
    } else {
      final encoded = <int>[];
      final locations = <String, int>{};
      for (final file in located) {
        locations[file.path] = encoded.length;
        var bits = (1 << 31) | (1 << 30) | (1 << 29) | (file.method << 23);
        if (file.method != 0) bits |= file.blocks.length << 6 | 32;
        encoded
          ..addAll(le32(bits))
          ..addAll(le32(file.offset))
          ..addAll(le32(file.uncompressed));
        if (file.method != 0) encoded.addAll(le32(file.size));
      }
      final folders = <String, List<String>>{};
      for (final file in located) {
        final slash = file.path.lastIndexOf('/');
        folders.putIfAbsent(slash < 0 ? '/' : file.path.substring(0, slash + 1), () => []).add(file.path);
      }
      final directory = <int>[...le32(folders.length)];
      for (final MapEntry(key: folder, value: paths) in folders.entries) {
        directory
          ..addAll(string(folder))
          ..addAll(le32(paths.length));
        for (final path in paths) {
          directory
            ..addAll(string(folder == '/' ? path : path.substring(folder.length)))
            ..addAll(le32(locations[path]!));
        }
      }
      final directoryOffset = pak.length;
      pak.addAll(directory);
      index
        ..addAll(le32(located.length))
        ..addAll(le64(0))
        ..addAll(le32(0))
        ..addAll(le32(1))
        ..addAll(le64(directoryOffset))
        ..addAll(le64(directory.length))
        ..addAll(List.filled(20, 0))
        ..addAll(le32(encoded.length))
        ..addAll(encoded)
        ..addAll(le32(0));
    }
    final indexOffset = pak.length;
    pak.addAll(index);
    if (version >= 7) pak.addAll(List.filled(16, 0));
    pak
      ..add(encryptedIndex ? 1 : 0)
      ..addAll(le32(UnrealPak.magic))
      ..addAll(le32(version))
      ..addAll(le64(indexOffset))
      ..addAll(le64(index.length))
      ..addAll(List.filled(20, 0));
    if (version >= 8) {
      for (final name in ['Zlib', '', '', '', '']) {
        final bytes = utf8.encode(name);
        pak
          ..addAll(bytes)
          ..addAll(List.filled(32 - bytes.length, 0));
      }
    }
    File(path).writeAsBytesSync(pak);
  }
}
