import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/core/update_channel.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/engine_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_github.dart';
import '../support/signing.dart';
import '../support/ui_support.dart';

/// Settings › AnyPS5 Engine on the Nightly update channel: the newest signed upstream nightly
/// (upstream's main, built unmodified by AnyPS5-ARM's CI) beside upstream's releases, and nothing
/// of it on Stable.
void main() {
  final key = TestReleaseKey('release');
  late FakeGitHub upstream;
  late FakeGitHub arm;
  late Fixture fixture;
  late AppModel model;

  setUp(() async {
    upstream = await FakeGitHub.start();
    arm = await FakeGitHub.start(repository: ArmToolkitPackage.repository);
    fixture = makeFixture(engine: upstream.api, armEngine: arm.api, armKeys: [key.key]);
    model = fixture.model;
    upstream.releases.add(upstreamRelease('0.1.4'));
    arm.releases.addAll([
      // CI's newest, not signed yet: not offered.
      upstreamNightlyRelease('upstream-nightly.20261107.ccccccccc', 'v0.1.4-30-gccccccccc'),
      signed(upstreamNightlyRelease('upstream-nightly.20261106.bbbbbbbbb', 'v0.1.4-20-gbbbbbbbbb'), [key]),
      signed(upstreamNightlyRelease('upstream-nightly.20261105.aaaaaaaaa', 'v0.1.4-10-gaaaaaaaaa'), [key]),
      signed(armRelease('v0.2.34-arm', '26d785b'), [key]),
    ]);
  });

  tearDown(() async {
    model.dispose();
    await upstream.close();
    await arm.close();
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 2000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  List<PanelRow> engineRows() {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
    return model.panelCategories().firstWhere((category) => category.id == 'engine').rows;
  }

  PanelRow? row(String id) => engineRows().where((row) => row.id == id).firstOrNull;

  test('Stable offers no upstream nightly, even with AnyPS5-ARM\'s releases listed', () async {
    await model.engine.check(quiet: true);
    await model.engine.checkArm(quiet: true);
    expect(model.updateChannel, UpdateChannel.stable);
    expect(model.engine.upstreamNightly, isNull);
    expect(row('engineUpstreamMain'), isNull);
    expect(engineRows().map((row) => row.id), isNot(contains(startsWith('engine-upstream'))));
  });

  test('Nightly offers the newest signed upstream nightly, labelled untested, and installs it', () async {
    model.setUpdateChannel(UpdateChannel.nightly);
    await until(() => model.engine.armChecked);
    final nightly = model.engine.upstreamNightly!;
    expect(nightly.commit, 'bbbbbbbbb', reason: 'the newer one is not signed yet');
    expect(nightly.release.tag, 'upstream-nightly.20261106.bbbbbbbbb');

    final offer = row('engineUpstreamMain')!;
    expect(offer.title, T.format('engineUpstreamMain', ['bbbbbbbbb · 2026-11-06']));
    expect(offer.title, 'Upstream main · bbbbbbbbb · 2026-11-06 (untested)');
    expect(offer.detail, endsWith(T.text('engineUpstreamMainDetail')));
    expect(model.engine.armSelected, isFalse, reason: 'it is an upstream engine: the Upstream source shows it');

    (offer.kind as ActionRow).run();
    await until(() => model.engine.downloading == null && model.toolkitVersion == 'upstream-main-bbbbbbbbb');
    expect(EngineModel.label(model.toolkit!), 'Upstream main bbbbbbbbb');
    expect(EngineModel.isUpstreamNightly(model.toolkitVersion), isTrue);
    expect(EngineModel.isArm(model.toolkitVersion), isFalse);
    expect(EngineModel.readsPhone(model.toolkitVersion), isFalse, reason: 'upstream has no phone input');
    expect(model.engine.readsDisplaySettings, isFalse);
    expect((row('engineUpstreamMain')!.kind as InfoRow).text, T.text('engineInUse'));
    expect((row('engineCurrent')!.kind as InfoRow).text, 'Upstream main bbbbbbbbb');
    expect(model.engine.updateAvailable, isFalse);

    // Upstream's release is no update of it (no "Update to v0.1.4"), and it is listed once.
    await model.engine.check(quiet: true);
    expect(model.engine.latest?.version, '0.1.4');
    expect(row('engineDownload'), isNull);
    expect(engineRows().map((row) => row.id), isNot(contains(startsWith('engine-upstream'))));

    // Once the next one is signed, it is offered as the update.
    arm.releases[0] = signed(arm.releases[0], [key]);
    await model.engine.checkArm(quiet: true);
    expect(model.engine.upstreamNightly!.commit, 'ccccccccc');
    expect(model.engine.updateAvailable, isTrue);
    expect(row('engineUpstreamMain')!.title, 'Upstream main · ccccccccc · 2026-11-07 (untested)');
    expect(row('engineDownload'), isNull, reason: 'the nightly row is the offer, not upstream\'s release');

    // Back on Stable it is neither offered nor an update; the one in use stays in use.
    model.setUpdateChannel(UpdateChannel.stable);
    expect(model.engine.upstreamNightly, isNull);
    expect(row('engineUpstreamMain'), isNull);
    expect(model.engine.updateAvailable, isFalse);
    expect(model.toolkitVersion, 'upstream-main-bbbbbbbbb');
  });

  test('download names an upstream nightly by its commit', () {
    final release = UpstreamRelease(tag: 'v0.1.4', assets: const []);
    final asset = ReleaseAsset(name: 'relinker-v0.1.4', size: 1, url: Uri.parse('https://example.invalid/r'));
    expect(EngineModel.packageName(ToolkitPackage(release: release, relinker: asset, libraries: asset)), 'v0.1.4');
    expect(
      EngineModel.packageName(
        UpstreamNightlyPackage(
          release: release,
          relinker: asset,
          libraries: asset,
          commit: 'bf80054e7',
          day: DateTime.utc(2026, 11, 6),
          describe: 'v0.1.4-1523-gbf80054e7',
        ),
      ),
      'Upstream main bf80054e7',
    );
  });
}
