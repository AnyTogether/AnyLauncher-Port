import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// An asset bundle of the given files and the manifest Flutter writes for them, so a language
/// file can be dropped in the way a translator adds one to assets/l10n.
class _Bundle extends CachingAssetBundle {
  _Bundle(this.files, {this.manifest = true});

  final Map<String, String> files;
  final bool manifest;

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin' && manifest) {
      return const StandardMessageCodec().encodeMessage({
        for (final path in files.keys)
          path: [
            {'asset': path},
          ],
      })!;
    }
    final text = files[key];
    if (text == null) throw FlutterError('No asset $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// The launcher's languages come from the files in assets/l10n: a new file is a new language in
/// Settings, a missing text is the English one, and a broken file is left out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The files as Weblate keeps them: every value a text, the language's own name one of them.
  const english =
      '{"languageName": "English", "language": "Language", '
      '"gamesFound": "%d games found", "back": "Back"}';
  const german =
      '{"languageName": "Deutsch", "language": "Sprache", '
      '"gamesFound": "%d Spiele gefunden"}';

  tearDown(() async {
    T.language = Language.english;
    await T.load();
  });

  test('the files the launcher ships are its languages: English, then the others by their own names', () async {
    await T.load();
    expect(
      [for (final language in T.languages) language.code],
      ['en', 'id', 'de', 'es', 'fr', 'pt', 'tr', 'ru', 'ur', 'ar', 'bho', 'hi', 'bn', 'ja'],
    );
    expect(T.languages.first.displayName, 'English');
    final names = {for (final language in T.languages) language.code: language.displayName};
    expect(names['de'], 'Deutsch');
    expect(names['es'], 'Español');
    expect(names['fr'], 'Français');
    expect(names['pt'], 'Português');
    expect(names['ja'], '日本語');
    // No letter of a name was lost to a question mark when a file was saved.
    expect(names.values.where((name) => name.contains('?')), isEmpty);
    expect(Language.byCode('tr').consoleLanguage, 19);
    expect(Language.byCode('tr').displayName, 'Türkçe');
    expect(Language.byCode('xx'), Language.english);
    expect(Language.byCode(null), Language.english);
  });

  test('a new file in assets/l10n is a new language, listed by its own name', () async {
    await T.load(
      bundle: _Bundle({
        'assets/l10n/en.json': english,
        'assets/l10n/de.json': german,
        'assets/fonts/Figtree-OFL.txt': 'not a language',
      }),
    );
    expect([for (final language in T.languages) language.code], ['en', 'de']);
    final deutsch = Language.byCode('de');
    expect(deutsch.displayName, 'Deutsch');
    expect(deutsch.consoleLanguage, 4);
    T.language = deutsch;
    expect(T.text('language'), 'Sprache');
    expect(T.format('gamesFound', [3]), '3 Spiele gefunden');
  });

  test('a text the language does not have yet is the English one', () async {
    await T.load(bundle: _Bundle({'assets/l10n/en.json': english, 'assets/l10n/de.json': german}));
    T.language = Language.byCode('de');
    expect(T.text('back'), 'Back');
    expect(T.text('noSuchKey'), 'noSuchKey');
  });

  test('a broken or half-filled file never stops the launcher', () async {
    await T.load(
      bundle: _Bundle({
        'assets/l10n/en.json': english,
        'assets/l10n/fr.json': '{"languageName": "Français", ',
        'assets/l10n/it.json': '["not", "an", "object"]',
        'assets/l10n/nl.json': '{"language": "Taal", "back": 7}',
        'assets/l10n/xx.json': '{"back": "Bak"}',
      }),
    );
    // Without its name a language is listed by its code; its console language comes from the
    // code, English for a code the console does not know.
    expect([for (final language in T.languages) language.code], ['en', 'nl', 'xx']);
    final dutch = Language.byCode('nl');
    expect(dutch.displayName, 'nl');
    expect(dutch.consoleLanguage, 6);
    expect(Language.byCode('xx').consoleLanguage, 1);
    T.language = dutch;
    expect(T.text('language'), 'Taal');
    expect(T.text('back'), 'Back');

    // No manifest and no files at all: English, with each text its key.
    await T.load(bundle: _Bundle({}, manifest: false));
    expect(T.languages, [Language.english]);
    expect(T.text('language'), 'language');
  });

  test('a file in the Languages folder is tried in a released launcher, before the built-in one', () async {
    final folder = Directory.systemTemp.createTempSync('anyps5_languages');
    addTearDown(() => folder.deleteSync(recursive: true));
    File('${folder.path}/de.json').writeAsStringSync(german);
    File('${folder.path}/tr.json').writeAsStringSync('{"languageName": "Türkçe", "back": "Dön"}');
    File('${folder.path}/en.json').writeAsStringSync('{"languageName": ');
    File('${folder.path}/notes.txt').writeAsStringSync('not a language');
    final builtIn = _Bundle({
      'assets/l10n/en.json': english,
      'assets/l10n/tr.json': '{"languageName": "Türkçe", "back": "Geri"}',
    });
    await T.load(bundle: builtIn, tryOut: folder);
    expect([for (final language in T.languages) language.code], ['en', 'de', 'tr']);
    T.language = Language.byCode('tr');
    expect(T.text('back'), 'Dön');
    expect(T.text('gamesFound'), '%d games found');
    // The broken English file there leaves the built-in one in use.
    T.language = Language.english;
    expect(T.text('back'), 'Back');

    await T.load(bundle: builtIn, tryOut: Directory('${folder.path}/missing'));
    expect([for (final language in T.languages) language.code], ['en', 'tr']);
    T.language = Language.byCode('tr');
    expect(T.text('back'), 'Geri');
  });

  test('the console language comes from the file\'s code, not from the file', () async {
    await T.load(
      bundle: _Bundle({
        'assets/l10n/en.json': english,
        'assets/l10n/de.json': german,
        'assets/l10n/pt-BR.json': '{"languageName": "Português (Brasil)"}',
        'assets/l10n/pt.json': '{"languageName": "Português"}',
        'assets/l10n/zh-Hant.json': '{"languageName": "繁體中文"}',
        'assets/l10n/es_419.json': '{"languageName": "Español (Latinoamérica)"}',
      }),
    );
    expect(Language.byCode('de').consoleLanguage, 4);
    expect(Language.byCode('pt-BR').consoleLanguage, 17);
    expect(Language.byCode('pt').consoleLanguage, 7);
    expect(Language.byCode('zh-Hant').consoleLanguage, 10);
    expect(Language.byCode('es_419').consoleLanguage, 20);
    expect(Language.english.consoleLanguage, 1);
    expect(ConsoleLanguage.forLocale('tr'), 19);
    expect(ConsoleLanguage.forLocale('en-GB'), 18);
    expect(ConsoleLanguage.forLocale('de-AT'), 4);
    expect(ConsoleLanguage.forLocale('zh'), 11);
    expect(ConsoleLanguage.forLocale('nb'), 15);
    expect(ConsoleLanguage.forLocale('eo'), isNull);
  });

  test('a file in the old format still works: its name and console language from "@meta"', () async {
    final folder = Directory.systemTemp.createTempSync('anyps5_languages');
    addTearDown(() => folder.deleteSync(recursive: true));
    File('${folder.path}/de.json')
        .writeAsStringSync('{"@meta": {"name": "Deutsch (alt)", "consoleLanguage": 4}, "back": "Zurück"}');
    // A code the console does not know keeps the number its file gave.
    File('${folder.path}/x-pirate.json')
        .writeAsStringSync('{"@meta": {"name": "Pirate", "consoleLanguage": 18}, "back": "Avast"}');
    await T.load(tryOut: folder);
    final deutsch = Language.byCode('de');
    expect(deutsch.displayName, 'Deutsch (alt)');
    expect(deutsch.consoleLanguage, 4);
    expect(Language.byCode('x-pirate').displayName, 'Pirate');
    expect(Language.byCode('x-pirate').consoleLanguage, 18);
    T.language = deutsch;
    expect(T.text('back'), 'Zurück');
    // "@meta" is never a text.
    expect(T.text('@meta'), '@meta');
  });

  test('numbers follow the language: its thousands separator and decimal mark', () async {
    await T.load(
      bundle: _Bundle({
        'assets/l10n/en.json':
            '{"languageName": "English", "numberGroupSeparator": ",", "numberDecimalSeparator": "."}',
        'assets/l10n/fr.json':
            '{"languageName": "Français", "numberGroupSeparator": "\u202f", "numberDecimalSeparator": ","}',
        'assets/l10n/de.json': german,
      }),
    );
    expect(T.number(1234567), '1,234,567');
    expect(T.number(-1200), '-1,200');
    expect(T.number(999), '999');
    expect(T.decimal(12.345, 1), '12.3');
    T.language = Language.byCode('fr');
    expect(T.number(1234567), '1\u202f234\u202f567');
    expect(T.decimal(12.345, 1), '12,3');
    // A language without them uses English's.
    T.language = Language.byCode('de');
    expect(T.number(1234), '1,234');
    expect(T.decimal(0.5, 1), '0.5');
  });

  test('Settings lists a new language and switching to it is kept', () async {
    await T.load(bundle: _Bundle({'assets/l10n/en.json': english, 'assets/l10n/de.json': german}));
    final fixture = makeFixture();
    addTearDown(fixture.dispose);
    final model = fixture.model;
    model.open(Layer.settings);
    final row = model.panelCategories().expand((category) => category.rows).firstWhere((row) => row.id == 'language');
    final choice = row.kind as ChoiceRow;
    expect(choice.options, ['English', 'Deutsch']);
    expect(choice.selected, 0);
    choice.set(1);
    expect(T.language.code, 'de');
    expect(model.preferences.language, 'de');
  });

  testWidgets('another language shows everywhere at once, the hint bar too', (tester) async {
    await tester.runAsync(T.load);
    final fixture = makeFixture();
    addTearDown(fixture.dispose);
    final model = fixture.model;
    await pumpLauncher(tester, model);
    expect(find.text('Move'), findsWidgets);
    expect(find.text('Select'), findsWidgets);
    model.open(Layer.settings);
    final row = model.panelCategories().expand((category) => category.rows).firstWhere((row) => row.id == 'language');
    (row.kind as ChoiceRow).set(T.languages.indexOf(Language.byCode('tr')));
    model.closeOverlay();
    await settle(tester);
    // The home screen's hint bar is a const widget: it never rebuilt with its parent before.
    expect(find.text('Move'), findsNothing);
    expect(find.text('Select'), findsNothing);
    expect(T.text('hintMove'), isNot('Move'));
    expect(find.text(T.text('hintMove')), findsWidgets);
  });
}
