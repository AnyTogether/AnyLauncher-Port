import 'package:anyps5_desktop/core/trophies.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Hidden trophies in the trophy list: △ (or a click on Show) shows one for this look at the
/// list, and a setting shows them all.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
    model.select(model.games.indexWhere((game) => game.titleId == 'PPSA01001'));
  });

  tearDown(() {
    model.dispose();
    T.language = Language.english;
    fixture.dispose();
  });

  /// Opens the trophies with the focus on the hidden silver (the fixture's fifth trophy).
  void openOnHidden() {
    model.open(Layer.trophies);
    for (var step = 0; step < 4; step++) {
      model.handle(Command.down);
    }
    expect(model.focusedTrophy!.name, 'Ghost Signal');
    expect(model.focusedTrophy!.hidden, isTrue);
  }

  test('△ shows the focused hidden trophy and hides it again; the list stays open', () {
    openOnHidden();
    final ghost = model.focusedTrophy!;
    expect(model.isSecret(ghost), isTrue);
    model.handle(Command.options);
    expect(model.overlay, Layer.trophies);
    expect(model.isSecret(ghost), isFalse);
    model.handle(Command.options);
    expect(model.isSecret(ghost), isTrue);
    expect(model.overlay, Layer.trophies);
  });

  test('what was shown is forgotten when the list closes', () {
    openOnHidden();
    model.handle(Command.options);
    model.handle(Command.back);
    expect(model.overlay, isNull);
    openOnHidden();
    expect(model.isSecret(model.focusedTrophy!), isTrue);
  });

  test('on a trophy that is not hidden, △ closes the list as before', () {
    model.open(Layer.trophies);
    expect(model.canReveal(model.focusedTrophy!), isFalse);
    model.handle(Command.options);
    expect(model.overlay, isNull);
  });

  test('an earned hidden trophy shows itself and has nothing to show', () {
    final set = model.trophies[model.selectedGame!.id]!;
    final earned = set.trophies.firstWhere((trophy) => trophy.unlocked != null);
    expect(model.canReveal(earned), isFalse);
    expect(model.isSecret(earned), isFalse);
  });

  test('a hidden trophy once earned is never shown as hidden; only unearned hidden ones are', () {
    const secret = Trophy(
      serviceLabel: 0,
      number: 9,
      grade: TrophyGrade.gold,
      hidden: true,
      name: 'Twist',
      detail: 'The end',
    );
    final earned = Trophy(
      serviceLabel: 0,
      number: 9,
      grade: TrophyGrade.gold,
      hidden: true,
      name: 'Twist',
      detail: 'The end',
      unlocked: DateTime.utc(2026, 10, 25),
    );
    expect(model.isSecret(secret), isTrue);
    expect(model.isSecret(earned), isFalse);
    expect(model.canReveal(earned), isFalse, reason: 'nothing to show or hide again');
    // Shown and hidden again before it was earned: once earned it shows all the same.
    model.revealedTrophies = {earned.id};
    expect(model.isSecret(earned), isFalse);
    model.revealedTrophies = {};
    expect(model.isSecret(earned), isFalse);
    // In the list only the hidden silver not earned yet is masked.
    final orbit = model.selectedGame!;
    final set = model.trophies[orbit.id]!;
    expect(set.trophies.where(model.isSecret).map((trophy) => trophy.name), ['Ghost Signal']);
  });

  test('Always Show Hidden Trophies shows them all, and is kept with the preferences', () {
    model.open(Layer.settings);
    final general = model.panelCategories().firstWhere((category) => category.id == 'general');
    final row = general.rows.firstWhere((row) => row.id == 'hiddenTrophies');
    expect(row.title, 'Always Show Hidden Trophies');
    expect(row.detail, 'Hidden trophies show their name and description before you earn them.');
    (row.kind as ToggleRow).set(true);
    expect(model.preferences.showHiddenTrophies, isTrue);
    expect(Preferences.fromJson(model.preferences.toJson()).showHiddenTrophies, isTrue);
    expect(Preferences.fromJson(const {}).showHiddenTrophies, isFalse);
    openOnHidden();
    expect(model.isSecret(model.focusedTrophy!), isFalse);
    expect(model.canReveal(model.focusedTrophy!), isFalse);
    model.handle(Command.options);
    expect(model.overlay, isNull, reason: 'nothing to show: △ closes the list');
  });

  test('in Turkish', () {
    T.language = Language.turkish;
    model.open(Layer.settings);
    final general = model.panelCategories().firstWhere((category) => category.id == 'general');
    final row = general.rows.firstWhere((row) => row.id == 'hiddenTrophies');
    expect(row.title, 'Gizli Kupaları Her Zaman Göster');
    expect(row.detail, 'Gizli kupaların adı ve açıklaması kazanmadan önce de görünür.');
  });

  testWidgets('the row\'s Show chip and the △ hint show it; O does as △ does', (tester) async {
    model.open(Layer.trophies);
    await pumpLauncher(tester, model);
    expect(find.text('Ghost Signal'), findsNothing);
    expect(find.text('Hidden Trophy'), findsOneWidget);
    // The focus is not on it: its chip shows, the hint does not.
    expect(find.byKey(const ValueKey('trophy-reveal-4')), findsOneWidget);
    expect(find.text('Show'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trophy-reveal-4')));
    await settle(tester);
    expect(find.text('Ghost Signal'), findsOneWidget);
    expect(find.text('Follow the signal'), findsOneWidget);
    expect(model.trophyIndex, 4);
    // Focused and shown: chip and hint both say Hide.
    expect(find.text('Hide'), findsNWidgets(2));
    await press(tester, LogicalKeyboardKey.keyO);
    expect(find.text('Ghost Signal'), findsNothing);
    expect(find.text('Show'), findsNWidgets(2));
    expect(model.overlay, Layer.trophies);
  });
}
