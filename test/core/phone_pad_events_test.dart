import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/remote/browser_pad_input.dart';
import 'package:anyps5_desktop/core/remote/phone_pad_events.dart';
import 'package:flutter_test/flutter_test.dart';

/// A phone's pad packets as controller events for the launcher's navigator: what changed from
/// one packet to the next, once.
void main() {
  late List<String> said;
  late PhonePadEvents events;
  var sequence = 0;

  List<int> packet({int buttons = 0, List<int>? sticks}) =>
      BrowserPadState(buttons: buttons, sticks: sticks).packet(sequence: ++sequence, sentMicros: 0, session: 7);

  setUp(() {
    said = [];
    events = PhonePadEvents((event) => said.add(event is PadGone ? 'PadGone(${event.pad})' : event.toString()));
  });

  test('a button pressed and let go is said once each, however often the pad repeats itself', () {
    events.packet('pixel', packet());
    expect(said, isEmpty, reason: 'a pad at rest says nothing');
    events.packet('pixel', packet(buttons: PadBits.cross));
    events.packet('pixel', packet(buttons: PadBits.cross));
    events.packet('pixel', packet(buttons: PadBits.cross | PadBits.right));
    events.packet('pixel', packet());
    expect(said, [
      'PadButtonEvent(phone:pixel, PadButton.south, down)',
      'PadButtonEvent(phone:pixel, PadButton.dpadRight, down)',
      'PadButtonEvent(phone:pixel, PadButton.south, up)',
      'PadButtonEvent(phone:pixel, PadButton.dpadRight, up)',
    ]);
  });

  test('Circle, Triangle, Options, L1 and R1 are the navigator\'s buttons; the left stick its axes', () {
    events.packet(
      'pixel',
      packet(buttons: PadBits.circle | PadBits.triangle | PadBits.options | PadBits.l1 | PadBits.r1),
    );
    expect(said, [
      'PadButtonEvent(phone:pixel, PadButton.east, down)',
      'PadButtonEvent(phone:pixel, PadButton.north, down)',
      'PadButtonEvent(phone:pixel, PadButton.l1, down)',
      'PadButtonEvent(phone:pixel, PadButton.r1, down)',
      'PadButtonEvent(phone:pixel, PadButton.start, down)',
    ]);
    said.clear();
    events.packet(
      'pixel',
      packet(
        buttons: PadBits.circle | PadBits.triangle | PadBits.options | PadBits.l1 | PadBits.r1,
        sticks: [255, 0, 128, 128],
      ),
    );
    expect(said, ['PadAxisEvent(phone:pixel, PadAxis.leftX, 1.0)', 'PadAxisEvent(phone:pixel, PadAxis.leftY, -1.0)']);
  });

  test('two phones are two pads; one that leaves lets go of what it held; not a packet, nothing', () {
    events.packet('a', packet(buttons: PadBits.cross));
    events.packet('b', packet(buttons: PadBits.cross));
    events.gone('a');
    events.gone('a');
    events.packet('b', [1, 2, 3]);
    expect(said, [
      'PadButtonEvent(phone:a, PadButton.south, down)',
      'PadButtonEvent(phone:b, PadButton.south, down)',
      'PadGone(phone:a)',
    ]);
  });
}
