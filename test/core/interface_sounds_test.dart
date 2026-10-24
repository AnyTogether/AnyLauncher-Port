import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anyps5_desktop/core/audio/interface_sounds.dart';
import 'package:anyps5_desktop/core/audio/tones.dart';
import 'package:anyps5_desktop/core/audio/wav.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_audio.dart';

double rms(Iterable<double> samples) {
  var sum = 0.0;
  var count = 0;
  for (final sample in samples) {
    sum += sample * sample;
    count++;
  }
  return count == 0 ? 0 : math.sqrt(sum / count);
}

void main() {
  group('Tones', () {
    test('every cue is as long as its partials and 20 ms more, as on the Mac', () {
      expect(
        {for (final cue in Cue.values) cue: Tones.render(cue).length},
        {Cue.move: 2866, Cue.select: 7497, Cue.back: 6835, Cue.unlocked: 22050, Cue.ring: 21168},
      );
    });

    test('the Mac sample values: a sine with a 4 ms attack and a fast decay', () {
      final move = Tones.render(Cue.move);
      expect(move[0], 0);
      // 1 ms in: a quarter of the attack, 1320 Hz and its octave.
      const time = 44 / 44100;
      final expected =
          math.sin(2 * math.pi * 1320 * time) * (time / 0.004) * math.exp(-time * 70) * 0.5 +
          math.sin(4 * math.pi * 1320 * time) * (time / 0.004) * math.exp(-time * 70 * 1.6) * 0.12;
      expect(move[44], closeTo(expected, 1e-6));
    });

    test('no cue clips, each rises within its attack, dies away and ends in silence', () {
      for (final cue in Cue.values) {
        final samples = Tones.render(cue);
        final peak = samples.map((sample) => sample.abs()).reduce(math.max);
        expect(peak, lessThan(1), reason: '$cue');
        expect(peak, greaterThan(0.2), reason: '$cue');
        // The first 4 ms stay under the attack's line.
        for (var frame = 0; frame < 176; frame++) {
          expect(samples[frame].abs(), lessThanOrEqualTo(0.62 * 2 * frame / 176 + 1e-6), reason: '$cue at $frame');
        }
        // The last 20 ms are silent.
        final tail = samples.sublist(samples.length - 880);
        expect(tail.every((sample) => sample == 0), isTrue, reason: '$cue');
        // The first partial alone, before the next one starts: its second half is quieter.
        final (partials, _) = Tones.recipes[cue]!;
        final alone = partials.length > 1 ? partials[1].$2 : partials.first.$3;
        final half = (alone * 44100 / 2).floor();
        expect(rms(samples.sublist(half, half * 2)), lessThan(rms(samples.sublist(0, half)) * 0.9), reason: '$cue');
      }
    });

    test('a cue as a WAV file: stereo 16-bit, both sides the same', () {
      final wav = Tones.wav(Cue.select);
      final bytes = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(bytes.getUint16(22, Endian.little), 2);
      expect(bytes.getUint32(24, Endian.little), 44100);
      expect(bytes.getUint16(34, Endian.little), 16);
      expect(bytes.getUint32(40, Endian.little), 7497 * 4);
      expect(wav.length, 44 + 7497 * 4);
      for (var frame = 0; frame < 7497; frame += 97) {
        expect(bytes.getInt16(44 + frame * 4, Endian.little), bytes.getInt16(46 + frame * 4, Endian.little));
      }
    });
  });

  group('Wav', () {
    test('holds samples past full scale and writes a part of the frames', () {
      final samples = Float32List.fromList([0, 0, 0.5, -0.5, 2, -2, 1, -1]);
      final wav = ByteData.sublistView(Wav.pcm16(samples, channels: 2, sampleRate: 48000, start: 1, end: 3));
      expect(wav.lengthInBytes, 44 + 2 * 4);
      expect(wav.getUint32(4, Endian.little), 36 + 8);
      expect(wav.getUint32(28, Endian.little), 48000 * 4);
      expect([for (var at = 44; at < 52; at += 2) wav.getInt16(at, Endian.little)], [16384, -16384, 32767, -32767]);
    });
  });

  group('InterfaceSounds', () {
    test('loads the five cues once and plays them softly under the volume chosen', () async {
      final out = FakeAudio();
      final sounds = InterfaceSounds(out);
      sounds.play(Cue.move);
      expect(out.voices, isEmpty, reason: 'nothing before the output is open');
      await sounds.start();
      await sounds.start();
      expect(out.loaded.map((sound) => sound.name), [
        'anyps5-move.wav',
        'anyps5-select.wav',
        'anyps5-back.wav',
        'anyps5-unlocked.wav',
        'anyps5-ring.wav',
      ]);
      sounds.play(Cue.select);
      expect(out.cues, ['select']);
      expect(out.voices.single.volume, closeTo(0.32, 1e-9));
      sounds.volume = 0.5;
      await Future<void>.value();
      sounds.play(Cue.back);
      expect(out.voices.last.volume, closeTo(0.16, 1e-9));
      sounds.enabled = false;
      sounds.play(Cue.move);
      expect(out.cues, ['select', 'back']);
    });

    test('four voices in turn: a fifth sound stops the first', () async {
      final out = FakeAudio();
      final sounds = InterfaceSounds(out);
      await sounds.start();
      for (var index = 0; index < 5; index++) {
        sounds.play(Cue.move);
        await Future<void>.value();
      }
      expect(out.voices.map((voice) => voice.stopped), [true, false, false, false, false]);
    });

    test('the same cue twice in one step plays once; muted, none plays', () async {
      final out = FakeAudio();
      final sounds = InterfaceSounds(out);
      await sounds.start();
      sounds
        ..play(Cue.select)
        ..play(Cue.select)
        ..play(Cue.back);
      expect(out.cues, ['select', 'back']);
      await Future<void>.value();
      sounds.play(Cue.select);
      expect(out.cues, ['select', 'back', 'select']);
      await Future<void>.value();
      sounds
        ..muted = true
        ..play(Cue.move);
      expect(out.cues, hasLength(3));
    });

    test('without an output it stays quiet', () async {
      final out = FakeAudio(works: false);
      final sounds = InterfaceSounds(out);
      await sounds.start();
      sounds.play(Cue.select);
      expect(out.voices, isEmpty);
    });
  });
}
