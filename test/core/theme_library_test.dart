import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/themes/theme_design.dart';
import 'package:anyps5_desktop/core/themes/theme_library.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Themes made in the Studio or installed from `.anyps5theme` files, the same files as the macOS
/// launcher's (ThemeLibraryTests.swift): saved, turned into a file and back, and never reaching
/// outside their folder.
void main() {
  late Directory temp;
  late ThemeLibrary library;

  setUp(() {
    temp = temporaryFolder('themes');
    library = ThemeLibrary(p.join(temp.path, 'Themes'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  ThemeDesign design([String name = 'Midnight']) => ThemeDesign(
    id: ThemeLibrary.newId(),
    name: name,
    author: 'Utku',
    style: 1,
    deep: '#05070F',
    middle: '#1B3A7A',
    bright: '#9EC5FF',
    accent: '#4F94FF',
  );

  String fixture(String name) => p.join('test', 'support', 'themes', name);

  test('colours are read from and written as #RRGGBB', () {
    expect(ThemeDesign.rgb('#FF8000'), (r: 1.0, g: 128 / 255, b: 0.0));
    expect(ThemeDesign.rgb('4f94ff'), (r: 79 / 255, g: 148 / 255, b: 1.0));
    expect(ThemeDesign.rgb('#12'), isNull);
    expect(ThemeDesign.rgb('#GGGGGG'), isNull);
    expect(ThemeDesign.hex((r: 1, g: 0.5, b: 0)), '#FF8000');
  });

  test('a theme with its own picture goes into a file and comes back from it', () async {
    final picture = File(p.join(temp.path, 'my picture.JPG'))..writeAsStringSync('jpeg');
    var saved = library.save(design(), background: picture.path);
    expect(saved.background, 'background.jpg');
    expect(File(library.file(saved.background, saved)!).readAsStringSync(), 'jpeg');
    final file = p.join(temp.path, 'Midnight.anyps5theme');
    await library.export(saved, file);
    // theme.json and its files at the top of the zip, as `ditto -c -k` on the Mac makes it.
    final names = ZipDecoder().decodeBytes(File(file).readAsBytesSync()).files.map((entry) => entry.name);
    expect(names, unorderedEquals(['theme.json', 'background.jpg']));

    final other = ThemeLibrary(p.join(temp.path, 'Other'));
    final installed = other.install(file);
    expect(installed.name, 'Midnight');
    expect(installed.id, saved.id);
    expect(other.all.map((design) => design.id), [saved.id]);
    expect(File(other.file(installed.background, installed)!).readAsStringSync(), 'jpeg');

    saved = saved.copyWith(name: 'Midnight 2');
    library.save(saved);
    expect(library.all.map((design) => design.name), ['Midnight 2'], reason: 'saved again in place');
    expect(library.file(library.all.single.background, library.all.single), isNotNull, reason: 'the picture kept');
  });

  test('a theme file made on the Mac installs with its picture and music', () {
    final installed = library.install(fixture('ember-mac.anyps5theme'));
    expect(installed.id, 'b5c0f7a2-6a1e-4c2b-9d3f-0a1b2c3d4e5f');
    expect(installed.name, 'Ember Mac');
    expect(installed.author, 'Utku');
    expect(installed.style, 2);
    expect(installed.version, 3);
    expect(installed.accent, '#FF8A3D');
    expect(installed.background, 'background.jpg');
    expect(installed.music, 'music.m4a');
    expect(File(library.file(installed.music, installed)!).readAsStringSync(), 'm4a-bytes');
    // What the theme does not name stays behind.
    final kept = Directory(p.join(library.folder, installed.id)).listSync().map((entry) => p.basename(entry.path));
    expect(kept, unorderedEquals(['theme.json', 'background.jpg', 'music.m4a']));
  });

  test("the Hub's own theme files install", () {
    final installed = library.install(fixture('forest.anyps5theme'));
    expect(installed.id, 'forest');
    expect(installed.name, 'Forest');
    expect(installed.style, 1);
    expect(installed.background, isNull);
    expect(library.design('forest'), installed);
  });

  test('a file saved here reads on the Mac: the same theme.json fields, sorted', () async {
    final saved = library.save(design().copyWith(id: 'abc'));
    final file = p.join(temp.path, 'out.anyps5theme');
    await library.export(saved, file);
    final archive = ZipDecoder().decodeBytes(File(file).readAsBytesSync());
    final json = jsonDecode(utf8.decode(archive.findFile('theme.json')!.readBytes()!)) as Map<String, dynamic>;
    expect(json.keys.toList(), ['accent', 'author', 'bright', 'deep', 'id', 'middle', 'name', 'style', 'version']);
    expect(json['style'], 1);
    expect(json['version'], 1);
  });

  test('a theme file cannot reach outside its folder', () {
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          'theme.json',
          utf8.encode(jsonEncode(design().copyWith(id: '../../escape', background: () => '../secret.jpg').toJson())),
        ),
      )
      ..addFile(ArchiveFile.bytes('extra.sh', utf8.encode('x')))
      ..addFile(ArchiveFile.bytes('../secret.jpg', utf8.encode('x')));
    final file = File(p.join(temp.path, 'bad.anyps5theme'))..writeAsBytesSync(ZipEncoder().encode(archive));
    final installed = library.install(file.path);
    expect(installed.background, isNull);
    expect(installed.id, isNot(contains('/')));
    expect(Directory(p.join(library.folder, installed.id)).listSync().map((entry) => p.basename(entry.path)), [
      'theme.json',
    ]);
    expect(File(p.join(temp.path, 'escape')).existsSync(), isFalse);
  });

  test('a theme inside a folder of the zip installs too', () {
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          'Midnight/theme.json',
          utf8.encode(jsonEncode(design().copyWith(music: () => 'music.mp3').toJson())),
        ),
      )
      ..addFile(ArchiveFile.bytes('Midnight/music.mp3', utf8.encode('mp3')));
    final file = File(p.join(temp.path, 'folder.anyps5theme'))..writeAsBytesSync(ZipEncoder().encode(archive));
    final installed = library.install(file.path);
    expect(File(library.file(installed.music, installed)!).readAsStringSync(), 'mp3');
  });

  test('something else is not a theme', () {
    final file = File(p.join(temp.path, 'nothing.anyps5theme'))..writeAsStringSync('not a zip');
    expect(() => library.install(file.path), throwsA(isA<ThemeFailure>()));
    final empty = File(p.join(temp.path, 'empty.anyps5theme'))
      ..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile.bytes('readme.txt', [1]))));
    expect(() => library.install(empty.path), throwsA(isA<ThemeFailure>()));
    expect(library.all, isEmpty);
  });

  test('a removed theme is gone, a theme removing its picture loses the file', () {
    final picture = File(p.join(temp.path, 'a.png'))..writeAsStringSync('png');
    final saved = library.save(design(), background: picture.path);
    final video = File(p.join(temp.path, 'b.mp4'))..writeAsStringSync('mp4');
    final changed = library.save(saved, background: video.path);
    expect(changed.background, 'background.mp4');
    expect(changed.backgroundIsVideo, isTrue);
    expect(File(p.join(library.folder, saved.id, 'background.png')).existsSync(), isFalse);
    library.remove(saved.id);
    expect(library.all, isEmpty);
  });

  group('the Studio knobs', () {
    test('make the colours the Mac makes', () {
      final made = const ThemeKnobs(hue: 220, highlight: 20, depth: 5, accentHue: 30).applyTo(design());
      // ThemeKnobs.apply on the Mac for the same knobs.
      expect(made.deep, ThemeDesign.hex(ThemeDesign.hsb(220, 0.85, 0.09)));
      expect(made.middle, ThemeDesign.hex(ThemeDesign.hsb(220, 0.80, 0.40)));
      expect(made.bright, ThemeDesign.hex(ThemeDesign.hsb(240, 0.55, 1)));
      expect(made.accent, ThemeDesign.hex(ThemeDesign.hsb(30, 0.68, 1)));
      expect(ThemeDesign.hsb(0, 1, 1), (r: 1.0, g: 0.0, b: 0.0));
      expect(ThemeDesign.hex(ThemeDesign.hsb(120, 1, 1)), '#00FF00');
    });

    test('are read back from the colours they made', () {
      for (final knobs in const [
        ThemeKnobs(hue: 220, highlight: 20, depth: 5, accentHue: 30),
        ThemeKnobs(hue: 0, highlight: -45, depth: 1, accentHue: 300),
        ThemeKnobs(hue: 350, highlight: 90, depth: 10, accentHue: 0),
      ]) {
        expect(ThemeKnobs.of(knobs.applyTo(design())), knobs);
      }
    });

    test("turn a hand-made theme's colours into knobs inside their ranges", () {
      final knobs = ThemeKnobs.of(design().copyWith(middle: '#FFFFFF', bright: '#000000'));
      expect(knobs.depth, inInclusiveRange(1, 10));
      expect(knobs.highlight, inInclusiveRange(-90, 90));
    });
  });
}
