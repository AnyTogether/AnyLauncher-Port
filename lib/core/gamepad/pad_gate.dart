import 'feel.dart';
import 'pad_navigation.dart';

/// Lets a controller reach the launcher only while the launcher's window is in front.
///
/// The readers (XInput and winmm on Windows, evdev on Linux) see every controller whichever window
/// is in front: the pad a game is played with is the launcher's pad too. So while a game's window
/// (or any other window) is in front, nothing but PS/Guide gets through, which brings the
/// launcher in front (and from it, back to the game). When the launcher stops being in front, the
/// navigator lets go of what it held, so a held direction does not keep moving behind the game.
///
/// When the launcher comes back in front, whatever is still held from before stays quiet: a
/// button pressed behind it must be let go and pressed again (the press that came back, a held
/// Cross from the game, does not also act in the launcher), and a stick still pushed must come
/// back to the middle before it moves anything.
class PadGate {
  PadGate(this.forward, {required this.inFront, this.log});

  /// Where the events that get through go (the navigator).
  final void Function(PadEvent event) forward;

  /// Whether the launcher's window is in front now (asked at each event).
  final bool Function() inFront;

  /// One line for each press that was kept from the launcher, and each time the gate opens or
  /// closes (a debug log; nothing when not given).
  final void Function(String line)? log;

  final Map<String, _RawPad> _pads = {};
  bool _open = true;

  /// Whether the last event found the launcher in front.
  bool get open => _open;

  /// The buttons of [pad] held since before the launcher came back in front, which do nothing
  /// until they are let go.
  Set<PadButton> waitingForRelease(String pad) => {...?_pads[pad]?.swallowed};

  /// Whether [pad]'s stick is held since before the launcher came back in front.
  bool stickWaiting(String pad) => _pads[pad]?.stickSwallowed ?? false;

  void handle(PadEvent event) {
    final raw = _pads.putIfAbsent(event.pad, _RawPad.new);
    switch (event) {
      case PadButtonEvent(:final button, :final down):
        down ? raw.pressed.add(button) : raw.pressed.remove(button);
      case PadAxisEvent(:final axis, :final value):
        if (axis == PadAxis.leftX) {
          raw.x = value;
        } else {
          raw.y = value;
        }
      case PadGone():
        _pads.remove(event.pad);
    }
    final front = inFront();
    if (front != _open) {
      if (front) {
        _reopen();
      } else {
        close();
      }
    }
    if (event is PadGone) return forward(event);
    if (!front) {
      // Behind a game: only PS/Guide, which brings the launcher in front.
      if (event is PadButtonEvent && event.button == PadButton.guide) return forward(event);
      if (event is PadButtonEvent && event.down) log?.call('pad: ${event.button.name} ignored, launcher not in front');
      return;
    }
    switch (event) {
      case PadButtonEvent(:final button):
        // A held button let go: the navigator never saw it go down (but for PS, which it did), so
        // letting go is harmless. (A press of a button still waiting means its release was
        // missed: it counts as a new press.)
        raw.swallowed.remove(button);
        forward(event);
      case PadAxisEvent():
        if (raw.stickSwallowed) {
          if (!raw.centred) return;
          raw.stickSwallowed = false;
          // Back in the middle: the navigator's stick starts from here.
          forward(PadAxisEvent(event.pad, PadAxis.leftX, raw.x));
          forward(PadAxisEvent(event.pad, PadAxis.leftY, raw.y));
          return;
        }
        forward(event);
      case PadGone():
        break;
    }
  }

  /// The launcher went behind: the navigator lets go of every pad (a held direction stops).
  void close() {
    if (!_open) return;
    _open = false;
    log?.call('pad: launcher not in front, only PS gets through');
    for (final pad in _pads.keys) {
      forward(PadGone(pad));
    }
  }

  /// The launcher is in front again: what is held now waits to be let go.
  void _reopen() {
    _open = true;
    for (final raw in _pads.values) {
      raw.swallowed
        ..clear()
        ..addAll(raw.pressed);
      raw.stickSwallowed = !raw.centred;
    }
    log?.call('pad: launcher in front again');
  }
}

class _RawPad {
  final Set<PadButton> pressed = {};
  final Set<PadButton> swallowed = {};
  double x = 0;
  double y = 0;
  bool stickSwallowed = false;

  bool get centred => x.abs() < StickGate.release && y.abs() < StickGate.release;
}
