import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/game_settings.dart';

/// A launcher language: one file in assets/l10n named by its locale code (de.json is German,
/// pt-BR.json Brazilian Portuguese), its own name the text "languageName" and its console
/// language found from the code ([ConsoleLanguage.forLocale]).
@immutable
class Language {
  const Language(this.code, this.displayName, this.consoleLanguage);

  final String code;

  /// The language's name in itself, as Settings lists it.
  final String displayName;

  /// The console language a game starts in when its own setting follows the launcher.
  final int consoleLanguage;

  /// The language every other one falls back to, there even when en.json is not.
  static const english = Language('en', 'English', 1);

  /// The language of [code], English when there is no file for it.
  static Language byCode(String? code) =>
      T.languages.firstWhere((language) => language.code == code, orElse: () => english);

  @override
  bool operator ==(Object other) => other is Language && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

/// Every user-facing text, read from the language files in assets/l10n: English first, then
/// the others by name. A text a language does not have is the English one.
abstract final class T {
  static const folder = 'assets/l10n/';

  /// The key of a language's own name ("Deutsch"), translated like every other text.
  static const nameKey = 'languageName';

  /// Where a file had its name and console language before the files were made for Weblate:
  /// {"@meta": {"name": "Deutsch", "consoleLanguage": 4}}. A file in the Languages folder may still
  /// have it, so it is read, and never a text.
  static const legacyMeta = '@meta';

  static Language language = Language.english;
  static List<Language> languages = const [Language.english];
  static Map<String, Map<String, String>> _texts = const {};

  /// Finds the language files in [bundle]'s manifest and reads them, then the ones in [tryOut]
  /// (the Languages folder beside the settings, where a translator tries a file in a released
  /// launcher: one there comes before the built-in file of its code). A file that cannot be read
  /// or is not a JSON object is left out for the next one of its code; without en.json each text
  /// is its key.
  static Future<void> load({AssetBundle? bundle, Directory? tryOut}) async {
    final assets = bundle ?? rootBundle;
    final files = <String, List<(String, Future<String> Function())>>{};
    try {
      for (final path in (await AssetManifest.loadFromAssetBundle(assets)).listAssets()) {
        if (!path.startsWith(folder) || !path.endsWith('.json')) continue;
        final code = path.substring(folder.length, path.length - '.json'.length);
        if (code.isEmpty || code.contains('/')) continue;
        (files[code] ??= []).add((path, () => assets.loadString(path, cache: false)));
      }
    } on Object catch (error) {
      debugPrint('[anyps5-launcher] no asset manifest for the languages: $error');
    }
    try {
      for (final file in tryOut?.listSync().whereType<File>() ?? const <File>[]) {
        final name = file.uri.pathSegments.last;
        if (name.endsWith('.json') && name.length > '.json'.length) {
          (files[name.substring(0, name.length - '.json'.length)] ??= []).insert(0, (file.path, file.readAsString));
        }
      }
    } on FileSystemException {
      // No Languages folder: the built-in files only.
    }
    final texts = <String, Map<String, String>>{};
    final found = <Language>[];
    for (final MapEntry(key: code, value: candidates) in files.entries) {
      for (final (path, read) in candidates) {
        try {
          final json = jsonDecode(await read());
          if (json is! Map<String, Object?>) throw const FormatException('not a JSON object');
          final about = json[legacyMeta];
          final legacyName = about is Map<String, Object?> ? about['name'] : null;
          final legacyConsole = about is Map<String, Object?> ? about['consoleLanguage'] : null;
          final file = texts[code] = {
            for (final MapEntry(:key, :value) in json.entries)
              if (key != legacyMeta && value is String) key: value,
          };
          final name = file[nameKey] ?? legacyName;
          found.add(
            Language(
              code,
              name is String && name.trim().isNotEmpty ? name.trim() : code,
              ConsoleLanguage.forLocale(code) ??
                  (legacyConsole is int ? legacyConsole : Language.english.consoleLanguage),
            ),
          );
          break;
        } on Object catch (error) {
          debugPrint('[anyps5-launcher] the language file $path is left out: $error');
        }
      }
    }
    found.sort((a, b) {
      if (a.code == 'en' || b.code == 'en') return a.code == 'en' ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    if (found.isEmpty || found.first.code != 'en') found.insert(0, Language.english);
    _texts = texts;
    languages = List.unmodifiable(found);
    language = Language.byCode(language.code);
  }

  /// The text for [key] in the current language, English when the language has none.
  static String text(String key) => _texts[language.code]?[key] ?? _texts['en']?[key] ?? key;

  /// The languages whose i and ı are two letters: their capitals are İ and I.
  static const _dottedI = {'tr', 'az'};

  static bool get _dotted => _dottedI.contains(language.code.split(RegExp('[-_]')).first); // not a text

  /// [text] in capitals as the language writes them: "Oyun Kimliği" is "OYUN KİMLİĞİ" in
  /// Turkish, where Dart's toUpperCase (the same in every language) gives "OYUN KIMLIĞI". For a
  /// text a person reads, never for a game's ID, a key or a code.
  static String upper(String text) => (_dotted ? text.replaceAll('i', '\u0130') : text).toUpperCase();

  /// [text] in small letters as the language writes them: I is ı and İ is i in Turkish.
  static String lower(String text) =>
      (_dotted ? text.replaceAll('I', '\u0131').replaceAll('\u0130', 'i') : text).toLowerCase();

  /// The first letter of [name] in capitals, for an initial ("?" for no name).
  static String initial(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : upper(String.fromCharCode(trimmed.runes.first));
  }

  /// 1,234,567 or 1.234.567: [value]'s digits grouped by the language's thousands separator.
  static String number(int value) {
    final digits = value.abs().toString();
    final separator = _textOr('numberGroupSeparator', ',');
    final out = StringBuffer(value < 0 ? '-' : '');
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) out.write(separator);
      out.write(digits[index]);
    }
    return out.toString();
  }

  /// 85% or %85: a percentage as the language writes it (the text "percent").
  static String percent(Object value) => format('percent', [value]);

  /// [value] with [digits] decimals and the language's decimal mark: 12.3 or 12,3.
  static String decimal(double value, int digits) =>
      value.toStringAsFixed(digits).replaceAll('.', _textOr('numberDecimalSeparator', '.'));

  static String _textOr(String key, String fallback) => _texts[language.code]?[key] ?? _texts['en']?[key] ?? fallback;

  /// [text] with its %@ and %d placeholders filled in order (%1\$@ names its argument);
  /// %% is a percent sign.
  static String format(String key, List<Object> arguments) {
    final template = text(key);
    final out = StringBuffer();
    var next = 0;
    for (var index = 0; index < template.length; index++) {
      final char = template[index];
      final positional = RegExp(r'%(\d)\$([@d])').matchAsPrefix(template, index);
      if (positional != null) {
        final at = int.parse(positional.group(1)!) - 1;
        out.write(at >= 0 && at < arguments.length ? arguments[at] : '');
        index += positional.group(0)!.length - 1;
        continue;
      }
      if (char == '%' && index + 1 < template.length) {
        final kind = template[index + 1];
        if (kind == '%') {
          out.write('%');
          index++;
          continue;
        }
        if (kind == '@' || kind == 'd') {
          out.write(next < arguments.length ? arguments[next] : '');
          next++;
          index++;
          continue;
        }
      }
      out.write(char);
    }
    return out.toString();
  }
}
