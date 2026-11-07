import 'dart:async';

import 'package:flutter/material.dart';

import 'app_model.dart';
import 'components.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// A friend calling, over the launcher, as on the Mac: their picture in rings going out, who, and
/// Answer or Decline.
class RingingCard extends StatefulWidget {
  const RingingCard({super.key, required this.model});

  final AppModel model;

  @override
  State<RingingCard> createState() => _RingingCardState();
}

class _RingingCardState extends State<RingingCard> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Still for those who asked for less motion (and in the goldens).
    if (MediaQuery.disableAnimationsOf(context) || Motion.reduced) {
      _pulse
        ..stop()
        ..value = 0.55;
    } else if (!_pulse.isAnimating) {
      unawaited(_pulse.repeat());
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final call = model.together.ringing;
    if (call == null) return const SizedBox.shrink();
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final name = TogetherModel.shown(call.from).name;
    final avatar = 132 * scale;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Glass(
          radius: 28 * scale,
          opacity: 0.5,
          padding: EdgeInsets.symmetric(horizontal: 64 * scale, vertical: 40 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: avatar * 2,
                height: 200 * scale,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) => Stack(
                    alignment: Alignment.center,
                    children: [
                      for (var ring = 0; ring < 2; ring++)
                        Builder(
                          builder: (context) {
                            final t = (_pulse.value - ring * 0.28) % 1;
                            return Opacity(
                              opacity: (0.8 * (1 - t)).clamp(0.0, 1.0),
                              child: Container(
                                width: avatar * (1 + t * 0.6),
                                height: avatar * (1 + t * 0.6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: accent.withValues(alpha: 0.6), width: 2 * scale),
                                ),
                              ),
                            );
                          },
                        ),
                      child!,
                    ],
                  ),
                  child: PersonAvatar(person: TogetherModel.card(call.from), size: avatar),
                ),
              ),
              SizedBox(height: 18 * scale),
              Text(name, style: AppText.display(32 * scale, weight: FontWeight.w300)),
              SizedBox(height: 8 * scale),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.phone_callback_rounded, size: 18 * scale, color: Colors.white.withValues(alpha: 0.7)),
                  SizedBox(width: 8 * scale),
                  Text(
                    T.text('callRinging'),
                    style: AppText.display(
                      16 * scale,
                      weight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 30 * scale),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConsoleButton(
                    title: T.text('callDecline'),
                    icon: Icons.call_end_rounded,
                    focused: false,
                    destructive: true,
                    minWidth: 170 * scale,
                    onPressed: () => model.together.declineRinging(),
                  ),
                  SizedBox(width: 16 * scale),
                  ConsoleButton(
                    title: T.text('callAnswer'),
                    icon: Icons.call_rounded,
                    focused: true,
                    prominent: true,
                    minWidth: 170 * scale,
                    onPressed: () => unawaited(model.together.acceptRinging()),
                  ),
                ],
              ),
              SizedBox(height: 22 * scale),
              Wrap(
                spacing: 22 * scale,
                children: [
                  Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('callAnswer'), action: HintAction.select),
                  Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('callDecline'), action: HintAction.back),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
