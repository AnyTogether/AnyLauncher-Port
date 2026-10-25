import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/steam/steam_shortcuts.dart';
import 'package:anyps5_desktop/ui/steam_art.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

/// A PNG's size from its IHDR chunk.
(int, int) pngSize(Uint8List png) {
  expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final data = ByteData.sublistView(png);
  return (data.getUint32(16), data.getUint32(20));
}

Future<String> solidPng(String path, int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
  return path;
}

void main() {
  // Set STEAM_ART_OUT to a folder to look at the pictures (STEAM_ART_GAME: a dump's sce_sys).
  final out = Platform.environment['STEAM_ART_OUT'];

  void keep(String prefix, Map<SteamArt, Uint8List> art) {
    if (out == null) return;
    Directory(out).createSync(recursive: true);
    for (final MapEntry(:key, :value) in art.entries) {
      File(p.join(out, '$prefix${key.suffix}')).writeAsBytesSync(value);
    }
  }

  testWidgets('AnyPS5\'s pictures come in Steam\'s sizes', (tester) async {
    await loadFonts();
    final art = (await tester.runAsync(SteamArtist.launcher))!;
    expect(art.keys, SteamArt.values);
    expect(pngSize(art[SteamArt.portrait]!), (600, 900));
    expect(pngSize(art[SteamArt.wide]!), (920, 430));
    expect(pngSize(art[SteamArt.hero]!), (1920, 620));
    expect(pngSize(art[SteamArt.icon]!), (256, 256));
    expect(pngSize(art[SteamArt.logo]!).$1, greaterThan(800));
    keep('launcher', art);
  });

  testWidgets('a game\'s come from its pic0 and icon0, and without them from the Cosmic field', (tester) async {
    await loadFonts();
    final temp = Directory.systemTemp.createTempSync('art');
    addTearDown(() => temp.deleteSync(recursive: true));
    final game = Platform.environment['STEAM_ART_GAME'];
    final art = (await tester.runAsync(() async {
      final background = game != null
          ? p.join(game, 'pic0.png')
          : await solidPng(p.join(temp.path, 'pic0.png'), 1920, 1080, const Color(0xFF884422));
      final cover = game != null
          ? p.join(game, 'icon0.png')
          : await solidPng(p.join(temp.path, 'icon0.png'), 512, 512, const Color(0xFF2266AA));
      return (
        await SteamArtist.game(name: 'Hollow Knight: Silksong', background: background, cover: cover),
        await SteamArtist.game(name: 'A Game Without Any Pictures', background: p.join(temp.path, 'missing.png')),
      );
    }))!;
    for (final set in [art.$1, art.$2]) {
      expect(set.keys, SteamArt.values);
      expect(pngSize(set[SteamArt.portrait]!), (600, 900));
      expect(pngSize(set[SteamArt.wide]!), (920, 430));
      expect(pngSize(set[SteamArt.hero]!), (1920, 620));
      expect(pngSize(set[SteamArt.icon]!), (256, 256));
    }
    keep('game', art.$1);
    keep('bare', art.$2);
  });
}
