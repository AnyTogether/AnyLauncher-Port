import 'dart:ui' show Size;

import 'package:anyps5_desktop/core/themes/theme_design.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// The Theme Studio over the live home screen, and the Themes panel, as goldens.
void main() {
  late Fixture fixture;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  final shell = find.byType(LauncherShell);

  /// A theme of the Studio's knobs: violet with a warm highlight and a coral accent.
  void studio(AppModel model) {
    model.openStudio();
    model.editTheme(
      (design) => const ThemeKnobs(
        hue: 265,
        highlight: 45,
        depth: 5,
        accentHue: 15,
      ).applyTo(design).copyWith(name: 'Night Drive', style: 1),
    );
    model.panelRow = 3;
  }

  testWidgets('the Theme Studio over the home screen it changes', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    studio(model);
    await pumpLauncher(tester, model);
    await expectLater(shell, matchesGoldenFile('goldens/theme_studio.png'));
  });

  testWidgets('the Theme Studio in Turkish, in a smaller window', (tester) async {
    fixture = makeFixture(language: Language.byCode('tr'));
    final model = fixture.model;
    studio(model);
    await pumpLauncher(tester, model, size: const Size(1280, 720));
    await expectLater(shell, matchesGoldenFile('goldens/theme_studio_tr.png'));
  });

  testWidgets('the Themes panel: the built-in looks, a custom theme in use, the Studio', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    studio(model);
    model.open(Layer.themes);
    model.panelRow = 5;
    await pumpLauncher(tester, model);
    await expectLater(shell, matchesGoldenFile('goldens/themes.png'));
  });
}
