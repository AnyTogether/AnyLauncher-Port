import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'components.dart';
import 'strings.dart';
import 'theme.dart';

/// Full screen, the window has no title bar of the system's: the pointer at the top edge brings
/// down the launcher's own Minimize, Leave Full Screen and Quit, a tab hanging from the edge it
/// went to, and they go up again a moment after the pointer leaves them (Settings › Appearance ›
/// Window Buttons at the Top Edge). Hidden, they take no clicks.
class WindowButtons extends StatefulWidget {
  const WindowButtons({
    super.key,
    required this.accent,
    required this.onMinimize,
    required this.onWindowed,
    required this.onQuit,
  });

  /// The look's accent: the edge the tab hangs from.
  final Color accent;
  final VoidCallback onMinimize;
  final VoidCallback onWindowed;
  final VoidCallback onQuit;

  /// The band at the top of the screen that brings them down, in logical pixels: a pointer
  /// thrown up stops in it.
  static const edge = 4.0;

  /// How long they stay after the pointer left them.
  static const linger = Duration(milliseconds: 900);

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> {
  bool _shown = false;

  /// The pointer is over the edge or the tab.
  bool _inside = false;
  Timer? _hide;

  /// The button under the pointer, said beside them.
  String? _label;

  void _enter() {
    _hide?.cancel();
    _inside = true;
    if (!_shown) setState(() => _shown = true);
  }

  void _leave() {
    _inside = false;
    _hide?.cancel();
    _hide = Timer(WindowButtons.linger, () {
      if (!mounted || _inside) return;
      setState(() {
        _shown = false;
        _label = null;
      });
    });
  }

  void _hovered(String? label) {
    if (label != _label) setState(() => _label = label);
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final duration = Duration(milliseconds: Motion.reduced ? 120 : 260);
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: WindowButtons.edge,
          // Clicks go through to what is under the edge.
          child: MouseRegion(
            hitTestBehavior: HitTestBehavior.translucent,
            onEnter: (_) => _enter(),
            onExit: (_) => _leave(),
          ),
        ),
        Positioned(
          top: 0,
          right: 28 * scale,
          child: IgnorePointer(
            key: const ValueKey('window-buttons'),
            ignoring: !_shown,
            child: AnimatedSlide(
              // With reduced motion they only fade.
              offset: _shown || Motion.reduced ? Offset.zero : const Offset(0, -1.1),
              duration: duration,
              curve: _shown ? Motion.settle : Curves.easeIn,
              child: AnimatedOpacity(
                opacity: _shown ? 1 : 0,
                duration: duration,
                curve: Motion.settle,
                child: MouseRegion(onEnter: (_) => _enter(), onExit: (_) => _leave(), child: _tab(scale)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tab(double scale) {
    final radius = BorderRadius.vertical(bottom: Radius.circular(18 * scale));
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0B0D14).withValues(alpha: 0.72),
            borderRadius: radius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          // Hung from the screen's edge: the accent along it.
          foregroundDecoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: widget.accent, width: 2 * scale),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(18 * scale, 6 * scale, 6 * scale, 6 * scale),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // What the button under the pointer does; AnyPS5 otherwise.
                SizedBox(
                  width: 150 * scale,
                  child: AnimatedSwitcher(
                    duration: Motion.focus,
                    switchInCurve: Motion.settle,
                    layoutBuilder: (current, previous) =>
                        Stack(alignment: Alignment.centerRight, children: [...previous, ?current]),
                    child: Text(
                      _label ?? 'AnyPS5',
                      key: ValueKey(_label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: AppText.display(
                        13 * scale,
                        weight: _label == null ? FontWeight.w700 : FontWeight.w500,
                        color: Colors.white.withValues(alpha: _label == null ? 0.45 : 0.85),
                      ).copyWith(letterSpacing: _label == null ? 1.2 * scale : 0.1),
                    ),
                  ),
                ),
                SizedBox(width: 12 * scale),
                _button('minimize', Icons.remove_rounded, T.text('windowMinimize'), widget.onMinimize, scale),
                _button(
                  'windowed',
                  Icons.close_fullscreen_rounded,
                  T.text('windowLeaveFullscreen'),
                  widget.onWindowed,
                  scale,
                ),
                _button('quit', Icons.close_rounded, T.text('quitLauncher'), widget.onQuit, scale, danger: true),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _button(String id, IconData icon, String label, VoidCallback onTap, double scale, {bool danger = false}) {
    return Semantics(
      button: true,
      label: label,
      child: MouseRegion(
        onEnter: (_) => _hovered(label),
        onExit: (_) => _hovered(null),
        child: Pressable(
          key: ValueKey('window-$id'),
          pressScale: 0.92,
          onTap: onTap,
          builder: (context, hovering) => AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            width: 46 * scale,
            height: 34 * scale,
            margin: EdgeInsets.only(left: 2 * scale),
            decoration: BoxDecoration(
              // Quit turns red under the pointer, as a title bar's close does.
              color: hovering
                  ? (danger ? const Color(0xFFE5484D) : Colors.white.withValues(alpha: 0.14))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12 * scale),
            ),
            child: Icon(
              icon,
              size: 18 * scale,
              color: Colors.white.withValues(alpha: hovering ? 1 : 0.78),
            ),
          ),
        ),
      ),
    );
  }
}
