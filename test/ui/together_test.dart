import 'dart:io';

import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/ui_support.dart';

/// AnyTogether in the launcher: signing in (email code, the website, the phone), the server,
/// signing out.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  int category(String id) => model.panelCategories().indexWhere((category) => category.id == id);

  List<String> rowIds() => model.panelCategories()[model.panelCategory].rows.map((row) => row.id).toList();

  void openTogether() {
    model.open(Layer.settings);
    model.selectCategory(category('together'));
  }

  group('signing in', () {
    setUp(() async {
      server = await FakeTogether.start();
      fixture = makeFixture(together: server.base);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    test('the settings offer the website and an email code; a code typed in signs in', () async {
      openTogether();
      expect(rowIds(), [
        'together-intro',
        'together-web',
        'together-email',
        'together-send',
        'together-server',
        'together-server-use',
      ]);
      final together = model.together;
      together.email = 'utku@example.com';
      await together.sendCode();
      expect(rowIds(), ['together-intro', 'together-sent', 'together-code', 'together-verify', 'together-other']);
      final code = model.panelCategories()[model.panelCategory].rows[2].kind as TextRow;
      code.set('123 456');
      await until(() => together.signedIn);
      expect(model.toast, 'Signed in as Utku');
      expect(rowIds(), [
        'together-user',
        'together-online',
        'together-signout',
        'together-server',
        'together-server-use',
      ]);

      await together.signOut();
      expect(together.signedIn, isFalse);
      expect(server.callsTo('auth/logout'), hasLength(1));
    });

    test('a wrong code says so and keeps the code row', () async {
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '654321';
      await model.together.verify();
      expect(model.toast, 'That code is not right');
      expect(model.together.account.step, isA<SignInCodeSent>());
    });

    test('the website opens in the browser with the code, and signing in there signs in here', () async {
      openTogether();
      final signingIn = model.together.signInWithWebsite();
      await until(() => fixture.opened.isNotEmpty);
      expect(fixture.opened.single.queryParameters['code'], 'ABCD-EFGH');
      expect(rowIds(), ['together-intro', 'together-device', 'together-open', 'together-cancel']);
      expect(model.panelCategories()[model.panelCategory].rows[1].title, 'ABCD-EFGH');
      server.approveDevice();
      await signingIn;
      expect(model.together.user?.handle, 'utku');
      expect(server.callsTo('auth/device').single.headers.value('AnyTogether-Client'), startsWith('launcher-linux/'));
    });

    test('the paired phone approves the launcher, or says no', () async {
      await model.startPhoneServer();
      final phone = await FakePhone.connect(model.remote!.port!);
      phone.hello('phone-1', 'Pixel');
      await phone.next<Pairing>();
      await until(() => model.pairing != null);
      model.handle(launcher.Command.select);
      final welcome = await phone.next<Welcome>();
      expect(welcome.togetherServer, server.base.toString());
      openTogether();
      expect(rowIds(), contains('together-phone'));

      // No: the launcher goes back to the start.
      var signingIn = model.together.signInWithPhone();
      var asked = await phone.next<TogetherHandoff>();
      expect(asked.deviceName, 'Desk');
      expect(rowIds(), ['together-intro', 'together-onphone', 'together-cancel']);
      phone.send(TogetherHandoffAnswer(id: asked.id, approved: false));
      await signingIn;
      expect(model.toast, 'The phone did not approve; sign in to AnyTogether on the phone first');
      expect(model.together.signedIn, isFalse);

      // Yes: the phone approves on the server.
      signingIn = model.together.signInWithPhone();
      asked = await phone.next<TogetherHandoff>();
      server.approveHandoff(asked.id);
      await signingIn;
      expect(model.together.signedIn, isTrue);
      await phone.close();
      await model.stopPhoneServer();
    });

    test('a signed-in launcher approves its phone, a signed-out one turns it down', () async {
      await model.startPhoneServer();
      final phone = await FakePhone.connect(model.remote!.port!);
      phone.hello('phone-1', 'Pixel');
      await phone.next<Pairing>();
      await until(() => model.pairing != null);
      model.handle(launcher.Command.select);
      await phone.next<Welcome>();

      phone.send(const TogetherHandoff(id: 'handoff-x', deviceName: 'Pixel'));
      expect((await phone.next<TogetherHandoffAnswer>()).approved, isFalse);

      final phoneAccount = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'phone/1.9.1');
      final handoff = await phoneAccount.startHandoff('Pixel', 'Desk');
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      phone.send(TogetherHandoff(id: handoff.id, deviceName: 'Pixel'));
      final answer = await phone.next<TogetherHandoffAnswer>();
      expect(answer.approved, isTrue);
      expect(answer.id, handoff.id);
      expect(model.toast, 'Pixel signed in to AnyTogether');
      expect((await phoneAccount.waitForPhone(handoff)).id, 'u-me');
      phoneAccount.close();
      await phone.close();
      await model.stopPhoneServer();
    });

    test('another server signs out of this one first; a bad address is refused', () async {
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await model.together.useServer('http://example.org');
      expect(model.toast, 'Type an https:// address (http:// only for this computer or the home network)');
      expect(model.together.signedIn, isTrue);
      await model.together.useServer('https://together.example.org/');
      expect(model.together.signedIn, isFalse);
      expect(model.together.account.base, Uri.parse('https://together.example.org'));
      expect(model.preferences.togetherServer, 'https://together.example.org');
      expect(model.toast, 'Now using together.example.org');
    });

    test('a session kept from the last run is signed in at the start', () async {
      final store = MemoryTokenStore(
        SavedSession(
          accessToken: 'old',
          accessExpiry: DateTime.now().add(const Duration(hours: 1)),
          refreshToken: 'old-refresh',
          user: const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku'),
        ),
      );
      final again = makeFixture(together: server.base, togetherStore: store);
      await again.model.together.start();
      expect(again.model.together.user?.handle, 'utku');
      again.model.dispose();
      again.dispose();
    });
  });

  group('friends and presence', () {
    setUp(() async {
      server = await FakeTogether.start();
      server
        ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
        ..friend('u-bora', 'bora', 'Bora', presence: {'state': 'in_game', 'titleId': 'PPSA02002'})
        ..person('u-deniz', 'deniz', 'Deniz');
      server.incoming.add(FakeTogether.card('u-cem', 'cem', 'Cem'));
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.hub.friends.loaded);
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    test('the friends panel: requests, adding by handle, friends by what they do', () async {
      model.open(Layer.friends);
      expect(rowIds(), [
        'accept-u-cem',
        'decline-u-cem',
        'friends-handle',
        'friends-ask',
        'friend-u-bora',
        'friend-u-ana',
      ]);
      final rows = model.panelCategories().single.rows;
      expect(rows[4].detail, '@bora · Playing Neon Alley');
      expect(rows[4].person?.status, PersonStatus.playing);
      expect(model.together.hub.badge, 1);

      (rows[0].kind as ActionRow).run();
      await until(() => model.together.hub.friends.byId('u-cem') != null);
      expect(model.toast, 'You and Cem are friends');

      model.together.friendHandle = '@deniz';
      await model.together.askFriend();
      expect(model.toast, 'Request sent to deniz');
      expect(rowIds().last, 'waiting-u-deniz');
      model.together.friendHandle = 'nobody';
      await model.together.askFriend();
      expect(model.toast, 'No one is called nobody');
    });

    test('a friend opens their options; removing them takes them off', () async {
      model.open(Layer.friends);
      final ana = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-u-ana');
      (ana.kind as ActionRow).run();
      expect(model.overlay, Layer.friendOptions);
      expect(rowIds(), ['friend-card', 'friend-remove', 'friend-back']);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.friends);
      (ana.kind as ActionRow).run();
      final remove = model.panelCategories().single.rows[1];
      (remove.kind as ActionRow).run();
      await until(() => model.together.hub.friends.byId('u-ana') == null);
      expect(model.overlay, Layer.friends);
      expect(server.callsTo('me/friends/u-ana', method: 'DELETE'), hasLength(1));
    });

    test('a request on the socket shows and comes into the list', () async {
      server.incoming.add(FakeTogether.card('u-eda', 'eda', 'Eda'));
      server.push('friend.request', FakeTogether.card('u-eda', 'eda', 'Eda'));
      await until(() => model.together.hub.badge == 2);
      expect(model.toast, 'Eda wants to be friends');
    });

    test('friends see the game played, then the launcher online again', () async {
      await server.nextFrame('heartbeat', test: (frame) => (frame['presence'] as Map)['state'] == 'online');
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 0.4\n');
      Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      final inGame = await server.nextFrame(
        'heartbeat',
        test: (frame) => (frame['presence'] as Map)['state'] == 'in_game',
      );
      expect((inGame['presence'] as Map)['titleId'], 'PPSA01001');
      expect(DateTime.parse((inGame['presence'] as Map)['since'] as String).isBefore(DateTime.now()), isTrue);
      await playing;
      await server.nextFrame('heartbeat', test: (frame) => (frame['presence'] as Map)['state'] == 'online');
    });

    test('signed out on another device: signed out here too', () async {
      await until(() => model.together.connected);
      await server.dropSockets(4003);
      await until(() => !model.together.signedIn);
      expect(model.together.hub.friends.friends, isEmpty);
    });
  });
}
