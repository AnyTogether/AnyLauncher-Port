import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../core/capture/stream_packet.dart';

/// Where a watched share play's PCM goes (from hosts that send the game's sound on the "audio"
/// channel rather than as an Opus track): SoLoud in the launcher, a recording in tests.
abstract class ShareSoundOut {
  /// One StreamPacket audio packet as it came.
  void push(Uint8List packet);
  void stop();
}

/// The StreamPacket audio packets in order: an older one than the newest is dropped, as the
/// Mac's SoundJitterBuffer drops it; the samples of the rest.
class ShareSoundOrder {
  int? _newest;

  /// The 16-bit stereo samples of [packet], or null when it is not audio or came late.
  Uint8List? samples(Uint8List packet) {
    if (packet.length <= StreamPacket.audioHeader) return null;
    final view = ByteData.sublistView(packet);
    if (view.getUint32(0, Endian.little) != StreamPacket.audioMagic) return null;
    final header = view.getUint16(6, Endian.little);
    if (header < StreamPacket.audioHeader || header >= packet.length) return null;
    final number = view.getUint32(8, Endian.little);
    final newest = _newest;
    if (newest != null && ((number - newest) & 0xFFFFFFFF).toSigned(32) <= 0) return null;
    _newest = number;
    return Uint8List.sublistView(packet, header);
  }
}

/// SoLoud's buffer stream at 48 kHz stereo: started on the first packet, about 60 ms held
/// before it plays (and again after it ran dry), old sound let go as it plays.
class SoloudShareSound implements ShareSoundOut {
  final _order = ShareSoundOrder();
  AudioSource? _source;
  SoundHandle? _voice;
  bool _failed = false;

  @override
  void push(Uint8List packet) {
    if (_failed) return;
    final samples = _order.samples(packet);
    if (samples == null) return;
    try {
      final soloud = SoLoud.instance;
      if (!soloud.isInitialized) return;
      var source = _source;
      if (source == null) {
        source = soloud.setBufferStream(
          maxBufferSizeDuration: const Duration(seconds: 2),
          bufferingType: BufferingType.released,
          bufferingTimeNeeds: 0.06,
          sampleRate: 48000,
          channels: Channels.stereo,
          format: BufferType.s16le,
        );
        _source = source;
        _voice = soloud.play(source);
      }
      soloud.addAudioDataStream(source, samples);
    } on Object {
      // No sound card, or SoLoud refused: the picture goes on without it.
      _failed = true;
    }
  }

  @override
  void stop() {
    final source = _source;
    final voice = _voice;
    _source = null;
    _voice = null;
    if (source == null) return;
    try {
      if (voice != null) SoLoud.instance.stop(voice);
      SoLoud.instance.disposeSource(source);
    } on Object {
      // Already gone with the engine.
    }
  }
}
