import 'dart:io';

import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_elf.dart';
import '../support/fake_github.dart';
import '../support/ui_support.dart';

/// The AnyPS5 engine downloaded by the launcher itself: onboarding, settings, updates. (The
/// screens are in launcher_test.dart: a file with widget tests gets no real HTTP.)
void main() {
  tearDown(() => T.language = Language.english);

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  group('model', () {
    late FakeGitHub github;
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      github = await FakeGitHub.start();
      fixture = makeFixture(onboarded: false, withToolkit: false, engine: github.api);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await github.close();
      fixture.dispose();
    });

    PanelRow row(String id) => model
        .panelCategories()
        .expand((category) => category.rows)
        .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

    void choose(String id) => (row(id).kind as ActionRow).run();

    Future<void> toToolkitStep() async {
      model.onboardingStep = 2;
      model.onboardingChoice = 1;
      model.onboardingConfirm();
      expect(model.onboardingStep, 3);
      await until(() => !model.engine.checking);
    }

    test('onboarding: the toolkit step finds the newest engine and downloads it', () async {
      github.releases.addAll([upstreamRelease('0.1.3'), upstreamRelease('0.1.2')]);
      expect(model.toolkit, isNull);
      await toToolkitStep();
      expect(model.engine.checkError, isNull);
      expect(model.engine.latest?.tag, 'v0.1.3');
      expect(model.onboardingChoice, 0, reason: 'the download is offered first');
      model.onboardingConfirm();
      expect(model.engine.downloading?.version, '0.1.3');
      await until(() => model.engine.downloading == null);
      final toolkit = model.toolkit!;
      expect(toolkit.version, 'upstream-v0.1.3');
      expect(toolkit.root, p.join(model.paths.toolkits, '0.1.3'));
      expect(model.preferences.toolkitFolder, toolkit.root);
      expect(model.onboardingChoice, 2, reason: 'next comes Start');
      expect(model.toast, 'AnyPS5 engine v0.1.3 is ready');
      model.onboardingConfirm();
      expect(model.preferences.onboarded, isTrue);
    });

    test('onboarding: without GitHub the card says so, and choosing it asks again', () async {
      github.apiStatus = 500;
      await toToolkitStep();
      expect(model.engine.checkError, isNotNull);
      github.apiStatus = null;
      github.releases.add(upstreamRelease('0.1.3'));
      model.onboardingConfirm();
      await until(() => model.engine.latest != null && !model.engine.checking);
      expect(model.engine.downloading, isNull, reason: 'the first choice only looked again');
    });

    test('a release without checksums is downloaded only when chosen a second time', () async {
      github.releases.add(upstreamRelease('0.1.3')..digests = false);
      await toToolkitStep();
      model.onboardingConfirm();
      await until(() => model.engine.unverified != null);
      expect(model.toast, T.text('engineUnverified'));
      expect(github.downloads, isEmpty);
      expect(model.toolkit, isNull);
      model.onboardingConfirm();
      await until(() => model.toolkit != null);
      expect(model.toolkit!.version, 'upstream-v0.1.3');
      expect(model.engine.unverified, isNull);
    });

    test('settings: the engine in use, other versions to switch to or download, the old ones deleted', () async {
      github.releases.addAll([upstreamRelease('0.1.2'), upstreamRelease('0.1.1')]);
      await model.engine.check(quiet: true);
      model.open(Layer.settings);
      expect(model.panelCategories().map((category) => category.id), contains('engine'));
      expect((row('engineCurrent').kind as InfoRow).text, 'Not found');
      expect(row('engineDownload').title, 'Download v0.1.2');
      choose('engineDownload');
      await until(() => model.engine.downloading == null && model.toolkit != null);
      choose('engine-0.1.1');
      await until(() => model.engine.downloading == null && model.toolkit!.version == 'upstream-v0.1.1');
      expect((row('engineCurrent').kind as InfoRow).text, 'v0.1.1');
      expect((row('engine-0.1.1').kind as InfoRow).text, 'In use');
      expect(row('engine-0.1.2').detail, 'Downloaded · select to use');
      choose('engine-0.1.2');
      expect(model.toolkit!.version, 'upstream-v0.1.2');
      expect(model.toast, 'Now using the AnyPS5 engine v0.1.2');
      expect(row('engineDeleteOld').detail, 'Downloaded versions not in use: 1');
      choose('engineDeleteOld');
      expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), ['0.1.2']);
      expect(
        model.panelCategories().expand((category) => category.rows).map((row) => row.id),
        isNot(contains('engineDeleteOld')),
      );
      expect(row('engine-0.1.1').detail, contains('select to download'));
      choose('engineCheck');
      await until(() => !model.engine.checking);
      expect(model.toast, 'The AnyPS5 engine is up to date (v0.1.2)');
    });

    test('a newer engine marks installed games; Update and Play downloads it, then unlocks again', () async {
      github.releases.add(upstreamRelease('0.1.2'));
      await model.engine.download();
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, Installer.recordName)).writeAsStringSync(
        '{"date":"2026-10-24T12:00:00Z","source":"${orbit.folder}","system":"linux","titleID":"PPSA01001",'
        '"toolkit":"upstream-v0.1.2"}',
      );
      model.preferences.onboarded = true;
      model.rescan();
      expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));

      github.releases.insert(0, upstreamRelease('0.1.3'));
      await model.engine.startupCheck();
      expect(model.engine.updateAvailable, isTrue);
      expect(model.toast, 'AnyPS5 engine v0.1.3 is out: Settings › AnyPS5 Engine');
      expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isTrue));
      model.select(model.games.indexOf(orbit));
      model.primaryAction(orbit);
      expect(model.overlay, Layer.updateChoice);
      expect(row('update').detail, startsWith('Downloads AnyPS5 engine v0.1.3'));
      choose('update');
      await until(() => model.engine.downloading == null && model.toolkit!.version == 'upstream-v0.1.3');
      expect(model.engine.updateAvailable, isFalse);
      // The game is unlocked again with the new engine.
      expect(
        model.queue.contains(orbit.id) || model.progress.containsKey(orbit.id) || model.failures.containsKey(orbit.id),
        isTrue,
      );
      await until(() => !model.progress.containsKey(orbit.id) && !model.queue.contains(orbit.id));
      // 0.1.2 stays: the game was made with it.
      expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), ['0.1.3', '0.1.2']);
    });

    test('a folder of the user\'s own is not nagged about engine updates', () async {
      github.releases.add(upstreamRelease('0.1.3'));
      model.preferences.toolkitFolder = fixture.toolkit;
      model.preferences.onboarded = true;
      await model.engine.check(quiet: true);
      expect(model.engine.updateAvailable, isFalse);
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));
      model.open(Layer.settings);
      expect(row('engineOwn').detail, fixture.toolkit);
      expect(
        model.panelCategories().expand((category) => category.rows).map((row) => row.id),
        isNot(contains('engineDownload')),
      );
    });
  });

  group('glibc', () {
    PanelRow? row(AppModel model, String id) {
      model.open(Layer.settings);
      return model.panelCategories().expand((category) => category.rows).where((row) => row.id == id).firstOrNull;
    }

    test('an engine needing a newer glibc is said in Settings and before a game is unlocked', () {
      final fixture = makeFixture(glibc: '2.35');
      addTearDown(fixture.dispose);
      final model = fixture.model;
      addTearDown(model.dispose);
      File(p.join(fixture.toolkit, 'libs', 'libkernel.prx')).writeAsBytesSync(elfNeeding(['GLIBC_2.38']));
      final warning = row(model, 'engineGlibc');
      expect(warning?.title, 'Games need glibc 2.38 or newer; this system has 2.35');
      expect(warning?.detail, contains('Ubuntu 24.04'));
      final locked = model.games.firstWhere((game) => game.titleId == 'PPSA03003');
      model.unlock(locked);
      expect(model.toast, 'Games need glibc 2.38 or newer; this system has 2.35');
      expect(
        model.queue.contains(locked.id) || model.progress.containsKey(locked.id),
        isTrue,
        reason: 'it is unlocked all the same',
      );
      model.cancelUnlock(locked);
      T.language = Language.turkish;
      expect(row(model, 'engineGlibc')?.title, 'Oyunlar glibc 2.38 veya daha yenisini istiyor; bu sistemde 2.35 var');
    });

    test('nothing is said when the system has enough, or its glibc is unknown', () {
      for (final glibc in ['2.39', null]) {
        final fixture = makeFixture(glibc: glibc);
        File(p.join(fixture.toolkit, 'libs', 'libkernel.prx')).writeAsBytesSync(elfNeeding(['GLIBC_2.38']));
        expect(row(fixture.model, 'engineGlibc'), isNull);
        fixture.model.dispose();
        fixture.dispose();
      }
    });
  });
}
