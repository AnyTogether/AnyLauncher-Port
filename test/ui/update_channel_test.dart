import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/core/update_channel.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_github.dart';
import '../support/signing.dart';
import '../support/ui_support.dart';

/// Settings › About › Update Channel: nightly engines in the engine picker only on Nightly, and
/// Stable never offering to go back from a nightly engine in use.
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

  PanelRow row(String id) => model
      .panelCategories()
      .expand((category) => category.rows)
      .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

  FakeRelease nightly(String tag, String commit) {
    final release = armRelease(tag, commit);
    return signed(FakeRelease(release.tag, release.files, prerelease: true), [key]);
  }

  test('nightly engines are offered only on the Nightly channel', () async {
    arm.releases
      ..add(nightly('v0.2.31-arm-nightly.20261101.1', 'aaaaaaa'))
      ..add(signed(armRelease('v0.2.30-arm', 'bbbbbbb'), [key]));
    model.engine.chooseSource(true);
    await until(() => model.engine.armChecked);
    expect(model.updateChannel, UpdateChannel.stable);
    expect(model.engine.armPackage?.commit, 'bbbbbbb');

    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'about');
    final channel = row('updateChannel');
    expect(channel.title, T.text('updateChannel'));
    expect(channel.detail, T.text('updateChannelStableDetail'));
    expect((channel.kind as ChoiceRow).options, [T.text('channelStable'), T.text('channelNightly')]);
    (channel.kind as ChoiceRow).set(1);
    expect(model.updateChannel, UpdateChannel.nightly);
    expect(model.preferences.updateChannel, 'nightly');
    expect(row('updateChannel').detail, T.text('updateChannelNightlyDetail'));
    expect(model.engine.armPackage?.commit, 'aaaaaaa');
    expect(model.engine.armPackage?.release.prerelease, isTrue);
  });

  test('a nightly not signed yet is not offered: the signed one before it is', () async {
    final unsigned = armRelease('v0.2.31-arm-nightly.20261102.1', 'ddddddd');
    arm.releases
      ..add(FakeRelease(unsigned.tag, unsigned.files, prerelease: true))
      ..add(nightly('v0.2.31-arm-nightly.20261101.1', 'aaaaaaa'))
      ..add(signed(armRelease('v0.2.30-arm', 'bbbbbbb'), [key]));
    model.setUpdateChannel(UpdateChannel.nightly);
    model.engine.chooseSource(true);
    await until(() => model.engine.armChecked);
    expect(model.engine.armPackage?.commit, 'aaaaaaa');
  });

  test('back on Stable, a nightly engine in use is not replaced by the older release', () async {
    arm.releases
      ..add(nightly('v0.2.31-arm-nightly.20261101.1', 'aaaaaaa'))
      ..add(signed(armRelease('v0.2.30-arm', 'bbbbbbb'), [key]));
    model.setUpdateChannel(UpdateChannel.nightly);
    model.engine.chooseSource(true);
    await until(() => model.engine.armChecked);
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
    (row('engineDownload').kind as ActionRow).run();
    await until(() => model.engine.downloading == null && model.toolkitVersion == 'arm-aaaaaaa');

    model.setUpdateChannel(UpdateChannel.stable);
    expect(model.engine.armPackage?.commit, 'bbbbbbb');
    expect(model.engine.armInUseIsNewer, isTrue);
    expect(model.engine.updateAvailable, isFalse);
    expect(
      model.panelCategories().expand((category) => category.rows).where((row) => row.id == 'engineDownload'),
      isEmpty,
      reason: 'the older release is not offered as a download',
    );

    // The release the nightly led to comes out: Stable offers it.
    arm.releases.add(signed(armRelease('v0.2.31-arm', 'ccccccc'), [key]));
    await model.engine.checkArm(quiet: true);
    expect(model.engine.armPackage?.commit, 'ccccccc');
    expect(model.engine.updateAvailable, isTrue);
  });
}
