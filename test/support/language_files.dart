import 'dart:convert';
import 'dart:io';

/// The texts of assets/l10n/[code].json as the file has them, without its "@meta": what a
/// language really covers, where T.text would answer with the English text.
Map<String, String> languageFile(String code) {
  final json = jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map<String, Object?>;
  return {
    for (final MapEntry(:key, :value) in json.entries)
      if (key != '@meta') key: value! as String,
  };
}
