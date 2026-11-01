import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/unreal/unreal_pak.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/pak_writer.dart';

/// Files out of Unreal paks written as the engine writes them: the same cases as the Mac
/// launcher's UnrealPakTests.swift.
void main() {
  late Directory folder;

  setUp(() => folder = temporaryFolder('pak'));
  tearDown(() => folder.deleteSync(recursive: true));

  List<PakFile> files() => [
    (
      path: 'Stray/Config/DefaultInput.ini',
      data: utf8.encode(
        '[/Script/Engine.InputSettings]\n+ActionMappings=(ActionName="Jump",Key=Gamepad_FaceButton_Bottom)\n',
      ),
      zlib: false,
    ),
    (
      path: 'Stray/Config/DefaultGame.ini',
      data: utf8.encode('[/Script/EngineSettings.GeneralProjectSettings]\nProjectName=Stray\n' * 40),
      zlib: true,
    ),
    (path: 'Engine/Config/BaseInput.ini', data: utf8.encode('engine'), zlib: false),
  ];

  test('files come out of a pak with the directory index', () {
    final path = p.join(folder.path, 'pakchunk0-ps5.pak');
    PakWriter(version: 11, files: files()).write(path);
    final pak = UnrealPak.open(path);
    expect(pak.version, 11);
    expect(pak.paths.toSet(), {
      'Stray/Config/DefaultInput.ini',
      'Stray/Config/DefaultGame.ini',
      'Engine/Config/BaseInput.ini',
    });
    expect(pak.fileEndingWith('config/defaultinput.ini'), files()[0].data);
    expect(pak.fileEndingWith('DefaultGame.ini'), files()[1].data, reason: 'a zlib file');
    expect(pak.file('Engine/Config/BaseInput.ini'), utf8.encode('engine'));
  });

  test('files come out of a pak with the old index', () {
    final path = p.join(folder.path, 'old.pak');
    PakWriter(version: 8, files: files()).write(path);
    final pak = UnrealPak.open(path);
    expect(pak.version, 8);
    expect(pak.fileEndingWith('DefaultInput.ini'), files()[0].data);
    expect(pak.fileEndingWith('DefaultGame.ini'), files()[1].data);
  });

  test('an encrypted index is said so', () {
    final path = p.join(folder.path, 'locked.pak');
    PakWriter(version: 11, files: files(), encryptedIndex: true).write(path);
    expect(
      () => UnrealPak.open(path),
      throwsA(isA<UnrealPakFailure>().having((failure) => '$failure', 'description', contains('encrypted'))),
    );
  });

  test('something else is not a pak', () {
    final path = p.join(folder.path, 'other.pak');
    File(path).writeAsBytesSync(List.filled(300, 7));
    expect(() => UnrealPak.open(path), throwsA(isA<UnrealPakFailure>()));
  });
}
