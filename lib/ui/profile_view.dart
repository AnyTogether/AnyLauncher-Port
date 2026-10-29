import 'package:flutter/material.dart';

import '../core/together/levels.dart';
import '../core/together/profiles.dart';
import '../core/trophies.dart';
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'level_badge.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// Someone's AnyTogether profile: who they are and their totals on the left; their games with
/// play time and trophy progress, then their recent trophies with how rare they are, on the right.
class ProfileView extends StatelessWidget {
  const ProfileView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final page = together.profile;
    final card = together.profileCard;
    // A friend's friends-only name and picture (the user's own too), the handle under it.
    final shownCard = page?.profile.card ?? card;
    final identity = shownCard == null ? null : TogetherModel.shown(shownCard);
    final name = identity?.name ?? '';
    final handle = page?.profile.handle ?? card?.handle ?? '';
    final muted = Colors.white.withValues(alpha: 0.6);
    final totals = page?.totals;
    final level = page?.profile.trophyLevel;
    final appearing = page?.profile.isMe == true && together.appearingOffline;
    return LayerScrim(
      opacity: 0.64,
      child: Padding(
        padding: EdgeInsets.fromLTRB(90 * scale, 64 * scale, 90 * scale, 50 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 380 * scale,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(T.text('profileTitle'), style: AppText.display(18 * scale, color: muted)),
                  SizedBox(height: 22 * scale),
                  PersonAvatar(
                    person: PanelPerson(
                      name: name,
                      avatar: identity?.avatar,
                      status: appearing ? PersonStatus.offline : null,
                    ),
                    size: 112 * scale,
                  ),
                  SizedBox(height: 20 * scale),
                  Text(name, style: AppText.display(38 * scale, weight: FontWeight.w300)),
                  SizedBox(height: 6 * scale),
                  Row(
                    children: [
                      Text(
                        '@$handle',
                        style: AppText.display(16 * scale, weight: FontWeight.w500, color: muted),
                      ),
                      if (identity != null && identity.isPrivate) ...[
                        SizedBox(width: 10 * scale),
                        Icon(Icons.lock_rounded, size: 13 * scale, color: muted),
                        SizedBox(width: 4 * scale),
                        Flexible(
                          child: Text(
                            identity.publicName == identity.name
                                ? T.text('privateBadge')
                                : '${identity.publicName} · ${T.text('privateBadge')}',
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(12 * scale, weight: FontWeight.w600, color: muted),
                          ),
                        ),
                      ],
                      if (page != null && (page.profile.isMe || page.profile.friendship == 'friends')) ...[
                        SizedBox(width: 10 * scale),
                        _Tag(
                          text: page.profile.isMe ? T.text('profileYou') : T.text('profileFriend'),
                          color: model.accentChoice.color,
                        ),
                      ],
                      if (page?.profile.country case final String country) ...[
                        SizedBox(width: 10 * scale),
                        _Tag(text: country, color: Colors.white),
                      ],
                    ],
                  ),
                  if (appearing) ...[
                    SizedBox(height: 10 * scale),
                    _Tag(text: T.text('presenceAppearing'), color: PersonAvatar.statusColor(PersonStatus.offline)),
                  ],
                  if (page?.profile.bio case final String bio) ...[
                    SizedBox(height: 16 * scale),
                    Text(
                      bio,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.8), height: 1.4),
                    ),
                  ],
                  if (page?.detailsPrivate == true) ...[
                    SizedBox(height: 14 * scale),
                    Text(T.text('profileDetailsPrivate'), style: AppText.display(14 * scale, color: muted)),
                  ],
                  if (level != null) ...[
                    SizedBox(height: 22 * scale),
                    SizedBox(
                      width: 368 * scale,
                      child: LevelCard(level: level, accent: model.accentChoice.color),
                    ),
                  ],
                  SizedBox(height: level != null ? 14 * scale : 30 * scale),
                  if (totals != null)
                    Wrap(
                      spacing: 12 * scale,
                      runSpacing: 12 * scale,
                      children: [
                        _Total(label: T.text('profileGames'), value: '${totals.games}'),
                        _Total(label: T.text('profileHours'), value: '${totals.seconds ~/ 3600}'),
                        _Total(label: T.text('profileTrophies'), value: '${totals.trophies}'),
                        _Total(label: T.text('profilePoints'), value: '${totals.points}'),
                      ],
                    ),
                  if (together.canCompare) ...[
                    SizedBox(height: 18 * scale),
                    _CompareButton(focused: together.profileIndex == 0, onTap: together.compareProfile),
                  ],
                ],
              ),
            ),
            SizedBox(width: 60 * scale),
            Expanded(
              child: page == null
                  ? Center(
                      child: Text(
                        together.profileFailed ? T.text('profileFailed') : T.text('profileLoading'),
                        style: AppText.display(18 * scale, color: muted),
                      ),
                    )
                  : _Sections(model: model, page: page),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sections extends StatelessWidget {
  const _Sections({required this.model, required this.page});

  final AppModel model;
  final ProfilePage page;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final language = T.language.code;
    final games = page.library.value ?? const <PlayedGame>[];
    final trophies = page.trophies.value ?? const <EarnedTrophy>[];
    final accent = model.accentChoice.color;
    String closed(Section<Object?> section, String empty) => switch (section) {
      SectionPrivate() =>
        page.profile.friendship == 'friends'
            ? T.format('profilePrivate', [page.profile.displayName])
            : T.format('profileFriendsOnly', [page.profile.displayName]),
      SectionFailed() => T.text('profileFailed'),
      SectionShown() => empty,
    };
    Widget heading(String text) => Padding(
      padding: EdgeInsets.only(bottom: 12 * scale, top: 6 * scale),
      child: Text(text, style: AppText.display(22 * scale, weight: FontWeight.w500)),
    );
    Widget note(String text) => Padding(
      padding: EdgeInsets.only(bottom: 22 * scale),
      child: Text(text, style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.55))),
    );
    final from = together.profileGamesFrom;
    final showcase = page.showcase;
    final pinned = showcase.value;
    final private = T.format('profilePrivate', [page.profile.displayName]);
    Widget subheading(String text) => Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: Text(
        text.toUpperCase(),
        style: AppText.display(
          12 * scale,
          weight: FontWeight.w700,
          color: Colors.white.withValues(alpha: 0.55),
        ).copyWith(letterSpacing: 1.2 * scale),
      ),
    );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // What they pinned: nothing on a server without showcases, or with nothing pinned.
          if (showcase is SectionPrivate<Showcase> || (pinned != null && pinned.private)) ...[
            heading(T.text('showcaseTitle')),
            note(private),
          ] else if (pinned != null && !pinned.empty) ...[
            heading(T.text('showcaseTitle')),
            if (pinned.trophies case final List<EarnedTrophy> list when list.isNotEmpty) ...[
              subheading(T.text('showcaseTrophies')),
              Wrap(
                spacing: 10 * scale,
                runSpacing: 10 * scale,
                children: [for (final trophy in list) _PinnedTrophy(trophy: trophy, language: language)],
              ),
              SizedBox(height: 18 * scale),
            ] else if (pinned.trophies == null) ...[
              subheading(T.text('showcaseTrophies')),
              note(private),
            ],
            if (pinned.games case final List<PlayedGame> list when list.isNotEmpty) ...[
              subheading(T.text('showcaseGames')),
              Wrap(
                spacing: 14 * scale,
                runSpacing: 14 * scale,
                children: [for (final game in list) _PinnedGame(model: model, game: game, accent: accent)],
              ),
              SizedBox(height: 18 * scale),
            ] else if (pinned.games == null) ...[
              subheading(T.text('showcaseGames')),
              note(private),
            ],
            SizedBox(height: 10 * scale),
          ],
          heading(T.text('profileGamesTitle')),
          if (games.isEmpty) note(closed(page.library, T.text('profileNoGames'))),
          for (var index = 0; index < games.length; index++)
            KeepVisible(
              active: together.profileIndex == from + index,
              child: _GameRow(
                model: model,
                game: games[index],
                focused: together.profileIndex == from + index,
                accent: accent,
              ),
            ),
          SizedBox(height: 18 * scale),
          heading(T.text('profileRecentTrophies')),
          if (trophies.isEmpty) note(closed(page.trophies, T.text('profileNoTrophies'))),
          for (var index = 0; index < trophies.length; index++)
            KeepVisible(
              active: together.profileIndex == from + games.length + index,
              child: _TrophyRow(
                trophy: trophies[index],
                language: language,
                focused: together.profileIndex == from + games.length + index,
              ),
            ),
        ],
      ),
    );
  }
}

class _GameRow extends StatelessWidget {
  const _GameRow({required this.model, required this.game, required this.focused, required this.accent});

  final AppModel model;
  final PlayedGame game;
  final bool focused;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final local = model.games.where((known) => known.titleId == game.titleId).firstOrNull;
    final color = focused ? LookScope.focusedInk(context) : Colors.white;
    final last = game.lastPlayedAt?.toLocal();
    final detail = [
      TogetherProfiles.playTime(game.secondsPlayed),
      if (last != null)
        T.format('profileLastPlayed', [
          '${last.year}-${last.month.toString().padLeft(2, '0')}-${last.day.toString().padLeft(2, '0')}',
        ]),
    ].join(' · ');
    return PaneRow(
      focused: focused,
      radius: 14 * scale,
      margin: EdgeInsets.only(bottom: 8 * scale),
      padding: EdgeInsets.all(12 * scale),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10 * scale),
            child: SizedBox.square(
              dimension: 56 * scale,
              child: local?.icon != null
                  ? ArtworkImage(path: local!.icon!, cacheWidth: 160)
                  : ColoredBox(
                      color: Colors.white.withValues(alpha: 0.08),
                      child: Icon(Icons.sports_esports_rounded, size: 26 * scale, color: color.withValues(alpha: 0.5)),
                    ),
            ),
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  local?.nameFor([T.language.code]) ?? game.name(T.language.code),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(17 * scale, weight: FontWeight.w600, color: color),
                ),
                SizedBox(height: 4 * scale),
                Text(detail, style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6))),
                if (game.progress != null) ...[
                  SizedBox(height: 8 * scale),
                  SizedBox(
                    width: 260 * scale,
                    child: ProgressLine(fraction: game.progress! / 100, color: accent, height: 4 * scale),
                  ),
                ],
              ],
            ),
          ),
          if (game.trophiesEarned != null) ...[
            SizedBox(width: 16 * scale),
            Icon(Icons.emoji_events_rounded, size: 20 * scale, color: color.withValues(alpha: 0.7)),
            SizedBox(width: 6 * scale),
            Text(
              game.trophiesTotal == null ? '${game.trophiesEarned}' : '${game.trophiesEarned}/${game.trophiesTotal}',
              style: AppText.display(15 * scale, weight: FontWeight.w600, color: color),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrophyRow extends StatelessWidget {
  const _TrophyRow({required this.trophy, required this.language, required this.focused});

  final EarnedTrophy trophy;
  final String language;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = focused ? LookScope.focusedInk(context) : Colors.white;
    final grade = TrophyGrade.values.where((value) => value.name == trophy.grade).firstOrNull ?? TrophyGrade.bronze;
    final rarity = TogetherProfiles.rarity(trophy.rarityLabel);
    final percent = trophy.rarity == null
        ? null
        : T.percent(T.decimal(trophy.rarity! * 100, trophy.rarity! < 0.1 ? 1 : 0));
    return PaneRow(
      focused: focused,
      radius: 14 * scale,
      margin: EdgeInsets.only(bottom: 8 * scale),
      padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale),
      child: Row(
        children: [
          Icon(Icons.emoji_events_rounded, size: 28 * scale, color: TrophyView.gradeColor(grade)),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trophy.name(language) ?? T.text('trophyHidden'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(16 * scale, weight: FontWeight.w600, color: color),
                ),
                SizedBox(height: 3 * scale),
                Text(
                  trophy.gameName(language),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          if (rarity.isNotEmpty)
            Text(
              percent == null ? rarity : '$rarity · $percent',
              style: AppText.display(13 * scale, weight: FontWeight.w600, color: color.withValues(alpha: 0.7)),
            ),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      width: 178 * scale,
      padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 14 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14 * scale),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: AppText.display(30 * scale, weight: FontWeight.w300)),
          SizedBox(height: 2 * scale),
          Text(
            label.toUpperCase(),
            style: AppText.display(11 * scale, weight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6 * scale)),
      child: Text(
        text,
        style: AppText.display(12 * scale, weight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// Compare trophies, under a profile's totals: focused first when the profile opens.
class _CompareButton extends StatelessWidget {
  const _CompareButton({required this.focused, required this.onTap});

  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Pressable(
      onTap: onTap,
      pressScale: 0.98,
      builder: (context, hovering) {
        final ink = focused ? Colors.black : Colors.white;
        return AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          width: 368 * scale,
          padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 14 * scale),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.12 : 0.06),
            borderRadius: BorderRadius.circular(14 * scale),
            border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withValues(alpha: focused ? 0.22 : 0),
                blurRadius: 16 * scale,
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(Icons.compare_arrows_rounded, size: 22 * scale, color: ink),
              SizedBox(width: 12 * scale),
              Expanded(
                child: Text(
                  T.text('compareTrophies'),
                  style: AppText.display(16 * scale, weight: FontWeight.w600, color: ink),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 22 * scale, color: ink.withValues(alpha: 0.6)),
            ],
          ),
        );
      },
    );
  }
}

/// A pinned trophy: its grade's cup, its name and its game.
class _PinnedTrophy extends StatelessWidget {
  const _PinnedTrophy({required this.trophy, required this.language});

  final EarnedTrophy trophy;
  final String language;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final grade = TrophyGrade.values.where((value) => value.name == trophy.grade).firstOrNull ?? TrophyGrade.bronze;
    final color = TrophyView.gradeColor(grade);
    return Container(
      width: 300 * scale,
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 12 * scale),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14 * scale),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.04)],
        ),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(Icons.emoji_events_rounded, size: 26 * scale, color: color),
          SizedBox(width: 12 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trophy.name(language) ?? T.text('trophyHidden'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(15 * scale, weight: FontWeight.w600),
                ),
                SizedBox(height: 2 * scale),
                Text(
                  trophy.gameName(language),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(12.5 * scale, color: Colors.white.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A favourite game: its icon (from this library when it is here), its name, its progress.
class _PinnedGame extends StatelessWidget {
  const _PinnedGame({required this.model, required this.game, required this.accent});

  final AppModel model;
  final PlayedGame game;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final local = model.games.where((known) => known.titleId == game.titleId).firstOrNull;
    return SizedBox(
      width: 112 * scale,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16 * scale),
            child: SizedBox.square(
              dimension: 112 * scale,
              child: local?.icon != null
                  ? ArtworkImage(path: local!.icon!, cacheWidth: 240)
                  : ColoredBox(
                      color: Colors.white.withValues(alpha: 0.08),
                      child: Icon(
                        Icons.sports_esports_rounded,
                        size: 36 * scale,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
            ),
          ),
          SizedBox(height: 8 * scale),
          Text(
            local?.nameFor([T.language.code]) ?? game.name(T.language.code),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(13.5 * scale, weight: FontWeight.w600),
          ),
          if (game.progress != null) ...[
            SizedBox(height: 6 * scale),
            ProgressLine(fraction: game.progress! / 100, color: accent, height: 3 * scale),
          ],
        ],
      ),
    );
  }
}
