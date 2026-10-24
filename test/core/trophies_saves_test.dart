import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/save_backup.dart';
import 'package:anyps5_desktop/core/trophies.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/trophy_fixture.dart';

void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('trophies'));
  tearDown(() => temp.deleteSync(recursive: true));

  Game gameWithTrophies() {
    final folder = makeDump(temp.path, 'Game', names: {'en-US': 'Dump Name'});
    Directory(p.join(folder, 'sce_sys', 'trophy2')).createSync();
    File(p.join(folder, 'sce_sys', 'trophy2', 'trophy00.ucp')).writeAsBytesSync(
      ucp({
        'tropconf.json': json({
          'defaultLanguage': 'en-US',
          'trophies': [
            {'id': '0000', 'grade': 'P'},
            {'id': 1, 'grade': 'G', 'hidden': true},
            {
              'id': '0002',
              'grade': 'B',
              'unlockCondition': {'progressive': true, 'udsStatId': '7', 'targetValue': 10},
            },
            {'id': '0003', 'grade': 'X'},
          ],
        }),
        'tropmeta_en-US.json': json({
          'metadata': {
            'titleMetadata': {'name': 'Orbit Runner'},
            'trophyMetadata': [
              {'id': '0000', 'name': 'Every Star', 'detail': 'Earn every trophy'},
              {'id': '0001', 'name': 'Secret', 'detail': 'Find it'},
              {'id': '0002', 'name': 'Ten Laps', 'detail': 'Run ten laps'},
            ],
          },
        }),
        'tropmeta_tr-TR.json': json({
          'metadata': {
            'titleMetadata': {'name': 'Yörünge'},
            'trophyMetadata': [
              {'id': '0000', 'name': 'Bütün Yıldızlar', 'detail': 'Hepsini kazan'},
            ],
          },
        }),
        'trop0001.png': [0x89, 0x50, 0x4E, 0x47],
        'icon0.png': [1, 2, 3],
      }),
    );
    return GameLibrary.inspect(folder)!;
  }

  group('trophies', () {
    test('the list and texts come from the package, in the first language it has', () {
      final set = Trophies.load(gameWithTrophies(), languages: ['de-DE'])!;
      expect(set.title, 'Orbit Runner');
      expect(set.icon, [1, 2, 3]);
      expect(set.trophies.map((trophy) => trophy.id), ['0/0', '0/1', '0/2'], reason: 'grade X is not one');
      expect(set.trophies[0].grade, TrophyGrade.platinum);
      expect(set.trophies[0].name, 'Every Star');
      expect(set.trophies[1].hidden, isTrue);
      expect(set.trophies[1].icon, [0x89, 0x50, 0x4E, 0x47]);
      expect(set.trophies[2].progress, (0, 10));
      expect(set.unlockedCount, 0);
      expect(set.percent, 0);
      final turkish = Trophies.load(gameWithTrophies(), languages: ['tr-TR'])!;
      expect(turkish.title, 'Yörünge');
      expect(turkish.trophies[0].name, 'Bütün Yıldızlar');
      expect(turkish.trophies[1].name, '', reason: 'no Turkish text for it');
    });

    test('unlocks and stats come from the installed game, the earliest of every user', () {
      final game = gameWithTrophies();
      final installed = p.join(temp.path, 'installed');
      final records = Directory(p.join(installed, '_trophy'))..createSync(recursive: true);
      final when = DateTime.utc(2026, 10, 24, 20);
      final tick = Trophies.unixEpochTick + when.microsecondsSinceEpoch;
      File(p.join(records.path, '1_0.txt')).writeAsStringSync('1 $tick\n2 ${tick + 5000000}\n');
      File(p.join(records.path, '2_0.txt')).writeAsStringSync('1 ${tick + 1000000}\nbroken line\n');
      File(p.join(records.path, '1_0.stats.txt')).writeAsStringSync('7 4\n');
      File(p.join(records.path, '2_0.stats.txt')).writeAsStringSync('7 15\n');
      final set = Trophies.load(game, installed: installed)!;
      expect(set.trophies[1].unlocked, when);
      expect(set.trophies[2].unlocked, when.add(const Duration(seconds: 5)));
      expect(set.trophies[2].progress, (10, 10), reason: 'the highest value, capped at the target');
      expect(set.unlockedCount, 2);
      expect(set.count(TrophyGrade.gold), (1, 1));
      expect(set.count(TrophyGrade.platinum), (0, 1));
      expect(set.percent, (90 + 15) * 100 ~/ (300 + 90 + 15));
      expect(Trophies.earned(installed), {'0/1', '0/2'});
    });

    test('no packages, a broken package, no records', () {
      final plain = GameLibrary.inspect(makeDump(temp.path, 'Plain'))!;
      expect(Trophies.load(plain), isNull);
      expect(Trophies.readUcp(Uint8List.fromList([1, 2, 3])), isNull);
      expect(Trophies.earned(p.join(temp.path, 'nowhere')), isEmpty);
    });
  });

  group('save backup', () {
    String installedWithSaves() {
      final game = p.join(temp.path, 'installed');
      File(p.join(game, '_sd', 'slot0', 'save.dat'))
        ..createSync(recursive: true)
        ..writeAsStringSync('progress 1');
      File(p.join(game, '_trophy', '1_0.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('1 2');
      File(p.join(game, 'app.elf')).writeAsStringSync('not a save');
      return game;
    }

    test('backs up only the saves, named after the date, never over an older one', () {
      final game = installedWithSaves();
      final folder = SaveBackup.folderFor(p.join(temp.path, 'Backups'), 'Orbit: Runner', 'PPSA01001');
      expect(p.basename(folder), 'Orbit- Runner (PPSA01001)');
      final date = DateTime(2026, 10, 24, 21, 5, 9);
      final first = SaveBackup.backUp(game, folder, date);
      final second = SaveBackup.backUp(game, folder, date);
      expect(p.basename(first), '2026-10-24 21.05.09.zip');
      expect(p.basename(second), '2026-10-24 21.05.09 2.zip');
      expect(SaveBackup.contents(first)..sort(), ['_sd/slot0/save.dat', '_trophy/1_0.txt']);
      expect(SaveBackup.backups(folder), hasLength(2));
      expect(() => SaveBackup.backUp(p.join(temp.path, 'empty'), folder, date), throwsA(isA<SaveBackupFailure>()));
    });

    test('restoring puts the backup in place and keeps what was there first', () {
      final game = installedWithSaves();
      final folder = p.join(temp.path, 'Backups', 'G');
      final backup = SaveBackup.backUp(game, folder, DateTime(2026, 1, 1));
      File(p.join(game, '_sd', 'slot0', 'save.dat')).writeAsStringSync('progress 2');
      File(p.join(game, '_sd', 'slot1.dat')).writeAsStringSync('newer slot');
      SaveBackup.restore(backup, game, folder, DateTime(2026, 2, 2));
      expect(File(p.join(game, '_sd', 'slot0', 'save.dat')).readAsStringSync(), 'progress 1');
      expect(File(p.join(game, '_sd', 'slot1.dat')).existsSync(), isFalse);
      expect(File(p.join(game, 'app.elf')).readAsStringSync(), 'not a save');
      // The saves from before the restore were backed up.
      final kept = SaveBackup.backups(folder).firstWhere((path) => p.basename(path).startsWith('2026-02-02'));
      expect(SaveBackup.contents(kept), contains('_sd/slot1.dat'));
      expect(
        Directory(game).listSync().where((entry) => p.basename(entry.path).startsWith('.anyps5-restore')),
        isEmpty,
      );
    });

    test('a file that is not a backup, or holds no saves, is refused', () {
      final game = installedWithSaves();
      final junk = File(p.join(temp.path, 'junk.zip'))..writeAsStringSync('nope');
      expect(() => SaveBackup.restore(junk.path, game, temp.path, DateTime(2026)), throwsA(isA<SaveBackupFailure>()));
      expect(() => SaveBackup.contents(junk.path), throwsA(isA<SaveBackupFailure>()));
    });

    test('a backup made with the macOS launcher (ditto) restores', () {
      // ditto -c -k writes a plain zip with the same _sd/ layout; the system zip stands in.
      final source = Directory(p.join(temp.path, 'mac', '_sd'))..createSync(recursive: true);
      File(p.join(source.path, 'data.bin')).writeAsStringSync('from the mac');
      final zip = p.join(temp.path, 'mac.zip');
      final result = Process.runSync('zip', ['-r', '-q', zip, '_sd'], workingDirectory: p.join(temp.path, 'mac'));
      if (result.exitCode != 0) return markTestSkipped('zip is not installed');
      final game = installedWithSaves();
      SaveBackup.restore(zip, game, p.join(temp.path, 'kept'), DateTime(2026));
      expect(File(p.join(game, '_sd', 'data.bin')).readAsStringSync(), 'from the mac');
      expect(File(p.join(game, '_trophy', '1_0.txt')).existsSync(), isTrue, reason: 'parts not in the backup stay');
    });
  });
}
