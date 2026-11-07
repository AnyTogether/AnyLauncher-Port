import 'dart:ui';

import 'package:anyps5_desktop/ui/profile_picture.dart';
import 'package:flutter_test/flutter_test.dart';

/// The crop's sums, the same as the Mac launcher's ProfilePictureTests.
void main() {
  test('zoom 1 is the largest square in the middle', () {
    expect(ProfilePicture.crop(width: 400, height: 200), const Rect.fromLTWH(100, 0, 200, 200));
    expect(ProfilePicture.crop(width: 200, height: 400), const Rect.fromLTWH(0, 100, 200, 200));
  });

  test('zoom and the offset move a smaller square, never past the edges', () {
    expect(ProfilePicture.crop(width: 400, height: 200, zoom: 2), const Rect.fromLTWH(150, 50, 100, 100));
    expect(
      ProfilePicture.crop(width: 400, height: 200, zoom: 2, offset: const Offset(-1, 1)),
      const Rect.fromLTWH(0, 100, 100, 100),
    );
    expect(
      ProfilePicture.crop(width: 400, height: 200, zoom: 2, offset: const Offset(5, -5)),
      const Rect.fromLTWH(300, 0, 100, 100),
    );
    expect(ProfilePicture.crop(width: 400, height: 200, zoom: 0.2), const Rect.fromLTWH(100, 0, 200, 200));
  });

  test('dragging the picture right moves the square left', () {
    final moved = ProfilePicture.moved(Offset.zero, const Offset(50, 0), width: 400, height: 200, zoom: 1);
    expect(moved.dx, closeTo(-0.5, 0.0001));
    expect(moved.dy, 0);
    expect(ProfilePicture.crop(width: 400, height: 200, offset: moved).left, closeTo(50, 0.0001));
    final far = ProfilePicture.moved(Offset.zero, const Offset(-1000, 0), width: 400, height: 200, zoom: 1);
    expect(far.dx, 1);
  });

  test('the crop keeps its zoom between 1 and 4', () async {
    final recorder = PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 40, 20), Paint());
    final image = await recorder.endRecording().toImage(40, 20);
    final crop = PictureCrop(image, profileId: 'p1')..zoomTo(9);
    expect(crop.zoom, 4);
    crop.zoomTo(0);
    expect(crop.zoom, 1);
    crop.drag(const Offset(-100, 0));
    expect(crop.rect, const Rect.fromLTWH(20, 0, 20, 20));
    image.dispose();
  });
}
