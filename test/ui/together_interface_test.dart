import 'package:anyps5_desktop/core/together/account.dart';
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
  });
}
