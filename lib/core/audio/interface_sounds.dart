import 'dart:async';

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

  /// Quiet for now, the choice kept (a game in front).
  bool muted = false;

  /// 0 to 1.
  double volume = 1;

  final Map<Cue, Object> _sounds = {};
  final List<Object?> _playing = List.filled(voices, null);
  final Set<Cue> _thisTurn = {};
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

  /// Plays [cue]; the same cue asked twice in one step (a row that opens a panel) plays once.
  /// [overGame] plays it while a game is in front too (a trophy earned).
  void play(Cue cue, {bool overGame = false}) {
    if (!enabled || (muted && !overGame) || volume <= 0) return;
    final sound = _sounds[cue];
    if (sound == null || !_thisTurn.add(cue)) return;
    if (_thisTurn.length == 1) scheduleMicrotask(_thisTurn.clear);
    final previous = _playing[_next];
    if (previous != null) _out.stop(previous);
    _playing[_next] = _out.play(sound, volume: level * volume);
    _next = (_next + 1) % voices;
  }
}
