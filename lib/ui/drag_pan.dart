import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Click-and-drag with the mouse, as a finger drags on a phone (and as Android emulators let the
/// mouse do): the left button held down and moved pans a list, which glides on when let go
/// fast. A drag starts only once the pointer has moved [DragPan.slop] pixels, so a click that
/// wobbles a little still clicks; a drag never clicks what it started on. The cursor is an open
/// hand where a list can be dragged and a closed one while it is.
abstract final class DragPan {
  /// How far the pointer moves, held down, before a click becomes a drag.
  static const slop = 6.0;
}

/// Tells the launcher when a drag (and the glide after it) starts and ends: the hover tick is
/// quiet meanwhile.
class PanScope extends InheritedWidget {
  const PanScope({super.key, required this.onPanning, required super.child});

  final void Function(bool panning) onPanning;

  static void Function(bool panning)? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PanScope>()?.onPanning;

  @override
  bool updateShouldNotify(PanScope oldWidget) => false;
}

/// The mouse's left button, dragged up or down past [DragPan.slop] (Flutter's own slop for a
/// mouse is a single pixel, which would turn every click into a drag).
class MouseVerticalDrag extends VerticalDragGestureRecognizer {
  MouseVerticalDrag({required this.canPan, super.debugOwner})
    : super(supportedDevices: const {PointerDeviceKind.mouse});

  /// Whether there is anywhere to pan to; a drag where there is not stays a click.
  final bool Function() canPan;

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      globalDistanceMoved.abs() > DragPan.slop && canPan();
}

/// The same, left or right.
class MouseHorizontalDrag extends HorizontalDragGestureRecognizer {
  MouseHorizontalDrag({required this.canPan, super.debugOwner})
    : super(supportedDevices: const {PointerDeviceKind.mouse});

  final bool Function() canPan;

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      globalDistanceMoved.abs() > DragPan.slop && canPan();
}

/// The drag itself, around what it pans: the recognizer, the cursors, and [PanScope]'s reports.
/// [glide], when given, says whether the panned thing is still moving after the drag (a list's
/// glide): the drag is over for the hover tick only once it stops.
class DragPanRegion extends StatefulWidget {
  const DragPanRegion({
    super.key,
    required this.axis,
    required this.canPan,
    required this.child,
    this.onDown,
    this.onStart,
    this.onUpdate,
    this.onEnd,
    this.onCancel,
    this.glide,
  });

  final Axis axis;
  final bool Function() canPan;
  final Widget child;
  final GestureDragDownCallback? onDown;
  final GestureDragStartCallback? onStart;
  final GestureDragUpdateCallback? onUpdate;
  final GestureDragEndCallback? onEnd;
  final GestureDragCancelCallback? onCancel;
  final ValueListenable<bool>? glide;

  @override
  State<DragPanRegion> createState() => DragPanRegionState();
}

class DragPanRegionState extends State<DragPanRegion> {
  bool _dragging = false;
  bool _reported = false;
  bool _canPan = false;
  ValueListenable<bool>? _gliding;

  /// Whether a drag is going on now.
  bool get dragging => _dragging;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCanPan());
  }

  void _checkCanPan() {
    if (!mounted) return;
    final can = widget.canPan();
    if (can != _canPan) setState(() => _canPan = can);
  }

  /// Where the reports go, kept from the drag's start (a region going away mid-glide still
  /// says the drag is over).
  void Function(bool panning)? _scope;

  void _report(bool panning) {
    if (_reported == panning) return;
    _reported = panning;
    if (panning) _scope = PanScope.of(context);
    _scope?.call(panning);
  }

  void _start(DragStartDetails details) {
    _stopWatchingGlide();
    setState(() => _dragging = true);
    _report(true);
    widget.onStart?.call(details);
  }

  void _end(DragEndDetails details) {
    widget.onEnd?.call(details);
    _finish();
  }

  void _cancel() {
    widget.onCancel?.call();
    if (_dragging) _finish();
  }

  void _finish() {
    if (mounted) setState(() => _dragging = false);
    final glide = widget.glide;
    if (glide != null && glide.value) {
      _gliding = glide..addListener(_glideChanged);
    } else {
      _report(false);
    }
  }

  void _glideChanged() {
    if (_gliding?.value ?? false) return;
    _stopWatchingGlide();
    _report(false);
  }

  void _stopWatchingGlide() {
    _gliding?.removeListener(_glideChanged);
    _gliding = null;
  }

  @override
  void dispose() {
    _stopWatchingGlide();
    if (_reported) _scope?.call(false);
    super.dispose();
  }

  void _configure(DragGestureRecognizer recognizer) => recognizer
    ..onDown = widget.onDown
    ..onStart = _start
    ..onUpdate = widget.onUpdate
    ..onEnd = _end
    ..onCancel = _cancel;

  @override
  Widget build(BuildContext context) {
    final cursor = _canPan ? SystemMouseCursors.grab : MouseCursor.defer;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) WidgetsBinding.instance.addPostFrameCallback((_) => _checkCanPan());
        return false;
      },
      child: RawGestureDetector(
        gestures: {
          if (widget.axis == Axis.vertical)
            MouseVerticalDrag: GestureRecognizerFactoryWithHandlers<MouseVerticalDrag>(
              () => MouseVerticalDrag(canPan: () => widget.canPan(), debugOwner: this),
              _configure,
            )
          else
            MouseHorizontalDrag: GestureRecognizerFactoryWithHandlers<MouseHorizontalDrag>(
              () => MouseHorizontalDrag(canPan: () => widget.canPan(), debugOwner: this),
              _configure,
            ),
        },
        child: MouseRegion(
          cursor: cursor,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.child,
              // While dragging, a closed hand over everything, and nothing under it is hovered.
              if (_dragging)
                const Positioned.fill(child: MouseRegion(opaque: true, cursor: SystemMouseCursors.grabbing)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every list in the launcher pans with a mouse drag, and glides on when let go fast. Text
/// fields keep their own drag (they turn the overscroll part of the behaviour off, and with it
/// this).
class LauncherScrollBehavior extends MaterialScrollBehavior {
  const LauncherScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    final inner = super.buildOverscrollIndicator(context, child, details);
    final controller = details.controller;
    if (controller == null) return inner;
    return _ScrollDragPan(controller: controller, axis: axisDirectionToAxis(details.direction), child: inner);
  }
}

/// A Scrollable dragged with the mouse, the way Scrollable itself takes a finger: a press stops
/// a glide, the drag moves the list, the release lets it glide (its physics' fling).
class _ScrollDragPan extends StatefulWidget {
  const _ScrollDragPan({required this.controller, required this.axis, required this.child});

  final ScrollController controller;
  final Axis axis;
  final Widget child;

  @override
  State<_ScrollDragPan> createState() => _ScrollDragPanState();
}

class _ScrollDragPanState extends State<_ScrollDragPan> {
  Drag? _drag;
  ScrollHoldController? _hold;

  ScrollPosition? get _position {
    final positions = widget.controller.positions;
    return positions.length == 1 ? positions.first : null;
  }

  bool _canPan() {
    final position = _position;
    return position != null &&
        position.hasContentDimensions &&
        position.maxScrollExtent > position.minScrollExtent &&
        position.physics.shouldAcceptUserOffset(position);
  }

  void _down(DragDownDetails details) {
    _hold = _position?.hold(() => _hold = null);
  }

  void _start(DragStartDetails details) {
    _drag = _position?.drag(details, () => _drag = null);
  }

  void _update(DragUpdateDetails details) => _drag?.update(details);

  void _end(DragEndDetails details) => _drag?.end(details);

  void _cancel() {
    _hold?.cancel();
    _drag?.cancel();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragPanRegion(
      axis: widget.axis,
      canPan: _canPan,
      onDown: _down,
      onStart: _start,
      onUpdate: _update,
      onEnd: _end,
      onCancel: _cancel,
      glide: _position?.isScrollingNotifier,
      child: widget.child,
    );
  }
}
