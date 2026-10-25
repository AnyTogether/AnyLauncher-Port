import 'power.dart';
import 'unlock_space.dart';

/// What the background preparation looks at before each step.
class PrepareConditions {
  const PrepareConditions({
    this.enabled = true,
    this.playing = false,
    this.unlocking = false,
    this.power = PowerState.mains,
  });

  /// Nothing in the way.
  static const idle = PrepareConditions();

  /// Settings › Game Library › Prepare New Games Automatically.
  final bool enabled;

  /// A game is starting or running.
  final bool playing;

  /// The user's own unlocks are running or waiting.
  final bool unlocking;
  final PowerState power;

  @override
  bool operator ==(Object other) =>
      other is PrepareConditions &&
      other.enabled == enabled &&
      other.playing == playing &&
      other.unlocking == unlocking &&
      other.power == power;

  @override
  int get hashCode => Object.hash(enabled, playing, unlocking, power);
}

/// Why a new game was not prepared.
sealed class PrepareSkip {
  const PrepareSkip();
}

class BatteryLow extends PrepareSkip {
  const BatteryLow(this.level);
  final int? level;

  @override
  bool operator ==(Object other) => other is BatteryLow && other.level == level;

  @override
  int get hashCode => level.hashCode;
}

class SpaceShort extends PrepareSkip {
  const SpaceShort(this.shortage);
  final SpaceShortage shortage;

  @override
  bool operator ==(Object other) => other is SpaceShort && other.shortage == shortage;

  @override
  int get hashCode => shortage.hashCode;
}

/// What the launcher does next for the background preparation.
sealed class PrepareAction {
  const PrepareAction();
}

/// Nothing to do now.
class PrepareNone extends PrepareAction {
  const PrepareNone();

  @override
  bool operator ==(Object other) => other is PrepareNone;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'none';
}

/// Unlock this game in the background.
class PrepareStart extends PrepareAction {
  const PrepareStart(this.id);
  final String id;

  @override
  bool operator ==(Object other) => other is PrepareStart && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'start($id)';
}

/// Stop the background unlock where it is.
class PreparePause extends PrepareAction {
  const PreparePause();

  @override
  bool operator ==(Object other) => other is PreparePause;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'pause';
}

/// Let it go on.
class PrepareResume extends PrepareAction {
  const PrepareResume();

  @override
  bool operator ==(Object other) => other is PrepareResume;

  @override
  int get hashCode => 2;

  @override
  String toString() => 'resume';
}

/// This game will not be prepared, and why.
class PrepareSkipped extends PrepareAction {
  const PrepareSkipped(this.id, this.reason);
  final String id;
  final PrepareSkip reason;

  @override
  bool operator ==(Object other) => other is PrepareSkipped && other.id == id && other.reason == reason;

  @override
  int get hashCode => Object.hash(id, reason);

  @override
  String toString() => 'skip($id, $reason)';
}

/// New games unlocked in the background like a console installing them: one at a time, only
/// while no game plays and the user's own unlocks are done, never on a low battery, never on a
/// drive without the room. A game started meanwhile stops the preparation where it is until the
/// game closes; the user's own unlock does too, unless they asked to play the game being
/// prepared ([promote]).
///
/// The launcher calls [step] whenever something changed (a scan, a game starting or ending, an
/// unlock done, the power) until it answers [PrepareNone], and does what each answer says.
class PrepareQueue {
  final List<String> _pending = [];

  /// Waiting, in the order they came.
  List<String> get pending => List.unmodifiable(_pending);

  /// Being prepared.
  String? active;
  bool paused = false;

  /// The user asked to play the game being prepared.
  bool promoted = false;

  bool contains(String id) => active == id || _pending.contains(id);

  /// New games from a scan, after those already waiting.
  void add(Iterable<String> ids) {
    for (final id in ids) {
      if (!contains(id)) _pending.add(id);
    }
  }

  /// The next thing to do given [conditions]; [shortage] tells a game's want of room.
  PrepareAction step(PrepareConditions conditions, {required SpaceShortage? Function(String id) shortage}) {
    if (active != null) {
      if (!conditions.enabled) _pending.clear();
      final hold = conditions.playing || conditions.power.low || (conditions.unlocking && !promoted);
      if (hold && !paused) {
        paused = true;
        return const PreparePause();
      }
      if (!hold && paused) {
        paused = false;
        return const PrepareResume();
      }
      return const PrepareNone();
    }
    if (!conditions.enabled) {
      _pending.clear();
      return const PrepareNone();
    }
    if (_pending.isEmpty || conditions.playing || conditions.unlocking) return const PrepareNone();
    final next = _pending.removeAt(0);
    if (conditions.power.low) return PrepareSkipped(next, BatteryLow(conditions.power.level));
    final short = shortage(next);
    if (short != null) return PrepareSkipped(next, SpaceShort(short));
    active = next;
    paused = false;
    promoted = false;
    return PrepareStart(next);
  }

  /// The user wants to play the game being prepared: it stops waiting for their other unlocks.
  void promote(String id) {
    if (active == id) promoted = true;
  }

  /// Takes a game out of the queue; true when it is being prepared, and its unlock must be
  /// stopped (then [finished] follows).
  bool cancel(String id) {
    _pending.remove(id);
    return active == id;
  }

  /// The background unlock of [id] ended, however it ended.
  void finished(String id) {
    if (active != id) return;
    active = null;
    paused = false;
    promoted = false;
  }
}
