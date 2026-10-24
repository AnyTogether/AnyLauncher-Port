import 'audio_out.dart';
import 'tones.dart';

/// The interface's soft sounds (Tones), the way the macOS launcher plays them: four voices taken
/// in turn, each stopping what it played before, at a soft level under the volume chosen.
class InterfaceSounds {
  InterfaceSounds(this._out);

  final AudioOut _out;

  /// The sounds' own level: the volume chosen (0 to 1) is on top of it.
  static const level = 0.32;
  static const voices = 4;

  bool enabled = true;

  /// 0 to 1.
  double volume = 1;

  final Map<Cue, Object> _sounds = {};
  final List<Object?> _playing = List.filled(voices, null);
  int _next = 0;
  Future<void>? _loading;

  /// Opens the output and makes the cues; the sounds play from then on.
  Future<void> start() => _loading ??= () async {
    if (!await _out.start()) return;
    for (final cue in Cue.values) {
      final sound = await _out.loadWav('anyps5-${cue.name}.wav', Tones.wav(cue));
      if (sound != null) _sounds[cue] = sound;
    }
  }();

  void play(Cue cue) {
    if (!enabled || volume <= 0) return;
    final sound = _sounds[cue];
    if (sound == null) return;
    final previous = _playing[_next];
    if (previous != null) _out.stop(previous);
    _playing[_next] = _out.play(sound, volume: level * volume);
    _next = (_next + 1) % voices;
  }
}
