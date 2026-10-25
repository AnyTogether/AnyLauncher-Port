import 'package:anyps5_desktop/core/family/family_rules.dart';
import 'package:anyps5_desktop/core/family/play_time_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// A game that started at [start] with [limit] minutes left and the [action] when they run out;
/// [bonus] minutes added on the way, [window] minutes until the window closes.
class Scenario {
  Scenario(this.async, {required this.limit, this.action = LimitAction.close, this.grace = 3});

  final FakeAsync async;
  final int limit;
  LimitAction action;
  final int grace;
  int bonus = 0;
  bool limits = true;
  final start = DateTime.utc(2026, 10, 26, 15);
  final events = <(PlayTimeEvent, int?)>[];

  DateTime now() => start.add(async.elapsed);

  PlayTimeCheck? check(DateTime at) {
    if (!limits) return null;
    final played = at.difference(start).inSeconds;
    final left = (limit + bonus) * 60 - played;
    return PlayTimeCheck(remainingSeconds: left < 0 ? 0 : left, allowed: left > 0, action: action, graceMinutes: grace);
  }

  late final session = PlayTimeSession(
    check: check,
    now: now,
    onEvent: (event, remaining) => events.add((event, remaining)),
  )..start();

  List<PlayTimeEvent> get kinds => [for (final event in events) event.$1];
}

void main() {
  test('warns at 10 and 1 minutes, shows the notice at 0, closes after the grace, kills last', () {
    fakeAsync((async) {
      final game = Scenario(async, limit: 15)..session;
      async.elapse(const Duration(minutes: 4, seconds: 59));
      expect(game.events, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(game.events.single, (PlayTimeEvent.warnTen, 600));
      async.elapse(const Duration(minutes: 9));
      expect(game.events.last, (PlayTimeEvent.warnOne, 60));
      async.elapse(const Duration(minutes: 1));
      expect(game.events.last.$1, PlayTimeEvent.reached);
      // The grace period to save; then a gentle close; the kill only if it is still running.
      async.elapse(const Duration(minutes: 2, seconds: 59));
      expect(game.kinds, [PlayTimeEvent.warnTen, PlayTimeEvent.warnOne, PlayTimeEvent.reached]);
      async.elapse(const Duration(seconds: 1));
      expect(game.kinds.last, PlayTimeEvent.close);
      async.elapse(PlayTimeSession.killAfter - const Duration(seconds: 1));
      expect(game.kinds.last, PlayTimeEvent.close);
      async.elapse(const Duration(seconds: 1));
      expect(game.kinds.last, PlayTimeEvent.kill);
      async.elapse(const Duration(minutes: 10));
      expect(game.kinds, hasLength(5));
      game.session.stop();
    });
  });

  test('"notify": the notice, and the game goes on', () {
    fakeAsync((async) {
      final game = Scenario(async, limit: 2, action: LimitAction.notify)..session;
      async.elapse(const Duration(minutes: 30));
      expect(game.kinds, [PlayTimeEvent.warnTen, PlayTimeEvent.warnOne, PlayTimeEvent.reached]);
      expect(game.events.first.$2, 120);
      game.session.stop();
    });
  });

  test('a game started with less than a minute left warns once, then the notice', () {
    fakeAsync((async) {
      final game = Scenario(async, limit: 1, grace: 0)..session;
      async.elapse(const Duration(seconds: 1));
      expect(game.kinds, [PlayTimeEvent.warnOne]);
      async.elapse(const Duration(seconds: 60));
      expect(game.kinds, [PlayTimeEvent.warnOne, PlayTimeEvent.reached, PlayTimeEvent.close]);
      game.session.stop();
    });
  });

  test('extra time from a parent calls off the close and warns again later', () {
    fakeAsync((async) {
      final game = Scenario(async, limit: 5)..session;
      async.elapse(const Duration(minutes: 5, seconds: 30));
      expect(game.kinds.last, PlayTimeEvent.reached);
      game.bonus = 30;
      async.elapse(const Duration(minutes: 5));
      expect(game.kinds.last, PlayTimeEvent.reached, reason: 'no close while there is time again');
      async.elapse(const Duration(minutes: 19, seconds: 30));
      expect(game.kinds.last, PlayTimeEvent.warnTen);
      game.session.stop();
    });
  });

  test('switching from notify to close mid-game closes after the grace from the notice', () {
    fakeAsync((async) {
      final game = Scenario(async, limit: 1, action: LimitAction.notify)..session;
      async.elapse(const Duration(minutes: 2));
      expect(game.kinds.last, PlayTimeEvent.reached);
      game.action = LimitAction.close;
      async.elapse(const Duration(minutes: 2));
      expect(game.kinds.last, PlayTimeEvent.close);
      game.session.stop();
    });
  });

  test('no limits: nothing happens; stopped: no more ticks', () {
    fakeAsync((async) {
      final game = Scenario(async, limit: 1)..limits = false;
      game.session;
      async.elapse(const Duration(hours: 2));
      expect(game.events, isEmpty);
      game.limits = true;
      game.session.stop();
      async.elapse(const Duration(hours: 2));
      expect(game.events, isEmpty);
      expect(async.periodicTimerCount, 0);
    });
  });
}
