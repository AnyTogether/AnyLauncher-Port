import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:flutter_test/flutter_test.dart';

const windowsCrash = '''
--- 2026-10-24T21:30:00.000 PPSA01001-app
[agc] Selected GPU name=NVIDIA GeForce RTX 3070 vendor=0x10de device=0x2484 subgroup=32
[kernel] loading C:\\Users\\Utku Halis\\Games\\PPSA01001-app\\eboot.bin
[savedata] mount /home/utku/.local/share/AnyPS5 for utku@example.com

FATAL: unhandled exception 0xc0000005 on thread 9384 'GameMain'
  rip app.exe+0x10006
  read of 0x0000000000000010
  rax 0000000000000000 rbx 0000000000000001 rcx 0000000000000002 rdx 0000000000000003
--- exit -1073741819''';

ReportPrivacy windowsUser() => const ReportPrivacy(
  home: r'C:\Users\Utku Halis',
  names: ['Utku Halis', 'DESKTOP-UTKU'],
  secrets: ['secret-access-token-123'],
);

SessionReport report({
  String session = windowsCrash,
  int? exitCode = -1073741819,
  bool traced = false,
  String? engine = 'upstream-v0.1.3',
  ReportPrivacy? privacy,
  String? unlockLog,
}) => SessionReport(
  gameName: 'Orbit Runner',
  titleId: 'PPSA01001',
  gameVersion: '01.000.002',
  settings: const GameSettings(fullscreen: true),
  system: const SystemInfo(os: 'Windows 11 Pro 10.0 (Build 22631)', cpu: 'AMD Ryzen 7 5800X', memoryGB: 32),
  launcherVersion: '0.1.4',
  platform: 'Windows',
  session: session,
  created: DateTime(2026, 10, 24, 21, 31),
  privacy: privacy ?? windowsUser(),
  exitCode: exitCode,
  traced: traced,
  unlockedWith: engine,
  engineNow: engine,
  started: DateTime(2026, 10, 24, 21, 30),
  ended: DateTime(2026, 10, 24, 21, 31, 5),
  unlockLog: unlockLog,
);

void main() {
  group('personal details', () {
    test('the Windows home folder becomes ~, in either slash and any case', () {
      final privacy = windowsUser();
      expect(privacy.clean(r'C:\Users\Utku Halis\Games\a.bin'), r'~\Games\a.bin');
      expect(privacy.clean('c:/users/utku halis/Games'), '~/Games');
      expect(privacy.clean(r'D:\Users\Someone Else\x'), r'D:\Users\<user>\x');
      expect(privacy.clean(r'C:\Users\Public\Documents'), r'C:\Users\Public\Documents');
    });

    test('a Linux home becomes ~, other homes <user>', () {
      const privacy = ReportPrivacy(home: '/home/utku', names: ['utku']);
      expect(privacy.clean('/home/utku/Games/x and /home/utkuhalis/y'), '~/Games/x and /home/<user>/y');
      expect(privacy.clean('/home/ada/.config'), '/home/<user>/.config');
    });

    test('names, the computer\'s name, e-mails, private addresses and tokens are taken out', () {
      final text = windowsUser().clean(
        'Utku Halis on DESKTOP-UTKU mailed ada@example.org from 192.168.1.20 '
        'with Bearer abcdefghijk token=hunter22 and secret-access-token-123 '
        'eyJhbGciOiJI.eyJzdWIiOiIxMjM0.c2lnbmF0dXJlMTIz',
      );
      expect(text, isNot(contains('Utku')));
      expect(text, isNot(contains('DESKTOP-UTKU')));
      expect(text, isNot(contains('ada@example.org')));
      expect(text, isNot(contains('192.168.1.20')));
      expect(text, isNot(contains('abcdefghijk')));
      expect(text, isNot(contains('hunter22')));
      expect(text, isNot(contains('secret-access-token-123')));
      expect(text, isNot(contains('eyJhbGciOiJI')));
      expect(text, contains('<user> on <user>'));
      expect(text, contains('<email>'));
      expect(text, contains('<ip>'));
    });

    test('a short or common word stays', () {
      const privacy = ReportPrivacy(home: '/home/al', names: ['al']);
      expect(privacy.clean('alpha al'), 'alpha al');
    });
  });

  group('why a game stopped', () {
    test('a Windows crash report in the log names the exception', () {
      final found = Diagnosis.read(windowsCrash, exitCode: -1073741819);
      expect(found, isA<Crashed>());
      expect(found!.report, 'The game crashed: access violation (0xC0000005)');
    });

    test('a Linux signal reads from the exit code', () {
      expect(Diagnosis.read('', exitCode: -11)!.report, 'The game crashed: SIGSEGV (signal 11)');
      expect(Diagnosis.read('', exitCode: -1073741795)!.report, 'The game crashed: illegal instruction (0xC000001D)');
    });

    test('the engine\'s own reasons come first', () {
      expect(
        Diagnosis.read(
          'app.elf: error while loading shared libraries: libSceAgc.so: cannot open shared object file',
          exitCode: 127,
        ),
        const MissingModule('libSceAgc.so'),
      );
      expect(
        Diagnosis.read(
          "terminate called after throwing an instance of 'std::runtime_error'\n  what():  sceFooBar not implemented",
          exitCode: -6,
        ),
        const Unsupported('sceFooBar'),
      );
      expect(Diagnosis.read('vkQueueSubmit: VK_ERROR_DEVICE_LOST', exitCode: 1), const GpuLost());
      expect(Diagnosis.read('std::bad_alloc', exitCode: 1), const OutOfMemory());
      expect(Diagnosis.read('[libc] abort() called from 0x1234', exitCode: 3), const Aborted());
    });

    test('a plain non-zero exit says its status; a clean exit says nothing', () {
      expect(Diagnosis.read('', exitCode: 3), const Exited(3));
      expect(Diagnosis.read('[libc] exit(0) called from 0x1', exitCode: 0), isNull);
      expect(Diagnosis.read('', exitCode: null), isNull);
    });

    test('the crash block and the GPU are read from the log', () {
      expect(Diagnosis.crashLines(windowsCrash, limit: 3), [
        "FATAL: unhandled exception 0xc0000005 on thread 9384 'GameMain'",
        '  rip app.exe+0x10006',
        '  read of 0x0000000000000010',
      ]);
      expect(Diagnosis.gpu(windowsCrash), 'NVIDIA GeForce RTX 3070');
      expect(Diagnosis.gpu('no gpu here'), isNull);
    });
  });

  group('the report', () {
    test('says what happened, on which system, engine and settings, cleaned', () {
      final text = report().text();
      expect(text, startsWith('AnyPS5 crash report, 2026-10-24'));
      expect(text, contains('Game: Orbit Runner (PPSA01001), version 01.000.002'));
      expect(text, contains('What happened: The game crashed: access violation (0xC0000005)'));
      expect(text, contains('ran 1 min 5 s'));
      expect(text, contains('exit code -1073741819 (0xC0000005)'));
      expect(
        text,
        contains('System: Windows 11 Pro 10.0 (Build 22631) · AMD Ryzen 7 5800X · 32 GB · NVIDIA GeForce RTX 3070'),
      );
      expect(text, contains('Launcher: AnyPS5 Desktop 0.1.4 (Windows)'));
      expect(text, contains('Engine the game was unlocked with: upstream-v0.1.3'));
      expect(text, contains('Fullscreen'));
      expect(text, contains('Detailed logging off'));
      expect(text, contains('  rip app.exe+0x10006'));
      expect(text, isNot(contains('Utku')));
      expect(text, isNot(contains('utku@example.com')));
      expect(text, contains(r'~\Games\PPSA01001-app\eboot.bin'));
    });

    test('the copied text carries the last 200 log lines; the saved file the whole start and the unlock', () {
      final long = [windowsCrash.split('\n').first, for (var line = 0; line < 500; line++) 'line $line'].join('\n');
      final short = report(session: long, unlockLog: '[relink] done').text();
      expect(short, contains('line 499'));
      expect(short, isNot(contains('line 100\n')));
      expect(short, isNot(contains('[relink] done')));
      final whole = report(session: long, unlockLog: '[relink] done').text(whole: true);
      expect(whole, contains('line 0\n'));
      expect(whole, contains('[relink] done'));
      expect(report().fileName, 'crash_log.txt');
    });

    test('carries the last lines of the game\'s online log, cleaned, when there are any', () {
      expect(report().text(), isNot(contains('Online play')));
      final online = SessionReport(
        gameName: 'Orbit Runner',
        titleId: 'PPSA01001',
        gameVersion: '01.000.002',
        settings: const GameSettings(),
        system: const SystemInfo(os: 'Windows 11'),
        launcherVersion: '0.1.8',
        platform: 'Windows',
        session: windowsCrash,
        privacy: windowsUser(),
        onlineLines: const [
          '{"v":1,"fn":"sceNpWebApi2CreateRequest","in":{"api_group":"sessionManager"}}',
          r'{"v":1,"fn":"sceNpGetOnlineId","in":{"path":"C:\\Users\\Utku Halis\\x"}}',
        ],
      );
      final text = online.text();
      expect(text, contains('Online play, the end of the game\'s online log (2 lines):'));
      expect(text, contains('  {"v":1,"fn":"sceNpWebApi2CreateRequest"'));
      expect(text, isNot(contains('Utku Halis')), reason: 'cleaned like the rest');
    });

    test('says when detailed logging was on and when the user stopped the game', () {
      expect(report(traced: true).text(), contains('detailed logging on'));
      final stopped = SessionReport(
        gameName: 'x',
        titleId: 'PPSA1',
        gameVersion: '1',
        settings: const GameSettings(),
        system: const SystemInfo(os: 'Linux'),
        launcherVersion: '0.1.4',
        platform: 'Linux',
        session: '',
        privacy: const ReportPrivacy(home: ''),
        exitCode: -15,
        stoppedByUser: true,
      );
      expect(stopped.reason, 'Stopped from the launcher');
      expect(stopped.abnormal, isFalse);
    });
  });

  group('the issue', () {
    test('goes to the engine\'s bug form on boykopovar/AnyPS5 for upstream\'s engine', () {
      final draft = IssueDraft.engine(report());
      expect(draft.url.host, 'github.com');
      expect(draft.url.path, '/boykopovar/AnyPS5/issues/new');
      final query = draft.url.queryParameters;
      expect(query['template'], 'bug_report.yml');
      expect(query['title'], 'Crash: Orbit Runner (PPSA01001) 01.000.002');
      expect(query['summary'], 'The game crashed: access violation (0xC0000005)');
      expect(query['commit'], contains('upstream-v0.1.3'));
      expect(query['commit'], contains('AnyPS5 Desktop 0.1.4'));
      expect(query['system'], contains('NVIDIA GeForce RTX 3070'));
      expect(query['steps'], contains('Fullscreen'));
      expect(query['log'], contains('FATAL: unhandled exception'));
      expect(query['notes'], contains('crash_log.txt'));
    });

    test('goes to AnyPS5-ARM for its engine', () {
      expect(IssueDraft.engine(report(engine: 'arm-1a2b3c4')).url.path, '/utkuhalis/AnyPS5-ARM/issues/new');
    });

    test('a launcher bug goes to utkuhalis/AnyPS5-Desktop\'s crash form', () {
      final draft = IssueDraft.launcher(report());
      expect(draft.url.path, '/utkuhalis/AnyPS5-Desktop/issues/new');
      final query = draft.url.queryParameters;
      expect(query['template'], 'crash.yml');
      expect(query['title'], 'Crash: Orbit Runner (PPSA01001)');
      expect(query['game'], 'Orbit Runner (PPSA01001), version 01.000.002');
      expect(query['versions'], contains('Launcher 0.1.4 (Windows)'));
      expect(query['report'], contains('crash_log.txt'));
    });

    test('a plus stays a plus and nothing personal is in the link', () {
      final draft = IssueDraft.engine(report(session: '$windowsCrash\nrip app.exe+0x1 C++ Utku Halis'));
      expect(draft.url.toString(), isNot(contains('+0x1 ')));
      expect(draft.url.queryParameters['log'], contains('app.exe+0x1 C++'));
      expect(draft.url.toString().toLowerCase(), isNot(contains('utku%20halis')));
      expect(draft.url.queryParameters.values.join('\n'), isNot(contains('Utku Halis')));
      expect(draft.preview, isNot(contains('Utku')));
    });

    test('fits GitHub\'s link length, the oldest log lines going first', () {
      final long = [
        windowsCrash.split('\n').first,
        for (var line = 0; line < 2000; line++) 'line $line ${'x' * 120}',
        'the last line',
      ].join('\n');
      for (final draft in [IssueDraft.engine(report(session: long)), IssueDraft.launcher(report(session: long))]) {
        expect(draft.url.toString().length, lessThanOrEqualTo(IssueDraft.maximumLength));
        expect(draft.url.queryParameters['log'], endsWith('the last line'));
        expect(draft.url.queryParameters['log'], isNot(contains('line 0 ')));
      }
    });
  });
}
