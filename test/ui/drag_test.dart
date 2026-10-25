import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Lists and the mouse: a hover may move the focus but never scrolls (the list used to chase the
/// pointer); the wheel scrolls, and so does a drag with the left button held, which glides on
/// when let go fast and never clicks the row it started on; a click that wobbles a few pixels
/// still clicks.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
  });

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    fixture.dispose();
  });

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  GameSettings settings() => model.currentSettings(orbit());

  Future<void> openGameSettings(WidgetTester tester) async {
    model.select(model.games.indexOf(orbit()));
    model.open(Layer.gameSettings);
    await pumpLauncher(tester, model);
  }

  Finder row(String id) => find.byKey(ValueKey('row-$id'));

  ScrollPosition rowsList(WidgetTester tester) =>
      tester.state<ScrollableState>(find.ancestor(of: row('vsync'), matching: find.byType(Scrollable)).first).position;

  Rect viewport(WidgetTester tester) =>
      tester.getRect(find.ancestor(of: row('vsync'), matching: find.byType(Scrollable)).first);

  Future<TestGesture> mouse(WidgetTester tester, {int pointer = 7}) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: pointer);
    await gesture.addPointer(location: const Offset(1, 1));
    addTearDown(gesture.removePointer);
    return gesture;
  }

  // A test mouse is device 1, whatever its pointer number.
  MouseCursor cursor(int device) => RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(device)!;

  testWidgets('the game settings are longer than the panel (what the other tests drag)', (tester) async {
    await openGameSettings(tester);
    expect(rowsList(tester).maxScrollExtent, greaterThan(100));
  });

  testWidgets('moving the mouse over the rows focuses them but never scrolls the list', (tester) async {
    await openGameSettings(tester);
    final list = rowsList(tester);
    final view = viewport(tester);
    final rows = model.panelCategories().single.rows;
    // The last row the panel shows only in part: hovering it used to scroll it to the middle,
    // which slid the next row under the pointer, and so on down the list.
    final cut = rows.indexWhere((candidate) {
      final finder = row(candidate.id);
      if (finder.evaluate().isEmpty || !candidate.focusable) return false;
      final rect = tester.getRect(finder);
      return rect.top < view.bottom - 8 && rect.bottom > view.bottom;
    });
    expect(cut, isNonNegative, reason: 'a row cut by the panel\'s bottom edge');
    final gesture = await mouse(tester);
    await gesture.moveTo(Offset(view.center.dx, view.bottom - 4));
    await settle(tester);
    expect(model.panelRow, cut, reason: 'the focus follows the pointer');
    expect(list.pixels, 0, reason: 'the list stays where it is');
    for (var step = 0; step < 6; step++) {
      await gesture.moveBy(const Offset(0, -2));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await settle(tester);
    expect(list.pixels, 0, reason: 'still put: no row slid under the pointer');
    // The keys move the focus from the hovered row, and the list follows them.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(model.panelRow, greaterThan(cut));
    expect(list.pixels, greaterThan(0), reason: 'the keys scroll the focused row into view');
  });

  testWidgets('the wheel scrolls the list', (tester) async {
    await openGameSettings(tester);
    final list = rowsList(tester);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: viewport(tester).center,
        scrollDelta: const Offset(0, 120),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await settle(tester);
    expect(list.pixels, greaterThan(0));
  });

  testWidgets('a drag with the left button scrolls the list and does not click the row it began on', (tester) async {
    await openGameSettings(tester);
    final list = rowsList(tester);
    final before = settings().toJson().toString();
    final gesture = await mouse(tester);
    // From the bottom of the list, up: the pointer stays over it all along.
    final start = Offset(tester.getCenter(row('vsync')).dx, viewport(tester).bottom - 20);
    await gesture.moveTo(start);
    await settle(tester);
    expect(cursor(1), SystemMouseCursors.click, reason: 'over a row, the row is a button');
    final pressed = model.panelRow;
    await gesture.down(start);
    await tester.pump();
    for (var step = 0; step < 10; step++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(model.panning, isTrue);
    expect(cursor(1), SystemMouseCursors.grabbing, reason: 'a closed hand while dragging');
    expect(list.pixels, greaterThan(150), reason: 'the list follows the pointer');
    await gesture.up();
    await settle(tester);
    expect(settings().toJson().toString(), before, reason: 'letting go after a drag is not a click');
    expect(model.overlay, Layer.gameSettings, reason: 'no row opened anything either');
    expect(model.panelRow, pressed, reason: 'nor does the drag move the focus');
    expect(model.panning, isFalse);
    expect(cursor(1), isNot(SystemMouseCursors.grabbing));
  });

  testWidgets('a click that wobbles less than the drag threshold still clicks', (tester) async {
    await openGameSettings(tester);
    final list = rowsList(tester);
    final vsync = settings().vsync;
    final gesture = await mouse(tester);
    await gesture.down(tester.getCenter(row('vsync')));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -4));
    await tester.pump();
    await gesture.up();
    await settle(tester);
    expect(settings().vsync, !vsync, reason: 'four pixels is a click');
    expect(list.pixels, 0);
  });

  testWidgets('let go fast, the list glides on', (tester) async {
    await openGameSettings(tester);
    final list = rowsList(tester);
    await tester.flingFrom(
      tester.getCenter(row('vsync')),
      const Offset(0, -60),
      1500,
      deviceKind: PointerDeviceKind.mouse,
    );
    final released = list.pixels;
    expect(model.panning, isTrue, reason: 'gliding: rows passing under the pointer make no tick');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(list.pixels, greaterThan(released), reason: 'it carries on after the release');
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(model.panning, isFalse, reason: 'stopped: the tick is back');
  });

  testWidgets('no hover tick while a list is dragged or gliding', (tester) async {
    await openGameSettings(tester);
    model.preferences.sounds = true;
    model.panning = true;
    final before = model.sounds.requests;
    model.hoverArrived('somewhere', x: 10, y: 10, buttonsDown: false);
    model.hoverArrived('elsewhere', x: 200, y: 200, buttonsDown: false);
    expect(model.sounds.requests, before);
    model.panning = false;
    // The tick keeps its distance from other sounds by the clock, not by frames.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    model.hoverArrived('a third place', x: 400, y: 400, buttonsDown: false);
    expect(model.sounds.requests, greaterThan(before), reason: 'after the drag, arrivals tick again');
  });

  testWidgets('dragging the game tiles moves between games, and does not click the tile', (tester) async {
    await pumpLauncher(tester, model);
    model.select(0);
    await settle(tester);
    final first = model.games[0];
    final start = tester.getCenter(find.byKey(ValueKey('tile-press-${first.id}')));
    final gesture = await mouse(tester);
    await gesture.down(start);
    await tester.pump();
    // Two tiles' worth to the left: two games on.
    final step = (118 + 16) * (tester.view.physicalSize.width / 1600);
    for (var moved = 0.0; moved < step * 2 + 10; moved += 10) {
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(model.selected, 2);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await settle(tester);
    expect(model.selected, 2, reason: 'a slow release does not carry on');
    expect(model.stateOf(first), isNot(isA<Running>()));
    expect(model.starting, isNull, reason: 'the drag did not click (or double-click) the tile');
  });
}
