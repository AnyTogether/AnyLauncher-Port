import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'account.dart';

/// The Theme Hub, as the macOS launcher's ThemeHub and TogetherThemes: the shared place for
/// themes. AnyTogether serves the index at /api/v1/hub/themes.json; the folder in the AnyPS5-ARM
/// repository on GitHub stays as the fallback while a server has none. Signed in, a theme is
/// shared straight onto AnyTogether's Hub, a theme shared before going up as its new version.

/// A theme the Hub lists: its look in short, its file and its picture.
class HubTheme {
  const HubTheme({
    required this.id,
    required this.name,
    this.author = '',
    this.version = 1,
    this.style = 0,
    required this.deep,
    required this.middle,
    required this.bright,
    required this.accent,
    required this.package,
    this.preview,
  });

  /// An entry of a themes.json index, its addresses taken relative to [base]; null when it lacks
  /// what a theme needs.
  static HubTheme? fromIndex(Object? json, Uri base) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final package = json['package'];
    if (id is! String || name is! String || package is! String) return null;
    String colour(String key) => json[key] is String ? json[key] as String : '#000000';
    final preview = json['preview'];
    return HubTheme(
      id: id,
      name: name,
      author: json['author'] is String ? json['author'] as String : '',
      version: (json['version'] as num? ?? 1).toInt(),
      style: (json['style'] as num? ?? 0).toInt(),
      deep: colour('deep'),
      middle: colour('middle'),
      bright: colour('bright'),
      accent: colour('accent'),
      package: base.resolve(package),
      preview: preview is String ? base.resolve(preview) : null,
    );
  }

  final String id;
  final String name;
  final String author;
  final int version;
  final int style;
  final String deep;
  final String middle;
  final String bright;
  final String accent;

  /// The .anyps5theme file.
  final Uri package;
  final Uri? preview;

  /// Theme IDs on AnyTogether are UUIDs.
  static bool isId(String text) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(text);
}

/// What sharing a theme came to: its name on the Hub and the version it is there.
class SharedTheme {
  const SharedTheme({required this.id, required this.name, required this.version});

  final String id;
  final String name;
  final int version;
}

/// Reading the Hub, downloading a theme, and sharing one.
class ThemeHub {
  ThemeHub({HttpClient Function()? client}) : _client = client ?? HttpClient.new;

  final HttpClient Function() _client;

  /// The folder on GitHub the Hub started as.
  static final githubBase = Uri.parse('https://raw.githubusercontent.com/AnyTogether/AnyPS5-ARM/main/hub/');

  /// Where a theme is shared from when not signed in: a new issue on the repository.
  static final shareIssue = Uri.parse(
    'https://github.com/AnyTogether/AnyPS5-ARM/issues/new?labels=theme&title=Theme%3A%20',
  );

  /// The Hub on an AnyTogether server: the same index the GitHub folder has.
  static Uri onServer(Uri server) => server.resolve('/api/v1/hub/');

  /// The most a theme file may be, as the server takes it.
  static const maxBytes = 50 * 1024 * 1024;

  /// The themes of one index.
  static List<HubTheme> index(String text, Uri base) {
    final json = jsonDecode(text);
    final list = json is Map ? json['themes'] : null;
    return [for (final entry in list is List ? list : const []) ?HubTheme.fromIndex(entry, base)];
  }

  /// The first of [bases] that offers themes: AnyTogether's Hub, then the GitHub folder while
  /// the server has none (or cannot be reached). Throws only when none answered.
  Future<List<HubTheme>> themes(List<Uri> bases) async {
    Object? failure;
    var answered = false;
    for (final base in bases) {
      try {
        final found = index(utf8.decode(await _get(base.resolve('themes.json'))), base);
        answered = true;
        if (found.isNotEmpty) return found;
      } on Object catch (error) {
        failure = error;
      }
    }
    if (!answered && failure != null) throw failure;
    return const [];
  }

  /// One theme on AnyTogether's Hub by its ID (for an anyps5://theme link), read without an
  /// account: its name, version and file. Null when the server has no such theme.
  Future<HubTheme?> theme(Uri server, String id) async {
    if (!HubTheme.isId(id)) return null;
    final address = server.resolve('/api/v1/themes/$id');
    final List<int> bytes;
    try {
      bytes = await _get(address);
    } on HttpException catch (error) {
      if (error.message == '404') return null;
      rethrow;
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map) return null;
    final colours = json['colors'];
    final maker = json['maker'];
    return HubTheme.fromIndex({
      'id': json['id'],
      'name': json['name'],
      'author': maker is Map ? maker['displayName'] : null,
      'version': json['version'],
      'style': json['style'],
      if (colours is Map) ...colours,
      'package': json['download'],
      'preview': json['thumb'],
    }, address);
  }

  /// Downloads [theme]'s file into [folder]; its path.
  Future<String> download(HubTheme theme, String folder) async {
    final bytes = await _get(theme.package, limit: maxBytes);
    Directory(folder).createSync(recursive: true);
    final safe = theme.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final file = File('$folder${Platform.pathSeparator}${safe.isEmpty ? 'theme' : safe}.anyps5theme');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<List<int>> _get(Uri address, {int? limit}) async {
    final client = _client()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(address);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('${response.statusCode}', uri: address);
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        bytes.addAll(chunk);
        if (limit != null && bytes.length > limit) throw HttpException('too large', uri: address);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  /// multipart/form-data of files, as the server's upload takes them.
  static (List<int>, String) form(List<({String name, String filename, String type, List<int> data})> files) {
    final random = math.Random.secure();
    final boundary = 'anyps5-${List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join()}';
    final body = BytesBuilder(copy: false);
    void line(String text) => body.add(utf8.encode('$text\r\n'));
    for (final file in files) {
      line('--$boundary');
      line('Content-Disposition: form-data; name="${file.name}"; filename="${file.filename.replaceAll('"', '')}"');
      line('Content-Type: ${file.type}');
      line('');
      body.add(file.data);
      line('');
    }
    line('--$boundary--');
    return (body.takeBytes(), 'multipart/form-data; boundary=$boundary');
  }

  /// Shares a theme file on AnyTogether's Hub with a still of it (the server needs a picture
  /// when the theme has none of its own); a theme shared before from the same design goes up as
  /// its new version instead.
  static Future<SharedTheme> share(
    TogetherAccount account, {
    required List<int> theme,
    required String filename,
    List<int>? preview,
  }) async {
    final (body, type) = form([
      (name: 'theme', filename: filename, type: 'application/zip', data: theme),
      if (preview != null) (name: 'preview', filename: 'preview.png', type: 'image/png', data: preview),
    ]);
    Map<String, dynamic> answer;
    try {
      answer = await account.upload('POST', 'themes', body, type);
    } on TogetherProblem catch (problem) {
      final id = problem.extra['themeId'];
      if (problem.status != 409 || id is! String) rethrow;
      answer = await account.upload('POST', 'themes/${Uri.encodeComponent(id)}/versions', body, type);
    }
    return SharedTheme(
      id: answer['id'] as String? ?? '',
      name: answer['name'] as String? ?? '',
      version: (answer['version'] as num? ?? 1).toInt(),
    );
  }
}
