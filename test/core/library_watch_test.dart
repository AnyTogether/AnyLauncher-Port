import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/library_watch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

Game _game(String folder, String titleId) => Game(
  folder: '/games/$folder',
  titleId: titleId,
  name: titleId,
  names: {'en-US': titleId},
  defaultLanguage: 'en-US',
  version: '1.0',
  executable: ExecutableKind.elf,
);

void _writeSystem(String folder, String titleId) {
  Directory(p.join(folder, 'sce_sys')).createSync(recursive: true);
  File(p.join(folder, 'sce_sys', 'param.json')).writeAsStringSync(
    jsonEncode({
      'titleId': titleId,
      'contentVersion': '01.000',
      'localizedParameters': {
        'defaultLanguage': 'en-US',
        'en-US': {'titleName': 'Game $titleId'},
      },
    }),
  );
}

void _writeEboot(String folder) =>
    File(p.join(folder, 'eboot.bin')).writeAsBytesSync([...elfHead, ...List.filled(56, 0)]);

void main() {
  group('which games are new', () {
    test('the first scan is the baseline; later ones give what is new, once', () {
      final tracker = LibraryTracker();
      final a = _game('A', 'PPSA00001'), b = _game('B', 'PPSA00002'), c = _game('C', 'PPSA00003');
      expect(tracker.update([a, b]), isEmpty, reason: 'nothing is new on the first scan after launch');
      expect(tracker.update([a, b]), isEmpty);
      expect(tracker.update([a, b, c]), [c]);
      expect(tracker.update([a, b, c]), isEmpty);
    });

    test('several new games come together', () {
      final tracker = LibraryTracker();
      final a = _game('A', 'PPSA00001');
      tracker.update([a]);
      final added = [_game('B', 'PPSA00002'), _game('C', 'PPSA00003'), _game('D', 'PPSA00004')];
      expect(tracker.update([a, ...added]), added);
    });

    test('removed games go quietly, and are not new when they come back with their drive', () {
      final tracker = LibraryTracker();
      final a = _game('A', 'PPSA00001'), b = _game('B', 'PPSA00002');
      tracker.update([a, b]);
      expect(tracker.update([a]), isEmpty);
      expect(tracker.update([]), isEmpty);
      expect(tracker.update([a, b]), isEmpty);
    });

    test('a renamed or moved folder is not a new game; a second copy is', () {
      final tracker = LibraryTracker();
      tracker.update([_game('Old', 'PPSA00001'), _game('B', 'PPSA00002')]);
      expect(tracker.update([_game('Sub/New', 'PPSA00001'), _game('B', 'PPSA00002')]), isEmpty);
      final copy = _game('Copy', 'PPSA00002');
      expect(tracker.update([_game('Sub/New', 'PPSA00001'), _game('B', 'PPSA00002'), copy]), [copy]);
    });

    test('a new games folder starts a new baseline', () {
      final tracker = LibraryTracker()..update([_game('A', 'PPSA00001')]);
      tracker.reset();
      expect(tracker.update([_game('X', 'PPSA00009')]), isEmpty);
    });
  });

  group('half-copied dumps', () {
    late Directory root;
    setUp(() => root = temporaryFolder('survey'));
    tearDown(() => root.deleteSync(recursive: true));

    test('an incomplete dump is listed, and becomes a game when its copy finishes', () {
      makeDump(root.path, 'Have', titleId: 'PPSA00001');
      final tracker = LibraryTracker()..update(GameLibrary.survey(root.path).games);
      final folder = p.join(root.path, 'Sub', 'Copying');
      Directory(p.join(folder, 'sce_sys')).createSync(recursive: true);
      var survey = GameLibrary.survey(root.path);
      expect(survey.games, hasLength(1));
      expect(survey.incomplete, [folder]);
      File(p.join(folder, 'sce_sys', 'param.json')).writeAsStringSync('{"titleId":"PPSA0');
      expect(GameLibrary.survey(root.path).incomplete, [folder], reason: 'param.json half written');
      _writeSystem(folder, 'PPSA00002');
      survey = GameLibrary.survey(root.path);
      expect(survey.incomplete, [folder], reason: 'no eboot.bin yet');
      expect(tracker.update(survey.games), isEmpty);
      _writeEboot(folder);
      survey = GameLibrary.survey(root.path);
      expect(survey.incomplete, isEmpty);
      expect(tracker.update(survey.games).map((game) => game.name), ['Game PPSA00002']);
    });

    test('the survey finds what the scan finds', () {
      makeDump(root.path, 'A', titleId: 'PPSA00001');
      makeDump(p.join(root.path, 'Deep', 'Er'), 'B', titleId: 'PPSA00002');
      expect(
        GameLibrary.survey(root.path).games.map((game) => game.id),
        GameLibrary.scan(root.path).map((game) => game.id),
      );
      expect(GameLibrary.scan(root.path), hasLength(2));
    });

    test('the same listing compares what the library shows', () {
      final a = _game('A', 'PPSA00001');
      final unreadable = Game(
        folder: a.folder,
        titleId: a.titleId,
        name: a.name,
        names: a.names,
        defaultLanguage: a.defaultLanguage,
        version: a.version,
        executable: ExecutableKind.unreadable,
      );
      expect(GameLibrary.sameListing([a], [a]), isTrue);
      expect(GameLibrary.sameListing([a], [unreadable]), isFalse);
      expect(GameLibrary.sameListing([a], []), isFalse);
    });
  });

  test('the launcher\'s store and hidden files do not count', () {
    final base = p.join(p.separator, 'games');
    expect(LibraryWatcher.matters(p.join(base, '.AnyPS5', 'Games', 'x', 'app.elf'), base), isFalse);
    expect(LibraryWatcher.matters(p.join(base, '.AnyPS5'), base), isFalse);
    expect(LibraryWatcher.matters(p.join(base, 'Game', '.DS_Store'), base), isFalse);
    expect(LibraryWatcher.matters(p.join(base, 'Folder', 'Game', 'sce_sys', 'param.json'), base), isTrue);
    expect(LibraryWatcher.matters(p.join(base, 'Folder', 'Game', 'eboot.bin'), base), isTrue);
    expect(LibraryWatcher.matters(base, base), isTrue);
  });

  for (final recursive in [true, false]) {
    final mode = recursive ? 'one watch on the whole folder' : 'a watch per folder (Linux)';
    // The launcher watches the whole tree in one go only on macOS and Windows. On Linux, Dart's
    // recursive watch adds a folder's watch after the folder is made, so a folder made right
    // under it in the same moment can be missed: the launcher watches folder by folder there.
    final skip = recursive && Platform.isLinux ? 'one recursive watch is the macOS and Windows mode' : null;
    group('the watcher, $mode', skip: skip, () {
      late Directory root;
      late LibraryWatcher watcher;
      late List<List<Game>> scans;
      late LibraryTracker tracker;
      late List<Game> announced;

      setUp(() {
        root = temporaryFolder('watch');
        scans = [];
        announced = [];
        tracker = LibraryTracker();
        makeDump(root.path, 'Existing', titleId: 'PPSA00001');
        tracker.update(GameLibrary.survey(root.path).games);
        watcher = LibraryWatcher(
          root.path,
          recursive: recursive,
          onScan: () {
            final survey = GameLibrary.survey(root.path);
            scans.add(survey.games);
            announced.addAll(tracker.update(survey.games));
            return survey.incomplete;
          },
        )..start();
      });

      tearDown(() {
        watcher.stop();
        root.deleteSync(recursive: true);
      });

      Future<void> until(bool Function() condition, {Duration within = const Duration(seconds: 8)}) async {
        final end = DateTime.now().add(within);
        while (!condition() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(condition(), isTrue);
      }

      test('a game copied two folders down in steps is found when its eboot.bin lands', () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final folder = p.join(root.path, 'New Games', 'Big Game');
        Directory(folder).createSync(recursive: true);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        _writeSystem(folder, 'PPSA00002');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        Directory(p.join(folder, 'Content', 'Paks')).createSync(recursive: true);
        File(p.join(folder, 'Content', 'Paks', 'a.pak')).writeAsBytesSync(List.filled(4096, 0));
        _writeEboot(folder);
        await until(() => announced.any((game) => game.titleId == 'PPSA00002'));
        expect(announced.map((game) => game.titleId), ['PPSA00002'], reason: 'announced once');
        expect(scans.last, hasLength(2));
        expect(
          watcher.watchedFolders,
          recursive ? 1 : greaterThanOrEqualTo(5),
          reason: 'the new folders are watched too',
        );
      });

      test('a dump whose folder landed without its eboot.bin is found when the eboot comes', () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final folder = p.join(root.path, 'Late');
        _writeSystem(folder, 'PPSA00003');
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        _writeEboot(folder);
        await until(() => announced.any((game) => game.titleId == 'PPSA00003'));
      });

      test('writing in the launcher\'s store does not scan', () async {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final before = scans.length;
        final store = Directory(p.join(root.path, GameLibrary.storeName, 'Games', 'PPSA00001'))
          ..createSync(recursive: true);
        for (var index = 0; index < 20; index++) {
          File(p.join(store.path, 'file$index')).writeAsBytesSync(List.filled(1024, 0));
        }
        await Future<void>.delayed(const Duration(milliseconds: 3000));
        expect(scans.length, before);
      });

      test('asked rescans are coalesced, not dropped', () async {
        makeDump(root.path, 'Meanwhile', titleId: 'PPSA00004');
        for (var index = 0; index < 5; index++) {
          watcher.rescanSoon();
        }
        await until(() => scans.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(scans.length, lessThanOrEqualTo(2));
        expect(announced.map((game) => game.titleId), ['PPSA00004']);
      });
    });
  }

  test('a games folder that is not there yet is watched once it appears (a drive plugged in)', () async {
    final parent = temporaryFolder('later');
    addTearDown(() => parent.deleteSync(recursive: true));
    final folder = p.join(parent.path, 'Games');
    final found = <String>[];
    final watcher = LibraryWatcher(
      folder,
      timing: const LibraryTiming(missingPoll: Duration(milliseconds: 300)),
      onScan: () {
        found.addAll(GameLibrary.scan(folder).map((game) => game.titleId));
        return const [];
      },
    )..start();
    addTearDown(watcher.stop);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    makeDump(folder, 'Game', titleId: 'PPSA00005');
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (!found.contains('PPSA00005') && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(found, contains('PPSA00005'));
  });
}
