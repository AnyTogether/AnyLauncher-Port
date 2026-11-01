import 'dart:io';

import 'package:anyps5_desktop/core/themes/theme_design.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_audio.dart';
import '../support/ui_support.dart';

/// Settings › Appearance with themes: installing a `.anyps5theme` (as the Hub and a double-click
/// do), the Theme Studio changing the theme in use live, Save as a File, and the user's own
/// background and menu music.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakeAudio audio;
  String? picked;
  String? savedTo;

  setUp(() {
    picked = null;
    savedTo = null;
    audio = FakeAudio();
    fixture = makeFixture(
      audio: audio,
      pickFile: (label, extensions) async => picked,
      saveFileAs: (name, label, extensions) async => savedTo,
    );
    model = fixture.model;
  });

  tearDown(() {
    model.dispose();
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 2000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  List<PanelRow> rows() => model.panelCategories().expand((category) => category.rows).toList();
  PanelRow row(String id) => rows().firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));
  bool has(String id) => rows().any((row) => row.id == id);

  void openAppearance() {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'appearance');
  }

  String fixtureTheme(String name) => p.absolute(p.join('test', 'support', 'themes', name));

  test('a theme file made on the Mac installs, is used and wears its own colours', () async {
    final design = await model.installTheme(fixtureTheme('ember-mac.anyps5theme'));
    expect(design?.name, 'Ember Mac');
    expect(model.preferences.customTheme, design!.id);
    expect(model.activeDesign, design);
    expect(model.toast, T.format('themeInstalled', ['Ember Mac']));
    // Sunset's motion, the theme's own tones and accent.
    expect(model.look, LookStyle.sunset);
    expect(LookStyle.hex(model.palette.middle), '#6B2410');
    expect(LookStyle.hex(model.accentChoice.color), '#FF8A3D');
    // Its picture is the background; its music plays when the game has none.
    expect(model.ownBackground?.path, endsWith('background.jpg'));
    expect(model.ownBackground?.video, isFalse);
    expect(model.menuMusic, endsWith('music.m4a'));

    openAppearance();
    final theme = row('theme').kind as ChoiceRow;
    expect(theme.options.last, 'Ember Mac');
    expect(theme.selected, LookStyle.values.length);
    expect(has('accent'), isFalse, reason: 'the theme brings its accent');
    // Back to a built-in look.
    theme.set(LookStyle.aurora.index);
    expect(model.activeDesign, isNull);
    expect(model.look, LookStyle.aurora);
    expect(has('accent'), isTrue);
  });

  test('something that is no theme says so and changes nothing', () async {
    final bad = File(p.join(fixture.temp.path, 'bad.anyps5theme'))..writeAsStringSync('nope');
    expect(await model.installTheme(bad.path), isNull);
    expect(model.toast, T.text('themeInstallFailed'));
    expect(model.preferences.customTheme, isNull);
  });

  test('the Theme Studio copies the look in use and changes it live', () async {
    openAppearance();
    (row('studio').kind as ActionRow).run();
    expect(model.overlay, Layer.themeStudio);
    final design = model.activeDesign!;
    expect(design.name, T.text('newThemeName'));
    expect(design.author, 'Utku');
    expect(design.middle, LookStyle.hex(LookStyle.cosmic.middle));

    // A knob turned: the colours change and are saved at once.
    final hue = row('hue').kind as StepperRow;
    hue.set(hue.value + 40);
    final turned = model.activeDesign!;
    expect(turned.middle, isNot(design.middle));
    expect(model.themes.design(turned.id), turned, reason: 'saved as it changes');
    (row('motion').kind as ChoiceRow).set(LookStyle.glass.index);
    expect(model.look, LookStyle.glass);
    (row('name').kind as TextRow).set('Night Drive');
    expect(model.activeDesign!.name, 'Night Drive');

    // A picture, then a video, as its background; taken off again.
    picked = p.join(fixture.temp.path, 'mine.png');
    File(picked!).writeAsStringSync('png');
    (row('background').kind as ActionRow).run();
    await until(() => model.activeDesign!.background == 'background.png');
    expect(row('background').detail, T.text('backgroundImage'));
    picked = p.join(fixture.temp.path, 'loop.mp4');
    File(picked!).writeAsStringSync('mp4');
    (row('background').kind as ActionRow).run();
    await until(() => model.activeDesign!.background == 'background.mp4');
    expect(row('background').detail, T.text('backgroundVideo'));
    expect(model.ownBackground?.video, isTrue);
    (row('backgroundOff').kind as ActionRow).run();
    expect(model.activeDesign!.background, isNull);
    expect(File(p.join(model.themes.folder, turned.id, 'background.mp4')).existsSync(), isFalse);

    // Save as a File: one .anyps5theme, theme.json at its top.
    savedTo = p.join(fixture.temp.path, 'Night Drive');
    (row('export').kind as ActionRow).run();
    final file = File('$savedTo.${ThemeDesign.fileExtension}');
    await until(file.existsSync);
    expect(ZipDecoder().decodeBytes(file.readAsBytesSync()).findFile('theme.json'), isNotNull);
    expect(model.toast, T.text('themeSaved'));

    // Back goes to the themes, then to Appearance on the Themes row.
    model.handle(Command.back);
    expect(model.overlay, Layer.themes);
    expect(rows().map((row) => row.id), containsAll(['studio', 'file', 'design-${turned.id}']));
    expect(row('design-${turned.id}').detail, T.text('themeActive'));
    model.handle(Command.back);
    expect(model.overlay, Layer.settings);
    expect(model.panelCategories()[model.panelCategory].id, 'appearance');
    expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].id, 'themes');
  });

  test('a deleted theme goes back to the built-in look', () async {
    model.openStudio();
    final design = model.activeDesign!;
    (row('delete').kind as ActionRow).run();
    expect(model.overlay, Layer.themes);
    expect(model.activeDesign, isNull);
    expect(model.designs, isEmpty);
    expect(Directory(p.join(model.themes.folder, design.id)).existsSync(), isFalse);
  });

  test('Install from a File picks a theme file', () async {
    model.open(Layer.themes);
    picked = fixtureTheme('forest.anyps5theme');
    (row('file').kind as ActionRow).run();
    await until(() => model.activeDesign?.id == 'forest');
    expect(model.look, LookStyle.aurora);
  });

  test('my own picture or video as the background, and my own menu music', () async {
    openAppearance();
    expect((row('backdrop').kind as ChoiceRow).options, [
      T.text('backgroundTheme'),
      T.text('backgroundImage'),
      T.text('backgroundVideo'),
    ]);
    expect(has('backdropFile'), isFalse);
    picked = p.join(fixture.temp.path, 'wall.jpg');
    File(picked!).writeAsStringSync('jpg');
    (row('backdrop').kind as ChoiceRow).set(1);
    await until(() => model.preferences.backdrop == 'image');
    expect(model.preferences.backdropFile, picked);
    expect(model.ownBackground, (path: picked!, video: false));
    expect(row('backdropFile').detail, 'wall.jpg');
    // Back to the animation: the file is kept for next time.
    (row('backdrop').kind as ChoiceRow).set(0);
    expect(model.ownBackground, isNull);
    expect(model.preferences.backdropFile, picked);

    // Menu music for when the selected game has no song.
    final song = p.join(fixture.temp.path, 'menu.mp3');
    File(song).writeAsStringSync('mp3');
    picked = song;
    (row('menuMusic').kind as ActionRow).run();
    await until(() => model.preferences.menuMusicFile == song);
    expect(model.menuMusic, song);
    expect(row('menuMusic').detail, 'menu.mp3');
    await until(() => model.music.playing == 'theme:$song');
    (row('menuMusicOff').kind as ActionRow).run();
    expect(model.menuMusic, isNull);
  });

  test('the choices are kept in the preferences, with the macOS launcher\'s keys', () {
    final preferences = Preferences.fromJson({
      'customTheme': 'abc',
      'backdrop': 'video',
      'backdropFile': '/v/loop.mp4',
      'menuMusicFile': '/m/menu.mp3',
    });
    expect(preferences.customTheme, 'abc');
    expect(preferences.backdrop, 'video');
    final json = preferences.toJson();
    expect(json['backdropFile'], '/v/loop.mp4');
    expect(json['menuMusicFile'], '/m/menu.mp3');
    expect(Preferences.fromJson({'backdrop': 'hologram'}).backdrop, 'theme');
  });
}
