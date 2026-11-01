import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:anyps5_desktop/core/capture/remote_play.dart';
import 'package:anyps5_desktop/core/capture/stream_packet.dart';
import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:test/test.dart';

import '../../support/capture_fakes.dart';

/// Sound a test plays into.
class FakeSound implements GameSound {
  SoundSink? sink;
  bool stopped = false;
  @override
  SoundReach get reach => SoundReach.game;
  @override
  Future<void> start(SoundSink sink) async => this.sink = sink;
  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  late List<List<String>> started;
  late List<StreamingProcess> processes;
  late ScreenArea? area;
  late FakeSound sound;
  late List<Uint8List> sent;

  setUp(() {
    started = [];
    processes = [];
    area = const ScreenArea(0, 0, 1920, 1080);
    sound = FakeSound();
    sent = [];
  });

  RemotePlayStream stream() => RemotePlayStream(
    ffmpeg: 'ffmpeg',
    system: HostSystem.windows,
    encoders: EncoderChoice(ffmpeg: 'ffmpeg', system: HostSystem.windows, run: (executable, arguments) async {
      return ProcessResult(1, arguments.contains('libx264') ? 0 : 1, '', '');
    }),
    areaOf: (_) => area,
    soundOf: (_) => sound,
    followEvery: const Duration(milliseconds: 20),
    start: (executable, arguments) async {
      started.add(arguments);
      final process = StreamingProcess();
      processes.add(process);
      return process;
    },
  );

  test('the game\'s picture and sound reach the phone in the Mac\'s packets', () async {
    final play = stream();
    expect(await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll), RemotePlayStart.on);
    final arguments = started.single.join(' ');
    expect(arguments, contains('-video_size 1920x1080 -i desktop'));
    expect(arguments, contains('scale=1280:720:flags=bilinear,format=yuv420p'));
    expect(arguments, contains('-c:v libx264'));
    expect(arguments, contains('-b:v 11059200'));
    expect(arguments, endsWith('-f flv pipe:1'));
    processes.single
      ..write(FlvBuilder.header())
      ..write(FlvBuilder.sequence())
      ..write(FlvBuilder.frame([[0x65, 1, 2]], key: true));
    sound.sink!(Uint8List(SoundChunker.bytes * 2));
    await pumpEventQueue();
    final video = sent.where((packet) => ByteData.sublistView(packet).getUint32(0, Endian.little) == StreamPacket.videoMagic);
    final audio = sent.where((packet) => ByteData.sublistView(packet).getUint32(0, Endian.little) == StreamPacket.audioMagic);
    expect(video, hasLength(1));
    expect(ByteData.sublistView(video.single).getUint16(16, Endian.little), 1, reason: 'a key frame');
    expect(audio, hasLength(2));
    await play.stop();
    expect(processes.single.ended, isTrue);
    expect(sound.stopped, isTrue);
  });

  test('no window: the phone hears there is no game', () async {
    area = null;
    expect(await stream().start(pid: 77, width: 1280, height: 720, send: sent.addAll), RemotePlayStart.noGame);
    expect(started, isEmpty);
  });

  test('a window that moves is recorded again where it is, the frames numbered on', () async {
    final play = stream();
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    processes.last
      ..write(FlvBuilder.header())
      ..write(FlvBuilder.sequence())
      ..write(FlvBuilder.frame([[0x65, 1]], key: true));
    await pumpEventQueue();
    area = const ScreenArea(100, 50, 1280, 720);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(processes.length, greaterThanOrEqualTo(2));
    expect(processes.first.ended, isTrue);
    expect(started.last.join(' '), contains('-offset_x 100 -offset_y 50 -video_size 1280x720'));
    processes.last
      ..write(FlvBuilder.header())
      ..write(FlvBuilder.sequence())
      ..write(FlvBuilder.frame([[0x65, 2]], key: true));
    await pumpEventQueue();
    final numbers = [
      for (final packet in sent)
        if (ByteData.sublistView(packet).getUint32(0, Endian.little) == StreamPacket.videoMagic)
          ByteData.sublistView(packet).getUint32(8, Endian.little),
    ];
    expect(numbers, [1, 2]);
    await play.stop();
  });

  test('asking again for the same size keeps the stream going', () async {
    final play = stream();
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    expect(started, hasLength(1));
    await play.stop();
  });
}
