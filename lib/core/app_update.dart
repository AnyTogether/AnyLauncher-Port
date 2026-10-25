import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';
import 'release_signing.dart';
import 'toolkit_download.dart';

/// New releases of AnyPS5 Desktop itself (utkuhalis/AnyPS5-Desktop on GitHub). The launcher says
/// when one is out and downloads its installer for this system, checked against the release's
/// signed SHA256SUMS; the user runs it. Every release newer than a launcher that checks
/// signatures came out after signing began, so an unsigned one is never downloaded.
abstract final class LauncherUpdates {
  static const repository = 'utkuhalis/AnyPS5-Desktop';

  /// Where the launcher's releases are read from, signed with the built-in keys.
  static GitHubReleases source({Uri? api, List<ReleaseKey>? keys, HttpClient Function()? client}) =>
      GitHubReleases(api: api, repository: repository, signingKeys: keys ?? ReleaseSigning.trustedKeys, client: client);

  /// Whether [release] is past the running version [current].
  static bool isNewer(UpstreamRelease release, String current) => compareVersions(release.version, current) > 0;

  /// The file of [release] for this system: the installer on Windows; on Linux the AppImage when
  /// the launcher runs from one ([appImage]), the archive otherwise.
  static ReleaseAsset? assetFor(UpstreamRelease release, HostSystem system, {bool appImage = false}) {
    bool wanted(String name) => switch (system) {
      HostSystem.windows => name.startsWith('AnyPS5-Desktop-Setup-') && name.endsWith('.exe'),
      HostSystem.linux => appImage ? name.endsWith('.AppImage') : name == 'AnyPS5-Desktop-linux-x64.tar.gz',
    };
    return release.assets.where((asset) => wanted(asset.name)).firstOrNull;
  }

  /// Downloads [asset] of [release] into [folder] once the release's signature checked out, and
  /// checks the file against the signed sums; returns where it is. An unsigned release, or one
  /// whose signature is not good, is refused before anything else is downloaded.
  static Future<String> download(
    UpstreamRelease release,
    ReleaseAsset asset,
    String folder, {
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    if (release.signingKeys == null || release.signatureFiles == null) {
      throw ToolkitFailure(ToolkitFailureKind.signature, 'AnyPS5 Desktop ${release.version} is not signed');
    }
    final sums = await SignedRelease.sums(release, folder, cancel: cancel, client: client);
    final digest = SignedRelease.digestOf(sums, asset);
    final target = p.join(folder, asset.name);
    await AssetDownload.fetch(
      asset.url,
      target,
      size: asset.size,
      sha256: digest,
      onProgress: onProgress,
      cancel: cancel,
      client: client,
    );
    return target;
  }
}
