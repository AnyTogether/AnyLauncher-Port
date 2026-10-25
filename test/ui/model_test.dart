import 'dart:io';

import 'package:anyps5_desktop/core/file_links.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// The launcher's state machine with the fake toolkit: installs, failures, the queue, updates
/// and a game started and ended.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
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

  int indexOf(String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

  test('a failed install shows the relinker message; trying again starts over', () async {
    makeFakeToolkit(fixture.toolkit, mode: 'fail');
    final game = model.games[indexOf('PPSA02002')];
    File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    model.primaryAction(game);
    expect(model.stateOf(game), isA<Installing>());
    await until(() => model.stateOf(game) is Failed);
    expect((model.stateOf(game) as Failed).message, 'relinker failed (3): relink: unsupported relocation');
    expect(model.toast, startsWith(T.text('unlockFailed')));
    makeFakeToolkit(fixture.toolkit);
    model.primaryAction(game);
    await until(() => model.stateOf(game) is Installed);
    expect(model.records[game.id]!.toolkit, 'toolkit-1');
  });

  test('a second game waits its turn and can leave the queue', () async {
    makeFakeToolkit(fixture.toolkit, mode: 'slow');
    final first = model.games[indexOf('PPSA02002')];
    final second = model.games[indexOf('PPSA03003')];
    for (final game in [first, second]) {
      File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    }
    model.unlock(first);
    model.unlock(second);
    expect(model.stateOf(first), isA<Installing>());
    expect(model.stateOf(second), isA<Queued>());
    model.primaryAction(second);
    expect(model.stateOf(second), isA<Locked>(), reason: 'cancelled while queued');
    await until(() => model.progress[first.id]?.$1 == InstallStep.relink);
    model.cancelUnlock(first);
    await until(() => model.stateOf(first) is Locked);
    expect(model.failures, isEmpty, reason: 'a cancel is not a failure');
  });

  test('a game made with an older toolkit is offered an update', () {
    final orbit = model.games[indexOf('PPSA01001')];
    expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));
    makeFakeToolkit(fixture.toolkit, version: 'toolkit-2');
    // The toolkit is read again with the library (or when the launcher comes back in front), not
    // on every frame.
    model.rescan();
    expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isTrue));
    model.primaryAction(orbit);
    expect(model.overlay, Layer.updateChoice);
    expect(model.panelCategories().single.rows.map((row) => row.id), ['update', 'play']);
  });

  test('playing writes the input file, passes the environment and ends with the game', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    final installed = Installer.installedFolder(orbit, model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_ | sort\nsleep 0.3\n');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    final playing = model.play(orbit);
    expect(model.stateOf(orbit), isA<Starting>());
    await until(() => model.stateOf(orbit) is Running);
    await playing;
    expect(model.stateOf(orbit), isA<Installed>());
    final log = File(model.paths.logFile(orbit.titleId)).readAsStringSync();
    expect(log, contains('ANYPS5_LANGUAGE=1'));
    expect(log, contains('ANYPS5_INPUT_CONFIG=${p.join(model.paths.inputFilesFolder, '${orbit.slug}.ini')}'));
    expect(log, contains('ANYPS5_SHADER_CACHE_DIR=${model.paths.shaderCache(orbit.slug)}'));
    expect(
      File(p.join(model.paths.inputFilesFolder, '${orbit.slug}.ini')).readAsStringSync(),
      contains('Cross = KEY:K'),
    );
    expect(model.preferences.lastPlayed, contains(orbit.id));
  });

  test('saves are backed up and restored from the game settings', () {
    final orbit = model.games[indexOf('PPSA01001')];
    final installed = Installer.installedFolder(orbit, model.root!);
    File(p.join(installed, '_sd', 'save.dat'))
      ..createSync(recursive: true)
      ..writeAsStringSync('one');
    model.select(indexOf('PPSA01001'));
    model.open(Layer.gameSettings);
    final backup = model.panelCategories().single.rows.firstWhere((row) => row.id == 'backup');
    (backup.kind as ActionRow).run();
    expect(model.toast, T.text('savesBackedUp'));
    File(p.join(installed, '_sd', 'save.dat')).writeAsStringSync('two');
    final restore = model.panelCategories().single.rows.firstWhere((row) => row.id == 'restore');
    (restore.kind as ActionRow).run();
    expect(File(p.join(installed, '_sd', 'save.dat')).readAsStringSync(), 'one');
    expect(model.toast, T.text('savesRestored'));
  });

  test('a dump copied into the games folder shows up on its own', () async {
    model.watchGamesFolder();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    makeDump(model.root!, 'late', titleId: 'PPSA09009', names: {'en-US': 'Late Arrival'});
    await until(() => model.games.any((game) => game.titleId == 'PPSA09009'));
    expect(model.games, hasLength(5));
  });

  group('an unlock that would copy', () {
    // The games folder cannot link to the dump: another drive, Windows without Developer Mode.
    setUp(() => FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false));
    tearDown(() => FileLinks.calls = FileLinks.system);

    List<String> rowIds() => model.panelCategories().single.rows.map((row) => row.id).toList();

    test('asks first, says how much and why, and copies when told to', () async {
      final stray = model.games[indexOf('PPSA02002')];
      File(p.join(stray.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      model.sizes[stray.id] = 31400000000;
      model.unlock(stray);
      expect(model.overlay, Layer.copyWarning);
      expect(model.stateOf(stray), isA<Locked>(), reason: 'nothing starts before the answer');
      expect(model.panelCategories().single.title, T.text('copyWarningTitle'));
      expect(rowIds(), ['why', 'sameDrive', 'copyAnyway', 'cancel'], reason: 'no Developer Mode on Linux');
      final why = model.panelCategories().single.rows.first.kind as InfoRow;
      expect(why.text, contains('31.4 GB'));
      // The keyboard and the pad move through it like any panel: the explanation is skipped.
      expect(model.panelRow, 1);
      model.handle(Command.down);
      model.handle(Command.select);
      expect(model.overlay, isNull);
      expect(model.stateOf(stray), isA<Installing>());
      await until(() => model.stateOf(stray) is Installed);
      final installed = Installer.installedFolder(stray, model.root!);
      expect(
        FileSystemEntity.typeSync(p.join(installed, 'app0', 'sce_sys', 'param.json'), followLinks: false),
        FileSystemEntityType.file,
      );
    });

    test('on Windows it offers Developer Mode; the folder choice and cancel start nothing', () {
      model.dispose();
      fixture.dispose();
      fixture = makeFixture(system: HostSystem.windows);
      model = fixture.model;
      final stray = model.games[indexOf('PPSA02002')];
      model.sizes[stray.id] = 52000000000;
      model.unlock(stray);
      expect(rowIds(), ['why', 'sameDrive', 'developerMode', 'copyAnyway', 'cancel']);
      expect((model.panelCategories().single.rows.first.kind as InfoRow).text, contains('Developer Mode'));
      model.handle(Command.down);
      model.handle(Command.select);
      expect(fixture.opened, [Uri.parse('ms-settings:developers')]);
      expect(model.overlay, isNull);
      expect(model.toast, T.text('copyFixDeveloperModeThen'));
      expect(model.stateOf(stray), isA<Locked>());
      model.unlock(stray);
      model.handle(Command.select);
      expect(model.overlay, isNull, reason: 'the games folder was chosen');
      expect(model.stateOf(stray), isA<Locked>());
      model.unlock(stray);
      model.handle(Command.back);
      expect(model.overlay, isNull);
      expect(model.stateOf(stray), isA<Locked>());
      expect(model.queue, isEmpty);
    });

    test('a small copy goes ahead without asking', () {
      final stray = model.games[indexOf('PPSA02002')];
      model.sizes[stray.id] = 6000000;
      model.unlock(stray);
      expect(model.overlay, isNull);
      expect(model.stateOf(stray), isNot(isA<Locked>()));
    });
  });

  test('a game whose dump moved away from its links says so instead of starting', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    final installed = Installer.installedFolder(orbit, model.root!);
    Directory(p.join(installed, 'app0')).createSync(recursive: true);
    Link(p.join(installed, 'app0', 'eboot.bin')).createSync(p.join(model.root!, 'moved-away', 'eboot.bin'));
    await model.play(orbit);
    expect(model.toast, T.text('dumpMoved'));
    expect(model.stateOf(orbit), isA<Installed>());
    expect(File(model.paths.logFile(orbit.titleId)).existsSync(), isFalse, reason: 'nothing started');
  });

  test('uninstalling removes the installed game and keeps the dump', () {
    final orbit = model.games[indexOf('PPSA01001')];
    model.uninstall(orbit);
    expect(model.stateOf(orbit), isA<Locked>());
    expect(Directory(Installer.installedFolder(orbit, model.root!)).existsSync(), isFalse);
    expect(File(p.join(orbit.folder, 'eboot.bin')).existsSync(), isTrue);
  });
}
