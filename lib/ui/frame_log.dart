import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// `ANYPS5_FRAME_LOG=<file>`: a line every second with how many frames the launcher drew and how
/// long they took (build on the CPU, raster on the GPU: average, 90th percentile and worst, in
/// ms), and what was on screen. An idle launcher, or one behind a game, draws 0 frames a second.
/// For testers' reports of a slow launcher; nothing is measured without it.
class FrameLog {
  FrameLog(this._write, {required this.describe});

  /// The log for [path] (appended to), or null for none.
  static FrameLog? forPath(String? path, {required String Function() describe}) {
    if (path == null || path.trim().isEmpty) return null;
    return FrameLog((line) {
      try {
        File(path).writeAsStringSync('$line\n', mode: FileMode.append);
      } on FileSystemException {
        // The log is a help, never a reason to stop.
      }
    }, describe: describe);
  }

  final void Function(String line) _write;

  /// What is on screen (the look, the layer, a game running), written with each line.
  final String Function() describe;

  final List<int> _build = [];
  final List<int> _raster = [];
  Timer? _timer;

  /// Writes a line every [every] until [stop].
  void start({Duration every = const Duration(seconds: 1)}) {
    _timer ??= Timer.periodic(every, (_) => flush());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// A frame drawn: [build] on the UI thread, [raster] on the raster thread.
  void add(Duration build, Duration raster) {
    _build.add(build.inMicroseconds);
    _raster.add(raster.inMicroseconds);
  }

  /// The line for the frames since the last one (also with none).
  String line(DateTime now) {
    String stats(List<int> values) {
      if (values.isEmpty) return '-';
      final sorted = [...values]..sort();
      final average = sorted.reduce((a, b) => a + b) / sorted.length;
      final p90 = sorted[math.min(sorted.length - 1, (sorted.length * 0.9).floor())];
      String ms(num micros) => (micros / 1000).toStringAsFixed(1);
      return '${ms(average)}/${ms(p90)}/${ms(sorted.last)}';
    }

    return '${now.toIso8601String()} frames ${_build.length} build ${stats(_build)} raster ${stats(_raster)} '
        '| ${describe()}';
  }

  void flush([DateTime? now]) {
    _write(line(now ?? DateTime.now()));
    _build.clear();
    _raster.clear();
  }
}
