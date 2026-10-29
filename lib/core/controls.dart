import 'dart:convert';
import 'dart:io';

/// A pad input a keyboard key or mouse button can press, named as the engine's anyps5-input.ini
/// names it.
enum PadAction {
  cross('Cross'),
  circle('Circle'),
  square('Square'),
  triangle('Triangle'),
  l1('L1'),
  r1('R1'),
  l2('L2'),
  r2('R2'),
  l3('L3'),
  r3('R3'),
  options('Options'),
  touchLeft('TouchLeft'),
  touchRight('TouchRight'),
  up('Up'),
  down('Down'),
  left('Left'),
  right('Right'),
  leftStickUp('LeftStickUp'),
  leftStickDown('LeftStickDown'),
  leftStickLeft('LeftStickLeft'),
  leftStickRight('LeftStickRight'),
  rightStickUp('RightStickUp'),
  rightStickDown('RightStickDown'),
  rightStickLeft('RightStickLeft'),
  rightStickRight('RightStickRight'),

  /// Held, the keyboard sticks tilt only by the tuning's stick modifier scale, for walking.
  stickModifier('StickModifier');

  const PadAction(this.key);

  /// The name in the input file.
  final String key;

  static PadAction? byKey(String key) {
    for (final action in values) {
      if (action.key == key) return action;
    }
    return null;
  }
}

/// The input file's settings for the controller sticks, the mouse as the right stick and the
/// keyboard sticks, in the steps the launcher shows them: whole percentages, tenths and
/// milliseconds. The defaults are the engine's, and only changed ones are written.
class InputTuning {
  const InputTuning({
    this.leftDeadzone = 0,
    this.rightDeadzone = 0,
    this.mouseSensitivity = 10,
    this.mouseVerticalScale = 10,
    this.mouseCurve = 10,
    this.mouseDeadzoneOffset = 20,
    this.mouseMaxSpeed = 10,
    this.mouseSmoothingMs = 10,
    this.mouseDecayMs = 30,
    this.stickModifierScale = 50,
    this.keyboardRampMs = 0,
    this.triggerRampMs = 0,
  });

  /// Settings saved by an older launcher miss the newer fields, which keep their defaults.
  factory InputTuning.fromJson(Map<String, dynamic> json) {
    const defaults = InputTuning();
    int read(String key, int fallback) => (json[key] as num?)?.toInt() ?? fallback;
    return InputTuning(
      leftDeadzone: read('leftDeadzone', defaults.leftDeadzone),
      rightDeadzone: read('rightDeadzone', defaults.rightDeadzone),
      mouseSensitivity: read('mouseSensitivity', defaults.mouseSensitivity),
      mouseVerticalScale: read('mouseVerticalScale', defaults.mouseVerticalScale),
      mouseCurve: read('mouseCurve', defaults.mouseCurve),
      mouseDeadzoneOffset: read('mouseDeadzoneOffset', defaults.mouseDeadzoneOffset),
      mouseMaxSpeed: read('mouseMaxSpeed', defaults.mouseMaxSpeed),
      mouseSmoothingMs: read('mouseSmoothingMs', defaults.mouseSmoothingMs),
      mouseDecayMs: read('mouseDecayMs', defaults.mouseDecayMs),
      stickModifierScale: read('stickModifierScale', defaults.stickModifierScale),
      keyboardRampMs: read('keyboardRampMs', defaults.keyboardRampMs),
      triggerRampMs: read('triggerRampMs', defaults.triggerRampMs),
    );
  }

  final int leftDeadzone;
  final int rightDeadzone;
  final int mouseSensitivity;
  final int mouseVerticalScale;
  final int mouseCurve;
  final int mouseDeadzoneOffset;
  final int mouseMaxSpeed;
  final int mouseSmoothingMs;
  final int mouseDecayMs;
  final int stickModifierScale;
  final int keyboardRampMs;
  final int triggerRampMs;

  Map<String, int> toJson() => {
    'leftDeadzone': leftDeadzone,
    'rightDeadzone': rightDeadzone,
    'mouseSensitivity': mouseSensitivity,
    'mouseVerticalScale': mouseVerticalScale,
    'mouseCurve': mouseCurve,
    'mouseDeadzoneOffset': mouseDeadzoneOffset,
    'mouseMaxSpeed': mouseMaxSpeed,
    'mouseSmoothingMs': mouseSmoothingMs,
    'mouseDecayMs': mouseDecayMs,
    'stickModifierScale': stickModifierScale,
    'keyboardRampMs': keyboardRampMs,
    'triggerRampMs': triggerRampMs,
  };

  InputTuning copyWith({
    int? leftDeadzone,
    int? rightDeadzone,
    int? mouseSensitivity,
    int? mouseVerticalScale,
    int? mouseCurve,
    int? mouseDeadzoneOffset,
    int? mouseMaxSpeed,
    int? mouseSmoothingMs,
    int? mouseDecayMs,
    int? stickModifierScale,
    int? keyboardRampMs,
    int? triggerRampMs,
  }) => InputTuning(
    leftDeadzone: leftDeadzone ?? this.leftDeadzone,
    rightDeadzone: rightDeadzone ?? this.rightDeadzone,
    mouseSensitivity: mouseSensitivity ?? this.mouseSensitivity,
    mouseVerticalScale: mouseVerticalScale ?? this.mouseVerticalScale,
    mouseCurve: mouseCurve ?? this.mouseCurve,
    mouseDeadzoneOffset: mouseDeadzoneOffset ?? this.mouseDeadzoneOffset,
    mouseMaxSpeed: mouseMaxSpeed ?? this.mouseMaxSpeed,
    mouseSmoothingMs: mouseSmoothingMs ?? this.mouseSmoothingMs,
    mouseDecayMs: mouseDecayMs ?? this.mouseDecayMs,
    stickModifierScale: stickModifierScale ?? this.stickModifierScale,
    keyboardRampMs: keyboardRampMs ?? this.keyboardRampMs,
    triggerRampMs: triggerRampMs ?? this.triggerRampMs,
  );

  /// `Setting = Value` lines for the settings that differ from the engine's defaults, clamped to
  /// the ranges the engine accepts.
  List<String> get lines {
    const defaults = InputTuning();
    int clamp(int value, int low, int high) => value < low ? low : (value > high ? high : value);
    String whole(int value) => '$value';
    String tenths(int value) => _decimal(value / 10);
    String hundredths(int value) => _decimal(value / 100);
    final settings = <(String, int, int, String Function(int))>[
      ('LeftStickDeadzone', clamp(leftDeadzone, 0, 90), defaults.leftDeadzone, whole),
      ('RightStickDeadzone', clamp(rightDeadzone, 0, 90), defaults.rightDeadzone, whole),
      ('MouseSensitivity', clamp(mouseSensitivity, 1, 100), defaults.mouseSensitivity, tenths),
      ('MouseVerticalScale', clamp(mouseVerticalScale, 1, 100), defaults.mouseVerticalScale, tenths),
      ('MouseCurve', clamp(mouseCurve, 2, 50), defaults.mouseCurve, tenths),
      ('MouseDeadzoneOffset', clamp(mouseDeadzoneOffset, 0, 90), defaults.mouseDeadzoneOffset, hundredths),
      ('MouseMaxSpeed', clamp(mouseMaxSpeed, 1, 100), defaults.mouseMaxSpeed, tenths),
      ('MouseSmoothingMs', clamp(mouseSmoothingMs, 0, 500), defaults.mouseSmoothingMs, whole),
      ('MouseDecayMs', clamp(mouseDecayMs, 1, 1000), defaults.mouseDecayMs, whole),
      ('StickModifierScale', clamp(stickModifierScale, 5, 100), defaults.stickModifierScale, hundredths),
      ('KeyboardRampMs', clamp(keyboardRampMs, 0, 2000), defaults.keyboardRampMs, whole),
      ('TriggerRampMs', clamp(triggerRampMs, 0, 2000), defaults.triggerRampMs, whole),
    ];
    return [
      for (final (name, value, fallback, format) in settings)
        if (value != fallback) '$name = ${format(value)}',
    ];
  }

  /// A decimal as Swift's String(Double) writes it: 1.0, 0.5, 2.5.
  static String _decimal(double value) {
    final text = value.toString();
    return text.contains('.') || text.contains('e') ? text : '$text.0';
  }

  @override
  bool operator ==(Object other) => other is InputTuning && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The keyboard and mouse layout a game starts with: the launcher's own layout, with the keys the
/// user moved. Every action is written to the input file, so none of the engine's scattered
/// built-in keys (C for Circle, I for Triangle) stay behind.
abstract final class Controls {
  /// Stands for "no key": the engine refuses an empty source, and keyboards have no F24.
  static const unbound = 'KEY:F24';

  /// Left hand on WASD for the left stick, right hand on JKLI for the face buttons, as console
  /// emulators lay them out; the mouse keeps its clicks.
  static const layout = <PadAction, List<String>>{
    PadAction.cross: ['KEY:K', 'KEY:Space', 'KEY:Return'],
    PadAction.circle: ['KEY:L'],
    PadAction.square: ['KEY:J', 'MOUSE:Left'],
    PadAction.triangle: ['KEY:I'],
    PadAction.l1: ['KEY:Q'],
    PadAction.r1: ['KEY:E'],
    PadAction.l2: ['KEY:U', 'MOUSE:X1'],
    PadAction.r2: ['KEY:O', 'MOUSE:Right'],
    PadAction.l3: ['KEY:Left Shift'],
    PadAction.r3: ['KEY:Left Ctrl'],
    PadAction.options: ['KEY:Escape'],
    PadAction.touchLeft: ['KEY:Backspace'],
    PadAction.touchRight: ['KEY:Tab'],
    PadAction.up: ['KEY:Up', 'WHEEL:Up'],
    PadAction.down: ['KEY:Down', 'WHEEL:Down'],
    PadAction.left: ['KEY:Left'],
    PadAction.right: ['KEY:Right'],
    PadAction.leftStickUp: ['KEY:W'],
    PadAction.leftStickDown: ['KEY:S'],
    PadAction.leftStickLeft: ['KEY:A'],
    PadAction.leftStickRight: ['KEY:D'],
    PadAction.rightStickUp: ['KEY:T'],
    PadAction.rightStickDown: ['KEY:G'],
    PadAction.rightStickLeft: ['KEY:F'],
    PadAction.rightStickRight: ['KEY:H'],
  };

  /// The sources an action has, the user's changes over the layout.
  static List<String> sources(PadAction action, Map<String, List<String>> changes) =>
      changes[action.key] ?? layout[action] ?? const [];

  /// The changes after giving [key] (a KEY: source) to [action]: it replaces the action's keys,
  /// keeps its mouse buttons, and leaves every other action that had it.
  static Map<String, List<String>> assign(String key, PadAction action, Map<String, List<String>> changes) {
    final result = Map<String, List<String>>.of(changes);
    for (final other in PadAction.values) {
      if (other == action) continue;
      final current = sources(other, changes);
      if (current.contains(key)) result[other.key] = current.where((source) => source != key).toList();
    }
    result[action.key] = [key, ...sources(action, changes).where((source) => !source.startsWith('KEY:'))];
    result.removeWhere((name, value) {
      final pad = PadAction.byKey(name);
      final defaults = pad == null ? null : layout[pad];
      return defaults != null && _same(defaults, value);
    });
    return result;
  }

  /// The changes with [action] back to the layout's keys.
  static Map<String, List<String>> reset(PadAction action, Map<String, List<String>> changes) =>
      Map.of(changes)..remove(action.key);

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// anyps5-input.ini text for the changes and the tuning.
  static String file(Map<String, List<String>> changes, {InputTuning tuning = const InputTuning()}) {
    final lines = ["# Written by AnyPS5 at each start; change the keys in the game's settings there."];
    for (final action in PadAction.values) {
      final current = sources(action, changes);
      for (final source in current.isEmpty ? const [unbound] : current) {
        lines.add('${action.key} = $source');
      }
    }
    lines.addAll(tuning.lines);
    return '${lines.join('\n')}\n';
  }

  /// Writes the input file for ANYPS5_INPUT_CONFIG, atomically.
  static void write(String path, Map<String, List<String>> changes, {InputTuning tuning = const InputTuning()}) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temporary = File('$path.tmp');
    temporary.writeAsStringSync(Controls.file(changes, tuning: tuning), flush: true);
    temporary.renameSync(path);
  }

  /// The SDL scancode name of a USB HID keyboard usage (the key's position on a US layout, as SDL
  /// reads scancodes, and as Flutter's PhysicalKeyboardKey.usbHidUsage carries it in its low 16
  /// bits), null for keys a binding cannot use. `;` and `#` are left out: the input file treats
  /// them as comments.
  static String? keyName(int usage) => _keyNames[usage & 0xFFFF];

  static final Map<int, String> _keyNames = {
    for (var index = 0; index < 26; index++) 0x04 + index: String.fromCharCode(0x41 + index),
    for (var index = 0; index < 9; index++) 0x1E + index: '${index + 1}',
    0x27: '0',
    0x28: 'Return',
    0x29: 'Escape',
    0x2A: 'Backspace',
    0x2B: 'Tab',
    0x2C: 'Space',
    0x2D: '-',
    0x2E: '=',
    0x2F: '[',
    0x30: ']',
    0x31: r'\',
    0x34: "'",
    0x35: '`',
    0x36: ',',
    0x37: '.',
    0x38: '/',
    0x39: 'CapsLock',
    for (var index = 0; index < 12; index++) 0x3A + index: 'F${index + 1}',
    0x4A: 'Home',
    0x4B: 'PageUp',
    0x4C: 'Delete',
    0x4D: 'End',
    0x4E: 'PageDown',
    0x4F: 'Right',
    0x50: 'Left',
    0x51: 'Down',
    0x52: 'Up',
    0x54: 'Keypad /',
    0x55: 'Keypad *',
    0x56: 'Keypad -',
    0x57: 'Keypad +',
    0x58: 'Keypad Enter',
    for (var index = 0; index < 9; index++) 0x59 + index: 'Keypad ${index + 1}',
    0x62: 'Keypad 0',
    0x63: 'Keypad .',
    0xE0: 'Left Ctrl',
    0xE1: 'Left Shift',
    0xE2: 'Left Alt',
    0xE3: 'Left GUI',
    0xE4: 'Right Ctrl',
    0xE5: 'Right Shift',
    0xE6: 'Right Alt',
    0xE7: 'Right GUI',
  };

  /// A source as the launcher shows it: the key's name, or the mouse button or wheel in words.
  /// [format] gives the words, the launcher's T.format: the keys mouseLeft, mouseRight,
  /// mouseMiddle, mouseButton (with the button's name), wheelUp, wheelDown, keySuper and keyEnter
  /// in assets/l10n.
  static String label(String source, String Function(String key, List<Object> arguments) format) {
    final colon = source.indexOf(':');
    final kind = colon < 0 ? '' : source.substring(0, colon);
    final name = colon < 0 ? source : source.substring(colon + 1);
    switch (kind) {
      case 'MOUSE':
        return switch (name) {
          'Left' => format('mouseLeft', const []),
          'Right' => format('mouseRight', const []),
          'Middle' => format('mouseMiddle', const []),
          _ => format('mouseButton', [name]),
        };
      case 'WHEEL':
        return format(name == 'Up' ? 'wheelUp' : 'wheelDown', const []);
      default:
        return switch (name) {
          'Left GUI' || 'Right GUI' => format('keySuper', const []),
          'Return' => format('keyEnter', const []),
          _ => name,
        };
    }
  }
}
