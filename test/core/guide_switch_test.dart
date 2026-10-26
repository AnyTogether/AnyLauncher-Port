import 'package:anyps5_desktop/core/gamepad/guide_switch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Duration ms(int value) => Duration(milliseconds: value);

  test('with a game: game in front → launcher, launcher in front → game, and so on', () {
    final guide = GuideSwitch();
    expect(guide.press(now: ms(0), gameRunning: true, launcherInFront: false), GuideAction.showLauncher);
    expect(guide.press(now: ms(1000), gameRunning: true, launcherInFront: true), GuideAction.showGame);
    expect(guide.press(now: ms(2000), gameRunning: true, launcherInFront: false), GuideAction.showLauncher);
    expect(guide.press(now: ms(3000), gameRunning: true, launcherInFront: true), GuideAction.showGame);
  });

  test('one press is one switch: a second press (or the same one read twice) right after does nothing', () {
    final guide = GuideSwitch();
    expect(guide.press(now: ms(0), gameRunning: true, launcherInFront: true), GuideAction.showGame);
    // The game is in front now; the same press seen again must not bring the launcher straight back.
    expect(guide.press(now: ms(16), gameRunning: true, launcherInFront: false), GuideAction.none);
    expect(guide.press(now: ms(400), gameRunning: true, launcherInFront: false), GuideAction.none);
    expect(
      guide.press(now: GuideSwitch.defaultDebounce, gameRunning: true, launcherInFront: false),
      GuideAction.showLauncher,
    );
  });

  test('without a game: behind another window → launcher; in front it closes a layer', () {
    final guide = GuideSwitch();
    expect(guide.press(now: ms(0), gameRunning: false, launcherInFront: false), GuideAction.showLauncher);
    expect(
      guide.press(now: ms(1000), gameRunning: false, launcherInFront: true, layerOpen: true),
      GuideAction.closeLayer,
    );
    expect(
      guide.press(now: ms(1100), gameRunning: false, launcherInFront: true, layerOpen: true),
      GuideAction.closeLayer,
      reason: 'closing a layer is not a switch of windows: no wait after it',
    );
    expect(guide.press(now: ms(1200), gameRunning: false, launcherInFront: true), GuideAction.none);
  });

  test('a clock that went backwards (a new stopwatch) never locks PS out', () {
    final guide = GuideSwitch();
    guide.press(now: ms(5000), gameRunning: true, launcherInFront: false);
    expect(guide.press(now: ms(10), gameRunning: true, launcherInFront: true), GuideAction.showGame);
  });
}
