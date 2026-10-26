import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';

void main() {
  group('controls', () {
    test('the default file lists every action once per source, unbound ones as F24', () {
      final text = Controls.file(const {});
      final lines = text.trimRight().split('\n');
      expect(lines.first, startsWith('# Written by AnyPS5'));
      expect(lines, contains('Cross = KEY:K'));
      expect(lines, contains('Cross = KEY:Space'));
      expect(lines, contains('Cross = KEY:Return'));
      expect(lines, contains('Square = MOUSE:Left'));
      expect(lines, contains('Up = WHEEL:Up'));
      expect(lines, contains('StickModifier = KEY:F24'));
      expect(text.endsWith('\n'), isTrue);
      // Every action appears, in the engine's order.
      final order = lines.skip(1).map((line) => line.split(' = ').first).toSet().toList();
      expect(order, PadAction.values.map((action) => action.key).toList());
    });

    test('the file is the same text the macOS launcher writes, apart from its first line', () {
      // Written out from Controls.swift for the default layout.
      const swift = '''
Cross = KEY:K
Cross = KEY:Space
Cross = KEY:Return
Circle = KEY:L
Square = KEY:J
Square = MOUSE:Left
Triangle = KEY:I
L1 = KEY:Q
R1 = KEY:E
L2 = KEY:U
L2 = MOUSE:X1
R2 = KEY:O
R2 = MOUSE:Right
L3 = KEY:Left Shift
R3 = KEY:Left Ctrl
Options = KEY:Escape
TouchLeft = KEY:Backspace
TouchRight = KEY:Tab
Up = KEY:Up
Up = WHEEL:Up
Down = KEY:Down
Down = WHEEL:Down
Left = KEY:Left
Right = KEY:Right
LeftStickUp = KEY:W
LeftStickDown = KEY:S
LeftStickLeft = KEY:A
LeftStickRight = KEY:D
RightStickUp = KEY:T
RightStickDown = KEY:G
RightStickLeft = KEY:F
RightStickRight = KEY:H
StickModifier = KEY:F24
''';
      expect(Controls.file(const {}).split('\n').skip(1).join('\n'), swift);
    });

    test('assigning a key takes it from other actions, keeps mouse buttons, drops changes back to default', () {
      var changes = Controls.assign('KEY:L', PadAction.square, const {});
      expect(Controls.sources(PadAction.square, changes), ['KEY:L', 'MOUSE:Left']);
      expect(Controls.sources(PadAction.circle, changes), isEmpty);
      expect(Controls.file(changes), contains('Circle = KEY:F24'));
      // Giving J back to Square and L back to Circle returns to the layout: no changes left.
      changes = Controls.assign('KEY:J', PadAction.square, changes);
      changes = Controls.assign('KEY:L', PadAction.circle, changes);
      expect(changes, isEmpty);
      // A key from a multi-key action.
      changes = Controls.assign('KEY:Space', PadAction.triangle, const {});
      expect(Controls.sources(PadAction.cross, changes), ['KEY:K', 'KEY:Return']);
      expect(Controls.sources(PadAction.triangle, changes), ['KEY:Space']);
      expect(Controls.reset(PadAction.triangle, changes).containsKey('Triangle'), isFalse);
    });

    test('tuning writes only changed settings, clamped, in the engine units', () {
      expect(const InputTuning().lines, isEmpty);
      final tuning = const InputTuning().copyWith(
        leftDeadzone: 120,
        mouseSensitivity: 25,
        mouseCurve: 1,
        mouseDeadzoneOffset: 35,
        stickModifierScale: 40,
        triggerRampMs: 150,
      );
      expect(tuning.lines, [
        'LeftStickDeadzone = 90',
        'MouseSensitivity = 2.5',
        'MouseCurve = 0.2',
        'MouseDeadzoneOffset = 0.35',
        'StickModifierScale = 0.4',
        'TriggerRampMs = 150',
      ]);
      expect(const InputTuning().copyWith(mouseSensitivity: 20).lines, ['MouseSensitivity = 2.0']);
      expect(Controls.file(const {}, tuning: tuning).trimRight().split('\n').last, 'TriggerRampMs = 150');
    });

    test('tuning reads old settings without the newer fields', () {
      final tuning = InputTuning.fromJson({'leftDeadzone': 5, 'mouseSensitivity': 12});
      expect(tuning.leftDeadzone, 5);
      expect(tuning.mouseSensitivity, 12);
      expect(tuning.triggerRampMs, 0);
      expect(InputTuning.fromJson(tuning.toJson()), tuning);
    });

    test('key names from USB HID usages, as Flutter physical keys carry them', () {
      expect(Controls.keyName(0x00070004), 'A');
      expect(Controls.keyName(0x0007001D), 'Z');
      expect(Controls.keyName(0x0007001E), '1');
      expect(Controls.keyName(0x00070027), '0');
      expect(Controls.keyName(0x00070028), 'Return');
      expect(Controls.keyName(0x0007002C), 'Space');
      expect(Controls.keyName(0x0007003A), 'F1');
      expect(Controls.keyName(0x00070045), 'F12');
      expect(Controls.keyName(0x00070052), 'Up');
      expect(Controls.keyName(0x00070062), 'Keypad 0');
      expect(Controls.keyName(0x000700E1), 'Left Shift');
      expect(Controls.keyName(0x000700E7), 'Right GUI');
      expect(Controls.keyName(0x00070033), isNull, reason: '; starts a comment');
      expect(Controls.keyName(0x00070068), isNull, reason: 'F13');
    });

    test('labels', () {
      expect(Controls.label('KEY:Left Shift'), 'Left Shift');
      expect(Controls.label('KEY:Return'), 'Enter');
      expect(Controls.label('MOUSE:Left'), 'Left click');
      expect(Controls.label('MOUSE:Right', turkish: true), 'Sağ tık');
      expect(Controls.label('WHEEL:Down'), 'Wheel down');
    });

    test('write is atomic and leaves no temporary file', () {
      final folder = temporaryFolder('controls');
      addTearDown(() => folder.deleteSync(recursive: true));
      final path = p.join(folder.path, 'input', 'ppsa01234.ini');
      Controls.write(path, const {
        'Cross': ['KEY:X'],
      });
      expect(File(path).readAsStringSync(), contains('Cross = KEY:X\n'));
      expect(File('$path.tmp').existsSync(), isFalse);
    });
  });

  group('game settings', () {
    test('the default environment', () {
      expect(const GameSettings().environment(launcherLanguage: 19), {
        'ANYPS5_FULLSCREEN': '0',
        'ANYPS5_WINDOW_SIZE': '75',
        'ANYPS5_PRESENT_MODE': 'fifo',
        'ANYPS5_LANGUAGE': '19',
        'SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS': '0',
      });
    });

    test('every choice reaches the environment', () {
      const settings = GameSettings(
        fullscreen: true,
        windowSize: 10,
        vsync: false,
        overlay: OverlayCorner.bottomRight,
        overlayStyle: OverlayStyle.detailed,
        language: 1,
        shaderCache: false,
      );
      expect(
        settings.environment(
          launcherLanguage: 19,
          inputFile: '/cfg/input/x.ini',
          screenshots: '/pics',
          fonts: '/fonts',
          shaderCacheFolder: '/cache/x',
        ),
        {
          'ANYPS5_FULLSCREEN': '1',
          'ANYPS5_WINDOW_SIZE': '30',
          'ANYPS5_PRESENT_MODE': 'immediate',
          'ANYPS5_LANGUAGE': '1',
          'SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS': '0',
          'ANYPS5_OVERLAY': '1',
          'ANYPS5_OVERLAY_POS': 'br',
          'ANYPS5_OVERLAY_STYLE': 'detailed',
          'ANYPS5_INPUT_CONFIG': '/cfg/input/x.ini',
          'ANYPS5_SCREENSHOTS': '/pics',
          'ANYPS5_SYSTEM_FONTS': '/fonts',
          'ANYPS5_NO_SHADER_CACHE': '1',
        },
      );
      final generated = const GameSettings(
        vsync: false,
        frameGeneration: true,
      ).environment(launcherLanguage: 1, shaderCacheFolder: '/cache/x');
      expect(generated['ANYPS5_PRESENT_MODE'], 'fifo', reason: 'frame generation needs vertical sync');
      expect(generated['ANYPS5_FRAME_GEN'], '1');
      expect(generated['ANYPS5_SHADER_CACHE_DIR'], '/cache/x');
      expect(
        const GameSettings(overlay: OverlayCorner.topLeft).environment(launcherLanguage: 1)['ANYPS5_OVERLAY_STYLE'],
        'minimal',
      );
    });

    test('JSON round trip, with the macOS launcher keys, and old files missing fields', () {
      const settings = GameSettings(
        resolution: '1920x1080',
        fullscreen: true,
        windowSize: 90,
        overlay: OverlayCorner.topRight,
        overlayStyle: OverlayStyle.minimal,
        frameGeneration: true,
        language: 4,
        controls: {
          'Cross': ['KEY:X', 'MOUSE:Left'],
        },
        tuning: InputTuning(leftDeadzone: 10),
        shaderCache: false,
        phoneLayout: '{"buttons":[]}',
      );
      final json = jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>;
      expect(json['overlay'], 'topRight');
      expect(json['windowSize'], 90);
      expect(GameSettings.fromJson(json), settings);
      // A file the macOS launcher wrote.
      final mac = GameSettings.fromJson(
        jsonDecode('{"fullscreen":false,"windowSize":75,"vsync":true,"overlay":"off","controls":{"Circle":["KEY:B"]}}')
            as Map<String, dynamic>,
      );
      expect(mac.controls, {
        'Circle': ['KEY:B'],
      });
      expect(mac.tuning, isNull);
      expect(GameSettings.fromJson(const {}), const GameSettings());
    });

    test('copyWith changes and clears', () {
      const settings = GameSettings(language: 4, resolution: '1280x720');
      expect(settings.copyWith(fullscreen: true).language, 4);
      expect(settings.copyWith(language: null).language, isNull);
      expect(settings.copyWith(resolution: '1920x1080').resolution, '1920x1080');
    });

    test('the store keeps one file per game and reads a broken one as the defaults', () {
      final folder = temporaryFolder('settings');
      addTearDown(() => folder.deleteSync(recursive: true));
      final store = GameSettingsStore(p.join(folder.path, 'games'));
      expect(store.load('ppsa01234'), const GameSettings());
      store.save('ppsa01234', const GameSettings(windowSize: 50));
      expect(store.load('ppsa01234').windowSize, 50);
      File(p.join(folder.path, 'games', 'ppsa09999.json')).writeAsStringSync('{broken');
      expect(store.load('ppsa09999'), const GameSettings());
    });

    test('writeInputFile writes the controls and tuning', () {
      final folder = temporaryFolder('input');
      addTearDown(() => folder.deleteSync(recursive: true));
      final path = p.join(folder.path, 'x.ini');
      const GameSettings(
        controls: {
          'Cross': ['KEY:X'],
        },
        tuning: InputTuning(rightDeadzone: 12),
      ).writeInputFile(path);
      final text = File(path).readAsStringSync();
      expect(text, contains('Cross = KEY:X\n'));
      expect(text, contains('RightStickDeadzone = 12\n'));
    });

    test('console languages', () {
      expect(ConsoleLanguage.tag(19), 'tr-TR');
      expect(ConsoleLanguage.tag(1), 'en-US');
      expect(ConsoleLanguage.tag(99), isNull);
      expect(ConsoleLanguage.all.first, (19, 'Türkçe'));
    });
  });

  group('resolution patch', () {
    const toml = '''
format = 1

[[patch]]
name        = "width"
target      = "eboot.bin"
va          = 0x1234
type        = "u32"
expected    = 1920
value       = 1920 # the title's own
description = "output width"

[[patch]]
name        = "height"
target      = "eboot.bin"
va          = 0x1240
type        = "u32"
expected    = 1080
value       = 1080

[[patch]]
name        = "pool"
target      = "eboot.bin"
va          = 0x2000
expected    = "0000"
value       = "0100"
''';

    test('parse and supports', () {
      expect(ResolutionPatch.parse('2560x1440'), (2560, 1440));
      expect(ResolutionPatch.parse('2560X1440'), (2560, 1440));
      expect(ResolutionPatch.parse('wide'), isNull);
      expect(ResolutionPatch.parse('0x10'), isNull);
      expect(ResolutionPatch.supports(toml), isTrue);
      expect(ResolutionPatch.supports('format = 1\n'), isFalse);
    });

    test('apply sets only the width and height values', () {
      final patched = ResolutionPatch.apply(toml, '2560x1440');
      expect(patched, contains('value       = 2560 # the title\'s own'));
      expect(patched, contains('value       = 1440'));
      expect(patched, contains('expected    = 1920'));
      expect(patched, contains('value       = "0100"'));
      expect(ResolutionPatch.apply(toml, 'nonsense'), toml);
    });

    test('the installer hands the title patch file to the relinker, with the chosen resolution', () async {
      final temp = temporaryFolder('patch');
      addTearDown(() => temp.deleteSync(recursive: true));
      final toolkit = makeFakeToolkit(p.join(temp.path, 'toolkit'));
      Directory(p.join(toolkit, 'patches')).createSync();
      File(p.join(toolkit, 'patches', 'PPSA01234.toml')).writeAsStringSync(toml);
      final root = p.join(temp.path, 'Games');
      final game = GameLibrary.inspect(makeDump(root, 'G', titleId: 'PPSA01234'))!;
      final installed = await Installer(
        game: game,
        toolkit: Toolkit(toolkit),
        root: root,
        resolution: '1600x900',
      ).run();
      final arguments = fakeRelinkerArguments(toolkit);
      final at = arguments.indexOf('--patches');
      expect(at, greaterThan(0));
      expect(p.basename(arguments[at + 1]), 'relinker-patches.toml');
      expect(Installer.record(installed, system: HostSystem.linux)!.resolution, '1600x900');
      // Without a patch file there is no --patches and no resolution.
      final other = GameLibrary.inspect(makeDump(root, 'H', titleId: 'PPSA05555'))!;
      final plain = await Installer(game: other, toolkit: Toolkit(toolkit), root: root, resolution: '1600x900').run();
      expect(fakeRelinkerArguments(toolkit), isNot(contains('--patches')));
      expect(Installer.record(plain, system: HostSystem.linux)!.resolution, isNull);
    });
  });
}
