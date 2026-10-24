import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'binary.dart';

/// Why a container cannot be unwrapped, worded as tools/unwrap_self.py words it.
class SelfRefused implements Exception {
  SelfRefused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// A container broken in a way the reference script does not refuse but fails on (Python's
/// struct module raises): an unusable result either way.
class SelfMalformed extends SelfRefused {
  SelfMalformed(super.reason);
}

/// Turns a decrypted SELF or fSELF container into the clean ELF the relinker reads: the Dart form
/// of upstream's tools/unwrap_self.py, which documents the container layout. The two write the same
/// bytes (the test suite compares them on synthetic containers when python3 is present).
///
/// Header values are kept as [BigInt] so that every comparison and sum is the exact arithmetic
/// Python does on them, whatever a broken container holds; the file's bytes are plain lists.
abstract final class SelfUnwrap {
  static const selfMagic = 0x1D3D154F;
  static const selfMagicKernel = 0xEEF51454;
  static const recordOffset = 0x40;
  static const recordSize = 0x20;
  static const recordHasSegment = 0x800;
  static const recordSegmentShift = 20;
  static const firstRegion = 0x400;
  static const maxAlignmentPadding = 64 * 1024 * 1024;
  static const ptLoad = 1;
  static const ptNote = 4;
  static const entropyLimit = 7.5;
  static const entropySample = 0x10000;

  /// Whether the file starts with a SELF container's magic.
  static bool isContainer(String path) {
    final head = Binary.head(path, 4);
    if (head.length != 4) return false;
    final magic = Binary.u32(head, 0);
    return magic == selfMagic || magic == selfMagicKernel;
  }

  /// Unwraps the container at [input] into [output]; returns the ELF's size. A refusal leaves an
  /// existing output as it was.
  static int unwrapFile(String input, String output) {
    final source = File(input);
    final destination = File(output);
    if (source.absolute.path == destination.absolute.path ||
        (destination.existsSync() && FileSystemEntity.identicalSync(input, output)) ||
        _resolved(input) == _resolved(output)) {
      throw SelfRefused('output aliases the input container');
    }
    final result = unwrap(source.readAsBytesSync());
    destination.parent.createSync(recursive: true);
    destination.writeAsBytesSync(result, flush: true);
    return result.length;
  }

  static String _resolved(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      try {
        final file = File(path);
        return '${file.parent.resolveSymbolicLinksSync()}${Platform.pathSeparator}${file.uri.pathSegments.last}';
      } on FileSystemException {
        return File(path).absolute.path;
      }
    }
  }

  /// The clean ELF of a container's bytes.
  static Uint8List unwrap(Uint8List data) {
    if (data.length < firstRegion) throw SelfRefused('file is smaller than the SELF header area');
    final magic = Binary.u32(data, 0);
    if (magic != selfMagic && magic != selfMagicKernel) {
      throw SelfRefused('not a SELF container (magic 0x${magic.toRadixString(16)})');
    }
    final records = _readRecords(data);
    final elf = _parseElf(data);
    final headers = elf.headers;
    _placeSegments(data, headers, records);
    _checkDecrypted(data, headers);

    final regions = <_Region>[];
    final loadRegions = <int, _Region>{};
    for (final header in headers) {
      if (header.type == ptLoad && header.size != BigInt.zero) {
        final region = _Region(header.source, header.size, header.vaddr, header.align);
        regions.add(region);
        loadRegions[header.index] = region;
      }
    }

    _Region? regionFor(BigInt offset, BigInt size) {
      for (final region in regions) {
        if (region.old <= offset && offset + size <= region.old + region.size) return region;
      }
      return null;
    }

    for (final header in headers) {
      if (header.type == ptLoad || header.size == BigInt.zero) continue;
      if (regionFor(header.source, header.size) == null) {
        regions.add(_Region(header.source, header.size, header.vaddr, header.align));
      }
    }

    // Python's sort is stable: regions at the same container offset keep their order.
    final ordered = List<_Region>.generate(regions.length, (index) => regions[index]);
    final positions = {for (var index = 0; index < regions.length; index++) regions[index]: index};
    ordered.sort((a, b) {
      final byOffset = a.old.compareTo(b.old);
      return byOffset != 0 ? byOffset : positions[a]!.compareTo(positions[b]!);
    });
    // Python sorts the list in place, so later lookups walk it in this order.
    regions
      ..clear()
      ..addAll(ordered);

    final programOffset = elf.programOffset;
    var cursor = _max(BigInt.from(firstRegion), programOffset + BigInt.from(headers.length * 56));
    var padding = BigInt.zero;
    for (final region in regions) {
      final alignment = region.align != BigInt.zero && (region.align & (region.align - BigInt.one)) == BigInt.zero
          ? region.align
          : BigInt.one;
      final placed = cursor + (region.vaddr - cursor) % alignment;
      padding += placed - cursor;
      region.fresh = placed;
      cursor = placed + region.size;
    }

    var emptyEnd = cursor;
    for (final header in headers) {
      if (header.type == ptLoad && header.size == BigInt.zero) {
        emptyEnd = _max(emptyEnd, header.vaddr % _max(header.align, BigInt.one));
      }
    }
    padding += emptyEnd - cursor;
    if (padding > BigInt.from(maxAlignmentPadding)) {
      throw SelfRefused('segment alignment requires more than $maxAlignmentPadding bytes of output padding');
    }
    cursor = emptyEnd;

    var result = Uint8List(cursor.toInt());
    for (final region in regions) {
      // Normally a plain copy. A segment without a vaddr that carries a negative shift is read
      // the way Python's slices read it, from the end, and a shorter slice shrinks the output.
      final bytes = _pySlice(data, region.old, region.old + region.size);
      result = _pyAssign(result, region.fresh, region.fresh + region.size, bytes);
    }

    for (final header in headers) {
      if (header.size == BigInt.zero && (header.type == ptLoad || header.source == BigInt.zero)) {
        header.fresh = header.type == ptLoad ? header.vaddr % _max(header.align, BigInt.one) : BigInt.zero;
        continue;
      }
      final host = header.type == ptLoad ? header : header.host;
      var region = host != null ? loadRegions[host.index] : null;
      region ??= regionFor(header.source, header.size);
      header.fresh = region == null ? header.source : region.fresh + (header.source - region.old);
      if (header.fresh + header.size > BigInt.from(result.length)) {
        throw SelfRefused('segment ${header.index} escaped the output');
      }
    }

    result = _pyAssign(result, BigInt.zero, BigInt.from(0x40), elf.header);
    if (result.length < 0x40) throw SelfMalformed('the output is shorter than an ELF header');
    Binary.put64(result, 0x28, 0);
    Binary.put16(result, 0x3C, 0);
    Binary.put16(result, 0x3E, 0);
    final table = programOffset.toInt();
    for (final header in headers) {
      final at = table + header.index * 56;
      // Python's struct.pack_into raises on these instead of refusing.
      if (at + 56 > result.length) throw SelfMalformed('program header ${header.index} is outside the output');
      if (header.fresh < BigInt.zero) throw SelfMalformed('segment ${header.index} has a negative offset');
      Binary.put32(result, at, header.type);
      Binary.put32(result, at + 4, header.flags);
      Binary.put64(result, at + 8, _bits(header.fresh));
      Binary.put64(result, at + 16, _bits(header.vaddr));
      Binary.put64(result, at + 24, _bits(header.vaddr));
      Binary.put64(result, at + 32, _bits(header.size));
      Binary.put64(result, at + 40, _bits(header.memory));
      Binary.put64(result, at + 48, _bits(header.align));
    }
    return result;
  }

  /// `data[start:end]` as Python reads it.
  static Uint8List _pySlice(Uint8List data, BigInt start, BigInt end) {
    final from = _pyIndex(start, data.length);
    final to = _pyIndex(end, data.length);
    return to <= from ? Uint8List(0) : Uint8List.sublistView(data, from, to);
  }

  /// `result[start:end] = bytes` as Python does it on a bytearray, resizing it when the lengths
  /// differ.
  static Uint8List _pyAssign(Uint8List result, BigInt start, BigInt end, Uint8List bytes) {
    final from = _pyIndex(start, result.length);
    final to = math.max(from, _pyIndex(end, result.length));
    if (to - from == bytes.length) {
      result.setRange(from, to, bytes);
      return result;
    }
    return Uint8List.fromList([...result.sublist(0, from), ...bytes, ...result.sublist(to)]);
  }

  static int _pyIndex(BigInt index, int length) {
    var value = index < BigInt.zero ? index + BigInt.from(length) : index;
    if (value < BigInt.zero) value = BigInt.zero;
    if (value > BigInt.from(length)) value = BigInt.from(length);
    return value.toInt();
  }

  static final _mask64 = (BigInt.one << 64) - BigInt.one;

  static BigInt _big64(List<int> data, int at) =>
      BigInt.from(Binary.u32(data, at)) | (BigInt.from(Binary.u32(data, at + 4)) << 32);

  static int _bits(BigInt value) => (value & _mask64).toUnsigned(64).toSigned(64).toInt();

  static BigInt _max(BigInt a, BigInt b) => a >= b ? a : b;
  static BigInt _min(BigInt a, BigInt b) => a <= b ? a : b;

  static double entropy(List<int> data) {
    if (data.isEmpty) return 0;
    final counts = List<int>.filled(256, 0);
    for (final byte in data) {
      counts[byte]++;
    }
    final length = data.length;
    var total = 0.0;
    for (final count in counts) {
      if (count == 0) continue;
      final share = count / length;
      total -= share * (math.log(share) / math.ln2);
    }
    return total;
  }

  static List<_Record> _readRecords(Uint8List data) {
    final records = <_Record>[];
    var offset = recordOffset;
    final length = BigInt.from(data.length);
    while (offset + recordSize <= firstRegion) {
      final flags = _big64(data, offset);
      final segment = _big64(data, offset + 8);
      final size = _big64(data, offset + 16);
      final sizeAgain = _big64(data, offset + 24);
      if (size == BigInt.zero || size != sizeAgain) break;
      if (segment >= length || segment < BigInt.from(0x350) || segment % BigInt.from(0x10) != BigInt.zero) break;
      if (size > length) break;
      records.add(_Record(flags, segment, size));
      offset += recordSize;
    }
    return records;
  }

  static int _findElf(Uint8List data) {
    for (var start = 0; start + 4 <= data.length; start++) {
      if (data[start] == 0x7F && data[start + 1] == 0x45 && data[start + 2] == 0x4C && data[start + 3] == 0x46) {
        return start;
      }
    }
    return -1;
  }

  static _Elf _parseElf(Uint8List data) {
    final inner = _findElf(data);
    if (inner < 0) throw SelfRefused('no inner ELF header');
    if (inner + 0x40 > data.length) throw SelfRefused('inner ELF header is truncated');
    final header = Uint8List.fromList(data.sublist(inner, inner + 0x40));
    if (header[4] != 2 || header[5] != 1) throw SelfRefused('inner ELF is not 64-bit little-endian');
    final programOffset = _big64(header, 0x20);
    final entrySize = Binary.u16(header, 0x36);
    final count = Binary.u16(header, 0x38);
    if (entrySize != 56 || count == 0) {
      throw SelfRefused('program header table is $count entries of $entrySize bytes');
    }
    if (programOffset < BigInt.from(header.length)) {
      throw SelfRefused('ELF program header table overlaps the ELF header');
    }
    if (BigInt.from(inner) + programOffset + BigInt.from(count * entrySize) > BigInt.from(data.length)) {
      throw SelfRefused('ELF program header table does not fit the file');
    }
    final table = inner + programOffset.toInt();
    final headers = <_Header>[];
    final limit = BigInt.one << 64;
    for (var index = 0; index < count; index++) {
      final at = table + index * 56;
      final kind = Binary.u32(data, at);
      final flags = Binary.u32(data, at + 4);
      final fileOffset = _big64(data, at + 8);
      final vaddr = _big64(data, at + 16);
      final fileSize = _big64(data, at + 32);
      final memorySize = _big64(data, at + 40);
      final alignment = _big64(data, at + 48);
      if (kind == ptLoad) {
        if (fileSize > memorySize) throw SelfRefused('segment $index file size exceeds memory size');
        if (alignment != BigInt.zero && (alignment & (alignment - BigInt.one)) != BigInt.zero) {
          throw SelfRefused('segment $index alignment is not a power of two');
        }
        if (memorySize > limit - vaddr) throw SelfRefused('segment $index memory range exceeds ELF64');
      }
      headers.add(_Header(index, kind, flags, fileOffset, vaddr, fileSize, memorySize, alignment));
    }
    return _Elf(inner, header, programOffset, headers);
  }

  static void _placeSegments(Uint8List data, List<_Header> headers, List<_Record> records) {
    final length = BigInt.from(data.length);
    final loads = headers.where((header) => header.type == ptLoad).toList();
    final used = <int>{};
    final placed = <int>{};
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      final target = record.flags >> recordSegmentShift;
      if ((record.flags & BigInt.from(recordHasSegment)) != BigInt.zero &&
          target < BigInt.from(headers.length) &&
          !placed.contains(target.toInt()) &&
          headers[target.toInt()].size == record.size) {
        headers[target.toInt()].source = record.segment;
        placed.add(target.toInt());
        used.add(index);
      }
    }
    final recorded = headers
        .where((header) => placed.contains(header.index) && header.vaddr == BigInt.zero && header.type != ptLoad)
        .toList();
    if (recorded.isNotEmpty) {
      // Python's max keeps the first of equal keys.
      var last = recorded.first;
      for (final header in recorded.skip(1)) {
        if (header.offset > last.offset) last = header;
      }
      var cursor = last.source + last.size;
      final trailing = headers
          .where(
            (header) =>
                !placed.contains(header.index) &&
                header.vaddr == BigInt.zero &&
                header.type != ptLoad &&
                header.size != BigInt.zero &&
                header.offset > last.offset,
          )
          .toList();
      _stableSort(trailing, (a, b) => a.offset.compareTo(b.offset));
      for (final header in trailing) {
        placed.add(header.index);
        if (header.type == ptNote) {
          header.source = BigInt.zero;
          header.size = BigInt.zero;
          continue;
        }
        header.source = cursor;
        cursor += header.size;
        if (cursor > length) {
          header.source = BigInt.zero;
          header.size = BigInt.zero;
        }
      }
    }
    for (final header in loads) {
      if (header.size == BigInt.zero || placed.contains(header.index)) continue;
      for (var index = 0; index < records.length; index++) {
        if (used.contains(index)) continue;
        if (records[index].size == header.size) {
          used.add(index);
          header.source = records[index].segment;
          break;
        }
      }
    }

    _Header? loadFor(BigInt vaddr, BigInt size) {
      _Header? found;
      for (final header in loads) {
        final end = header.vaddr + header.memory;
        if (header.memory != BigInt.zero &&
            header.vaddr <= vaddr &&
            (vaddr < end || (size == BigInt.zero && vaddr == end))) {
          found = header;
        }
      }
      return found;
    }

    // (offset in the ELF, shift to the container offset) of the last placed segment.
    (BigInt, BigInt)? tail;
    for (final header in headers) {
      if (header.type == ptLoad) continue;
      if (placed.contains(header.index)) {
        if (header.size != BigInt.zero && (tail == null || header.offset > tail.$1)) {
          tail = (header.offset, header.source - header.offset);
        }
        continue;
      }
      if (header.vaddr != BigInt.zero) {
        final host = loadFor(header.vaddr, header.size);
        if (host == null) {
          if (header.size == BigInt.zero) {
            header.source = BigInt.zero;
            continue;
          }
          throw SelfRefused('segment ${header.index} vaddr 0x${header.vaddr.toRadixString(16)} is in no PT_LOAD');
        }
        final offset = header.vaddr - host.vaddr;
        if (header.size != BigInt.zero && (offset > host.size || header.size > host.size - offset)) {
          throw SelfRefused('segment ${header.index} does not fit the file-backed range of PT_LOAD ${host.index}');
        }
        if (host.size == BigInt.zero || offset > host.size) {
          header.source = BigInt.zero;
          continue;
        }
        header.host = host;
        header.source = host.source + offset;
        if (tail == null || header.offset > tail.$1) {
          tail = (header.offset, header.source - header.offset);
        }
      } else if (header.size != BigInt.zero) {
        header.source = header.offset + (tail?.$2 ?? BigInt.zero);
        if (header.source > length) header.source = length;
        final keep = _max(BigInt.zero, length - header.source);
        header.size = _min(header.size, keep);
        header.memory = _min(header.memory, keep);
      }
    }

    for (final header in headers) {
      if (header.type == ptLoad && header.size == BigInt.zero) continue;
      if (header.source > length || header.size > length - header.source) {
        throw SelfRefused('segment ${header.index} does not fit the file');
      }
    }
  }

  static void _checkDecrypted(Uint8List data, List<_Header> headers) {
    final encrypted = <String>[];
    final loaded = headers.where((header) => header.type == ptLoad && header.size != BigInt.zero).toList();
    for (final header in loaded) {
      final start = header.source.toInt();
      final end = start + math.min<int>(header.size.toInt(), entropySample);
      final value = entropy(Uint8List.sublistView(data, start, end));
      if (value >= entropyLimit) {
        encrypted.add(
          'segment ${header.index} at 0x${header.source.toRadixString(16)} '
          '(${value.toStringAsFixed(2)} bits per byte)',
        );
      }
    }
    if (encrypted.isNotEmpty && encrypted.length == loaded.length) {
      throw SelfRefused('every load segment looks encrypted: ${encrypted.join(', ')}');
    }
  }

  /// List.sort is not stable; Python's sorted is.
  static void _stableSort<T>(List<T> list, int Function(T, T) compare) {
    final indexed = [for (var index = 0; index < list.length; index++) (index, list[index])];
    indexed.sort((a, b) {
      final order = compare(a.$2, b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
    for (var index = 0; index < list.length; index++) {
      list[index] = indexed[index].$2;
    }
  }
}

class _Record {
  _Record(this.flags, this.segment, this.size);
  final BigInt flags;
  final BigInt segment;
  final BigInt size;
}

class _Header {
  _Header(this.index, this.type, this.flags, this.offset, this.vaddr, this.size, this.memory, this.align)
    : source = offset;
  final int index;
  final int type;
  final int flags;
  final BigInt offset;
  final BigInt vaddr;
  BigInt size;
  BigInt memory;
  final BigInt align;
  BigInt source;
  BigInt fresh = BigInt.zero;
  _Header? host;
}

class _Region {
  _Region(this.old, this.size, this.vaddr, this.align);
  final BigInt old;
  final BigInt size;
  final BigInt vaddr;
  final BigInt align;
  BigInt fresh = BigInt.zero;
}

class _Elf {
  _Elf(this.inner, this.header, this.programOffset, this.headers);
  final int inner;
  final Uint8List header;
  final BigInt programOffset;
  final List<_Header> headers;
}
