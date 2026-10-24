import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// AnyTogether's screens, rendered headless. (The network tests are in together_test.dart: a
/// file with widget tests gets Flutter's HTTP stand-in, which answers every request with 400.)
void main() {
  late Fixture fixture;
  late AppModel model;

  int category(String id) => model.panelCategories().indexWhere((category) => category.id == id);

  void openTogether() {
    model.open(Layer.settings);
    model.selectCategory(category('together'));
  }

  group('interface', () {
    tearDown(() {
      T.language = Language.english;
      fixture.dispose();
    });

    testWidgets('golden: the AnyTogether settings, signed out', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      openTogether();
      model.handle(launcher.Command.down);
      await pumpLauncher(tester, model);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_signin.png'));
    });

    testWidgets('golden: the code step, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.turkish);
      model = fixture.model;
      model.together.account.step = const SignInCodeSent('utku@example.com');
      openTogether();
      await pumpLauncher(tester, model);
      expect(find.text('Maildeki kod'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_code_tr.png'));
    });

    testWidgets('Enter puts the cursor in the email field, the keys type, Esc gives them back', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      openTogether();
      await pumpLauncher(tester, model);
      while (model.panelCategories()[model.panelCategory].rows[model.panelRow].id != 'together-email') {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.editingRow, 'together-email');
      await tester.enterText(find.byType(TextField).first, 'utku@example.com');
      await settle(tester);
      expect(model.together.email, 'utku@example.com');
      // Backspace and space are the field's while typing, not Back and Select.
      await press(tester, LogicalKeyboardKey.backspace);
      expect(model.overlay, Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.editingRow, isNull);
      expect(model.overlay, Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull);
    });

    testWidgets('golden: friends, with a request, one playing, one online, one offline', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      model.open(Layer.friends);
      await pumpLauncher(tester, model);
      expect(find.text('@bora · Playing Neon Alley · 25 min · joinable · in a party 2/8'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_friends.png'));
    });

    testWidgets('golden: home with the friends button and its badge, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.turkish);
      model = fixture.model;
      signedInPreview(model);
      model.handle(launcher.Command.up);
      model.handle(launcher.Command.right);
      await pumpLauncher(tester, model);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_home_tr.png'));
    });

    testWidgets('golden: messages, a conversation open with a quick reply focused', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
      const me = Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
      ChatMessage message(int seq, String author, String text, {bool failed = false}) => ChatMessage(
        id: 'm$seq',
        conversationId: 'c-ana',
        seq: seq,
        authorId: author,
        text: text,
        createdAt: DateTime.utc(2026, 10, 24, 20, seq),
        failed: failed,
      );
      final thread = [
        message(1, 'u-ana', 'Hi! Are you playing Neon Alley tonight?'),
        message(2, 'u-me', 'Yes, after dinner'),
        message(3, 'u-ana', 'Great, I will start a party'),
        message(4, 'u-me', 'look at this blocked link', failed: true),
      ];
      model.together.hub.messages
        ..conversations = [
          Conversation(
            id: 'c-ana',
            group: false,
            title: null,
            members: const [me, ana],
            lastSeq: 4,
            readSeq: 4,
            lastMessage: thread[2],
            updatedAt: DateTime.utc(2026, 10, 24),
          ),
          Conversation(
            id: 'c-group',
            group: true,
            title: 'Friday night',
            members: const [
              me,
              ana,
              Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz'),
            ],
            lastSeq: 9,
            readSeq: 6,
            lastMessage: message(9, 'u-cem', 'Who brings snacks?'),
            updatedAt: DateTime.utc(2026, 10, 23),
          ),
        ]
        ..unread = 3
        ..loaded = true
        ..openId = 'c-ana'
        ..thread = thread;
      model.open(Layer.messages);
      model.together
        ..messagesInThread = true
        ..messageFocus = 1;
      await pumpLauncher(tester, model);
      expect(find.text('Who brings snacks?'), findsNothing);
      expect(find.text('Cem Yılmaz: Who brings snacks?'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages.png'));
    });

    testWidgets('golden: a party, in Turkish, led by Utku with Ana muted in voice', (tester) async {
      fixture = makeFixture(language: Language.turkish);
      model = fixture.model;
      signedInPreview(model);
      model.together.hub.parties.party = const Party(
        id: 'p1',
        leaderId: 'u-me',
        open: true,
        members: [
          Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis'),
          Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
        ],
        invited: [Person(id: 'u-bora', handle: 'bora', displayName: 'Bora')],
        callId: 'call-1',
        inCall: {'u-ana'},
        muted: {'u-ana'},
      );
      model.open(Layer.party);
      await pumpLauncher(tester, model);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_party_tr.png'));
    });
  });
}

/// Signed in as Utku with three friends and a request, without a server: for the screens.
void signedInPreview(AppModel model) {
  final together = model.together;
  together.account.user = const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
  const cem = Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz');
  together.hub.friends
    ..incoming = [const Person(id: 'u-eda', handle: 'eda', displayName: 'Eda')]
    ..friends = [
      Friend(
        const Person(id: 'u-bora', handle: 'bora', displayName: 'Bora'),
        Presence(
          state: PresenceState.inGame,
          titleId: 'PPSA02002',
          since: DateTime.now().subtract(const Duration(minutes: 25, seconds: 20)),
          party: const PresenceParty(id: 'p1', size: 2, max: 8, open: true),
          game: const PresenceGame(sessionId: 's1', titleId: 'PPSA02002', joinable: true, players: 1, capacity: 4),
        ),
      ),
      const Friend(Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'), Presence(state: PresenceState.online)),
      const Friend(cem, Presence()),
    ]
    ..loaded = true;
}
