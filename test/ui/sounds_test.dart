import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/audio/atrac9.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_audio.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// Where the launcher plays its sounds, as the macOS launcher does, and the selected game's
/// theme song.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakeAudio out;
  late List<String> decoded;

  setUp(() async {
    out = FakeAudio();
    decoded = [];
    fixture = makeFixture(
      audio: out,
      decodeSong: (path) async {
        decoded.add(path);
        return PlayableSong(Uint8List.fromList([1, 2, 3]), const Duration(seconds: 1));
      },
    );
    model = fixture.model;
    await model.startAudio();
  });

  tearDown(() {
    model.dispose();
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  /// The next step: the same cue may play again.
  Future<void> step() => Future<void>.value();

  int indexOf(String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

  Iterable<FakeVoice> songs() => out.voices.where((voice) => voice.sound.name.startsWith('anyps5-song'));

  test('moving between the tiles, the buttons and the top bar ticks; an edge says nothing', () async {
    model.select(0);
    await step();
    model.handle(Command.left);
    expect(out.cues, isEmpty);
    model.handle(Command.right);
    await step();
    model.handle(Command.down);
    await step();
    model.handle(Command.right);
    await step();
    model.handle(Command.up);
    await step();
    model.handle(Command.up);
    expect(out.cues, ['move', 'move', 'move', 'move', 'move']);
    expect(out.voices.first.volume, closeTo(0.32, 1e-9));
  });

  test('a panel opens with select, its rows tick and it closes with back', () async {
    model.open(Layer.settings);
    await step();
    model.handle(Command.down);
    await step();
    model.handle(Command.back);
    expect(out.cues, ['select', 'move', 'back']);
  });

  test('a row\'s action that opens another panel plays select once', () async {
    model.open(Layer.gameSettings);
    await step();
    final rows = model.panelCategories().first.rows;
    model.panelRow = rows.indexWhere((row) => row.id == 'controls');
    model.handle(Command.select);
    expect(model.overlay, Layer.controls);
    expect(out.cues, ['select', 'select']);
    await step();
    model.handle(Command.back);
    expect(model.overlay, Layer.gameSettings);
    expect(out.cues.last, 'back');
  });

  test('Behaviour: the interface sounds\' volume, off at 0, and the game music\'s', () async {
    model.open(Layer.settings);
    final categories = model.panelCategories();
    final behaviour = categories.indexWhere((category) => category.id == 'general');
    expect(categories[behaviour].title, 'Behaviour');
    model.selectCategory(behaviour);
    PanelRow row(String id) => model.panelCategories()[behaviour].rows.firstWhere((row) => row.id == id);
    expect(row('sounds').title, 'Interface Sounds');
    expect((row('sounds').kind as StepperRow).format(100), '100%');
    expect((row('music').kind as StepperRow).value, 50);
    expect(row('music').detail, T.text('gameMusicDetail'));
    model.panelRow = model.panelCategories()[behaviour].rows.indexWhere((row) => row.id == 'sounds');
    await step();
    out.voices.clear();
    model.handle(Command.left);
    expect(model.preferences.soundVolume, 90);
    expect(model.sounds.volume, closeTo(0.9, 1e-9));
    expect(out.voices.single.volume, closeTo(0.32 * 0.9, 1e-9), reason: 'the tick at the new volume');
    for (var times = 0; times < 9; times++) {
      await step();
      model.handle(Command.left);
    }
    expect(model.preferences.sounds, isFalse);
    expect(model.preferences.soundVolume, 10, reason: 'the last volume is kept for turning them on');
    expect((row('sounds').kind as StepperRow).format(0), T.text('off'));
    expect(out.voices, hasLength(9), reason: 'turning them off is silent');
    await step();
    model.handle(Command.right);
    expect(model.preferences.sounds, isTrue);
    expect(model.preferences.soundVolume, 10);
    model.panelRow = model.panelCategories()[behaviour].rows.indexWhere((row) => row.id == 'music');
    model.handle(Command.right);
    expect(model.preferences.musicVolume, 60);
    expect(model.music.volume, closeTo(0.6, 1e-9));
    final saved = Preferences.fromJson(model.preferences.toJson());
    expect([saved.sounds, saved.soundVolume, saved.musicVolume], [true, 10, 60]);
    expect([Preferences().sounds, Preferences().soundVolume, Preferences().musicVolume], [true, null, null]);
  });

  test('Behaviour in Turkish', () {
    T.language = Language.turkish;
    model.open(Layer.settings);
    final behaviour = model.panelCategories().firstWhere((category) => category.id == 'general');
    expect(behaviour.title, 'Davranış');
    final rows = {for (final row in behaviour.rows) row.id: row};
    expect(rows['sounds']!.title, 'Arayüz Sesleri');
    expect(rows['music']!.title, 'Oyun Müziği');
    expect(rows['music']!.detail, 'Seçili oyunun kendi müziği, varsa');
    expect((rows['music']!.kind as StepperRow).format(0), 'Kapalı');
  });

  test('unlocking: select as it starts, the finished sound when the game is ready', () async {
    final game = model.games[indexOf('PPSA02002')];
    File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    model.primaryAction(game);
    expect(out.cues, ['select']);
    await until(() => model.stateOf(game) is Installed);
    expect(out.cues, ['select', 'unlocked']);
  }, skip: Platform.isWindows ? 'the fake relinker is a shell script' : false);

  test('the selected game\'s theme song plays while the launcher is in front and idle', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    File(p.join(orbit.folder, 'sce_sys', 'snd0.at9')).writeAsBytesSync([0]);
    model.rescan();
    model.select(indexOf('PPSA01001'));
    await until(() => songs().isNotEmpty && songs().last.volume > 0.49);
    final first = songs().single;
    expect(decoded, [p.join(orbit.folder, 'sce_sys', 'snd0.at9')]);
    expect(first.loop, isTrue);
    expect(first.loopStart, const Duration(seconds: 1));
    expect(model.music.volume, 0.5);

    // Behind another window: it fades out; in front again, it comes back without decoding again.
    model.setActive(false);
    await until(() => first.stopped);
    model.setActive(true);
    await until(() => songs().length == 2);
    expect(decoded, hasLength(1));

    // A game without a song: silence.
    model.moveSelection(1);
    await until(() => songs().last.stopped);

    // At volume 0 nothing plays.
    model.preferences.musicVolume = 0;
    model.select(indexOf('PPSA01001'));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(songs(), hasLength(2));
  });

  test('a game starting or playing silences the song and, in front, the interface sounds', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    File(p.join(orbit.folder, 'sce_sys', 'snd0.at9')).writeAsBytesSync([0]);
    model.rescan();
    final installed = Installer.installedFolder(model.games[indexOf('PPSA01001')], model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 0.6\n');
    Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    model.select(indexOf('PPSA01001'));
    await until(() => songs().isNotEmpty && songs().last.volume > 0.49);
    out.voices.removeWhere((voice) => !voice.sound.name.startsWith('anyps5-song'));
    final playing = model.play(model.selectedGame!);
    expect(out.cues, ['select']);
    await until(() => songs().single.stopped);
    await until(() => model.running != null);
    model.setActive(false);
    await step();
    model.moveSelection(1);
    expect(out.cues, ['select'], reason: 'quiet while the game is in front');
    await playing;
    model.setActive(true);
    expect(model.sounds.muted, isFalse);
  }, skip: Platform.isWindows ? 'runs a shell script as the game' : false);
}
