import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/controls.dart';
import '../core/trophies.dart';
import 'app_model.dart';
import 'components.dart';
import 'home.dart';
import 'strings.dart';
import 'theme.dart';

/// Every game as a grid, opened from the library button.
class LibraryGrid extends StatelessWidget {
  const LibraryGrid({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final size = 196 * scale;
    return _Scrim(
      opacity: 0.74,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 80 * scale, vertical: 60 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(T.text('library'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
                SizedBox(width: 14 * scale),
                Padding(
                  padding: EdgeInsets.only(bottom: 6 * scale),
                  child: Text(
                    '${model.games.length}',
                    style: AppText.display(
                      22 * scale,
                      weight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                const Spacer(),
                const HintBar(options: false),
              ],
            ),
            SizedBox(height: 26 * scale),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(14 * scale),
                child: Wrap(
                  spacing: 26 * scale,
                  runSpacing: 30 * scale,
                  children: [
                    for (var index = 0; index < model.games.length; index++)
                      KeepVisible(
                        active: index == model.libraryIndex,
                        child: GestureDetector(
                          onTap: () {
                            model.select(index);
                            model.closeOverlay();
                          },
                          child: SizedBox(
                            width: size,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox.square(
                                  dimension: size,
                                  child: GameTile(
                                    model: model,
                                    game: model.games[index],
                                    size: size,
                                    focused: index == model.libraryIndex,
                                  ),
                                ),
                                SizedBox(height: 10 * scale),
                                Text(
                                  model.games[index].nameFor([T.language.code]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.display(
                                    15 * scale,
                                    weight: index == model.libraryIndex ? FontWeight.w600 : FontWeight.w400,
                                    color: Colors.white.withValues(alpha: index == model.libraryIndex ? 1 : 0.75),
                                  ),
                                ),
                                SizedBox(height: 4 * scale),
                                StateLabel(model: model, state: model.stateOf(model.games[index]), size: 12),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A darkened, blurred layer over the home screen.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.child, this.opacity = 0.65});

  final Widget child;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: opacity),
          child: child,
        ),
      ),
    );
  }
}

/// The settings, a game's settings, its controls and the confirmations: categories on the left
/// (when there are several), the rows of the chosen one on the right.
class PanelView extends StatelessWidget {
  const PanelView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final categories = model.panelCategories();
    if (categories.isEmpty) return const SizedBox.shrink();
    final category = categories[model.panelCategory.clamp(0, categories.length - 1)];
    final compact = model.overlay == Layer.confirmUninstall || model.overlay == Layer.updateChoice;
    final heading = switch (model.overlay) {
      Layer.settings => T.text('settings'),
      Layer.controls => T.text('controls'),
      Layer.gameSettings => T.text('gameSettings'),
      _ => category.title,
    };
    return _Scrim(
      opacity: 0.55,
      child: Center(
        child: SizedBox(
          width: (compact ? 760 : 1180) * scale,
          height: (compact ? 420 : 720) * scale,
          child: Glass(
            radius: 28 * scale,
            opacity: 0.5,
            padding: EdgeInsets.all(36 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(heading, style: AppText.display(34 * scale, weight: FontWeight.w300)),
                    if (model.overlay != Layer.settings && !compact) ...[
                      SizedBox(width: 14 * scale),
                      Flexible(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 5 * scale),
                          child: Text(
                            category.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(18 * scale, color: Colors.white.withValues(alpha: 0.55)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: 24 * scale),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (categories.length > 1) ...[
                        SizedBox(
                          width: 250 * scale,
                          child: Column(
                            children: [
                              for (var index = 0; index < categories.length; index++)
                                _CategoryTab(
                                  title: categories[index].title,
                                  selected: index == model.panelCategory,
                                  onTap: () => model.selectCategory(index),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(width: 28 * scale),
                      ],
                      Expanded(
                        child: _Rows(model: model, rows: category.rows),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({required this.title, required this.selected, required this.onTap});

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        width: double.infinity,
        margin: EdgeInsets.only(bottom: 6 * scale),
        padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 14 * scale),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: selected ? 0.14 : 0),
          borderRadius: BorderRadius.circular(12 * scale),
        ),
        child: Text(
          title,
          style: AppText.display(
            17 * scale,
            weight: selected ? FontWeight.w600 : FontWeight.w400,
            color: Colors.white.withValues(alpha: selected ? 1 : 0.6),
          ),
        ),
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows({required this.model, required this.rows});

  final AppModel model;
  final List<PanelRow> rows;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 6 * scale),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++)
            KeepVisible(
              active: index == model.panelRow,
              child: _RowView(
                model: model,
                row: rows[index],
                focused: index == model.panelRow,
                onTap: () {
                  model.panelRow = index;
                  model.handle(Command.select);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _RowView extends StatelessWidget {
  const _RowView({required this.model, required this.row, required this.focused, required this.onTap});

  final AppModel model;
  final PanelRow row;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final kind = row.kind;
    final destructive = kind is ActionRow && kind.destructive;
    final titleColor = focused ? Colors.black : (destructive ? Palette.danger : Colors.white);
    final detailColor = focused ? Colors.black.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.55);
    final accent = model.accentChoice.color;
    Widget value() {
      final style = AppText.display(16 * scale, weight: FontWeight.w600, color: titleColor);
      switch (kind) {
        case ChoiceRow(:final options, :final selected):
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chevron_left_rounded, size: 20 * scale, color: detailColor),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 280 * scale),
                child: Text(
                  options[selected.clamp(0, options.length - 1)],
                  style: style,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20 * scale, color: detailColor),
            ],
          );
        case ToggleRow(:final value):
          return AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            width: 46 * scale,
            height: 26 * scale,
            padding: EdgeInsets.all(3 * scale),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20 * scale),
              color: value
                  ? accent
                  : (focused ? Colors.black.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.18)),
            ),
            child: Container(
              width: 20 * scale,
              height: 20 * scale,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
            ),
          );
        case StepperRow(:final value, :final format):
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.remove_rounded, size: 18 * scale, color: detailColor),
              SizedBox(width: 10 * scale),
              Text(format(value), style: style),
              SizedBox(width: 10 * scale),
              Icon(Icons.add_rounded, size: 18 * scale, color: detailColor),
            ],
          );
        case KeysRow(:final sources, :final capturing):
          if (capturing) {
            return Text(T.text('pressKey'), style: style.copyWith(color: focused ? Colors.black : accent));
          }
          return Wrap(
            spacing: 6 * scale,
            children: [
              if (sources.isEmpty) Text(T.text('noKey'), style: style.copyWith(color: detailColor)),
              for (final source in sources)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 9 * scale, vertical: 4 * scale),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7 * scale),
                    color: focused ? Colors.black.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.12),
                  ),
                  child: Text(
                    Controls.label(source, turkish: T.language == Language.turkish),
                    style: AppText.display(13 * scale, weight: FontWeight.w600, color: titleColor),
                  ),
                ),
            ],
          );
        case ActionRow():
          return Icon(Icons.chevron_right_rounded, size: 22 * scale, color: detailColor);
        case InfoRow():
          return const SizedBox.shrink();
        case TextRow():
          return SizedBox(
            width: 420 * scale,
            child: RowTextField(model: model, row: row, kind: kind, focused: focused),
          );
      }
    }

    final info = kind is InfoRow ? kind.text : null;
    return GestureDetector(
      onTap: row.focusable ? onTap : null,
      child: AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        margin: EdgeInsets.only(bottom: 6 * scale),
        padding: EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 14 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: row.focusable ? 0.06 : 0),
          borderRadius: BorderRadius.circular(14 * scale),
          boxShadow: [
            BoxShadow(
              color: Colors.white.withValues(alpha: focused ? 0.22 : 0),
              blurRadius: 16 * scale,
            ),
          ],
        ),
        child: Row(
          children: [
            if (row.person != null) ...[
              PersonAvatar(person: row.person!, size: 44 * scale, focused: focused),
              SizedBox(width: 16 * scale),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        row.title,
                        style: AppText.display(17 * scale, weight: FontWeight.w500, color: titleColor),
                      ),
                      if (row.glyph != null) ...[
                        SizedBox(width: 8 * scale),
                        PadGlyphIcon(row.glyph!, size: 15 * scale, color: titleColor),
                      ],
                    ],
                  ),
                  if (row.detail != null || info != null) ...[
                    SizedBox(height: 4 * scale),
                    Text(
                      info ?? row.detail!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(13 * scale, color: detailColor),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: 18 * scale),
            value(),
          ],
        ),
      ),
    );
  }
}

/// The game's log, newest at the bottom.
class LogView extends StatelessWidget {
  const LogView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.selectedGame;
    final text = game == null ? '' : model.logText(game);
    return _Scrim(
      opacity: 0.65,
      child: Padding(
        padding: EdgeInsets.all(70 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${T.text('logTitle')}${game == null ? '' : ' · ${game.name}'}',
                  style: AppText.display(30 * scale, weight: FontWeight.w300),
                ),
                const Spacer(),
                ConsoleButton(
                  title: T.text('close'),
                  icon: Icons.close_rounded,
                  focused: true,
                  onPressed: model.closeOverlay,
                ),
              ],
            ),
            SizedBox(height: 18 * scale),
            Expanded(
              child: Glass(
                radius: 14 * scale,
                opacity: 0.55,
                child: SingleChildScrollView(
                  reverse: true,
                  padding: EdgeInsets.all(18 * scale),
                  child: SelectableText(
                    text.isEmpty ? '—' : text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12 * scale,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A phone asking to pair: its name and the code both screens show.
class PairingCard extends StatelessWidget {
  const PairingCard({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final request = model.pairing;
    if (request == null) return const SizedBox.shrink();
    return _Scrim(
      opacity: 0.5,
      child: Center(
        child: SizedBox(
          width: 620 * scale,
          child: Glass(
            radius: 28 * scale,
            opacity: 0.55,
            padding: EdgeInsets.all(40 * scale),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_iphone_rounded, size: 44 * scale, color: Colors.white),
                SizedBox(height: 16 * scale),
                Text(T.text('phonePairingTitle'), style: AppText.display(28 * scale, weight: FontWeight.w300)),
                SizedBox(height: 10 * scale),
                Text(request.deviceName, style: AppText.display(18 * scale, weight: FontWeight.w600)),
                SizedBox(height: 6 * scale),
                Text(
                  T.text('phonePairingText'),
                  textAlign: TextAlign.center,
                  style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.7)),
                ),
                SizedBox(height: 26 * scale),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final digit in request.code.split(''))
                      Container(
                        width: 64 * scale,
                        height: 82 * scale,
                        margin: EdgeInsets.symmetric(horizontal: 6 * scale),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(14 * scale),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                        ),
                        child: Text(digit, style: AppText.display(44 * scale, weight: FontWeight.w300)),
                      ),
                  ],
                ),
                SizedBox(height: 30 * scale),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConsoleButton(
                      title: T.text('phoneAllow'),
                      icon: Icons.check_rounded,
                      focused: true,
                      onPressed: () => model.answerPairing(true),
                    ),
                    SizedBox(width: 16 * scale),
                    ConsoleButton(
                      title: T.text('phoneDeny'),
                      focused: false,
                      onPressed: () => model.answerPairing(false),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A game's trophies: the counts by grade, then every trophy, earned ones first in their order.
class TrophyView extends StatelessWidget {
  const TrophyView({super.key, required this.model});

  final AppModel model;

  static Color gradeColor(TrophyGrade grade) => switch (grade) {
    TrophyGrade.platinum => const Color(0xFFD9E4F2),
    TrophyGrade.gold => const Color(0xFFF2C14E),
    TrophyGrade.silver => const Color(0xFFC0C6CF),
    TrophyGrade.bronze => const Color(0xFFC98A5B),
  };

  static String gradeName(TrophyGrade grade) => T.text(switch (grade) {
    TrophyGrade.platinum => 'gradePlatinum',
    TrophyGrade.gold => 'gradeGold',
    TrophyGrade.silver => 'gradeSilver',
    TrophyGrade.bronze => 'gradeBronze',
  });

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.selectedGame;
    final set = game == null ? null : model.trophies[game.id];
    if (set == null) return const SizedBox.shrink();
    final accent = model.accentChoice.color;
    return _Scrim(
      opacity: 0.6,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 90 * scale, vertical: 64 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 360 * scale,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(T.text('trophies'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
                  SizedBox(height: 8 * scale),
                  Text(
                    set.title.isEmpty ? game!.name : set.title,
                    style: AppText.display(18 * scale, color: Colors.white.withValues(alpha: 0.6)),
                  ),
                  SizedBox(height: 34 * scale),
                  Text('${set.percent}%', style: AppText.display(64 * scale, weight: FontWeight.w200)),
                  SizedBox(height: 10 * scale),
                  ProgressLine(fraction: set.percent / 100, color: accent, height: 6 * scale),
                  SizedBox(height: 28 * scale),
                  for (final grade in TrophyGrade.values)
                    if (set.count(grade).$2 > 0)
                      Padding(
                        padding: EdgeInsets.only(bottom: 12 * scale),
                        child: Row(
                          children: [
                            Icon(Icons.emoji_events_rounded, size: 22 * scale, color: gradeColor(grade)),
                            SizedBox(width: 12 * scale),
                            Text(gradeName(grade), style: AppText.display(17 * scale)),
                            const Spacer(),
                            Text(
                              '${set.count(grade).$1} / ${set.count(grade).$2}',
                              style: AppText.display(17 * scale, weight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
            SizedBox(width: 60 * scale),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var index = 0; index < set.trophies.length; index++)
                      KeepVisible(
                        active: index == model.trophyIndex,
                        child: Builder(
                          builder: (context) {
                            final trophy = set.trophies[index];
                            final focused = index == model.trophyIndex;
                            final earned = trophy.unlocked != null;
                            final secret = trophy.hidden && !earned;
                            final color = focused ? Colors.black : Colors.white;
                            return AnimatedContainer(
                              duration: Motion.focus,
                              curve: Motion.settle,
                              margin: EdgeInsets.only(bottom: 8 * scale),
                              padding: EdgeInsets.all(14 * scale),
                              decoration: BoxDecoration(
                                color: focused ? Colors.white : Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14 * scale),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 56 * scale,
                                    height: 56 * scale,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10 * scale),
                                      color: Colors.black.withValues(alpha: 0.3),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: trophy.icon != null && !secret
                                        ? Opacity(
                                            opacity: earned ? 1 : 0.35,
                                            child: Image.memory(
                                              trophy.icon!,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) => const SizedBox(),
                                            ),
                                          )
                                        : Icon(
                                            secret
                                                ? Icons.lock_rounded
                                                : (earned ? Icons.emoji_events_rounded : Icons.emoji_events_outlined),
                                            size: 26 * scale,
                                            color: earned
                                                ? gradeColor(trophy.grade)
                                                : Colors.white.withValues(alpha: 0.5),
                                          ),
                                  ),
                                  SizedBox(width: 16 * scale),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          secret ? T.text('trophyHidden') : trophy.name,
                                          style: AppText.display(17 * scale, weight: FontWeight.w600, color: color),
                                        ),
                                        SizedBox(height: 4 * scale),
                                        Text(
                                          secret ? T.text('trophyHiddenDetail') : trophy.detail,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6)),
                                        ),
                                        if (trophy.progress case (final value, final target)) ...[
                                          SizedBox(height: 8 * scale),
                                          SizedBox(
                                            width: 240 * scale,
                                            child: ProgressLine(
                                              fraction: value / target,
                                              color: accent,
                                              height: 4 * scale,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 16 * scale),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Icon(
                                        Icons.emoji_events_rounded,
                                        size: 22 * scale,
                                        color: gradeColor(trophy.grade),
                                      ),
                                      SizedBox(height: 6 * scale),
                                      Text(
                                        earned
                                            ? '${trophy.unlocked!.toLocal().year}-${trophy.unlocked!.toLocal().month.toString().padLeft(2, '0')}-${trophy.unlocked!.toLocal().day.toString().padLeft(2, '0')}'
                                            : T.text('trophyLocked'),
                                        style: AppText.display(12 * scale, color: color.withValues(alpha: 0.6)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A text row's field: the cursor goes in when the row is chosen (or clicked), Enter sends it,
/// Esc gives the keys back to the launcher.
class RowTextField extends StatefulWidget {
  const RowTextField({super.key, required this.model, required this.row, required this.kind, required this.focused});

  final AppModel model;
  final PanelRow row;
  final TextRow kind;
  final bool focused;

  @override
  State<RowTextField> createState() => _RowTextFieldState();
}

class _RowTextFieldState extends State<RowTextField> {
  late final TextEditingController _controller = TextEditingController(text: widget.kind.value);
  final FocusNode _node = FocusNode(debugLabel: 'row text');

  @override
  void initState() {
    super.initState();
    _node.addListener(_focusChanged);
    _follow();
  }

  @override
  void didUpdateWidget(RowTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_node.hasFocus && _controller.text != widget.kind.value) _controller.text = widget.kind.value;
    _follow();
  }

  /// The model says where the cursor is.
  void _follow() {
    final editing = widget.model.editingRow == widget.row.id;
    if (editing && !_node.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.model.editingRow == widget.row.id) _node.requestFocus();
      });
    } else if (!editing && _node.hasFocus) {
      _node.unfocus();
    }
  }

  void _focusChanged() {
    if (_node.hasFocus) {
      if (widget.model.editingRow != widget.row.id) widget.model.startEditing(widget.row.id);
    } else if (widget.model.editingRow == widget.row.id) {
      widget.model.stopEditing();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_focusChanged);
    _node.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = widget.focused ? Colors.black : Colors.white;
    final editing = widget.model.editingRow == widget.row.id;
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
      decoration: BoxDecoration(
        color: color.withValues(alpha: editing ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(10 * scale),
        border: Border.all(
          color: editing ? widget.model.accentChoice.color : color.withValues(alpha: 0.14),
          width: 1.5 * scale,
        ),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _node,
        onChanged: widget.kind.set,
        onSubmitted: (_) {
          widget.kind.submit?.call();
          widget.model.stopEditing();
        },
        cursorColor: widget.focused ? Colors.black : widget.model.accentChoice.color,
        style: AppText.display(16 * scale, weight: FontWeight.w500, color: color),
        decoration: InputDecoration.collapsed(
          hintText: widget.kind.hint,
          hintStyle: AppText.display(16 * scale, color: color.withValues(alpha: 0.35)),
        ),
      ),
    );
  }
}

/// Someone's picture, or their initials on the accent, with a dot for what they do and a ring
/// while they speak.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.person, required this.size, this.focused = false});

  final PanelPerson person;
  final double size;
  final bool focused;

  static Color statusColor(PersonStatus status) => switch (status) {
    PersonStatus.playing => const Color(0xFF6FA8FF),
    PersonStatus.online => Palette.success,
    PersonStatus.away => Palette.warning,
    PersonStatus.offline => const Color(0xFF8A8F98),
  };

  @override
  Widget build(BuildContext context) {
    final initials = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF5B6B8C), const Color(0xFF2B3346).withValues(alpha: 0.9)],
        ),
      ),
      child: Text(person.initials, style: AppText.display(size * 0.38, weight: FontWeight.w700)),
    );
    final avatar = person.avatar;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Palette.success.withValues(alpha: person.speaking ? 0.9 : 0),
                  spreadRadius: size * 0.06,
                ),
              ],
            ),
            child: ClipOval(
              child: avatar == null
                  ? initials
                  : Image.network(
                      avatar,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => initials,
                    ),
            ),
          ),
          if (person.status != null)
            Positioned(
              right: -size * 0.02,
              bottom: -size * 0.02,
              child: Container(
                width: size * 0.3,
                height: size * 0.3,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor(person.status!),
                  border: Border.all(color: focused ? Colors.white : Colors.black, width: size * 0.06),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
