import 'package:anyps5_desktop/core/together/account.dart';
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
