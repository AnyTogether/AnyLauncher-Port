import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'game_library.dart';

/// A game's pictures: the engine's F12 screenshots (`<TITLE ID>-<date>-<time>.png` straight in the
/// pictures folder, upstream's naming) and the ones the launcher takes when a trophy is earned
/// (`<game name>/<TITLE ID>-trophy<id>-<date>-<time>.png`).
abstract final class Screenshots {
  /// The game's own folder in [pictures]: its name made safe for every file system.
  static String folderFor(String pictures, Game game) => p.join(pictures, safeName(game.name, fallback: game.titleId));

  /// A name with the characters Windows and Linux refuse in file names replaced, without
  /// trailing dots or spaces (Windows drops them).
  static String safeName(String name, {String fallback = 'Game'}) {
    var safe = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty || RegExp(r'^(con|prn|aux|nul|com\d|lpt\d)$', caseSensitive: false).hasMatch(safe)) {
      return fallback;
    }
    return safe.length > 80 ? safe.substring(0, 80).trim() : safe;
  }

  static String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }

  /// Where the picture taken when [trophyId] was earned at [time] goes.
  static String trophyPath(String pictures, Game game, String trophyId, DateTime time) {
    // A trophy id is <service label>/<number>: the slash becomes an underscore.
    final id = trophyId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return p.join(folderFor(pictures, game), '${game.titleId}-trophy$id-${_stamp(time)}.png');
  }

  /// Where a clip saved at [time] goes: the game's own folder, beside its pictures.
  static String clipPath(String pictures, Game game, DateTime time) =>
      p.join(folderFor(pictures, game), '${game.titleId}-clip-${_stamp(time)}.mp4');

  /// Where a screenshot taken by the launcher (Share held) at [time] goes.
  static String shotPath(String pictures, Game game, DateTime time) =>
      p.join(folderFor(pictures, game), '${game.titleId}-${_stamp(time)}.png');

  /// Whether [path] is a clip (from the replay buffer) rather than a picture.
  static bool isClip(String path) => path.toLowerCase().endsWith('.mp4');

  /// Every picture and clip of [game], newest first.
  static List<String> list(String pictures, Game game) {
    final found = <String>[];
    void scan(String folder, bool Function(String name) wanted) {
      try {
        for (final entity in Directory(folder).listSync(followLinks: false)) {
          final name = p.basename(entity.path);
          final lower = name.toLowerCase();
          if (entity is File && (lower.endsWith('.png') || lower.endsWith('.mp4')) && wanted(name)) {
            found.add(entity.path);
          }
        }
      } on FileSystemException {
        // No pictures yet.
      }
    }

    scan(pictures, (name) => name.startsWith('${game.titleId}-'));
    scan(folderFor(pictures, game), (_) => true);
    int compare(String a, String b) {
      // The time in the name first (both namings end in date-time), then the file's own.
      String key(String path) {
        final match = RegExp(r'(\d{8}-\d{6})(-\d+)?\.(png|mp4)$').firstMatch(p.basename(path));
        return match?.group(1) ?? '';
      }

      final byName = key(b).compareTo(key(a));
      return byName != 0 ? byName : b.compareTo(a);
    }

    return found..sort(compare);
  }

  /// The trophy each picture taken when one was earned shows, by trophy id (the newest picture).
  static Map<String, String> trophyShots(List<String> shots) {
    final byTrophy = <String, String>{};
    for (final shot in shots) {
      final match = RegExp(r'-trophy([A-Za-z0-9_]+)-\d{8}-\d{6}').firstMatch(p.basename(shot));
      if (match != null) byTrophy.putIfAbsent(match.group(1)!.replaceAll('_', '/'), () => shot);
    }
    return byTrophy;
  }
}

/// RGBA pixels as a PNG file (8-bit, no filter, zlib through dart:io).
abstract final class PngEncoder {
  static Uint8List rgba(int width, int height, Uint8List pixels, {bool opaque = true}) {
    if (width <= 0 || height <= 0 || pixels.length != width * height * 4) {
      throw ArgumentError('expected ${width}x$height RGBA pixels, got ${pixels.length} bytes');
    }
    final channels = opaque ? 3 : 4;
    final stride = width * channels + 1;
    final raw = Uint8List(stride * height);
    var out = 0;
    var source = 0;
    for (var y = 0; y < height; y++) {
      raw[out++] = 0;
      for (var x = 0; x < width; x++) {
        raw[out++] = pixels[source];
        raw[out++] = pixels[source + 1];
        raw[out++] = pixels[source + 2];
        if (!opaque) raw[out++] = pixels[source + 3];
        source += 4;
      }
    }
    final file = BytesBuilder(copy: false)..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    void chunk(String type, List<int> data) {
      final body = Uint8List(4 + data.length)
        ..setAll(0, type.codeUnits)
        ..setAll(4, data);
      file
        ..add(_u32(data.length))
        ..add(body)
        ..add(_u32(_crc(body)));
    }

    chunk('IHDR', [..._u32(width), ..._u32(height), 8, opaque ? 2 : 6, 0, 0, 0]);
    chunk('IDAT', ZLibEncoder(level: 6).convert(raw));
    chunk('IEND', const []);
    return file.takeBytes();
  }

  static List<int> _u32(int value) => [value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF];

  static final List<int> _table = List.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crc(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }
}
