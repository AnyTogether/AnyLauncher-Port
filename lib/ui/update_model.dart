import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_update.dart';
import '../core/toolkit_download.dart';
import 'app_model.dart';
import 'components.dart';
import 'strings.dart';
import 'together_model.dart' show launcherVersion;

/// New versions of AnyPS5 Desktop itself: whether one is out, and its installer downloaded and
/// checked against the release's signature, for the user to run (Settings › About).
class LauncherUpdateModel {
  LauncherUpdateModel(this.app);

  final AppModel app;

  /// What GitHub said last.
  UpstreamRelease? latest;
  bool checking = false;
  String? checkError;

  /// The download in progress: bytes so far of [total].
  int? received;
  int total = 0;
  DownloadCancel? _cancel;

  /// The checked installer, once downloaded.
  String? downloaded;

  /// Why the last download failed.
  String? error;

  GitHubReleases? get _source => app.services.launcherReleases;

  /// The version this launcher is.
  String get current => launcherVersion;

  bool get available => latest != null && LauncherUpdates.isNewer(latest!, current);

  bool get _appImage => (app.services.environment ?? Platform.environment)['APPIMAGE']?.isNotEmpty ?? false;

  /// The newest release's file for this system.
  ReleaseAsset? get asset => latest == null ? null : LauncherUpdates.assetFor(latest!, app.system, appImage: _appImage);

  /// Where installers are downloaded to.
  String get folder => p.join(app.paths.cache, 'Updates');

  /// Asks GitHub for the newest release; without [quiet], says what came of it.
  Future<void> check({bool quiet = false}) async {
    final source = _source;
    if (source == null || checking) return;
    checking = true;
    checkError = null;
    app.refresh();
    try {
      latest = await source.latest();
      if (!quiet) {
        app.show(
          available
              ? T.format('desktopUpdateAvailable', [latest!.version])
              : T.format('desktopUpToDate', [current]),
        );
      }
    } on ToolkitFailure catch (failure) {
      checkError = failure.message;
      if (!quiet) app.show(T.text('updateCheckFailed'));
    } finally {
      checking = false;
      app.refresh();
    }
  }

  /// At start: a quiet look, said once when a newer version is out.
  Future<void> startupCheck() async {
    if (_source == null) return;
    await check(quiet: true);
    if (available) app.show(T.format('desktopUpdateAvailable', [latest!.version]));
  }

  /// Downloads the newest release's installer once its signature checked out.
  Future<void> download() async {
    final release = latest;
    final file = asset;
    if (release == null || file == null || received != null) return;
    final cancel = DownloadCancel();
    _cancel = cancel;
    received = 0;
    total = file.size;
    error = null;
    app.refresh();
    var shown = -1;
    try {
      downloaded = await LauncherUpdates.download(
        release,
        file,
        folder,
        cancel: cancel,
        onProgress: (bytes) {
          received = bytes;
          final step = total <= 0 ? 0 : bytes * 100 ~/ total;
          if (step != shown) {
            shown = step;
            app.refresh();
          }
        },
      );
      app.show(T.format('desktopUpdateReady', [release.version]));
    } on ToolkitFailure catch (failure) {
      if (failure.kind != ToolkitFailureKind.cancelled) {
        error = failure.message;
        app.show(T.format('desktopUpdateFailed', [failure.message]));
      }
    } finally {
      received = null;
      _cancel = null;
      app.refresh();
    }
  }

  void cancel() => _cancel?.cancel();

  /// The About rows: the version, a newer one to download or the downloaded installer, and the
  /// check.
  List<PanelRow> aboutRows() {
    final release = latest;
    final file = asset;
    return [
      if (received case final int bytes)
        PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopUpdateDownloading', [release?.version ?? '', total <= 0 ? 0 : bytes * 100 ~/ total]),
          detail: T.format('engineProgress', [byteText(bytes), byteText(total)]),
          kind: ActionRow(cancel),
        )
      else if (downloaded case final String path when available)
        PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopUpdateReady', [release!.version]),
          detail: path,
          kind: ActionRow(() => app.services.openFolder?.call(p.dirname(path))),
        )
      else if (available && file != null)
        PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopUpdateTo', [release!.version]),
          detail: T.format('desktopUpdateDetail', [file.name, byteText(file.size)]),
          kind: ActionRow(() => unawaited(download())),
        )
      else if (available)
        PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopUpdateAvailable', [release!.version]),
          detail: T.text('desktopUpdateNoFile'),
          kind: const InfoRow(''),
        ),
      PanelRow(
        id: 'desktopUpdateCheck',
        title: T.text('checkForUpdatesNow'),
        detail: checking
            ? T.text('checkingUpdates')
            : release == null
            ? (checkError == null ? T.format('desktopVersion', [current]) : T.text('updateCheckFailed'))
            : T.format('desktopNewest', [release.version, current]),
        kind: ActionRow(() => unawaited(check())),
      ),
    ];
  }
}
