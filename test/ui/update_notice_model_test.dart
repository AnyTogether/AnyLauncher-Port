import 'dart:io';

import 'package:anyps5_desktop/core/app_update.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/update_notice.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart' show launcherVersion;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';
import '../support/ui_support.dart';

/// The launcher's own update as the player meets it: found and downloaded quietly, the notice
/// with Restart Now and Later, Later for the next launch, About's states. (The screens are in
/// update_notice_screens_test.dart: a file with widget tests gets no real HTTP.)
void main() {
  // Always newer than the launcher, whatever version it is (and the same in the goldens).
  const newer = '9.0.0';
  final key = TestReleaseKey('desktop release');
  late FakeGitHub github;
  Fixture? fixture;
  final started = <(String, List<String>)>[];
  final quits = <int>[];

  FakeRelease release(String version) => FakeRelease('v$version', {
    'AnyPS5-Desktop-Setup-$version-x64.exe': [0x4D, 0x5A, ...filler('setup$version')],
    'AnyPS5-Desktop-$version-x86_64.AppImage': filler('appimage$version'),
    'AnyPS5-Desktop-linux-x64.tar.gz': filler('tar$version'),
  });

  setUp(() async {
    github = await FakeGitHub.start(repository: LauncherUpdates.repository);
    github.releases.add(signed(release(newer), [key]));
    started.clear();
    quits.clear();
  });

  tearDown(() async {
    fixture?.model.dispose();
    fixture?.dispose();
    fixture = null;
    T.language = Language.english;
    await github.close();
  });

  AppModel launcher({HostSystem system = HostSystem.windows, Map<String, String> environment = const {}}) {
    fixture = makeFixture(
      system: system,
      environment: environment,
      launcherReleases: LauncherUpdates.source(api: github.api, keys: [key.key]),
      startDetached: (executable, arguments) async => started.add((executable, arguments)),
      quit: quits.add,
    );
    return fixture!.model;
  }

  group('model', () {
    test('a newer release is downloaded quietly, then the notice offers Restart Now', () async {
      final model = launcher();
      await model.updates.startupCheck();
      expect(model.updates.state, const UpdateReady(newer));
      expect(model.updates.showsNotice, isTrue);
      expect(model.toast, isNull, reason: 'no toast, no progress: the notice says it once it is ready');
      await model.updates.restartNow();
      expect(started.single.$1, endsWith('AnyPS5-Desktop-Setup-$newer-x64.exe'));
      expect(started.single.$2, SelfApply.installerArguments);
      expect(quits, [0]);
    });

    test('Later: no nagging, and the installer runs at the next launch, once', () async {
      final model = launcher();
      await model.updates.startupCheck();
      model.updates.later();
      expect(model.updates.showsNotice, isFalse);
      await model.updates.periodicCheck();
      expect(model.updates.showsNotice, isFalse, reason: 'the next check does not bring it back');
      expect(started, isEmpty);
      expect(await model.updates.applyPendingAtLaunch(), isTrue);
      expect(started.single.$1, endsWith('AnyPS5-Desktop-Setup-$newer-x64.exe'));
      expect(await model.updates.applyPendingAtLaunch(), isFalse, reason: 'once');
    });

    test('an installer changed after it was checked is never run', () async {
      final model = launcher();
      await model.updates.startupCheck();
      model.updates.later();
      File(model.updates.downloaded!).writeAsBytesSync([1, 2, 3]);
      expect(await model.updates.applyPendingAtLaunch(), isFalse);
      expect(started, isEmpty);
    });

    test('Restart Now with a game starting waits for it', () async {
      final model = launcher();
      await model.updates.startupCheck();
      model.starting = model.games.first;
      await model.updates.restartNow();
      expect(model.updates.restartAfterGame, isTrue);
      expect(started, isEmpty);
      expect(model.updates.showsNotice, isTrue, reason: 'the notice says it restarts when the game closes');
      model.updates.cancelRestart();
      expect(model.updates.restartAfterGame, isFalse);
      model.starting = null;
    });

    test('an AppImage is swapped for the new one: now for Restart Now, kept for the next start on Later', () async {
      final temp = temporaryFolder('appimage');
      addTearDown(() => temp.deleteSync(recursive: true));
      final appImage = p.join(temp.path, 'AnyPS5-Desktop.AppImage');
      File(appImage).writeAsBytesSync([0]);
      final model = launcher(system: HostSystem.linux, environment: {'APPIMAGE': appImage});
      await model.updates.startupCheck();
      expect(model.updates.apply, SelfApply.appImage);
      model.updates.later();
      expect(File(appImage).readAsBytesSync(), filler('appimage$newer'));
      expect(started, isEmpty, reason: 'Later starts nothing');
    }, skip: Platform.isWindows ? 'chmod' : false);

    test('an archive is the user\'s to put in place: Show File', () async {
      final model = launcher(system: HostSystem.linux);
      await model.updates.startupCheck();
      expect(model.updates.apply, SelfApply.manual);
      await model.updates.restartNow();
      expect(started, isEmpty);
      expect(quits, isEmpty);
    });

    test('back in front after half an hour it asks again; sooner it does not', () async {
      final model = launcher();
      await model.updates.startupCheck();
      final asked = github.requests.length;
      model.updates.activated();
      expect(model.updates.checking, isFalse);
      model.updates.lastCheck = DateTime.now().subtract(const Duration(minutes: 31));
      model.updates.activated();
      expect(model.updates.checking, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(github.requests.length, greaterThan(asked));
    });

    test('About shows where it stands', () async {
      final model = launcher();
      expect(model.updates.aboutRows().map((row) => row.detail), [
        T.format('desktopVersion', [launcherVersion]),
      ]);
      await model.updates.startupCheck();
      final rows = model.updates.aboutRows();
      expect(rows.first.title, 'AnyPS5 Desktop $newer is ready · Restart Now');
      expect(rows.first.detail, 'Restart now, or it goes in at the next launch');
    });
  });
}
