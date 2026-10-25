import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/core/trophies.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/background.dart';
import 'package:anyps5_desktop/ui/glass.dart';
import 'package:anyps5_desktop/ui/home.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:anyps5_desktop/ui/trophy_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import '../support/ui_support.dart';
import 'together_interface_test.dart' show signedInPreview;

/// The Glass look: its place among the looks and in the preferences, the contrast its recipe
/// promises, and its screens.
void main() {
  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
  });

  group('the look', () {
    test('Glass is the fourth look, kept as 3; anything unknown is Cosmic', () {
      expect(LookStyle.glass.index, 3);
      expect(LookStyle.values.take(3), [LookStyle.cosmic, LookStyle.aurora, LookStyle.sunset]);
      expect(LookStyle.fromIndex(3), LookStyle.glass);
      for (final unknown in [-1, 4, 99, null, '3', 2.5]) {
        expect(LookStyle.fromIndex(unknown), LookStyle.cosmic, reason: '$unknown');
      }
    });

    test('its colors, name and default accent match the Mac', () {
      expect(LookStyle.hex(LookStyle.glass.deep), '#04101C');
      expect(LookStyle.hex(LookStyle.glass.middle), '#1C4F73');
      expect(LookStyle.hex(LookStyle.glass.bright), '#CFEFFF');
      expect(LookStyle.glass.defaultAccent, Accent.ice);
      expect(LookStyle.hex(Accent.ice.color), '#8AD8FF');
      expect(Accent.ice.index, Accent.values.length - 1, reason: 'new accents go last');
      expect(LookStyle.glass.title, 'Glass');
      expect(Accent.ice.title, 'Ice');
      T.language = Language.turkish;
      expect(LookStyle.glass.title, 'Cam');
      expect(Accent.ice.title, 'Buz');
    });

    test('saved as 3 and read back; garbage reads as Cosmic and keeps the other choices', () {
      final temp = temporaryFolder('glass-prefs');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = p.join(temp.path, 'preferences.json');
      final saved = Preferences()
        ..theme = LookStyle.glass.index
        ..reduceTransparency = true
        ..profileName = 'Utku';
      saved.save(file);
      expect((jsonDecode(File(file).readAsStringSync()) as Map)['theme'], 3);
      final read = Preferences.load(file);
      expect(read.theme, 3);
      expect(read.reduceTransparency, isTrue);

      for (final garbage in [99, -4, 'glass', 3.7, null, true]) {
        final json = {...saved.toJson(), 'theme': garbage};
        File(file).writeAsStringSync(jsonEncode(json));
        final back = Preferences.load(file);
        expect(back.theme, garbage == 3.7 ? 3 : LookStyle.cosmic.index, reason: '$garbage');
        expect(back.profileName, 'Utku', reason: 'the rest of the file still counts ($garbage)');
      }
    });

    test('the model wears Glass with the Ice accent, and a theme index it does not know as Cosmic', () {
      final fixture = makeFixture(theme: 3);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      expect(model.look, LookStyle.glass);
      expect(model.accentChoice, Accent.ice);
      model.preferences.theme = 42;
      expect(model.look, LookStyle.cosmic);
      expect(model.accentChoice, Accent.blue);
    });

    test('choosing Glass in the settings resets the accent to Ice; Reduce Transparency shows only there', () {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      model.preferences.accent = Accent.gold.name;
      model.open(Layer.settings);
      List<String> rows() => model.panelCategories().first.rows.map((row) => row.id).toList();
      expect(rows(), isNot(contains('transparency')));
      for (var step = 0; step < 3; step++) {
        model.handle(Command.right);
      }
      expect(model.preferences.theme, 3);
      expect(model.look, LookStyle.glass);
      expect(model.accentChoice, Accent.ice);
      expect(rows(), containsAllInOrder(['theme', 'transparency', 'accent']));
      expect(model.solidGlass, isFalse);
      model.panelRow = rows().indexOf('transparency');
      model.handle(Command.select);
      expect(model.preferences.reduceTransparency, isTrue);
      expect(model.solidGlass, isTrue);
    });

    test('a GPU too slow for the blur turns Glass solid once, with a word; other looks are left alone', () {
      final fixture = makeFixture(theme: 3);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      model.glassTooSlow();
      expect(model.glassFallback, isTrue);
      expect(model.solidGlass, isTrue);
      expect(model.toast, T.text('glassFallback'));
      final cosmic = makeFixture();
      addTearDown(cosmic.dispose);
      cosmic.model.glassTooSlow();
      expect(cosmic.model.glassFallback, isFalse);
    });

    test('the raster watch trips only when most frames of two windows in a row are slow', () {
      var slow = 0;
      final watch = RasterWatch(onSlow: () => slow++, window: 10);
      const fast = Duration(milliseconds: 6);
      const late = Duration(milliseconds: 16);
      watch.add([for (var i = 0; i < 10; i++) i < 7 ? late : fast]);
      watch.add([for (var i = 0; i < 10; i++) i < 4 ? late : fast]);
      expect(slow, 0, reason: 'a window under the share starts over');
      watch.add(List.filled(10, late));
      expect(slow, 0, reason: 'one slow window is a stutter');
      watch.add(List.filled(10, late));
      expect(slow, 1);
      watch.add(List.filled(40, late));
      expect(slow, 1, reason: 'once');
      final again = RasterWatch(onSlow: () => slow++, window: 10)..add(List.filled(10, late));
      again
        ..reset()
        ..add(List.filled(10, late));
      expect(slow, 1, reason: 'a reset forgets the first window');
    });
  });

  group('contrast (WCAG 2)', () {
    const white = Color(0xFFFFFFFF);
    const scrimNavy = GlassRecipe.layer;

    test('ink on the accents: dark on the light ones', () {
      for (final accent in Accent.values) {
        final light = Contrast.luminance(accent.color) > 0.4;
        expect(accent.ink, light ? Contrast.darkInk : Contrast.lightInk, reason: accent.name);
      }
      expect(Accent.ice.ink, Contrast.darkInk);
      expect(Contrast.ratio(Accent.ice.ink, Accent.ice.color), greaterThan(4.5));
      expect(Contrast.ratio(const Color(0xFF000000), white), closeTo(21, 0.01));
      expect(Contrast.ratio(white, white), 1);
    });

    test('white text on glass over the frosted picture\'s brightest pixel, under the lightest veil', () {
      // The brightest the picture can be (a white pixel: the ice tint keeps lightness), under the
      // thinnest part of the veil (the right edge, upper half), then the glass at its sheen.
      final thinnest = [
        for (var x = 0.0; x <= 1; x += 0.05)
          for (var y = 0.0; y <= 1; y += 0.05) GlassRecipe.veilAt(x, y),
      ].reduce(math.min);
      expect(thinnest, closeTo(GlassRecipe.veil, 1e-9));
      final backdrop = GlassRecipe.over(scrimNavy, thinnest, GlassRecipe.artworkCeiling);
      final surface = GlassRecipe.surfaceOver(backdrop);
      expect(Contrast.ratio(white, surface), greaterThanOrEqualTo(4.5));
    });

    test('the focused ice chip\'s ink, over the darkest and the brightest backdrops', () {
      for (final backdrop in [const Color(0xFF000000), white, LookStyle.glass.bright]) {
        final chip = GlassRecipe.over(white, GlassRecipe.chipTo, backdrop);
        expect(Contrast.ratio(GlassRecipe.ink, chip), greaterThanOrEqualTo(4.5), reason: '$backdrop');
      }
    });

    test('a full-screen layer over the brightest picture, then a panel on it', () {
      final layer = GlassRecipe.over(scrimNavy, GlassRecipe.layerOpacity, GlassRecipe.artworkCeiling);
      final panel = GlassRecipe.surfaceOver(layer);
      expect(Contrast.ratio(white, panel), greaterThanOrEqualTo(4.5));
      // The rows' detail text, at 72 % white.
      expect(Contrast.ratio(GlassRecipe.over(white, 0.72, panel), panel), greaterThanOrEqualTo(4.5));
    });

    testWidgets('white text on glass over the background shader\'s brightest pixel', (tester) async {
      await tester.runAsync(() async {
        await loadFonts();
        await ThemeBackground.preload();
      });
      tester.view.physicalSize = const Size(800, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var brightest = const Color(0xFF000000);
      for (final time in [0.0, 120.0, 900.0, 2400.0]) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('background'),
            child: ThemeBackground(style: LookStyle.glass, time: time),
          ),
        );
        final pixels = await tester.runAsync(() async {
          final image = await captureImage(find.byKey(const ValueKey('background')).evaluate().single);
          final data = await image.toByteData();
          image.dispose();
          return data!;
        });
        for (var offset = 0; offset < pixels!.lengthInBytes; offset += 4) {
          final color = Color.fromARGB(
            255,
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2),
          );
          if (Contrast.luminance(color) > Contrast.luminance(brightest)) brightest = color;
        }
      }
      expect(Contrast.luminance(brightest), greaterThan(0.005), reason: 'the shader drew');
      final surface = GlassRecipe.surfaceOver(brightest);
      expect(Contrast.ratio(white, surface), greaterThanOrEqualTo(4.5), reason: 'brightest $brightest');
      expect(Contrast.ratio(GlassRecipe.over(white, 0.72, surface), surface), greaterThanOrEqualTo(4.5));
    });
  });

  group('golden', () {
    late Fixture fixture;

    tearDown(() => fixture.dispose());

    int indexOf(AppModel model, String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

    /// Orbit Runner's key art: a bright sky, a sun and a planet, so the frosting shows.
    void keyArt(AppModel model) {
      final game = model.games[indexOf(model, 'PPSA01001')];
      File(p.join(game.folder, 'sce_sys', 'pic0.png')).writeAsBytesSync(
        png(320, 180, (x, y) {
          final t = y / 180;
          double disc(double cx, double cy, double r) =>
              math.max(0, 1 - math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2)) / r);
          final sun = disc(250, 50, 70);
          final planet = disc(110, 150, 90);
          int channel(double sky, double sunTint, double planetTint) =>
              (sky * (1 - t) + 40 * t + 255 * sun * sunTint + 200 * planet * planetTint).round().clamp(0, 255);
          return channel(255, 1, 0.9) << 24 | channel(150, 0.85, 0.3) << 16 | channel(70, 0.4, 0.8) << 8 | 0xFF;
        }),
      );
    }

    Future<void> shoot(WidgetTester tester, String name) =>
        expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/$name.png'));

    testWidgets('home, an installed game selected, its picture frosted', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.select(indexOf(model, 'PPSA01001'));
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_home');
      // The cards' labels (72 % white) keep AA contrast over the brightest picture where the
      // cards are: the veil there is the left-to-right one and the bottom one together.
      final cards = find.byType(InfoCard).evaluate().map((element) => tester.getRect(find.byWidget(element.widget)));
      final worst = Offset(
        cards.map((rect) => rect.right).reduce(math.max),
        cards.map((rect) => rect.top).reduce(math.min),
      );
      final veil = GlassRecipe.veilAt(worst.dx / 1600, worst.dy / 900);
      final surface = GlassRecipe.surfaceOver(GlassRecipe.over(GlassRecipe.layer, veil, GlassRecipe.artworkCeiling));
      const white = Color(0xFFFFFFFF);
      expect(Contrast.ratio(GlassRecipe.over(white, 0.72, surface), surface), greaterThanOrEqualTo(4.5));
      // The phone pill's words (90 % white) in the top bar, under the thinnest veil.
      final pill = GlassRecipe.surfaceOver(
        GlassRecipe.over(GlassRecipe.layer, GlassRecipe.veil, GlassRecipe.artworkCeiling),
      );
      expect(Contrast.ratio(GlassRecipe.over(white, 0.9, pill), pill), greaterThanOrEqualTo(4.5));
    });

    testWidgets('home, in Turkish, a locked game with the unlock button focused', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.turkish);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      expect(find.text('Kilidi Aç'), findsOneWidget);
      await shoot(tester, 'glass_home_tr');
    });

    testWidgets('home, the settings button focused, with Reduce Transparency', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.preferences.reduceTransparency = true;
      model.select(indexOf(model, 'PPSA01001'));
      model.handle(Command.up);
      model.handle(Command.up);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_home_solid');
    });

    testWidgets('library grid', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.open(Layer.library);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_library');
    });

    testWidgets('game settings, in Turkish', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.turkish);
      final model = fixture.model;
      keyArt(model);
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.gameSettings);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_game_settings_tr');
    });

    testWidgets('settings, appearance', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      expect(find.text('Glass'), findsOneWidget);
      expect(find.text('Ice'), findsOneWidget);
      expect(find.text('Reduce Transparency'), findsOneWidget);
      await shoot(tester, 'glass_settings');
    });

    testWidgets('settings, appearance, in Turkish', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.turkish);
      final model = fixture.model;
      model.open(Layer.settings);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      expect(find.text('Cam'), findsOneWidget);
      expect(find.text('Şeffaflığı Azalt'), findsOneWidget);
      await shoot(tester, 'glass_settings_tr');
    });

    testWidgets('friends', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      signedInPreview(model);
      model.open(Layer.friends);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_friends');
    });

    testWidgets('a friend\'s profile, in Turkish', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.turkish);
      final model = fixture.model;
      keyArt(model);
      signedInPreview(model);
      model.open(Layer.friends);
      model.open(Layer.profile);
      model.together
        ..profileReturn = Layer.friends
        ..profileIndex = 2
        ..profile = ProfilePage(
          profile: const TogetherProfile(
            userId: 'u-bora',
            handle: 'bora',
            displayName: 'Bora',
            bio: 'Çoğunlukla ortak oyun geceleri.',
            country: 'TR',
            friendship: 'friends',
          ),
          library: SectionShown([
            PlayedGame(
              titleId: 'PPSA02002',
              names: const {'en': 'Neon Alley'},
              lastPlayedAt: DateTime(2026, 10, 24, 21),
              secondsPlayed: 3600 * 42,
              trophiesEarned: 18,
              trophiesTotal: 42,
              progress: 43,
              points: 690,
            ),
            PlayedGame(
              titleId: 'PPSA01001',
              names: const {'en': 'Orbit Runner'},
              lastPlayedAt: DateTime(2026, 10, 2),
              secondsPlayed: 3 * 3600,
              trophiesEarned: 5,
              trophiesTotal: 5,
              progress: 100,
              points: 435,
            ),
          ]),
          trophies: SectionShown([
            EarnedTrophy(
              titleId: 'PPSA01001',
              gameNames: const {'en': 'Orbit Runner'},
              trophyId: 0,
              grade: 'platinum',
              hidden: false,
              names: const {'en': 'Grand Tour'},
              earnedAt: DateTime(2026, 10, 2),
              rarity: 0.031,
              rarityLabel: 'ultra_rare',
            ),
          ]),
        );
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_profile_tr');
    });

    testWidgets('trophies', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.trophies);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_trophies');
    });

    testWidgets('a new game copied in: its toast', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      final orbit = model.games[indexOf(model, 'PPSA01001')];
      model.select(indexOf(model, 'PPSA01001'));
      model.show(T.format('newGame', [orbit.name]), icon: orbit.icon);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_toast');
      await tester.pump(const Duration(seconds: 5));
    });

    for (final language in [Language.english, Language.turkish]) {
      testWidgets('the trophy card over a game, ${language.code}', (tester) async {
        fixture = makeFixture(theme: 3);
        T.language = language;
        final trophy = Trophy(
          serviceLabel: 0,
          number: 3,
          grade: TrophyGrade.gold,
          hidden: false,
          name: language == Language.turkish ? 'Kalenin Kalbine' : 'Into the Citadel',
          detail: language == Language.turkish ? 'Pharloom\'un kalbine ulaş' : 'Reach the heart of Pharloom',
          icon: iconArt(0xF2C14E, 0x5C3B0B, size: 64),
        );
        final card = await tester.runAsync(() async {
          await loadFonts();
          await ThemeBackground.preload();
          final rgba = await TrophyCard.render(trophy, glass: true);
          final completer = <ui.Image>[];
          ui.decodeImageFromPixels(rgba.pixels, rgba.width, rgba.height, ui.PixelFormat.rgba8888, completer.add);
          while (completer.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          return completer.single;
        });
        tester.view.physicalSize = const Size(720, 240);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: const ValueKey('card'),
              // A game behind it: the card is its own window, drawn over whatever runs.
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF3A5A40), Color(0xFF8D6E4A), Color(0xFF2B2D42)],
                  ),
                ),
                child: Center(child: RawImage(image: card)),
              ),
            ),
          ),
        );
        await expectLater(
          find.byKey(const ValueKey('card')),
          matchesGoldenFile('goldens/glass_trophy_card_${language.code}.png'),
        );
        card!.dispose();
      });
    }
  });

  testWidgets('the onboarding offers Glass beside the other looks', (tester) async {
    final fixture = makeFixture(onboarded: false, withToolkit: false);
    addTearDown(fixture.dispose);
    final model = fixture.model;
    await pumpLauncher(tester, model);
    await press(tester, LogicalKeyboardKey.enter);
    for (var step = 0; step < 3; step++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(model.preferences.theme, 3);
    expect(model.look, LookStyle.glass);
    expect(find.text('Glass'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'four cards fit the row');
  });
}
