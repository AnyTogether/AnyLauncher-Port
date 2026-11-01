import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/deep_link.dart';
import 'package:anyps5_desktop/core/desktop/url_scheme.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/link_relay.dart';
import 'package:anyps5_desktop/core/shared_settings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('anyps5:// links', () {
    // The macOS launcher's DeepLinkTests, case for case.
    test('a game link selects it and a play link plays it', () {
      expect(DeepLink.parse('anyps5://game/PPSA15065'), const ShowGameLink('PPSA15065'));
      expect(DeepLink.parse('anyps5://play/PPSA12544'), const PlayLink('PPSA12544'));
      expect(DeepLink.parse('ANYPS5://GAME/ppsa15065/'), const ShowGameLink('PPSA15065'));
    });

    test('the library and settings open', () {
      expect(DeepLink.parse('anyps5://library'), const LibraryLink());
      expect(DeepLink.parse('anyps5://settings'), const SettingsLink());
    });

    test('other links are not ours', () {
      expect(DeepLink.parse('https://example.com/game/PPSA15065'), isNull);
      expect(DeepLink.parse('anyps5://game/'), isNull);
      expect(DeepLink.parse('anyps5://game/../../etc'), isNull);
      expect(DeepLink.parse('anyps5://delete/PPSA15065'), isNull);
      expect(DeepLink.parse('anyps5:'), isNull);
    });

    test('a link is written the way it is read', () {
      expect(const ShowGameLink('PPSA15065').url, 'anyps5://game/PPSA15065');
      expect(DeepLink.parse(const PlayLink('CUSA00001').url), const PlayLink('CUSA00001'));
    });

    test('the system hands the link over as an argument, among others', () {
      expect(DeepLink.inArguments(['--fullscreen', 'anyps5://play/PPSA01001']), const PlayLink('PPSA01001'));
      expect(DeepLink.inArguments(['--play', 'PPSA01001']), isNull);
      expect(DeepLink.inArguments(['anyps5://nothing', 'ANYPS5://library']), const LibraryLink());
    });
  });

  group('link relay', () {
    late Directory temp;
    setUp(() => temp = temporaryFolder('relay'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('a second launcher hands its link to the open one', () async {
      final file = LinkRelay.fileIn(temp.path);
      final relay = (await LinkRelay.listen(file))!;
      final received = <String>[];
      final sub = relay.links.listen(received.add);
      expect(await LinkRelay.send(file, 'anyps5://game/PPSA01001'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, ['anyps5://game/PPSA01001']);
      await sub.cancel();
      await relay.close();
      expect(File(file).existsSync(), isFalse, reason: 'the address goes with the launcher');
    });

    test('without an open launcher nothing takes it, and the launcher opens the link itself', () async {
      final file = LinkRelay.fileIn(temp.path);
      expect(await LinkRelay.send(file, 'anyps5://library'), isFalse);
      // An address left by a launcher that crashed: nobody listens there.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      File(file).writeAsStringSync(jsonEncode({'port': port, 'secret': 'x'}));
      expect(await LinkRelay.send(file, 'anyps5://library'), isFalse);
    });

    test('a connection without the secret is refused', () async {
      final file = LinkRelay.fileIn(temp.path);
      final relay = (await LinkRelay.listen(file))!;
      final received = <String>[];
      final sub = relay.links.listen(received.add);
      final json = jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
      File(file).writeAsStringSync(jsonEncode({'port': json['port'], 'secret': 'not it'}));
      expect(await LinkRelay.send(file, 'anyps5://library', timeout: const Duration(milliseconds: 500)), isFalse);
      expect(received, isEmpty);
      await sub.cancel();
      await relay.close();
    });
  });

  group('registering the scheme', () {
    test('Windows: the protocol for this user, opening the launcher with the link', () async {
      final calls = <List<String>>[];
      final wrote = await UrlScheme.register(
        windows: true,
        resolvedExecutable: r'C:\Users\u\AppData\Local\Programs\AnyPS5 Desktop\anyps5_desktop.exe',
        environment: const {},
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return (arguments.first == 'query' ? 1 : 0, '');
        },
      );
      expect(wrote, isTrue);
      expect(calls.first.take(2), ['reg', 'query']);
      expect(
        calls.skip(1).every((call) => call[1] == 'add' && call[2].startsWith(r'HKCU\Software\Classes\anyps5')),
        isTrue,
      );
      expect(calls.last, [
        'reg',
        'add',
        r'HKCU\Software\Classes\anyps5\shell\open\command',
        '/ve',
        '/d',
        r'"C:\Users\u\AppData\Local\Programs\AnyPS5 Desktop\anyps5_desktop.exe" "%1"',
        '/f',
      ]);
      expect(
        calls,
        contains(equals(['reg', 'add', r'HKCU\Software\Classes\anyps5', '/v', 'URL Protocol', '/d', '', '/f'])),
      );
    });

    test('Windows: nothing is written when the protocol already opens this launcher', () async {
      const exe = r'C:\AnyPS5\anyps5_desktop.exe';
      final calls = <List<String>>[];
      final wrote = await UrlScheme.register(
        windows: true,
        resolvedExecutable: exe,
        environment: const {},
        run: (executable, arguments) async {
          calls.add(arguments);
          return (0, '    (Default)    REG_SZ    "C:\\AnyPS5\\anyps5_desktop.exe" "%1"\r\n');
        },
      );
      expect(wrote, isFalse);
      expect(calls, hasLength(1));
    });

    test('Linux: a hidden entry for x-scheme-handler/anyps5, the AppImage named where there is one', () async {
      final temp = temporaryFolder('scheme');
      addTearDown(() => temp.deleteSync(recursive: true));
      final calls = <List<String>>[];
      Future<(int, String)> run(String executable, List<String> arguments) async {
        calls.add([executable, ...arguments]);
        return (0, '');
      }

      final env = {'HOME': temp.path, 'APPIMAGE': '/home/u/Apps/AnyPS5 Desktop.AppImage'};
      expect(
        await UrlScheme.register(
          windows: false,
          resolvedExecutable: '/tmp/.mount_x/anyps5_desktop',
          environment: env,
          run: run,
        ),
        isTrue,
      );
      final entry = File(p.join(temp.path, '.local', 'share', 'applications', UrlScheme.desktopFile))
          .readAsStringSync();
      expect(entry, contains('MimeType=x-scheme-handler/anyps5;'));
      expect(entry, contains('Exec="/home/u/Apps/AnyPS5 Desktop.AppImage" %u'));
      expect(entry, contains('NoDisplay=true'));
      expect(calls.first, ['xdg-mime', 'default', UrlScheme.desktopFile, 'x-scheme-handler/anyps5']);
      // The same launcher again: nothing to write.
      calls.clear();
      expect(
        await UrlScheme.register(
          windows: false,
          resolvedExecutable: '/tmp/.mount_y/anyps5_desktop',
          environment: env,
          run: run,
        ),
        isFalse,
      );
      expect(calls, isEmpty);
    });

    test('Linux: the .deb registers through its own entry', () async {
      final temp = temporaryFolder('scheme');
      addTearDown(() => temp.deleteSync(recursive: true));
      final wrote = await UrlScheme.register(
        windows: false,
        resolvedExecutable: '/opt/anyps5-desktop/anyps5_desktop',
        environment: {'HOME': temp.path},
        run: (_, _) async => (0, ''),
      );
      expect(wrote, isFalse);
      expect(Directory(p.join(temp.path, '.local')).existsSync(), isFalse);
    });

    test('an Exec path with quotes and dollars is escaped as the spec says', () {
      expect(UrlScheme.linuxEntry(r'/home/u/my "$games"/anyps5'), contains(r'Exec="/home/u/my \"\$games\"/anyps5" %u'));
    });
  });

  group('settings files', () {
    const settings = GameSettings(
      fullscreen: true,
      overlay: OverlayCorner.topRight,
      frameGeneration: true,
      upscaler: Upscaler.fsr1,
      fsrSharpness: 0.5,
      controls: {
        'cross': ['KEY:J'],
      },
    );

    test('the file has the macOS launcher\'s keys, sorted as it sorts them', () {
      const shared = SharedSettings(titleId: 'PPSA01001', game: 'Orbit Runner', settings: settings);
      final text = shared.encode();
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json.keys.toList(), ['format', 'game', 'settings', 'titleID', 'version']);
      expect(json['format'], 'anyps5-settings');
      expect(json['version'], 1);
      final inner = json['settings'] as Map<String, dynamic>;
      expect(inner.keys.toList(), [...inner.keys]..sort());
      expect(inner['frameGeneration'], isTrue);
      expect(inner['fullscreen'], isTrue);
      expect(inner['settingsVersion'], GameSettings.version);
      // Read back, the same settings.
      final back = SharedSettings.decode(text);
      expect(back.settings, settings);
      expect(back.titleId, 'PPSA01001');
      expect(back.game, 'Orbit Runner');
    });

    test('a file the macOS launcher wrote imports, its Mac-only keys left out', () {
      // As Swift's JSONEncoder writes it (prettyPrinted, sortedKeys): " : " between key and value.
      const mac = '''
{
  "format" : "anyps5-settings",
  "game" : "Neon Alley",
  "settings" : {
    "engine" : "arm",
    "frameGeneration" : true,
    "language" : 19,
    "overlay" : "bottomLeft",
    "settingsVersion" : 2,
    "upscaler" : "fsr1",
    "vsync" : false,
    "windowSize" : 60
  },
  "titleID" : "PPSA02002",
  "version" : 1
}''';
      final shared = SharedSettings.decode(mac);
      expect(shared.titleId, 'PPSA02002');
      expect(shared.settings.frameGeneration, isTrue);
      expect(shared.settings.language, 19);
      expect(shared.settings.overlay, OverlayCorner.bottomLeft);
      expect(shared.settings.ownVsync, isFalse);
      expect(shared.settings.ownWindowSize, 60);
      expect(shared.settings.upscaler, Upscaler.fsr1);
    });

    test('anything else is refused', () {
      for (final text in ['not json', '[]', '{"format":"other"}', '{"format":"anyps5-settings","titleID":"X"}']) {
        expect(() => SharedSettings.decode(text), throwsA(isA<SharedSettingsRefused>()), reason: text);
      }
    });
  });
}
