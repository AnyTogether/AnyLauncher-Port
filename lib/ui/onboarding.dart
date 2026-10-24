import 'package:flutter/material.dart';

import 'app_model.dart';
import 'background.dart';
import 'components.dart';
import 'home.dart';
import 'strings.dart';
import 'theme.dart';

/// First start: language, one of the three themes, the games folder, then the toolkit.
class OnboardingView extends StatelessWidget {
  const OnboardingView({super.key, required this.model, this.time});

  final AppModel model;

  /// A fixed moment for the theme cards' animation (previews, tests).
  final double? time;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final step = model.onboardingStep;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Colors.black.withValues(alpha: 0.55), Colors.black.withValues(alpha: 0.1)]),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 110 * scale, vertical: 80 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var index = 0; index < AppModel.onboardingSteps; index++)
                  AnimatedContainer(
                    duration: Motion.layout,
                    curve: Motion.settle,
                    margin: EdgeInsets.only(right: 10 * scale),
                    width: (index == step ? 46 : 18) * scale,
                    height: 5 * scale,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5 * scale),
                      color: Colors.white.withValues(alpha: index <= step ? 0.95 : 0.22),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 54 * scale),
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.layout,
                switchInCurve: Motion.settle,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(animation),
                    child: child,
                  ),
                ),
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                child: KeyedSubtree(
                  key: ValueKey(step),
                  child: switch (step) {
                    0 => _LanguageStep(model: model),
                    1 => _ThemeStep(model: model, time: time),
                    2 => _FolderStep(model: model),
                    _ => _ToolkitStep(model: model),
                  },
                ),
              ),
            ),
            Row(
              children: [
                if (step > 0)
                  ConsoleButton(
                    title: T.text('back'),
                    icon: Icons.chevron_left_rounded,
                    focused: false,
                    onPressed: model.onboardingBack,
                  ),
                const Spacer(),
                const HintBar(options: false),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.display(54 * scale, weight: FontWeight.w300)),
        SizedBox(height: 14 * scale),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 720 * scale),
          child: Text(
            subtitle,
            style: AppText.display(19 * scale, color: Colors.white.withValues(alpha: 0.7), height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// A card that turns white when chosen.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.focused, required this.onTap, required this.child, this.width, this.height});

  final bool focused;
  final VoidCallback onTap;
  final Widget child;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: focused ? 1.04 : 1,
        duration: Motion.focus,
        curve: Motion.settle,
        child: AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          width: width,
          height: height,
          padding: EdgeInsets.all(26 * scale),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20 * scale),
            border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withValues(alpha: focused ? 0.3 : 0),
                blurRadius: 20 * scale,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _LanguageStep extends StatelessWidget {
  const _LanguageStep({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('welcome'), subtitle: T.text('welcomeSubtitle')),
        SizedBox(height: 46 * scale),
        Text(
          T.text('chooseLanguage').toUpperCase(),
          style: AppText.display(
            14 * scale,
            weight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.55),
          ).copyWith(letterSpacing: 0.8),
        ),
        SizedBox(height: 16 * scale),
        Row(
          children: [
            for (final language in Language.values) ...[
              _ChoiceCard(
                focused: model.onboardingChoice == language.index,
                width: 280 * scale,
                height: 150 * scale,
                onTap: () {
                  model.onboardingChoice = language.index;
                  model.onboardingConfirm();
                },
                child: Builder(
                  builder: (context) {
                    final color = model.onboardingChoice == language.index ? Colors.black : Colors.white;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          language.code.toUpperCase(),
                          style: AppText.display(
                            15 * scale,
                            weight: FontWeight.w700,
                            color: color.withValues(alpha: 0.6),
                          ),
                        ),
                        SizedBox(height: 10 * scale),
                        Text(
                          language.displayName,
                          style: AppText.display(28 * scale, weight: FontWeight.w500, color: color),
                        ),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(width: 20 * scale),
            ],
          ],
        ),
      ],
    );
  }
}

class _ThemeStep extends StatelessWidget {
  const _ThemeStep({required this.model, this.time});

  final AppModel model;
  final double? time;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('chooseTheme'), subtitle: T.text('chooseThemeSubtitle')),
        SizedBox(height: 46 * scale),
        Row(
          children: [
            for (final style in LookStyle.values) ...[
              GestureDetector(
                onTap: () => model.previewTheme(style.index),
                child: AnimatedScale(
                  scale: model.onboardingChoice == style.index ? 1.04 : 0.97,
                  duration: Motion.focus,
                  curve: Motion.settle,
                  child: AnimatedOpacity(
                    opacity: model.onboardingChoice == style.index ? 1 : 0.72,
                    duration: Motion.focus,
                    child: SizedBox(
                      width: 330 * scale,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FocusRing(
                            focused: model.onboardingChoice == style.index,
                            radius: 18 * scale,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18 * scale),
                              child: SizedBox(
                                width: 330 * scale,
                                height: 186 * scale,
                                child: ThemeBackground(
                                  style: style,
                                  paused: model.onboardingChoice != style.index,
                                  time: time,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: 14 * scale),
                          Row(
                            children: [
                              Text(
                                style.title,
                                style: AppText.display(
                                  22 * scale,
                                  weight: model.onboardingChoice == style.index ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                width: 12 * scale,
                                height: 12 * scale,
                                decoration: BoxDecoration(shape: BoxShape.circle, color: style.defaultAccent.color),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 26 * scale),
            ],
          ],
        ),
      ],
    );
  }
}

class _FolderStep extends StatelessWidget {
  const _FolderStep({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final folder = model.preferences.gamesFolder;
    final accent = model.accentChoice.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('chooseFolder'), subtitle: T.text('chooseFolderSubtitle')),
        SizedBox(height: 46 * scale),
        Row(
          children: [
            ConsoleButton(
              title: T.text(folder == null ? 'pickFolder' : 'changeFolder'),
              icon: Icons.folder_rounded,
              focused: model.onboardingChoice == 0,
              minWidth: 220,
              onPressed: () {
                model.onboardingChoice = 0;
                model.onboardingConfirm();
              },
            ),
            if (folder != null) ...[
              SizedBox(width: 18 * scale),
              ConsoleButton(
                title: T.text('continueAction'),
                icon: Icons.arrow_forward_rounded,
                focused: model.onboardingChoice == 1,
                prominent: true,
                minWidth: 180,
                onPressed: () {
                  model.onboardingChoice = 1;
                  model.onboardingConfirm();
                },
              ),
            ],
          ],
        ),
        if (folder != null) ...[
          SizedBox(height: 22 * scale),
          SizedBox(
            width: 640 * scale,
            child: Glass(
              radius: 16 * scale,
              padding: EdgeInsets.all(20 * scale),
              child: Row(
                children: [
                  Icon(
                    model.games.isEmpty ? Icons.folder_off_rounded : Icons.check_circle_rounded,
                    size: 24 * scale,
                    color: model.games.isEmpty ? Colors.white.withValues(alpha: 0.7) : accent,
                  ),
                  SizedBox(width: 14 * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.games.isEmpty ? T.text('noGamesFound') : T.format('gamesFound', [model.games.length]),
                          style: AppText.display(18 * scale, weight: FontWeight.w500),
                        ),
                        SizedBox(height: 4 * scale),
                        Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.5)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (model.games.isNotEmpty) ...[
            SizedBox(height: 22 * scale),
            Row(
              children: [
                for (final game in model.games.take(8)) ...[
                  SizedBox.square(
                    dimension: 84 * scale,
                    child: GameTile(model: model, game: game, size: 84 * scale, focused: false),
                  ),
                  SizedBox(width: 12 * scale),
                ],
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _ToolkitStep extends StatelessWidget {
  const _ToolkitStep({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final toolkit = model.toolkit;
    final accent = model.accentChoice.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('chooseToolkit'), subtitle: T.text('chooseToolkitSubtitle')),
        SizedBox(height: 46 * scale),
        Row(
          children: [
            ConsoleButton(
              title: T.text('toolkitChoose'),
              icon: Icons.build_rounded,
              focused: model.onboardingChoice == 0,
              minWidth: 220,
              onPressed: () {
                model.onboardingChoice = 0;
                model.onboardingConfirm();
              },
            ),
            SizedBox(width: 18 * scale),
            ConsoleButton(
              title: T.text(toolkit == null ? 'skip' : 'start'),
              icon: Icons.arrow_forward_rounded,
              focused: model.onboardingChoice == 1,
              prominent: true,
              minWidth: 180,
              onPressed: () {
                model.onboardingChoice = 1;
                model.onboardingConfirm();
              },
            ),
          ],
        ),
        SizedBox(height: 22 * scale),
        SizedBox(
          width: 640 * scale,
          child: Glass(
            radius: 16 * scale,
            padding: EdgeInsets.all(20 * scale),
            child: Row(
              children: [
                Icon(
                  toolkit == null ? Icons.help_outline_rounded : Icons.check_circle_rounded,
                  size: 24 * scale,
                  color: toolkit == null ? Colors.white.withValues(alpha: 0.7) : accent,
                ),
                SizedBox(width: 14 * scale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        toolkit == null ? T.text('toolkitMissing') : '${T.text('toolkit')} · ${toolkit.version}',
                        style: AppText.display(18 * scale, weight: FontWeight.w500),
                      ),
                      SizedBox(height: 4 * scale),
                      Text(
                        toolkit?.root ?? T.text('toolkitDetail'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.5)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
