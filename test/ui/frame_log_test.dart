import 'package:anyps5_desktop/ui/frame_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a line a second: the frames, build and raster average/p90/worst, what is on screen', () {
    final lines = <String>[];
    final log = FrameLog(lines.add, describe: () => 'look glass layer home');
    for (final ms in [2, 4, 6, 8, 30]) {
      log.add(Duration(milliseconds: ms), Duration(milliseconds: ms * 2));
    }
    log.flush(DateTime.utc(2026, 10, 26, 12));
    expect(
      lines.single,
      '2026-10-26T12:00:00.000Z frames 5 build 10.0/30.0/30.0 raster 20.0/60.0/60.0 | look glass layer home',
    );
  });

  test('an idle second says 0 frames, and the next starts afresh', () {
    final lines = <String>[];
    final log = FrameLog(lines.add, describe: () => 'behind')..add(const Duration(milliseconds: 1), Duration.zero);
    log.flush(DateTime.utc(2026));
    log.flush(DateTime.utc(2026));
    expect(lines.last, '2026-01-01T00:00:00.000Z frames 0 build - raster - | behind');
  });

  test('no file named: nothing is measured', () {
    expect(FrameLog.forPath(null, describe: () => ''), isNull);
    expect(FrameLog.forPath('  ', describe: () => ''), isNull);
  });
}
