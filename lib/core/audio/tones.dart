import 'dart:math' as math;
import 'dart:typed_data';

import 'wav.dart';

/// The launcher's interface sounds: [bump] when a direction has nowhere to go, [hover] when the
/// pointer arrives on something.
enum Cue { move, select, back, unlocked, ring, bump, hover }

/// One sine of a cue: its frequency, when it starts and how long it lasts, in seconds.
typedef Partial = (double frequency, double start, double length);

/// Soft interface sounds, synthesized: a short tick for moving, a rising pair for selecting, a
/// falling one for going back, a rising three for something finished and two trills for a call.
/// The macOS launcher's tones (Sounds.swift), sample for sample.
abstract final class Tones {
  static const sampleRate = 44100;

  /// Each cue's partials and how fast they die away.
  static const recipes = <Cue, (List<Partial>, double)>{
    Cue.move: ([(1320, 0.0, 0.045)], 70),
    Cue.select: ([(880, 0.0, 0.07), (1320, 0.05, 0.1)], 32),
    Cue.back: ([(990, 0.0, 0.06), (660, 0.045, 0.09)], 34),
    Cue.unlocked: ([(660, 0.0, 0.12), (990, 0.09, 0.14), (1320, 0.18, 0.3)], 12),
    // A friend calling: two soft trills.
    Cue.ring: ([(988, 0.0, 0.11), (1319, 0.1, 0.11), (988, 0.2, 0.11), (1319, 0.3, 0.16)], 5),
    // The end of a row: B3 and a fast decay, the quietest cue.
    Cue.bump: ([(247, 0.0, 0.06)], 55),
    // The pointer on something new: the move tick, about 3 dB lower.
    Cue.hover: ([(1320, 0.0, 0.045)], 70),
  };

  /// How loud each cue is against the others (1 for the rest).
  static const gains = <Cue, double>{Cue.bump: 0.6, Cue.hover: 0.7};

  /// The cue as mono samples at [rate].
  static Float32List render(Cue cue, {int rate = sampleRate}) {
    final (partials, decay) = recipes[cue]!;
    final samples = synthesize(partials, decay, rate: rate);
    final gain = gains[cue] ?? 1;
    if (gain != 1) {
      for (var index = 0; index < samples.length; index++) {
        samples[index] *= gain;
      }
    }
    return samples;
  }

  /// Sine partials with a 4 ms attack and an exponential decay, plus a quieter octave that dies
  /// away faster; 20 ms of silence after the last one ends.
  static Float32List synthesize(List<Partial> partials, double decay, {int rate = sampleRate}) {
    final length = partials.isEmpty ? 0.1 : partials.map((partial) => partial.$2 + partial.$3).reduce(math.max);
    final frames = (rate * (length + 0.02)).floor();
    final samples = Float32List(frames);
    for (var frame = 0; frame < frames; frame++) {
      final time = frame / rate;
      var sample = 0.0;
      for (final (frequency, start, duration) in partials) {
        if (time < start || time >= start + duration) continue;
        final local = time - start;
        final attack = math.min(1.0, local / 0.004);
        sample += math.sin(2 * math.pi * frequency * local) * attack * math.exp(-local * decay) * 0.5;
        sample += math.sin(4 * math.pi * frequency * local) * attack * math.exp(-local * decay * 1.6) * 0.12;
      }
      samples[frame] = sample;
    }
    return samples;
  }

  /// The cue as a stereo 16-bit WAV file, both sides the same, for the audio engine.
  static Uint8List wav(Cue cue) {
    final mono = render(cue);
    final stereo = Float32List(mono.length * 2);
    for (var frame = 0; frame < mono.length; frame++) {
      stereo[frame * 2] = mono[frame];
      stereo[frame * 2 + 1] = mono[frame];
    }
    return Wav.pcm16(stereo, channels: 2, sampleRate: sampleRate);
  }
}
