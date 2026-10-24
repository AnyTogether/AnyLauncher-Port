import 'dart:io';

import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
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
      expect(rowIds(), ['friend-card', 'friend-message', 'friend-remove', 'friend-back']);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.friends);
      (ana.kind as ActionRow).run();
      final remove = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-remove');
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

  group('play and trophies', () {
    setUp(() async {
      server = await FakeTogether.start();
      fixture = makeFixture(together: server.base);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      fixture.dispose();
    });

    test('signing in sends every game\'s trophies; a session played goes up', () async {
      // Signed out, nothing is kept for AnyTogether.
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.together.recordPlay(orbit, DateTime.now().subtract(const Duration(hours: 1)), DateTime.now());
      expect(model.together.sync.sessions, isEmpty);

      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => server.earned.length == 2);
      expect(server.devices.values.single['platform'], 'linux');
      expect(server.devices.values.single['name'], 'Desk');
      expect(server.games['PPSA01001'], {
        'names': {'en': 'Orbit Runner'},
      });
      final set = server.trophySets.keys.single;
      expect(set, startsWith('PPSA01001/'));
      expect(server.earned.keys.toSet(), {'PPSA01001/1', 'PPSA01001/2'});

      model.together.recordPlay(
        orbit,
        DateTime.now().subtract(const Duration(minutes: 40)),
        DateTime.now(),
        exit: 'killed',
      );
      await until(() => server.playSessions.isNotEmpty);
      expect(server.playSessions.values.single['titleId'], 'PPSA01001');
      expect(server.playSessions.values.single['exit'], 'killed');
      expect(model.together.sync.isEmpty, isTrue);
    });
  });

  group('messages and the party', () {
    setUp(() async {
      server = await FakeTogether.start();
      server
        ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
        ..friend('u-bora', 'bora', 'Bora');
      server.conversation(
        'c-ana',
        [FakeTogether.card('u-ana', 'ana', 'Ana')],
        texts: [('u-ana', 'Hi!'), ('u-ana', 'Playing tonight?')],
      );
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.hub.friends.loaded && model.together.hub.messages.loaded);
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    test('the conversations, then friends to start one with; opening reads it; quick replies and typing', () async {
      final together = model.together;
      await until(() => together.unread == 2);
      await together.openMessages();
      expect(model.overlay, Layer.messages);
      final targets = together.messageTargets;
      expect(targets.first, isA<ConversationTarget>());
      expect((targets.last as FriendTarget).friend.person.handle, 'bora');
      await until(() => together.hub.messages.thread.length == 2);
      await until(() => server.callsTo('conversations/c-ana/read').isNotEmpty);
      expect(together.unread, 0);

      // Into the thread: the field first, a quick reply to its left.
      model.handle(launcher.Command.right);
      expect(together.messagesInThread, isTrue);
      model.handle(launcher.Command.left);
      model.handle(launcher.Command.select);
      await until(() => server.threads['c-ana']!.length == 3);
      expect(server.threads['c-ana']!.last['text'], 'One sec');

      // Typing: the others are told, Enter sends.
      model.handle(launcher.Command.right);
      model.handle(launcher.Command.select);
      expect(model.editingRow, 'message-draft');
      final field = together.draftField.kind as TextRow;
      field.set('See you at nine');
      final typing = await server.nextFrame('typing');
      expect(typing['conversation'], 'c-ana');
      field.submit!();
      await until(() => server.threads['c-ana']!.length == 4);
      expect(together.draft, isEmpty);

      // Someone typing, then their message.
      server.push('typing', {'conversationId': 'c-ana', 'userId': 'u-ana'});
      await until(() => together.hub.messages.typingIn('c-ana').isNotEmpty);
      server.receive('c-ana', 'u-ana', 'Great');
      await until(() => together.hub.messages.thread.length == 5);
      expect(together.hub.messages.typingIn('c-ana'), isEmpty);

      model.handle(launcher.Command.back);
      model.handle(launcher.Command.back);
      expect(model.overlay, isNull);
      server.receive('c-ana', 'u-ana', 'Are you there?');
      await until(() => model.toast == 'Ana: Are you there?');
    });

    test('a link the server blocks is said so; a friend without a conversation gets one', () async {
      final together = model.together;
      await together.openMessages();
      await until(() => together.hub.messages.openId == 'c-ana');
      await together.sendMessage('look https://blocked.example/x');
      expect(model.toast, "That link can't be sent");
      expect(together.hub.messages.thread.last.failed, isTrue);

      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      await until(() => server.callsTo('conversations', method: 'POST').isNotEmpty);
      expect(server.callsTo('conversations', method: 'POST').single.body, {
        'members': ['u-bora'],
      });
      await until(() => together.hub.messages.openId != 'c-ana' && together.hub.messages.openId != null);
      expect(together.messagesInThread, isTrue);
    });

    test('a party: start it, invite from a friend\'s options, join its voice, choose the talk key', () async {
      final together = model.together;
      model.open(Layer.party);
      expect(rowIds(), ['party-start', 'party-open']);
      await together.startParty();
      expect(rowIds(), [
        'voice-join',
        'party-members',
        'party-member-u-me',
        'party-privacy',
        'party-invite-title',
        'party-invite-u-ana',
        'party-invite-u-bora',
        'party-leave',
      ]);

      model.open(Layer.friends);
      (model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-u-ana').kind as ActionRow).run();
      expect(rowIds(), contains('friend-party'));
      (model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-party').kind as ActionRow).run();
      await until(() => server.callsTo('parties/${together.hub.parties.party!.id}/invites').isNotEmpty);
      expect(model.toast, 'Ana is invited');

      model.open(Layer.party);
      await together.joinVoice();
      expect(model.toast, "You're in voice");
      expect(rowIds().take(4), ['voice-mic', 'voice-ptt', 'voice-key', 'voice-leave']);
      final mic = model.panelCategories().single.rows.first;
      expect(mic.detail, 'V turns the microphone on and off, in a game too');

      together.captureTalkKey();
      expect(together.capturingTalkKey, isTrue);
      expect(together.chooseTalkKey(0x4F), isFalse, reason: 'an arrow is not a talk key');
      together.captureTalkKey();
      expect(together.chooseTalkKey(0x0A), isTrue);
      expect(model.preferences.talkKey, 0x0A);
      expect(model.toast, 'Talk key: G');

      together.setPushToTalk(true);
      expect(model.preferences.pushToTalk, isTrue);
      expect(rowIds().take(3), ['voice-ptt', 'voice-key', 'voice-leave']);
      expect(model.panelCategories().single.rows.first.detail, 'Hold G to talk, in a game too');
      // Without a desktop key reader, the launcher's own keys hold it.
      expect(together.talkKeyInWindow(0x0A, down: true), isTrue);
      expect(together.hub.voice.sending, isTrue);
      expect(together.talkKeyInWindow(0x0A, down: false), isTrue);
      expect(together.hub.voice.sending, isFalse);

      await together.leaveParty();
      expect(together.hub.voice.active, isFalse);
      expect(together.hub.parties.party, isNull);
    });

    test('an invite shows, can be accepted; a full party says so', () async {
      final together = model.together;
      final invite = {'partyId': 'p-ana', 'from': FakeTogether.card('u-ana', 'ana', 'Ana'), 'size': 2};
      server.partyInvites.add(invite);
      server.push('party.invite', invite);
      await until(() => together.partyBadge == 1);
      expect(model.toast, 'Ana invites you to a party');
      model.open(Layer.party);
      expect(rowIds().take(2), ['party-accept-p-ana', 'party-decline-p-ana']);
      expect(model.panelCategories().single.rows.first.detail, '2 of 8 in it');
      (model.panelCategories().single.rows.first.kind as ActionRow).run();
      await until(() => together.hub.parties.party?.id == 'p-ana');
      expect(rowIds(), contains('party-member-u-ana'));

      server.partyInvites.add({...invite, 'partyId': 'p-full', 'full': true});
      await together.joinParty('p-full');
      expect(model.toast, 'The party is full');
    });
  });
}
