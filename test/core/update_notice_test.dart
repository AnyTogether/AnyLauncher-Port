import 'package:anyps5_desktop/core/update_notice.dart';
import 'package:test/test.dart';

void main() {
  final noon = DateTime.utc(2026, 10, 25, 12);

  test('the state About shows', () {
    expect(LauncherUpdateState.of(checking: false), const UpdateIdle());
    expect(LauncherUpdateState.of(checking: true), const UpdateChecking());
    expect(LauncherUpdateState.of(checking: false, lastCheck: noon), UpdateCurrent(noon));
    expect(LauncherUpdateState.of(checking: false, lastCheck: noon, failed: true), const UpdateCheckFailed());
    expect(LauncherUpdateState.of(checking: false, newer: '0.1.6', lastCheck: noon), const UpdateAvailable('0.1.6'));
    expect(
      LauncherUpdateState.of(checking: false, newer: '0.1.6', progress: 0.42),
      const UpdateDownloading('0.1.6', 0.42),
    );
    expect(LauncherUpdateState.of(checking: false, newer: '0.1.6', ready: '0.1.6'), const UpdateReady('0.1.6'));
  });

  test('a ready update wins over another check, a download over the check', () {
    expect(LauncherUpdateState.of(checking: true, newer: '0.1.6', ready: '0.1.6'), const UpdateReady('0.1.6'));
    expect(
      LauncherUpdateState.of(checking: false, newer: '0.1.6', ready: '0.1.6', failed: true),
      const UpdateReady('0.1.6'),
    );
    expect(
      LauncherUpdateState.of(checking: true, newer: '0.1.6', progress: 0.5),
      const UpdateDownloading('0.1.6', 0.5),
    );
  });

  test('the percent shown', () {
    expect(const UpdateDownloading('1', 0.423).percent, 42);
    expect(const UpdateDownloading('1', 1.4).percent, 100);
    expect(const UpdateDownloading('1', -1).percent, 0);
  });

  test('the notice shows only for a ready update, until Later', () {
    final notice = UpdateNotice();
    for (final state in <LauncherUpdateState>[
      const UpdateIdle(),
      const UpdateChecking(),
      UpdateCurrent(noon),
      const UpdateCheckFailed(),
      const UpdateAvailable('0.1.6'),
      const UpdateDownloading('0.1.6', 0.9),
    ]) {
      expect(notice.shows(state), isFalse, reason: '$state');
    }
    expect(notice.shows(const UpdateReady('0.1.6')), isTrue);
    notice.later(const UpdateReady('0.1.6'));
    expect(
      notice.shows(const UpdateReady('0.1.6')),
      isFalse,
      reason: 'Later: no nagging, it goes in at the next launch',
    );
    expect(notice.shows(const UpdateReady('0.1.7')), isTrue, reason: 'a newer one ready is news once');
    notice.later(const UpdateChecking());
    expect(notice.shows(const UpdateReady('0.1.7')), isTrue);
  });

  test('Restart Now never interrupts a game', () {
    expect(UpdateRestart.decide(gameRunning: false), UpdateRestart.now);
    expect(UpdateRestart.decide(gameRunning: true), UpdateRestart.afterGame);
  });

  test('how this copy puts an update in place', () {
    expect(
      SelfApply.of(windows: true, appImage: false, file: r'C:\x\AnyPS5-Desktop-Setup-0.1.6-x64.exe'),
      SelfApply.installer,
    );
    expect(
      SelfApply.of(windows: false, appImage: true, file: '/tmp/AnyPS5-Desktop-0.1.6-x86_64.AppImage'),
      SelfApply.appImage,
    );
    expect(
      SelfApply.of(windows: false, appImage: false, file: '/tmp/AnyPS5-Desktop-linux-x64.tar.gz'),
      SelfApply.manual,
    );
    expect(SelfApply.installerArguments, contains('/VERYSILENT'));
    expect(SelfApply.installerArguments, contains('/relaunch=1'));
  });
}
