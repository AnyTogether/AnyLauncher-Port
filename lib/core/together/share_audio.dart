import 'dart:convert';
import 'dart:typed_data';

import '../controllers/pad_info.dart';
import '../gamepad/pad_navigation.dart';
import '../remote/remote_protocol.dart';

/// How the game's sound reaches a share play viewer, agreed per viewer, as the macOS launcher's
/// ShareAudioCodec.swift and the website's shareOpus.ts agree it.
///
/// Every host sends 16-bit stereo PCM on the "audio" data channel (5 ms StreamPacket audio)
/// unless told otherwise. A viewer that can play an Opus audio track says so with a text message
/// on that channel once it opens ([ShareAudioHello]); a host that understands it adds the game's
/// sound to that viewer's connection as a WebRTC audio track, offers again, and stops the PCM for
/// that viewer once the answer takes the track. Old hosts ignore the hello and old viewers (the
/// phone app) never send one, so either side alone keeps working on PCM.
enum ShareAudioCodec {
  /// An RTP audio track on the connection, Opus stereo.
  opus,

  /// StreamPacket audio on the "audio" data channel.
  pcm,
}

/// A viewer's word on the "audio" channel: `{"type":"audio-hello","v":1,"codecs":["opus","pcm"]}`,
/// as a text message (the PCM packets are binary).
class ShareAudioHello {
  const ShareAudioHello(this.codecs);

  static const type = 'audio-hello';
  static const version = 1;

  final List<ShareAudioCodec> codecs;

  String get text => jsonEncode({'type': type, 'v': version, 'codecs': [for (final codec in codecs) codec.name]});

  /// A hello from its text; unknown codecs are left out, anything else is null.
  static ShareAudioHello? parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map || json['type'] != type || json['codecs'] is! List) return null;
    return ShareAudioHello([
      for (final name in json['codecs'] as List)
        ?ShareAudioCodec.values.where((codec) => codec.name == name).firstOrNull,
    ]);
  }

  /// What the host sends a viewer who said this (Opus whenever they can take it).
  ShareAudioCodec get chosen => codecs.contains(ShareAudioCodec.opus) ? ShareAudioCodec.opus : ShareAudioCodec.pcm;
}

/// The SDP side of the Opus track, as the Mac's ShareAudioSDP.
abstract final class ShareAudioSdp {
  /// What the game's sound is sent at.
  static const kbps = 128;

  /// Opus frames of 10 ms rather than WebRTC's 20: the jitter buffer can hold less.
  static const frameMs = 10;

  /// Every Opus format of [sdp] asking for stereo, and, with [kbps], for that average bit rate
  /// with in-band FEC and no silence suppression. A viewer applies it to its own answer (WebRTC
  /// decodes stereo only when the receiver's description asks for it); the host applies it, with
  /// the rate, to the answer before taking it (the sender encodes as the remote description
  /// asks).
  static String stereoOpus(String sdp, {int? kbps, int? frameMs}) {
    final payloads = [
      for (final match in RegExp(r'a=rtpmap:(\d+) opus/48000/2', caseSensitive: false).allMatches(sdp)) match.group(1)!,
    ];
    if (payloads.isEmpty) return sdp;
    final newline = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(newline);
    final wanted = [
      ('stereo', '1'),
      ('sprop-stereo', '1'),
      if (kbps != null) ...[('maxaveragebitrate', '${kbps * 1000}'), ('useinbandfec', '1'), ('usedtx', '0')],
    ];
    for (final payload in payloads) {
      final prefix = 'a=fmtp:$payload ';
      final index = lines.indexWhere((line) => line.startsWith(prefix));
      if (index >= 0) {
        lines[index] = prefix + _merge(lines[index].substring(prefix.length), wanted);
      } else {
        final rtpmap = lines.indexWhere((line) => line.startsWith('a=rtpmap:$payload '));
        if (rtpmap >= 0) lines.insert(rtpmap + 1, prefix + _merge('', wanted));
      }
    }
    final audio = lines.indexWhere((line) => line.startsWith('m=audio '));
    if (frameMs != null && audio >= 0) {
      var end = lines.indexWhere((line) => line.startsWith('m='), audio + 1);
      if (end < 0) end = lines.length;
      final ptime = lines.sublist(audio + 1, end).indexWhere((line) => line.startsWith('a=ptime:'));
      if (ptime >= 0) {
        lines[audio + 1 + ptime] = 'a=ptime:$frameMs';
      } else {
        var last = end - 1;
        while (last > audio && lines[last].isEmpty) {
          last--;
        }
        lines.insert(last + 1, 'a=ptime:$frameMs');
      }
    }
    return lines.join(newline);
  }

  /// Whether [sdp] has an audio section that is not turned down and carries Opus.
  static bool takesOpus(String sdp) {
    final newline = sdp.contains('\r\n') ? '\r\n' : '\n';
    var inAudio = false, opus = false, rejected = false, inactive = false;
    bool done() => inAudio && opus && !rejected && !inactive;
    for (final line in sdp.split(newline)) {
      if (line.startsWith('m=')) {
        if (done()) return true;
        inAudio = line.startsWith('m=audio ');
        rejected = line.startsWith('m=audio 0 ');
        opus = false;
        inactive = false;
      } else if (inAudio) {
        final lower = line.toLowerCase();
        if (lower.startsWith('a=rtpmap:') && lower.contains(' opus/48000')) opus = true;
        if (line == 'a=inactive' || line == 'a=sendonly') inactive = true;
      }
    }
    return done();
  }

  static String _merge(String existing, List<(String, String)> wanted) {
    final pairs = <(String, String)>[
      for (final part in existing.split(';'))
        if (part.trim().isNotEmpty)
          () {
            final item = part.trim();
            final at = item.indexOf('=');
            return at < 0 ? (item, '') : (item.substring(0, at), item.substring(at + 1));
          }(),
    ];
    for (final (key, value) in wanted) {
      final index = pairs.indexWhere((pair) => pair.$1.toLowerCase() == key);
      if (index >= 0) {
        pairs[index] = (pairs[index].$1, value);
      } else {
        pairs.add((key, value));
      }
    }
    return [for (final (key, value) in pairs) value.isEmpty ? key : '$key=$value'].join(';');
  }
}

/// A controller as a share play viewer's launcher sends it to the host: the 80-byte input packet
/// the engine's RemotePad takes (the phone's layout: magic, version, size, sequence, flags, sent
/// time, session, buttons, sticks, triggers, touch, motion). The Mac's SharePadState.
abstract final class SharePadPacket {
  /// The engine's pad button bits (libScePad).
  static const l3 = 0x0002, r3 = 0x0004, options = 0x0008;
  static const up = 0x0010, right = 0x0020, down = 0x0040, left = 0x0080;
  static const l2 = 0x0100, r2 = 0x0200, l1 = 0x0400, r1 = 0x0800;
  static const triangle = 0x1000, circle = 0x2000, cross = 0x4000, square = 0x8000;
  static const touchPad = 0x100000;

  /// The launcher's buttons as the engine's bits: south is Cross, north Triangle; Select (View,
  /// Create) and the touchpad's click are the touchpad, as the Mac reads a pad without one.
  static const bits = {
    PadButton.south: cross,
    PadButton.east: circle,
    PadButton.west: square,
    PadButton.north: triangle,
    PadButton.l1: l1,
    PadButton.r1: r1,
    PadButton.l3: l3,
    PadButton.r3: r3,
    PadButton.start: options,
    PadButton.dpadUp: up,
    PadButton.dpadDown: down,
    PadButton.dpadLeft: left,
    PadButton.dpadRight: right,
    PadButton.touchpad: touchPad,
    PadButton.select: touchPad,
  };

  /// The buttons of [state], with L2 and R2 pressed once their triggers are a tenth in.
  static int buttons(PadState state) {
    var buttons = 0;
    for (final button in state.pressed) {
      buttons |= bits[button] ?? 0;
    }
    if (state.l2 > 0.1 || state.pressed.contains(PadButton.l2)) buttons |= l2;
    if (state.r2 > 0.1 || state.pressed.contains(PadButton.r2)) buttons |= r2;
    return buttons;
  }

  /// A stick axis from -1 to 1 (down and right positive, as the launcher reads them): 0 to 255,
  /// 128 at the centre, up is 0.
  static int axis(double value) => ((value.clamp(-1.0, 1.0) + 1) * 127.5).round().clamp(0, 255);

  static int trigger(double value) => (value.clamp(0.0, 1.0) * 255).round();

  static Uint8List packet(PadState state, {required int sequence, required int sentMicros, required int session}) {
    final bytes = Uint8List(RemotePacket.inputSize);
    final data = ByteData.sublistView(bytes)
      ..setUint32(0, RemotePacket.inputMagic, Endian.little)
      ..setUint16(4, RemotePacket.version, Endian.little)
      ..setUint16(6, RemotePacket.inputSize, Endian.little)
      ..setUint32(8, sequence & 0xFFFFFFFF, Endian.little)
      ..setUint64(16, sentMicros, Endian.little)
      ..setUint64(24, session, Endian.little)
      ..setUint32(32, buttons(state), Endian.little);
    bytes[36] = axis(state.leftX);
    bytes[37] = axis(state.leftY);
    bytes[38] = axis(state.rightX);
    bytes[39] = axis(state.rightY);
    bytes[40] = trigger(state.l2);
    bytes[41] = trigger(state.r2);
    // No motion: gravity straight down, as the phone sends it.
    data.setFloat32(60, 9.80665, Endian.little);
    return bytes;
  }
}
