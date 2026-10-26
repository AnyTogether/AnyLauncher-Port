import 'pad_navigation.dart';

/// What a shortcut does in the launcher (Settings › Shortcuts).
enum LauncherAction {
  /// PS: from the game to the launcher (with the quick menu) and back; held, the home menu in the
  /// launcher, "Close game?" in a game.
  home,

  /// The in-game quick menu (Resume, Game Settings, Close Game) straight away.
  quickMenu,

  /// The game's picture now, into its gallery.
  screenshot,

  /// The last seconds of play from the replay buffer (a screenshot while the buffer is off).
  saveClip,

  /// The launcher's window full screen or back.
  toggleFullscreen,

  /// The settings' sections, the games on the home screen.
  previousSection,
  nextSection;

  /// Whether it acts while a game's window is in front (pads are read whichever window is; the
  /// keyboard only reaches the launcher while it has the keyboard).
  bool get inGame => switch (this) {
    home || quickMenu || screenshot || saveClip => true,
    toggleFullscreen || previousSection || nextSection => false,
  };

  static LauncherAction? byName(String name) {
    for (final action in values) {
      if (action.name == name) return action;
    }
    return null;
  }
}

/// A controller button, or several held together, pressed or held for [ShortcutTiming.hold].
class PadChord {
  PadChord(Set<PadButton> buttons, {this.hold = false}) : buttons = Set.unmodifiable(buttons);

  PadChord.of(PadButton button, {bool hold = false}) : this({button}, hold: hold);

  final Set<PadButton> buttons;
  final bool hold;

  /// The same buttons pressed rather than held, or held rather than pressed.
  PadChord get asPress => PadChord(buttons);
  PadChord get asHold => PadChord(buttons, hold: true);

  bool sameButtons(PadChord other) => buttons.length == other.buttons.length && buttons.containsAll(other.buttons);

  static PadChord? fromJson(Object? json) {
    if (json is! Map) return null;
    final names = json['buttons'];
    if (names is! List) return null;
    final buttons = <PadButton>{};
    for (final name in names) {
      final button = PadButton.values.where((button) => button.name == name).firstOrNull;
      if (button == null) return null;
      buttons.add(button);
    }
    if (buttons.isEmpty) return null;
    return PadChord(buttons, hold: json['hold'] == true);
  }

  Map<String, Object?> toJson() => {
    'buttons': [
      for (final button in PadButton.values)
        if (buttons.contains(button)) button.name,
    ],
    if (hold) 'hold': true,
  };

  @override
  bool operator ==(Object other) => other is PadChord && other.hold == hold && sameButtons(other);

  @override
  int get hashCode => Object.hash(hold, Object.hashAllUnordered(buttons));

  @override
  String toString() => '${buttons.map((button) => button.name).join('+')}${hold ? ' (hold)' : ''}';
}

/// A key with the modifiers held with it; [key] is Flutter's LogicalKeyboardKey.keyId.
class KeyCombo {
  const KeyCombo(this.key, {this.control = false, this.alt = false, this.shift = false});

  final int key;
  final bool control;
  final bool alt;
  final bool shift;

  static KeyCombo? fromJson(Object? json) {
    if (json is! Map || json['key'] is! num) return null;
    return KeyCombo(
      (json['key'] as num).toInt(),
      control: json['control'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'key': key,
    if (control) 'control': true,
    if (alt) 'alt': true,
    if (shift) 'shift': true,
  };

  @override
  bool operator ==(Object other) =>
      other is KeyCombo && other.key == key && other.control == control && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(key, control, alt, shift);
}

/// Flutter's LogicalKeyboardKey.keyId of the keys the launcher names here (checked against
/// Flutter's own in the tests): letters are their lower-case character.
abstract final class KeyIds {
  static const q = 0x71;
  static const e = 0x65;
  static const o = 0x6f;
  static const space = 0x20;
  static const f11 = 0x0010000080b;
  static const f12 = 0x0010000080c;
  static const enter = 0x0010000000d;
  static const numpadEnter = 0x0020000020d;
  static const escape = 0x0010000001b;
  static const backspace = 0x00100000008;
  static const delete = 0x0010000007f;
  static const arrowDown = 0x00100000301;
  static const arrowLeft = 0x00100000302;
  static const arrowRight = 0x00100000303;
  static const arrowUp = 0x00100000304;
}

/// The two inputs of one action; either may be none.
class ShortcutBinding {
  const ShortcutBinding({this.key, this.pad});

  final KeyCombo? key;
  final PadChord? pad;

  ShortcutBinding withKey(KeyCombo? key) => ShortcutBinding(key: key, pad: pad);
  ShortcutBinding withPad(PadChord? pad) => ShortcutBinding(key: key, pad: pad);

  @override
  bool operator ==(Object other) => other is ShortcutBinding && other.key == key && other.pad == pad;

  @override
  int get hashCode => Object.hash(key, pad);
}

/// Why a binding cannot be had.
sealed class ShortcutConflict {
  const ShortcutConflict();
}

/// Another action has it.
class TakenBy extends ShortcutConflict {
  const TakenBy(this.action);
  final LauncherAction action;

  @override
  bool operator ==(Object other) => other is TakenBy && other.action == action;
  @override
  int get hashCode => action.hashCode;
}

/// The launcher moves with it (the arrows, Enter, Esc; ✕ ○ △, Options, the D-pad).
class Reserved extends ShortcutConflict {
  const Reserved();
  @override
  bool operator ==(Object other) => other is Reserved;
  @override
  int get hashCode => 0;
}

/// How long a press must be held to be a long press.
abstract final class ShortcutTiming {
  static const hold = Duration(milliseconds: 500);
}

/// Every action's key and controller binding (Settings › Shortcuts), kept in the preferences.
class ShortcutMap {
  ShortcutMap([Map<LauncherAction, ShortcutBinding>? bindings]) : _bindings = {...defaults, ...?bindings};

  static final defaults = <LauncherAction, ShortcutBinding>{
    LauncherAction.home: ShortcutBinding(pad: PadChord.of(PadButton.guide)),
    LauncherAction.quickMenu: const ShortcutBinding(),
    LauncherAction.screenshot: ShortcutBinding(pad: PadChord.of(PadButton.misc, hold: true)),
    LauncherAction.saveClip: ShortcutBinding(pad: PadChord.of(PadButton.misc)),
    LauncherAction.toggleFullscreen: const ShortcutBinding(key: KeyCombo(KeyIds.f11)),
    LauncherAction.previousSection: ShortcutBinding(key: const KeyCombo(KeyIds.q), pad: PadChord.of(PadButton.l1)),
    LauncherAction.nextSection: ShortcutBinding(key: const KeyCombo(KeyIds.e), pad: PadChord.of(PadButton.r1)),
  };

  /// The keys the launcher is moved with: no shortcut may take them (without a modifier).
  static const reservedKeys = {
    KeyIds.arrowLeft,
    KeyIds.arrowRight,
    KeyIds.arrowUp,
    KeyIds.arrowDown,
    KeyIds.enter,
    KeyIds.numpadEnter,
    KeyIds.space,
    KeyIds.escape,
    KeyIds.backspace,
    KeyIds.o,
  };

  /// The buttons the launcher is moved with: none of them alone may be a shortcut.
  static const reservedButtons = {
    PadButton.south,
    PadButton.east,
    PadButton.north,
    PadButton.start,
    PadButton.dpadUp,
    PadButton.dpadDown,
    PadButton.dpadLeft,
    PadButton.dpadRight,
  };

  final Map<LauncherAction, ShortcutBinding> _bindings;

  ShortcutBinding operator [](LauncherAction action) => _bindings[action] ?? const ShortcutBinding();

  Map<LauncherAction, ShortcutBinding> get all => Map.unmodifiable(_bindings);

  bool get isDefault => LauncherAction.values.every((action) => this[action] == defaults[action]);

  /// What stands in the way of giving [action] the key [key]: another action's key, or one the
  /// launcher moves with.
  ShortcutConflict? keyConflict(LauncherAction action, KeyCombo key) {
    if (!key.control && !key.alt && reservedKeys.contains(key.key)) return const Reserved();
    for (final other in LauncherAction.values) {
      if (other != action && this[other].key == key) return TakenBy(other);
    }
    return null;
  }

  /// What stands in the way of giving [action] the chord [chord]: a button the launcher moves
  /// with on its own, or another action with the same buttons pressed the same way (Home's
  /// buttons are its press and its hold both).
  ShortcutConflict? padConflict(LauncherAction action, PadChord chord) {
    if (chord.buttons.length == 1 && reservedButtons.contains(chord.buttons.first)) return const Reserved();
    for (final other in LauncherAction.values) {
      if (other == action) continue;
      final theirs = this[other].pad;
      if (theirs == null || !theirs.sameButtons(chord)) continue;
      if (theirs.hold == chord.hold || other == LauncherAction.home || action == LauncherAction.home) {
        return TakenBy(other);
      }
    }
    return null;
  }

  /// Every action whose binding clashes with another's (a hand-edited file, an older default).
  Set<LauncherAction> get conflicted => {
    for (final action in LauncherAction.values)
      if ((this[action].key != null && keyConflict(action, this[action].key!) is TakenBy) ||
          (this[action].pad != null && padConflict(action, this[action].pad!) != null))
        action,
  };

  ShortcutMap withBinding(LauncherAction action, ShortcutBinding binding) =>
      ShortcutMap({..._bindings, action: binding});

  /// The action [key] runs, if any.
  LauncherAction? actionForKey(KeyCombo key) {
    for (final action in LauncherAction.values) {
      if (this[action].key == key) return action;
    }
    return null;
  }

  /// The actions on the controller, by chord.
  Map<PadChord, LauncherAction> get padActions => {
    for (final action in LauncherAction.values)
      if (this[action].pad case final PadChord chord) chord: action,
  };

  static ShortcutMap fromJson(Object? json) {
    if (json is! Map) return ShortcutMap();
    final bindings = <LauncherAction, ShortcutBinding>{};
    for (final entry in json.entries) {
      final action = LauncherAction.byName('${entry.key}');
      final value = entry.value;
      if (action == null || value is! Map) continue;
      bindings[action] = ShortcutBinding(key: KeyCombo.fromJson(value['key']), pad: PadChord.fromJson(value['pad']));
    }
    return ShortcutMap(bindings);
  }

  /// Only the actions changed from the defaults are written.
  Map<String, Object?> toJson() => {
    for (final action in LauncherAction.values)
      if (this[action] != defaults[action])
        action.name: {'key': this[action].key?.toJson(), 'pad': this[action].pad?.toJson()},
  };
}
