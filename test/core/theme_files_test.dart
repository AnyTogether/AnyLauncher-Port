import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/file_types.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/link_relay.dart';
import 'package:anyps5_desktop/core/looping_video.dart';
import 'package:anyps5_desktop/core/opened_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Opening a `.anyps5theme`: the file type registered for the launcher, a second launcher handing
/// the file to the running one, and the looping background video's frames.
void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('theme-files'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('the file type', () {
    test('Windows: the user\'s classes name the launcher, once', () async {
      final calls = <List<String>>[];
      var registered = '';
      final type = ThemeFileType(
        system: HostSystem.windows,
        executable: r'C:\Apps\AnyPS5 Desktop\anyps5_desktop.exe',
        environment: const {},
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.first == 'query') return (ok: registered.isNotEmpty, out: registered);
          if (arguments.contains(r'HKCU\Software\Classes\AnyPS5.Theme\shell\open\command')) {
            registered = arguments[arguments.indexOf('/d') + 1];
          }
          return (ok: true, out: '');
        },
      );
      expect(await type.register(), isTrue);
      expect(registered, r'"C:\Apps\AnyPS5 Desktop\anyps5_desktop.exe" "%1"');
      expect(
        calls.where((call) => call[1] == 'add').map((call) => call[2]),
        containsAll([r'HKCU\Software\Classes\.anyps5theme', r'HKCU\Software\Classes\AnyPS5.Theme']),
      );
      calls.clear();
      expect(await type.register(), isFalse, reason: 'already the launcher\'s');
      expect(calls.where((call) => call[1] == 'add'), isEmpty);
    });

    test('Linux: a MIME package and a hidden desktop entry in the user\'s data folder', () async {
      final calls = <String>[];
      final data = p.join(temp.path, 'share');
      ThemeFileType type(String executable) => ThemeFileType(
        system: HostSystem.linux,
        executable: executable,
        environment: {'XDG_DATA_HOME': data, 'HOME': temp.path},
        run: (executable, arguments) async {
          calls.add('$executable ${arguments.join(' ')}');
          return (ok: true, out: '');
        },
      );
      expect(await type('/home/me/Apps/AnyPS5 Desktop.AppImage').register(), isTrue);
      final entry = File(p.join(data, 'applications', ThemeFileType.desktopEntry)).readAsStringSync();
      expect(entry, contains('Exec="/home/me/Apps/AnyPS5 Desktop.AppImage" %f'));
      expect(entry, contains('MimeType=application/x-anyps5theme;'));
      expect(entry, contains('NoDisplay=true'));
      expect(
        File(p.join(data, 'mime', 'packages', 'anyps5-desktop.xml')).readAsStringSync(),
        ThemeFileType.mimePackage,
      );
      expect(calls, contains('xdg-mime default ${ThemeFileType.desktopEntry} application/x-anyps5theme'));
      calls.clear();
      expect(await type('/home/me/Apps/AnyPS5 Desktop.AppImage').register(), isFalse);
      expect(calls, isEmpty);
      // The .deb registers its own.
      expect(await type('/opt/anyps5-desktop/anyps5_desktop').register(), isFalse);
    });

    test('the packages register the same type the launcher does', () {
      expect(File('packaging/linux/anyps5-desktop-mime.xml').readAsStringSync(), ThemeFileType.mimePackage);
      expect(
        File('packaging/linux/anyps5-desktop.desktop').readAsStringSync(),
        matches(RegExp(r'^MimeType=.*application/x-anyps5theme;', multiLine: true)),
      );
      final installer = File('packaging/windows/AnyPS5-Desktop.iss').readAsStringSync();
      expect(installer, contains(r'Software\Classes\.anyps5theme'));
      expect(installer, contains(r'Software\Classes\AnyPS5.Theme\shell\open\command'));
      expect(installer, contains('ChangesAssociations=yes'));
    });
  });

  group('the files the launcher is opened with', () {
    test('paths and file URIs, not options or a title ID', () {
      final theme = File(p.join(temp.path, 'My Theme.anyps5theme'))..writeAsStringSync('x');
      final found = OpenedFiles.of([
        '--fullscreen',
        '--play',
        theme.path,
        theme.uri.toString(),
        p.join(temp.path, 'missing.anyps5theme'),
      ]);
      expect(found, [theme.path]);
    });

    test('a launcher already open is handed a theme file over the link relay', () async {
      final file = LinkRelay.fileIn(temp.path);
      final relay = (await LinkRelay.listen(file))!;
      final got = relay.links.first;
      expect(await LinkRelay.send(file, '/a/Ember.anyps5theme'), isTrue);
      expect(await got, '/a/Ember.anyps5theme');
      await relay.close();
    });
  });

  group('the background video', () {
    test('ffmpeg loops the file at its own pace, silent, filling 960 by 540', () {
      final video = LoopingVideo(ffmpeg: 'ffmpeg', file: '/v/clip.mp4');
      final arguments = video.arguments;
      expect(arguments.sublist(arguments.indexOf('-stream_loop'), arguments.indexOf('-stream_loop') + 2), [
        '-stream_loop',
        '-1',
      ]);
      expect(arguments, containsAll(['-re', '-an', '-sn', 'rgba', 'rawvideo', 'pipe:1']));
      expect(
        arguments[arguments.indexOf('-vf') + 1],
        'scale=960:540:force_original_aspect_ratio=increase,crop=960:540,fps=30',
      );
      expect(arguments[arguments.indexOf('-i') + 1], '/v/clip.mp4');
      expect(video.frameBytes, 960 * 540 * 4);
    });

    test('its output, in pieces of any size, is cut into whole frames', () {
      final chunker = FrameChunker(4);
      expect(chunker.add([1, 2, 3]), isEmpty);
      expect(chunker.add([4, 5, 6, 7, 8, 9]), [
        Uint8List.fromList([1, 2, 3, 4]),
        Uint8List.fromList([5, 6, 7, 8]),
      ]);
      expect(chunker.add([10, 11, 12]), [
        Uint8List.fromList([9, 10, 11, 12]),
      ]);
    });

    test('a missing ffmpeg is a video that does not start', () async {
      final video = LoopingVideo(
        ffmpeg: '/nowhere/ffmpeg',
        file: '/v/clip.mp4',
        start: (_, _) async => throw const ProcessException('/nowhere/ffmpeg', []),
      );
      expect(await video.start((_) {}), isFalse);
      expect(video.running, isFalse);
    });
  });
}
