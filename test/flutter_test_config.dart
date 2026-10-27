import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The goldens in test/ui/goldens are made on macOS. Linux and Windows draw text and blur a
/// little differently (from about 1 % of the pixels on Windows to about 12 % on Linux), so CI
/// compares them on macOS only and runs the whole suite on Linux with ANYPS5_SKIP_GOLDENS=1:
/// the screens are still built and pumped, only the pixel comparison is left out.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.environment['ANYPS5_SKIP_GOLDENS'] == '1' && !autoUpdateGoldenFiles) {
    goldenFileComparator = _SkippedGoldens();
  }
  await testMain();
}

class _SkippedGoldens extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}
