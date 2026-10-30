import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/controllers/pad_info.dart';
import '../core/gamepad/pad_navigation.dart';
import 'app_model.dart';
import 'components.dart';
import 'controllers_model.dart';
import 'glass.dart';
import 'strings.dart';
import 'theme.dart';

/// The controller test: Player 1's controller drawn, every button lit while it is held, the
/// sticks where they are (with the dead zone's ring), the triggers as far as they go. Any pad
/// pressed becomes the one shown; holding the east button (○, B) for a second leaves, as does Esc.
class ControllerTestView extends StatefulWidget {
  const ControllerTestView({super.key, required this.model});

  final AppModel model;

  static const holdToLeave = Duration(seconds: 1);

  /// The east face button's name: Circle, B, or A on a Switch controller.
  static String eastName(PadKind kind) => kind.isPlayStation ? T.text('padCircle') : (kind == PadKind.switchPro ? 'A' : 'B');

  @override
  State<ControllerTestView> createState() => _ControllerTestViewState();
}

class _ControllerTestViewState extends State<ControllerTestView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _now = Duration.zero;
  Duration? _eastSince;

  ControllersModel get _controllers => widget.model.controllers;

  @override
  void initState() {
    super.initState();
    // Redrawn every frame while open: the pads' states are read, not told.
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration now) {
    _now = now;
    final pad = _controllers.playerOne;
    final held = pad != null && (_controllers.stateOf(pad.id)?.pressed.contains(PadButton.east) ?? false);
    if (!held) {
      _eastSince = null;
    } else {
      _eastSince ??= now;
      if (now - _eastSince! >= ControllerTestView.holdToLeave && widget.model.overlay == Layer.controllerTest) {
        _eastSince = null;
        widget.model.closeControllerTest();
        return;
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final model = widget.model;
    final pad = _controllers.playerOne;
    final state = (pad == null ? null : _controllers.stateOf(pad.id)) ?? PadState.idle;
    final accent = model.accentChoice.color;
    final leaving = _eastSince == null
        ? 0.0
        : ((_now - _eastSince!).inMilliseconds / ControllerTestView.holdToLeave.inMilliseconds).clamp(0.0, 1.0);
    final muted = Colors.white.withValues(alpha: 0.65);
    String axis(double value) => '${value >= 0 ? '+' : '-'}${value.abs().toStringAsFixed(2)}';
    return LayerScrim(
      opacity: 0.78,
      child: Padding(
        padding: EdgeInsets.fromLTRB(90 * scale, 64 * scale, 90 * scale, 44 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(T.text('padTestTitle'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
                      SizedBox(height: 6 * scale),
                      Text(
                        pad == null ? T.text('padTestNoPad') : '${pad.name} · ${ControllersModel.summary(pad)}',
                        style: AppText.display(16 * scale, color: muted),
                      ),
                    ],
                  ),
                ),
                _Pill(label: T.text('padLeave'), selected: false, onTap: model.closeControllerTest),
              ],
            ),
            if (_controllers.pads.length > 1) ...[
              SizedBox(height: 18 * scale),
              Wrap(
                spacing: 10 * scale,
                children: [
                  for (final other in _controllers.pads)
                    _Pill(label: other.name, selected: other.id == pad?.id, onTap: () => _controllers.used(other.id)),
                ],
              ),
            ],
            SizedBox(height: 18 * scale),
            Expanded(
              child: Center(
                child: Opacity(
                  opacity: pad == null ? 0.35 : 1,
                  child: PadDiagram(
                    kind: pad?.kind ?? PadKind.dualSense,
                    state: state,
                    deadzone: model.preferences.stickDeadzone,
                    accent: accent,
                  ),
                ),
              ),
            ),
            SizedBox(height: 18 * scale),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Readout(
                  title: T.text('padSticks'),
                  value: 'L ${axis(state.leftX)} ${axis(-state.leftY)}   R ${axis(state.rightX)} ${axis(-state.rightY)}',
                ),
                SizedBox(width: 28 * scale),
                _Readout(
                  title: T.text('padTriggers'),
                  value: 'L2 ${(state.l2 * 100).round().toString().padLeft(3)}%   R2 ${(state.r2 * 100).round().toString().padLeft(3)}%',
                ),
                const Spacer(),
                SizedBox(
                  width: 20 * scale,
                  height: 20 * scale,
                  child: CircularProgressIndicator(
                    value: leaving,
                    strokeWidth: 3 * scale,
                    color: accent,
                    backgroundColor: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
                SizedBox(width: 8 * scale),
                Text(
                  '${T.format('padHoldToLeave', [ControllerTestView.eastName(pad?.kind ?? PadKind.dualSense)])} · Esc',
                  style: AppText.display(14 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.72)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 8 * scale),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(40 * scale),
          ),
          child: Text(
            label,
            style: AppText.display(14 * scale, weight: selected ? FontWeight.w600 : FontWeight.w500, color: selected ? Colors.black : Colors.white),
          ),
        ),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          T.upper(title),
          style: AppText.display(11 * scale, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.5)).copyWith(letterSpacing: 1.2),
        ),
        SizedBox(height: 4 * scale),
        Text(
          value,
          style: AppText.display(15 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.9))
              .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

/// A controller drawn flat in a 160 × 100 box, its family's glyphs on the face buttons: what is
/// held lights in the accent, the sticks sit where they are inside their dead zone's ring, the
/// triggers fill. The same drawing as the macOS launcher's.
class PadDiagram extends StatelessWidget {
  const PadDiagram({super.key, required this.kind, required this.state, required this.deadzone, required this.accent});

  final PadKind kind;
  final PadState state;
  final int deadzone;
  final Color accent;

  bool _lit(PadButton button) => state.pressed.contains(button);
  Color _fill(PadButton button) => _lit(button) ? accent : Colors.white.withValues(alpha: 0.13);

  String get _selectLabel => switch (kind) {
    PadKind.dualSense => 'Create',
    PadKind.dualShock4 => 'Share',
    PadKind.dualShock3 => 'Select',
    PadKind.xbox => 'View',
    PadKind.switchPro => '−',
    PadKind.generic => 'Back',
  };

  String get _startLabel => switch (kind) {
    PadKind.dualSense || PadKind.dualShock4 => 'Options',
    PadKind.dualShock3 || PadKind.generic => 'Start',
    PadKind.xbox => 'Menu',
    PadKind.switchPro => '+',
  };

  /// A PlayStation pad's face buttons are drawn (the interface font has no ✕ ○ □ △).
  static const _playStationFaces = {
    PadButton.south: PadGlyph.cross,
    PadButton.east: PadGlyph.circle,
    PadButton.west: PadGlyph.square,
    PadButton.north: PadGlyph.triangle,
  };

  /// The face buttons by place: Nintendo's B is south and A east.
  Map<PadButton, String> get _faces => switch (kind) {
    PadKind.dualSense || PadKind.dualShock4 || PadKind.dualShock3 => const {
      PadButton.south: '',
      PadButton.east: '',
      PadButton.west: '',
      PadButton.north: '',
    },
    PadKind.switchPro => const {PadButton.south: 'B', PadButton.east: 'A', PadButton.west: 'Y', PadButton.north: 'X'},
    PadKind.xbox || PadKind.generic => const {PadButton.south: 'A', PadButton.east: 'B', PadButton.west: 'X', PadButton.north: 'Y'},
  };

  String _shoulder(String playStation, String xbox, String nintendo) =>
      kind == PadKind.xbox ? xbox : (kind == PadKind.switchPro ? nintendo : playStation);

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.6,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final u = constraints.maxWidth / 160;
          Widget at(double x, double y, double width, double height, Widget child) =>
              Positioned(left: (x - width / 2) * u, top: (y - height / 2) * u, width: width * u, height: height * u, child: child);
          Widget label(String text, bool lit, double size) => Center(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: AppText.family,
                fontSize: size * u,
                fontWeight: FontWeight.w700,
                color: lit ? Colors.black : Colors.white.withValues(alpha: 0.85),
              ),
            ),
          );
          Widget capsule(PadButton button, String text, double width, double height) => DecoratedBox(
            decoration: BoxDecoration(color: _fill(button), borderRadius: BorderRadius.circular(height * u)),
            child: label(text, _lit(button), 3.2),
          );
          Widget trigger(PadButton button, double value, String text) => ClipRRect(
            borderRadius: BorderRadius.circular(6 * u),
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: Colors.white.withValues(alpha: 0.13))),
                Positioned(left: 0, top: 0, bottom: 0, width: 22 * u * value, child: ColoredBox(color: accent)),
                Positioned.fill(child: label(text, _lit(button) || value > 0.5, 3.4)),
              ],
            ),
          );
          return Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _SilhouettePainter())),
              at(36, 3.5, 22, 6, trigger(PadButton.l2, state.l2, _shoulder('L2', 'LT', 'ZL'))),
              at(124, 3.5, 22, 6, trigger(PadButton.r2, state.r2, _shoulder('R2', 'RT', 'ZR'))),
              at(36, 10.5, 22, 5, capsule(PadButton.l1, _shoulder('L1', 'LB', 'L'), 22, 5)),
              at(124, 10.5, 22, 5, capsule(PadButton.r1, _shoulder('R1', 'RB', 'R'), 22, 5)),
              for (final (button, dx, dy) in const [
                (PadButton.dpadUp, 0.0, -1.0),
                (PadButton.dpadDown, 0.0, 1.0),
                (PadButton.dpadLeft, -1.0, 0.0),
                (PadButton.dpadRight, 1.0, 0.0),
              ])
                at(
                  36 + dx * 7.5,
                  38 + dy * 7.5,
                  7,
                  7,
                  DecoratedBox(decoration: BoxDecoration(color: _fill(button), borderRadius: BorderRadius.circular(1.4 * u))),
                ),
              for (final (button, dx, dy) in const [
                (PadButton.south, 0.0, 1.0),
                (PadButton.east, 1.0, 0.0),
                (PadButton.west, -1.0, 0.0),
                (PadButton.north, 0.0, -1.0),
              ])
                at(
                  124 + dx * 9,
                  38 + dy * 9,
                  9,
                  9,
                  DecoratedBox(
                    decoration: BoxDecoration(color: _fill(button), shape: BoxShape.circle),
                    child: kind.isPlayStation
                        ? Center(
                            child: PadGlyphIcon(
                              _playStationFaces[button]!,
                              size: 4.4 * u,
                              color: _lit(button) ? Colors.black : Colors.white.withValues(alpha: 0.85),
                            ),
                          )
                        : label(_faces[button]!, _lit(button), 5.2),
                  ),
                ),
              if (kind == PadKind.dualSense || kind == PadKind.dualShock4)
                at(
                  80,
                  30,
                  40,
                  20,
                  DecoratedBox(decoration: BoxDecoration(color: _fill(PadButton.touchpad), borderRadius: BorderRadius.circular(3 * u))),
                ),
              at(56, 24, 15, 4.4, capsule(PadButton.select, _selectLabel, 15, 4.4)),
              at(104, 24, 15, 4.4, capsule(PadButton.start, _startLabel, 15, 4.4)),
              at(
                80,
                50,
                8,
                8,
                DecoratedBox(
                  decoration: BoxDecoration(color: _fill(PadButton.guide), shape: BoxShape.circle),
                  child: label(kind.isPlayStation ? 'PS' : (kind == PadKind.xbox ? 'X' : '⌂'), _lit(PadButton.guide), 3.6),
                ),
              ),
              if (kind == PadKind.xbox || kind == PadKind.dualSense)
                at(
                  80,
                  57,
                  5,
                  2.4,
                  DecoratedBox(decoration: BoxDecoration(color: _fill(PadButton.misc), borderRadius: BorderRadius.circular(2 * u))),
                ),
              at(58, 60, 18, 18, _Stick(x: state.leftX, y: state.leftY, pressed: _lit(PadButton.l3), label: 'L', deadzone: deadzone, accent: accent, unit: u)),
              at(102, 60, 18, 18, _Stick(x: state.rightX, y: state.rightY, pressed: _lit(PadButton.r3), label: 'R', deadzone: deadzone, accent: accent, unit: u)),
            ],
          );
        },
      ),
    );
  }
}

class _Stick extends StatelessWidget {
  const _Stick({
    required this.x,
    required this.y,
    required this.pressed,
    required this.label,
    required this.deadzone,
    required this.accent,
    required this.unit,
  });

  final double x;
  final double y;
  final bool pressed;
  final String label;
  final int deadzone;
  final Color accent;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final radius = 9 * unit;
    final knob = 7 * unit;
    return CustomPaint(
      painter: _StickPainter(deadzone: deadzone, accent: accent, unit: unit),
      child: Stack(
        children: [
          Positioned(
            left: radius - knob / 2 + x * radius,
            top: radius - knob / 2 + y * radius,
            width: knob,
            height: knob,
            child: DecoratedBox(
              decoration: BoxDecoration(color: pressed ? accent : Colors.white.withValues(alpha: 0.85), shape: BoxShape.circle),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(fontFamily: AppText.family, fontSize: 3 * unit, fontWeight: FontWeight.w700, color: Colors.black.withValues(alpha: 0.7)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StickPainter extends CustomPainter {
  _StickPainter({required this.deadzone, required this.accent, required this.unit});

  final int deadzone;
  final Color accent;
  final double unit;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2;
    canvas.drawCircle(centre, radius, Paint()..color = Colors.white.withValues(alpha: 0.06));
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5 * unit
        ..color = Colors.white.withValues(alpha: 0.2),
    );
    if (deadzone > 0) {
      canvas.drawCircle(
        centre,
        math.max(1, radius * deadzone / 100),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.4 * unit
          ..color = accent.withValues(alpha: 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(_StickPainter old) => old.deadzone != deadzone || old.accent != accent || old.unit != unit;
}

/// A controller's outline in a 160 × 100 box: a wide body and two grips.
class _SilhouettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 160;
    final path = Path()
      ..moveTo(30 * u, 14 * u)
      ..lineTo(130 * u, 14 * u)
      ..cubicTo(144 * u, 14 * u, 150 * u, 26 * u, 152 * u, 40 * u)
      ..cubicTo(156 * u, 62 * u, 158 * u, 88 * u, 146 * u, 92 * u)
      ..cubicTo(134 * u, 96 * u, 126 * u, 80 * u, 118 * u, 74 * u)
      ..lineTo(42 * u, 74 * u)
      ..cubicTo(34 * u, 80 * u, 26 * u, 96 * u, 14 * u, 92 * u)
      ..cubicTo(2 * u, 88 * u, 4 * u, 62 * u, 8 * u, 40 * u)
      ..cubicTo(10 * u, 26 * u, 16 * u, 14 * u, 30 * u, 14 * u)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.07));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6 * u
        ..color = Colors.white.withValues(alpha: 0.22),
    );
  }

  @override
  bool shouldRepaint(_SilhouettePainter old) => false;
}

/// The top bar's controller line, shown only when there is something to say (a controller's
/// battery nearly empty): its name and what is left.
class PadStatusPill extends StatelessWidget {
  const PadStatusPill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      height: 36 * scale,
      padding: EdgeInsets.symmetric(horizontal: 14 * scale),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(18 * scale)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.battery_alert_rounded, size: 16 * scale, color: const Color.fromRGBO(255, 158, 51, 1)),
          SizedBox(width: 8 * scale),
          Text(text, style: AppText.display(14 * scale, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.9))),
        ],
      ),
    );
  }
}
