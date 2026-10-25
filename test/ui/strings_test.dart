import 'dart:io';

import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/strings_family.dart';
import 'package:anyps5_desktop/ui/strings_fonts.dart';
import 'package:anyps5_desktop/ui/strings_table.dart';
import 'package:anyps5_desktop/ui/strings_together.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => T.language = Language.english);

  test('every text the interface asks for exists in both languages', () {
    final keys = <String>{};
    final pattern = RegExp(r"""T\.(?:text|format)\(\s*'([A-Za-z0-9]+)'""");
    final inSwitch = RegExp(r"""=> '([a-z][A-Za-z0-9]+)'""");
    for (final file in Directory('lib/ui').listSync().whereType<File>()) {
      final source = file.readAsStringSync();
      keys.addAll(pattern.allMatches(source).map((match) => match.group(1)!));
      // Keys chosen in a switch and passed to T.text afterwards.
      if (source.contains('T.text(switch')) keys.addAll(inSwitch.allMatches(source).map((match) => match.group(1)!));
    }
    expect(keys.length, greaterThan(80));
    final missing = <String>[];
    for (final key in keys) {
      for (final language in Language.values) {
        T.language = language;
        if (T.text(key) == key) missing.add('$key (${language.code})');
      }
    }
    expect(missing, isEmpty);
  });

  test('the Mac is not named where the PC is meant', () {
    for (final language in Language.values) {
      T.language = language;
      for (final key in ['welcomeSubtitle', 'startingText', 'stepRelink', 'aboutText', 'showInFinder', 'themesOnMac']) {
        expect(T.text(key), isNot(contains('Mac')), reason: '$key in ${language.code}');
        expect(T.text(key), isNot(contains('Finder')), reason: '$key in ${language.code}');
      }
    }
  });

  test('format fills %@ and %d in order and keeps %%', () {
    T.language = Language.english;
    expect(T.format('gamesFound', [4]), '4 games found');
    expect(T.format('lastBackup', ['today']), 'Last backup: today');
    T.language = Language.turkish;
    expect(T.format('gamesFound', [4]), '4 oyun bulundu');
    expect(T.format('updateDownloading', [42]), 'İndiriliyor… %42');
  });

  test('the family texts cover the same keys in both languages', () {
    expect(familyEnglish.keys.toSet(), familyTurkish.keys.toSet());
  });

  test('the font and hidden trophy texts cover the same keys in both languages', () {
    expect(fontsEnglish.keys.toSet(), fontsTurkish.keys.toSet());
    T.language = Language.turkish;
    expect(T.format('fontsCjkDownloading', [42]), 'İniyor… %42');
    expect(T.text('fontsBuiltIn'), 'Yerleşik');
    T.language = Language.english;
    expect(T.format('fontsCjkDownloading', [42]), 'Downloading… 42%');
  });

  test('the tables cover the same keys', () {
    expect(englishTable.keys.toSet(), turkishTable.keys.toSet());
  });

  test('the AnyTogether tables cover the same keys, with the PC named where the Mac was', () {
    expect(togetherEnglish.keys.toSet(), togetherTurkish.keys.toSet());
    for (final text in [...togetherEnglish.values, ...togetherTurkish.values]) {
      expect(text, isNot(contains('Mac')));
      expect(text, isNot(contains('⌥')));
    }
  });

  test('positional placeholders take the argument they name', () {
    T.language = Language.english;
    expect(T.format('gameJoined', ['Utku', 'Orbit Runner']), 'Starting Orbit Runner with Utku');
    T.language = Language.turkish;
    expect(T.format('gameJoined', ['Utku', 'Orbit Runner']), 'Utku ile Orbit Runner başlıyor');
  });
}
