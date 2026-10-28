import 'dart:async';

import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Many commands quickly (a held direction, keys hammered, the wheel): nothing on the interface's
/// isolate waits for the disk per input, and the work an input starts is done once, for where
/// the user stops.
void main() {
  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
  });

  testWidgets('moving through the games walks no game folder on the interface; only where the selection rests', (
    tester,
  ) async {
    // Each measurement waits until the test answers it, as a dump of 80,000 files keeps a walk busy.
    final asked = <String, Completer<int>>{};
    final fixture = makeFixture(folderSize: (folder) => (asked[folder] = Completer<int>()).future);
    addTearDown(fixture.dispose);
    final model = fixture.model;
    await pumpLauncher(tester, model);
    final first = model.selectedGame!;
    asked.clear();
    model.sizes.clear();

    for (var press = 0; press < 3; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pump();
    expect(model.selected, 3, reason: 'every press moved at once');
    expect(model.sizes, isEmpty, reason: 'no size was read while the keys were pressed');
    expect(asked.length, 1, reason: 'one walk at a time, not one per game passed');
    final passed = asked.keys.single;

    asked.remove(passed)!.complete(1000);
    await tester.pump();
    expect(asked.keys, [model.selectedGame!.folder], reason: 'then the game the selection rests on');
    asked.remove(model.selectedGame!.folder)!.complete(2000);
    await tester.pump();
    expect(model.sizes[model.selectedGame!.id], 2000);
    expect(first.folder, isNot(model.selectedGame!.folder));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    asked.remove(model.selectedGame!.folder)!.complete(3000);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(asked, isEmpty, reason: 'a game measured once is not walked again');
  });

  group('a screen switched back before its fade ends', () {
    // Faster than any fade (160 to 260 ms): each switch lands while the one before still fades.
    const quick = Duration(milliseconds: 30);

    Future<void> noError(WidgetTester tester, String what) async {
      await tester.pump(quick);
      expect(tester.takeException(), isNull, reason: what);
    }

    testWidgets('the games: their picture and details', (tester) async {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      model.preferences.gameArtwork = true;
      await pumpLauncher(tester, model);
      for (var press = 0; press < 12; press++) {
        await tester.sendKeyEvent(press.isEven ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft);
        await noError(tester, 'press $press: a game passed and come back to while its copy still fades');
      }
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(ValueKey(model.selectedGame!.id)), findsWidgets);
    });

    testWidgets('a layer opened, closed and opened again; a toast said again', (tester) async {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      for (var round = 0; round < 4; round++) {
        model.open(Layer.settings);
        await noError(tester, 'settings opened again while closing');
        model.handle(Command.back);
        await noError(tester, 'settings closed again while opening');
      }
      for (final message in ['One', 'Two', 'One', 'Two', 'One']) {
        model.show(message);
        await noError(tester, 'toast "$message" again while it still fades out');
      }
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('the first start\'s steps, forward and back', (tester) async {
      final fixture = makeFixture(onboarded: false);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      for (var round = 0; round < 6; round++) {
        model.onboardingStep = round.isEven ? 1 : 0;
        model.refresh();
        await noError(tester, 'step ${model.onboardingStep} again while it still fades out');
      }
    });
  });
}
