import 'package:flutter/material.dart';

import '../core/crash_report.dart';
import '../core/toolkit_download.dart' show ToolkitStore;
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'crash_model.dart';
import 'panels.dart' show PanelRows;
import 'strings.dart';
import 'theme.dart';

/// After a game stopped on an error (or from its options): why, on which system and engine, the
/// end of its log, and the actions to save, copy or report it; the issue's text before it is
/// shared.
class CrashReportView extends StatelessWidget {
  const CrashReportView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final state = model.crash.current;
    if (state == null) return const SizedBox.shrink();
    final scale = LayoutScale.of(context);
    final categories = model.panelCategories();
    return LayerScrim(
      opacity: 0.74,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 70 * scale, vertical: 52 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 560 * scale,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Header(state: state),
                  SizedBox(height: 22 * scale),
                  _Reason(model: model, state: state),
                  if (state.report case final SessionReport report) ...[
                    SizedBox(height: 18 * scale),
                    _Facts(report: report),
                  ],
                  SizedBox(height: 18 * scale),
                  Expanded(
                    child: PanelRows(model: model, rows: categories.isEmpty ? const [] : categories.first.rows),
                  ),
                  SizedBox(height: 12 * scale),
                  const HintBar(options: false, games: false),
                ],
              ),
            ),
            SizedBox(width: 40 * scale),
            Expanded(
              child: _Side(model: model, state: state),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});

  final CrashReportState state;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final icon = state.game.icon;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14 * scale),
          child: SizedBox(
            width: 76 * scale,
            height: 76 * scale,
            child: ColoredBox(
              color: Colors.white.withValues(alpha: 0.08),
              child: icon == null
                  ? Icon(Icons.sports_esports_rounded, size: 30 * scale, color: Colors.white.withValues(alpha: 0.5))
                  : ArtworkImage(path: icon, cacheWidth: (76 * scale * 2).round()),
            ),
          ),
        ),
        SizedBox(width: 20 * scale),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                T.upper(T.text(state.sharing ? 'reportKickerShare' : 'reportKicker')),
                style: AppText.display(
                  12 * scale,
                  weight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.55),
                ).copyWith(letterSpacing: 0.9 * scale),
              ),
              SizedBox(height: 6 * scale),
              Text(
                T.format(state.afterCrash ? 'reportStopped' : 'reportLastSession', [state.game.name]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(30 * scale, weight: FontWeight.w300),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason({required this.model, required this.state});

  final AppModel model;
  final CrashReportState state;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final report = state.report;
    final abnormal = report?.abnormal ?? state.afterCrash;
    final color = abnormal ? Palette.warning : Colors.white.withValues(alpha: 0.85);
    return Glass(
      radius: 14 * scale,
      opacity: 0.5,
      padding: EdgeInsets.all(16 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            report == null
                ? Icons.hourglass_top_rounded
                : (abnormal ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded),
            size: 20 * scale,
            color: color,
          ),
          SizedBox(width: 12 * scale),
          Expanded(
            child: Text(
              model.crash.reasonText(state),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(16 * scale, weight: FontWeight.w500, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.report});

  final SessionReport report;

  static String _engine(String? version) {
    if (version == null) return '—';
    if (version.startsWith('arm-')) return 'AnyPS5-ARM ${version.substring(4)}';
    final upstream = ToolkitStore.upstreamVersion(version);
    return upstream == null ? version : 'v$upstream';
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final system = report.systemInfo;
    final from = report.started;
    final to = report.ended;
    final facts = <(String, String)>[
      (T.text('reportFactSystem'), [system.os, ?system.cpu].join(' · ')),
      (T.text('reportFactGpu'), system.gpu ?? '—'),
      (T.text('reportFactEngine'), _engine(report.unlockedWith ?? report.engineNow)),
      (T.text('reportFactExit'), report.exitLine ?? '—'),
      (
        T.text('reportFactSession'),
        from != null && to != null ? T.format('reportRan', [to.difference(from).inMinutes.clamp(0, 1 << 20)]) : '—',
      ),
      (T.text('reportFactLogging'), T.text(report.traced ? 'on' : 'off')),
    ];
    final label = AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.5));
    final value = AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.88));
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4 * scale),
      child: Column(
        children: [
          for (final (name, text) in facts)
            Padding(
              padding: EdgeInsets.only(bottom: 6 * scale),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 150 * scale,
                    child: Text(name, style: label),
                  ),
                  Expanded(
                    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: value),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The end of the log, or the issue's text exactly as the link carries it.
class _Side extends StatelessWidget {
  const _Side({required this.model, required this.state});

  final AppModel model;
  final CrashReportState state;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final sharing = state.sharing;
    final String text;
    if (sharing) {
      text = state.engineIssue?.preview ?? '';
    } else if (state.report != null) {
      text = state.tail.isEmpty ? T.text('reportNoLog') : state.tail.join('\n');
    } else {
      text = '';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              sharing ? Icons.visibility_outlined : Icons.notes_rounded,
              size: 20 * scale,
              color: model.accentChoice.color,
            ),
            SizedBox(width: 10 * scale),
            Expanded(
              child: Text(
                T.text(sharing ? 'reportShareTitle' : 'reportLogTail'),
                style: AppText.display(18 * scale, weight: FontWeight.w600),
              ),
            ),
            BackPill(onTap: () => model.handle(Command.back), close: !sharing),
          ],
        ),
        if (sharing) ...[
          SizedBox(height: 10 * scale),
          Text(
            T.text('reportShareDetail'),
            style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.6)),
          ),
        ],
        SizedBox(height: 14 * scale),
        Expanded(
          child: Glass(
            radius: 14 * scale,
            opacity: 0.55,
            child: SizedBox.expand(
              child: SingleChildScrollView(
                key: ValueKey(sharing),
                // The log reads from its end; the shared text from its title.
                reverse: !sharing,
                padding: EdgeInsets.all(18 * scale),
                child: SelectableText(
                  text,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5 * scale,
                    height: 1.35,
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
