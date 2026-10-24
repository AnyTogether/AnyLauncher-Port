import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_model.dart';
import 'components.dart';
import 'home.dart';
import 'onboarding.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';

/// The launcher's whole screen: the backdrop, the home screen or the first-start steps, and the
/// layers over them. Keys move through it as a pad would.
class LauncherShell extends StatefulWidget {
  const LauncherShell({super.key, required this.model, this.time, this.now});

  final AppModel model;

  /// A fixed moment of the background animation and clock, for previews and golden tests.
  final double? time;
  final DateTime? now;

  @override
  State<LauncherShell> createState() => _LauncherShellState();
}

class _LauncherShellState extends State<LauncherShell> {
  final FocusNode _focus = FocusNode(debugLabel: 'launcher');

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_modelChanged);
  }

  @override
  void didUpdateWidget(LauncherShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_modelChanged);
      widget.model.addListener(_modelChanged);
    }
  }

  /// Out of a text field: the keys come back to the launcher.
  void _modelChanged() {
    if (widget.model.editingRow == null && !_focus.hasPrimaryFocus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.model.editingRow == null && !_focus.hasPrimaryFocus) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_modelChanged);
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final model = widget.model;
    // Typing in a field: the keys are the field's, Esc gives them back.
    if (model.editingRow != null) {
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
        model.stopEditing();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (model.capturing != null && event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        model.handle(Command.back);
        return KeyEventResult.handled;
      }
      return model.captureKey(event.physicalKey.usbHidUsage) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    Command? command;
    if (key == LogicalKeyboardKey.arrowLeft) command = Command.left;
    if (key == LogicalKeyboardKey.arrowRight) command = Command.right;
    if (key == LogicalKeyboardKey.arrowUp) command = Command.up;
    if (key == LogicalKeyboardKey.arrowDown) command = Command.down;
    if (!repeat) {
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space) {
        command = Command.select;
      }
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) command = Command.back;
      if (key == LogicalKeyboardKey.keyO) command = Command.options;
      if (key == LogicalKeyboardKey.keyQ || key == LogicalKeyboardKey.keyE) {
        final delta = key == LogicalKeyboardKey.keyE ? 1 : -1;
        if (model.overlay == Layer.settings) {
          model.moveCategory(delta);
          return KeyEventResult.handled;
        }
        command = delta > 0 ? Command.nextGame : Command.previousGame;
      }
    }
    if (command == null) return KeyEventResult.ignored;
    model.handle(command);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = math.min(constraints.maxWidth / 1600, constraints.maxHeight / 900);
          return LayoutScale(
            scale: scale,
            child: ListenableBuilder(
              listenable: model,
              builder: (context, _) => ColoredBox(
                color: model.look.deep,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Backdrop(model: model, time: widget.time),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 700),
                      switchInCurve: Motion.inOut,
                      child: model.preferences.onboarded
                          ? HomeView(key: const ValueKey('home'), model: model, now: widget.now)
                          : OnboardingView(key: const ValueKey('onboarding'), model: model, time: widget.time),
                    ),
                    AnimatedSwitcher(
                      duration: Motion.overlay,
                      switchInCurve: Motion.settle,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(animation), child: child),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(model.overlay),
                        child: switch (model.overlay) {
                          Layer.library => LibraryGrid(model: model),
                          Layer.log => LogView(model: model),
                          Layer.trophies => TrophyView(model: model),
                          null => const SizedBox.shrink(),
                          _ => PanelView(model: model),
                        },
                      ),
                    ),
                    if (model.starting != null) _StartingCard(model: model),
                    if (model.pairing != null) PairingCard(model: model),
                    _Toast(message: model.toast),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StartingCard extends StatelessWidget {
  const _StartingCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.starting!;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (game.icon != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(24 * scale),
                child: SizedBox.square(
                  dimension: 160 * scale,
                  child: ArtworkImage(path: game.icon!, cacheWidth: 400),
                ),
              ),
            SizedBox(height: 28 * scale),
            Text(game.name, style: AppText.display(36 * scale, weight: FontWeight.w300)),
            SizedBox(height: 12 * scale),
            SizedBox(
              width: 520 * scale,
              child: Text(
                T.text('startingText'),
                textAlign: TextAlign.center,
                style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.65), height: 1.4),
              ),
            ),
            SizedBox(height: 24 * scale),
            SizedBox(
              width: 260 * scale,
              child: IndeterminateLine(color: model.accentChoice.color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 92 * scale,
      child: IgnorePointer(
        child: Center(
          child: AnimatedSwitcher(
            duration: Motion.overlay,
            switchInCurve: Motion.settle,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(animation),
                child: child,
              ),
            ),
            child: message == null
                ? const SizedBox.shrink()
                : Glass(
                    key: ValueKey(message),
                    radius: 30 * scale,
                    opacity: 0.6,
                    padding: EdgeInsets.symmetric(horizontal: 26 * scale, vertical: 14 * scale),
                    child: Text(message!, style: AppText.display(16 * scale, weight: FontWeight.w500)),
                  ),
          ),
        ),
      ),
    );
  }
}
