import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'audio_out.dart';

/// The sound card through SoLoud (miniaudio: WASAPI on Windows, PulseAudio or ALSA on Linux).
/// Every call is guarded: a launcher without sound still works.
class SoloudAudio implements AudioOut {
  Future<bool>? _started;
  bool _ready = false;

  SoLoud get _soloud => SoLoud.instance;

  @override
  Future<bool> start() => _started ??= () async {
    try {
      // A small buffer: a tick follows the key press without a lag.
      await _soloud.init(bufferSize: 1024);
      _ready = _soloud.isInitialized;
    } on Object {
      _ready = false;
    }
    return _ready;
  }();

  @override
  Future<Object?> loadWav(String name, Uint8List bytes) async {
    if (!await start()) return null;
    try {
      return await _soloud.loadMem(name, bytes);
    } on Object {
      return null;
    }
  }

  @override
  Future<Object?> loadFile(String path) async {
    if (!await start()) return null;
    try {
      return await _soloud.loadFile(path);
    } on Object {
      return null;
    }
  }

  @override
  Object? play(Object sound, {double volume = 1, bool loop = false, Duration loopStart = Duration.zero}) {
    if (!_ready || sound is! AudioSource) return null;
    try {
      return _Voice(_soloud.play(sound, volume: volume, looping: loop, loopingStartAt: loopStart));
    } on Object {
      return null;
    }
  }

  @override
  void setVolume(Object voice, double volume) {
    if (!_ready || voice is! _Voice) return;
    try {
      if (_soloud.getIsValidVoiceHandle(voice.handle)) _soloud.setVolume(voice.handle, volume);
    } on Object {
      // The voice ended.
    }
  }

  @override
  void stop(Object voice) {
    if (!_ready || voice is! _Voice) return;
    try {
      if (_soloud.getIsValidVoiceHandle(voice.handle)) unawaited(_soloud.stop(voice.handle).catchError((Object _) {}));
    } on Object {
      // The voice ended.
    }
  }

  @override
  void release(Object sound) {
    if (!_ready || sound is! AudioSource) return;
    unawaited(_soloud.disposeSource(sound).catchError((Object _) {}));
  }
}

/// A playing sound's handle (an extension type, kept in a class to be told apart).
class _Voice {
  const _Voice(this.handle);
  final SoundHandle handle;
}
