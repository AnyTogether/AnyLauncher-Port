import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// A profile's picture as the launcher keeps it: a square of the one chosen (its middle, or the
/// one placed and zoomed in the crop), at most [ProfilePicture.size] pixels a side, as a PNG.
/// Read with the engine's own decoders, so PNG, JPEG and WebP all work without a package of
/// their own. The crop's sums are the Mac launcher's ProfilePicture.crop and offset.
abstract final class ProfilePicture {
  /// The side of a kept picture: sharp on the picker's 168-point tile at 1.5×.
  static const size = 256;

  /// The files the picker offers.
  static const extensions = ['png', 'jpg', 'jpeg', 'webp'];

  /// Larger files are not read: no picture needs them.
  static const maxBytes = 20 * 1024 * 1024;

  /// Pictures larger than this on a side are read smaller: a crop needs no more.
  static const readMaxSide = 4096;

  /// AnyTogether's limits for PUT /me/avatar: at most 5 MB, at least 32 pixels a side.
  static const uploadMaxBytes = 5 * 1024 * 1024;
  static const uploadMinSide = 32;

  /// How far the crop zooms in.
  static const zoomMin = 1.0;
  static const zoomMax = 4.0;

  /// [bytes] read, at most [maxSide] pixels on its longer side; throws on bytes that are not a
  /// picture.
  static Future<ui.Image> read(Uint8List bytes, {int maxSide = readMaxSide}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0) throw const FormatException('an empty picture');
      final long = math.max(width, height);
      final scale = long > maxSide ? maxSide / long : 1.0;
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).round()),
        targetHeight: math.max(1, (height * scale).round()),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  /// The square of a [width] × [height] picture the crop keeps, in its pixels from the top left.
  /// Zoom 1 is the largest square in the middle, more zoom a smaller one. [offset] (-1 to 1 on
  /// each axis) moves the square within the room around it, 0 being the middle.
  static ui.Rect crop({required int width, required int height, double zoom = 1, ui.Offset offset = ui.Offset.zero}) {
    final side = math.min(width, height) / zoom.clamp(1.0, 8.0);
    final roomX = (width - side) / 2;
    final roomY = (height - side) / 2;
    return ui.Rect.fromLTWH(
      roomX + offset.dx.clamp(-1.0, 1.0) * roomX,
      roomY + offset.dy.clamp(-1.0, 1.0) * roomY,
      side,
      side,
    );
  }

  /// The offset that moves the crop by [pixels] of the picture: dragging the picture right by d
  /// moves the square left by d.
  static ui.Offset moved(
    ui.Offset offset,
    ui.Offset pixels, {
    required int width,
    required int height,
    required double zoom,
  }) {
    final side = math.min(width, height) / zoom.clamp(1.0, 8.0);
    final roomX = (width - side) / 2;
    final roomY = (height - side) / 2;
    double along(double value, double by, double room) => room < 0.5 ? 0 : (value - by / room).clamp(-1.0, 1.0);
    return ui.Offset(along(offset.dx, pixels.dx, roomX), along(offset.dy, pixels.dy, roomY));
  }

  /// The [square] of [image] drawn at most [side] pixels a side (never larger than the square
  /// was), as a PNG.
  static Future<Uint8List> cut(ui.Image image, ui.Rect square, {int side = size}) async {
    final out = math.max(1, math.min(side, square.width.round()));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      square,
      ui.Rect.fromLTWH(0, 0, out.toDouble(), out.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final squared = await picture.toImage(out, out);
    final png = await squared.toByteData(format: ui.ImageByteFormat.png);
    squared.dispose();
    picture.dispose();
    if (png == null) throw const FormatException('the picture could not be written');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  }

  /// [bytes] cut to their middle square and made at most [side] pixels a side (never larger
  /// than the picture was); throws on bytes that are not a picture.
  static Future<Uint8List> square(Uint8List bytes, {int side = size}) async {
    // Read at about twice the size kept, so a 6000-pixel photo is not held whole.
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final short = math.min(descriptor.width, descriptor.height);
    final long = math.max(descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    if (short <= 0) throw const FormatException('an empty picture');
    final scale = short > side * 2 ? side * 2 / short : 1.0;
    final image = await read(bytes, maxSide: (long * scale).round());
    try {
      return await cut(
        image,
        crop(width: image.width, height: image.height),
        side: side,
      );
    } finally {
      image.dispose();
    }
  }
}

/// A picture being cut square for a profile: the picture read, its zoom and where the square
/// is, the profile it is for and the settings row to go back to.
class PictureCrop {
  PictureCrop(this.image, {required this.profileId, this.returnCategory = 0, this.returnRow = 0});

  final ui.Image image;
  final String profileId;
  final int returnCategory;
  final int returnRow;
  double zoom = 1;
  ui.Offset offset = ui.Offset.zero;

  /// The square kept, in the picture's pixels.
  ui.Rect get rect => ProfilePicture.crop(width: image.width, height: image.height, zoom: zoom, offset: offset);

  /// Zoomed in or out, between [ProfilePicture.zoomMin] and [ProfilePicture.zoomMax].
  void zoomTo(double next) => zoom = next.clamp(ProfilePicture.zoomMin, ProfilePicture.zoomMax);

  /// The picture dragged by [pixels] of it.
  void drag(ui.Offset pixels) =>
      offset = ProfilePicture.moved(offset, pixels, width: image.width, height: image.height, zoom: zoom);
}
