import 'package:anyps5_desktop/ui/background.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop, FakePads;

/// The launcher draws nothing it does not have to: its background moves on a timer at a few
/// steps a second, and stops asking for frames when paused, behind a game or another window.
void main() {
  /// How many times the background drew a new step in [span] (a new painter each step).
  Future<int> framesIn(WidgetTester tester, Duration span) async {
    CustomPainter? painter() => tester
        .widget<CustomPaint>(find.descendant(of: find.byType(ThemeBackground), matching: find.byType(CustomPaint)))
        .painter;
    var steps = 0;
    var last = painter();
    final end = tester.binding.clock.now().add(span);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 5));
      final now = painter();
      if (!identical(now, last)) steps++;
      last = now;
    }
    return steps;
  }

  Widget background({required bool tickers, bool paused = false, LookStyle style = LookStyle.cosmic}) => TickerMode(
    enabled: tickers,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: ThemeBackground(style: style, paused: paused),
    ),
  );

  testWidgets('moving, the background asks for 30 steps a second (Glass 20), not one per refresh', (tester) async {
    await tester.runAsync(ThemeBackground.preload);
    await tester.pumpWidget(background(tickers: true));
    final cosmic = await framesIn(tester, const Duration(seconds: 1));
    expect(cosmic, inInclusiveRange(28, 31));
    await tester.pumpWidget(background(tickers: true, style: LookStyle.glass));
    final glass = await framesIn(tester, const Duration(seconds: 1));
    expect(glass, inInclusiveRange(18, 21));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('paused, or with tickers muted above it, it asks for no frame at all', (tester) async {
    await tester.runAsync(ThemeBackground.preload);
    await tester.pumpWidget(background(tickers: true, paused: true));
    expect(await framesIn(tester, const Duration(seconds: 1)), 0);
    await tester.pumpWidget(background(tickers: false));
    expect(await framesIn(tester, const Duration(seconds: 1)), 0, reason: 'a muted TickerMode is a still background');
    await tester.pumpWidget(background(tickers: true));
    expect(
      await framesIn(tester, const Duration(milliseconds: 500)),
      greaterThan(10),
      reason: 'unmuted it moves again',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('behind a game the whole launcher rests: tickers muted, the background still', (tester) async {
    final desktop = FakeDesktop();
    final fixture = makeFixture(desktop: desktop, pads: FakePads.new);
    addTearDown(fixture.dispose);
    final model = fixture.model;
    await pumpLauncher(tester, model);
    bool tickersOn() => TickerMode.valuesOf(tester.element(find.byType(ThemeBackground))).enabled;
    expect(model.resting, isFalse);
    expect(tickersOn(), isTrue);
    desktop.focused = false;
    await tester.pump(const Duration(milliseconds: 450));
    expect(model.resting, isTrue, reason: 'the shell looks at the desktop a few times a second');
    await tester.pump();
    expect(tickersOn(), isFalse);
    desktop.focused = true;
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(model.resting, isFalse);
    expect(tickersOn(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
