import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:anyps5_desktop/ui/sealed_photo.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_test/flutter_test.dart';

/// A photo is drawn again as a new PNG before it is sealed: the server cannot strip a sealed
/// file, so nothing of the original (location, camera, any metadata) may go along.
void main() {
  Future<Uint8List> picture(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var x = 0; x < width; x += 8) {
      canvas.drawRect(
        ui.Rect.fromLTWH(x.toDouble(), 0, 8, height.toDouble()),
        ui.Paint()..color = ui.Color.fromARGB(255, x % 256, (x * 3) % 256, 120),
      );
    }
    final image = await recorder.endRecording().toImage(width, height);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  }

  /// [png] with a chunk of [type] holding [data] put in after its header.
  Uint8List withChunk(Uint8List png, String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final length = ByteData(4)..setUint32(0, data.length);
    final crc = ByteData(4)..setUint32(0, getCrc32([...typeBytes, ...data]));
    // The signature (8) and IHDR (4 + 4 + 13 + 4) come first.
    const afterHeader = 33;
    return Uint8List.fromList([
      ...png.sublist(0, afterHeader),
      ...length.buffer.asUint8List(),
      ...typeBytes,
      ...data,
      ...crc.buffer.asUint8List(),
      ...png.sublist(afterHeader),
    ]);
  }

  bool has(List<int> bytes, String text) {
    final needle = ascii.encode(text);
    for (var i = 0; i + needle.length <= bytes.length; i++) {
      var all = true;
      for (var j = 0; j < needle.length && all; j++) {
        all = bytes[i + j] == needle[j];
      }
      if (all) return true;
    }
    return false;
  }

  test('leaves the location, the camera and every other chunk behind', () async {
    var source = await picture(120, 80);
    source = withChunk(source, 'eXIf', ascii.encode('MM\x00*GPSLatitude 41.0082 Canon EOS'));
    source = withChunk(source, 'tEXt', ascii.encode('Comment\x00taken at home, GPSLongitude 28.97'));
    expect(has(source, 'GPSLatitude'), isTrue, reason: 'the test photo carries them');
    final clean = await SealedPhoto.clean(source);
    expect(has(clean.bytes, 'GPS'), isFalse);
    expect(has(clean.bytes, 'Canon'), isFalse);
    expect(has(clean.bytes, 'eXIf'), isFalse);
    expect(has(clean.bytes, 'tEXt'), isFalse);
    expect([clean.width, clean.height], [120, 80]);
    expect(clean.type, 'image/png');
    // Still a picture of the same size.
    final codec = await ui.instantiateImageCodec(clean.bytes);
    final frame = await codec.getNextFrame();
    expect([frame.image.width, frame.image.height], [120, 80]);
  });

  test('a big photo is made smaller, its shape kept', () async {
    final clean = await SealedPhoto.clean(await picture(400, 200), side: 100);
    expect([clean.width, clean.height], [100, 50]);
  });

  test('one that does not fit the limit is made smaller until it does', () async {
    final source = await picture(800, 800);
    final whole = await SealedPhoto.clean(source);
    final limit = whole.bytes.length ~/ 2;
    final clean = await SealedPhoto.clean(source, limit: limit);
    expect(clean.bytes.length, lessThanOrEqualTo(limit));
    expect(clean.width, lessThan(800));
    expect(clean.width, clean.height);
  });

  test('bytes that are no picture are refused', () async {
    expect(() => SealedPhoto.clean(Uint8List.fromList(utf8.encode('not a picture'))), throwsFormatException);
  });
}
