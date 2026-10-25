import 'dart:io';

import 'package:anyps5_desktop/core/system_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('font set types, decoded as SystemFont.cpp decodes them', () {
    test('the table is the engine\'s 120 types', () {
      expect(SystemFontSet.types, hasLength(120));
    });

    test('a plain set opens Latin only', () {
      expect(SystemFontSet.scripts(0x18070044), [FontScript.latin]);
      expect(SystemFontSet.scripts(0x18070043), [FontScript.latin]);
    });

    test('the Japanese region opens Japanese, the Chinese region Simplified Chinese', () {
      expect(SystemFontSet.scripts(0x18080444), [FontScript.japanese]);
      expect(SystemFontSet.scripts(0x180C8044), [FontScript.chinese]);
    });

    test('script bits add fallbacks after the set\'s own script, in the engine\'s order', () {
      // Scripts 0x24: Japanese, then Korean (0x20), behind Latin.
      expect(SystemFontSet.scripts(0x18072444), [FontScript.latin, FontScript.japanese, FontScript.korean]);
      // Scripts 0xA0: Chinese (0x80) then Korean; 0x88 is not all set, so Chinese comes from 0x80.
      expect(SystemFontSet.scripts(0x1807A044), [FontScript.latin, FontScript.chinese, FontScript.korean]);
      // Scripts 0xAC: 0x88 puts Chinese before Japanese.
      expect(SystemFontSet.scripts(0x1807AC44), [
        FontScript.latin,
        FontScript.chinese,
        FontScript.japanese,
        FontScript.korean,
      ]);
      expect(SystemFontSet.scripts(0x18078044), [FontScript.latin, FontScript.chinese]);
    });

    test('bit 0x80 of the low byte adds Arabic', () {
      expect(SystemFontSet.scripts(0x180700C4), [FontScript.latin, FontScript.arabic]);
      expect(SystemFontSet.scripts(0x1A0705C3), [FontScript.latin, FontScript.japanese, FontScript.arabic]);
    });

    test('Vietnamese, Thai, italic and typewriter sets', () {
      expect(SystemFontSet.scripts(0x18070054), [FontScript.vietnamese]);
      expect(SystemFontSet.scripts(0x18071054), [FontScript.thai, FontScript.vietnamese]);
      expect(SystemFontSet.scripts(0x18080454), [FontScript.vietnamese, FontScript.japanese]);
      expect(SystemFontSet.scripts(0x18170044), [FontScript.latinItalic]);
      expect(SystemFontSet.scripts(0x18370447), [FontScript.typewriter, FontScript.japanese]);
    });

    test('a type the console does not have opens nothing', () {
      expect(SystemFontSet.scripts(0x18070046), isEmpty);
      expect(SystemFontSet.scripts(0x18070044 | 0x80), [FontScript.latin, FontScript.arabic]);
      expect(SystemFontSet.scripts(0x18080444 | 0x80), [FontScript.japanese, FontScript.arabic]);
      expect(SystemFontSet.scripts(0x180C8044 | 0x100000), isEmpty);
    });

    test('every type in the table opens at least its own script', () {
      for (final type in SystemFontSet.types) {
        expect(SystemFontSet.scripts(type).first, SystemFontSet.primary(type));
      }
    });

    test('Noto stands in for every script; CJK shares the collections', () {
      for (final script in FontScript.values) {
        expect(script.consoleFiles, hasLength(4));
        expect(script.notoFiles, hasLength(4));
      }
      expect(FontScript.japanese.notoFiles[1], 'NotoSansCJK-Regular.ttc');
      expect(FontScript.korean.notoFiles, FontScript.chinese.notoFiles);
      expect(FontScript.vietnamese.notoFiles, FontScript.latin.notoFiles);
      expect(
        [
          for (final script in FontScript.values)
            if (script.isCjk) script,
        ],
        [FontScript.japanese, FontScript.chinese, FontScript.korean],
      );
    });
  });

  group('the log', () {
    const log = '''
--- 2026-10-25T10:00:00.000 PPSA01001-app
[libSceFont] sceFontOpenFontSet fontSetType=0x18070044 file=/fonts/NotoSans-Regular.ttf
[libSceFont] sceFontOpenFontSet fontSetType=0x18080444 file=(none)
[libSceFont] sceFontOpenFontSet fontSetType=0x18070044 file=/fonts/NotoSans-Regular.ttf
[libSceFont] sceFontOpenFontSet fontSetType=0x180c8044 file=(none)
something else fontSetType=0x1234 and fontSetType=0xZZ070044
''';

    test('gives the font sets a game opened', () {
      expect(SystemFontSet.opened(log), {0x18070044, 0x18080444, 0x180C8044});
    });

    test('gives the scripts they need', () {
      expect(SystemFontSet.scriptsIn(log), {FontScript.latin, FontScript.japanese, FontScript.chinese});
      expect(SystemFontSet.scriptsIn('no fonts at all'), isEmpty);
    });

    test('is read as it grows, from where this session began, a cut marker whole', () {
      final temp = Directory.systemTemp.createTempSync('fontlog');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'game.log'))
        ..writeAsStringSync('earlier session fontSetType=0x18080444 file=(none)\n');
      final scanner = FontLogScanner(file.path, offset: file.lengthSync());
      expect(scanner.scan(), isEmpty);
      file.writeAsStringSync('--- start\nsceFontOpenFontSet fontSetType=0x1807', mode: FileMode.append);
      expect(scanner.scan(), isEmpty);
      file.writeAsStringSync('0044 file=(none)\nfontSetType=0x180C8044 file=(none)\n', mode: FileMode.append);
      expect(scanner.scan(), {0x18070044, 0x180C8044});
      file.writeAsStringSync('fontSetType=0x18070044 file=(none)\n', mode: FileMode.append);
      expect(scanner.scan(), isEmpty, reason: 'seen before');
      expect(scanner.types, {0x18070044, 0x180C8044});
    });

    test('a missing log gives nothing', () {
      expect(FontLogScanner('/nowhere/at/all.log').scan(), isEmpty);
    });
  });

  group('the folders games get fonts from', () {
    late Directory temp;
    late String user;
    late String downloaded;
    late String builtIn;
    late String games;

    void write(String folder, String name, [String content = 'font']) {
      File(p.join(folder, name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    setUp(() {
      temp = Directory.systemTemp.createTempSync('fonts');
      user = p.join(temp.path, 'user');
      downloaded = p.join(temp.path, 'downloaded');
      builtIn = p.join(temp.path, 'builtin');
      games = p.join(temp.path, 'games');
      for (final name in [
        'NotoSans-Regular.ttf',
        'NotoSans-Bold.ttf',
        'NotoSansMono-Regular.ttf',
        'NotoSansThai-Regular.ttf',
        'NotoSansArabic-Regular.ttf',
        'OFL.txt',
      ]) {
        write(builtIn, name, 'builtin $name');
      }
      write(downloaded, 'NotoSansCJK-Regular.ttc', 'cjk');
      write(downloaded, 'LICENSE-NotoSansCJK.txt', 'licence');
      Directory(p.join(downloaded, '.download')).createSync();
      write(downloaded, 'NotoSansCJK-Bold.ttc.part', 'half');
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('without a folder of the user\'s, the built-in and downloaded fonts are given', () {
      final fonts = SystemFonts(downloaded: downloaded, builtIn: builtIn);
      expect(
        fonts.files().keys,
        unorderedEquals([
          'NotoSans-Regular.ttf',
          'NotoSans-Bold.ttf',
          'NotoSansMono-Regular.ttf',
          'NotoSansThai-Regular.ttf',
          'NotoSansArabic-Regular.ttf',
          'NotoSansCJK-Regular.ttc',
        ]),
        reason: 'no licence texts, parts or folders',
      );
      expect(fonts.pick(FontScript.latin), const FontPick('NotoSans-Regular.ttf', FontSource.builtIn));
      expect(fonts.pick(FontScript.korean), const FontPick('NotoSansCJK-Regular.ttc', FontSource.downloaded));
      expect(fonts.pick(FontScript.korean, weight: 3), isNull, reason: 'bold CJK is not downloaded');
      expect(fonts.pick(FontScript.latinItalic), isNull);
    });

    test('the user\'s files win by name, and the launcher\'s fill in what the folder lacks', () {
      write(user, 'NotoSans-Regular.ttf', 'mine');
      write(user, 'SST-Roman.otf', 'console');
      write(user, 'notes.txt', 'not a font');
      final fonts = SystemFonts(user: user, downloaded: downloaded, builtIn: builtIn);
      final files = fonts.files();
      expect(files['NotoSans-Regular.ttf'], (FontSource.user, p.join(user, 'NotoSans-Regular.ttf')));
      expect(files['NotoSans-Bold.ttf']!.$1, FontSource.builtIn);
      expect(files.containsKey('notes.txt'), isFalse);
      // The engine takes a console file over Noto: so does the pick.
      final latin = fonts.pick(FontScript.latin)!;
      expect(latin, const FontPick('SST-Roman.otf', FontSource.user));
      expect(latin.isConsole, isTrue);
      expect(latin.family, 'SST');
      expect(fonts.pick(FontScript.thai), const FontPick('NotoSansThai-Regular.ttf', FontSource.builtIn));
    });

    test('font families for people', () {
      expect(const FontPick('NotoSansCJK-Regular.ttc', FontSource.downloaded).family, 'Noto Sans CJK');
      expect(const FontPick('NotoSansMono-Regular.ttf', FontSource.builtIn).family, 'Noto Sans Mono');
      expect(const FontPick('NotoSans-Regular.ttf', FontSource.builtIn).family, 'Noto Sans');
      expect(const FontPick('NotoSansArabic-Regular.ttf', FontSource.builtIn).family, 'Noto Sans Arabic');
      expect(const FontPick('SSTTypewriter-Roman.otf', FontSource.user).family, 'SST Typewriter');
      expect(const FontPick('SSTJpPro-Regular.otf', FontSource.user).family, 'SST Jp Pro');
      expect(const FontPick('DFHEI5-SONY.ttf', FontSource.user).family, 'DFHEI5');
    });

    test('are put together in one folder, kept up to date and cleared of what went', () {
      write(user, 'SST-Roman.otf', 'console');
      var fonts = SystemFonts(user: user, downloaded: downloaded, builtIn: builtIn);
      expect(fonts.assemble(games), 7);
      String read(String name) => File(p.join(games, name)).readAsStringSync();
      expect(read('SST-Roman.otf'), 'console');
      expect(read('NotoSans-Regular.ttf'), 'builtin NotoSans-Regular.ttf');
      expect(read('NotoSansCJK-Regular.ttc'), 'cjk');
      expect(File(p.join(games, 'OFL.txt')).existsSync(), isFalse);
      if (!Platform.isWindows) {
        expect(FileSystemEntity.isLinkSync(p.join(games, 'NotoSans-Regular.ttf')), isTrue);
      }

      // The user's folder gains a file the launcher has too: theirs takes its place.
      write(user, 'NotoSans-Regular.ttf', 'mine');
      expect(fonts.assemble(games), 7);
      expect(read('NotoSans-Regular.ttf'), 'mine');

      // The downloaded fonts are removed and the user's folder is no longer used.
      File(p.join(downloaded, 'NotoSansCJK-Regular.ttc')).deleteSync();
      fonts = SystemFonts(downloaded: downloaded, builtIn: builtIn);
      expect(fonts.assemble(games), 5);
      expect(read('NotoSans-Regular.ttf'), 'builtin NotoSans-Regular.ttf');
      expect(File(p.join(games, 'NotoSansCJK-Regular.ttc')).existsSync(), isFalse);
      expect(File(p.join(games, 'SST-Roman.otf')).existsSync(), isFalse);
      expect(SystemFonts.fontsIn(games), hasLength(5));
    });

    test('with no fonts anywhere no folder is left', () {
      Directory(games).createSync();
      expect(SystemFonts(user: p.join(temp.path, 'none')).assemble(games), 0);
      expect(Directory(games).existsSync(), isFalse);
    });

    test('the launcher\'s own fonts are found beside its executable or where the environment says', () {
      final exe = p.join(temp.path, 'app', 'anyps5_desktop');
      final assets = p.join(temp.path, 'app', 'data', 'flutter_assets', SystemFonts.assetFolder);
      expect(SystemFonts.locateBuiltIn(environment: const {}, executable: exe), isNull);
      write(assets, 'NotoSans-Regular.ttf');
      expect(SystemFonts.locateBuiltIn(environment: const {}, executable: exe), assets);
      expect(SystemFonts.locateBuiltIn(environment: {'ANYPS5_LAUNCHER_FONTS': builtIn}, executable: exe), builtIn);
    });

    test('the fonts that come with the launcher are the ones the engine looks for, with their licence', () {
      final shipped = Directory(SystemFonts.assetFolder);
      final names = SystemFonts.fontsIn(shipped.path);
      final expected = {
        for (final script in FontScript.values)
          if (!script.isCjk) ...script.notoFiles,
      };
      expect(names.toSet(), expected);
      expect(names, hasLength(20));
      expect(File(p.join(shipped.path, 'OFL.txt')).readAsStringSync(), contains('SIL OPEN FONT LICENSE Version 1.1'));
      expect(File(p.join(shipped.path, 'SOURCES.txt')).existsSync(), isTrue);
    });
  });
}
