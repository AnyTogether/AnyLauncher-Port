import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/steam/binary_vdf.dart';
import 'package:anyps5_desktop/core/steam/steam_install.dart';
import 'package:anyps5_desktop/core/steam/steam_launch.dart';
import 'package:anyps5_desktop/core/steam/steam_shortcuts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List fixture(String name) => File(p.join('test', 'core', 'steam', 'fixtures', name)).readAsBytesSync();

/// Each entry's bytes inside the shortcuts list, by AppName.
Map<String, List<int>> entryBytes(Uint8List file) {
  final list = BinaryVdf.decode(file).root.map('shortcuts')!;
  return {
    for (final entry in list.entries)
      (entry.value as VdfMap).string('AppName')!: BinaryVdf.encodeEntry(VdfEntry.map('x', entry.value as VdfMap)),
  };
}

void main() {
  group('shortcut IDs', () {
    test('CRC-32 is zlib\'s', () {
      expect(SteamAppId.crc32(ascii.encode('123456789')), 0xCBF43926);
      expect(SteamAppId.crc32(const []), 0);
    });

    test('the ID is CRC-32 of the quoted Exe and the AppName with the top bit set', () {
      // Worked out with Python's zlib.crc32((exe + name).encode()) | 0x80000000.
      expect(SteamAppId.shortcut(r'"C:\Program Files\AnyPS5\anyps5_desktop.exe"', 'AnyPS5'), 3980285510);
      expect(SteamAppId.shortcut('"/home/deck/Applications/AnyPS5-Desktop-x86_64.AppImage"', 'AnyPS5'), 4185666005);
      expect(
        SteamAppId.shortcut('"/home/deck/Applications/AnyPS5-Desktop-x86_64.AppImage"', 'Hollow Knight: Silksong'),
        3816483209,
      );
      expect(SteamAppId.gameId(3980285510), BigInt.parse('17095196094226235392'));
    });

    test('the appid field holds the same bits, signed', () {
      const shortcut = SteamShortcut(appName: 'AnyPS5', exe: '"/a"', startDir: '"/"', launchOptions: '--steam');
      expect(shortcut.toVdf().int32('appid')!.toUnsigned(32), shortcut.appId);
      expect(shortcut.appId & 0x80000000, isNonZero);
    });
  });

  group('the shortcuts', () {
    late Directory temp;
    late SteamInstall install;
    late SteamShortcuts steam;
    const user = SteamUser(id: '52079950');
    const program = '/home/deck/Applications/AnyPS5-Desktop-x86_64.AppImage';

    setUp(() {
      temp = Directory.systemTemp.createTempSync('steam');
      install = SteamInstall(temp.path);
      steam = SteamShortcuts(install, user);
    });
    tearDown(() => temp.deleteSync(recursive: true));

    void existing(String name) {
      File(steam.shortcutsFile)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(fixture(name));
    }

    Map<SteamArt, Uint8List> art(int seed) => {
      for (final kind in SteamArt.values) kind: Uint8List.fromList([seed, kind.index]),
    };

    List<SteamEntry> entries({bool games = false}) => [
      SteamEntry(SteamPlan.launcher(program, fullscreen: true, into: steam), art: art(1)),
      if (games)
        SteamEntry(
          SteamPlan.game(program, name: 'Hollow Knight: Silksong', titleId: 'PPSA12544', into: steam),
          art: art(2),
        ),
    ];

    test('the launcher\'s entry has every field Steam needs', () {
      existing('deck_shortcuts.vdf');
      final change = steam.put(entries());
      final ours = steam.ours();
      expect(ours, hasLength(1));
      final entry = ours.single;
      expect(entry.string('AppName'), 'AnyPS5');
      expect(entry.string('Exe'), '"$program"');
      expect(entry.string('StartDir'), '"/home/deck/Applications"');
      expect(entry.string('LaunchOptions'), '--steam --fullscreen');
      expect(entry.strings('tags'), ['AnyPS5']);
      expect(entry.int32('AllowOverlay'), 1);
      expect(ShortcutsFile.appIdOf(entry), 4185666005);
      expect(entry.string('icon'), p.join(steam.gridFolder, '4185666005_icon.png'));
      expect(change.appIds, [4185666005]);
      expect(Directory(steam.gridFolder).listSync().map((file) => p.basename(file.path)).toSet(), {
        '4185666005p.png',
        '4185666005.png',
        '4185666005_hero.png',
        '4185666005_logo.png',
        '4185666005_icon.png',
      });
      // Next after the three already there.
      final list = BinaryVdf.decode(File(steam.shortcutsFile).readAsBytesSync()).root.map('shortcuts')!;
      expect(list.entries.map((entry) => entry.name), ['0', '1', '2', '3']);
    });

    test('everyone else\'s shortcuts keep their bytes, and removing ours gives the file back', () {
      existing('windows_shortcuts.vdf');
      final before = fixture('windows_shortcuts.vdf');
      steam.put(entries(games: true));
      final after = File(steam.shortcutsFile).readAsBytesSync();
      final kept = entryBytes(after);
      for (final MapEntry(:key, :value) in entryBytes(before).entries) {
        expect(kept[key], value, reason: key);
      }
      expect(kept.keys, containsAll(['AnyPS5', 'Hollow Knight: Silksong']));
      final removed = steam.remove();
      expect(removed.appIds.toSet(), {4185666005, 3816483209});
      expect(File(steam.shortcutsFile).readAsBytesSync(), before);
    });

    test('adding again changes nothing; games turned off take their entry and pictures away', () {
      existing('deck_shortcuts.vdf');
      steam.put(entries(games: true));
      final once = File(steam.shortcutsFile).readAsBytesSync();
      steam.put(entries(games: true));
      expect(File(steam.shortcutsFile).readAsBytesSync(), once);
      expect(steam.ours(), hasLength(2));
      steam.put(entries());
      expect(steam.ours().map((entry) => entry.string('AppName')), ['AnyPS5']);
      expect(File(steam.artPath(3816483209, SteamArt.hero)).existsSync(), isFalse);
      expect(File(steam.artPath(4185666005, SteamArt.hero)).existsSync(), isTrue);
    });

    test('removing twice, or with none of ours, writes nothing', () {
      existing('deck_shortcuts.vdf');
      expect(steam.remove().appIds, isEmpty);
      expect(File(steam.backupFile).existsSync(), isFalse, reason: 'a file without ours is not written');
      steam.put(entries());
      expect(steam.remove().appIds, [4185666005]);
      final modified = File(steam.shortcutsFile).lastModifiedSync();
      expect(steam.remove().appIds, isEmpty);
      expect(File(steam.shortcutsFile).lastModifiedSync(), modified);
      expect(File(steam.shortcutsFile).readAsBytesSync(), fixture('deck_shortcuts.vdf'));
    });

    test('ours sitting before others are taken out and the rest renumbered, their bodies intact', () {
      existing('empty_shortcuts.vdf');
      steam.put(entries());
      // Steam added a shortcut after ours while it ran.
      final file = ShortcutsFile.decode(File(steam.shortcutsFile).readAsBytesSync());
      final list = BinaryVdf.decode(fixture('deck_shortcuts.vdf')).root.map('shortcuts')!;
      final withLutris = BinaryVdf.decode(file.encode());
      withLutris.root.map('shortcuts')!.add(list.entries.last.renamed('1'));
      File(steam.shortcutsFile).writeAsBytesSync(BinaryVdf.encode(withLutris));
      steam.remove();
      final left = BinaryVdf.decode(File(steam.shortcutsFile).readAsBytesSync()).root.map('shortcuts')!;
      expect(left.entries.map((entry) => entry.name), ['0']);
      expect(BinaryVdf.encodeEntry(left.entries.single.renamed('2')), BinaryVdf.encodeEntry(list.entries.last));
    });

    test('a shortcut tagged AnyPS5 by hand, without --steam, is never taken for ours', () {
      final file = ShortcutsFile.empty();
      final mine = const SteamShortcut(
        appName: 'AnyPS5 (mine)',
        exe: '"/opt/anyps5"',
        startDir: '"/opt"',
        launchOptions: '--trace',
      ).toVdf();
      expect(ShortcutsFile.isOurs(mine), isFalse);
      file.putOurs([SteamPlan.launcher(program)]);
      expect(file.ours, hasLength(1));
    });

    test('the file is backed up before each write, and made when Steam has none yet', () {
      steam.put(entries());
      expect(File(steam.backupFile).existsSync(), isFalse);
      expect(steam.ours(), hasLength(1));
      final first = File(steam.shortcutsFile).readAsBytesSync();
      steam.put(entries(games: true));
      expect(File(steam.backupFile).readAsBytesSync(), first);
      expect(File('${steam.shortcutsFile}.anyps5-new').existsSync(), isFalse);
    });

    test('other shortcuts\' pictures stay', () {
      existing('deck_shortcuts.vdf');
      final foreign = File(p.join(steam.gridFolder, '3000000000p.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([7]);
      steam.put(entries());
      steam.remove();
      expect(foreign.existsSync(), isTrue);
      expect(Directory(steam.gridFolder).listSync(), hasLength(1));
    });

    test('the program is the AppImage when the launcher runs from one', () {
      expect(
        SteamPlan.program(resolvedExecutable: '/tmp/.mount_AnyPS5x/usr/bin/anyps5_desktop'),
        '/tmp/.mount_AnyPS5x/usr/bin/anyps5_desktop',
      );
      expect(
        SteamPlan.program(
          resolvedExecutable: '/tmp/.mount_AnyPS5x/usr/bin/anyps5_desktop',
          environment: {'APPIMAGE': program},
        ),
        program,
      );
      expect(SteamPlan.launchOptions(play: 'PPSA12544'), '--steam --play PPSA12544');
    });
  });

  group('finding Steam', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('home'));
    tearDown(() => home.deleteSync(recursive: true));

    Directory make(String path) => Directory(p.join(home.path, path))..createSync(recursive: true);

    test('Linux: ~/.steam/steam pointing at ~/.local/share/Steam counts once; Flatpak beside it', () async {
      make('.local/share/Steam/userdata/52079950/config');
      make('.steam');
      Link(p.join(home.path, '.steam', 'steam')).createSync(p.join(home.path, '.local', 'share', 'Steam'));
      Link(p.join(home.path, '.steam', 'root')).createSync(p.join(home.path, '.local', 'share', 'Steam'));
      make('.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata/1');
      final found = await SteamLocator.find(system: HostSystem.linux, environment: {'HOME': home.path});
      final real = home.resolveSymbolicLinksSync();
      expect(found.map((install) => install.root), [
        p.join(real, '.local', 'share', 'Steam'),
        p.join(real, '.var', 'app', 'com.valvesoftware.Steam', '.local', 'share', 'Steam'),
      ]);
      expect(found.map((install) => install.flatpak), [false, true]);
    });

    test('Linux: none without a userdata folder', () async {
      make('.local/share/Steam');
      expect(await SteamLocator.find(system: HostSystem.linux, environment: {'HOME': home.path}), isEmpty);
    });

    test('Windows: the registry\'s SteamPath first, then Program Files (x86)', () async {
      final registry = make('Games/Steam/userdata/7');
      final x86 = make('x86/Steam/userdata/8');
      final found = await SteamLocator.find(
        system: HostSystem.windows,
        environment: {'ProgramFiles(x86)': p.join(home.path, 'x86'), 'ProgramFiles': p.join(home.path, 'none')},
        registry: () async => registry.parent.parent.path,
      );
      expect(found.map((install) => p.basename(p.dirname(install.root))), ['Games', 'x86']);
      expect(x86.existsSync(), isTrue);
      expect(
        SteamLocator.parseRegQuery(
          '\r\nHKEY_CURRENT_USER\\Software\\Valve\\Steam\r\n    SteamPath    REG_SZ    c:/program files (x86)/steam\r\n\r\n',
          'SteamPath',
        ),
        r'c:\program files (x86)\steam',
      );
    });

    test('accounts: the one signed in last first, names from loginusers.vdf', () {
      final root = make('Steam');
      for (final id in ['0', '52079950', '22202', '99']) {
        make('Steam/userdata/$id/config');
      }
      make('Steam/config');
      File(p.join(root.path, 'config', 'loginusers.vdf')).writeAsStringSync('''
"users"
{
	"76561197960287930"
	{
		"AccountName"		"gaben"
		"PersonaName"		"Gabe"
		"MostRecent"		"0"
		"Timestamp"		"1600000000"
	}
	"76561198012345678"
	{
		"AccountName"		"siler"
		"PersonaName"		"Siler"
		"MostRecent"		"1"
		"Timestamp"		"1500000000"
	}
}
''');
      final users = SteamInstall(root.path).users();
      expect(SteamUser.accountIdOf(BigInt.parse('76561198012345678')), 52079950);
      expect(users.map((user) => user.id), ['52079950', '22202', '99']);
      expect(users.map((user) => user.label), ['Siler', 'Gabe', '99']);
      expect(users.first.mostRecent, isTrue);
    });
  });

  group('Steam running', () {
    late Directory proc;
    setUp(() => proc = Directory.systemTemp.createTempSync('proc'));
    tearDown(() => proc.deleteSync(recursive: true));

    void process(int pid, String name) => File(p.join(proc.path, '$pid', 'comm'))
      ..createSync(recursive: true)
      ..writeAsStringSync('$name\n');

    test('Linux reads the process names; quitting asks Steam and waits until it is gone', () async {
      process(1, 'systemd');
      process(4242, 'steamwebhelper');
      final started = <List<String>>[];
      final control = SteamControl(
        SteamInstall('/home/deck/.local/share/Steam'),
        system: HostSystem.linux,
        procRoot: proc.path,
        start: (executable, arguments) async {
          started.add([executable, ...arguments]);
          if (executable == 'steam') throw const ProcessException('steam', [], 'not found');
          Directory(p.join(proc.path, '4243')).deleteSync(recursive: true);
        },
      );
      expect(await control.running(), isFalse);
      process(4243, 'steam');
      expect(await control.running(), isTrue);
      expect(await control.shutdown(poll: const Duration(milliseconds: 5)), isTrue);
      expect(started, [
        ['steam', '-shutdown'],
        ['/home/deck/.local/share/Steam/steam.sh', '-shutdown'],
      ]);
      expect(await control.running(), isFalse);
    });

    test('a Steam that will not quit is said', () async {
      process(4243, 'steam');
      final control = SteamControl(
        SteamInstall('/s', flatpak: true),
        system: HostSystem.linux,
        procRoot: proc.path,
        start: (executable, arguments) async {},
      );
      expect(control.shutdownCommands.first, ['flatpak', 'run', 'com.valvesoftware.Steam', '-shutdown']);
      expect(
        await control.shutdown(timeout: const Duration(milliseconds: 30), poll: const Duration(milliseconds: 5)),
        isFalse,
      );
    });

    test('Windows asks tasklist', () async {
      var output = 'INFO: No tasks are running which match the specified criteria.';
      final control = SteamControl(
        SteamInstall(r'C:\Program Files (x86)\Steam'),
        system: HostSystem.windows,
        run: (executable, arguments) async => ProcessResult(1, 0, output, ''),
      );
      expect(await control.running(), isFalse);
      output = 'steam.exe                    11236 Console                    1    112,340 K';
      expect(await control.running(), isTrue);
      expect(control.shutdownCommands.first.last, '-shutdown');
    });
  });

  group('started from Steam', () {
    test('the flag or Steam\'s variables say so; gamescope is Game Mode', () {
      expect(SteamLaunch.detect(const [], const {}).fromSteam, isFalse);
      expect(SteamLaunch.detect(const ['--steam'], const {}).fromSteam, isTrue);
      final deck = SteamLaunch.detect(const [], const {
        'SteamGameId': '17977298603487526912',
        'XDG_CURRENT_DESKTOP': 'gamescope',
        'SDL_GAMECONTROLLER_IGNORE_DEVICES': '0x28de/0x1205,0x054c/0x0ce6, 0x045e/0x0b13',
      });
      expect(deck.fromSteam, isTrue);
      expect(deck.gameMode, isTrue);
      expect(deck.gameId, '17977298603487526912');
      expect(deck.ignoredPads, {(0x28DE, 0x1205), (0x054C, 0x0CE6), (0x045E, 0x0B13)});
    });

    test('physical pads Steam Input took over are skipped, its virtual pad never', () {
      final launch = SteamLaunch.detect(
        const ['--steam'],
        const {'SDL_GAMECONTROLLER_IGNORE_DEVICES': '0x054c/0x0ce6'},
      );
      expect(launch.skipPhysicalPad(0x054C, 0x0CE6), isTrue);
      expect(launch.skipPhysicalPad(0x28DE, 0x11FF), isFalse);
      expect(launch.skipPhysicalPad(0x045E, 0x0B13), isFalse);
      // Not from Steam: nothing is skipped even if the variable is about.
      final outside = SteamLaunch.detect(const [], const {'SDL_GAMECONTROLLER_IGNORE_DEVICES': '0x054c/0x0ce6'});
      expect(outside.skipPhysicalPad(0x054C, 0x0CE6), isFalse);
      final only = SteamLaunch.detect(
        const ['--steam'],
        const {'SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT': '0x28de/0x11ff'},
      );
      expect(only.skipPhysicalPad(0x054C, 0x0CE6), isTrue);
    });
  });
}
