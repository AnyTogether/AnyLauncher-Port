import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A launcher language: one file in assets/l10n named by its code (de.json is German), with its
/// name and console language in the file's "@meta".
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

  /// The reserved key of a file's name and console language; never a text.
  static const meta = '@meta';

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
          final about = json[meta];
          final name = about is Map<String, Object?> ? about['name'] : null;
          final console = about is Map<String, Object?> ? about['consoleLanguage'] : null;
          texts[code] = {
            for (final MapEntry(:key, :value) in json.entries)
              if (key != meta && value is String) key: value,
          };
          found.add(
            Language(
              code,
              name is String && name.trim().isNotEmpty ? name.trim() : code,
              console is int ? console : Language.english.consoleLanguage,
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
