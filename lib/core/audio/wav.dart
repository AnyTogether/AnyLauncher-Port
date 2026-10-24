import 'dart:typed_data';

/// RIFF WAVE files written from float samples, the form the audio engine loads from memory.
abstract final class Wav {
  /// Interleaved samples (frames [start] to [end], all by default) as 16-bit PCM; anything past
  /// -1 or 1 is held there.
  static Uint8List pcm16(
    Float32List samples, {
    required int channels,
    required int sampleRate,
    int start = 0,
    int? end,
  }) {
    final frames = (end ?? samples.length ~/ channels) - start;
    final dataSize = frames * channels * 2;
    final bytes = ByteData(44 + dataSize);
    void tag(int at, String text) {
      for (var index = 0; index < 4; index++) {
        bytes.setUint8(at + index, text.codeUnitAt(index));
      }
    }

    tag(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bytes
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * channels * 2, Endian.little)
      ..setUint16(32, channels * 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    tag(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);
    final out = Int16List.view(bytes.buffer, 44, frames * channels);
    final from = start * channels;
    for (var index = 0; index < out.length; index++) {
      final value = samples[from + index];
      out[index] = value >= 1 ? 32767 : (value <= -1 ? -32767 : (value * 32767).round());
    }
    return bytes.buffer.asUint8List();
  }
}
