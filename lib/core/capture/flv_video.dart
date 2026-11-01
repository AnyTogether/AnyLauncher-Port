import 'dart:typed_data';

/// One encoded frame: start-code H.264 (a key frame with its parameter sets first), as the
/// phone's decoders take it.
class EncodedFrame {
  const EncodedFrame(this.data, {required this.key, required this.milliseconds});
  final Uint8List data;
  final bool key;

  /// The encoder's time stamp, from the stream's start.
  final int milliseconds;
}

/// Reads ffmpeg's FLV output as it comes from a pipe and hands on each H.264 frame whole. FLV
/// says where every frame ends, which a raw H.264 stream only says once the next one begins
/// (a frame late), and marks key frames; the parameter sets come once, in the AVC sequence
/// header, and go before every key frame for a phone that joins late.
class FlvVideoReader {
  FlvVideoReader(this.onFrame);

  final void Function(EncodedFrame frame) onFrame;

  final _pending = BytesBuilder(copy: false);
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;
  bool _header = false;
  int _lengthSize = 4;
  List<Uint8List> _parameterSets = const [];

  /// The parameter sets the stream gave (SPS then PPS).
  List<Uint8List> get parameterSets => _parameterSets;

  void add(List<int> data) {
    _pending.add(data is Uint8List ? data : Uint8List.fromList(data));
    if (_offset < _buffer.length) {
      final rest = Uint8List.sublistView(_buffer, _offset);
      final more = _pending.takeBytes();
      _buffer = Uint8List(rest.length + more.length)
        ..setAll(0, rest)
        ..setAll(rest.length, more);
    } else {
      _buffer = _pending.takeBytes();
    }
    _offset = 0;
    _parse();
  }

  void _parse() {
    if (!_header) {
      // "FLV", version, flags, header size (9), then the first previous-tag size.
      if (_buffer.length - _offset < 9) return;
      if (_buffer[_offset] != 0x46 || _buffer[_offset + 1] != 0x4C || _buffer[_offset + 2] != 0x56) {
        throw const FormatException('not FLV');
      }
      final size = ByteData.sublistView(_buffer).getUint32(_offset + 5);
      if (_buffer.length - _offset < size + 4) return;
      _offset += size + 4;
      _header = true;
    }
    while (_buffer.length - _offset >= 11) {
      final type = _buffer[_offset] & 0x1F;
      final size = _buffer[_offset + 1] << 16 | _buffer[_offset + 2] << 8 | _buffer[_offset + 3];
      final time = _buffer[_offset + 7] << 24 | _buffer[_offset + 4] << 16 | _buffer[_offset + 5] << 8 | _buffer[_offset + 6];
      if (_buffer.length - _offset < 11 + size + 4) return;
      if (type == 9 && size > 0) _video(Uint8List.sublistView(_buffer, _offset + 11, _offset + 11 + size), time);
      _offset += 11 + size + 4;
    }
  }

  void _video(Uint8List tag, int time) {
    final frameType = tag[0] >> 4;
    final codec = tag[0] & 0x0F;
    // H.264 only (codec 7), the classic FLV way ffmpeg writes it.
    if (codec != 7 || tag.length < 5) return;
    final packetType = tag[1];
    final body = Uint8List.sublistView(tag, 5);
    if (packetType == 0) {
      _configuration(body);
    } else if (packetType == 1) {
      final key = frameType == 1;
      onFrame(
        EncodedFrame(
          annexB(body, lengthSize: _lengthSize, parameterSets: key ? _parameterSets : const []),
          key: key,
          milliseconds: time,
        ),
      );
    }
  }

  /// The AVCDecoderConfigurationRecord: the NAL length size and the parameter sets.
  void _configuration(Uint8List record) {
    if (record.length < 7) return;
    _lengthSize = (record[4] & 3) + 1;
    final sets = <Uint8List>[];
    var position = 5;
    for (final countMask in const [0x1F, 0xFF]) {
      if (position >= record.length) break;
      final count = record[position++] & countMask;
      for (var index = 0; index < count && position + 2 <= record.length; index++) {
        final length = record[position] << 8 | record[position + 1];
        position += 2;
        if (position + length > record.length) break;
        sets.add(Uint8List.fromList(Uint8List.sublistView(record, position, position + length)));
        position += length;
      }
    }
    _parameterSets = sets;
  }

  /// A frame with a length before each NAL unit as the start-code stream the phones' decoders
  /// take; the parameter sets go first when given (before a key frame). Access unit delimiters
  /// are left out. The macOS launcher's StreamPacket.annexB.
  static Uint8List annexB(Uint8List frame, {int lengthSize = 4, List<Uint8List> parameterSets = const []}) {
    final units = <Uint8List>[];
    var position = 0;
    while (position + lengthSize <= frame.length) {
      var length = 0;
      for (var index = 0; index < lengthSize; index++) {
        length = length << 8 | frame[position + index];
      }
      position += lengthSize;
      if (length <= 0 || position + length > frame.length) break;
      final unit = Uint8List.sublistView(frame, position, position + length);
      position += length;
      if (unit[0] & 0x1F != 9) units.add(unit);
    }
    // A frame with parameter sets of its own needs no others.
    final own = units.any((unit) => unit[0] & 0x1F == 7);
    final out = BytesBuilder(copy: false);
    const start = [0, 0, 0, 1];
    for (final unit in [if (!own) ...parameterSets, ...units]) {
      out
        ..add(start)
        ..add(unit);
    }
    return out.takeBytes();
  }
}
