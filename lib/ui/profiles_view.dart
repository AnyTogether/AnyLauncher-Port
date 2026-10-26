import 'package:flutter/material.dart';

import '../core/profiles/profiles.dart';
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'strings.dart';
import 'theme.dart';

/// A profile's round tile: its initial on its colour, lit from the top left, and the
/// controller's light-bar strip in that colour under it.
class ProfileTile extends StatelessWidget {
  const ProfileTile({super.key, required this.profile, required this.size, this.focused = false});

  final LauncherProfile? profile;
  final double size;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = LauncherProfiles.colorOf(profile);
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.45)!],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: focused ? 0.95 : 0.16),
          width: (focused ? 4 : 1.5) * scale,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: focused ? 0.6 : 0.22),
            blurRadius: (focused ? 34 : 14) * scale,
          ),
        ],
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.7, -0.7),
            radius: 0.9,
            colors: [Colors.white.withValues(alpha: 0.26), Colors.white.withValues(alpha: 0)],
          ),
        ),
        child: Center(
          child: Text(profile?.initial ?? '?', style: AppText.display(size * 0.42, weight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// "Who's playing?": every profile as a tile, the one in use first, and Add Profile.
class ProfilePickerView extends StatelessWidget {
  const ProfilePickerView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final tiles = model.profiles.book.pickerOrder;
    final flow = model.profileFlow;
    return LayerScrim(
      opacity: 0.74,
      child: Padding(
        padding: EdgeInsets.only(top: 120 * scale, bottom: 54 * scale),
        child: Column(
          children: [
            Text(
              T.text('profileKicker').toUpperCase(),
              style: AppText.display(
                13 * scale,
                weight: FontWeight.w700,
                color: model.accentChoice.color,
              ).copyWith(letterSpacing: 2.2 * scale),
            ),
            SizedBox(height: 10 * scale),
            Text(T.text('profileWhoIsPlaying'), style: AppText.display(60 * scale, weight: FontWeight.w300)),
            SizedBox(height: 8 * scale),
            Text(
              T.text(flow.atLaunch ? 'profilePickerSubtitleLaunch' : 'profilePickerSubtitle'),
              style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.62)),
            ),
            SizedBox(height: 70 * scale),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = 0; index < tiles.length; index++)
                  _PickerTile(
                    focused: flow.pickerIndex == index,
                    onTap: () {
                      flow.pickerIndex = index;
                      model.pickerCommand(Command.select);
                    },
                    avatar: ProfileTile(profile: tiles[index], size: 168 * scale, focused: flow.pickerIndex == index),
                    strip: LauncherProfiles.colorOf(tiles[index]),
                    name: tiles[index].name,
                    line: _modeLine(
                      tiles[index],
                      current: tiles[index].id == model.currentProfile?.id && !flow.atLaunch,
                    ),
                  ),
                _PickerTile(
                  focused: flow.pickerIndex == tiles.length,
                  onTap: () {
                    flow.pickerIndex = tiles.length;
                    model.pickerCommand(Command.select);
                  },
                  avatar: _AddCircle(size: 168 * scale, focused: flow.pickerIndex == tiles.length),
                  strip: Colors.white.withValues(alpha: 0.3),
                  name: T.text('profileAdd'),
                ),
              ],
            ),
            const Spacer(),
            Wrap(
              spacing: 10 * scale,
              children: [
                Hint(keys: '← →', label: T.text('hintMove')),
                Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('profileHintPlay'), action: HintAction.select),
                if (!flow.atLaunch) ...[
                  Hint(keys: 'O', glyph: PadGlyph.triangle, label: T.text('profileManage'), action: HintAction.options),
                  Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeLine(LauncherProfile profile, {required bool current}) {
    final online = profile.mode == ProfileMode.online;
    final text = online
        ? (profile.account == null ? T.text('profileOnline') : '@${profile.account!.handle}')
        : T.text('profileOffline');
    return Builder(
      builder: (context) {
        final scale = LayoutScale.of(context);
        final color = Colors.white.withValues(alpha: 0.62);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(online ? Icons.people_alt_rounded : Icons.wifi_off_rounded, size: 13 * scale, color: color),
            SizedBox(width: 6 * scale),
            Flexible(
              child: Text(
                current ? '$text · ${T.text('profilePlayingNow')}' : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(13 * scale, weight: FontWeight.w500, color: color),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.focused,
    required this.onTap,
    required this.avatar,
    required this.strip,
    required this.name,
    this.line,
  });

  final bool focused;
  final VoidCallback onTap;
  final Widget avatar;
  final Color strip;
  final String name;
  final Widget? line;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 23 * scale),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: focused ? 1 : 0.78,
          duration: Motion.focus,
          curve: Motion.settle,
          child: AnimatedScale(
            scale: focused ? 1.06 : 0.96,
            duration: Motion.focus,
            curve: Motion.settle,
            child: SizedBox(
              width: 190 * scale,
              child: Column(
                children: [
                  avatar,
                  SizedBox(height: 18 * scale),
                  // The light bar of the profile's controller.
                  AnimatedContainer(
                    duration: Motion.focus,
                    curve: Motion.settle,
                    width: (focused ? 54 : 30) * scale,
                    height: 4 * scale,
                    decoration: BoxDecoration(
                      color: strip.withValues(alpha: focused ? 1 : 0.55),
                      borderRadius: BorderRadius.circular(2 * scale),
                    ),
                  ),
                  SizedBox(height: 18 * scale),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(23 * scale, weight: focused ? FontWeight.w600 : FontWeight.w400),
                  ),
                  if (line != null) ...[SizedBox(height: 6 * scale), line!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddCircle extends StatelessWidget {
  const _AddCircle({required this.size, required this.focused});

  final double size;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: focused ? 0.16 : 0.06),
        border: Border.all(
          color: Colors.white.withValues(alpha: focused ? 0.95 : 0.3),
          width: (focused ? 4 : 1.5) * scale,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: focused ? 0.22 : 0),
            blurRadius: 26 * scale,
          ),
        ],
      ),
      child: Icon(
        Icons.add_rounded,
        size: 56 * scale,
        color: Colors.white.withValues(alpha: focused ? 1 : 0.7),
      ),
    );
  }
}

/// Offline or online: two cards, the focused one lifted. The first start's last step and Add
/// Profile.
class ProfileModeCards extends StatelessWidget {
  const ProfileModeCards({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ModeCard(
          model: model,
          index: 0,
          icon: Icons.wifi_off_rounded,
          title: T.text('profileOfflineTitle'),
          lead: T.text('profileOfflineLead'),
          facts: [T.text('profileOfflineFact1'), T.text('profileOfflineFact2'), T.text('profileOfflineFact3')],
          tag: T.text('profileOfflineTag'),
        ),
        SizedBox(width: 28 * scale),
        _ModeCard(
          model: model,
          index: 1,
          icon: Icons.people_alt_rounded,
          title: T.text('profileOnlineTitle'),
          lead: T.text('profileOnlineLead'),
          facts: [T.text('profileOnlineFact1'), T.text('profileOnlineFact2'), T.text('profileOnlineFact3')],
          tag: T.text('profileOnlineTag'),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.model,
    required this.index,
    required this.icon,
    required this.title,
    required this.lead,
    required this.facts,
    required this.tag,
  });

  final AppModel model;
  final int index;
  final IconData icon;
  final String title;
  final String lead;
  final List<String> facts;
  final String tag;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final focused = model.profileFlow.modeChoice == index;
    final ink = focused ? Colors.black : Colors.white;
    final chip = focused ? Colors.black.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.1);
    return GestureDetector(
      onTap: () {
        model.profileFlow.modeChoice = index;
        model.modeChoiceCommand(Command.select);
      },
      child: AnimatedScale(
        scale: focused ? 1.03 : 0.98,
        duration: Motion.focus,
        curve: Motion.settle,
        child: AnimatedOpacity(
          opacity: focused ? 1 : 0.8,
          duration: Motion.focus,
          curve: Motion.settle,
          child: FocusRing(
            focused: focused,
            radius: 26 * scale,
            child: AnimatedContainer(
              duration: Motion.focus,
              curve: Motion.settle,
              width: 430 * scale,
              height: 380 * scale,
              padding: EdgeInsets.all(30 * scale),
              decoration: BoxDecoration(
                color: focused ? Colors.white : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(26 * scale),
                border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.14)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 58 * scale,
                        height: 58 * scale,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: chip),
                        child: Icon(icon, size: 26 * scale, color: ink),
                      ),
                      const Spacer(),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 5 * scale),
                        decoration: BoxDecoration(color: chip, borderRadius: BorderRadius.circular(20 * scale)),
                        child: Text(
                          tag.toUpperCase(),
                          style: AppText.display(
                            11 * scale,
                            weight: FontWeight.w700,
                            color: ink,
                          ).copyWith(letterSpacing: 1.4 * scale),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 26 * scale),
                  Text(
                    title,
                    style: AppText.display(34 * scale, weight: FontWeight.w600, color: ink),
                  ),
                  SizedBox(height: 6 * scale),
                  Text(lead, style: AppText.display(16 * scale, color: ink.withValues(alpha: 0.72), height: 1.3)),
                  SizedBox(height: 24 * scale),
                  for (final fact in facts)
                    Padding(
                      padding: EdgeInsets.only(bottom: 11 * scale),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(top: 2 * scale),
                            child: Icon(Icons.check_rounded, size: 15 * scale, color: ink.withValues(alpha: 0.7)),
                          ),
                          SizedBox(width: 10 * scale),
                          Expanded(
                            child: Text(
                              fact,
                              style: AppText.display(15 * scale, weight: FontWeight.w500, color: ink, height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Add Profile: a name, then offline or online.
class AddProfileView extends StatefulWidget {
  const AddProfileView({super.key, required this.model});

  final AppModel model;

  @override
  State<AddProfileView> createState() => _AddProfileViewState();
}

class _AddProfileViewState extends State<AddProfileView> {
  late final TextEditingController _name = TextEditingController(text: widget.model.profileFlow.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final model = widget.model;
    return LayerScrim(
      opacity: 0.74,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 110 * scale, vertical: 80 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              T.text('profileAdd').toUpperCase(),
              style: AppText.display(
                13 * scale,
                weight: FontWeight.w700,
                color: model.accentChoice.color,
              ).copyWith(letterSpacing: 2.2 * scale),
            ),
            SizedBox(height: 10 * scale),
            Text(T.text('profileHowToPlay'), style: AppText.display(54 * scale, weight: FontWeight.w300)),
            SizedBox(height: 8 * scale),
            Text(
              T.text('profileHowToPlaySubtitle'),
              style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.62)),
            ),
            SizedBox(height: 34 * scale),
            AnimatedOpacity(
              opacity: model.profileFlow.modeChoice == 0 ? 1 : 0.45,
              duration: Motion.focus,
              child: SizedBox(
                width: 430 * scale,
                height: 56 * scale,
                child: Glass(
                  radius: 16 * scale,
                  padding: EdgeInsets.symmetric(horizontal: 20 * scale),
                  child: Row(
                    children: [
                      Icon(Icons.badge_outlined, size: 20 * scale, color: Colors.white.withValues(alpha: 0.6)),
                      SizedBox(width: 14 * scale),
                      Expanded(
                        child: TextField(
                          controller: _name,
                          onChanged: (text) => model.profileFlow.name = text,
                          style: AppText.display(20 * scale, weight: FontWeight.w500),
                          cursorColor: Colors.white,
                          decoration: InputDecoration.collapsed(
                            hintText: T.text('profileNameHint'),
                            hintStyle: AppText.display(20 * scale, color: Colors.white.withValues(alpha: 0.4)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: 26 * scale),
            ProfileModeCards(model: model),
            const Spacer(),
            Wrap(
              spacing: 10 * scale,
              children: [
                Hint(keys: '← →', label: T.text('hintMove')),
                Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('hintSelect'), action: HintAction.select),
                Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
