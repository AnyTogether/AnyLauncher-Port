import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_translations.dart';

/// The CI check of the language files: what stops a translation, and what is only counted.
void main() {
  const english = {'gamesFound': '%d games found', 'gameJoined': 'Starting %2\$@ with %1\$@', 'back': 'Back'};

  test('a text with other placeholders than the English one is a problem', () {
    final report = checkLanguage(
      'de',
      '{"@meta": {"name": "Deutsch", "consoleLanguage": 4}, '
          '"gamesFound": "%@ Spiele gefunden", "back": "Zurück"}',
      english,
    );
    expect(report.problems, hasLength(1));
    expect(report.problems.single, contains('gamesFound'));
  });

  test('placeholders may change places when they are numbered', () {
    final report = checkLanguage(
      'tr',
      '{"@meta": {"name": "Türkçe", "consoleLanguage": 19}, '
          r'"gameJoined": "%1$@ ile %2$@ başlıyor", "gamesFound": "%d oyun bulundu"}',
      english,
    );
    expect(report.problems, isEmpty);
  });

  test('a key English does not have is a problem', () {
    final report = checkLanguage(
      'de',
      '{"@meta": {"name": "Deutsch", "consoleLanguage": 4}, '
          '"bakc": "Zurück"}',
      english,
    );
    expect(report.problems, hasLength(1));
    expect(report.problems.single, contains('bakc'));
  });

  test('missing keys are only counted', () {
    final report = checkLanguage(
      'de',
      '{"@meta": {"name": "Deutsch", "consoleLanguage": 4}, '
          '"back": "Zurück"}',
      english,
    );
    expect(report.problems, isEmpty);
    expect(report.translated, 1);
    expect(report.total, 3);
    expect(report.coverage, closeTo(33.3, 0.1));
  });

  test('a file that is not JSON, or has no name and console language, is a problem', () {
    expect(checkLanguage('de', '{"back": "Zurück",}', english).problems, hasLength(1));
    expect(checkLanguage('de', '{"back": "Zurück"}', english).problems, isNotEmpty);
    expect(
      checkLanguage('de', '{"@meta": {"name": "Deutsch", "consoleLanguage": 99}, "back": "Zurück"}', english).problems,
      isNotEmpty,
    );
    expect(
      checkLanguage('de', '{"@meta": {"name": "Deutsch", "consoleLanguage": 4}, "back": 7}', english).problems,
      isNotEmpty,
    );
  });

  test('the files in assets/l10n pass', () {
    final out = StringBuffer();
    expect(checkFolder(Directory('assets/l10n'), out), 0, reason: out.toString());
    expect(out.toString(), contains('tr: 100.0 %'));
  });
}
