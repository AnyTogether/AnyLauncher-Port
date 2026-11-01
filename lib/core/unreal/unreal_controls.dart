import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../controls.dart';
import 'unreal_pak.dart';

/// What an Unreal Engine game does with each pad button, from its own input settings
/// (DefaultInput.ini and the platform's file after it, in the game's pak): the action and axis
/// mappings that name a gamepad key. Games that keep their controls only in Enhanced Input
/// assets, or whose pak is encrypted, say nothing.
abstract final class UnrealControls {
  static const section = '[/Script/Engine.InputSettings]';

  /// The game's actions by pad button, null when its files say nothing readable. It reads the
  /// game's paks, so it belongs away from the interface (Isolate.run).
  static Map<PadAction, List<String>>? read(String folder) {
    for (final path in paks(folder)) {
      final UnrealPak pak;
      try {
        pak = UnrealPak.open(path);
      } on Object {
        continue;
      }
      final projectFiles = pak.paths.where((path) => !path.toLowerCase().startsWith('engine/')).toList();
      // The project's file, then its platform files, which change it.
      final defaults = projectFiles.where((path) => path.toLowerCase().endsWith('/config/defaultinput.ini')).toList()
        ..sort((a, b) => a.length != b.length ? a.length.compareTo(b.length) : a.compareTo(b));
      if (defaults.isEmpty) continue;
      final platform = projectFiles.where((path) {
        final lower = path.toLowerCase();
        return lower.endsWith('input.ini') &&
            lower.contains('/config/') &&
            !defaults.contains(path) &&
            (lower.contains('/ps5/') || lower.contains('ps5input'));
      }).toList()..sort();
      final texts = <String>[];
      for (final name in [defaults.first, ...platform]) {
        try {
          texts.add(utf8.decode(pak.file(name), allowMalformed: true));
        } on Object {
          continue;
        }
      }
      final controls = parse(texts);
      return controls.isEmpty ? null : controls;
    }
    return null;
  }

  /// The game's .pak files, the first chunk first (it holds the config).
  static List<String> paks(String folder) {
    final found = <String>[];
    void walk(Directory directory, int level) {
      List<FileSystemEntity> children;
      try {
        children = directory.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final child in children) {
        final name = p.basename(child.path);
        if (name.startsWith('.')) continue;
        if (child is Directory) {
          if (level < 7) walk(child, level + 1);
        } else if (p.extension(name).toLowerCase() == '.pak') {
          found.add(child.path);
        }
      }
    }

    walk(Directory(folder), 1);
    int rank(String path) {
      final name = p.basename(path).toLowerCase();
      if (name.startsWith('pakchunk0-') || name.startsWith('pakchunk0_')) return 0;
      return name.contains('pakchunk0') ? 1 : 2;
    }

    return found..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : p.basename(a).compareTo(p.basename(b));
    });
  }

  static final _lines = RegExp('\r\n|[\n\r\u000B\u000C\u0085  ]');

  /// The mappings in [files], later files changing earlier ones.
  static Map<PadAction, List<String>> parse(List<String> files) {
    final actions = <(String, String)>[];
    final axes = <(String, String)>[];
    for (final text in files) {
      var inSection = false;
      for (final raw in text.split(_lines)) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('[')) {
          inSection = line == section;
          continue;
        }
        final first = line[0];
        final marked = '+-!'.contains(first);
        if (!inSection || !(marked || line.startsWith('ActionMappings') || line.startsWith('AxisMappings'))) continue;
        final body = marked ? line.substring(1) : line;
        final isAction = body.startsWith('ActionMappings=');
        if (!isAction && !body.startsWith('AxisMappings=')) continue;
        final list = isAction ? actions : axes;
        if (first == '!') {
          list.clear();
          continue;
        }
        final name = field(isAction ? 'ActionName' : 'AxisName', body);
        final key = field('Key', body);
        if (name == null || key == null) continue;
        final mapping = (name, key);
        if (first == '-') {
          list.removeWhere((each) => each == mapping);
        } else if (!list.contains(mapping)) {
          list.add(mapping);
        }
      }
    }
    final controls = <PadAction, List<String>>{};
    for (final (name, key) in [...actions, ...axes]) {
      final shown = title(name);
      for (final action in buttons(key)) {
        final names = controls.putIfAbsent(action, () => []);
        if (!names.contains(shown)) names.add(shown);
      }
    }
    return controls;
  }

  /// A value in `(Name="Value",Key=Gamepad_X)`, quoted or not.
  static String? field(String name, String body) {
    final at = body.indexOf('$name=');
    if (at < 0) return null;
    final rest = body.substring(at + name.length + 1);
    if (rest.startsWith('"')) {
      final end = rest.indexOf('"', 1);
      return end < 0 ? null : rest.substring(1, end);
    }
    final end = rest.indexOf(RegExp('[,)]'));
    return end < 0 ? rest : rest.substring(0, end);
  }

  /// The pad buttons an Unreal gamepad key is; a stick axis is both its directions.
  static List<PadAction> buttons(String key) => switch (key.toLowerCase()) {
    'gamepad_facebutton_bottom' => [PadAction.cross],
    'gamepad_facebutton_right' => [PadAction.circle],
    'gamepad_facebutton_left' => [PadAction.square],
    'gamepad_facebutton_top' => [PadAction.triangle],
    'gamepad_leftshoulder' => [PadAction.l1],
    'gamepad_rightshoulder' => [PadAction.r1],
    'gamepad_lefttrigger' || 'gamepad_lefttriggeraxis' => [PadAction.l2],
    'gamepad_righttrigger' || 'gamepad_righttriggeraxis' => [PadAction.r2],
    'gamepad_leftthumbstick' => [PadAction.l3],
    'gamepad_rightthumbstick' => [PadAction.r3],
    'gamepad_special_right' => [PadAction.options],
    'gamepad_special_left' => [PadAction.touchLeft],
    'gamepad_dpad_up' => [PadAction.up],
    'gamepad_dpad_down' => [PadAction.down],
    'gamepad_dpad_left' => [PadAction.left],
    'gamepad_dpad_right' => [PadAction.right],
    'gamepad_leftstick_up' => [PadAction.leftStickUp],
    'gamepad_leftstick_down' => [PadAction.leftStickDown],
    'gamepad_leftstick_left' => [PadAction.leftStickLeft],
    'gamepad_leftstick_right' => [PadAction.leftStickRight],
    'gamepad_rightstick_up' => [PadAction.rightStickUp],
    'gamepad_rightstick_down' => [PadAction.rightStickDown],
    'gamepad_rightstick_left' => [PadAction.rightStickLeft],
    'gamepad_rightstick_right' => [PadAction.rightStickRight],
    'gamepad_lefty' => [PadAction.leftStickUp, PadAction.leftStickDown],
    'gamepad_leftx' => [PadAction.leftStickLeft, PadAction.leftStickRight],
    'gamepad_righty' => [PadAction.rightStickUp, PadAction.rightStickDown],
    'gamepad_rightx' => [PadAction.rightStickLeft, PadAction.rightStickRight],
    _ => const [],
  };

  static final _number = RegExp(r'^\p{N}$', unicode: true);

  static bool _isUpper(String character) =>
      character != character.toLowerCase() && character == character.toUpperCase();

  static bool _isLower(String character) =>
      character != character.toUpperCase() && character == character.toLowerCase();

  /// "Interact_Primary" and "IA_OpenMenu" read as "Interact primary" and "Open menu".
  static String title(String name) {
    var rest = name;
    for (final prefix in const ['IA_', 'Action_', 'Axis_', 'Input_']) {
      if (rest.startsWith(prefix) && rest.length > prefix.length) rest = rest.substring(prefix.length);
    }
    final words = <String>[];
    var word = '';
    String? previous;
    for (final rune in rest.runes) {
      final character = String.fromCharCode(rune);
      if (character == '_' || character == ' ') {
        if (word.isNotEmpty) words.add(word);
        word = '';
      } else if (_isUpper(character) && previous != null && (_isLower(previous) || _number.hasMatch(previous))) {
        words.add(word);
        word = character;
      } else {
        word += character;
      }
      previous = character;
    }
    if (word.isNotEmpty) words.add(word);
    return [
      for (final (index, word) in words.indexed)
        // Short all-capital words (UI, HUD) stay as they are.
        if (word.length > 1 && word == word.toUpperCase())
          word
        else if (index == 0)
          word.substring(0, 1).toUpperCase() + word.substring(1)
        else
          word.toLowerCase(),
    ].join(' ');
  }
}
