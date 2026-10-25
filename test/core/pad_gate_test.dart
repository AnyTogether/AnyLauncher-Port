import 'package:anyps5_desktop/core/gamepad/pad_gate.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// The pad behind a game: the readers see every controller whichever window is in front, so the
/// gate keeps everything but PS from the launcher then, and what is still held when the launcher
/// comes back stays quiet until it is let go.
void main() {
  late List<PadCommand> commands;
  late PadNavigator navigator;
  late PadGate gate;
  late List<String> logged;
  var front = true;

  setUp(() {
    commands = [];
    logged = [];
    front = true;
    navigator = PadNavigator(commands.add);
    gate = PadGate(navigator.handle, inFront: () => front, log: logged.add);
  });
  tearDown(() => navigator.dispose());

  PadButtonEvent down(PadButton button, [String pad = 'a']) => PadButtonEvent(pad, button, down: true);
  PadButtonEvent up(PadButton button, [String pad = 'a']) => PadButtonEvent(pad, button, down: false);
  void press(PadButton button, [String pad = 'a']) => gate
    ..handle(down(button, pad))
    ..handle(up(button, pad));

  test('in front, everything gets through', () {
    press(PadButton.south);
    press(PadButton.dpadDown);
    press(PadButton.guide);
    expect(commands, [PadCommand.select, PadCommand.down, PadCommand.home]);
    expect(gate.open, isTrue);
  });

  test('with a game (or any other window) in front, only PS gets through', () {
    front = false;
    for (final button in PadButton.values.where((button) => button != PadButton.guide)) {
      press(button);
    }
    gate
      ..handle(const PadAxisEvent('a', PadAxis.leftX, 1))
      ..handle(const PadAxisEvent('a', PadAxis.leftX, 0));
    expect(commands, isEmpty, reason: 'Cross in the game is not Cross in the launcher');
    press(PadButton.guide);
    expect(commands, [PadCommand.home], reason: 'PS brings the launcher in front');
    expect(gate.open, isFalse);
    expect(logged, contains('pad: south ignored, launcher not in front'));
  });

  test('a direction held in the launcher stops when a game comes in front', () {
    fakeAsync((async) {
      gate.handle(down(PadButton.dpadDown));
      async.elapse(const Duration(milliseconds: 500));
      final moved = commands.length;
      expect(moved, greaterThan(1), reason: 'the hold repeats');
      front = false;
      gate.close();
      async.elapse(const Duration(seconds: 1));
      expect(commands.length, moved, reason: 'nothing repeats behind the game');
      expect(navigator.held, isNull);
    });
  });

  test('a press that went down behind the game does nothing when let go in front', () {
    front = false;
    gate.handle(down(PadButton.south));
    front = true;
    gate.handle(up(PadButton.south));
    expect(commands, isEmpty);
    press(PadButton.south);
    expect(commands, [PadCommand.select], reason: 'the next press counts');
  });

  test('PS from the game: it comes back, and letting go of it does not act again', () {
    front = false;
    gate.handle(down(PadButton.guide));
    expect(commands, [PadCommand.home]);
    // The launcher came in front with PS still held, and Cross held from the game.
    front = true;
    gate.handle(const PadAxisEvent('a', PadAxis.leftX, 0.01));
    expect(gate.waitingForRelease('a'), {PadButton.guide});
    gate.handle(up(PadButton.guide));
    expect(gate.waitingForRelease('a'), isEmpty);
    press(PadButton.guide);
    expect(commands, [PadCommand.home, PadCommand.home], reason: 'PS works again after it was let go');
  });

  test('buttons held from the game wait to be let go when the launcher comes back', () {
    front = false;
    gate
      ..handle(down(PadButton.south))
      ..handle(down(PadButton.dpadUp));
    front = true;
    gate.handle(const PadAxisEvent('a', PadAxis.leftY, 0));
    expect(gate.waitingForRelease('a'), {PadButton.south, PadButton.dpadUp});
    expect(commands, isEmpty, reason: 'nothing held from the game acts in the launcher');
    gate
      ..handle(up(PadButton.south))
      ..handle(up(PadButton.dpadUp));
    expect(commands, isEmpty);
    press(PadButton.dpadUp);
    expect(commands, [PadCommand.up]);
  });

  test('a stick still pushed when the launcher comes back moves nothing until it is let go', () {
    front = false;
    gate.handle(const PadAxisEvent('a', PadAxis.leftY, 0.9));
    front = true;
    gate.handle(const PadAxisEvent('a', PadAxis.leftY, 0.92));
    expect(gate.stickWaiting('a'), isTrue);
    expect(commands, isEmpty);
    gate.handle(const PadAxisEvent('a', PadAxis.leftY, 0.1));
    expect(gate.stickWaiting('a'), isFalse);
    expect(commands, isEmpty);
    gate.handle(const PadAxisEvent('a', PadAxis.leftY, 0.9));
    expect(commands, [PadCommand.down], reason: 'pushed again, it moves');
  });

  test('a pad that goes away behind the game is forgotten', () {
    front = false;
    gate
      ..handle(down(PadButton.south))
      ..handle(const PadGone('a'));
    front = true;
    press(PadButton.south);
    expect(commands, [PadCommand.select]);
  });
}
