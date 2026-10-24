import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'host.dart';
import 'toolkit.dart';

/// Why getting the AnyPS5 engine from upstream did not work.
enum ToolkitFailureKind {
  /// GitHub could not be reached, or answered with an error.
  network,

  /// The release has no relinker and system libraries for this system.
  noAssets,

  /// GitHub gave no checksum for a file; it is only used when the user says so.
  unverified,

  /// A downloaded file is not the one GitHub described (size or checksum).
  checksum,

  /// The archive names a file outside its own folder, or a link that leads out of it.
  unsafeArchive,

  /// The unpacked files are not a toolkit.
  badLayout,

  /// The user stopped the download.
  cancelled,
}

class ToolkitFailure implements Exception {
  ToolkitFailure(this.kind, this.message);
  final ToolkitFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// One file of an upstream release, as GitHub's API describes it.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.size, required this.url, this.sha256});

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) {
    final digest = json['digest'] as String?;
    return ReleaseAsset(
      name: json['name'] as String,
      size: (json['size'] as num).toInt(),
      url: Uri.parse(json['browser_download_url'] as String),
      sha256: digest != null && digest.startsWith('sha256:') && digest.length == 71
          ? digest.substring(7).toLowerCase()
          : null,
    );
  }

  final String name;
  final int size;
  final Uri url;

  /// GitHub's SHA-256 of the file in hex, null when the API gave none.
  final String? sha256;
}

/// A release of upstream AnyPS5 (boykopovar/AnyPS5).
class UpstreamRelease {
  const UpstreamRelease({required this.tag, required this.assets, this.published, this.prerelease = false});

  factory UpstreamRelease.fromJson(Map<String, dynamic> json) => UpstreamRelease(
    tag: json['tag_name'] as String,
    published: DateTime.tryParse(json['published_at'] as String? ?? ''),
    prerelease: json['prerelease'] as bool? ?? false,
    assets: [
      for (final asset in json['assets'] as List<dynamic>? ?? const [])
        if (asset is Map<String, dynamic>) ReleaseAsset.fromJson(asset),
    ],
  );

  final String tag;
  final DateTime? published;
  final bool prerelease;
  final List<ReleaseAsset> assets;

  /// The tag without its v: 0.1.3.
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  /// The relinker and the system libraries for [system], null when the release has none.
  ///
  /// Windows takes `relinker-v0.1.3.exe` and `prx-windows-v0.1.3.zip`, Linux `relinker-v0.1.3`
  /// and `prx-linux-v0.1.3.tar.gz`; the other archive format of the same libraries is the
  /// fallback.
  ToolkitPackage? packageFor(HostSystem system) {
    ReleaseAsset? named(String name) => assets.where((asset) => asset.name == name).firstOrNull;
    final windows = system == HostSystem.windows;
    final relinker = named(windows ? 'relinker-v$version.exe' : 'relinker-v$version');
    final prefix = 'prx-${windows ? 'windows' : 'linux'}-v$version';
    final formats = windows ? ['.zip', '.tar.gz'] : ['.tar.gz', '.zip'];
    final libraries = formats.map((format) => named('$prefix$format')).nonNulls.firstOrNull;
    if (relinker == null || libraries == null) return null;
    return ToolkitPackage(release: this, relinker: relinker, libraries: libraries);
  }
}

/// What is downloaded for one system: the relinker and the archive of system libraries.
class ToolkitPackage {
  const ToolkitPackage({required this.release, required this.relinker, required this.libraries});

  final UpstreamRelease release;
  final ReleaseAsset relinker;
  final ReleaseAsset libraries;

  String get version => release.version;

  /// Bytes to download.
  int get size => relinker.size + libraries.size;

  /// Whether GitHub gave a checksum for both files.
  bool get verified => relinker.sha256 != null && libraries.sha256 != null;

  /// The version.txt a toolkit made from this package has: upstream-v0.1.3.
  String get toolkitVersion => ToolkitStore.versionText(version);
}

/// Orders upstream versions: 0.1.10 after 0.1.9, a release after its own pre-release.
int compareVersions(String a, String b) {
  List<int> numbers(String version) {
    final core = (version.startsWith('v') ? version.substring(1) : version).split(RegExp('[-+]')).first;
    return core.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  }

  final left = numbers(a);
  final right = numbers(b);
  for (var index = 0; index < left.length || index < right.length; index++) {
    final x = index < left.length ? left[index] : 0;
    final y = index < right.length ? right[index] : 0;
    if (x != y) return x.compareTo(y);
  }
  String bare(String version) => version.startsWith('v') ? version.substring(1) : version;
  final leftPre = a.contains('-');
  final rightPre = b.contains('-');
  if (leftPre != rightPre) return leftPre ? -1 : 1;
  return bare(a).compareTo(bare(b));
}

/// Stops a download or an install in progress.
class DownloadCancel {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _check() {
    if (_cancelled) throw ToolkitFailure(ToolkitFailureKind.cancelled, 'the download was stopped');
  }
}

/// Reads upstream's releases from GitHub's API.
class GitHubReleases {
  GitHubReleases({Uri? api, this.repository = defaultRepository, HttpClient Function()? client})
    : api = api ?? Uri.parse('https://api.github.com'),
      _client = client ?? HttpClient.new;

  static const defaultRepository = 'boykopovar/AnyPS5';

  final Uri api;
  final String repository;
  final HttpClient Function() _client;

  /// The release GitHub calls the latest.
  Future<UpstreamRelease> latest() async {
    final json = await _get('repos/$repository/releases/latest');
    if (json is! Map<String, dynamic>) throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub sent no release');
    return UpstreamRelease.fromJson(json);
  }

  /// Every recent release, newest first, without drafts.
  Future<List<UpstreamRelease>> all() async {
    final json = await _get('repos/$repository/releases?per_page=30');
    if (json is! List<dynamic>) throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub sent no releases');
    final releases = [
      for (final entry in json)
        if (entry is Map<String, dynamic> && entry['draft'] != true) UpstreamRelease.fromJson(entry),
    ]..sort((a, b) => compareVersions(b.version, a.version));
    return releases;
  }

  Future<Object?> _get(String path) async {
    final client = _client()..connectionTimeout = const Duration(seconds: 20);
    try {
      final base = api.toString().endsWith('/') ? api : Uri.parse('$api/');
      final request = await client.getUrl(base.resolve(path));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'AnyPS5-Desktop')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub answered ${response.statusCode}');
      }
      return jsonDecode(body);
    } on ToolkitFailure {
      rethrow;
    } on Object catch (error) {
      throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub could not be reached: $error');
    } finally {
      client.close(force: true);
    }
  }
}

/// Downloads one file into place: into [target].part first, carried on from where an earlier
/// try stopped, then checked against [size] and [sha256] and renamed to [target].
abstract final class AssetDownload {
  static Future<void> fetch(
    Uri url,
    String target, {
    required int size,
    String? sha256,
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    // A file finished by an earlier try that stopped later is kept when it still checks out.
    final done = File(target);
    if (done.existsSync() &&
        done.lengthSync() == size &&
        (sha256 == null || await sha256Of(target) == sha256.toLowerCase())) {
      onProgress?.call(size);
      return;
    }
    final part = File('$target.part');
    part.parent.createSync(recursive: true);
    var have = part.existsSync() ? part.lengthSync() : 0;
    if (have > size) {
      part.deleteSync();
      have = 0;
    }
    if (have < size) await _receive(url, part, have, size, onProgress, cancel, client ?? HttpClient.new);
    onProgress?.call(size);
    cancel?._check();
    final length = part.lengthSync();
    if (length != size) {
      part.deleteSync();
      throw ToolkitFailure(ToolkitFailureKind.checksum, '${p.basename(target)}: $length bytes, expected $size');
    }
    if (sha256 != null) {
      final digest = (await sha256Of(part.path)).toLowerCase();
      if (digest != sha256.toLowerCase()) {
        part.deleteSync();
        throw ToolkitFailure(ToolkitFailureKind.checksum, '${p.basename(target)}: checksum does not match');
      }
    }
    if (File(target).existsSync()) File(target).deleteSync();
    part.renameSync(target);
  }

  static Future<String> sha256Of(String file) async => (await sha256.bind(File(file).openRead()).first).toString();

  static Future<void> _receive(
    Uri url,
    File part,
    int have,
    int size,
    void Function(int)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function() makeClient,
  ) async {
    final client = makeClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    void stop() => client.close(force: true);
    cancel?._listeners.add(stop);
    try {
      cancel?._check();
      // Redirects are followed here, so that every hop is asked for the same range.
      var location = url;
      HttpClientResponse? response;
      for (var hop = 0; hop < 6; hop++) {
        final request = await client.getUrl(location);
        request
          ..followRedirects = false
          ..headers.set(HttpHeaders.userAgentHeader, 'AnyPS5-Desktop')
          ..headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
        if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final answer = await request.close();
        if (answer.isRedirect) {
          final next = answer.headers.value(HttpHeaders.locationHeader);
          await answer.drain<void>();
          if (next == null) break;
          location = location.resolve(next);
          continue;
        }
        response = answer;
        break;
      }
      if (response == null) throw ToolkitFailure(ToolkitFailureKind.network, 'too many redirects for $url');
      final IOSink sink;
      switch (response.statusCode) {
        case HttpStatus.partialContent
            when have > 0 && (response.headers.value(HttpHeaders.contentRangeHeader) ?? '').startsWith('bytes $have-'):
          sink = part.openWrite(mode: FileMode.append);
        case HttpStatus.partialContent:
          await response.drain<void>();
          part.deleteSync();
          throw ToolkitFailure(ToolkitFailureKind.network, 'the server sent another part of the file; try again');
        case HttpStatus.ok:
          // The server sent the whole file: start again.
          have = 0;
          sink = part.openWrite();
        case HttpStatus.requestedRangeNotSatisfiable:
          await response.drain<void>();
          // The part is as long as the server's file, or wrong; the checks after say which.
          if (part.lengthSync() != size) part.deleteSync();
          if (!part.existsSync()) throw ToolkitFailure(ToolkitFailureKind.network, 'the download could not resume');
          return;
        default:
          await response.drain<void>();
          throw ToolkitFailure(ToolkitFailureKind.network, 'the download answered ${response.statusCode}');
      }
      var received = have;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
          if (received > size) throw ToolkitFailure(ToolkitFailureKind.checksum, 'the file is longer than expected');
          onProgress?.call(received);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } on ToolkitFailure {
      cancel?._check();
      rethrow;
    } on Object catch (error) {
      cancel?._check();
      throw ToolkitFailure(ToolkitFailureKind.network, 'the download stopped: $error');
    } finally {
      cancel?._listeners.remove(stop);
      client.close(force: true);
    }
    if (part.lengthSync() < size) {
      throw ToolkitFailure(ToolkitFailureKind.network, 'the download stopped early; try again to carry on');
    }
  }
}

/// Unpacks a zip or a .tar.gz into a folder without letting it write anywhere else: names that
/// are absolute, carry a drive or climb out with .. stop the unpacking, and so does a link whose
/// target leads out of the folder. Links that stay inside are made last (on POSIX; Windows
/// skips them), so no file is written through one.
abstract final class SafeUnpack {
  static Future<void> unpack(String archive, String destination) => Isolate.run(() => unpackSync(archive, destination));

  static void unpackSync(String archive, String destination) {
    Directory(destination).createSync(recursive: true);
    final root = p.normalize(p.absolute(destination));
    final links = <(String, String)>[];

    void entry(ArchiveFile file) {
      final relative = safeName(file.name);
      if (relative == null) return;
      final target = p.joinAll([root, ...relative]);
      if (file.isSymbolicLink) {
        final link = file.symbolicLink!.replaceAll(r'\', '/');
        final resolved = p.normalize(p.join(p.dirname(target), p.joinAll(link.split('/'))));
        if (p.posix.isAbsolute(link) || p.windows.isAbsolute(link) || !p.isWithin(root, resolved)) {
          throw ToolkitFailure(ToolkitFailureKind.unsafeArchive, 'the archive links ${file.name} outside itself');
        }
        links.add((target, link));
        return;
      }
      if (!file.isFile) {
        Directory(target).createSync(recursive: true);
        return;
      }
      Directory(p.dirname(target)).createSync(recursive: true);
      final output = OutputFileStream(target);
      try {
        file.writeContent(output);
      } finally {
        output.closeSync();
      }
    }

    final lower = archive.toLowerCase();
    if (lower.endsWith('.zip')) {
      final input = InputFileStream(archive);
      try {
        final decoded = ZipDecoder().decodeStream(input);
        for (final file in decoded.files) {
          entry(file);
        }
      } finally {
        input.closeSync();
      }
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      final tar = '$destination.tar';
      final source = InputFileStream(archive);
      final unzipped = OutputFileStream(tar);
      try {
        const GZipDecoder().decodeStream(source, unzipped);
      } finally {
        source.closeSync();
        unzipped.closeSync();
      }
      final input = InputFileStream(tar);
      try {
        TarDecoder().decodeStream(input, callback: entry, keepEntries: false);
      } finally {
        input.closeSync();
        File(tar).deleteSync();
      }
    } else {
      throw ToolkitFailure(ToolkitFailureKind.badLayout, 'unknown archive format: ${p.basename(archive)}');
    }
    if (!Platform.isWindows) {
      for (final (path, target) in links) {
        Directory(p.dirname(path)).createSync(recursive: true);
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
          Link(path).createSync(target);
        }
      }
    }
  }

  /// The parts of an archive member's name, null for the archive's own folder; throws for a
  /// name that would land outside the folder.
  static List<String>? safeName(String name) {
    final unsafe = ToolkitFailure(ToolkitFailureKind.unsafeArchive, 'the archive names a file outside itself: $name');
    final slashed = name.replaceAll(r'\', '/');
    if (slashed.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(slashed) || slashed.contains('\u0000')) {
      throw unsafe;
    }
    final parts = <String>[];
    for (final part in slashed.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') throw unsafe;
      if (part.contains(':')) throw unsafe;
      parts.add(part);
    }
    return parts.isEmpty ? null : parts;
  }
}

/// How far an engine download has come.
class ToolkitProgress {
  const ToolkitProgress(this.phase, this.received, this.total);
  final ToolkitPhase phase;
  final int received;
  final int total;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0, 1).toDouble();
}

enum ToolkitPhase { download, unpack, finish }

/// The engine toolkits the launcher downloaded, one folder per upstream version:
///
/// ```text
/// Toolkits/
///     0.1.3/              relinker[.exe], libs/, version.txt = upstream-v0.1.3
///     0.1.2/
///     .downloads/         files on their way, kept to carry on after a restart
///     .staging-0.1.4/     a toolkit being laid out
/// ```
class ToolkitStore {
  ToolkitStore(this.root, {this.system = HostSystem.linux});

  final String root;
  final HostSystem system;

  static String versionText(String version) => 'upstream-v$version';

  /// The upstream version a toolkit was downloaded as, null for any other toolkit.
  static String? upstreamVersion(String toolkitVersion) =>
      toolkitVersion.startsWith('upstream-v') ? toolkitVersion.substring('upstream-v'.length) : null;

  String folderFor(String version) => p.join(root, version);
  String get _downloads => p.join(root, '.downloads');

  /// The usable toolkits in the store, newest first.
  List<Toolkit> installed() {
    final List<Directory> folders;
    try {
      folders = Directory(root).listSync().whereType<Directory>().toList();
    } on FileSystemException {
      return const [];
    }
    final toolkits = [
      for (final folder in folders)
        if (!p.basename(folder.path).startsWith('.')) Toolkit(folder.path, system: system),
    ].where((toolkit) => toolkit.problem == null).toList();
    toolkits.sort((a, b) => compareVersions(p.basename(b.root), p.basename(a.root)));
    return toolkits;
  }

  /// The store's toolkit for [version], null when it is not there.
  Toolkit? find(String version) {
    final toolkit = Toolkit(folderFor(version), system: system);
    return toolkit.problem == null ? toolkit : null;
  }

  /// Downloads [package], checks it and lays it out as a toolkit; returns it. Without
  /// [allowUnverified], a package GitHub gave no checksum for is refused before any download.
  Future<Toolkit> install(
    ToolkitPackage package, {
    bool allowUnverified = false,
    void Function(ToolkitProgress)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    if (!package.verified && !allowUnverified) {
      throw ToolkitFailure(ToolkitFailureKind.unverified, 'GitHub gave no checksum for AnyPS5 ${package.version}');
    }
    final version = package.version;
    if (!_plainName(version)) {
      throw ToolkitFailure(ToolkitFailureKind.unsafeArchive, 'unusable version name $version');
    }
    final total = package.size;
    final relinkerFile = p.join(_downloads, package.relinker.name);
    final librariesFile = p.join(_downloads, package.libraries.name);
    await AssetDownload.fetch(
      package.relinker.url,
      relinkerFile,
      size: package.relinker.size,
      sha256: package.relinker.sha256,
      cancel: cancel,
      client: client,
      onProgress: (received) => onProgress?.call(ToolkitProgress(ToolkitPhase.download, received, total)),
    );
    await AssetDownload.fetch(
      package.libraries.url,
      librariesFile,
      size: package.libraries.size,
      sha256: package.libraries.sha256,
      cancel: cancel,
      client: client,
      onProgress: (received) =>
          onProgress?.call(ToolkitProgress(ToolkitPhase.download, package.relinker.size + received, total)),
    );
    cancel?._check();
    onProgress?.call(ToolkitProgress(ToolkitPhase.unpack, total, total));
    final staging = p.join(root, '.staging-$version');
    final raw = p.join(staging, '.unpacked');
    if (Directory(staging).existsSync()) Directory(staging).deleteSync(recursive: true);
    try {
      await SafeUnpack.unpack(librariesFile, raw);
      cancel?._check();
      layOut(raw, staging, relinker: relinkerFile, version: version);
      final toolkit = Toolkit(staging, system: system);
      final problem = toolkit.problem;
      if (problem != null) {
        throw ToolkitFailure(ToolkitFailureKind.badLayout, 'the release is not a toolkit for this system ($problem)');
      }
      cancel?._check();
      onProgress?.call(ToolkitProgress(ToolkitPhase.finish, total, total));
      final folder = folderFor(version);
      if (Directory(folder).existsSync()) Directory(folder).deleteSync(recursive: true);
      Directory(staging).renameSync(folder);
    } finally {
      if (Directory(staging).existsSync()) Directory(staging).deleteSync(recursive: true);
    }
    for (final file in [relinkerFile, librariesFile]) {
      if (File(file).existsSync()) File(file).deleteSync();
    }
    return Toolkit(folderFor(version), system: system);
  }

  /// Turns the unpacked archive in [raw] and the downloaded [relinker] into the toolkit layout
  /// in [folder]: the folder that holds the .prx files becomes libs/ (older releases put them
  /// at the archive's top, newer ones in libs/), what sits beside a libs/ folder (patches/)
  /// is kept, the relinker gets its toolkit name and on POSIX its executable bit.
  void layOut(String raw, String folder, {required String relinker, required String version}) {
    final prx = Directory(raw)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => p.extension(file.path).toLowerCase() == '.prx')
        .map((file) => p.dirname(file.path))
        .toList();
    if (prx.isEmpty) throw ToolkitFailure(ToolkitFailureKind.badLayout, 'the archive has no system libraries');
    final counts = <String, int>{};
    for (final directory in prx) {
      counts[directory] = (counts[directory] ?? 0) + 1;
    }
    final libraries = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    final libs = p.join(folder, 'libs');
    if (p.basename(libraries) == 'libs' && p.isWithin(raw, libraries)) {
      final base = p.dirname(libraries);
      for (final entity in Directory(base).listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        final destination = name == 'libs' ? libs : p.join(folder, name);
        if (_reserved(name)) continue;
        entity.renameSync(destination);
      }
    } else {
      Directory(libraries).renameSync(libs);
    }
    final relinkerPath = p.join(folder, system.relinkerName);
    File(relinker).copySync(relinkerPath);
    if (!Platform.isWindows) Process.runSync('chmod', ['755', relinkerPath]);
    File(p.join(folder, 'version.txt')).writeAsStringSync('${versionText(version)}\n');
    if (Directory(raw).existsSync()) Directory(raw).deleteSync(recursive: true);
  }

  /// A version that is one plain folder name.
  static bool _plainName(String version) {
    try {
      return !version.startsWith('.') && SafeUnpack.safeName(version)?.length == 1;
    } on ToolkitFailure {
      return false;
    }
  }

  /// Names the layout writes itself; an archive's own copies are left out.
  bool _reserved(String name) => name == 'version.txt' || name == system.relinkerName || name == '.unpacked';

  /// Deletes the toolkit for [version].
  void remove(String version) {
    if (!_plainName(version)) return;
    final folder = Directory(folderFor(version));
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }

  /// Deletes what is no longer needed: every toolkit but the [keepNewest] newest and those
  /// whose version.txt is in [keep] (the current one, the ones installed games were made
  /// with), and leftovers of installs that never finished. Returns the versions deleted.
  List<String> removeUnused({Set<String> keep = const {}, int keepNewest = 2}) {
    final removed = <String>[];
    final toolkits = installed();
    for (final (index, toolkit) in toolkits.indexed) {
      if (index < keepNewest || keep.contains(toolkit.version) || keep.contains(toolkit.root)) continue;
      final version = p.basename(toolkit.root);
      remove(version);
      removed.add(version);
    }
    try {
      for (final folder in Directory(root).listSync().whereType<Directory>()) {
        if (p.basename(folder.path).startsWith('.staging-')) folder.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Nothing there yet.
    }
    return removed;
  }

  /// Deletes half-downloaded files.
  void clearDownloads() {
    final folder = Directory(_downloads);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }
}
