import 'dart:convert';

import 'package:anyps5_desktop/core/gamepad/pad_gate.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/gamepad/shortcuts.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PadButtonEvent down(PadButton button, [String pad = 'a']) => PadButtonEvent(pad, button, down: true);
  PadButtonEvent up(PadButton button, [String pad = 'a']) => PadButtonEvent(pad, button, down: false);

  test('the key ids are Flutter\'s own', () {
    expect(KeyIds.q, LogicalKeyboardKey.keyQ.keyId);
    expect(KeyIds.e, LogicalKeyboardKey.keyE.keyId);
    expect(KeyIds.o, LogicalKeyboardKey.keyO.keyId);
    expect(KeyIds.space, LogicalKeyboardKey.space.keyId);
    expect(KeyIds.f11, LogicalKeyboardKey.f11.keyId);
    expect(KeyIds.f12, LogicalKeyboardKey.f12.keyId);
    expect(KeyIds.enter, LogicalKeyboardKey.enter.keyId);
    expect(KeyIds.numpadEnter, LogicalKeyboardKey.numpadEnter.keyId);
    expect(KeyIds.escape, LogicalKeyboardKey.escape.keyId);
    expect(KeyIds.backspace, LogicalKeyboardKey.backspace.keyId);
    expect(KeyIds.delete, LogicalKeyboardKey.delete.keyId);
    expect(KeyIds.arrowDown, LogicalKeyboardKey.arrowDown.keyId);
    expect(KeyIds.arrowLeft, LogicalKeyboardKey.arrowLeft.keyId);
    expect(KeyIds.arrowRight, LogicalKeyboardKey.arrowRight.keyId);
    expect(KeyIds.arrowUp, LogicalKeyboardKey.arrowUp.keyId);
  });

  group('the map', () {
    test('defaults: PS, Share and Share held, F11, Q/E and L1/R1', () {
      final map = ShortcutMap();
      expect(map[LauncherAction.home].pad, PadChord.of(PadButton.guide));
      expect(map[LauncherAction.saveClip].pad, PadChord.of(PadButton.misc));
      expect(map[LauncherAction.screenshot].pad, PadChord.of(PadButton.misc, hold: true));
      expect(map[LauncherAction.toggleFullscreen].key, const KeyCombo(KeyIds.f11));
      expect(map[LauncherAction.previousSection].key, const KeyCombo(KeyIds.q));
      expect(map[LauncherAction.nextSection].pad, PadChord.of(PadButton.r1));
      expect(map[LauncherAction.quickMenu], const ShortcutBinding());
      expect(map.conflicted, isEmpty);
      expect(map.isDefault, isTrue);
    });

    test('a key or a chord another action has is a conflict, a launcher key is reserved', () {
      final map = ShortcutMap();
      expect(
        map.keyConflict(LauncherAction.screenshot, const KeyCombo(KeyIds.f11)),
        const TakenBy(LauncherAction.toggleFullscreen),
      );
      expect(map.keyConflict(LauncherAction.screenshot, const KeyCombo(KeyIds.f11, control: true)), isNull);
      expect(map.keyConflict(LauncherAction.screenshot, const KeyCombo(KeyIds.escape)), const Reserved());
      expect(map.keyConflict(LauncherAction.screenshot, const KeyCombo(KeyIds.arrowUp)), const Reserved());
      expect(map.keyConflict(LauncherAction.screenshot, const KeyCombo(KeyIds.o, control: true)), isNull);
      expect(map.keyConflict(LauncherAction.toggleFullscreen, const KeyCombo(KeyIds.f11)), isNull, reason: 'its own');

      expect(
        map.padConflict(LauncherAction.quickMenu, PadChord.of(PadButton.misc)),
        const TakenBy(LauncherAction.saveClip),
      );
      expect(
        map.padConflict(LauncherAction.quickMenu, PadChord.of(PadButton.misc, hold: true)),
        const TakenBy(LauncherAction.screenshot),
      );
      expect(
        map.padConflict(LauncherAction.quickMenu, PadChord.of(PadButton.guide, hold: true)),
        const TakenBy(LauncherAction.home),
        reason: 'PS held is Home\'s own',
      );
      expect(map.padConflict(LauncherAction.quickMenu, PadChord.of(PadButton.south)), const Reserved());
      expect(map.padConflict(LauncherAction.quickMenu, PadChord.of(PadButton.dpadUp)), const Reserved());
      expect(
        map.padConflict(LauncherAction.quickMenu, PadChord({PadButton.select, PadButton.south})),
        isNull,
        reason: 'a face button in a chord is fine',
      );
      expect(map.padConflict(LauncherAction.quickMenu, PadChord({PadButton.select, PadButton.start})), isNull);
    });

    test('kept as JSON with only the changes; a file with garbage keeps the defaults', () {
      final map = ShortcutMap()
          .withBinding(LauncherAction.quickMenu, ShortcutBinding(pad: PadChord({PadButton.select, PadButton.start})))
          .withBinding(LauncherAction.toggleFullscreen, const ShortcutBinding(key: KeyCombo(KeyIds.enter, alt: true)));
      final json = jsonDecode(jsonEncode(map.toJson())) as Map<String, dynamic>;
      expect(json.keys, unorderedEquals(['quickMenu', 'toggleFullscreen']));
      final back = ShortcutMap.fromJson(json);
      expect(back[LauncherAction.quickMenu].pad, PadChord({PadButton.start, PadButton.select}));
      expect(back[LauncherAction.toggleFullscreen].key, const KeyCombo(KeyIds.enter, alt: true));
      expect(back[LauncherAction.home], ShortcutMap.defaults[LauncherAction.home]);
      final garbage = ShortcutMap.fromJson({
        'home': 3,
        'nothing': {},
        'screenshot': {
          'pad': {
            'buttons': ['nope'],
          },
        },
      });
      expect(garbage[LauncherAction.home], ShortcutMap.defaults[LauncherAction.home]);
      expect(garbage[LauncherAction.screenshot].pad, isNull);
      expect(ShortcutMap.fromJson(null).isDefault, isTrue);
    });
  });

  group('the navigator', () {
    late List<PadCommand> commands;
    late PadNavigator navigator;

    setUp(() {
      commands = [];
      navigator = PadNavigator(commands.add, isPlayStation: (pad) => pad == 'ps');
    });
    tearDown(() => navigator.dispose());

    test('PS acts when let go; held half a second it is the long press, and letting go does nothing more', () {
      fakeAsync((async) {
        navigator.handle(down(PadButton.guide));
        expect(commands, isEmpty, reason: 'it might become a long press');
        async.elapse(const Duration(milliseconds: 200));
        navigator.handle(up(PadButton.guide));
        expect(commands, [PadCommand.home]);
        navigator.handle(down(PadButton.guide));
        async.elapse(ShortcutTiming.hold);
        expect(commands, [PadCommand.home, PadCommand.homeHold]);
        navigator.handle(up(PadButton.guide));
        async.elapse(const Duration(seconds: 1));
        expect(commands, [PadCommand.home, PadCommand.homeHold]);
      });
    });

    test('Share: a press saves the clip, held it takes a screenshot; Create is Share on a PlayStation pad', () {
      fakeAsync((async) {
        navigator
          ..handle(down(PadButton.misc))
          ..handle(up(PadButton.misc));
        expect(commands, [PadCommand.saveClip]);
        navigator.handle(down(PadButton.select, 'ps'));
        async.elapse(ShortcutTiming.hold);
        navigator.handle(up(PadButton.select, 'ps'));
        expect(commands, [PadCommand.saveClip, PadCommand.screenshot]);
        navigator
          ..handle(down(PadButton.select, 'xbox'))
          ..handle(up(PadButton.select, 'xbox'));
        async.elapse(const Duration(seconds: 1));
        expect(commands, hasLength(2), reason: "an Xbox pad's View is the game's touchpad, not Share");
        expect(navigator.passesInGame('ps', PadButton.select), isTrue);
        expect(navigator.passesInGame('xbox', PadButton.select), isFalse);
        expect(navigator.passesInGame('xbox', PadButton.guide), isTrue);
        expect(navigator.passesInGame('xbox', PadButton.south), isFalse);
      });
    });

    test('a binding with no held partner acts at once; L1 and R1 come from the shortcuts', () {
      navigator.handle(down(PadButton.r1));
      expect(commands, [PadCommand.nextGame]);
      navigator.shortcuts = ShortcutMap().withBinding(
        LauncherAction.nextSection,
        ShortcutBinding(pad: PadChord.of(PadButton.r2)),
      );
      navigator
        ..handle(up(PadButton.r1))
        ..handle(down(PadButton.r1))
        ..handle(up(PadButton.r1))
        ..handle(down(PadButton.r2));
      expect(commands, [PadCommand.nextGame, PadCommand.nextGame], reason: 'R1 does nothing now, R2 moves');
    });

    test('a chord: its last button does not also move; a direction held is no part of it', () {
      navigator.shortcuts = ShortcutMap().withBinding(
        LauncherAction.quickMenu,
        ShortcutBinding(pad: PadChord({PadButton.select, PadButton.south})),
      );
      navigator
        ..handle(down(PadButton.select))
        ..handle(down(PadButton.south));
      expect(commands, [PadCommand.quickMenu]);
      navigator
        ..handle(up(PadButton.south))
        ..handle(up(PadButton.select))
        ..handle(down(PadButton.dpadDown))
        ..handle(down(PadButton.l1));
      expect(commands, [PadCommand.quickMenu, PadCommand.down, PadCommand.previousGame]);
    });

    test('a pad that goes away with PS held never acts', () {
      fakeAsync((async) {
        navigator
          ..handle(down(PadButton.guide))
          ..handle(const PadGone('a'));
        async.elapse(const Duration(seconds: 1));
        expect(commands, isEmpty);
      });
    });
  });

  test('behind a game the gate lets the in-game shortcuts through, nothing else', () {
    fakeAsync((async) {
      final commands = <PadCommand>[];
      final navigator = PadNavigator(commands.add, isPlayStation: (pad) => true);
      final gate = PadGate(navigator.handle, inFront: () => false, passesInGame: navigator.passesInGame);
      for (final button in [PadButton.south, PadButton.r1, PadButton.select, PadButton.guide]) {
        gate
          ..handle(down(button))
          ..handle(up(button));
      }
      expect(commands, [PadCommand.saveClip, PadCommand.home]);
      navigator.dispose();
    });
  });
}
