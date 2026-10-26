import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/server.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_together.dart';
import '../support/fixtures.dart';

void main() {
  group('server address', () {
    test('https anywhere, http only here or at home, nothing extra', () {
      expect(TogetherServer.address('https://together.example.org/'), Uri.parse('https://together.example.org'));
      expect(TogetherServer.address('  http://192.168.1.20:8080  '), Uri.parse('http://192.168.1.20:8080'));
      expect(TogetherServer.address('http://localhost:3000'), isNotNull);
      expect(TogetherServer.address('http://nas.local'), isNotNull);
      expect(TogetherServer.address('http://172.20.0.4'), isNotNull);
      expect(TogetherServer.address('http://together.example.org'), isNull);
      expect(TogetherServer.address('http://172.32.0.4'), isNull);
      expect(TogetherServer.address('https://user@together.example.org'), isNull);
      expect(TogetherServer.address('https://together.example.org/?a=1'), isNull);
      expect(TogetherServer.address('together.example.org'), isNull);
      expect(TogetherServer.address(''), isNull);
    });

    test('ANYTOGETHER_URL, then the choice, then the standard server', () {
      expect(TogetherServer.base({}, null), TogetherServer.standard);
      expect(TogetherServer.base({}, 'https://mine.example.org'), Uri.parse('https://mine.example.org'));
      expect(TogetherServer.base({}, 'not an address'), TogetherServer.standard);
      expect(
        TogetherServer.base({'ANYTOGETHER_URL': 'http://10.0.0.5:3000/'}, 'https://mine.example.org'),
        Uri.parse('http://10.0.0.5:3000'),
      );
    });
  });

  group('account', () {
    late FakeTogether server;
    late MemoryTokenStore store;
    late TogetherAccount account;

    setUp(() async {
      server = await FakeTogether.start();
      store = MemoryTokenStore();
      account = TogetherAccount(
        base: server.base,
        store: store,
        clientName: 'launcher-linux/0.1.0 (Linux test)',
        pollEvery: const Duration(milliseconds: 10),
      );
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('client_too_old tells the launcher to update, with the minimum and where', () async {
      server.answers['auth/email/start'] = (
        426,
        {
          'code': 'client_too_old',
          'status': 426,
          'title': 'This version is too old. Update to 0.2.0 or newer.',
          'client': 'launcher-linux',
          'current': '0.1.0',
          'minimum': '0.2.0',
          'downloadUrl': 'https://anytogether.test/download',
        },
      );
      expect(account.tooOld, isNull);
      await expectLater(account.startEmail('utku@example.com'), throwsA(isA<TogetherProblem>()));
      expect(account.tooOld?.minimum, '0.2.0');
      expect(account.tooOld?.current, '0.1.0');
      expect(account.tooOld?.downloadUrl, Uri.parse('https://anytogether.test/download'));
      final other = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'x');
      server.answers['auth/email/start'] = FakeTogether.problem(409, 'conflict');
      await expectLater(other.startEmail('utku@example.com'), throwsA(isA<TogetherProblem>()));
      expect(other.tooOld, isNull);
      other.close();
    });

    test('signs in with an email code and keeps the session', () async {
      await account.startEmail(' utku@example.com ');
      expect(account.step, isA<SignInCodeSent>().having((step) => step.email, 'email', 'utku@example.com'));
      expect(server.callsTo('auth/email/start').single.body, {'email': 'utku@example.com'});
      expect(server.calls.first.headers.value('AnyTogether-Client'), 'launcher-linux/0.1.0 (Linux test)');

      await expectLater(account.verifyEmail('000000'), throwsA(isA<TogetherProblem>()));
      expect(account.user, isNull);
      final user = await account.verifyEmail('123456');
      expect(user.handle, 'utku');
      expect(account.step, isA<SignInIdle>());
      await Future<void>.delayed(Duration.zero);
      expect(store.session?.user.id, 'u-me');

      // A new start finds the session.
      final again = TogetherAccount(base: server.base, store: store, clientName: 'x');
      await again.restore();
      expect(again.user?.displayName, 'Utku');
      expect((await again.call('GET', 'me'))['profile'], isNotNull);
      again.close();
    });

    test('signs in with a code approved on the website, which opens with the code in it', () async {
      Uri? opened;
      final signingIn = account.signInWithWebsite('Desk', show: (page) => opened = page);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(account.step, isA<SignInDeviceCode>().having((step) => step.userCode, 'code', 'ABCD-EFGH'));
      expect(opened, Uri.parse('${server.base}/link?code=ABCD-EFGH'));
      expect(server.callsTo('auth/device').single.body, {'deviceName': 'Desk'});
      expect(server.callsTo('auth/token').length, greaterThan(1));
      server.approveDevice();
      final user = await signingIn;
      expect(user.id, 'u-me');
      expect(account.signedIn, isTrue);
    });

    test('a phone approves the hand-off', () async {
      final handoff = await account.startHandoff('Desk', 'Pixel');
      expect(account.step, isA<SignInWaitingForPhone>().having((step) => step.phone, 'phone', 'Pixel'));
      final waiting = account.waitForPhone(handoff);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      server.approveHandoff(handoff.id);
      expect((await waiting).handle, 'utku');
    });

    test('waiting can be given up', () async {
      final handoff = await account.startHandoff('Desk', 'Pixel');
      final waiting = account.waitForPhone(handoff);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      account.cancel();
      await expectLater(waiting, throwsA(isA<TogetherCancelled>()));
      expect(account.step, isA<SignInIdle>());
    });

    test('approves a phone hand-off as the signed-in user', () async {
      final phone = TogetherAccount(
        base: server.base,
        store: MemoryTokenStore(),
        clientName: 'phone/1.9.1',
        pollEvery: const Duration(milliseconds: 10),
      );
      final handoff = await phone.startHandoff('Pixel', 'Desk');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      await account.approveHandoff(handoff.id);
      expect((await phone.waitForPhone(handoff)).id, 'u-me');
      phone.close();
    });

    test('an access token about to expire is refreshed once, a refused refresh signs out', () async {
      server.expiresIn = 10;
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      await Future.wait([account.call('GET', 'me'), account.call('GET', 'me')]);
      final refreshes = server.callsTo('auth/token').where((call) => call.body['grantType'] == 'refresh_token');
      expect(refreshes.length, 1);

      server.validRefresh.clear();
      await expectLater(account.call('GET', 'me'), throwsA(isA<TogetherProblem>()));
      expect(account.user, isNull);
      expect(store.session, isNull);
    });

    test('a 401 refreshes and calls again', () async {
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      server.validAccess.clear();
      expect((await account.call('GET', 'me'))['account'], isNotNull);
    });

    test('sign out tells the server and forgets the session', () async {
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      await account.signOut();
      expect(server.callsTo('auth/logout'), hasLength(1));
      expect(account.user, isNull);
      expect(store.session, isNull);
    });
  });

  group('token stores', () {
    late Directory temp;
    final session = SavedSession(
      accessToken: 'access-secret',
      accessExpiry: DateTime.utc(2026, 10, 24, 12),
      refreshToken: 'refresh-secret',
      user: const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku'),
    );

    setUp(() => temp = temporaryFolder('tokens'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('a file only this user can read', () async {
      final file = p.join(temp.path, 'Together', 'session.json');
      final store = FileTokenStore(file);
      await store.save(session);
      expect(store.kind, 'file');
      expect((await store.load())?.refreshToken, 'refresh-secret');
      if (!Platform.isWindows) {
        expect(File(file).statSync().mode & 0x1FF, 384); // 0600
        expect(Directory(p.dirname(file)).statSync().mode & 0x1FF, 448); // 0700
      }
      await store.save(null);
      expect(File(file).existsSync(), isFalse);
      expect(await store.load(), isNull);
    });

    test('a sealed file holds no token in the clear, and one that does not open is no session', () async {
      final file = p.join(temp.path, 'session.bin');
      final store = FileTokenStore(file, sealer: _XorSealer());
      await store.save(session);
      expect(store.kind, 'dpapi');
      expect(utf8.decode(File(file).readAsBytesSync(), allowMalformed: true), isNot(contains('refresh-secret')));
      expect((await store.load())?.accessToken, 'access-secret');
      expect(await FileTokenStore(file, sealer: _XorSealer(refuse: true)).load(), isNull);
    });

    test('the Secret Service through secret-tool, a file when it does not answer', () async {
      if (Platform.isWindows) return;
      final keyring = p.join(temp.path, 'keyring');
      final tool = p.join(temp.path, 'secret-tool');
      File(tool).writeAsStringSync('''#!/bin/sh
case "\$1" in
  store) cat > "$keyring" ;;
  lookup) [ -f "$keyring" ] && cat "$keyring" || exit 1 ;;
  clear) rm -f "$keyring" ;;
esac
''');
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', tool]);
      final fallback = FileTokenStore(p.join(temp.path, 'session.json'));
      final store = SecretServiceStore(fallback: fallback, tool: tool);
      await store.save(session);
      expect(store.kind, 'secret-service');
      expect(File(keyring).readAsStringSync(), contains('refresh-secret'));
      expect(File(fallback.file).existsSync(), isFalse);
      expect((await store.load())?.user.handle, 'utku');
      await store.save(null);
      expect(File(keyring).existsSync(), isFalse);

      final broken = p.join(temp.path, 'broken-tool');
      File(broken).writeAsStringSync('#!/bin/sh\nexit 1\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', broken]);
      final failing = SecretServiceStore(fallback: fallback, tool: broken);
      await failing.save(session);
      expect(failing.kind, 'file');
      expect((await failing.load())?.accessToken, 'access-secret');
      final missing = SecretServiceStore(fallback: fallback, tool: p.join(temp.path, 'no-such-tool'));
      expect((await missing.load())?.accessToken, 'access-secret');
      expect(missing.kind, 'file');
    });
  });
}

class _XorSealer implements Sealer {
  _XorSealer({this.refuse = false});

  final bool refuse;

  @override
  List<int> seal(List<int> data) => [for (final byte in data) byte ^ 0x5A];

  @override
  List<int>? open(List<int> data) => refuse ? null : [for (final byte in data) byte ^ 0x5A];
}
