import 'dart:typed_data';

/// The sound card, as the launcher uses it: sounds loaded once, voices started, faded and
/// stopped. SoLoud in the app (soloud_audio.dart), silence or a recording fake in tests.
abstract class AudioOut {
  /// Opens the output; false when there is none (no device, no library), and every call after
  /// does nothing.
  Future<bool> start();

  /// A WAV file in memory as a sound to play, or null.
  Future<Object?> loadWav(String name, Uint8List bytes);

  /// A file the engine reads (wav, mp3, and m4a where the system decodes it), or null.
  Future<Object?> loadFile(String path);

  /// Starts [sound]; looping, it starts again at [loopStart] after its end. The voice, or null.
  Object? play(Object sound, {double volume = 1, bool loop = false, Duration loopStart = Duration.zero});

  void setVolume(Object voice, double volume);
  void stop(Object voice);

  /// Lets go of a sound loaded earlier (and stops its voices).
  void release(Object sound);
}

/// No sound at all.
class SilentAudio implements AudioOut {
  const SilentAudio();

  @override
  Future<bool> start() async => false;

  @override
  Future<Object?> loadWav(String name, Uint8List bytes) async => null;

  @override
  Future<Object?> loadFile(String path) async => null;

  @override
  Object? play(Object sound, {double volume = 1, bool loop = false, Duration loopStart = Duration.zero}) => null;

  @override
  void setVolume(Object voice, double volume) {}

  @override
  void stop(Object voice) {}

  @override
  void release(Object sound) {}
}
