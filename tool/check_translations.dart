// Checks the language files in assets/l10n (TRANSLATING.md): dart run tool/check_translations.dart
//
// Every file other than en.json has to be a JSON object of texts with a "@meta" name and console
// language, no key en.json lacks and the same placeholders as English in each text. A text not
// translated yet is fine: the launcher shows the English one, and the check counts it.
import 'dart:convert';
import 'dart:io';

/// The reserved key of a file's name and console language (T.meta in lib/ui/strings.dart).
const meta = '@meta';

/// The console languages the engine knows (ConsoleLanguage in lib/core/game_settings.dart).
const consoleLanguages = 22;

/// What the check found in one language file.
class LanguageReport {
  LanguageReport(this.code, this.problems, this.translated, this.total);

  final String code;
  final List<String> problems;
  final int translated;
  final int total;

  double get coverage => total == 0 ? 100 : translated * 100 / total;
}

/// A text's placeholders as T.format fills them: (argument number, kind) for each %@ and %d,
/// numbered in order, and each %1$@ by its own number; %% is a percent sign, not one.
Set<(int, String)> placeholders(String text) {
  final found = <(int, String)>{};
  var next = 0;
  for (var index = 0; index < text.length; index++) {
    final positional = RegExp(r'%(\d)\$([@d])').matchAsPrefix(text, index);
    if (positional != null) {
      found.add((int.parse(positional.group(1)!), positional.group(2)!));
      index += positional.group(0)!.length - 1;
      continue;
    }
    if (text[index] == '%' && index + 1 < text.length) {
      final kind = text[index + 1];
      if (kind == '%') {
        index++;
      } else if (kind == '@' || kind == 'd') {
        found.add((++next, kind));
        index++;
      }
    }
  }
  return found;
}

String _shown(Set<(int, String)> found) => found.isEmpty
    ? 'none'
    : [for (final (number, kind) in found.toList()..sort((a, b) => a.$1 - b.$1)) '#$number %$kind'].join(', ');

/// Checks the file [source] of language [code] against the English texts.
LanguageReport checkLanguage(String code, String source, Map<String, String> english) {
  final problems = <String>[];
  Object? json;
  try {
    json = jsonDecode(source);
  } on FormatException catch (error) {
    return LanguageReport(
      code,
      ['$code.json is not valid JSON: ${error.message} (at character ${error.offset})'],
      0,
      english.length,
    );
  }
  if (json is! Map<String, Object?>) {
    return LanguageReport(code, ['$code.json has to be one JSON object: { "key": "text", ... }'], 0, english.length);
  }
  final about = json[meta];
  if (about is! Map<String, Object?>) {
    problems.add('$code.json has no "$meta": { "name": "...", "consoleLanguage": ... }');
  } else {
    final name = about['name'];
    if (name is! String || name.trim().isEmpty) {
      problems.add('$code.json: "$meta" needs "name", the language\'s own name');
    }
    final console = about['consoleLanguage'];
    if (console is! int || console < 0 || console >= consoleLanguages) {
      problems.add('$code.json: "$meta" needs "consoleLanguage", a number from 0 to ${consoleLanguages - 1}');
    }
  }
  var translated = 0;
  for (final MapEntry(:key, :value) in json.entries) {
    if (key == meta) continue;
    final englishText = english[key];
    if (englishText == null) {
      problems.add('$code.json: "$key" is not a key of en.json (a typo, or a key English no longer has)');
      continue;
    }
    if (value is! String) {
      problems.add('$code.json: "$key" has to be a text in quotes');
      continue;
    }
    translated++;
    final want = placeholders(englishText);
    final have = placeholders(value);
    if (want.length != have.length || !want.containsAll(have)) {
      problems.add('$code.json: "$key" has the placeholders ${_shown(have)}, English has ${_shown(want)}');
    }
  }
  return LanguageReport(code, problems, translated, english.length);
}

/// Checks every language file in [folder], writing one line per language to [out]; 0 when they
/// all pass, 1 when one has a problem. With [annotate] the problems are GitHub Actions errors
/// too, shown on the file in the pull request.
int checkFolder(Directory folder, StringSink out, {bool annotate = false}) {
  final englishFile = File('${folder.path}/en.json');
  final Map<String, String> english;
  try {
    final json = jsonDecode(englishFile.readAsStringSync()) as Map<String, Object?>;
    english = {
      for (final MapEntry(:key, :value) in json.entries)
        if (key != meta) key: value! as String,
    };
  } on Object catch (error) {
    out.writeln('en.json cannot be read: $error');
    return 1;
  }
  out.writeln('en: ${english.length} texts');
  var failed = false;
  final files = folder.listSync().whereType<File>().where((file) => file.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final code = file.uri.pathSegments.last.replaceAll('.json', '');
    if (code == 'en') continue;
    final report = checkLanguage(code, file.readAsStringSync(), english);
    final missing = report.total - report.translated;
    out.writeln(
      '$code: ${report.coverage.toStringAsFixed(1)} % translated (${report.translated} of ${report.total}'
      '${missing > 0 ? ', $missing shown in English' : ''})',
    );
    for (final problem in report.problems) {
      out.writeln(annotate ? '::error file=${folder.path}/$code.json::$problem' : '  error: $problem');
    }
    failed |= report.problems.isNotEmpty;
  }
  return failed ? 1 : 0;
}

void main(List<String> arguments) {
  exitCode = checkFolder(
    Directory(arguments.isEmpty ? 'assets/l10n' : arguments.single),
    stdout,
    annotate: Platform.environment['GITHUB_ACTIONS'] == 'true',
  );
}
