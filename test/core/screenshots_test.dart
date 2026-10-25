import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/desktop/linux_desktop.dart';
import 'package:anyps5_desktop/core/desktop/windows_desktop.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  late Directory temp;
  setUp(() => temp = temporaryFolder('pictures'));
  tearDown(() => temp.deleteSync(recursive: true));

  Game game({String name = 'Hollow Knight: Silksong', String titleId = 'PPSA12544'}) => Game(
    folder: p.join(temp.path, 'dump'),
    titleId: titleId,
    name: name,
    names: {'en-US': name},
    defaultLanguage: 'en-US',
    version: '01.000',
    executable: ExecutableKind.container,
  );

  group('pictures', () {
    test('a game\'s folder is its name, made safe for Windows and Linux', () {
      expect(Screenshots.safeName('Hollow Knight: Silksong'), 'Hollow Knight Silksong');
      expect(Screenshots.safeName('A/B\\C*?<>|"'), 'A B C');
      expect(Screenshots.safeName('Ends with dots...'), 'Ends with dots');
      expect(Screenshots.safeName('CON', fallback: 'PPSA1'), 'PPSA1');
      expect(Screenshots.safeName('   ', fallback: 'PPSA1'), 'PPSA1');
    });

    test('a trophy picture is named after the game, the trophy and the moment', () {
      final path = Screenshots.trophyPath(temp.path, game(), '0/12', DateTime(2026, 10, 25, 9, 5, 7));
      expect(p.dirname(path), p.join(temp.path, 'Hollow Knight Silksong'));
      expect(p.basename(path), 'PPSA12544-trophy0_12-20261025-090507.png');
    });

    test('the gallery has F12 pictures and trophy pictures of the game, newest first, no one else\'s', () {
      final folder = Screenshots.folderFor(temp.path, game());
      Directory(folder).createSync(recursive: true);
      for (final name in ['PPSA12544-20261020-101010.png', 'PPSA99999-20261024-101010.png', 'notes.txt']) {
        File(p.join(temp.path, name)).writeAsStringSync('x');
      }
      File(p.join(folder, 'PPSA12544-trophy0_3-20261024-120000.png')).writeAsStringSync('x');
      File(p.join(folder, 'PPSA12544-trophy0_3-20261021-120000.png')).writeAsStringSync('x');
      final shots = Screenshots.list(temp.path, game());
      expect(shots.map(p.basename), [
        'PPSA12544-trophy0_3-20261024-120000.png',
        'PPSA12544-trophy0_3-20261021-120000.png',
        'PPSA12544-20261020-101010.png',
      ]);
      expect(Screenshots.trophyShots(shots), {'0/3': shots.first});
      expect(Screenshots.list(p.join(temp.path, 'none'), game()), isEmpty);
    });

    test('PNG: the header, the size and the pixels come back out', () {
      final pixels = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 8, 7, 255]);
      final png = PngEncoder.rgba(2, 2, pixels);
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final header = ByteData.sublistView(png, 16, 24);
      expect(header.getUint32(0), 2);
      expect(header.getUint32(4), 2);
      expect(png[25], 2, reason: 'RGB: an opaque capture keeps no alpha');
      // The IDAT chunk inflates to filter byte + RGB rows.
      final idat = _chunk(png, 'IDAT');
      expect(ZLibDecoder().convert(idat), [0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 255, 9, 8, 7]);
      expect(() => PngEncoder.rgba(3, 2, pixels), throwsArgumentError);
    });
  });

  group('desktop', () {
    test('cards go to the window premultiplied, as BGRA, faded by the opacity', () {
      final card = RgbaImage(1, 1, Uint8List.fromList([200, 100, 50, 128]));
      expect(card.premultipliedBgra(), [25, 50, 100, 128]);
      expect(card.premultipliedBgra(0.5), [12, 25, 50, 64]);
      expect(() => RgbaImage(2, 2, Uint8List(3)), throwsArgumentError);
    });

    test('a capture\'s BGRX rows, with padding at their ends, become opaque RGBA', () {
      final rows = Uint8List.fromList([1, 2, 3, 0, 99, 99, 4, 5, 6, 0, 99, 99]);
      final image = RgbaImage.fromBgra(1, 2, rows, stride: 6);
      expect(image.pixels, [3, 2, 1, 255, 6, 5, 4, 255]);
    });

    test('a card comes in within 200 ms, stays, goes, and is done', () {
      expect(cardPhase(Duration.zero).opacity, 0);
      expect(cardPhase(const Duration(milliseconds: 100)).opacity, closeTo(0.5, 0.01));
      expect(cardPhase(const Duration(milliseconds: 200)).opacity, 1);
      expect(cardPhase(const Duration(seconds: 3)).done, isFalse);
      expect(cardPhase(const Duration(milliseconds: 4930)).opacity, closeTo(0.5, 0.05));
      expect(cardPhase(const Duration(seconds: 6)).done, isTrue);
    });

    test('a card sits centred at the top of its screen, sliding down into place', () {
      final start = cardPosition(
        screenLeft: 1920,
        screenTop: 0,
        screenWidth: 1920,
        cardWidth: 560,
        margin: 18,
        slide: 22,
        t: 0,
      );
      final end = cardPosition(
        screenLeft: 1920,
        screenTop: 0,
        screenWidth: 1920,
        cardWidth: 560,
        margin: 18,
        slide: 22,
        t: 1,
      );
      expect(end, (x: 1920 + 680, y: 18));
      expect(start.y, 18 - 22);
    });

    test('a window size is a 16:9 picture in that share of the work area, plus the frame', () {
      expect(windowArea(workWidth: 1920, workHeight: 1040, percent: 50), (width: 924, height: 520));
      expect(windowArea(workWidth: 1920, workHeight: 1040, percent: 50, frameWidth: 16, frameHeight: 39), (
        width: 855 + 16,
        height: 481 + 39,
      ));
      expect(
        windowArea(workWidth: 1920, workHeight: 1040, percent: 10),
        windowArea(workWidth: 1920, workHeight: 1040, percent: 30),
      );
    });

    test('Wayland gets notifications, X11 the card, nothing without a display', () {
      expect(linuxSession({'XDG_SESSION_TYPE': 'wayland', 'DISPLAY': ':0'}), LinuxSession.wayland);
      expect(linuxSession({'WAYLAND_DISPLAY': 'wayland-0'}), LinuxSession.wayland);
      expect(linuxSession({'XDG_SESSION_TYPE': 'x11', 'DISPLAY': ':0'}), LinuxSession.x11);
      expect(linuxSession({}), LinuxSession.none);
    });
  });
}

List<int> _chunk(Uint8List png, String type) {
  var offset = 8;
  final data = ByteData.sublistView(png);
  while (offset < png.length) {
    final length = data.getUint32(offset);
    final name = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
    if (name == type) return png.sublist(offset + 8, offset + 8 + length);
    offset += 12 + length;
  }
  throw StateError('no $type');
}
