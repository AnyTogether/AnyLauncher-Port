import 'dart:convert';
import 'dart:typed_data';

import 'remote_protocol.dart';

/// The engine's pad button bits (libScePad).
abstract final class PadBits {
  static const l3 = 0x0002, r3 = 0x0004, options = 0x0008;
  static const up = 0x0010, right = 0x0020, down = 0x0040, left = 0x0080;
  static const l2 = 0x0100, r2 = 0x0200, l1 = 0x0400, r1 = 0x0800;
  static const triangle = 0x1000, circle = 0x2000, cross = 0x4000, square = 0x8000;
  static const touchPad = 0x100000;
}

/// The whole pad as a browser holds it, and the 80-byte input packet of the engine's RemotePad
/// (the phone app's layout: magic, version, size, sequence, flags, sent time, session, buttons,
/// sticks, triggers, touch, motion).
class BrowserPadState {
  BrowserPadState({this.buttons = 0, List<int>? sticks, this.l2 = 0, this.r2 = 0, List<(int, int, int)>? touches})
    : sticks = sticks ?? [128, 128, 128, 128],
      touches = touches ?? [];

  int buttons;

  /// Left x, left y, right x, right y: 0 to 255, 128 at the centre, up is 0.
  List<int> sticks;
  int l2;
  int r2;

  /// Fingers on the touchpad (id, x, y), at most two, in its 1920 x 1080 space.
  List<(int, int, int)> touches;

  bool get neutral => this == BrowserPadState();

  Uint8List packet({required int sequence, required int sentMicros, required int session}) {
    final bytes = Uint8List(RemotePacket.inputSize);
    final data = ByteData.sublistView(bytes)
      ..setUint32(0, RemotePacket.inputMagic, Endian.little)
      ..setUint16(4, RemotePacket.version, Endian.little)
      ..setUint16(6, RemotePacket.inputSize, Endian.little)
      ..setUint32(8, sequence & 0xFFFFFFFF, Endian.little)
      ..setUint64(16, sentMicros, Endian.little)
      ..setUint64(24, session, Endian.little)
      ..setUint32(32, buttons, Endian.little);
    for (var axis = 0; axis < 4; axis++) {
      bytes[36 + axis] = sticks[axis];
    }
    bytes[40] = l2;
    bytes[41] = r2;
    for (var index = 0; index < touches.length && index < 2; index++) {
      final (id, x, y) = touches[index];
      final offset = 44 + index * 6;
      bytes[offset] = 1;
      bytes[offset + 1] = id;
      data
        ..setUint16(offset + 2, x, Endian.little)
        ..setUint16(offset + 4, y, Endian.little);
    }
    // No motion: gravity straight down, as the phone sends it.
    data.setFloat32(60, 9.80665, Endian.little);
    return bytes;
  }

  @override
  bool operator ==(Object other) =>
      other is BrowserPadState &&
      other.buttons == buttons &&
      other.l2 == l2 &&
      other.r2 == r2 &&
      _same(other.sticks, sticks) &&
      _same(other.touches, touches);

  @override
  int get hashCode => Object.hash(buttons, l2, r2, Object.hashAll(sticks), Object.hashAll(touches));

  static bool _same<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

/// What the browser pad page says on its WebSocket (BrowserPadInput.swift has the same):
///
/// - `{"t":"pad","b":bits,"s":[lx,ly,rx,ry],"l2":0-255,"r2":0-255,"tp":[[id,x,y]]}`: the whole pad,
///   sent on every change and again every 200 ms while nothing changes;
/// - `{"t":"btn","n":"ps"|"create"}`: the launcher's PS and Create buttons, as the phone app sends;
/// - `{"t":"ping","at":ms}`, answered with a pong; `{"t":"lat","ms":ms}`, the latency it measured.
sealed class BrowserPadMessage {
  const BrowserPadMessage();

  /// The pad buttons a page may hold: every libScePad bit the phone app sends, nothing else.
  static const buttonMask = 0x0002 | 0x0004 | 0x0008 | 0x00F0 | 0x0F00 | 0xF000 | 0x100000;

  /// A text frame longer than this is not one of the page's.
  static const maxLength = 1024;

  static BrowserPadMessage? parse(String text) {
    if (utf8.encode(text).length > maxLength) return null;
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    switch (json['t']) {
      case 'pad':
        final state = _pad(json);
        return state == null ? null : BrowserPadInput(state);
      case 'btn':
        final name = json['n'];
        return name == 'ps' || name == 'create' ? BrowserPadButton(name as String) : null;
      case 'ping':
        final at = _number(json['at']);
        return at == null ? null : BrowserPadPing(at);
      case 'lat':
        final ms = _number(json['ms']);
        return ms == null || ms < 0 || ms >= 10000 ? null : BrowserPadLatency(ms);
      default:
        return null;
    }
  }

  /// The pad from a `pad` message: buttons kept to the pad's own bits, every value clamped; a
  /// trigger pulled shows as its button and a trigger's button as a full pull.
  static BrowserPadState? _pad(Map<String, dynamic> json) {
    final bits = _number(json['b']);
    if (bits == null || bits < 0 || bits > 0xFFFFFFFF) return null;
    final state = BrowserPadState(buttons: bits.toInt() & buttonMask);
    if (json.containsKey('s')) {
      final sticks = json['s'];
      if (sticks is! List || sticks.length != 4) return null;
      final values = <int>[];
      for (final axis in sticks) {
        final value = _number(axis);
        if (value == null) return null;
        values.add(_byte(value));
      }
      state.sticks = values;
    }
    state
      ..l2 = _byte(_number(json['l2']) ?? 0)
      ..r2 = _byte(_number(json['r2']) ?? 0);
    if (state.l2 > 0) {
      state.buttons |= PadBits.l2;
    } else if (state.buttons & PadBits.l2 != 0) {
      state.l2 = 255;
    }
    if (state.r2 > 0) {
      state.buttons |= PadBits.r2;
    } else if (state.buttons & PadBits.r2 != 0) {
      state.r2 = 255;
    }
    final points = json['tp'];
    if (points is List) {
      for (final point in points.take(2)) {
        if (point is! List || point.length != 3) continue;
        final id = _number(point[0]), x = _number(point[1]), y = _number(point[2]);
        if (id == null || x == null || y == null) continue;
        state.touches.add((id.clamp(0, 255).toInt(), x.clamp(0, 1919).toInt(), y.clamp(0, 1079).toInt()));
      }
    }
    return state;
  }

  static double? _number(Object? value) {
    if (value is! num) return null;
    final number = value.toDouble();
    return number.isFinite ? number : null;
  }

  static int _byte(double value) => value.round().clamp(0, 255);
}

class BrowserPadInput extends BrowserPadMessage {
  const BrowserPadInput(this.state);
  final BrowserPadState state;
}

class BrowserPadButton extends BrowserPadMessage {
  const BrowserPadButton(this.name);
  final String name;
}

class BrowserPadPing extends BrowserPadMessage {
  const BrowserPadPing(this.at);
  final double at;
}

class BrowserPadLatency extends BrowserPadMessage {
  const BrowserPadLatency(this.milliseconds);
  final double milliseconds;
}

/// What the launcher tells the page, as the JSON text it sends.
abstract final class BrowserPadReply {
  static String wait() => _text({'t': 'wait'});
  static String pairing(String code) => _text({'code': code, 't': 'pairing'});
  static String welcome(String host) => _text({'host': host, 't': 'welcome'});
  static String busy() => _text({'t': 'busy'});
  static String rejected(String reason) => _text({'reason': reason, 't': 'rejected'});
  static String player(int number) => _text({'n': number, 't': 'player'});
  static String look(String deep, String middle, String accent) =>
      _text({'accent': accent, 'deep': deep, 'middle': middle, 't': 'look'});
  static String pong(double at) => _text({'at': at, 't': 'pong'});

  /// The game's answer packet (vibration and light bar) as the page hears it; null for anything else.
  static String? output(List<int> packet) {
    if (!RemotePacket.isOutput(packet)) return null;
    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    return _text({
      'big': packet[24],
      if (packet[26] != 0) 'rgb': '#${hex(packet[27])}${hex(packet[28])}${hex(packet[29])}',
      'small': packet[25],
      't': 'out',
    });
  }

  static String _text(Map<String, Object> fields) => jsonEncode(fields);
}
