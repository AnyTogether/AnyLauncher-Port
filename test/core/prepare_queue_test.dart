import 'dart:io';

import 'package:anyps5_desktop/core/power.dart';
import 'package:anyps5_desktop/core/prepare_queue.dart';
import 'package:anyps5_desktop/core/unlock_space.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Preparing new games in the background, like a console installing: one at a time, only while
/// nothing else needs the computer, never on a low battery or a drive without the room.
void main() {
  /// Every action until the queue has nothing more to do.
  List<PrepareAction> drain(
    PrepareQueue queue,
    PrepareConditions conditions, {
    SpaceShortage? Function(String)? shortage,
  }) {
    final actions = <PrepareAction>[];
    while (true) {
      final action = queue.step(conditions, shortage: shortage ?? (_) => null);
      if (action is PrepareNone) return actions;
      actions.add(action);
      if (actions.length > 20) fail('the queue does not settle');
    }
  }

  const playing = PrepareConditions(playing: true);
  const unlocking = PrepareConditions(unlocking: true);

  test('a new game is prepared at once when nothing else happens', () {
    final queue = PrepareQueue()..add(['a']);
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(queue.active, 'a');
    expect(queue.pending, isEmpty);
  });

  test('one at a time, in the order they came', () {
    final queue = PrepareQueue()
      ..add(['a', 'b'])
      ..add(['a', 'c']);
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(queue.pending, ['b', 'c']);
    queue.finished('a');
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('b')]);
    queue.finished('b');
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('c')]);
    queue.finished('c');
    expect(drain(queue, PrepareConditions.idle), isEmpty);
    expect(queue.active, isNull);
  });

  test('a game running holds the queue and pauses the preparation until it closes', () {
    final queue = PrepareQueue()..add(['a']);
    expect(drain(queue, playing), isEmpty);
    expect(queue.pending, ['a'], reason: 'waits, not skipped');
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(drain(queue, playing), [const PreparePause()]);
    expect(queue.paused, isTrue);
    expect(drain(queue, playing), isEmpty, reason: 'paused once');
    expect(drain(queue, PrepareConditions.idle), [const PrepareResume()]);
    expect(queue.paused, isFalse);
  });

  test("the user's own unlocks come first", () {
    final queue = PrepareQueue()..add(['a', 'b']);
    expect(drain(queue, unlocking), isEmpty);
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(drain(queue, unlocking), [const PreparePause()]);
    expect(drain(queue, PrepareConditions.idle), [const PrepareResume()]);
  });

  test("a promoted preparation does not stop for the user's unlocks", () {
    final queue = PrepareQueue()..add(['a']);
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(drain(queue, unlocking), [const PreparePause()]);
    queue.promote('a');
    expect(drain(queue, unlocking), [const PrepareResume()]);
    queue.finished('a');
    expect(queue.promoted, isFalse);
  });

  test('on a low battery new games are skipped', () {
    final queue = PrepareQueue()..add(['a', 'b']);
    const battery = PrepareConditions(power: PowerState(onBattery: true, level: 22));
    expect(drain(queue, battery), [
      const PrepareSkipped('a', BatteryLow(22)),
      const PrepareSkipped('b', BatteryLow(22)),
    ]);
    expect(queue.pending, isEmpty);
    expect(queue.active, isNull);
  });

  test('plugged in, or a battery at 30 % or more, goes ahead', () {
    final queue = PrepareQueue()..add(['a']);
    expect(drain(queue, const PrepareConditions(power: PowerState(onBattery: true, level: 30))), [
      const PrepareStart('a'),
    ]);
    queue
      ..finished('a')
      ..add(['b']);
    expect(drain(queue, const PrepareConditions(power: PowerState(onBattery: false, level: 5))), [
      const PrepareStart('b'),
    ]);
  });

  test('a battery that does not say its level counts as low', () {
    expect(const PowerState(onBattery: true).low, isTrue);
    expect(PowerState.mains.low, isFalse);
  });

  test('unplugged below the line while preparing: it stops until plugged in', () {
    final queue = PrepareQueue()..add(['a']);
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(drain(queue, const PrepareConditions(power: PowerState(onBattery: true, level: 10))), [
      const PreparePause(),
    ]);
    expect(drain(queue, PrepareConditions.idle), [const PrepareResume()]);
  });

  test('a game without the room is skipped with the shortage', () {
    final queue = PrepareQueue()..add(['big', 'small']);
    const shortage = SpaceShortage(needed: 10 << 30, free: 2 << 30, folder: '/games', copying: false);
    expect(drain(queue, PrepareConditions.idle, shortage: (id) => id == 'big' ? shortage : null), [
      const PrepareSkipped('big', SpaceShort(shortage)),
      const PrepareStart('small'),
    ]);
    expect(queue.active, 'small');
  });

  test('cancel takes a game out of the queue', () {
    final queue = PrepareQueue()..add(['a', 'b', 'c']);
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(queue.cancel('b'), isFalse, reason: 'b was only waiting');
    expect(queue.pending, ['c']);
    expect(queue.cancel('a'), isTrue, reason: 'a is being prepared: its installer must be stopped');
    expect(queue.active, 'a', reason: 'until the installer says it stopped');
    queue.finished('a');
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('c')]);
  });

  test('turned off: nothing more starts, what is going on finishes', () {
    final queue = PrepareQueue()..add(['a', 'b']);
    expect(drain(queue, PrepareConditions.idle), [const PrepareStart('a')]);
    expect(drain(queue, const PrepareConditions(enabled: false)), isEmpty);
    expect(queue.pending, isEmpty);
    expect(queue.active, 'a');
  });

  group('power', () {
    late Directory temp;
    setUp(() => temp = temporaryFolder('power'));
    tearDown(() => temp.deleteSync(recursive: true));

    void supply(String name, Map<String, String> files) {
      for (final entry in files.entries) {
        File(p.join(temp.path, name, entry.key))
          ..createSync(recursive: true)
          ..writeAsStringSync('${entry.value}\n');
      }
    }

    test('a laptop on its battery', () {
      supply('AC', {'type': 'Mains', 'online': '0'});
      supply('BAT0', {'type': 'Battery', 'status': 'Discharging', 'capacity': '24'});
      expect(Power.fromSysfs(temp.path), const PowerState(onBattery: true, level: 24));
    });

    test('plugged in, charging', () {
      supply('AC', {'type': 'Mains', 'online': '1'});
      supply('BAT0', {'type': 'Battery', 'status': 'Charging', 'capacity': '12'});
      expect(Power.fromSysfs(temp.path).onBattery, isFalse);
    });

    test("a controller's battery is not the computer's; a desktop has none", () {
      supply('hidpp_battery_0', {'type': 'Battery', 'status': 'Discharging', 'capacity': '5', 'scope': 'Device'});
      expect(Power.fromSysfs(temp.path).onBattery, isFalse);
      expect(Power.fromSysfs(p.join(temp.path, 'missing')), PowerState.mains);
    });

    test('Windows: GetSystemPowerStatus', () {
      expect(
        Power.fromWindowsStatus(acLine: 0, batteryFlag: 0, percent: 18),
        const PowerState(onBattery: true, level: 18),
      );
      expect(Power.fromWindowsStatus(acLine: 1, batteryFlag: 8, percent: 18).onBattery, isFalse);
      expect(
        Power.fromWindowsStatus(acLine: 0, batteryFlag: 128, percent: 255),
        PowerState.mains,
        reason: 'no battery',
      );
      expect(Power.fromWindowsStatus(acLine: 0, batteryFlag: 0, percent: 255).low, isTrue);
    });
  });
}
