import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

import '../core/themes/theme_design.dart';
import '../core/themes/theme_library.dart';
import '../core/together/account.dart';
import '../core/together/theme_hub.dart';
import 'app_model.dart';
import 'strings.dart';

/// What the Hub showed: nothing read yet, reading, the themes, or a failure.
sealed class HubList {
  const HubList();
}

class HubIdle extends HubList {
  const HubIdle();
}

class HubLoading extends HubList {
  const HubLoading();
}

class HubFailed extends HubList {
  const HubFailed();
}

class HubShown extends HubList {
  const HubShown(this.themes);
  final List<HubTheme> themes;
}

final _lists = Expando<HubList>('hub');

/// The Theme Hub in Settings › Appearance › Themes, as the macOS launcher's: the themes people
/// share, read from AnyTogether's Hub (the GitHub folder while it has none), installed and used
/// with one choice; Share on the Hub uploads the theme in use with a still of it when signed in,
/// and saves the file and opens the GitHub page otherwise.
extension ThemeHubModel on AppModel {
  /// For the tests: the Hub's client.
  static ThemeHub hub = ThemeHub();

  HubList get hubList => _lists[this] ?? const HubIdle();
  set hubList(HubList next) => _lists[this] = next;

  /// For the tests: the addresses the Hub is read from instead of the server's and GitHub's.
  static List<Uri>? basesInstead;

  /// Where the Hub is read from, in order.
  List<Uri> get hubBases => basesInstead ?? [ThemeHub.onServer(together.account.base), ThemeHub.githubBase];

  Future<void> loadHub({bool again = false}) async {
    if (hubList is HubLoading || (hubList is HubShown && !again)) return;
    hubList = const HubLoading();
    refresh();
    try {
      hubList = HubShown(await hub.themes(hubBases));
    } on Object {
      hubList = const HubFailed();
    }
    refresh();
  }

  List<PanelRow> hubRows() {
    if (hubList is HubIdle) scheduleMicrotask(loadHub);
    return [
      PanelRow(id: 'hub', title: T.text('themesHub'), kind: const InfoRow('')),
      ...switch (hubList) {
        HubIdle() ||
        HubLoading() => [PanelRow(id: 'hub-loading', title: T.text('hubLoading'), kind: const InfoRow(''))],
        HubFailed() => [
          PanelRow(id: 'hub-retry', title: T.text('hubFailed'), kind: ActionRow(() => unawaited(loadHub(again: true)))),
        ],
        HubShown(:final themes) when themes.isEmpty => [
          PanelRow(id: 'hub-empty', title: T.text('hubEmpty'), kind: const InfoRow('')),
        ],
        HubShown(:final themes) => [for (final theme in themes) _hubRow(theme)],
      },
    ];
  }

  PanelRow _hubRow(HubTheme theme) {
    final installed = designs.where((design) => design.id == theme.id).firstOrNull;
    final current = installed != null && installed.version >= theme.version;
    final inUse = current && activeDesign?.id == theme.id;
    return PanelRow(
      id: 'hub-${theme.id}',
      title: theme.name,
      detail: [
        if (theme.author.isNotEmpty) T.format('themeBy', [theme.author]),
        if (inUse) T.text('themeActive'),
      ].join(', '),
      kind: ActionRow(() => current ? useTheme(installed) : unawaited(installFromHub(theme))),
    );
  }

  /// Downloads the theme, installs it and uses it.
  Future<void> installFromHub(HubTheme theme) async {
    show(T.format('themeDownloading', [theme.name]));
    final folder = Directory.systemTemp.createTempSync('anyps5-hub').path;
    try {
      final file = await hub.download(theme, folder);
      await installTheme(file);
    } on Object {
      show(T.text('themeInstallFailed'));
    } finally {
      try {
        Directory(folder).deleteSync(recursive: true);
      } on FileSystemException {
        // The system cleans its temporary folder.
      }
    }
  }

  /// `anyps5://theme/<ID>`: the theme is read from AnyTogether's Hub, downloaded and used.
  Future<void> installHubTheme(String id) async {
    try {
      final theme = await hub.theme(together.account.base, id);
      if (theme == null) return show(T.text('socialHubNoTheme'));
      await installFromHub(theme);
    } on Object {
      show(T.text('themeInstallFailed'));
    }
  }

  /// Share on the Hub: signed in, straight onto AnyTogether's Hub; otherwise the file is saved
  /// and the page it is sent from opens.
  Future<void> shareOnHub(ThemeDesign design) async {
    final folder = Directory.systemTemp.createTempSync('anyps5-share').path;
    final name = ThemeLibrary.plainName(design.name.replaceAll(RegExp(r'[/\\:]'), ' ')) ?? 'theme';
    final file = p.join(folder, '$name.${ThemeDesign.fileExtension}');
    try {
      await themes.export(design, file);
    } on Object {
      show(T.text('themeSaveFailed'));
      return;
    }
    final together = this.together;
    if (!together.signedIn) {
      services.openFolder?.call(folder);
      services.openUrl?.call(
        ThemeHub.shareIssue.replace(
          queryParameters: {...ThemeHub.shareIssue.queryParameters, 'title': 'Theme: ${design.name}'},
        ),
      );
      show(T.text('themeShareNext'));
      return;
    }
    show(T.format('socialHubSharing', [design.name]));
    try {
      final bytes = File(file).readAsBytesSync();
      if (bytes.length > ThemeHub.maxBytes) return show(T.text('socialHubTooLarge'));
      // The server needs a picture of the theme: its own background, or a still in its colours.
      final preview = design.background == null || design.backgroundIsVideo ? await themeStill(design) : null;
      final shared = await ThemeHub.share(together.account, theme: bytes, filename: p.basename(file), preview: preview);
      show(
        shared.version > 1
            ? T.format('socialHubSharedVersion', [shared.name, shared.version])
            : T.format('socialHubShared', [shared.name]),
      );
      unawaited(loadHub(again: true));
    } on Object catch (error) {
      show(hubShareMessage(error));
    } finally {
      try {
        Directory(folder).deleteSync(recursive: true);
      } on FileSystemException {
        // The system cleans its temporary folder.
      }
    }
  }

  String hubShareMessage(Object error) {
    if (error is! TogetherProblem) return together.message(error);
    return switch (error.code) {
      'payload_too_large' => T.text('socialHubTooLarge'),
      'bad_theme' || 'unsupported_media_type' => T.text('socialHubBadTheme'),
      'preview_required' || 'bad_image' => T.text('socialHubNoPreview'),
      _ => together.message(error),
    };
  }

  /// A 1280×720 PNG of the theme's colours: the deep tone into the middle one, the bright tone
  /// and the accent glowing in, as its animated background looks at rest.
  static Future<List<int>> themeStill(ThemeDesign design) async {
    Color colour(String hex) {
      final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0;
      return Color(0xFF000000 | value);
    }

    const size = ui.Size(1280, 720);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(size.width, size.height), [
          colour(design.deep),
          colour(design.middle),
        ]),
    );
    void glow(Offset centre, double radius, Color tint) => canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.radial(centre, radius, [tint.withValues(alpha: 0.75), tint.withValues(alpha: 0)]),
    );
    glow(Offset(size.width * 0.28, size.height * 0.32), size.width * 0.45, colour(design.bright));
    glow(Offset(size.width * 0.78, size.height * 0.74), size.width * 0.32, colour(design.accent));
    final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }
}
