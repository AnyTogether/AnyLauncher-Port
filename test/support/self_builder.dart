import 'dart:math';
import 'dart:typed_data';

/// One program header of a synthetic SELF and where its bytes sit in the container.
class FakeSegment {
  FakeSegment({
    required this.type,
    this.flags = 4,
    this.vaddr = 0,
    required this.fileSize,
    int? memorySize,
    this.align = 0x10,
    this.elfOffset = 0,
    this.at,
    this.recorded = true,
    this.recordIndex,
    this.encrypted = false,
    this.fill,
  }) : memorySize = memorySize ?? fileSize;

  final int type;
  final int flags;
  final int vaddr;
  final int fileSize;
  final int memorySize;
  final int align;

  /// The stale p_offset the inner ELF carries.
  final int elfOffset;

  /// Where the segment's bytes are in the container; null leaves them out.
  final int? at;

  /// Whether a SELF record with the has-segment flag names this header.
  final bool recorded;

  /// The header index the record names, when it should name another one.
  final int? recordIndex;

  /// Random bytes (looks encrypted) instead of a low-entropy pattern.
  final bool encrypted;

  /// A byte to fill with, for the pattern.
  final int? fill;
}

const ptLoad = 1;
const ptDynamic = 2;
const ptNote = 4;
const ptTls = 7;
const ptGnuEhFrame = 0x6474E550;
const ptSceDynlibData = 0x61000000;
const ptSceProcParam = 0x61000001;

/// Builds a decrypted SELF: magic, the segment records from 0x40, the inner ELF header and its
/// program headers after them, and the segment bytes at their container offsets.
Uint8List buildSelf(
  List<FakeSegment> segments, {
  int magic = 0x1D3D154F,
  int? length,
  int seed = 1,
  List<(int flags, int offset, int size)>? extraRecords,
}) {
  final random = Random(seed);
  final records = <(int, int, int)>[];
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    if (segment.at == null || segment.fileSize == 0) continue;
    final target = segment.recordIndex ?? index;
    final flags = segment.recorded ? (target << 20) | 0x800 | 0x2 : 0x2;
    records.add((flags, segment.at!, segment.fileSize));
  }
  records.addAll(extraRecords ?? const []);
  final inner = 0x40 + records.length * 0x20 + 0x20;
  final table = inner + 0x40;
  var end = max(0x400, table + segments.length * 56);
  for (final segment in segments) {
    if (segment.at != null) end = max(end, segment.at! + segment.fileSize);
  }
  final data = Uint8List(length ?? end);
  void put(int at, int size, int value) {
    for (var byte = 0; byte < size; byte++) {
      if (at + byte < data.length) data[at + byte] = (value >>> (8 * byte)) & 0xFF;
    }
  }

  put(0, 4, magic);
  put(4, 4, 0x00010112);
  for (var index = 0; index < records.length; index++) {
    final (flags, offset, size) = records[index];
    final at = 0x40 + index * 0x20;
    put(at, 8, flags);
    put(at + 8, 8, offset);
    put(at + 16, 8, size);
    put(at + 24, 8, size);
  }
  // ELF64 little-endian header.
  data.setRange(inner, inner + 8, [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 9]);
  put(inner + 0x10, 2, 0xFE10);
  put(inner + 0x12, 2, 0x3E);
  put(inner + 0x14, 4, 1);
  put(inner + 0x18, 8, 0x1230);
  put(inner + 0x20, 8, 0x40);
  put(inner + 0x28, 8, 0x5555);
  put(inner + 0x34, 2, 0x40);
  put(inner + 0x36, 2, 56);
  put(inner + 0x38, 2, segments.length);
  put(inner + 0x3A, 2, 0x40);
  put(inner + 0x3C, 2, 7);
  put(inner + 0x3E, 2, 3);
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final at = table + index * 56;
    put(at, 4, segment.type);
    put(at + 4, 4, segment.flags);
    put(at + 8, 8, segment.elfOffset);
    put(at + 16, 8, segment.vaddr);
    put(at + 24, 8, segment.vaddr);
    put(at + 32, 8, segment.fileSize);
    put(at + 40, 8, segment.memorySize);
    put(at + 48, 8, segment.align);
  }
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final start = segment.at;
    if (start == null) continue;
    for (var byte = 0; byte < segment.fileSize && start + byte < data.length; byte++) {
      data[start + byte] = segment.encrypted
          ? random.nextInt(256)
          : (segment.fill ?? ((byte ~/ 3 + index * 17) % 23 + 1)) & 0xFF;
    }
  }
  return data;
}

/// A container shaped like a game's eboot: code and data loads, a recorded dynlib data
/// segment without a vaddr, a dynamic segment inside the data load, TLS, eh_frame, proc param,
/// a trailing note and an empty load.
Uint8List typicalSelf({int seed = 1}) => buildSelf(
  [
    FakeSegment(type: ptLoad, flags: 5, vaddr: 0, fileSize: 0x2345, align: 0x4000, elfOffset: 0, at: 0x500),
    FakeSegment(
      type: ptLoad,
      flags: 6,
      vaddr: 0x8000,
      fileSize: 0x1200,
      memorySize: 0x3000,
      align: 0x4000,
      elfOffset: 0x4000,
      at: 0x2850,
    ),
    FakeSegment(type: ptDynamic, vaddr: 0x8100, fileSize: 0x80, align: 8, elfOffset: 0x4100, at: null),
    FakeSegment(type: ptTls, vaddr: 0x8400, fileSize: 0x40, memorySize: 0x100, align: 0x10, elfOffset: 0x4400),
    FakeSegment(type: ptGnuEhFrame, vaddr: 0x2000, fileSize: 0x100, align: 4, elfOffset: 0x2000),
    FakeSegment(type: ptSceProcParam, vaddr: 0x8800, fileSize: 0x20, align: 8, elfOffset: 0x4800),
    FakeSegment(type: ptSceDynlibData, vaddr: 0, fileSize: 0x300, align: 0x10, elfOffset: 0x6000, at: 0x3a60),
    FakeSegment(type: ptNote, vaddr: 0, fileSize: 0x24, align: 4, elfOffset: 0x6400),
    FakeSegment(type: 0x6FFFFF01, vaddr: 0, fileSize: 0x18, align: 0x10, elfOffset: 0x6500),
    FakeSegment(type: ptLoad, flags: 6, vaddr: 0x10000, fileSize: 0, memorySize: 0x4000, align: 0x4000),
  ],
  seed: seed,
  length: 0x3a60 + 0x300 + 0x18,
);
