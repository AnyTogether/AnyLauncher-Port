import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/theme_hub.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// The Theme Hub as the macOS launcher reads and shares it: AnyTogether's index first, the GitHub
/// folder while the server has none, a theme's file downloaded, and sharing onto the Hub (a
/// theme shared before going up as its new version).
void main() {
  Map<String, Object?> entry(String id, String name) => {
    'id': id,
    'name': name,
    'author': 'Ana',
    'version': 2,
    'style': 1,
    'deep': '#101820',
    'middle': '#203040',
    'bright': '#4080ff',
    'accent': '#ff8040',
    'package': 'themes/$id/download',
    'preview': 'https://cdn.example.invalid/$id.webp',
  };

  test('an index: addresses taken relative to its folder, entries without a file left out', () {
    final base = Uri.parse('https://anytogether.net/api/v1/hub/');
    final themes = ThemeHub.index(
      jsonEncode({
        'themes': [
          entry('a1', 'Night Drive'),
          {'id': 'b', 'name': 'No file'},
        ],
      }),
      base,
    );
    expect(themes, hasLength(1));
    expect(themes.single.package.toString(), 'https://anytogether.net/api/v1/hub/themes/a1/download');
    expect(themes.single.preview.toString(), 'https://cdn.example.invalid/a1.webp');
    expect(themes.single.style, 1);
    expect(ThemeHub.onServer(Uri.parse('https://anytogether.net')).toString(), 'https://anytogether.net/api/v1/hub/');
    expect(HubTheme.isId('0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b'), isTrue);
    expect(HubTheme.isId('../etc'), isFalse);
  });

  group('over HTTP', () {
    late HttpServer server;
    late Directory temp;
    final served = <String, (int, List<int>)>{};

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('hub');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final answer = served[request.uri.path] ?? (404, utf8.encode('{}'));
        request.response.statusCode = answer.$1;
        request.response.add(answer.$2);
        await request.response.close();
      });
    });

    tearDown(() async {
      served.clear();
      await server.close(force: true);
      temp.deleteSync(recursive: true);
    });

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('the server\'s Hub first; the GitHub folder while it has none; a failure only when none answers', () async {
      served['/server/themes.json'] = (200, utf8.encode(jsonEncode({'themes': <Object>[]})));
      served['/github/themes.json'] = (
        200,
        utf8.encode(
          jsonEncode({
            'themes': [entry('g1', 'From GitHub')],
          }),
        ),
      );
      final hub = ThemeHub();
      final found = await hub.themes([at('/server/'), at('/github/')]);
      expect(found.single.name, 'From GitHub');

      served['/server/themes.json'] = (
        200,
        utf8.encode(
          jsonEncode({
            'themes': [entry('s1', 'On AnyTogether')],
          }),
        ),
      );
      expect((await hub.themes([at('/server/'), at('/github/')])).single.id, 's1');

      await expectLater(hub.themes([at('/none/')]), throwsA(isA<HttpException>()));
      served['/empty/themes.json'] = (200, utf8.encode('{"themes":[]}'));
      expect(await hub.themes([at('/none/'), at('/empty/')]), isEmpty);
    });

    test('one theme by its ID, for an anyps5://theme link; an unknown one is null', () async {
      const id = '0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b';
      served['/api/v1/themes/$id'] = (
        200,
        utf8.encode(
          jsonEncode({
            'id': id,
            'name': 'Night Drive',
            'maker': {'displayName': 'Ana'},
            'version': 3,
            'style': 2,
            'colors': {'deep': '#000000', 'middle': '#111111', 'bright': '#222222', 'accent': '#ff0000'},
            'download': '/api/v1/themes/$id/download',
            'thumb': '/api/v1/themes/$id/thumb.webp',
          }),
        ),
      );
      final theme = await ThemeHub().theme(at('/'), id);
      expect(theme!.name, 'Night Drive');
      expect(theme.author, 'Ana');
      expect(theme.version, 3);
      expect(theme.package, at('/api/v1/themes/$id/download'));
      expect(await ThemeHub().theme(at('/'), '0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c'), isNull);
      expect(await ThemeHub().theme(at('/'), '../../etc'), isNull);
    });

    test('a theme\'s file downloads into the folder', () async {
      served['/server/themes/s1/download'] = (200, [80, 75, 3, 4, 1, 2, 3]);
      final theme = HubTheme.fromIndex(entry('s1', 'On AnyTogether'), at('/server/'))!;
      final file = await ThemeHub().download(theme, p.join(temp.path, 'downloads'));
      expect(p.basename(file), 's1.anyps5theme');
      expect(File(file).readAsBytesSync(), [80, 75, 3, 4, 1, 2, 3]);
    });
  });

  group('sharing', () {
    late FakeTogether server;
    late TogetherAccount account;

    setUp(() async {
      server = await FakeTogether.start();
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('a new theme goes up with its still; one shared before becomes a new version', () async {
      server.answers['POST themes'] = (201, {'id': 't1', 'name': 'Night Drive', 'version': 1});
      final shared = await ThemeHub.share(account, theme: [1, 2, 3], filename: 'Night Drive.anyps5theme', preview: [9]);
      expect(shared.version, 1);
      expect(server.callsTo('themes', method: 'POST'), hasLength(1));
      expect(server.callsTo('themes', method: 'POST').single.headers.contentType?.mimeType, 'multipart/form-data');

      server.answers['POST themes'] = (
        409,
        {
          'type': 'about:blank',
          'status': 409,
          'code': 'conflict',
          'title': 'You shared this theme already: send it as a new version',
          'themeId': 't1',
        },
      );
      server.answers['POST themes/t1/versions'] = (200, {'id': 't1', 'name': 'Night Drive', 'version': 2});
      final again = await ThemeHub.share(account, theme: [1, 2, 3, 4], filename: 'Night Drive.anyps5theme');
      expect(again.version, 2);
    });
  });

  test('a form of files, as the server reads them', () {
    final (body, type) = ThemeHub.form([
      (name: 'theme', filename: 'a"b.anyps5theme', type: 'application/zip', data: [1, 2]),
    ]);
    final boundary = type.split('boundary=').last;
    final text = latin1.decode(body);
    expect(text, startsWith('--$boundary\r\n'));
    expect(text, contains('filename="ab.anyps5theme"'));
    expect(text, endsWith('--$boundary--\r\n'));
  });
}
