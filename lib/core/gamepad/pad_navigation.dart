import 'dart:async';

/// A controller's buttons, by place on the pad (Cross is south, Triangle north; on an Xbox pad
/// A is south, Y north). The system readers (Windows XInput and winmm, Linux evdev) turn their
/// own numbers into these.
enum PadButton {
  south,
  east,
  west,
  north,
  l1,
  r1,
  l2,
  r2,
  select,
  start,
  guide,
  l3,
  r3,
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
}

/// The two axes the launcher reads: the left stick, -1 (left, up) to 1 (right, down).
enum PadAxis { leftX, leftY }

/// What a controller did, from a system reader.
sealed class PadEvent {
  const PadEvent(this.pad);

  /// Which controller (a reader's own id, kept while it stays connected).
  final String pad;
}

class PadButtonEvent extends PadEvent {
  const PadButtonEvent(super.pad, this.button, {required this.down});
  final PadButton button;
  final bool down;

  @override
  String toString() => 'PadButtonEvent($pad, $button, ${down ? 'down' : 'up'})';
}

class PadAxisEvent extends PadEvent {
  const PadAxisEvent(super.pad, this.axis, this.value);
  final PadAxis axis;
  final double value;

  @override
  String toString() => 'PadAxisEvent($pad, $axis, $value)';
}

/// A controller left (unplugged, turned off): what it held is let go.
class PadGone extends PadEvent {
  const PadGone(super.pad);
}

/// What the launcher's screens act on, as a controller gives it.
enum PadCommand { left, right, up, down, select, back, options, previousGame, nextGame, home }

/// Controller input as launcher commands, the way the macOS launcher's Input.swift reads a pad:
/// the D-pad and the left stick move (a held direction repeats as a console menu does), Cross/A
/// selects, Circle/B goes back, Triangle/Y and Options open the options, L1 and R1 move between
/// games, PS/Guide brings the launcher in front of the game and back. Any number of pads at
/// once; a pad that goes away lets go of what it held.
class PadNavigator {
  PadNavigator(
    this.onCommand, {
    this.firstRepeat = const Duration(milliseconds: 380),
    this.repeat = const Duration(milliseconds: 85),
  });

  final void Function(PadCommand command) onCommand;
  final Duration firstRepeat;
  final Duration repeat;

  /// How far the stick must lean before it counts as a direction, and how far back it must come
  /// before it lets go (so a stick resting near the edge does not flicker).
  static const press = 0.55;
  static const release = 0.4;

  static const buttons = {
    PadButton.south: PadCommand.select,
    PadButton.east: PadCommand.back,
    PadButton.north: PadCommand.options,
    PadButton.start: PadCommand.options,
    PadButton.l1: PadCommand.previousGame,
    PadButton.r1: PadCommand.nextGame,
    PadButton.guide: PadCommand.home,
  };

  final Map<String, _PadState> _pads = {};
  PadCommand? _held;
  String? _heldBy;
  Timer? _timer;

  /// The direction being repeated, for tests.
  PadCommand? get held => _held;

  void handle(PadEvent event) {
    final state = _pads.putIfAbsent(event.pad, _PadState.new);
    switch (event) {
      case PadButtonEvent(:final button, :final down):
        if (state.pressed.contains(button) == down) return;
        down ? state.pressed.add(button) : state.pressed.remove(button);
        final command = buttons[button];
        if (down && command != null) onCommand(command);
      case PadAxisEvent(:final axis, :final value):
        final leaning = axis == PadAxis.leftX ? state.x : state.y;
        final next = value.abs() >= press ? value : (value.abs() <= release ? 0.0 : (leaning == 0 ? 0.0 : value));
        if (axis == PadAxis.leftX) {
          state.x = next;
        } else {
          state.y = next;
        }
      case PadGone():
        _pads.remove(event.pad);
        if (_heldBy == event.pad) _hold(null, null);
        return;
    }
    _direction(event.pad, state);
  }

  void _direction(String pad, _PadState state) {
    var x = 0.0;
    var y = 0.0;
    if (state.pressed.contains(PadButton.dpadLeft)) x -= 1;
    if (state.pressed.contains(PadButton.dpadRight)) x += 1;
    if (state.pressed.contains(PadButton.dpadUp)) y -= 1;
    if (state.pressed.contains(PadButton.dpadDown)) y += 1;
    if (x == 0 && y == 0) {
      x = state.x;
      y = state.y;
    }
    final PadCommand? command;
    if (x == 0 && y == 0) {
      command = null;
    } else if (x.abs() >= y.abs() && x != 0) {
      command = x > 0 ? PadCommand.right : PadCommand.left;
    } else {
      command = y > 0 ? PadCommand.down : PadCommand.up;
    }
    // Another pad's held direction is only let go by that pad.
    if (command == null && _heldBy != pad) return;
    if (command == _held && (_heldBy == pad || command == null)) return;
    _hold(command, command == null ? null : pad);
  }

  void _hold(PadCommand? command, String? pad) {
    _timer?.cancel();
    _timer = null;
    _held = command;
    _heldBy = pad;
    if (command == null) return;
    onCommand(command);
    _timer = Timer(firstRepeat, () {
      _timer = Timer.periodic(repeat, (_) {
        if (_held case final PadCommand held) onCommand(held);
      });
    });
  }

  void dispose() {
    _timer?.cancel();
    _pads.clear();
    _held = null;
  }
}

class _PadState {
  final Set<PadButton> pressed = {};
  double x = 0;
  double y = 0;
}

/// Where controller events come from on this system.
abstract class PadSource {
  /// Starts reading every controller there is and every one plugged in later.
  void start(void Function(PadEvent event) onEvent);
  void stop();

  /// What the reader found, for the log ("XInput 1, DualSense (winmm) 0").
  String get description;
}

/// No controllers (tests, systems without a reader).
class NoPadSource implements PadSource {
  const NoPadSource();
  @override
  void start(void Function(PadEvent event) onEvent) {}
  @override
  void stop() {}
  @override
  String get description => 'none';
}

/// One controller as a polling reader sees it at one moment: what is held, where the stick is.
class PadSnapshot {
  const PadSnapshot(this.pressed, {this.x = 0, this.y = 0});

  static const idle = PadSnapshot({});

  final Set<PadButton> pressed;
  final double x;
  final double y;

  /// The events that turn [before] into [after] for [pad].
  static List<PadEvent> diff(String pad, PadSnapshot before, PadSnapshot after) => [
    for (final button in PadButton.values)
      if (before.pressed.contains(button) != after.pressed.contains(button))
        PadButtonEvent(pad, button, down: after.pressed.contains(button)),
    if (before.x != after.x) PadAxisEvent(pad, PadAxis.leftX, after.x),
    if (before.y != after.y) PadAxisEvent(pad, PadAxis.leftY, after.y),
  ];
}

/// The system readers' numbers as pad buttons.
abstract final class PadMaps {
  /// XInput's wButtons (XINPUT_GAMEPAD_*; Guide is 0x0400, given by XInputGetStateEx) and its
  /// left stick (up is positive there).
  static PadSnapshot xinput(int buttons, int thumbX, int thumbY) {
    const bits = {
      0x0001: PadButton.dpadUp,
      0x0002: PadButton.dpadDown,
      0x0004: PadButton.dpadLeft,
      0x0008: PadButton.dpadRight,
      0x0010: PadButton.start,
      0x0020: PadButton.select,
      0x0040: PadButton.l3,
      0x0080: PadButton.r3,
      0x0100: PadButton.l1,
      0x0200: PadButton.r1,
      0x0400: PadButton.guide,
      0x1000: PadButton.south,
      0x2000: PadButton.east,
      0x4000: PadButton.west,
      0x8000: PadButton.north,
    };
    return PadSnapshot(
      {
        for (final entry in bits.entries)
          if (buttons & entry.key != 0) entry.value,
      },
      x: _unit(thumbX / 32767),
      y: _unit(-thumbY / 32767),
    );
  }

  /// A PlayStation controller (DualSense, DualShock 4) through winmm's joyGetPosEx, which numbers
  /// its buttons as DirectInput does: Square, Cross, Circle, Triangle, L1, R1, L2, R2, Create,
  /// Options, L3, R3, PS, touchpad. [pov] is the hat in hundredths of a degree (0 up, 9000 right),
  /// 0xFFFF when centred; [x] and [y] the left stick already as -1 to 1.
  static PadSnapshot sonyWinmm(int buttons, int pov, double x, double y) {
    const order = [
      PadButton.west,
      PadButton.south,
      PadButton.east,
      PadButton.north,
      PadButton.l1,
      PadButton.r1,
      PadButton.l2,
      PadButton.r2,
      PadButton.select,
      PadButton.start,
      PadButton.l3,
      PadButton.r3,
      PadButton.guide,
    ];
    return PadSnapshot(
      {
        for (var bit = 0; bit < order.length; bit++)
          if (buttons & (1 << bit) != 0) order[bit],
        ...hat(pov),
      },
      x: _unit(x),
      y: _unit(y),
    );
  }

  /// A POV hat (hundredths of a degree clockwise from up; anything above 36000 is centred) as
  /// D-pad buttons; the diagonals hold two.
  static Set<PadButton> hat(int pov) {
    if (pov < 0 || pov >= 36000) return const {};
    final degrees = pov / 100;
    bool near(double target) {
      final distance = ((degrees - target + 540) % 360 - 180).abs();
      return distance < 67.5;
    }

    return {
      if (near(0)) PadButton.dpadUp,
      if (near(90)) PadButton.dpadRight,
      if (near(180)) PadButton.dpadDown,
      if (near(270)) PadButton.dpadLeft,
    };
  }

  /// A Linux evdev key code (BTN_SOUTH and on, BTN_DPAD_*) as a pad button. The xpad driver
  /// reports an Xbox pad's X as BTN_X (BTN_NORTH) and Y as BTN_Y (BTN_WEST), the other way round
  /// from where they sit; [xbox] puts them back.
  static PadButton? evdevKey(int code, {bool xbox = false}) => switch (code) {
    0x130 => PadButton.south,
    0x131 => PadButton.east,
    0x133 => xbox ? PadButton.west : PadButton.north,
    0x134 => xbox ? PadButton.north : PadButton.west,
    0x136 => PadButton.l1,
    0x137 => PadButton.r1,
    0x138 => PadButton.l2,
    0x139 => PadButton.r2,
    0x13a => PadButton.select,
    0x13b => PadButton.start,
    0x13c => PadButton.guide,
    0x13d => PadButton.l3,
    0x13e => PadButton.r3,
    0x220 => PadButton.dpadUp,
    0x221 => PadButton.dpadDown,
    0x222 => PadButton.dpadLeft,
    0x223 => PadButton.dpadRight,
    _ => null,
  };

  /// An axis value from [minimum] to [maximum] as -1 to 1.
  static double scale(int value, int minimum, int maximum) {
    if (maximum <= minimum) return 0;
    return _unit((value - minimum) / (maximum - minimum) * 2 - 1);
  }

  static double _unit(double value) => value.clamp(-1.0, 1.0);
}
