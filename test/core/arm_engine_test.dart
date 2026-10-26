import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';

void main() {
  final key = TestReleaseKey('release');
  late FakeGitHub github;
  late GitHubReleases releases;
  late Directory temp;

  setUp(() async {
    github = await FakeGitHub.start(repository: ArmToolkitPackage.repository);
    releases = GitHubReleases(api: github.api, repository: ArmToolkitPackage.repository, signingKeys: [key.key]);
    temp = temporaryFolder('arm-engine');
  });

  tearDown(() async {
    await github.close();
    temp.deleteSync(recursive: true);
  });

  ToolkitStore store(HostSystem system) => ToolkitStore(p.join(temp.path, 'Toolkits'), system: system);

  test('the newest release that carries the engine for this system is the one offered', () async {
    github.releases.addAll([
      FakeRelease('v0.2.18-arm', {'AnyPS5-macOS.zip': filler('mac')}),
      armRelease('v0.2.17-arm', '26d785b', linux: false),
      armRelease('v0.2.16-arm', '1111111'),
    ]);
    final all = await releases.all();
    final windows = ArmToolkitPackage.find(all, HostSystem.windows)!;
    expect(windows.commit, '26d785b');
    expect(windows.version, 'arm-26d785b');
    expect(windows.release.tag, 'v0.2.17-arm');
    expect(windows.archive.name, 'AnyPS5-toolkit-windows-26d785b.zip');
    expect(ArmToolkitPackage.find(all, HostSystem.linux)!.commit, '1111111');
    expect(ArmToolkitPackage.find(const [], HostSystem.linux), isNull);
  });

  test('a release that keeps an older engine beside a newer one offers the newest upload', () async {
    final older = armRelease('v0.2.21-arm', '26d785b', linux: false);
    final newer = armRelease('v0.2.21-arm', '0a1b2c3');
    final release = FakeRelease('v0.2.21-arm', {...older.files, ...newer.files});
    release.uploaded['AnyPS5-toolkit-windows-26d785b.zip'] = '2026-10-26T01:03:23Z';
    release.uploaded['AnyPS5-toolkit-windows-0a1b2c3.zip'] = '2026-10-26T04:10:00Z';
    release.uploaded['AnyPS5-toolkit-linux-0a1b2c3.tar.gz'] = '2026-10-26T04:12:00Z';
    github.releases.add(release);
    final all = await releases.all();
    expect(all.single.assets.map((asset) => asset.name), contains('AnyPS5-toolkit-windows-26d785b.zip'));
    final windows = ArmToolkitPackage.find(all, HostSystem.windows)!;
    expect(
      windows.commit,
      '0a1b2c3',
      reason: 'GitHub lists 0a1b2c3 first by name, but it is the newer upload either way',
    );
    expect(windows.archive.name, 'AnyPS5-toolkit-windows-0a1b2c3.zip');
    expect(ArmToolkitPackage.find(all, HostSystem.linux)!.commit, '0a1b2c3');

    release.uploaded['AnyPS5-toolkit-windows-26d785b.zip'] = '2026-10-26T05:00:00Z';
    expect(
      ArmToolkitPackage.find(await releases.all(), HostSystem.windows)!.commit,
      '26d785b',
      reason: 'the upload time decides, not the name',
    );
  });

  test('a signed release: the archive is checked against the signed sums and laid out whole', () async {
    github.releases.add(signed(armRelease('v0.2.17-arm', '26d785b'), [key]));
    final package = ArmToolkitPackage.find(await releases.all(), HostSystem.windows)!;
    expect(package.trust, ReleaseTrust.signed);
    final kit = await store(HostSystem.windows).install(package);
    expect(kit.problem, isNull);
    expect(p.basename(kit.root), 'arm-26d785b');
    expect(kit.version, 'arm-26d785b');
    expect(kit.libraryFiles.map(p.basename), contains('libwinpthread-1.dll'));
    expect(
      github.downloads.where((path) => path.contains('AnyPS5-toolkit-windows')),
      hasLength(1),
      reason: 'one archive, once',
    );
    expect(github.downloads.where((path) => path.contains('macOS')), isEmpty);
  });

  test('Linux: the toolkit inside a folder of the archive, its relinker executable', () async {
    github.releases.add(signed(armRelease('v0.2.17-arm', 'abcdef0'), [key]));
    final package = ArmToolkitPackage.find(await releases.all(), HostSystem.linux)!;
    final kit = await store(HostSystem.linux).install(package);
    expect(kit.problem, isNull);
    expect(File(p.join(kit.root, 'version.txt')).readAsStringSync(), 'arm-abcdef0\n');
    if (!Platform.isWindows) {
      expect(File(kit.relinker).statSync().mode & 0x40, isNot(0));
    }
  });

  test('an archive changed after signing is refused', () async {
    final release = signed(armRelease('v0.2.17-arm', '26d785b'), [key]);
    release.files['AnyPS5-toolkit-windows-26d785b.zip'] = zipOf({
      'relinker.exe': filler('evil'),
      'libs/x.prx': filler('x'),
    });
    github.releases.add(release);
    final package = ArmToolkitPackage.find(await releases.all(), HostSystem.windows)!;
    await expectLater(
      store(HostSystem.windows).install(package),
      throwsA(isA<ToolkitFailure>().having((failure) => failure.kind, 'kind', ToolkitFailureKind.checksum)),
    );
    expect(store(HostSystem.windows).installed(), isEmpty);
  });

  test('an unsigned release from after signing began is refused', () async {
    github.releases.add(armRelease('v0.2.20-arm', '26d785b'));
    final package = ArmToolkitPackage.find(await releases.all(), HostSystem.windows)!;
    await expectLater(
      store(HostSystem.windows).install(package),
      throwsA(isA<ToolkitFailure>().having((failure) => failure.kind, 'kind', ToolkitFailureKind.signature)),
    );
  });

  test('an archive without a relinker beside libs/ is not a toolkit', () async {
    final release = FakeRelease('v0.2.17-arm', {
      'AnyPS5-toolkit-windows-26d785b.zip': zipOf({'libs/libkernel.prx': filler('k')}),
    });
    github.releases.add(signed(release, [key]));
    final package = ArmToolkitPackage.find(await releases.all(), HostSystem.windows)!;
    await expectLater(
      store(HostSystem.windows).install(package),
      throwsA(isA<ToolkitFailure>().having((failure) => failure.kind, 'kind', ToolkitFailureKind.badLayout)),
    );
  });
}
