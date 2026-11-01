import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('steady sound', () {
    late int now;
    late List<Uint8List> out;
    late SteadyPcm steady;

    setUp(() {
      now = 0;
      out = [];
      steady = SteadyPcm(out.add, microseconds: () => now);
    });

    int bytes(int milliseconds) => SteadyPcm.bytesPerSecond * milliseconds ~/ 1000;

    test('what comes goes on as time passes', () {
      steady.add(Uint8List(bytes(20)));
      now = 10000;
      steady.tick();
      expect(steady.written, bytes(10));
      now = 20000;
      steady.tick();
      expect(steady.written, bytes(20));
      expect(steady.waiting, 0);
    });

    test('silence fills a gap longer than the cushion, so the sound keeps pace', () {
      steady.add(Uint8List(0));
      now = 1000000;
      steady.tick();
      expect(steady.written, bytes(1000) - SteadyPcm.cushion);
      expect(out.every((chunk) => chunk.every((byte) => byte == 0)), isTrue);
      expect(steady.written % 4, 0);
    });

    test('a backlog is cut short and never makes the sound late', () {
      steady.add(Uint8List(bytes(1000)));
      now = 20000;
      steady.tick();
      expect(steady.waiting, lessThanOrEqualTo(SteadyPcm.keep));
      expect(steady.waiting % 4, 0);
    });

    test('a frame cut in two by the pipe waits for its other half', () {
      steady.add(Uint8List(6));
      now = 1000;
      steady.tick();
      expect(steady.written, 4);
      expect(steady.waiting, 2);
    });
  });

  group('PulseAudio', () {
    const listing = '''
Sink Input #41
	Driver: protocol-native.c
	Properties:
		application.name = "Firefox"
		application.process.id = "900"
Sink Input #57
	Driver: PipeWire
	Properties:
		media.name = "Playback"
		application.process.id = "4321"
''';

    test('the game\'s own stream is found among the sink inputs', () {
      expect(PulseGameSound.sinkInputOf(listing, {4321}), 57);
      expect(PulseGameSound.sinkInputOf(listing, {1, 2}), isNull);
      expect(PulseGameSound.sinkInputOf('', {4321}), isNull);
    });

    test('parec records the game\'s stream, else the output\'s monitor', () {
      expect(PulseGameSound.parecArguments(57), contains('--monitor-stream=57'));
      expect(PulseGameSound.parecArguments(null), contains('--device=@DEFAULT_MONITOR@'));
      expect(PulseGameSound.parecArguments(null), containsAll(['--format=s16le', '--rate=48000', '--channels=2']));
      expect(PulseGameSound.ffmpegArguments().join(' '), contains('-f pulse -fragment_size 3840 -i @DEFAULT_MONITOR@ -f s16le -ac 2 -ar 48000 pipe:1'));
    });

    test('the game\'s process tree, from /proc', () {
      final proc = Directory.systemTemp.createTempSync('proc');
      addTearDown(() => proc.deleteSync(recursive: true));
      void process(int pid, int parent, String name) {
        Directory(p.join(proc.path, '$pid')).createSync();
        File(p.join(proc.path, '$pid', 'stat')).writeAsStringSync('$pid ($name) S $parent 1 1 0');
      }

      process(100, 1, 'launcher');
      process(200, 100, 'game (main)');
      process(300, 200, 'audio');
      process(400, 1, 'other');
      expect(PulseGameSound.processTree(200, proc: proc.path), {200, 300});
    });
  });

  test('a desktop that cannot be heard hears nothing', () async {
    final sound = SilentGameSound();
    await sound.start((_) => fail('no sound'));
    expect(sound.reach, SoundReach.none);
  });
}
