import 'dart:io';

import 'package:anyps5_desktop/core/game_log.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';

void main() {
  late Directory temp;
  setUp(() => temp = temporaryFolder('game-log'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('a log grown too big', () {
    test('is set aside as <TID>.previous.log before a start, the one before dropped', () {
      final log = p.join(temp.path, 'PPSA01001.log');
      final previous = p.join(temp.path, 'PPSA01001.previous.log');
      File(previous).writeAsStringSync('older');
      File(log).writeAsStringSync('x' * 2048);
      expect(GameLog.rollForStart(log, limit: 1024), isTrue);
      expect(File(log).existsSync(), isFalse);
      expect(File(previous).readAsStringSync(), 'x' * 2048);
    });

    test('stays where it is while under the limit', () {
      final log = p.join(temp.path, 'PPSA01001.log');
      File(log).writeAsStringSync('short');
      expect(GameLog.rollForStart(log, limit: 1024), isFalse);
      expect(File(log).readAsStringSync(), 'short');
      expect(GameLog.rollForStart(p.join(temp.path, 'missing.log')), isFalse);
    });
  });

  group('the log a running game writes', () {
    test('starts again past its cap, the lines before kept as <TID>.earlier.log', () {
      final path = p.join(temp.path, 'PPSA01001.log');
      File(path).writeAsStringSync('before\n');
      final log = CappedLog(path, cap: 200)
        ..writeln('--- start')
        ..add(List.filled(220, 0x61));
      log.writeln('after the cut');
      log.close();
      final earlier = File(p.join(temp.path, 'PPSA01001.earlier.log')).readAsStringSync();
      expect(earlier, startsWith('before\n--- start\n'));
      expect(earlier, contains('a' * 220));
      final now = File(path).readAsStringSync();
      expect(now, contains('log rotated at'));
      expect(now, contains('PPSA01001.earlier.log'));
      expect(now, endsWith('after the cut\n'));
    });

    test('keeps at most twice the cap on disk', () {
      final path = p.join(temp.path, 'PPSA01001.log');
      final log = CappedLog(path, cap: 1000);
      for (var line = 0; line < 400; line++) {
        log.writeln('line $line ${'x' * 40}');
      }
      log.close();
      expect(File(path).lengthSync(), lessThanOrEqualTo(1100));
      expect(File(p.join(temp.path, 'PPSA01001.earlier.log')).lengthSync(), lessThanOrEqualTo(1100));
      expect(File(path).readAsStringSync(), contains('line 399'));
    });
  });

  group('the last start', () {
    test('is what follows the last start line, which says whether it was traced', () {
      final log = [
        '--- 2026-10-24T20:00:00.000 PPSA01001-app',
        'first run',
        '--- exit 0',
        '[unlock] relinking',
        GameLog.startLine(DateTime(2026, 10, 24, 21), 'PPSA01001-app', traced: true),
        'second run',
        '--- exit -11',
      ].join('\n');
      final session = GameLog.lastSession(log);
      expect(session, startsWith('--- 2026-10-24T21:00:00.000 PPSA01001-app trace'));
      expect(session, contains('second run'));
      expect(session, isNot(contains('first run')));
      expect(session, isNot(contains('relinking')));
      expect(GameLog.tracedStart(session), isTrue);
      expect(GameLog.tracedStart(GameLog.lastSession(log.replaceAll(' trace', ''))), isFalse);
    });

    test('is the end of the log when no start line is in it', () {
      final log = 'x' * (100 * 1024);
      expect(GameLog.lastSession(log).length, 64 * 1024);
    });

    test('reads the end of a big file only', () {
      final path = p.join(temp.path, 'big.log');
      File(path).writeAsStringSync('${'a' * 5000}tail');
      expect(GameLog.tail(path, 4), 'tail');
      expect(GameLog.tail(p.join(temp.path, 'none.log'), 4), '');
    });
  });

  test('the last unlock\'s output is kept apart, with the error it stopped on', () {
    final path = GameLog.unlockFile(temp.path, 'PPSA01001');
    expect(p.basename(path), 'PPSA01001-unlock.log');
    GameLog.writeUnlockLog(path, ['[relink] start', '[relink] done'], failure: 'relinker exited with 1');
    expect(File(path).readAsStringSync(), '[relink] start\n[relink] done\nrelinker exited with 1\n');
    expect(GameLog.read(path), contains('relinker exited with 1'));
    expect(GameLog.read(p.join(temp.path, 'none.log')), isNull);
  });

  group('detailed logging', () {
    test('turns on the engine\'s runtime switches Windows and Linux builds read', () {
      final environment = TraceMode.environment;
      for (final key in [
        'APS5_LOG_SYNC',
        'APS5_LOG_TIMESTAMPS',
        'APS5_TRACE_EXIT',
        'APS5_TRACE_UNREADABLE',
        'APS5_TRACE_MEMORY',
        'APS5_SAVEDATA_TRACE',
        'APS5_CRASH_INDIRECT_MEMORY',
      ]) {
        expect(environment[key], '1', reason: key);
      }
      // Recorded only by an executable relinked with --trace-imports; ignored by the others.
      expect(environment['APS5_TRACE_CALLS'], 'all');
      // MoltenVK is the Mac's.
      expect(environment.keys.where((key) => key.startsWith('MVK_')), isEmpty);
    });

    test('is a game setting, off by default, kept with the Mac\'s key', () {
      const settings = GameSettings();
      expect(settings.trace, isNull);
      expect(settings.environment(launcherLanguage: 1).keys, isNot(contains('APS5_LOG_SYNC')));
      final traced = settings.copyWith(trace: true);
      expect(traced.toJson()['trace'], isTrue);
      expect(GameSettings.fromJson(traced.toJson()).trace, isTrue);
      expect(traced.environment(launcherLanguage: 1)['APS5_TRACE_EXIT'], '1');
      expect(traced.copyWith(trace: null).toJson().containsKey('trace'), isFalse);
    });

    test('can be asked for one start without the setting', () {
      final environment = const GameSettings().environment(launcherLanguage: 1, trace: true);
      expect(environment['APS5_LOG_SYNC'], '1');
      expect(environment['ANYPS5_LANGUAGE'], '1');
    });
  });
}
