import '../gamepad/pad_navigation.dart';
import 'pad_info.dart';

/// What a controller reader knows about the pads beyond their presses, for Settings ›
/// Controllers: which pads there are, each one's whole state for the controller test, its light
/// bar and player lights. SDL knows all of it; the fallback readers (XInput and winmm, evdev)
/// give what they can.
abstract class PadInventory {
  /// The pads connected now (Steam's and the remappers' duplicates left out).
  List<PadInfo> get pads;

  /// Called whenever [pads] changes: one came, one went, a battery or connection reading moved.
  set onPadsChanged(void Function()? listener);

  /// Everything [id] holds now; null for a pad the reader does not know.
  PadState? state(String id);

  /// Sets [id]'s light bar (0 to 255 each); false where it has none or the reader cannot.
  bool setLight(String id, int red, int green, int blue);

  /// Player 1's light on the first pad, 2 on the next and so on, where the pads have them.
  void setPlayerLights(List<String> ordered);

  /// What the reader is, for the troubleshooter and the log: "SDL 2.32.10", "XInput and winmm".
  String get readerName;

  /// Pads the system lists but the reader may not open (Linux: /dev/input nodes without read
  /// permission): their names.
  List<String> get refused;
}

/// Each pad's state put together from its events, for the readers that only give events (the
/// fallback ones): the buttons held and the left stick.
class PadEventStates {
  final Map<String, PadState> _states = {};

  PadState? operator [](String pad) => _states[pad];

  void add(PadEvent event) {
    final before = _states[event.pad] ?? PadState.idle;
    switch (event) {
      case PadButtonEvent(:final button, :final down):
        final pressed = {...before.pressed};
        down ? pressed.add(button) : pressed.remove(button);
        _states[event.pad] = PadState(pressed: pressed, leftX: before.leftX, leftY: before.leftY);
      case PadAxisEvent(:final axis, :final value):
        _states[event.pad] = PadState(
          pressed: before.pressed,
          leftX: axis == PadAxis.leftX ? value : before.leftX,
          leftY: axis == PadAxis.leftY ? value : before.leftY,
        );
      case PadGone():
        _states.remove(event.pad);
    }
  }
}
