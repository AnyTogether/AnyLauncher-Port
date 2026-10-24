import 'dart:async';

import 'package:path/path.dart' as p;

import '../core/audio/tones.dart';
import '../core/glibc.dart';
import '../core/host.dart';
import '../core/toolkit.dart';
import '../core/toolkit_download.dart';
import 'app_model.dart';
import 'components.dart';
import 'strings.dart';

/// The AnyPS5 engine (upstream's relinker and system libraries) as the launcher gets it by
/// itself: which versions GitHub has, the one being downloaded, the ones on disk and which
/// one is in use.
class EngineModel {
  EngineModel(this.app) : store = ToolkitStore(app.paths.toolkits, system: app.system) {
    refresh();
  }

  final AppModel app;
  final ToolkitStore store;

  /// The downloaded toolkits, newest first.
  List<Toolkit> downloaded = const [];

  /// What GitHub said last: the latest release and the recent ones.
  UpstreamRelease? latest;
  List<UpstreamRelease> releases = const [];
  bool checking = false;

  /// Why GitHub could not be asked, until the next try.
  String? checkError;

  /// The package being downloaded and how far it is.
  ToolkitPackage? downloading;
  ToolkitProgress? progress;
  DownloadCancel? _cancel;

  /// A package GitHub gave no checksum for, waiting for the user to download it anyway.
  ToolkitPackage? unverified;

  /// Why the last download failed.
  String? error;

  GitHubReleases? get _source => app.services.engineReleases;

  /// Whether the launcher can ask GitHub at all (not in tests without a fake).
  bool get online => _source != null;

  void refresh() => downloaded = store.installed();

  /// The latest release's files for this system.
  ToolkitPackage? get latestPackage => latest?.packageFor(app.system);

  /// The upstream version of the toolkit in use, null for a folder of the user's own.
  String? get currentVersion {
    final kit = app.toolkit;
    return kit == null ? null : ToolkitStore.upstreamVersion(kit.version);
  }

  /// A newer engine than the downloaded one in use is out and not downloaded yet: games made
  /// with the current one are offered to be unlocked again with it.
  bool get updateAvailable {
    final package = latestPackage;
    final current = currentVersion;
    if (package == null || current == null) return false;
    return compareVersions(package.version, current) > 0 && store.find(package.version) == null;
  }

  /// A toolkit's name for people: v0.1.3 for a downloaded one, its version.txt otherwise.
  static String label(Toolkit kit) {
    final upstream = ToolkitStore.upstreamVersion(kit.version);
    return upstream == null ? kit.version : 'v$upstream';
  }

  bool isDownloaded(Toolkit kit) => p.equals(p.dirname(kit.root), store.root);

  /// This system's glibc, read once.
  late final String? hostGlibc = app.system == HostSystem.linux ? (app.services.hostGlibc ?? Glibc.host)() : null;

  /// What a Linux engine's libraries need of glibc and this system lacks, null when it has
  /// enough (or on Windows, or when either is unknown).
  ({String needed, String host})? glibcShortfall(Toolkit kit) {
    if (app.system != HostSystem.linux) return null;
    return Glibc.shortfall(kit.libraryFiles, host: hostGlibc, key: '${kit.root}\u0000${kit.version}');
  }

  /// "Games need glibc 2.38 or newer; this system has 2.35", null when nothing is missing.
  String? glibcWarning(Toolkit kit) {
    final missing = glibcShortfall(kit);
    return missing == null ? null : T.format('engineGlibc', [missing.needed, missing.host]);
  }

  /// Asks GitHub for the latest release and the recent ones. Without [quiet], says what came
  /// of it.
  Future<void> check({bool quiet = false}) async {
    final source = _source;
    if (source == null || checking) return;
    checking = true;
    checkError = null;
    app.refresh();
    try {
      final newest = await source.latest();
      latest = newest;
      try {
        releases = await source.all();
      } on ToolkitFailure {
        releases = [newest];
      }
      if (!quiet) {
        app.show(
          updateAvailable
              ? T.format('engineUpdateToast', ['v${newest.version}'])
              : T.format('engineUpToDate', ['v${newest.version}']),
        );
      }
    } on ToolkitFailure catch (failure) {
      checkError = failure.message;
      if (!quiet) app.show(T.text('engineOffline'));
    } finally {
      checking = false;
      app.refresh();
    }
  }

  /// At start: a quiet look for a newer engine, said once when there is one.
  Future<void> startupCheck() async {
    if (!online || !app.preferences.onboarded || currentVersion == null) return;
    await check(quiet: true);
    if (updateAvailable) app.show(T.format('engineUpdateToast', ['v${latest!.version}']));
  }

  /// Downloads [package] (the latest when null), makes it the toolkit in use and deletes
  /// versions nothing needs any more. True when it is in place.
  Future<bool> download([ToolkitPackage? package, bool allowUnverified = false]) async {
    if (downloading != null) return false;
    if (package == null) {
      if (latest == null) await check(quiet: true);
      package = latestPackage;
      if (package == null) {
        app.show(T.text(latest == null ? 'engineOffline' : 'engineNoDownload'));
        return false;
      }
    }
    final cancel = DownloadCancel();
    _cancel = cancel;
    downloading = package;
    progress = ToolkitProgress(ToolkitPhase.download, 0, package.size);
    error = null;
    app.refresh();
    var shown = -1;
    try {
      final kit = await store.install(
        package,
        allowUnverified: allowUnverified,
        cancel: cancel,
        onProgress: (next) {
          progress = next;
          final step = (next.fraction * 200).floor() + next.phase.index * 1000;
          if (step != shown) {
            shown = step;
            app.refresh();
          }
        },
      );
      unverified = null;
      refresh();
      app.preferences.toolkitFolder = kit.root;
      app.savePreferences();
      removeUnused();
      app.sounds.play(Cue.unlocked);
      app.show(glibcWarning(kit) ?? T.format('engineReady', [label(kit)]));
      return true;
    } on ToolkitFailure catch (failure) {
      switch (failure.kind) {
        case ToolkitFailureKind.cancelled:
          break;
        case ToolkitFailureKind.unverified:
          unverified = package;
          app.show(T.text('engineUnverified'));
        default:
          error = failure.message;
          app.show(T.format('engineFailed', [failure.message]));
      }
      return false;
    } finally {
      downloading = null;
      progress = null;
      _cancel = null;
      app.refresh();
    }
  }

  /// Stops the download; what came is kept, to carry on next time.
  void cancel() => _cancel?.cancel();

  /// Makes [kit] the toolkit in use.
  void use(Toolkit kit) {
    app.preferences.toolkitFolder = kit.root;
    app.savePreferences();
    app.show(glibcWarning(kit) ?? T.format('engineSwitched', [label(kit)]));
  }

  /// Keeps the toolkit in use, the newest two and those installed games were made with.
  void removeUnused() {
    final current = app.toolkit;
    store.removeUnused(
      keep: {?current?.version, ?current?.root, for (final record in app.records.values) record.toolkit},
    );
    refresh();
  }

  /// Deletes every downloaded version but the one in use.
  void deleteOthers() {
    final current = app.toolkit;
    for (final kit in downloaded) {
      if (current != null && p.equals(kit.root, current.root)) continue;
      store.remove(p.basename(kit.root));
    }
    store.clearDownloads();
    refresh();
    app.show(T.text('engineDeleted'));
  }

  /// The settings' AnyPS5 Engine rows.
  List<PanelRow> settingsRows() {
    final current = app.toolkit;
    final package = downloading;
    final rows = <PanelRow>[
      PanelRow(
        id: 'engineCurrent',
        title: T.text('engineInUse'),
        detail: current?.root ?? T.text('toolkitDetail'),
        kind: InfoRow(current == null ? T.text('toolkitMissing') : label(current)),
      ),
      if (current != null && glibcWarning(current) != null)
        PanelRow(
          id: 'engineGlibc',
          title: glibcWarning(current)!,
          detail: T.text('engineGlibcDetail'),
          kind: const InfoRow(''),
        ),
      if (package != null)
        PanelRow(
          id: 'engineDownload',
          title: T.format('engineDownloading', ['v${package.version}', ((progress?.fraction ?? 0) * 100).floor()]),
          detail: '${progressText()} · ${T.text('engineStop')}',
          kind: ActionRow(cancel),
        )
      else if (unverified case final ToolkitPackage pending)
        PanelRow(
          id: 'engineDownload',
          title: T.text('engineUnverifiedTitle'),
          detail: T.format('engineUnverifiedDetail', ['v${pending.version}']),
          kind: ActionRow(() => unawaited(download(pending, true)), destructive: true),
        )
      else if (latestPackage case final ToolkitPackage newest when updateAvailable || current == null)
        PanelRow(
          id: 'engineDownload',
          title: T.format(current == null ? 'engineDownloadVersion' : 'engineUpdate', ['v${newest.version}']),
          detail: byteText(newest.size),
          kind: ActionRow(() => unawaited(download(newest))),
        ),
      PanelRow(
        id: 'engineCheck',
        title: T.text('engineCheck'),
        detail: checking
            ? T.text('checkingUpdates')
            : latest == null
            ? (checkError == null ? T.text('engineSource') : T.text('engineOffline'))
            : T.format('engineNewest', ['v${latest!.version}']),
        kind: ActionRow(() => unawaited(check())),
      ),
    ];
    // Every version GitHub lists and every one on disk, newest first.
    final versions = <String>{
      for (final release in releases)
        if (release.packageFor(app.system) != null) release.version,
      for (final kit in downloaded) p.basename(kit.root),
    }.toList()..sort((a, b) => compareVersions(b, a));
    for (final version in versions.take(8)) {
      final kit = downloaded.where((kit) => p.basename(kit.root) == version).firstOrNull;
      final release = releases.where((release) => release.version == version).firstOrNull;
      final title = release?.prerelease ?? false ? 'v$version · ${T.text('enginePrerelease')}' : 'v$version';
      if (kit != null && current != null && p.equals(kit.root, current.root)) {
        rows.add(PanelRow(id: 'engine-$version', title: title, kind: InfoRow(T.text('engineInUse'))));
      } else if (kit != null) {
        rows.add(
          PanelRow(
            id: 'engine-$version',
            title: title,
            detail: T.text('engineDownloaded'),
            kind: ActionRow(() => use(kit)),
          ),
        );
      } else if (release?.packageFor(app.system) case final ToolkitPackage other) {
        rows.add(
          PanelRow(
            id: 'engine-$version',
            title: title,
            detail: T.format('engineSizeDetail', [byteText(other.size)]),
            kind: ActionRow(() => unawaited(download(other))),
          ),
        );
      }
    }
    rows.add(
      PanelRow(
        id: 'engineOwn',
        title: T.text('engineOwn'),
        detail: current != null && !isDownloaded(current) ? current.root : T.text('engineOwnFolderDetail'),
        kind: ActionRow(() => unawaited(app.chooseToolkit())),
      ),
    );
    final others = downloaded.where((kit) => current == null || !p.equals(kit.root, current.root)).length;
    if (others > 0) {
      rows.add(
        PanelRow(
          id: 'engineDeleteOld',
          title: T.text('engineDeleteOld'),
          detail: T.format('engineDeleteOldDetail', [others]),
          kind: ActionRow(deleteOthers, destructive: true),
        ),
      );
    }
    return rows;
  }

  /// 42 MB of 97 MB, or the step after the download.
  String progressText() {
    final now = progress;
    if (now == null) return '';
    return switch (now.phase) {
      ToolkitPhase.download => T.format('engineProgress', [byteText(now.received), byteText(now.total)]),
      _ => T.text('engineUnpacking'),
    };
  }
}
