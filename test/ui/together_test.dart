import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
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
        'together-profile',
        'together-join',
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
        'friends-me',
        'accept-u-cem',
        'decline-u-cem',
        'friends-handle',
        'friends-ask',
        'friend-u-bora',
        'friend-u-ana',
      ]);
      final rows = model.panelCategories().single.rows.skip(1).toList();
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
      expect(rowIds(), ['friend-card', 'friend-profile', 'friend-message', 'friend-remove', 'friend-back']);
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
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
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

  group('profiles and playing together', () {
    late Map<String, dynamic> ana;

    setUp(() async {
      server = await FakeTogether.start();
      server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
      ana = FakeTogether.card('u-ana', 'ana', 'Ana');
      server.profiles['utku'] = {
        'userId': 'u-me',
        'handle': 'utku',
        'displayName': 'Utku',
        'bio': 'Plays at night',
        'country': 'TR',
        'friendship': 'me',
      };
      server.libraries['utku'] = [
        {
          'titleId': 'PPSA01001',
          'names': {'en': 'Orbit Runner'},
          'lastPlayedAt': '2026-10-24T21:00:00Z',
          'secondsPlayed': 12000,
          'trophiesEarned': 2,
          'trophiesTotal': 5,
          'progress': 40,
          'points': 45,
        },
        {
          'titleId': 'PPSA09999',
          'names': {'en': 'Elsewhere', 'tr': 'Başka Yerde'},
          'secondsPlayed': 600,
          'trophiesEarned': null,
          'trophiesTotal': null,
          'progress': null,
          'points': null,
        },
      ];
      server.trophyLists['utku'] = [
        {
          'titleId': 'PPSA01001',
          'gameNames': {'en': 'Orbit Runner'},
          'trophyId': 2,
          'grade': 'gold',
          'hidden': false,
          'texts': {
            'en': {'name': 'Far Side'},
          },
          'earnedAt': '2026-10-24T21:00:00Z',
          'rarity': 0.04,
          'rarityLabel': 'very_rare',
        },
      ];
      server.profiles['ana'] = {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana', 'friendship': 'friends'};
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

    test('my profile: games, play time, trophies and totals; back to where it was opened', () async {
      model.open(Layer.friends);
      final mine = model.panelCategories().single.rows.first;
      expect(mine.id, 'friends-me');
      (mine.kind as ActionRow).run();
      expect(model.overlay, Layer.profile);
      await until(() => model.together.profile != null);
      final page = model.together.profile!;
      expect(page.profile.isMe, isTrue);
      expect(page.totals, (games: 2, seconds: 12600, trophies: 2, points: 45));
      expect(page.library.value!.last.name('tr'), 'Başka Yerde');
      expect(page.trophies.value!.single.name('en'), 'Far Side');
      expect(TogetherProfiles.playTime(12000), '3 h 20 min');
      expect(TogetherProfiles.playTime(7200), '2 h');
      expect(TogetherProfiles.playTime(600), '10 min');
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.down);
      expect(model.together.profileIndex, 2);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.friends);
    });

    test("a friend's profile keeps what they keep private; details fall back to their card", () async {
      server.privateParts['ana'] = {'profile', 'library'};
      await model.together.openProfile(
        'ana',
        card: const Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
      );
      final page = model.together.profile!;
      expect(page.detailsPrivate, isTrue);
      expect(page.profile.displayName, 'Ana');
      expect(page.library, isA<SectionPrivate<List<PlayedGame>>>());
      expect(page.trophies, isA<SectionShown<List<EarnedTrophy>>>());
      expect(page.totals, isNull);
    });

    test('while a game runs, friends see a session they can join; it ends with the game', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_TOGETHER\nsleep 0.6\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      await until(() => model.together.hub.games.session != null);
      expect(server.callsTo('game-sessions', method: 'POST').single.body, {
        'titleId': 'PPSA01001',
        'gameVersion': '01.000.000',
        'engineBuild': 'toolkit-1',
        'capacity': 4,
        'joinable': true,
      });
      final bridge = File(model.together.hub.games.bridgeFile);
      final written = jsonDecode(bridge.readAsStringSync()) as Map<String, dynamic>;
      expect(written['role'], 'host');
      expect(written['userId'], 'u-me');

      // Friends join only when it is let.
      await model.together.setFriendsJoin(false);
      expect(server.callsTo('game-sessions/${written['session']['id']}', method: 'PATCH').single.body, {
        'joinable': false,
      });
      await playing;
      await until(() => model.together.hub.games.session == null);
      await until(() => server.callsTo('game-sessions/${written['session']['id']}', method: 'DELETE').isNotEmpty);
      expect(bridge.existsSync(), isFalse);
      expect(
        File(model.paths.logFile('PPSA01001')).readAsStringSync(),
        contains('ANYPS5_TOGETHER_SESSION=${bridge.path}'),
      );
    });

    test("joining a friend's game: the same version and engine, then the game starts", () async {
      server.hostSession('gs-ana', ana);
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 0.4\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      await model.together.joinFriendGame('gs-ana', titleId: 'PPSA01001', host: 'Ana');
      expect(model.toast, 'Starting Orbit Runner with Ana');
      expect(server.callsTo('game-sessions/gs-ana/join').single.body, {
        'gameVersion': '01.000.000',
        'engineBuild': 'toolkit-1',
      });
      final written = jsonDecode(File(model.together.hub.games.bridgeFile).readAsStringSync()) as Map<String, dynamic>;
      expect(written['role'], 'guest');
      final session = written['session'] as Map<String, dynamic>;
      expect(session['properties'], {'mode': 'coop'});
      expect(((session['members'] as List).first as Map)['properties'], {'address': 'relay:1'});
      await until(() => model.running != null);
      await until(() => model.running == null);
      await until(() => server.callsTo('game-sessions/gs-ana/leave').isNotEmpty);
      expect(server.callsTo('game-sessions', method: 'POST'), isEmpty, reason: 'a guest opens no session of its own');
    });

    test('the version guard, a game not here or locked, a full game', () async {
      server.hostSession('gs-v', ana, gameVersion: '01.001.000');
      await model.together.joinFriendGame('gs-v', titleId: 'PPSA01001', host: 'Ana');
      expect(model.toast, 'Ana plays version 01.001.000 of the game; yours is 01.000.000');
      server.hostSession('gs-e', ana, engineBuild: '0.2.13-a1b2c3d4e5f6');
      await model.together.joinFriendGame('gs-e', titleId: 'PPSA01001', host: 'Ana');
      expect(model.toast, 'Ana plays on AnyPS5 0.2.13 (a1b2c3), you on toolkit (1): update to the same one');
      expect(server.calls.where((call) => call.path.endsWith('/join')), isEmpty);

      await model.together.joinFriendGame('gs-x', titleId: 'PPSA09999', host: 'Ana');
      expect(model.toast, 'PPSA09999 is not in your library');
      await model.together.joinFriendGame('gs-x', titleId: 'PPSA02002', host: 'Ana');
      expect(model.toast, 'Unlock Neon Alley first');

      final full = server.hostSession('gs-full', ana);
      full['capacity'] = 1;
      await model.together.joinFriendGame('gs-full', titleId: 'PPSA01001', host: 'Ana');
      expect(model.toast, 'This game is full');
    });

    test("an invite to a friend's game shows in the friends panel and can be declined", () async {
      final invite = {
        'sessionId': 'gs-ana',
        'from': ana,
        'titleId': 'PPSA01001',
        'gameVersion': '01.000.000',
        'engineBuild': 'toolkit-1',
      };
      server.gameInvites.add(invite);
      server.push('game_session.invite', invite);
      await until(() => model.together.hub.games.invites.isNotEmpty);
      expect(model.toast, 'Ana invites you to Orbit Runner');
      expect(model.together.hub.badge, 1);
      model.open(Layer.friends);
      expect(rowIds().skip(1).take(2), ['game-accept-gs-ana', 'game-decline-gs-ana']);
      (model.panelCategories().single.rows[2].kind as ActionRow).run();
      await until(() => server.callsTo('game-sessions/gs-ana/decline').isNotEmpty);
      expect(model.together.hub.badge, 0);
    });
  });
}
