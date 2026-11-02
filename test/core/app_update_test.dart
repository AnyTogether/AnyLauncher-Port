import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/app_update.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';

void main() {
  final key = TestReleaseKey('desktop release');
  late FakeGitHub github;
  late Directory temp;
  late GitHubReleases releases;

  FakeRelease desktopRelease(String version) => FakeRelease('v$version', {
    'AnyPS5-Desktop-Setup-$version-x64.exe': [0x4D, 0x5A, ...filler('setup$version')],
    'AnyPS5-Desktop-$version-x86_64.AppImage': filler('appimage$version'),
    'AnyPS5-Desktop-linux-x64.tar.gz': filler('tar$version'),
    'AnyPS5-Desktop-windows-x64.zip': filler('zip$version'),
  });

  setUp(() async {
    github = await FakeGitHub.start(repository: LauncherUpdates.repository);
    temp = temporaryFolder('updates');
    releases = LauncherUpdates.source(api: github.api, keys: [key.key]);
  });

  tearDown(() async {
    await github.close();
    temp.deleteSync(recursive: true);
  });

  Future<ToolkitFailure> failure(Future<Object?> future) async {
    try {
      await future;
    } on ToolkitFailure catch (error) {
      return error;
    }
    fail('expected a ToolkitFailure');
  }

  test('a newer signed release is found and its installer for this system downloaded and checked', () async {
    github.releases.add(signed(desktopRelease('0.1.3'), [key]));
    final latest = await releases.latest();
    expect(LauncherUpdates.isNewer(latest, '0.1.2'), isTrue);
    expect(LauncherUpdates.isNewer(latest, '0.1.3'), isFalse);
    expect(LauncherUpdates.assetFor(latest, HostSystem.windows)!.name, 'AnyPS5-Desktop-Setup-0.1.3-x64.exe');
    expect(LauncherUpdates.assetFor(latest, HostSystem.linux)!.name, 'AnyPS5-Desktop-linux-x64.tar.gz');
    final appImage = LauncherUpdates.assetFor(latest, HostSystem.linux, appImage: true)!;
    expect(appImage.name, 'AnyPS5-Desktop-0.1.3-x86_64.AppImage');
    final path = await LauncherUpdates.download(latest, appImage, temp.path);
    expect(p.basename(path), appImage.name);
    expect(File(path).readAsBytesSync(), filler('appimage0.1.3'));
    // The sums and the signature are not left behind.
    expect(Directory(temp.path).listSync().map((entry) => p.basename(entry.path)), [appImage.name]);
  });

  test('an installer that does not match the signed sums is refused and thrown away', () async {
    final release = signed(desktopRelease('0.1.3'), [key]);
    release.files['AnyPS5-Desktop-Setup-0.1.3-x64.exe'] = utf8.encode('something else');
    github.releases.add(release);
    final latest = await releases.latest();
    final setup = LauncherUpdates.assetFor(latest, HostSystem.windows)!;
    expect((await failure(LauncherUpdates.download(latest, setup, temp.path))).kind, ToolkitFailureKind.checksum);
    expect(File(p.join(temp.path, setup.name)).existsSync(), isFalse);
  });

  test('an unsigned release, or one signed by another key, is never downloaded', () async {
    github.releases.add(desktopRelease('0.1.3'));
    var latest = await releases.latest();
    var refused = await failure(LauncherUpdates.download(latest, LauncherUpdates.assetFor(latest, HostSystem.windows)!, temp.path));
    expect(refused.kind, ToolkitFailureKind.signature);
    expect(refused.message, 'AnyPS5 Desktop 0.1.3 is not signed');
    github.releases
      ..clear()
      ..add(signed(desktopRelease('0.1.4'), [TestReleaseKey('stranger')]));
    latest = await releases.latest();
    refused = await failure(LauncherUpdates.download(latest, LauncherUpdates.assetFor(latest, HostSystem.windows)!, temp.path));
    expect(refused.kind, ToolkitFailureKind.signature);
    expect(refused.message, contains('does not trust'));
    expect(github.downloads.where((path) => !path.contains('SHA256SUMS')), isEmpty);
  });

  test('the launcher reads its own repository with the built-in keys', () {
    final source = LauncherUpdates.source();
    expect(source.repository, 'AnyTogether/AnyPS5-Desktop');
    expect(source.signingKeys, isNotEmpty);
  });
}
