import 'dart:convert';

import 'online_wire.dart';

/// JSON answers to the game, as the Mac launcher writes them: keys sorted, compact.
abstract final class OnlineJson {
  static const contentType = WirePair('Content-Type', 'application/json');

  static WireWebReply reply(int status, Object? body) =>
      WireWebReply(status: status, headers: const [contentType], body: utf8.encode(encode(body)));

  /// The error shape the platform's web API answers with: {"error":{"code","message"}}.
  static WireWebReply problem(int status, String message) => reply(status, {
    'error': {'code': status, 'message': message},
  });

  static String encode(Object? value) => jsonEncode(_sorted(value));

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: _sorted(value[key])};
    }
    if (value is List) return [for (final item in value) _sorted(item)];
    return value;
  }

  /// A request body as a JSON object: {} for none, null when it is something else.
  static Map<String, dynamic>? object(List<int> body) {
    if (body.isEmpty) return {};
    try {
      final value = jsonDecode(utf8.decode(body));
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  /// "a=1&b=x%20y" → {a: 1, b: x y}.
  static Map<String, String> query(String text) {
    final fields = <String, String>{};
    for (final pair in text.split('&')) {
      if (pair.isEmpty) continue;
      final at = pair.indexOf('=');
      final name = _decode(at < 0 ? pair : pair.substring(0, at));
      if (name.isNotEmpty) fields[name] = at < 0 ? '' : _decode(pair.substring(at + 1));
    }
    return fields;
  }

  /// The path's segments (percent-decoded, empty ones dropped) and its query.
  static (List<String>, Map<String, String>) split(String path) {
    final at = path.indexOf('?');
    final bare = at < 0 ? path : path.substring(0, at);
    final query = at < 0 ? '' : path.substring(at + 1);
    return (
      [
        for (final part in bare.split('/'))
          if (part.isNotEmpty) _decode(part),
      ],
      OnlineJson.query(query),
    );
  }

  /// The path without its query, as counted for "not offered".
  static String bare(String path) {
    final at = path.indexOf('?');
    return at < 0 ? path : path.substring(0, at);
  }

  static String _decode(String text) {
    try {
      return Uri.decodeComponent(text);
    } on Object {
      return text;
    }
  }
}
