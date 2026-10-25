import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/steam/binary_vdf.dart';
import 'package:anyps5_desktop/core/steam/steam_shortcuts.dart';
import 'package:anyps5_desktop/core/steam/text_vdf.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The fixtures are shortcuts.vdf files laid out as a 2024-2026 Steam client writes them: on
/// Windows a Steam-made shortcut (random appid), Heroic with launch options and two tags, a
/// hidden game with Turkish letters in its name and path; on a Steam Deck EmulationStation-DE,
/// a Flatpak app with FlatpakAppID and sortas, Lutris with three tags; and an empty list.
Uint8List fixture(String name) => File(p.join('test', 'core', 'steam', 'fixtures', name)).readAsBytesSync();

void main() {
  group('binary VDF', () {
    for (final name in ['windows_shortcuts.vdf', 'deck_shortcuts.vdf', 'empty_shortcuts.vdf']) {
      test('$name reads and writes back to the same bytes', () {
        final bytes = fixture(name);
        expect(BinaryVdf.encode(BinaryVdf.decode(bytes)), bytes);
      });
    }

    test('fields read as Steam wrote them', () {
      final list = BinaryVdf.decode(fixture('windows_shortcuts.vdf')).root.map('shortcuts')!;
      expect(list.entries.map((entry) => entry.name), ['0', '1', '2']);
      final notepad = list.map('0')!;
      expect(notepad.int32('appid'), -1408730215);
      expect(notepad.string('AppName'), 'Notepad++');
      expect(notepad.string('Exe'), r'"C:\Program Files\Notepad++\notepad++.exe"');
      expect(notepad.int32('LastPlayTime'), 1729000000);
      final heroic = list.map('1')!;
      expect(heroic.string('LaunchOptions'), '--no-gui heroic://launch/legendary/Fortnite');
      expect(heroic.strings('tags'), ['Epic', 'favorite']);
      final turkish = list.map('2')!;
      expect(turkish.string('appname'), 'Pokémon Ünite Ç', reason: 'keys are found whatever their case');
      expect(turkish.int32('IsHidden'), 1);
      expect(turkish.int32('AllowOverlay'), 0);
      final deck = BinaryVdf.decode(fixture('deck_shortcuts.vdf')).root.map('shortcuts')!;
      expect(deck.map('1')!.string('FlatpakAppID'), 'com.usebottles.bottles');
      expect(deck.map('1')!.string('sortas'), 'bottles');
      expect(deck.map('2')!.strings('tags'), ['Linux', 'Lutris', 'Tools']);
    });

    test('types shortcuts never use are kept to the byte as well', () {
      final builder = BytesBuilder()
        ..add([0x00, ...'root'.codeUnits, 0])
        ..add([0x03, ...'f'.codeUnits, 0, 0x00, 0x00, 0x80, 0x3F])
        ..add([0x04, ...'ptr'.codeUnits, 0, 1, 2, 3, 4])
        ..add([0x05, ...'w'.codeUnits, 0, 0x41, 0x00, 0x42, 0x00, 0x00, 0x00])
        ..add([0x06, ...'c'.codeUnits, 0, 9, 8, 7, 6])
        ..add([0x07, ...'u64'.codeUnits, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        ..add([0x0A, ...'i64'.codeUnits, 0, 8, 7, 6, 5, 4, 3, 2, 1])
        ..add([0x0B])
        ..add([0x08])
        ..add([0xAA, 0xBB]);
      final bytes = builder.takeBytes();
      final document = BinaryVdf.decode(bytes);
      expect(document.root.map('root')!.entries, hasLength(6));
      expect(document.trailing, [0xAA, 0xBB]);
      expect(BinaryVdf.encode(document), bytes);
    });

    test('a cut-off or unknown file is refused, never half read', () {
      final bytes = fixture('windows_shortcuts.vdf');
      expect(() => BinaryVdf.decode(Uint8List.sublistView(bytes, 0, bytes.length - 40)), throwsFormatException);
      expect(() => BinaryVdf.decode(Uint8List.fromList([0x09, 0x41, 0x00, 0x08])), throwsFormatException);
      expect(() => ShortcutsFile.decode(Uint8List.fromList([0x00, 0x78, 0x00, 0x08, 0x08])), throwsFormatException);
    });
  });

  group('text VDF', () {
    test('loginusers.vdf', () {
      final parsed = TextVdf.parse(r'''
"users"
{
	"76561198012345678"
	{
		"AccountName"		"siler"
		"PersonaName"		"Siler \"S\" Bey"
		"RememberPassword"		"1"
		"MostRecent"		"1"
		"Timestamp"		"1730000000"
	}
	// an older account
	"76561197960287930"
	{
		"AccountName"		"gaben"
		"mostrecent"		"0"
	}
}
''');
      final users = TextVdf.get(parsed, 'USERS')! as Map<String, Object>;
      expect(users.keys, ['76561198012345678', '76561197960287930']);
      final siler = users['76561198012345678']! as Map<String, Object>;
      expect(siler['PersonaName'], 'Siler "S" Bey');
      expect(TextVdf.get(users['76561197960287930']! as Map<String, Object>, 'MostRecent'), '0');
    });

    test('broken files are refused', () {
      expect(() => TextVdf.parse('"a" { "b" "c"'), throwsFormatException);
      expect(() => TextVdf.parse('"a" "b" }'), throwsFormatException);
      expect(() => TextVdf.parse('"a'), throwsFormatException);
    });
  });
}
