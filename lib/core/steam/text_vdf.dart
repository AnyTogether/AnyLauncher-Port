/// Steam's text KeyValues (config/loginusers.vdf, libraryfolders.vdf): quoted keys, a quoted
/// value or a braced block, `//` comments. Read only; keys keep their case, [TextVdf.get] ignores
/// it as Steam does.
abstract final class TextVdf {
  /// The top level as a map of keys to strings and maps. Throws [FormatException] on a file
  /// that is not KeyValues.
  static Map<String, Object> parse(String text) {
    final tokens = _tokens(text);
    var at = 0;
    Map<String, Object> block({required bool top}) {
      final out = <String, Object>{};
      while (at < tokens.length) {
        final token = tokens[at];
        if (token == _close) {
          if (top) throw const FormatException('text VDF: a } without its {');
          at++;
          return out;
        }
        if (token == _open) throw const FormatException('text VDF: a { without a key');
        at++;
        if (at >= tokens.length) throw const FormatException('text VDF: a key without a value');
        final next = tokens[at];
        if (next == _open) {
          at++;
          out[token as String] = block(top: false);
        } else if (next == _close) {
          throw const FormatException('text VDF: a key without a value');
        } else {
          at++;
          out[token as String] = next as String;
        }
      }
      if (!top) throw const FormatException('text VDF: a { without its }');
      return out;
    }

    return block(top: true);
  }

  /// The value under [key] in [map], ignoring case.
  static Object? get(Map<String, Object> map, String key) {
    final exact = map[key];
    if (exact != null) return exact;
    final wanted = key.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == wanted) return entry.value;
    }
    return null;
  }

  static const _open = Object();
  static const _close = Object();

  static List<Object> _tokens(String text) {
    final tokens = <Object>[];
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        i++;
      } else if (c == '/' && i + 1 < text.length && text[i + 1] == '/') {
        while (i < text.length && text[i] != '\n') {
          i++;
        }
      } else if (c == '{') {
        tokens.add(_open);
        i++;
      } else if (c == '}') {
        tokens.add(_close);
        i++;
      } else if (c == '"') {
        final out = StringBuffer();
        i++;
        while (i < text.length && text[i] != '"') {
          if (text[i] == r'\' && i + 1 < text.length) {
            final escaped = text[i + 1];
            out.write(switch (escaped) {
              'n' => '\n',
              't' => '\t',
              _ => escaped,
            });
            i += 2;
          } else {
            out.write(text[i++]);
          }
        }
        if (i >= text.length) throw const FormatException('text VDF: a text without its closing quote');
        i++;
        tokens.add(out.toString());
      } else {
        // An unquoted word, which older files have for some values.
        final start = i;
        while (i < text.length && !' \t\r\n{}"'.contains(text[i])) {
          i++;
        }
        tokens.add(text.substring(start, i));
      }
    }
    return tokens;
  }
}
