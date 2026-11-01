import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/stream_packet.dart';
import 'package:test/test.dart';

/// The phone app's reading of a video piece (mobile/lib/stream/stream_packets.dart).
Map<String, Object>? phoneVideo(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 24 ||
      data.getUint32(0, Endian.little) != 0x56525041 ||
      data.getUint16(4, Endian.little) != 1 ||
      data.getUint16(6, Endian.little) != 24) {
    return null;
  }
  final index = data.getUint16(12, Endian.little);
  final count = data.getUint16(14, Endian.little);
  if (count == 0 || index >= count) return null;
  return {
    'number': data.getUint32(8, Endian.little),
    'index': index,
    'count': count,
    'key': data.getUint16(16, Endian.little) & 1 != 0,
    'milliseconds': data.getUint32(20, Endian.little),
    'payload': Uint8List.sublistView(bytes, 24),
  };
}

void main() {
  test('a frame goes in pieces no larger than one datagram, as the phone reads them', () {
    final frame = Uint8List.fromList(List.generate(3000, (index) => index & 0xFF));
    final packets = StreamPacket.video(frame, number: 7, key: true, milliseconds: 1234);
    expect(packets, hasLength(3));
    expect(packets.every((packet) => packet.length <= StreamPacket.largest), isTrue);
    final read = packets.map(phoneVideo).toList();
    expect(read.every((piece) => piece != null), isTrue);
    expect(read.map((piece) => piece!['index']), [0, 1, 2]);
    expect(read.every((piece) => piece!['count'] == 3 && piece['number'] == 7 && piece['key'] == true), isTrue);
    expect(read.first!['milliseconds'], 1234);
    final joined = [for (final piece in read) ...(piece!['payload'] as Uint8List)];
    expect(joined, frame);
  });

  test('the header is the Mac\'s, byte for byte', () {
    final packet = StreamPacket.video(Uint8List.fromList([9, 8]), number: 1, key: false, milliseconds: 2).single;
    expect(packet.sublist(0, 24), [
      0x41, 0x50, 0x52, 0x56, 1, 0, 24, 0, //
      1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 0, 0,
    ]);
    final audio = StreamPacket.audio(Uint8List(4), number: 3, milliseconds: 5);
    expect(audio.sublist(0, 16), [0x41, 0x50, 0x52, 0x41, 1, 0, 16, 0, 3, 0, 0, 0, 5, 0, 0, 0]);
  });

  test('sound goes in 5 ms packets, numbered, timed from the first sample', () {
    final chunker = SoundChunker();
    // 7 ms of sound: one packet, 2 ms kept for the next.
    expect(chunker.add(Uint8List(336 * 4), 1000), hasLength(1));
    final next = chunker.add(Uint8List(200 * 4), 1007);
    expect(next, hasLength(1));
    final data = ByteData.sublistView(next.single);
    expect(data.getUint32(8, Endian.little), 2);
    expect(data.getUint32(12, Endian.little), 7);
    expect(next.single.length, 16 + 960);
    expect(chunker.add(Uint8List(3), 1010), isEmpty);
  });
}
