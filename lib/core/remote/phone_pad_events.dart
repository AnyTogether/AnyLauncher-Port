import 'dart:typed_data';

import '../gamepad/pad_navigation.dart';
import 'browser_pad_input.dart' show PadBits;
import 'remote_protocol.dart';

/// A phone's pad (the AnyPS5 Remote app's, or a browser pad's through the phone server) as the
/// controller events the launcher's navigator reads: each input packet compared with the one
/// before, a button pressed or let go and the left stick moved said once. While no game is in
/// front the launcher moves with it as with a controller; the packets go on to the game as
/// before.
class PhonePadEvents {
  PhonePadEvents(this.onEvent);

  final void Function(PadEvent event) onEvent;

  final Map<String, _PhonePad> _pads = {};

  /// The pad's name in the navigator: one per phone.
  static String padId(String deviceId) => 'phone:$deviceId';

  /// The engine's bits as the navigator's buttons. Options is [PadButton.start].
  static const buttons = {
    PadBits.cross: PadButton.south,
    PadBits.circle: PadButton.east,
    PadBits.square: PadButton.west,
    PadBits.triangle: PadButton.north,
    PadBits.l1: PadButton.l1,
    PadBits.r1: PadButton.r1,
    PadBits.l2: PadButton.l2,
    PadBits.r2: PadButton.r2,
    PadBits.l3: PadButton.l3,
    PadBits.r3: PadButton.r3,
    PadBits.options: PadButton.start,
    PadBits.up: PadButton.dpadUp,
    PadBits.down: PadButton.dpadDown,
    PadBits.left: PadButton.dpadLeft,
    PadBits.right: PadButton.dpadRight,
    PadBits.touchPad: PadButton.touchpad,
  };

  /// One input packet from [deviceId]; anything that is not one is ignored.
  void packet(String deviceId, List<int> data) {
    if (RemotePacket.inputSession(data) == null) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final bits = ByteData.sublistView(bytes).getUint32(32, Endian.little);
    final x = _axis(bytes[36]), y = _axis(bytes[37]);
    final pad = padId(deviceId);
    final before = _pads.putIfAbsent(deviceId, _PhonePad.new);
    for (final MapEntry(key: bit, value: button) in buttons.entries) {
      final down = bits & bit != 0;
      if (down != (before.bits & bit != 0)) onEvent(PadButtonEvent(pad, button, down: down));
    }
    before.bits = bits;
    if (x != before.x) {
      before.x = x;
      onEvent(PadAxisEvent(pad, PadAxis.leftX, x));
    }
    if (y != before.y) {
      before.y = y;
      onEvent(PadAxisEvent(pad, PadAxis.leftY, y));
    }
  }

  /// [deviceId] went away: what it held is let go.
  void gone(String deviceId) {
    if (_pads.remove(deviceId) != null) onEvent(PadGone(padId(deviceId)));
  }

  /// A stick byte (0 to 255, 128 the middle, 0 up and left) as -1 to 1.
  static double _axis(int byte) => ((byte - 128) / 127).clamp(-1.0, 1.0);
}

class _PhonePad {
  int bits = 0;
  double x = 0;
  double y = 0;
}
