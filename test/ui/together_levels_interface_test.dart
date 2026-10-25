import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/level_badge.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// The screens of trophy levels, the showcase, comparing trophies and appearing offline,
/// rendered headless. Each golden is kept in one language; with
/// --dart-define=LEVELS_PREVIEW_ALL=true every screen is rendered in both (for previews).
void main() {
  const previewAll = bool.fromEnvironment('LEVELS_PREVIEW_ALL');
  late Fixture fixture;
  late AppModel model;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  /// [screen] golden in [kept], or in both languages for previews.
  void golden(
    String name,
    Language kept,
    Future<void> Function(WidgetTester tester) screen, {
    Future<void> Function(WidgetTester tester)? after,
  }) {
    for (final language in previewAll ? Language.values : [kept]) {
      testWidgets('golden: $name (${language.code})', (tester) async {
        fixture = makeFixture(language: language);
        model = fixture.model;
        signedIn(model);
        await screen(tester);
        await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/levels_${name}_${language.code}.png'));
        await after?.call(tester);
      });
    }
  }

  golden('profile_mine', Language.english, (tester) async {
    model.together.hub.self.appearOffline = true;
    model.open(Layer.friends);
    model.open(Layer.profile);
    model.together
      ..profileReturn = Layer.friends
      ..profile = ProfilePage(
        profile: TogetherProfile(
          userId: 'u-me',
          handle: 'utku',
          displayName: 'Utku Halis',
          bio: 'Night runs in Orbit Runner.',
          country: 'TR',
          friendship: 'me',
          trophyLevel: mine,
        ),
        library: SectionShown(library),
        trophies: SectionShown(recent),
      );
    await pumpLauncher(tester, model);
    expect(find.byType(LevelCard), findsOneWidget);
    expect(find.text(T.text('presenceAppearing')), findsWidgets);
    expect(find.text(T.text('compareTrophies')), findsNothing, reason: 'nothing to compare with yourself');
  });

  golden('friends', Language.turkish, (tester) async {
    model.open(Layer.friends);
    await pumpLauncher(tester, model);
    expect(
      find.byType(LevelBadgeView),
      findsNWidgets(4),
      reason: 'mine on the home screen and my row, Bora and Ana; Cem keeps his private',
    );
  });

  golden('profile_friend', Language.english, (tester) async {
    model.open(Layer.friends);
    model.open(Layer.profile);
    model.together
      ..profileReturn = Layer.friends
      ..profile = ProfilePage(
        profile: TogetherProfile(
          userId: 'u-bora',
          handle: 'bora',
          displayName: 'Bora',
          bio: 'Co-op nights, mostly. Say hi before you join.',
          friendship: 'friends',
          trophyLevel: TrophyLevel.fromJson({
            'level': 142,
            'tier': 'silver',
            'frame': 2,
            'points': 10650,
            'levelPoints': 10620,
            'nextLevelPoints': 10710,
            'progress': 33,
          }),
        ),
        library: SectionShown(library),
        trophies: SectionShown(recent.take(1).toList()),
        showcase: SectionShown(
          Showcase(
            trophies: [
              ...recent,
              EarnedTrophy(
                titleId: 'PPSA03003',
                gameNames: const {'en': 'Quiet Forest'},
                trophyId: 4,
                grade: 'gold',
                hidden: false,
                names: const {'en': 'Deep Roots', 'tr': 'Derin Kökler'},
                earnedAt: DateTime(2026, 9, 30),
                rarity: 0.09,
                rarityLabel: 'very_rare',
              ),
            ],
            games: library.take(2).toList(),
          ),
        ),
      );
    await pumpLauncher(tester, model);
    expect(find.text(T.text('compareTrophies')), findsOneWidget);
    expect(find.text(T.text('showcaseTitle')), findsOneWidget);
  });

  golden('compare_games', Language.turkish, (tester) async {
    model.open(Layer.compare);
    model.together
      ..compareReturn = Layer.profile
      ..compareWith = bora
      ..compareIndex = 0
      ..compareGames = const SectionShown(compared);
    await pumpLauncher(tester, model);
    expect(find.text(T.format('compareTitle', ['Bora'])), findsOneWidget);
  });

  golden('compare_trophies', Language.english, (tester) async {
    model.open(Layer.compare);
    model.together
      ..compareReturn = Layer.profile
      ..compareWith = bora
      ..compareGames = const SectionShown(compared)
      ..compareTitleId = 'PPSA02002'
      ..comparisonIndex = 1
      ..comparison = SectionShown(comparison);
    await pumpLauncher(tester, model);
    expect(find.text(T.format('compareBoth', [2])), findsOneWidget);
    expect(find.text(T.text('compareNotYet')), findsWidgets);
  });

  golden('compare_private', Language.turkish, (tester) async {
    model.open(Layer.compare);
    model.together
      ..compareWith = bora
      ..compareGames = const SectionPrivate();
    await pumpLauncher(tester, model);
    expect(find.text(T.format('comparePrivate', ['Bora'])), findsOneWidget);
  });

  golden('toast', Language.turkish, (tester) async {
    await pumpLauncher(tester, model);
    model.show(T.format('levelUp', [12]), level: LevelBadge.of(12));
    await settle(tester);
    expect(find.text(T.format('levelUp', [12])), findsOneWidget);
    expect(find.byType(LevelBadgeView), findsNWidgets(2), reason: 'the toast and mine on the home screen');
    // The toast goes after its time.
  }, after: (tester) => tester.pump(const Duration(seconds: 6)));

  golden('presence', Language.english, (tester) async {
    model.together.hub.self.appearOffline = true;
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'together'));
    model.panelRow = model.panelCategories()[model.panelCategory].rows.indexWhere(
      (row) => row.id == 'together-presence',
    );
    await pumpLauncher(tester, model);
    expect(find.text(T.text('presenceAppearOffline')), findsOneWidget);
  });
}

const bora = Person(id: 'u-bora', handle: 'bora', displayName: 'Bora');

final mine = TrophyLevel.fromJson({
  'level': 12,
  'tier': 'bronze',
  'frame': 1,
  'points': 700,
  'levelPoints': 660,
  'nextLevelPoints': 720,
  'progress': 66,
});

final library = [
  PlayedGame(
    titleId: 'PPSA02002',
    names: const {'en': 'Neon Alley'},
    lastPlayedAt: DateTime(2026, 10, 24, 21),
    secondsPlayed: 152 * 60 + 3600 * 40,
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
  const PlayedGame(titleId: 'PPSA07007', names: {'en': 'Harbor Lights'}, secondsPlayed: 25 * 60),
];

final recent = [
  EarnedTrophy(
    titleId: 'PPSA01001',
    gameNames: const {'en': 'Orbit Runner'},
    trophyId: 0,
    grade: 'platinum',
    hidden: false,
    names: const {'en': 'Grand Tour', 'tr': 'Büyük Tur'},
    earnedAt: DateTime(2026, 10, 2),
    rarity: 0.031,
    rarityLabel: 'ultra_rare',
  ),
  EarnedTrophy(
    titleId: 'PPSA02002',
    gameNames: const {'en': 'Neon Alley'},
    trophyId: 7,
    grade: 'silver',
    hidden: false,
    names: const {'en': 'Night Owl', 'tr': 'Gece Kuşu'},
    earnedAt: DateTime(2026, 10, 24),
    rarity: 0.42,
    rarityLabel: 'common',
  ),
];

const compared = [
  ComparedGame(
    titleId: 'PPSA02002',
    names: {'en': 'Neon Alley'},
    mine: CompareSide(earned: 9, total: 42, progress: 21, points: 255),
    theirs: CompareSide(earned: 18, total: 42, progress: 43, points: 690),
  ),
  ComparedGame(
    titleId: 'PPSA01001',
    names: {'en': 'Orbit Runner'},
    mine: CompareSide(earned: 2, total: 5, progress: 40, points: 45),
    theirs: CompareSide(earned: 5, total: 5, progress: 100, points: 435),
  ),
  ComparedGame(
    titleId: 'PPSA07007',
    names: {'en': 'Harbor Lights', 'tr': 'Liman Işıkları'},
    theirs: CompareSide(earned: 3, total: 12, progress: 25, points: 45),
  ),
  ComparedGame(
    titleId: 'PPSA03003',
    names: {'en': 'Quiet Forest'},
    mine: CompareSide(earned: 1, progress: null, points: 15),
  ),
];

final comparison = TrophyComparison(
  titleId: 'PPSA02002',
  gameNames: const {'en': 'Neon Alley'},
  me: ComparedPerson(const Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis'), LevelBadge.of(12)),
  them: ComparedPerson(bora, LevelBadge.of(142)),
  trophies: [
    ComparedTrophy(
      id: 0,
      grade: 'bronze',
      hidden: false,
      names: const {'en': 'First Light', 'tr': 'İlk Işık'},
      rarity: 0.82,
      rarityLabel: 'common',
      mine: DateTime(2026, 10, 21, 20),
      theirs: DateTime(2026, 10, 19, 20),
    ),
    ComparedTrophy(
      id: 1,
      grade: 'silver',
      hidden: false,
      names: const {'en': 'Back Alleys', 'tr': 'Arka Sokaklar'},
      rarity: 0.36,
      rarityLabel: 'uncommon',
      mine: DateTime(2026, 10, 22, 21),
      theirs: DateTime(2026, 10, 20, 22),
    ),
    ComparedTrophy(
      id: 2,
      grade: 'gold',
      hidden: false,
      names: const {'en': 'Night Owl', 'tr': 'Gece Kuşu'},
      rarity: 0.08,
      rarityLabel: 'very_rare',
      theirs: DateTime(2026, 10, 24, 1),
    ),
    const ComparedTrophy(id: 3, grade: 'gold', hidden: true, names: {}, rarity: 0.04, rarityLabel: 'very_rare'),
    const ComparedTrophy(
      id: 4,
      grade: 'platinum',
      hidden: false,
      names: {'en': 'Neon Legend', 'tr': 'Neon Efsanesi'},
      rarity: 0.012,
      rarityLabel: 'ultra_rare',
    ),
  ],
  mine: 2,
  theirs: 3,
  both: 2,
  total: 5,
);

/// Signed in as Utku (level 12) with four friends, three of them showing their levels.
void signedIn(AppModel model) {
  final together = model.together;
  together.account.user = const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
  together.hub.self
    ..level = mine
    ..loaded = true;
  together.hub.friends
    ..friends = [
      Friend(
        bora,
        Presence(
          state: PresenceState.inGame,
          titleId: 'PPSA02002',
          since: DateTime.now().subtract(const Duration(minutes: 25, seconds: 20)),
        ),
        level: LevelBadge.of(142),
      ),
      Friend(
        const Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
        const Presence(state: PresenceState.online),
        level: LevelBadge.of(640),
      ),
      const Friend(Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz'), Presence()),
    ]
    ..loaded = true;
}
