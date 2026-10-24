import 'binary.dart';

/// Turns a decrypted SELF or fSELF container into the clean ELF the relinker reads.
abstract final class SelfUnwrap {
  static const selfMagic = 0x1D3D154F;
  static const selfMagicKernel = 0xEEF51454;

  /// Whether the file starts with a SELF container's magic.
  static bool isContainer(String path) {
    final head = Binary.head(path, 4);
    if (head.length != 4) return false;
    final magic = Binary.u32(head, 0);
    return magic == selfMagic || magic == selfMagicKernel;
  }
}
