@DefaultAsset('package:anyps5_desktop/core/audio/atrac9.dart')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'wav.dart';

// LibAtrac9 (native/atrac9, built by hook/build.dart).
@Native<Pointer<Void> Function(Pointer<Uint8>, Pointer<Int32>)>(symbol: 'anyps5_atrac9_open')
external Pointer<Void> _open(Pointer<Uint8> config, Pointer<Int32> info);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Float>, Pointer<Int32>)>(
  symbol: 'anyps5_atrac9_decode',
)
external int _decode(Pointer<Void> handle, Pointer<Uint8> data, int size, Pointer<Float> pcm, Pointer<Int32> used);

@Native<Void Function(Pointer<Void>)>(symbol: 'anyps5_atrac9_close')
external void _close(Pointer<Void> handle);

class ThemeSongUnreadable implements Exception {
  const ThemeSongUnreadable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What an ATRAC9 decoder makes of a file's four config bytes.
class Atrac9Info {
  const Atrac9Info({required this.channels, required this.frameSamples, required this.framesInSuperframe});
  final int channels;
  final int frameSamples;
  final int framesInSuperframe;
}

/// What the RIFF chunks of an ATRAC9 file say.
class ThemeSongHeader {
  ThemeSongHeader({
    required this.channels,
    required this.sampleRate,
    required this.blockAlign,
    required this.config,
    required this.dataStart,
    required this.dataEnd,
  });

  final int channels;
  final int sampleRate;

  /// The size of a superframe.
  final int blockAlign;
  final Uint8List config;
  int totalFrames = 0;

  /// The encoder's delay: frames at the start that are not part of the song.
  int delay = 0;

  /// The part that repeats, in frames (end excluded); null repeats the whole song.
  (int, int)? loop;
  final int dataStart;
  final int dataEnd;
}

/// A song ready for the audio engine: a WAV file that, looping, starts again at [loopStart]
/// (the song up to the end of its loop, then the loop over and over).
class PlayableSong {
  const PlayableSong(this.wav, this.loopStart);
  final Uint8List wav;
  final Duration loopStart;
}

/// A game's theme song (sce_sys/snd0.at9), the music the PS5 plays while the game is selected:
/// ATRAC9 in a RIFF file, decoded to interleaved float samples. The macOS launcher's
/// ThemeSong.swift.
class ThemeSong {
  ThemeSong({required this.sampleRate, required this.channels, required this.samples, this.loop});

  final int sampleRate;
  final int channels;
  final Float32List samples;

  /// The part that repeats, in frames (end excluded); null repeats the whole song.
  final (int, int)? loop;

  int get frames => samples.length ~/ (channels < 1 ? 1 : channels);

  /// KSDATAFORMAT_SUBTYPE_ATRAC9, 47E142D2-36BA-4D8D-88FC-61654F8C836C.
  static const atrac9Format = [
    0xd2,
    0x42,
    0xe1,
    0x47,
    0xba,
    0x36,
    0x8d,
    0x4d,
    0x88,
    0xfc,
    0x61,
    0x65,
    0x4f,
    0x8c,
    0x83,
    0x6c,
  ];

  static ThemeSongHeader header(Uint8List bytes) {
    int u16(int at) => bytes[at] | bytes[at + 1] << 8;
    int u32(int at) => u16(at) | u16(at + 2) << 16;
    bool same(int at, List<int> expected) {
      if (at + expected.length > bytes.length) return false;
      for (var index = 0; index < expected.length; index++) {
        if (bytes[at + index] != expected[index]) return false;
      }
      return true;
    }

    if (bytes.length < 12 || !same(0, 'RIFF'.codeUnits) || !same(8, 'WAVE'.codeUnits)) {
      throw const ThemeSongUnreadable('not a RIFF WAVE file');
    }
    (int, int)? format;
    (int, int)? fact;
    (int, int)? sampler;
    (int, int)? data;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes, offset, offset + 4);
      final size = u32(offset + 4);
      final start = offset + 8;
      final end = start + size < bytes.length ? start + size : bytes.length;
      switch (id) {
        case 'fmt ':
          format = (start, end);
        case 'fact':
          fact = (start, end);
        case 'smpl':
          sampler = (start, end);
        case 'data':
          data = (start, end);
      }
      offset = end + (size & 1);
    }
    if (format == null ||
        format.$2 - format.$1 < 52 ||
        u16(format.$1) != 0xfffe ||
        !same(format.$1 + 24, atrac9Format)) {
      throw const ThemeSongUnreadable('not ATRAC9');
    }
    if (data == null || data.$2 <= data.$1) throw const ThemeSongUnreadable('no audio data');
    final at = format.$1;
    final header = ThemeSongHeader(
      channels: u16(at + 2),
      sampleRate: u32(at + 4),
      blockAlign: u16(at + 12),
      config: Uint8List.fromList(bytes.sublist(at + 44, at + 48)),
      dataStart: data.$1,
      dataEnd: data.$2,
    );
    if (header.channels <= 0 || header.sampleRate <= 0 || header.blockAlign <= 0) {
      throw const ThemeSongUnreadable('an empty format');
    }
    if (fact != null && fact.$2 - fact.$1 >= 8) {
      header
        ..totalFrames = u32(fact.$1)
        ..delay = u32(fact.$1 + 4);
    }
    if (sampler != null && sampler.$2 - sampler.$1 >= 60 && u32(sampler.$1 + 28) > 0) {
      final start = u32(sampler.$1 + 44);
      final end = u32(sampler.$1 + 48) + 1;
      if (start < end && (header.totalFrames == 0 || end <= header.totalFrames)) header.loop = (start, end);
    }
    return header;
  }

  /// What the decoder makes of [config], or null when it cannot use it.
  static Atrac9Info? codecInfo(Uint8List config) {
    final native = calloc<Uint8>(4);
    final info = calloc<Int32>(3);
    try {
      native.asTypedList(4).setAll(0, config.take(4));
      final handle = _open(native, info);
      if (handle == nullptr) return null;
      _close(handle);
      return Atrac9Info(channels: info[0], frameSamples: info[1], framesInSuperframe: info[2]);
    } finally {
      calloc
        ..free(native)
        ..free(info);
    }
  }

  /// The whole song, without the encoder's delay and cut to its length.
  static ThemeSong decode(Uint8List file) {
    final header = ThemeSong.header(file);
    final config = calloc<Uint8>(4);
    final info = calloc<Int32>(3);
    final used = calloc<Int32>();
    final dataSize = header.dataEnd - header.dataStart;
    final data = malloc<Uint8>(dataSize);
    Pointer<Float> out = nullptr;
    Pointer<Void> decoder = nullptr;
    try {
      config.asTypedList(4).setAll(0, header.config);
      decoder = _open(config, info);
      if (decoder == nullptr) throw const ThemeSongUnreadable('unusable ATRAC9 config');
      final channels = info[0];
      final frameSamples = info[1];
      final framesInSuperframe = info[2] < 1 ? 1 : info[2];
      if (channels != header.channels || frameSamples <= 0) {
        throw const ThemeSongUnreadable('ATRAC9 config does not match the file');
      }
      data.asTypedList(dataSize).setAll(0, Uint8List.sublistView(file, header.dataStart, header.dataEnd));
      final superframes = dataSize ~/ header.blockAlign;
      final frameValues = frameSamples * channels;
      final capacity = superframes * framesInSuperframe * frameValues;
      out = malloc<Float>(capacity < 1 ? 1 : capacity);
      var written = 0;
      // Each superframe is blockAlign bytes; its frames may leave padding at its end, so every
      // superframe is read from its own start.
      for (var superframe = 0; superframe + header.blockAlign <= dataSize; superframe += header.blockAlign) {
        var position = superframe;
        for (var frame = 0; frame < framesInSuperframe; frame++) {
          final status = _decode(
            decoder,
            data + position,
            superframe + header.blockAlign - position,
            out + written,
            used,
          );
          if (status != 0 || used.value <= 0) {
            throw ThemeSongUnreadable('ATRAC9 frame at ${header.dataStart + position} failed ($status)');
          }
          written += frameValues;
          position += used.value;
        }
      }
      final all = out.asTypedList(written);
      final skip = header.delay * channels < written ? header.delay * channels : written;
      var end = written;
      if (header.totalFrames > 0 && end - skip > header.totalFrames * channels) {
        end = skip + header.totalFrames * channels;
      }
      final song = Float32List.fromList(Float32List.sublistView(all, skip, end));
      final frames = song.length ~/ channels;
      final loop = header.loop;
      return ThemeSong(
        sampleRate: header.sampleRate,
        channels: channels,
        samples: song,
        loop: loop != null && loop.$2 <= frames ? loop : null,
      );
    } finally {
      if (decoder != nullptr) _close(decoder);
      if (out != nullptr) malloc.free(out);
      malloc.free(data);
      calloc
        ..free(config)
        ..free(info)
        ..free(used);
    }
  }

  static ThemeSong decodeFile(String path) => decode(File(path).readAsBytesSync());

  /// For playing: the song up to the end of its loop, repeating from the loop's start; without a
  /// loop (or one from the very start), the whole song repeats.
  PlayableSong playable() {
    final loop = this.loop;
    if (loop == null || loop.$1 <= 0) {
      return PlayableSong(Wav.pcm16(samples, channels: channels, sampleRate: sampleRate), Duration.zero);
    }
    return PlayableSong(
      Wav.pcm16(samples, channels: channels, sampleRate: sampleRate, end: loop.$2),
      Duration(microseconds: (loop.$1 * 1000000 / sampleRate).round()),
    );
  }

  /// A theme song decoded away from the interface, ready to play; null when it cannot be read.
  static Future<PlayableSong?> load(String path) => Isolate.run(() {
    try {
      return ThemeSong.decodeFile(path).playable();
    } on Object {
      return null;
    }
  });
}
