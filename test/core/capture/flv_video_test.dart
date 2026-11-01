import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/flv_video.dart';
import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:test/test.dart';

import '../../support/capture_fakes.dart';

/// The NAL unit types of a start-code stream.
List<int> types(Uint8List stream) {
  final found = <int>[];
  for (var index = 0; index + 4 < stream.length; index++) {
    if (stream[index] == 0 && stream[index + 1] == 0 && stream[index + 2] == 0 && stream[index + 3] == 1) {
      found.add(stream[index + 4] & 0x1F);
    }
  }
  return found;
}

void main() {
  test('frames come whole, key frames with the parameter sets, however the pipe cuts them', () {
    final frames = <EncodedFrame>[];
    final reader = FlvVideoReader(frames.add);
    final stream = [
      ...FlvBuilder.header(),
      ...FlvBuilder.metadata(),
      ...FlvBuilder.sequence(),
      ...FlvBuilder.frame([
        [0x09, 0xF0],
        [0x65, 1, 2, 3],
      ], key: true, time: 0),
      ...FlvBuilder.frame([
        [0x41, 4, 5],
      ], key: false, time: 17),
    ];
    // One byte at a time: the worst a pipe can do.
    for (final byte in stream) {
      reader.add([byte]);
    }
    expect(frames, hasLength(2));
    expect(frames.first.key, isTrue);
    expect(types(frames.first.data), [7, 8, 5], reason: 'parameter sets first, the delimiter left out');
    expect(frames.first.data.sublist(0, 9), [0, 0, 0, 1, ...FlvBuilder.sps]);
    expect(frames.last.key, isFalse);
    expect(frames.last.data, [0, 0, 0, 1, 0x41, 4, 5]);
    expect(frames.last.milliseconds, 17);
  });

  test('a key frame with parameter sets of its own gets no others', () {
    final out = FlvVideoReader.annexB(
      Uint8List.fromList([0, 0, 0, 2, 0x67, 1, 0, 0, 0, 2, 0x68, 2, 0, 0, 0, 2, 0x65, 3]),
      parameterSets: [Uint8List.fromList(FlvBuilder.sps)],
    );
    expect(types(out), [7, 8, 5]);
    expect(out.length, 18);
  });

  test('anything but FLV is refused', () {
    expect(() => FlvVideoReader((_) {}).add(Uint8List.fromList(List.filled(20, 1))), throwsFormatException);
  });

  final ffmpeg = Platform.environment['PATH']
      ?.split(Platform.isWindows ? ';' : ':')
      .map((folder) => '$folder/ffmpeg')
      .where((path) => File(path).existsSync())
      .firstOrNull;

  test('ffmpeg\'s own FLV of the Remote Play settings reads as the phone needs it', () async {
    final arguments = [
      '-hide_banner', '-loglevel', 'error', '-nostdin',
      '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=60', '-t', '2.5', '-an',
      '-vf', 'scale=480:270:flags=bilinear,${VideoEncoder.x264.filterTail}',
      ...VideoEncoder.x264.arguments(use: EncodeUse.live, bitRate: 2000000, keyEvery: 60),
      '-flush_packets', '1', '-flvflags', 'no_duration_filesize', '-f', 'flv', 'pipe:1',
    ];
    final process = await Process.start(ffmpeg!, arguments);
    final frames = <EncodedFrame>[];
    final reader = FlvVideoReader(frames.add);
    await process.stdout.forEach(reader.add);
    expect(await process.exitCode, 0);
    expect(frames, hasLength(150));
    final keys = [for (var index = 0; index < frames.length; index++) if (frames[index].key) index];
    expect(keys, [0, 60, 120], reason: 'a key frame every second');
    for (final index in keys) {
      expect(types(frames[index].data).take(2), [7, 8]);
      expect(types(frames[index].data), contains(5));
    }
    expect(types(frames[1].data), everyElement(1), reason: 'no B frames, no delimiters');
    expect(frames.map((frame) => frame.milliseconds).toList(), orderedEquals([...frames.map((frame) => frame.milliseconds)]..sort()));
  }, skip: ffmpeg == null ? 'no ffmpeg on the PATH' : false);
}
