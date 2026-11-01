import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/unreal/unreal_controls.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/pak_writer.dart';

/// What an Unreal game does with each pad button, from its own input file: the same cases as
/// the Mac launcher's UnrealControlsTests.swift.
void main() {
  const input = '''
[/Script/Engine.InputSettings]
bAltEnterTogglesFullscreen=True
+ActionMappings=(ActionName="Jump",bShift=False,bCtrl=False,bAlt=False,bCmd=False,Key=Gamepad_FaceButton_Bottom)
+ActionMappings=(ActionName="Jump",bShift=False,bCtrl=False,bAlt=False,bCmd=False,Key=SpaceBar)
+ActionMappings=(ActionName="Interact_Primary",Key=Gamepad_FaceButton_Left)
+ActionMappings=(ActionName="IA_Meow",Key=Gamepad_RightShoulder)
+ActionMappings=(ActionName="OpenMenu",Key=Gamepad_Special_Right)
+AxisMappings=(AxisName="MoveForward",Scale=1.000000,Key=Gamepad_LeftY)
+AxisMappings=(AxisName="MoveRight",Scale=-1.000000,Key=Gamepad_LeftX)
+AxisMappings=(AxisName="Sprint",Scale=1.000000,Key=Gamepad_RightTriggerAxis)
+AxisMappings=(AxisName="LookUp",Scale=1.000000,Key=Gamepad_RightY)''';

  test('each button says what the game does with it', () {
    final controls = UnrealControls.parse([input]);
    expect(controls[PadAction.cross], ['Jump']);
    expect(controls[PadAction.square], ['Interact primary']);
    expect(controls[PadAction.r1], ['Meow']);
    expect(controls[PadAction.options], ['Open menu']);
    expect(controls[PadAction.r2], ['Sprint']);
    expect(controls[PadAction.leftStickUp], ['Move forward']);
    expect(controls[PadAction.leftStickDown], ['Move forward']);
    expect(controls[PadAction.leftStickLeft], ['Move right']);
    expect(controls[PadAction.rightStickUp], ['Look up']);
    expect(controls[PadAction.circle], isNull);
  });

  // A later file adds to, takes from or clears what the earlier said, as Unreal's ini layers do.
  test('later files change the earlier ones', () {
    const platform = '''
[/Script/Engine.InputSettings]
-ActionMappings=(ActionName="Interact_Primary",Key=Gamepad_FaceButton_Left)
+ActionMappings=(ActionName="Interact_Primary",Key=Gamepad_FaceButton_Right)''';
    final controls = UnrealControls.parse([input, platform]);
    expect(controls[PadAction.square], isNull);
    expect(controls[PadAction.circle], ['Interact primary']);
    final cleared = UnrealControls.parse([input, '[/Script/Engine.InputSettings]\n!ActionMappings=ClearArray\n']);
    expect(cleared[PadAction.cross], isNull);
    expect(cleared[PadAction.r2], ['Sprint'], reason: 'axes stay');
  });

  test('other sections are left alone', () {
    final controls = UnrealControls.parse([
      '[/Script/Other.Thing]\n+ActionMappings=(ActionName="Jump",Key=Gamepad_FaceButton_Bottom)\n',
    ]);
    expect(controls, isEmpty);
  });

  // The game's own input file, found in a pak in the game's folder.
  test("the controls are read from the game's pak", () {
    final game = temporaryFolder('game');
    addTearDown(() => game.deleteSync(recursive: true));
    final paks = Directory(p.join(game.path, 'Stray', 'Content', 'Paks'))..createSync(recursive: true);
    PakWriter(
      version: 11,
      files: [
        (
          path: 'Engine/Config/BaseInput.ini',
          data: utf8.encode(
            '[/Script/Engine.InputSettings]\n+ActionMappings=(ActionName="EngineThing",Key=Gamepad_FaceButton_Top)\n',
          ),
          zlib: false,
        ),
        (path: 'Stray/Config/DefaultInput.ini', data: utf8.encode(input), zlib: true),
      ],
    ).write(p.join(paks.path, 'pakchunk0-ps5.pak'));
    final controls = UnrealControls.read(game.path);
    expect(controls, isNotNull);
    expect(controls![PadAction.cross], ['Jump']);
    expect(controls[PadAction.triangle], isNull, reason: "the engine's own file says nothing of the game");
  });

  // The launcher reads them away from the interface; what comes back is the same.
  test('the controls are read on another isolate', () async {
    final game = temporaryFolder('game');
    addTearDown(() => game.deleteSync(recursive: true));
    final paks = Directory(p.join(game.path, 'Stray', 'Content', 'Paks'))..createSync(recursive: true);
    PakWriter(files: [(path: 'Stray/Config/DefaultInput.ini', data: utf8.encode(input), zlib: true)])
        .write(p.join(paks.path, 'pakchunk0-ps5.pak'));
    final folder = game.path;
    final controls = await Isolate.run(() => UnrealControls.read(folder));
    expect(controls?[PadAction.r1], ['Meow']);
  });

  test('a game without paks has none', () {
    expect(
      UnrealControls.read(p.join(Directory.systemTemp.path, 'nothing-${DateTime.now().microsecondsSinceEpoch}')),
      isNull,
    );
  });
}
