import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/profile_look.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/core/together/theme_hub.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/profile_view.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme_hub_model.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';
import 'together_levels_interface_test.dart' show library, mine, recent, signedIn;

/// The screens of profile themes and the showcase, rendered headless: a profile wearing a theme
/// (its still behind the header, tinted, its accent on the highlights, Theme: name), one with a
/// cover and an accent, Edit showcase, Profile theme and Wear on my profile in the Hub. With
/// --dart-define=SHOWCASE_PREVIEW_ALL=true every screen is rendered in both languages.
void main() {
  const previewAll = bool.fromEnvironment('SHOWCASE_PREVIEW_ALL');
  late Fixture fixture;
  late AppModel model;
  late Uint8List still;

  tearDown(() {
    T.language = Language.english;
    ProfileView.pictureFor = NetworkImage.new;
    fixture.dispose();
  });

  final nightDrive = ProfileTheme.fromJson({
    'id': '7d0f4a52-3b1e-4c8a-9f61-2a5b8c9d0e11',
    'name': 'Night Drive',
    'colors': {'deep': '#0b0620', 'middle': '#4a1a6b', 'bright': '#ff5fa2', 'accent': '#ffb347'},
    'preview': 'https://anytogether.net/api/v1/themes/7d0f/preview.webp?v=2',
    'thumb': 'https://anytogether.net/api/v1/themes/7d0f/thumb.webp?v=2',
    'maker': {'handle': 'ana', 'displayName': 'Ana'},
  })!;

  /// A theme's still as the Hub serves one: its colours in soft light, a road of lights across.
  Future<Uint8List> paintStill() async {
    const size = ui.Size(1280, 720);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(size.width, size.height), [
          const Color(0xFF0B0620),
          const Color(0xFF4A1A6B),
        ]),
    );
    void glow(Offset centre, double radius, Color tint) => canvas.drawRect(
      rect,
      ui.Paint()..shader = ui.Gradient.radial(centre, radius, [tint.withValues(alpha: 0.8), tint.withValues(alpha: 0)]),
    );
    glow(const Offset(960, 180), 420, const Color(0xFFFF5FA2));
    glow(const Offset(260, 560), 360, const Color(0xFFFFB347));
    for (var lane = 0; lane < 14; lane++) {
      canvas.drawCircle(
        Offset(120.0 + lane * 82, 470 - lane * 16.0),
        6 + lane * 0.6,
        ui.Paint()..color = const Color(0xFFFFE2B8).withValues(alpha: 0.85),
      );
    }
    final image = await recorder.endRecording().toImage(1280, 720);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  void golden(String name, Language kept, Future<void> Function(WidgetTester tester) screen) {
    for (final language in previewAll ? [Language.english, Language.byCode('tr')] : [kept]) {
      testWidgets('golden: $name (${language.code})', (tester) async {
        fixture = makeFixture(language: language);
        model = fixture.model;
        signedIn(model);
        still = (await tester.runAsync(paintStill))!;
        ProfileView.pictureFor = (_) => MemoryImage(still);
        await screen(tester);
        await expectLater(
          find.byType(LauncherShell),
          matchesGoldenFile('goldens/showcase_${name}_${language.code}.png'),
        );
      });
    }
  }

  ProfilePage minePage({ProfileLook look = const ProfileLook(), Showcase? showcase}) => ProfilePage(
    profile: TogetherProfile(
      userId: 'u-me',
      handle: 'utku',
      displayName: 'Utku Halis',
      bio: 'Night runs in Orbit Runner.',
      country: 'TR',
      friendship: 'me',
      trophyLevel: mine,
      look: look,
    ),
    library: SectionShown(library),
    trophies: SectionShown(recent),
    showcase: SectionShown(showcase ?? const Showcase(trophies: [], games: [])),
  );

  golden('profile_theme', Language.english, (tester) async {
    model.open(Layer.profile);
    model.together
      ..profileReturn = (layer: Layer.friends, category: null, row: null)
      ..profile = minePage(
        look: ProfileLook(theme: nightDrive),
        showcase: Showcase(trophies: recent, games: library.take(2).toList()),
      );
    model.together.profileIndex = 1;
    await pumpLauncher(tester, model);
    expect(find.text('Theme: Night Drive'), findsOneWidget);
    expect(find.text(T.text('showcaseEdit')), findsOneWidget);
    expect(find.text(T.text('profileTheme')), findsOneWidget);
    expect(model.together.profileAccent, const Color(0xFFFFB347));
  });

  golden('profile_cover', Language.byCode('tr'), (tester) async {
    model.open(Layer.profile);
    model.together
      ..profileReturn = (layer: Layer.friends, category: null, row: null)
      ..profile = ProfilePage(
        profile: const TogetherProfile(
          userId: 'u-bora',
          handle: 'bora',
          displayName: 'Bora',
          bio: 'Co-op nights, mostly. Say hi before you join.',
          friendship: 'friends',
          look: ProfileLook(
            cover: ProfileCover(
              kind: 'preset',
              id: 'sunset-glow',
              url: 'https://anytogether.net/covers/sunset-glow.webp',
            ),
            accent: 'mint',
          ),
        ),
        library: SectionShown(library),
        trophies: SectionShown(recent.take(1).toList()),
        showcase: SectionShown(Showcase(trophies: recent, games: library)),
      );
    await pumpLauncher(tester, model);
    expect(find.textContaining('Tema:'), findsNothing, reason: 'a cover, no theme');
    expect(find.text(T.text('compareTrophies')), findsOneWidget);
    expect(find.text(T.text('showcaseEdit')), findsNothing);
  });

  golden('profile_empty', Language.byCode('tr'), (tester) async {
    model.open(Layer.profile);
    model.together
      ..profileReturn = (layer: Layer.friends, category: null, row: null)
      ..profile = minePage();
    await pumpLauncher(tester, model);
    expect(find.text(T.text('showcaseEmpty')), findsOneWidget);
  });

  golden('edit', Language.english, (tester) async {
    model.open(Layer.profile);
    model.together.profile = minePage(
      showcase: Showcase(trophies: recent.take(1).toList(), games: const []),
    );
    model.together.openShowcaseEditor();
    model.panelRow = 2;
    await pumpLauncher(tester, model);
    expect(find.text('1 of 6 pinned'), findsOneWidget);
  });

  golden('choose_theme', Language.byCode('tr'), (tester) async {
    model.open(Layer.profile);
    model.together.profile = minePage(look: ProfileLook(theme: nightDrive));
    model.open(Layer.profileTheme);
    model.together.themeChoices = SectionShown([
      nightDrive,
      ProfileTheme.fromJson({
        'id': '1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d',
        'name': 'Meadow',
        'colors': {'deep': '#03140a', 'middle': '#0f4d2a', 'bright': '#b8f28c', 'accent': '#5cebbd'},
        'maker': {'handle': 'bora', 'displayName': 'Bora'},
      })!,
      ProfileTheme.fromJson({'id': '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d', 'name': 'Paper Lanterns'})!,
    ]);
    model.panelRow = 2;
    await pumpLauncher(tester, model);
    expect(find.text('Çıkar'), findsOneWidget);
  });

  golden('hub', Language.english, (tester) async {
    model.together.hub.self.wornTheme = nightDrive;
    model.hubList = HubShown([
      HubTheme(
        id: nightDrive.id,
        name: 'Night Drive',
        author: 'Ana',
        deep: '#0b0620',
        middle: '#4a1a6b',
        bright: '#ff5fa2',
        accent: '#ffb347',
        package: Uri.parse('https://anytogether.net/x.anyps5theme'),
      ),
      HubTheme(
        id: '1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d',
        name: 'Meadow',
        author: 'Bora',
        deep: '#03140a',
        middle: '#0f4d2a',
        bright: '#b8f28c',
        accent: '#5cebbd',
        package: Uri.parse('https://anytogether.net/y.anyps5theme'),
      ),
    ]);
    model.open(Layer.themes);
    await pumpLauncher(tester, model);
    // The keys go down to Wear on my profile: the list follows them.
    model.panelRow = model.panelCategories().single.rows.indexWhere(
      (row) => row.id == 'hub-wear-1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d',
    );
    model.refresh();
    await settle(tester);
    expect(find.text('Wear on my profile'), findsOneWidget);
    expect(find.text('Take it off'), findsOneWidget);
  });
}
