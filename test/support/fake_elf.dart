import 'dart:typed_data';

/// A small 64-bit little-endian ELF whose version needs ask libc.so.6 for [versions]
/// (GLIBC_2.38, ...): an ELF header, .dynstr, .gnu.version_r and their section headers, as
/// much of a real library as the glibc check reads.
Uint8List elfNeeding(List<String> versions, {String library = 'libc.so.6'}) {
  final strings = BytesBuilder()..addByte(0);
  int add(String text) {
    final at = strings.length;
    strings
      ..add(text.codeUnits)
      ..addByte(0);
    return at;
  }

  final file = add(library);
  final names = [for (final version in versions) add(version)];
  final dynstr = strings.toBytes();

  final needs = ByteData(16 + 16 * versions.length);
  needs
    ..setUint16(0, 1, Endian.little) // vn_version
    ..setUint16(2, versions.length, Endian.little) // vn_cnt
    ..setUint32(4, file, Endian.little) // vn_file
    ..setUint32(8, 16, Endian.little) // vn_aux
    ..setUint32(12, 0, Endian.little); // vn_next
  for (var index = 0; index < versions.length; index++) {
    final at = 16 + 16 * index;
    needs
      ..setUint16(at + 6, 2 + index, Endian.little) // vna_other
      ..setUint32(at + 8, names[index], Endian.little) // vna_name
      ..setUint32(at + 12, index == versions.length - 1 ? 0 : 16, Endian.little); // vna_next
  }

  const headerSize = 64;
  final dynstrAt = headerSize;
  final needsAt = dynstrAt + dynstr.length;
  final sectionsAt = (needsAt + needs.lengthInBytes + 7) & ~7;
  final total = sectionsAt + 3 * 64;
  final out = ByteData(total);
  // \x7fELF, ELFCLASS64, ELFDATA2LSB, version 1; ET_DYN, EM_X86_64.
  out
    ..setUint32(0, 0x7f454c46, Endian.big)
    ..setUint8(4, 2)
    ..setUint8(5, 1)
    ..setUint8(6, 1)
    ..setUint16(16, 3, Endian.little)
    ..setUint16(18, 62, Endian.little)
    ..setUint32(20, 1, Endian.little)
    ..setUint64(0x28, sectionsAt, Endian.little)
    ..setUint16(0x34, headerSize, Endian.little)
    ..setUint16(0x3a, 64, Endian.little)
    ..setUint16(0x3c, 3, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(dynstrAt, dynstrAt + dynstr.length, dynstr);
  bytes.setRange(needsAt, needsAt + needs.lengthInBytes, needs.buffer.asUint8List());
  void section(int index, {required int type, required int offset, required int size, int link = 0}) {
    final at = sectionsAt + 64 * index;
    out
      ..setUint32(at + 4, type, Endian.little)
      ..setUint64(at + 0x18, offset, Endian.little)
      ..setUint64(at + 0x20, size, Endian.little)
      ..setUint32(at + 0x28, link, Endian.little);
  }

  section(1, type: 3, offset: dynstrAt, size: dynstr.length); // SHT_STRTAB
  section(2, type: 0x6ffffffe, offset: needsAt, size: needs.lengthInBytes, link: 1); // SHT_GNU_verneed
  return bytes;
}
