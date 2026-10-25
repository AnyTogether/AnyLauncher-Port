import 'dart:async';

import 'family_rules.dart';

/// What the play-time session says while a game runs.
enum PlayTimeEvent {
  /// About 10 minutes left (or less, at the start).
  warnTen,

  /// A minute left.
  warnOne,

  /// The time is up: the big notice (and the parents told, when they asked).
  reached,

  /// The grace period is over: close the game gently, so it can save.
  close,

  /// Still running a while after the gentle close: end it.
  kill,
}

/// The rules at one moment: the time left and what happens when it is up.
class PlayTimeCheck {
  const PlayTimeCheck({
    required this.remainingSeconds,
    required this.allowed,
    required this.action,
    required this.graceMinutes,
  });

  factory PlayTimeCheck.of(Allowance allowance, PlayTime playTime) => PlayTimeCheck(
    remainingSeconds: allowance.remainingSeconds,
    allowed: allowance.allowed,
    action: playTime.whenLimitReached,
    graceMinutes: playTime.graceMinutes,
  );

  /// null: no end today.
  final int? remainingSeconds;
  final bool allowed;
  final LimitAction action;
  final int graceMinutes;
}

/// Watches the play time of the running game: every tick it asks [check] for the rules now (so
/// midnight, a window's edge, extra time or new limits are followed), warns at 10 minutes and 1
/// minute left, then at 0 says so; with "close", after the grace period it asks for a gentle
/// close, and for the kill only [killAfter] later. Pure: the clock and the timer are given.
class PlayTimeSession {
  PlayTimeSession({
    required this.check,
    required this.onEvent,
    DateTime Function()? now,
    this.every = const Duration(seconds: 1),
  }) : now = now ?? DateTime.now;

  /// The rules at a moment; null when no limit applies.
  final PlayTimeCheck? Function(DateTime now) check;
  final void Function(PlayTimeEvent event, int? remainingSeconds) onEvent;
  final DateTime Function() now;
  final Duration every;

  /// Between the gentle close and the kill.
  static const killAfter = Duration(seconds: 30);

  static const tenMinutes = 600;
  static const oneMinute = 60;

  Timer? _timer;
  bool _warnedTen = false;
  bool _warnedOne = false;
  DateTime? _reachedAt;
  DateTime? _closedAt;
  bool _killed = false;

  bool get running => _timer != null;

  /// Whether the time is up (the notice was given).
  bool get reached => _reachedAt != null;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => tick());
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void tick() {
    final at = now();
    final rules = check(at);
    final remaining = rules?.remainingSeconds;
    if (rules == null || (rules.allowed && remaining == null)) {
      _reset();
      return;
    }
    if (rules.allowed) {
      // More time came (or the day changed): no close, and the warnings can come again.
      _reachedAt = null;
      _closedAt = null;
      _killed = false;
      if (remaining! > tenMinutes) _warnedTen = false;
      if (remaining > oneMinute) _warnedOne = false;
      if (remaining <= oneMinute && !_warnedOne) {
        _warnedOne = _warnedTen = true;
        onEvent(PlayTimeEvent.warnOne, remaining);
      } else if (remaining <= tenMinutes && !_warnedTen) {
        _warnedTen = true;
        onEvent(PlayTimeEvent.warnTen, remaining);
      }
      return;
    }
    if (_reachedAt == null) {
      _reachedAt = at;
      _warnedTen = _warnedOne = true;
      onEvent(PlayTimeEvent.reached, 0);
    }
    if (rules.action != LimitAction.close) return;
    final closeAt = _reachedAt!.add(Duration(minutes: rules.graceMinutes));
    if (_closedAt == null && !at.isBefore(closeAt)) {
      _closedAt = at;
      onEvent(PlayTimeEvent.close, 0);
    }
    if (_closedAt != null && !_killed && !at.isBefore(_closedAt!.add(killAfter))) {
      _killed = true;
      onEvent(PlayTimeEvent.kill, 0);
    }
  }

  void _reset() {
    _warnedTen = _warnedOne = false;
    _reachedAt = _closedAt = null;
    _killed = false;
  }
}
