import 'dart:async';

import 'package:flutter/material.dart';

import 'app_model.dart';
import 'components.dart';
import 'profile_picture.dart';
import 'strings.dart';
import 'theme.dart';

/// The sheet that cuts a profile picture square, as on the Mac: the picture dimmed around the
/// circle the avatar will be and lit inside it, dragged to place it, zoomed with the slider or
/// ← →, then Save.
class PictureCropView extends StatelessWidget {
  const PictureCropView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final crop = model.pictureCrop;
    final scale = LayoutScale.of(context);
    if (crop == null) return const SizedBox.shrink();
    final side = 360 * scale;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Glass(
          radius: 30 * scale,
          opacity: 0.62,
          padding: EdgeInsets.symmetric(horizontal: 44 * scale, vertical: 36 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(T.text('cropTitle'), style: AppText.display(26 * scale, weight: FontWeight.w600)),
              SizedBox(height: 22 * scale),
              _CropArea(model: model, crop: crop, side: side),
              SizedBox(height: 22 * scale),
              SizedBox(
                width: side,
                child: Row(
                  children: [
                    Icon(Icons.zoom_out_rounded, size: 18 * scale, color: Colors.white.withValues(alpha: 0.75)),
                    SizedBox(width: 12 * scale),
                    Expanded(
                      child: Semantics(
                        slider: true,
                        label: T.text('cropZoom'),
                        value: '${(crop.zoom * 100).round()}%',
                        child: _ZoomSlider(
                          value: crop.zoom,
                          accent: model.accentChoice.color,
                          onChanged: (zoom) {
                            crop.zoomTo(zoom);
                            model.refresh();
                          },
                        ),
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Icon(Icons.zoom_in_rounded, size: 18 * scale, color: Colors.white.withValues(alpha: 0.75)),
                  ],
                ),
              ),
              SizedBox(height: 24 * scale),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConsoleButton(
                    title: T.text('cancel'),
                    focused: false,
                    minWidth: 150 * scale,
                    onPressed: () => model.endCrop(saved: false),
                  ),
                  SizedBox(width: 14 * scale),
                  ConsoleButton(
                    title: T.text('cropSave'),
                    focused: true,
                    minWidth: 150 * scale,
                    onPressed: () => unawaited(model.saveCrop()),
                  ),
                ],
              ),
              SizedBox(height: 20 * scale),
              Wrap(
                spacing: 22 * scale,
                children: [
                  Hint(keys: '← →', label: T.text('cropZoom')),
                  Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('cropSave'), action: HintAction.select),
                  Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('cancel'), action: HintAction.back),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The picture in a square: dimmed outside the circle, lit inside it, dragged to place it.
class _CropArea extends StatelessWidget {
  const _CropArea({required this.model, required this.crop, required this.side});

  final AppModel model;
  final PictureCrop crop;
  final double side;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final rect = crop.rect;
    final margin = side * 0.11;
    final circle = side - 2 * margin;
    final factor = circle / rect.width;
    Widget placed() => Positioned(
      left: margin - rect.left * factor,
      top: margin - rect.top * factor,
      width: crop.image.width * factor,
      height: crop.image.height * factor,
      child: RawImage(image: crop.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        onPanUpdate: (details) {
          crop.drag(details.delta / factor);
          model.refresh();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22 * scale),
          child: SizedBox(
            width: side,
            height: side,
            child: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Color(0x59000000))),
                // The whole picture faint, the circle's part bright.
                Opacity(opacity: 0.3, child: Stack(children: [placed()])),
                ClipOval(
                  clipper: _Circle(margin, circle),
                  child: Stack(children: [placed()]),
                ),
                Positioned(
                  left: margin,
                  top: margin,
                  width: circle,
                  height: circle,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2 * scale),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22 * scale),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10 * scale,
                  child: Center(
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 5 * scale),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(20 * scale),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.pan_tool_alt_rounded,
                            size: 13 * scale,
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                          SizedBox(width: 6 * scale),
                          Text(
                            T.text('cropHint'),
                            style: AppText.display(
                              12 * scale,
                              weight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _Circle extends CustomClipper<Rect> {
  const _Circle(this.margin, this.side);

  final double margin;
  final double side;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(margin, margin, side, side);

  @override
  bool shouldReclip(_Circle oldClipper) => oldClipper.margin != margin || oldClipper.side != side;
}

/// The crop's zoom: a thin track in the accent and a white knob, dragged or clicked.
class _ZoomSlider extends StatelessWidget {
  const _ZoomSlider({required this.value, required this.accent, required this.onChanged});

  final double value;
  final Color accent;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final knob = 18 * scale;
    const span = ProfilePicture.zoomMax - ProfilePicture.zoomMin;
    final fraction = ((value - ProfilePicture.zoomMin) / span).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void at(double x) => onChanged(
          ProfilePicture.zoomMin + ((x - knob / 2) / (width - knob).clamp(1, double.infinity)).clamp(0.0, 1.0) * span,
        );
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => at(details.localPosition.dx),
            onHorizontalDragUpdate: (details) => at(details.localPosition.dx),
            child: SizedBox(
              height: 24 * scale,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 4 * scale,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(2 * scale),
                    ),
                  ),
                  Container(
                    width: (knob / 2 + (width - knob) * fraction).clamp(4 * scale, width),
                    height: 4 * scale,
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2 * scale)),
                  ),
                  Positioned(
                    left: (width - knob) * fraction,
                    child: Container(
                      width: knob,
                      height: knob,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 4 * scale,
                            offset: Offset(0, 1 * scale),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
