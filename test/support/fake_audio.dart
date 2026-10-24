import 'dart:typed_data';

import 'package:anyps5_desktop/core/audio/audio_out.dart';

/// A sound loaded into the fake output.
class FakeSound {
  FakeSound(this.name, {this.bytes});
  final String name;
  final Uint8List? bytes;
  bool released = false;

  @override
  String toString() => name;
}

/// A voice the fake output started, with every volume it was given.
class FakeVoice {
  FakeVoice(this.sound, {required this.loop, required this.loopStart, required double volume}) : volumes = [volume];
  final FakeSound sound;
  final bool loop;
  final Duration loopStart;
  final List<double> volumes;
  bool stopped = false;

  double get volume => volumes.last;
}

/// An output that plays nothing and remembers everything.
class FakeAudio implements AudioOut {
  FakeAudio({this.works = true});

  final bool works;
  int starts = 0;
  final List<FakeSound> loaded = [];
  final List<FakeVoice> voices = [];

  /// The cues played, in order, by name (move, select…).
  List<String> get cues => [
    for (final voice in voices)
      if (voice.sound.name.startsWith('anyps5-') && !voice.sound.name.startsWith('anyps5-song'))
        voice.sound.name.substring('anyps5-'.length).replaceAll('.wav', ''),
  ];

  @override
  Future<bool> start() async {
    starts++;
    return works;
  }

  @override
  Future<Object?> loadWav(String name, Uint8List bytes) async {
    if (!works) return null;
    final sound = FakeSound(name, bytes: bytes);
    loaded.add(sound);
    return sound;
  }

  @override
  Future<Object?> loadFile(String path) async {
    if (!works) return null;
    final sound = FakeSound(path);
    loaded.add(sound);
    return sound;
  }

  @override
  Object? play(Object sound, {double volume = 1, bool loop = false, Duration loopStart = Duration.zero}) {
    final voice = FakeVoice(sound as FakeSound, loop: loop, loopStart: loopStart, volume: volume);
    voices.add(voice);
    return voice;
  }

  @override
  void setVolume(Object voice, double volume) => (voice as FakeVoice).volumes.add(volume);

  @override
  void stop(Object voice) => (voice as FakeVoice).stopped = true;

  @override
  void release(Object sound) => (sound as FakeSound).released = true;
}
