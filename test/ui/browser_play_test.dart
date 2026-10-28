import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/remote/browser_pad_access.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/browser_play.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Play from a browser in the launcher: its rows under the phone controller, the server only
/// while it is wanted, and a browser through the launcher's own pairing card to the pad.
void main() {
  setUpAll(() => BrowserPlayModel.hostOverride = '127.0.0.1');
  tearDownAll(() => BrowserPlayModel.hostOverride = null);

  group('model', () {
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      fixture = makeFixture();
      model = fixture.model;
      await model.startPhoneServer();
    });

    tearDown(() async {
      await model.stopPhoneServer();
      T.language = Language.english;
      fixture.dispose();
    });

    Future<void> until(bool Function() condition) async {
      for (var tries = 0; tries < 300 && !condition(); tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(condition(), isTrue);
    }

    List<String> phoneRows() {
      model.open(Layer.settings);
      return model
          .panelCategories()
          .firstWhere((category) => category.id == 'phone')
          .rows
          .map((row) => row.id)
          .toList();
    }

    test('the rows sit under the phone controller, and turning it off hides them', () {
      expect(phoneRows(), containsAllInOrder(['server', 'browserPlay', 'browserPlayShow', 'browserPlayKeep']));
      model.preferences.browserPlay = false;
      expect(phoneRows(), contains('browserPlay'));
      expect(phoneRows(), isNot(contains('browserPlayShow')));
    });

    test('the server runs only while the code is shown or Keep On is chosen', () async {
      await model.browserPlay.update();
      expect(model.browserPlay.running, isFalse, reason: 'nothing asked for it');
      model.browserPlay.open();
      await until(() => model.browserPlay.url != null);
      expect(model.overlay, Layer.browserPlay);
      expect(model.browserPlay.url!.host, '127.0.0.1');
      model.browserPlay.close();
      await until(() => !model.browserPlay.running);
      model.preferences.browserPlayAlways = true;
      await model.browserPlay.update();
      expect(model.browserPlay.running, isTrue);
      model.preferences.browserPlay = false;
      await model.browserPlay.update();
      expect(model.browserPlay.running, isFalse, reason: 'off stops it, Keep On or not');
    });

    test("a browser pairs through the launcher's card and becomes a pad", () async {
      model.browserPlay.open();
      await until(() => model.browserPlay.url != null);
      final url = model.browserPlay.url!;
      // A raw request: the test binding fakes HttpClient.
      final socket = await Socket.connect('127.0.0.1', url.port);
      socket.write(
        'GET /?${url.query} HTTP/1.1\r\nHost: 127.0.0.1:${url.port}\r\n'
        'User-Agent: Mozilla/5.0 (Linux; Android 15; Pixel 9)\r\n\r\n',
      );
      final head = await utf8.decoder.bind(socket).join();
      socket.destroy();
      expect(head, startsWith('HTTP/1.1 303'));
      final cookie = RegExp(r'set-cookie: ([^;]+);', caseSensitive: false).firstMatch(head)!.group(1)!;
      final page = await WebSocket.connect(
        'ws://127.0.0.1:${url.port}/ws',
        headers: {'Origin': 'http://127.0.0.1:${url.port}', 'Cookie': cookie},
      );
      final heard = <Map<String, dynamic>>[];
      page.listen((data) => heard.add(jsonDecode(data as String) as Map<String, dynamic>));
      await until(() => model.pairing != null);
      expect(model.pairing!.deviceName, 'Android · Web');
      await until(() => heard.any((message) => message['t'] == 'pairing'));
      expect(heard.firstWhere((message) => message['t'] == 'pairing')['code'], model.pairing!.code);
      model.answerPairing(true);
      await until(() => heard.any((message) => message['t'] == 'welcome'));
      await until(() => model.browserPlay.pads.any((pad) => pad.$3));
      expect(model.remote!.connectedDevices, ['Android · Web']);
      expect(model.remote!.devices.all.single.id, startsWith(BrowserPadAccess.devicePrefix));
      await page.close();
    });
  });

  group('golden', () {
    Fixture? current;
    tearDown(() {
      T.language = Language.english;
      current?.dispose();
      current = null;
    });
    final shell = find.byType(LauncherShell);

    testWidgets('browser play: the code, one browser playing and one asking', (tester) async {
      final fixture = current = makeFixture();
      final model = fixture.model;
      model.browserPlay.preview(
        url: Uri.parse('http://192.168.1.24:47710/?t=Qm9vbS1ub3QtYS1yZWFsLXRva2Vu'),
        secondsLeft: 97,
        pads: const [('iPhone · Web', 'a', true), ('Android · Web', 'b', false)],
      );
      model.open(Layer.browserPlay);
      await pumpLauncher(tester, model);
      expect(find.text('Play from a browser'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/browser_play_en.png'));
    });

    testWidgets('browser play: no network, in Turkish', (tester) async {
      final fixture = current = makeFixture(language: Language.byCode('tr'));
      final model = fixture.model;
      model.browserPlay.preview(unavailable: true);
      model.open(Layer.browserPlay);
      await pumpLauncher(tester, model);
      expect(find.text('Tarayıcıdan oyna'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/browser_play_offline_tr.png'));
    });
  });
}
