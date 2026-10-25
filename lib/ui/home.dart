import 'dart:async';

import 'package:flutter/material.dart';

import '../core/audio/tones.dart';
import '../core/family/family_rules.dart' show TitleVerdict;
import '../core/game_library.dart';
import 'app_model.dart';
import 'background.dart';
import 'components.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// The theme animation and the selected game's artwork over it.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.model, this.time});

  final AppModel model;

  /// A fixed moment of the theme animation, for previews and tests.
  final double? time;

  @override
  Widget build(BuildContext context) {
    final game = model.selectedGame;
    final artwork =
        model.preferences.onboarded &&
        model.preferences.gameArtwork &&
        model.overlay != Layer.settings &&
        game?.background != null;
    // Under a layer the background is blurred and darkened: kept still, the blur is not worked
    // out again on every frame, which is what made opening and closing layers stutter.
    final covered = model.overlay != null || model.starting != null;
    if (artwork && time == null) {
      final index = model.selected;
      for (final near in [index - 1, index + 1]) {
        if (near >= 0 && near < model.games.length) {
          ArtworkImage.warm(context, model.games[near].background, cacheWidth: GameArtwork.cacheWidth);
        }
      }
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ThemeBackground(
          style: model.look,
          paused: model.running != null || model.preferences.reducedMotion || covered,
          time: time,
        ),
        RepaintBoundary(
          child: AnimatedSwitcher(
            duration: Motion.fade,
            switchInCurve: Motion.settle,
            child: artwork
                ? GameArtwork(
                    key: ValueKey(game!.id),
                    path: game.background!,
                    animated: !model.preferences.reducedMotion && time == null && !covered,
                  )
                : const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class HomeView extends StatelessWidget {
  const HomeView({super.key, required this.model, this.now});

  final AppModel model;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.selectedGame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(64 * scale, 34 * scale, 64 * scale, 0),
          child: TopBar(model: model, now: now),
        ),
        if (model.games.isEmpty)
          Expanded(child: EmptyLibrary(model: model))
        else ...[
          SizedBox(height: 34 * scale),
          TileRow(model: model),
          const Spacer(),
          if (game != null)
            AnimatedSwitcher(
              duration: Motion.layout,
              switchInCurve: Motion.settle,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(animation),
                  child: child,
                ),
              ),
              child: Padding(
                key: ValueKey(game.id),
                padding: EdgeInsets.symmetric(horizontal: 72 * scale),
                child: HeroInfo(model: model, game: game),
              ),
            ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 64 * scale, vertical: 28 * scale),
            child: const Align(alignment: Alignment.centerRight, child: HintBar()),
          ),
        ],
      ],
    );
  }
}

class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.model, this.now});

  final AppModel model;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final together = model.together;
    final name = together.user?.displayName ?? model.preferences.profileName;
    Widget iconButton(IconData icon, int index, VoidCallback action, {int badge = 0}) {
      final focused = model.focus == HomeFocus.top(index) && model.overlay == null;
      return Pressable(
        onTap: action,
        builder: (context, hovering) => AnimatedScale(
          scale: focused ? 1.1 : (hovering ? 1.05 : 1),
          duration: Motion.focus,
          curve: Motion.settle,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: Motion.focus,
                width: 44 * scale,
                height: 44 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.2 : 0.1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: focused ? 0.4 : 0),
                      blurRadius: 10 * scale,
                    ),
                  ],
                ),
                child: Icon(
                  icon,
                  size: 20 * scale,
                  color: focused ? Colors.black : Colors.white.withValues(alpha: 0.9),
                ),
              ),
              if (badge > 0)
                Positioned(
                  right: -4 * scale,
                  top: -4 * scale,
                  child: Container(
                    constraints: BoxConstraints(minWidth: 20 * scale),
                    height: 20 * scale,
                    padding: EdgeInsets.symmetric(horizontal: 5 * scale),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(10 * scale),
                      border: Border.all(color: Colors.black.withValues(alpha: 0.5), width: 1.5 * scale),
                    ),
                    child: Text(
                      badge > 9 ? '9+' : '$badge',
                      style: AppText.display(11 * scale, weight: FontWeight.w700, color: Colors.black),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        Text(T.text('games'), style: AppText.display(24 * scale, weight: FontWeight.w600)),
        if (model.scanning) ...[
          SizedBox(width: 16 * scale),
          SizedBox(
            width: 16 * scale,
            height: 16 * scale,
            child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
        ],
        const Spacer(),
        iconButton(Icons.grid_view_rounded, 0, () => model.open(Layer.library)),
        SizedBox(width: 22 * scale),
        iconButton(Icons.settings_rounded, 1, () => model.open(Layer.settings)),
        SizedBox(width: 22 * scale),
        iconButton(Icons.people_alt_rounded, 2, () => model.open(Layer.friends), badge: together.hub.badge),
        SizedBox(width: 22 * scale),
        iconButton(Icons.chat_bubble_rounded, 3, () => unawaited(together.openMessages()), badge: together.unread),
        SizedBox(width: 22 * scale),
        iconButton(
          together.hub.voice.active
              ? (together.hub.voice.sending ? Icons.mic_rounded : Icons.mic_off_rounded)
              : (together.hub.parties.party == null ? Icons.groups_outlined : Icons.groups_rounded),
          4,
          () => model.open(Layer.party),
          badge: together.partyBadge,
        ),
        SizedBox(width: 22 * scale),
        PhoneIndicator(model: model),
        SizedBox(width: 22 * scale),
        Container(
          width: 36 * scale,
          height: 36 * scale,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent, accent.withValues(alpha: 0.55)],
            ),
          ),
          child: Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: AppText.display(16 * scale, weight: FontWeight.w700),
          ),
        ),
        SizedBox(width: 10 * scale),
        Text(
          name,
          style: AppText.display(16 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.9)),
        ),
        SizedBox(width: 22 * scale),
        Clock(now: now),
      ],
    );
  }
}

/// The phone controller's light: green with a phone, orange while one connects, a ring with none.
class PhoneIndicator extends StatelessWidget {
  const PhoneIndicator({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final phones = model.remote?.connectedDevices ?? const [];
    final color = phones.isNotEmpty ? Palette.success : (model.phoneConnecting != null ? Palette.connecting : null);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(40 * scale),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9 * scale,
            height: 9 * scale,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: color == null
                  ? Border.all(color: Colors.white.withValues(alpha: 0.45), width: 1.5 * scale)
                  : null,
              boxShadow: color == null ? null : [BoxShadow(color: color, blurRadius: 4 * scale)],
            ),
          ),
          SizedBox(width: 8 * scale),
          Text(
            phones.length > 1 ? '${phones.length} × mController' : 'mController',
            style: AppText.display(
              14 * scale,
              weight: FontWeight.w600,
              color: Colors.white.withValues(alpha: color == null ? 0.55 : 0.9),
            ),
          ),
          if (phones.isNotEmpty && model.phoneLatency != null) ...[
            SizedBox(width: 8 * scale),
            Text(
              '${model.phoneLatency!.round()} ms',
              style: AppText.display(14 * scale, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.6)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The row of game tiles: the selected one is larger, sits at the row's start and carries the
/// game's name beside it, as on the console.
class TileRow extends StatelessWidget {
  const TileRow({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final small = 118 * scale;
    final large = 176 * scale;
    final gap = 16 * scale;
    final label = 300 * scale;
    final leading = 64 * scale;
    return SizedBox(
      height: large + 10 * scale,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var index = 0; index < model.games.length; index++)
            ...() {
              final game = model.games[index];
              final selected = index == model.selected;
              final offset = index - model.selected;
              final x = offset < 0
                  ? leading + offset * (small + gap)
                  : offset == 0
                  ? leading
                  : leading + large + gap + label + (offset - 1) * (small + gap);
              final size = selected ? large : small;
              return [
                AnimatedPositioned(
                  key: ValueKey('tile-${game.id}'),
                  duration: Motion.layout,
                  curve: Motion.settle,
                  left: x,
                  top: selected ? 0 : (large - small) * 0.18,
                  width: size,
                  height: size,
                  child: AnimatedOpacity(
                    duration: Motion.layout,
                    opacity: offset < 0 ? 0 : 1,
                    // A click selects at once (a GestureDetector with a double tap would wait to
                    // see whether a second click comes); a second click plays.
                    child: Pressable(
                      key: ValueKey('tile-press-${game.id}'),
                      onTap: () {
                        if (model.selected != index) model.sounds.play(Cue.move);
                        model.select(index);
                      },
                      onDoubleTap: () {
                        model.select(index);
                        model.primaryAction(game);
                      },
                      builder: (context, _) => GameTile(
                        model: model,
                        game: game,
                        size: size,
                        focused: selected && model.focus.isTiles && model.overlay == null,
                      ),
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    key: ValueKey('label-${game.id}'),
                    left: leading + large + gap * 1.4,
                    top: large * 0.32,
                    width: label - gap,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          game.nameFor([T.language.code]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(22 * scale, weight: FontWeight.w600),
                        ),
                        SizedBox(height: 6 * scale),
                        StateLabel(model: model, state: model.stateOf(game)),
                      ],
                    ),
                  ),
              ];
            }(),
        ],
      ),
    );
  }
}

class GameTile extends StatelessWidget {
  const GameTile({super.key, required this.model, required this.game, required this.size, required this.focused});

  final AppModel model;
  final Game game;
  final double size;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final state = model.stateOf(game);
    final radius = size * 0.12;
    final accent = model.accentChoice.color;
    return FocusRing(
      focused: focused,
      radius: radius,
      child: AnimatedContainer(
        duration: Motion.focus,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: Colors.white.withValues(alpha: 0.08),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: (focused ? 22 : 10) * scale,
              offset: Offset(0, 8 * scale),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (game.icon != null)
                ArtworkImage(path: game.icon!, cacheWidth: 400)
              else
                Icon(Icons.sports_esports_rounded, size: size * 0.32, color: Colors.white.withValues(alpha: 0.5)),
              ..._overlay(state, accent),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _overlay(GameState state, Color accent) {
    Widget badge(IconData icon) => Align(
      alignment: Alignment.bottomRight,
      child: Container(
        margin: EdgeInsets.all(size * 0.045),
        padding: EdgeInsets.all(size * 0.04),
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.55)),
        child: Icon(icon, size: size * 0.13, color: Colors.white),
      ),
    );
    final dim = ColoredBox(color: Colors.black.withValues(alpha: 0.42));
    return switch (state) {
      Locked() => [dim, badge(Icons.lock_rounded)],
      FamilyLocked() => [dim, badge(Icons.family_restroom_rounded)],
      Unreadable() => [dim, badge(Icons.block_rounded)],
      Failed() => [dim, badge(Icons.warning_rounded)],
      Installing(:final overall) => [
        ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(size * 0.07),
            child: ProgressLine(fraction: overall, color: accent, height: (size * 0.03).clamp(3, 8)),
          ),
        ),
      ],
      Queued() => [
        dim,
        Center(
          child: Icon(Icons.schedule_rounded, size: size * 0.18, color: Colors.white.withValues(alpha: 0.85)),
        ),
      ],
      Starting() => [
        dim,
        Center(
          child: SizedBox.square(
            dimension: size * 0.16,
            child: const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
          ),
        ),
      ],
      Running() => [
        Align(
          alignment: Alignment.topRight,
          child: Container(
            margin: EdgeInsets.all(size * 0.07),
            width: size * 0.09,
            height: size * 0.09,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent,
              boxShadow: [BoxShadow(color: accent, blurRadius: 6)],
            ),
          ),
        ),
      ],
      Installed() => const [],
    };
  }
}

class StateLabel extends StatelessWidget {
  const StateLabel({super.key, required this.model, required this.state, this.size = 14});

  final AppModel model;
  final GameState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final dim = Colors.white.withValues(alpha: 0.75);
    final (icon, text, tint) = switch (state) {
      Locked() => (Icons.lock_rounded, T.text('locked'), dim),
      FamilyLocked(:final verdict) => (
        Icons.family_restroom_rounded,
        T.text(verdict == TitleVerdict.unknown ? 'familyNotRated' : 'familyAgeLocked'),
        Palette.warning,
      ),
      Unreadable() => (Icons.block_rounded, T.text('unreadableDump'), Palette.danger),
      Queued() => (Icons.schedule_rounded, T.text('queued'), dim),
      Installing(:final step) => (Icons.downloading_rounded, InstallSpan.title(step), accent),
      Failed() => (Icons.warning_rounded, T.text('failed'), Palette.danger),
      Installed(outdated: true) => (Icons.sync_rounded, T.text('updateAvailable'), Palette.warning),
      Installed() => (Icons.check_circle_rounded, T.text('ready'), dim),
      Starting() => (Icons.hourglass_top_rounded, T.text('starting'), accent),
      Running() => (Icons.play_circle_rounded, T.text('running'), accent),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: (size + 2) * scale, color: tint),
        SizedBox(width: 6 * scale),
        Flexible(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(size * scale, weight: FontWeight.w500, color: tint),
          ),
        ),
      ],
    );
  }
}

/// The selected game's title, its main button and the facts about it.
class HeroInfo extends StatelessWidget {
  const HeroInfo({super.key, required this.model, required this.game});

  final AppModel model;
  final Game game;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final state = model.stateOf(game);
    final accent = model.accentChoice.color;
    final (title, icon) = switch (state) {
      Installed() => (T.text('play'), Icons.play_arrow_rounded),
      Locked() || Unreadable() => (T.text('unlock'), Icons.lock_open_rounded),
      Failed() => (T.text('retry'), Icons.refresh_rounded),
      Installing() || Queued() => (T.text('cancel'), Icons.close_rounded),
      Starting() => (T.text('starting'), Icons.hourglass_top_rounded),
      Running() => (T.text('running'), Icons.play_circle_outline_rounded),
      FamilyLocked() => (T.text('familyAskParent'), Icons.family_restroom_rounded),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          game.nameFor([T.language.code]),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.display(
            58 * scale,
            weight: FontWeight.w300,
            height: 1.08,
          ).copyWith(shadows: [Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 12)]),
        ),
        SizedBox(height: 22 * scale),
        Row(
          children: [
            ConsoleButton(
              title: title,
              icon: icon,
              focused: model.focus == const HomeFocus.actions(0) && model.overlay == null,
              prominent: true,
              minWidth: 210,
              onPressed: () {
                model.focus = const HomeFocus.actions(0);
                model.primaryAction(game);
              },
            ),
            if (model.trophies[game.id] case final set?) ...[
              SizedBox(width: 16 * scale),
              ConsoleButton(
                title: '${set.unlockedCount}/${set.trophies.length}',
                icon: Icons.emoji_events_rounded,
                focused: model.focus == const HomeFocus.actions(1) && model.overlay == null,
                onPressed: () {
                  model.focus = const HomeFocus.actions(1);
                  model.open(Layer.trophies);
                },
              ),
            ],
            SizedBox(width: 16 * scale),
            ConsoleButton(
              title: '',
              icon: Icons.more_horiz_rounded,
              focused: model.focus == HomeFocus.actions(model.settingsAction) && model.overlay == null,
              onPressed: () {
                model.focus = HomeFocus.actions(model.settingsAction);
                model.open(Layer.gameSettings);
              },
            ),
            SizedBox(width: 26 * scale),
            if (state is Installing)
              SizedBox(
                width: 340 * scale,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          InstallSpan.title(state.step),
                          style: AppText.display(
                            15 * scale,
                            weight: FontWeight.w500,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${(state.overall * 100).round()}%',
                          style: AppText.display(
                            15 * scale,
                            weight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8 * scale),
                    if (state.step.name == 'relink' && state.fraction == 0)
                      IndeterminateLine(color: accent)
                    else
                      ProgressLine(fraction: state.overall, color: accent),
                  ],
                ),
              )
            else if (state is Failed)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 520 * scale),
                child: Text(
                  state.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(14 * scale, color: Palette.danger),
                ),
              ),
          ],
        ),
        SizedBox(height: 22 * scale),
        Wrap(
          spacing: 14 * scale,
          runSpacing: 14 * scale,
          children: [
            InfoCard(
              title: T.text('status'),
              icon: Icons.donut_large_rounded,
              child: StateLabel(model: model, state: state, size: 16),
            ),
            InfoCard(
              title: T.text('size'),
              icon: Icons.storage_rounded,
              child: Text(byteText(model.sizes[game.id]), style: AppText.display(17 * scale, weight: FontWeight.w600)),
            ),
            InfoCard(
              title: T.text('titleID'),
              icon: Icons.tag_rounded,
              child: Text(game.titleId, style: AppText.display(17 * scale, weight: FontWeight.w600)),
            ),
            InfoCard(
              title: T.text('version'),
              icon: Icons.sell_rounded,
              child: Text(game.version, style: AppText.display(17 * scale, weight: FontWeight.w600)),
            ),
          ],
        ),
      ],
    );
  }
}

class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final label = Colors.white.withValues(alpha: 0.55);
    return SizedBox(
      width: 236 * scale,
      height: 96 * scale,
      child: Glass(
        radius: 16 * scale,
        padding: EdgeInsets.all(18 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14 * scale, color: label),
                SizedBox(width: 6 * scale),
                Text(
                  title.toUpperCase(),
                  style: AppText.display(
                    12 * scale,
                    weight: FontWeight.w600,
                    color: label,
                  ).copyWith(letterSpacing: 0.6),
                ),
              ],
            ),
            SizedBox(height: 10 * scale),
            child,
          ],
        ),
      ),
    );
  }
}

class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final folder = model.preferences.gamesFolder;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            model.scanning ? Icons.search_rounded : Icons.layers_clear_outlined,
            size: 54 * scale,
            color: Colors.white.withValues(alpha: 0.8),
          ),
          SizedBox(height: 18 * scale),
          Text(
            T.text(model.scanning ? 'scanning' : 'emptyLibraryTitle'),
            style: AppText.display(34 * scale, weight: FontWeight.w300),
          ),
          SizedBox(height: 12 * scale),
          Text(
            T.text('emptyLibraryText'),
            style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.65)),
          ),
          if (folder != null) ...[
            SizedBox(height: 12 * scale),
            Text(folder, style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.45))),
          ],
          SizedBox(height: 28 * scale),
          ConsoleButton(
            title: T.text('changeFolder'),
            icon: Icons.folder_rounded,
            focused: true,
            onPressed: model.chooseGamesFolder,
          ),
        ],
      ),
    );
  }
}
