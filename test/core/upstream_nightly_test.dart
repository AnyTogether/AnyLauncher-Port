import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/core/update_channel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';

/// Upstream nightlies: upstream's main built unmodified by AnyPS5-ARM's CI, published as
/// AnyPS5-ARM pre-releases tagged upstream-nightly.<YYYYMMDD>.<commit>.
void main() {
  final key = TestReleaseKey('release');
  late FakeGitHub github;
  late GitHubReleases releases;
  late Directory temp;

  setUp(() async {
    github = await FakeGitHub.start(repository: ArmToolkitPackage.repository);
    releases = GitHubReleases(api: github.api, repository: ArmToolkitPackage.repository, signingKeys: [key.key]);
    temp = temporaryFolder('upstream-nightly');
  });

  tearDown(() async {
    await github.close();
    temp.deleteSync(recursive: true);
  });

  ToolkitStore store(HostSystem system) => ToolkitStore(p.join(temp.path, 'Toolkits'), system: system);

  test('the tag gives the commit and the day; the files are upstream\'s, by its git describe', () async {
    github.releases.add(
      upstreamNightlyRelease('upstream-nightly.20261106.bf80054e7', 'v0.1.4-1523-gbf80054e7', unpatched: true),
    );
    final release = (await releases.all()).single;
    final windows = UpstreamNightlyPackage.of(release, HostSystem.windows)!;
    expect(windows.commit, 'bf80054e7');
    expect(windows.day, DateTime.utc(2026, 11, 6));
    expect(windows.date, '2026-11-06');
    expect(windows.describe, 'v0.1.4-1523-gbf80054e7');
    expect(windows.relinker.name, 'relinker-v0.1.4-1523-gbf80054e7.exe');
    expect(windows.libraries.name, 'prx-windows-v0.1.4-1523-gbf80054e7.zip', reason: 'not the unpatched libraries');
    expect(windows.version, 'upstream-main-bf80054e7');
    expect(windows.toolkitVersion, 'upstream-main-bf80054e7');
    final linux = UpstreamNightlyPackage.of(release, HostSystem.linux)!;
    expect(linux.relinker.name, 'relinker-v0.1.4-1523-gbf80054e7');
    expect(linux.libraries.name, 'prx-linux-v0.1.4-1523-gbf80054e7.tar.gz');
    expect(linux.trust, ReleaseTrust.unsignedRefused, reason: 'AnyPS5-ARM signs its releases; this one is not yet');
  });

  test('other tags, other days and missing files are no upstream nightly', () async {
    github.releases.addAll([
      armRelease('v0.2.35-arm-nightly.20261106.1', 'aaaaaaa'),
      upstreamNightlyRelease('upstream-nightly.20261332.bf80054e7', 'v0.1.4-1-gbf80054e7'),
      upstreamNightlyRelease('upstream-nightly.2026110.bf80054e7', 'v0.1.4-1-gbf80054e7'),
      upstreamNightlyRelease('upstream-nightly.20261106.main', 'v0.1.4-1-gbf80054e7'),
      upstreamNightlyRelease('upstream-nightly.20261105.0123456789', 'v0.1.4-2-g012345678', windows: false),
    ]);
    final all = await releases.all();
    final windows = [for (final release in all) ?UpstreamNightlyPackage.of(release, HostSystem.windows)];
    expect(windows, isEmpty);
    final linux = [for (final release in all) ?UpstreamNightlyPackage.of(release, HostSystem.linux)];
    expect(linux.map((package) => package.commit), ['0123456789']);
  });

  test('a relinker of another describe than the libraries is no package', () async {
    final release = upstreamNightlyRelease('upstream-nightly.20261106.bf80054e7', 'v0.1.4-1523-gbf80054e7');
    final bytes = release.files.remove('relinker-v0.1.4-1523-gbf80054e7')!;
    release.files['relinker-v0.1.4-1522-g000000000'] = bytes;
    github.releases.add(release);
    final all = await releases.all();
    expect(UpstreamNightlyPackage.of(all.single, HostSystem.linux), isNull);
    expect(UpstreamNightlyPackage.of(all.single, HostSystem.windows), isNotNull);
  });

  test('the newest is the latest day, then the one published last', () async {
    github.releases.addAll([
      upstreamNightlyRelease('upstream-nightly.20261105.aaaaaaaaa', 'v0.1.4-10-gaaaaaaaaa'),
      upstreamNightlyRelease('upstream-nightly.20261106.bbbbbbbbb', 'v0.1.4-20-gbbbbbbbbb'),
      upstreamNightlyRelease('upstream-nightly.20261104.ccccccccc', 'v0.1.4-5-gccccccccc'),
      armRelease('v0.2.35-arm', 'ddddddd'),
    ]);
    final all = await releases.all();
    expect(UpstreamNightlyPackage.newest(all, HostSystem.linux)!.commit, 'bbbbbbbbb');
    expect(UpstreamNightlyPackage.newest(const [], HostSystem.linux), isNull);

    final earlier = UpstreamRelease(
      tag: 'upstream-nightly.20261106.eeeeeeeee',
      published: DateTime.utc(2026, 11, 6, 1),
      assets: UpstreamNightlyPackage.of(all[1], HostSystem.linux)!.release.assets,
    );
    final later = UpstreamRelease(
      tag: 'upstream-nightly.20261106.fffffffff',
      published: DateTime.utc(2026, 11, 6, 9),
      assets: earlier.assets,
    );
    expect(UpstreamNightlyPackage.newest([later, earlier], HostSystem.linux)!.commit, 'fffffffff');
    expect(UpstreamNightlyPackage.newest([earlier, later], HostSystem.linux)!.commit, 'fffffffff');
  });

  test('no update channel offers an upstream nightly as AnyPS5-ARM\'s release or engine', () async {
    github.releases.addAll([
      signed(upstreamNightlyRelease('upstream-nightly.20261106.bf80054e7', 'v0.1.4-1523-gbf80054e7'), [key]),
      signed(armRelease('v0.2.34-arm', '26d785b'), [key]),
    ]);
    final all = await releases.all();
    expect(ReleaseVersion.parse('upstream-nightly.20261106.bf80054e7'), isNull);
    expect(ChannelReleases.isNewer('upstream-nightly.20261106.bf80054e7', '0.2.34-arm'), isFalse);
    for (final channel in UpdateChannel.values) {
      final offered = ChannelReleases.offered(all, channel);
      expect(offered.map((release) => release.tag), ['v0.2.34-arm'], reason: channel.name);
      expect(ArmToolkitPackage.find(offered, HostSystem.linux)!.commit, '26d785b');
    }
    // Its files are not AnyPS5-ARM's engine archives either.
    expect(
      ArmToolkitPackage.find([all.firstWhere((release) => release.tag.startsWith('upstream-'))], HostSystem.linux),
      isNull,
    );
  });

  test('a signed upstream nightly is checked against its signed sums and laid out as upstream\'s releases', () async {
    github.releases.add(
      signed(upstreamNightlyRelease('upstream-nightly.20261106.bf80054e7', 'v0.1.4-1523-gbf80054e7'), [key]),
    );
    final package = UpstreamNightlyPackage.of((await releases.all()).single, HostSystem.linux)!;
    expect(package.trust, ReleaseTrust.signed);
    final toolkit = await store(HostSystem.linux).install(package);
    expect(p.basename(toolkit.root), 'upstream-main-bf80054e7');
    expect(toolkit.version, 'upstream-main-bf80054e7');
    expect(File(p.join(toolkit.root, 'relinker')).readAsStringSync(), contains('v0.1.4-1523-gbf80054e7'));
    expect(File(p.join(toolkit.root, 'libs', 'libkernel.prx')).existsSync(), isTrue);
    expect(ToolkitStore.upstreamVersion(toolkit.version), isNull, reason: 'no upstream release version');
    expect(UpstreamNightlyPackage.isVersion(toolkit.version), isTrue);
    expect(UpstreamNightlyPackage.commitOf(toolkit.version), 'bf80054e7');
    expect(UpstreamNightlyPackage.commitOf('upstream-v0.1.4'), isNull);
    expect(UpstreamNightlyPackage.commitOf('arm-26d785b'), isNull);
  });

  test('an unsigned upstream nightly is refused before anything is downloaded', () async {
    github.releases.add(upstreamNightlyRelease('upstream-nightly.20261106.bf80054e7', 'v0.1.4-1523-gbf80054e7'));
    final package = UpstreamNightlyPackage.of((await releases.all()).single, HostSystem.windows)!;
    final failure = await store(HostSystem.windows)
        .install(package, allowUnsigned: true, allowUnverified: true)
        .then<ToolkitFailure?>((_) => null, onError: (Object error) => error as ToolkitFailure);
    expect(failure?.kind, ToolkitFailureKind.signature);
    expect(github.downloads, isEmpty);
  });
}
