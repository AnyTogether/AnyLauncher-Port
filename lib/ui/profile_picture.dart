import 'dart:typed_data';
import 'dart:ui' as ui;

/// A profile's picture as the launcher keeps it: the middle square of the one chosen, at most
/// [ProfilePicture.size] pixels a side, as a PNG. Read with the engine's own decoders, so PNG,
/// JPEG and WebP all work without a package of their own.
abstract final class ProfilePicture {
  /// The side of a kept picture: sharp on the picker's 168-point tile at 1.5×.
  static const size = 256;

  /// The files the picker offers.
  static const extensions = ['png', 'jpg', 'jpeg', 'webp'];

  /// Larger files are not read: no picture needs them.
  static const maxBytes = 20 * 1024 * 1024;

  /// [bytes] cut to their middle square and made at most [side] pixels a side (never larger
  /// than the picture was); throws on bytes that are not a picture.
  static Future<Uint8List> square(Uint8List bytes, {int side = size}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    final short = width < height ? width : height;
    if (short <= 0) throw const FormatException('an empty picture');
    // Decoded straight at about twice the size kept, so a 6000-pixel photo is not held whole.
    final decodeScale = short > side * 2 ? side * 2 / short : 1.0;
    final codec = await descriptor.instantiateCodec(
      targetWidth: (width * decodeScale).round(),
      targetHeight: (height * decodeScale).round(),
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final decodedShort = image.width < image.height ? image.width : image.height;
    final out = decodedShort < side ? decodedShort : side;
    final source = ui.Rect.fromLTWH(
      (image.width - decodedShort) / 2,
      (image.height - decodedShort) / 2,
      decodedShort.toDouble(),
      decodedShort.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      source,
      ui.Rect.fromLTWH(0, 0, out.toDouble(), out.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final squared = await picture.toImage(out, out);
    final png = await squared.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    squared.dispose();
    picture.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (png == null) throw const FormatException('the picture could not be written');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  }
}
