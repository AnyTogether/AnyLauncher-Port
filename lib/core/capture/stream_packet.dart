import 'dart:typed_data';

/// Remote Play's datagrams, from the launcher to the phone: video frames cut into pieces and
/// sound, little-endian with a magic, a version and the header's size up front, as the pad
/// packets have. On a cable they go as binary messages on the control channel instead. The
/// macOS launcher's StreamPacket.swift, byte for byte: the phone app reads both.
abstract final class StreamPacket {
  /// "APRV" and "APRA".
  static const videoMagic = 0x56525041;
  static const audioMagic = 0x41525041;
  static const version = 1;
  static const videoHeader = 24;
  static const audioHeader = 16;

  /// Small enough for one datagram on any network.
  static const largest = 1200;

  /// Pieces of one frame: magic, version, header size, frame number, piece index and count,
  /// flags (1 = key frame), two bytes kept at zero, milliseconds since the stream began, then
  /// the bytes.
  static List<Uint8List> video(Uint8List frame, {required int number, required bool key, required int milliseconds}) {
    const room = largest - videoHeader;
    final count = frame.isEmpty ? 1 : (frame.length + room - 1) ~/ room;
    return [
      for (var index = 0; index < count; index++)
        () {
          final start = index * room;
          final end = start + room < frame.length ? start + room : frame.length;
          final packet = Uint8List(videoHeader + end - start);
          ByteData.sublistView(packet)
            ..setUint32(0, videoMagic, Endian.little)
            ..setUint16(4, version, Endian.little)
            ..setUint16(6, videoHeader, Endian.little)
            ..setUint32(8, number & 0xFFFFFFFF, Endian.little)
            ..setUint16(12, index, Endian.little)
            ..setUint16(14, count, Endian.little)
            ..setUint16(16, key ? 1 : 0, Endian.little)
            ..setUint16(18, 0, Endian.little)
            ..setUint32(20, milliseconds & 0xFFFFFFFF, Endian.little);
          packet.setRange(videoHeader, packet.length, frame, start);
          return packet;
        }(),
    ];
  }

  /// Sound: magic, version, header size, packet number, milliseconds, then 16-bit stereo
  /// samples at 48 kHz.
  static Uint8List audio(Uint8List samples, {required int number, required int milliseconds}) {
    final packet = Uint8List(audioHeader + samples.length);
    ByteData.sublistView(packet)
      ..setUint32(0, audioMagic, Endian.little)
      ..setUint16(4, version, Endian.little)
      ..setUint16(6, audioHeader, Endian.little)
      ..setUint32(8, number & 0xFFFFFFFF, Endian.little)
      ..setUint32(12, milliseconds & 0xFFFFFFFF, Endian.little);
    packet.setRange(audioHeader, packet.length, samples);
    return packet;
  }
}

/// The game's sound as share play and Remote Play send it: 16-bit stereo at 48 kHz cut into
/// 5 ms audio packets, numbered, with milliseconds since the first sample. The macOS launcher's
/// SoundChunker.swift.
class SoundChunker {
  /// 5 ms at 48 kHz.
  static const frames = 240;
  static const bytes = frames * 4;

  final _pending = BytesBuilder(copy: true);
  int _number = 0;
  int? _start;

  /// Interleaved 16-bit stereo (little-endian) heard at [milliseconds] on any clock that goes
  /// forward; the whole packets it completes.
  List<Uint8List> add(Uint8List samples, int milliseconds) {
    final begin = _start ??= milliseconds;
    _pending.add(samples);
    if (_pending.length < bytes) return const [];
    final all = _pending.takeBytes();
    final packets = <Uint8List>[];
    var offset = 0;
    while (all.length - offset >= bytes) {
      _number = (_number + 1) & 0xFFFFFFFF;
      packets.add(
        StreamPacket.audio(
          Uint8List.sublistView(all, offset, offset + bytes),
          number: _number,
          milliseconds: milliseconds - begin < 0 ? 0 : milliseconds - begin,
        ),
      );
      offset += bytes;
    }
    if (offset < all.length) _pending.add(Uint8List.sublistView(all, offset));
    return packets;
  }
}
