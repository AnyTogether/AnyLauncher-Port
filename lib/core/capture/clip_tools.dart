import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// What sharing a clip needs from it, with ffmpeg (the replay buffer's): its length, a still for
/// its poster, and a smaller copy when it is larger than AnyTogether takes. The Mac does the same
/// with AVFoundation (MediaPrep).
abstract class ClipTools {
  /// The clip's length, null when it cannot be read.
  Future<int?> durationMs(String path);

  /// A JPEG still from its first second, null when none can be made.
  Future<Uint8List?> poster(String path);

  /// A copy of the clip re-encoded to fit [maxBytes] (H.264 and AAC in MP4), in [folder]; throws
  /// when it cannot be made or still does not fit.
  Future<String> shrink(String path, {required int maxBytes, required int durationMs, required String folder});
}

typedef RunProcess = Future<ProcessResult> Function(String executable, List<String> arguments, {bool binary});

class FfmpegClipTools implements ClipTools {
  FfmpegClipTools(this.ffmpeg, {RunProcess? run}) : _run = run ?? _runProcess;

  final String ffmpeg;
  final RunProcess _run;

  static Future<ProcessResult> _runProcess(String executable, List<String> arguments, {bool binary = false}) =>
      Process.run(executable, arguments, stdoutEncoding: binary ? null : systemEncoding);

  /// "Duration: 00:01:02.50" in what ffmpeg says of its input.
  static int? parseDuration(String text) {
    final match = RegExp(r'Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)').firstMatch(text);
    if (match == null) return null;
    final seconds = int.parse(match.group(1)!) * 3600 + int.parse(match.group(2)!) * 60 + double.parse(match.group(3)!);
    return (seconds * 1000).round();
  }

  @override
  Future<int?> durationMs(String path) async {
    // With no output ffmpeg stops at once, having said what the input is.
    final result = await _run(ffmpeg, ['-hide_banner', '-i', path]);
    return parseDuration('${result.stderr}');
  }

  @override
  Future<Uint8List?> poster(String path) async {
    final result = await _run(ffmpeg, [
      '-v', 'error', '-ss', '0.5', '-i', path, '-frames:v', '1', //
      '-vf', 'scale=min(1280\\,iw):-2', '-f', 'image2pipe', '-c:v', 'mjpeg', '-q:v', '4', '-',
    ], binary: true);
    final bytes = result.stdout;
    if (result.exitCode != 0 || bytes is! List<int> || bytes.length < 4) return null;
    return Uint8List.fromList(bytes);
  }

  /// The video bitrate that fills [maxBytes] over [durationMs] with room to spare, beside 96 kb/s
  /// of sound.
  static int videoBitrate(int maxBytes, int durationMs) {
    final seconds = durationMs / 1000;
    final total = maxBytes * 8 * 0.9 / (seconds <= 0 ? 1 : seconds);
    return (total - 96000).clamp(250000, 8000000).round();
  }

  @override
  Future<String> shrink(String path, {required int maxBytes, required int durationMs, required String folder}) async {
    final out = p.join(folder, '${p.basenameWithoutExtension(path)}-share.mp4');
    final rate = videoBitrate(maxBytes, durationMs);
    final result = await _run(ffmpeg, [
      '-y', '-v', 'error', '-i', path, //
      '-c:v', 'libx264', '-preset', 'veryfast', '-b:v', '$rate', '-maxrate', '$rate', '-bufsize', '${rate * 2}',
      '-vf', 'scale=min(1280\\,iw):-2', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', out,
    ]);
    final file = File(out);
    if (result.exitCode != 0 || !file.existsSync()) throw const FormatException('the clip could not be made smaller');
    if (file.lengthSync() > maxBytes) {
      file.deleteSync();
      throw const FormatException('the clip is still too big');
    }
    return out;
  }
}
