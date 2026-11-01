import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme_hub_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// The Theme Hub in Settings › Appearance › Themes, as the macOS launcher's: the shared themes
/// listed, one installed and used with a choice, and Share on the Hub uploading the theme in use
/// with a still of it.
void main() {
  late FakeTogether server;
  late HttpServer files;
  late Fixture fixture;
  late AppModel model;

  String fixtureTheme(String name) => p.absolute(p.join('test', 'support', 'themes', name));

  setUp(() async {
    HttpOverrides.global = null;
    server = await FakeTogether.start();
    files = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    files.listen((request) async {
      final path = request.uri.path;
      if (path == '/forest.anyps5theme') {
        request.response.add(File(fixtureTheme('forest.anyps5theme')).readAsBytesSync());
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    fixture = makeFixture(together: server.base);
    model = fixture.model;
    ThemeHubModel.basesInstead = [server.base.resolve('/api/v1/hub/')];
  });

  tearDown(() async {
    ThemeHubModel.basesInstead = null;
    model.dispose();
    fixture.dispose();
    await files.close(force: true);
    await server.close();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 1000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  List<String> hubIds() => [
    for (final row in model.hubRows())
      if (row.id.startsWith('hub')) row.id,
  ];

  test('the Hub lists the shared themes; choosing one installs and uses it', () async {
    server.answers['hub/themes.json'] = (
      200,
      {
        'themes': [
          {
            'id': 'forest-hub',
            'name': 'Forest',
            'author': 'Ana',
            'version': 1,
            'style': 1,
            'deep': '#0b1a12',
            'middle': '#18352a',
            'bright': '#5fbf8a',
            'accent': '#c9e86b',
            'package': 'http://127.0.0.1:${files.port}/forest.anyps5theme',
          },
        ],
      },
    );
    expect(hubIds(), ['hub', 'hub-loading']);
    await until(() => model.hubList is HubShown);
    expect(hubIds(), ['hub', 'hub-forest-hub']);
    final row = model.hubRows().firstWhere((row) => row.id == 'hub-forest-hub');
    expect(row.detail, T.format('themeBy', ['Ana']));
    (row.kind as ActionRow).run();
    await until(() => model.activeDesign != null);
    expect(model.toast, contains(model.activeDesign!.name));
  });

  test('a Hub that cannot be read offers to try again; an empty one says so', () async {
    server.answers['hub/themes.json'] = FakeTogether.problem(500, 'internal');
    await model.loadHub();
    expect(hubIds(), ['hub', 'hub-retry']);
    server.answers['hub/themes.json'] = (200, {'themes': <Object>[]});
    await model.loadHub(again: true);
    expect(hubIds(), ['hub', 'hub-empty']);
  });

  testWidgets('Share on the Hub, signed in: the theme in use goes up with a still of it', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      final together = model.together;
      together.email = 'utku@example.com';
      await together.sendCode();
      together.code = '123456';
      await together.verify();
      await until(() => together.signedIn);
      final design = await model.installTheme(fixtureTheme('forest.anyps5theme'));
      expect(design, isNotNull);
      server.answers['POST themes'] = (201, {'id': 't1', 'name': design!.name, 'version': 1});
      server.answers['hub/themes.json'] = (200, {'themes': <Object>[]});
      await model.shareOnHub(design);
      expect(model.toast, T.format('socialHubShared', [design.name]));
      final call = server.callsTo('themes', method: 'POST').single;
      expect(call.headers.contentType?.mimeType, 'multipart/form-data');
      expect(call.body['bytes'], greaterThan(File(fixtureTheme('forest.anyps5theme')).lengthSync() ~/ 2));
    });
  });

  test('a still of a theme is a PNG', () async {
    final design = await model.installTheme(fixtureTheme('forest.anyps5theme'), use: false);
    final still = await ThemeHubModel.themeStill(design!);
    expect(still.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(utf8.decode(still.sublist(1, 4)), 'PNG');
  });
}
