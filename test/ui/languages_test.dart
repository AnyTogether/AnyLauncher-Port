import 'dart:convert';
import 'dart:io';

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

  const english =
      '{"@meta": {"name": "English", "consoleLanguage": 1}, "language": "Language", '
      '"gamesFound": "%d games found", "back": "Back"}';
  const german =
      '{"@meta": {"name": "Deutsch", "consoleLanguage": 4}, "language": "Sprache", '
      '"gamesFound": "%d Spiele gefunden"}';

  tearDown(() async {
    T.language = Language.english;
    await T.load();
  });

  test('the files the launcher ships are its languages: English, then Türkçe', () async {
    await T.load();
    expect([for (final language in T.languages) language.code], ['en', 'tr']);
    expect([for (final language in T.languages) language.displayName], ['English', 'Türkçe']);
    expect([for (final language in T.languages) language.consoleLanguage], [1, 19]);
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
        'assets/l10n/fr.json': '{"@meta": {"name": "Français", ',
        'assets/l10n/it.json': '["not", "an", "object"]',
        'assets/l10n/nl.json': '{"language": "Taal", "back": 7}',
      }),
    );
    // Without its name and number a language is listed by its code and starts games in English.
    expect([for (final language in T.languages) language.code], ['en', 'nl']);
    final dutch = Language.byCode('nl');
    expect(dutch.displayName, 'nl');
    expect(dutch.consoleLanguage, 1);
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
    File('${folder.path}/tr.json')
        .writeAsStringSync('{"@meta": {"name": "Türkçe", "consoleLanguage": 19}, "back": "Dön"}');
    File('${folder.path}/en.json').writeAsStringSync('{"@meta": ');
    File('${folder.path}/notes.txt').writeAsStringSync('not a language');
    await T.load(tryOut: folder);
    expect([for (final language in T.languages) language.code], ['en', 'de', 'tr']);
    T.language = Language.byCode('tr');
    expect(T.text('back'), 'Dön');
    expect(T.text('gamesFound'), '%d games found');
    // The broken English file there leaves the built-in one in use.
    T.language = Language.english;
    expect(T.text('back'), 'Back');

    await T.load(tryOut: Directory('${folder.path}/missing'));
    expect([for (final language in T.languages) language.code], ['en', 'tr']);
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
}
