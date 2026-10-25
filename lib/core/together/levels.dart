import 'people.dart';
import 'profiles.dart';

/// The metal a trophy level is drawn in: bronze 1-99, silver 100-299, gold 300-599, platinum
/// 600-999.
enum LevelTier {
  bronze,
  silver,
  gold,
  platinum;

  static LevelTier of(int level) => level >= 600
      ? platinum
      : level >= 300
      ? gold
      : level >= 100
      ? silver
      : bronze;
}

/// A trophy level as a badge: the number, its tier, and the frame around it, which grows every
/// 100 levels (1 for 1-99 … 10 for 900-999).
class LevelBadge {
  const LevelBadge({required this.level, required this.tier, required this.frame});

  /// The badge of [level], its tier and frame worked out as the server does.
  factory LevelBadge.of(int level) {
    final clamped = level.clamp(1, 999);
    return LevelBadge(level: clamped, tier: LevelTier.of(clamped), frame: (clamped ~/ 100 + 1).clamp(1, 10));
  }

  /// null when [json] is not a level (missing on an older server, or kept private).
  static LevelBadge? fromJson(Object? json) {
    if (json is! Map || json['level'] is! num) return null;
    final level = (json['level'] as num).toInt().clamp(1, 999);
    final derived = LevelBadge.of(level);
    final frame = json['frame'];
    return LevelBadge(
      level: level,
      tier: LevelTier.values.where((tier) => tier.name == json['tier']).firstOrNull ?? derived.tier,
      frame: frame is num ? frame.toInt().clamp(1, 10) : derived.frame,
    );
  }

  final int level;
  final LevelTier tier;
  final int frame;

  @override
  bool operator ==(Object other) =>
      other is LevelBadge && other.level == level && other.tier == tier && other.frame == frame;

  @override
  int get hashCode => Object.hash(level, tier, frame);

  @override
  String toString() => 'Level $level (${tier.name}, frame $frame)';
}

/// A level with the way to the next one: all trophy points, where this level started and the
/// next one starts (null at the top), and how far along, 0-99 (100 at the top).
class TrophyLevel extends LevelBadge {
  const TrophyLevel({
    required super.level,
    required super.tier,
    required super.frame,
    required this.points,
    required this.levelPoints,
    required this.nextLevelPoints,
    required this.progress,
  });

  static TrophyLevel? fromJson(Object? json) {
    final badge = LevelBadge.fromJson(json);
    if (badge == null) return null;
    json as Map;
    final next = json['nextLevelPoints'];
    return TrophyLevel(
      level: badge.level,
      tier: badge.tier,
      frame: badge.frame,
      points: (json['points'] as num? ?? 0).toInt(),
      levelPoints: (json['levelPoints'] as num? ?? 0).toInt(),
      nextLevelPoints: next is num ? next.toInt() : null,
      progress: (json['progress'] as num? ?? 0).toInt().clamp(0, 100),
    );
  }

  /// A level just reached, before its points are read again.
  factory TrophyLevel.reached(LevelBadge badge, {int points = 0}) => TrophyLevel(
    level: badge.level,
    tier: badge.tier,
    frame: badge.frame,
    points: points,
    levelPoints: points,
    nextLevelPoints: null,
    progress: 0,
  );

  final int points;
  final int levelPoints;
  final int? nextLevelPoints;
  final int progress;

  bool get top => nextLevelPoints == null && level >= 999;

  /// Points still to earn for the next level; null at the top or before it is known.
  int? get toNext => nextLevelPoints == null ? null : (nextLevelPoints! - points).clamp(0, 1 << 30);
}

/// What someone pinned to their profile: trophies and games. A part kept from this user is null.
class Showcase {
  const Showcase({this.trophies, this.games});

  factory Showcase.fromJson(Map<String, dynamic> json) => Showcase(
    trophies: json['trophies'] is List
        ? [
            for (final trophy in json['trophies'] as List<dynamic>)
              if (trophy is Map<String, dynamic>) EarnedTrophy.fromJson(trophy),
          ]
        : null,
    games: json['games'] is List
        ? [
            for (final game in json['games'] as List<dynamic>)
              if (game is Map<String, dynamic>) PlayedGame.fromJson(game),
          ]
        : null,
  );

  final List<EarnedTrophy>? trophies;
  final List<PlayedGame>? games;

  bool get private => trophies == null && games == null;
  bool get empty => (trophies?.isEmpty ?? true) && (games?.isEmpty ?? true);
}

/// One side of a game compared: trophies earned of how many, 0-100, and points.
class CompareSide {
  const CompareSide({required this.earned, this.total, this.progress, this.points = 0});

  static CompareSide? fromJson(Object? json) {
    if (json is! Map) return null;
    return CompareSide(
      earned: (json['earned'] as num? ?? 0).toInt(),
      total: (json['total'] as num?)?.toInt(),
      progress: (json['progress'] as num?)?.toInt(),
      points: (json['points'] as num? ?? 0).toInt(),
    );
  }

  final int earned;
  final int? total;
  final int? progress;
  final int points;
}

/// A game either side has trophies in, with both sides' progress; null where one has none.
class ComparedGame {
  const ComparedGame({required this.titleId, required this.names, this.iconUrl, this.mine, this.theirs});

  factory ComparedGame.fromJson(Map<String, dynamic> json) => ComparedGame(
    titleId: json['titleId'] as String,
    names: namesOf(json['names']),
    iconUrl: json['iconUrl'] as String?,
    mine: CompareSide.fromJson(json['mine']),
    theirs: CompareSide.fromJson(json['theirs']),
  );

  final String titleId;
  final Map<String, String> names;
  final String? iconUrl;
  final CompareSide? mine;
  final CompareSide? theirs;

  bool get both => mine != null && theirs != null;

  String name(String language) => pickName(names, language) ?? titleId;
}

/// A person in a comparison, with their level.
class ComparedPerson {
  const ComparedPerson(this.person, this.level);

  factory ComparedPerson.fromJson(Map<String, dynamic> json) =>
      ComparedPerson(Person.fromJson(json), LevelBadge.fromJson(json['level']));

  final Person person;
  final LevelBadge? level;
}

/// One trophy of the game compared: when each side earned it, null for not yet.
class ComparedTrophy {
  const ComparedTrophy({
    required this.id,
    required this.grade,
    required this.hidden,
    required this.names,
    this.details = const {},
    this.rarity,
    this.rarityLabel,
    this.mine,
    this.theirs,
  });

  factory ComparedTrophy.fromJson(Map<String, dynamic> json) {
    final texts = json['texts'];
    String? text(Object? entry, String key) => entry is Map && entry[key] is String ? entry[key] as String : null;
    return ComparedTrophy(
      id: (json['id'] as num).toInt(),
      grade: json['grade'] as String? ?? 'bronze',
      hidden: json['hidden'] == true,
      names: {
        if (texts is Map)
          for (final entry in texts.entries)
            if (text(entry.value, 'name') case final String name) entry.key as String: name,
      },
      details: {
        if (texts is Map)
          for (final entry in texts.entries)
            if (text(entry.value, 'detail') case final String detail) entry.key as String: detail,
      },
      rarity: (json['rarity'] as num?)?.toDouble(),
      rarityLabel: json['rarityLabel'] as String?,
      mine: DateTime.tryParse(json['mine'] as String? ?? ''),
      theirs: DateTime.tryParse(json['theirs'] as String? ?? ''),
    );
  }

  final int id;
  final String grade;
  final bool hidden;

  /// Its name per language; empty for a hidden trophy this user has not earned.
  final Map<String, String> names;
  final Map<String, String> details;
  final double? rarity;
  final String? rarityLabel;
  final DateTime? mine;
  final DateTime? theirs;

  String? name(String language) => pickName(names, language);
}

/// One game's trophies side by side: who earned what and when, and the totals.
class TrophyComparison {
  const TrophyComparison({
    required this.titleId,
    required this.gameNames,
    this.iconUrl,
    required this.me,
    required this.them,
    required this.trophies,
    required this.mine,
    required this.theirs,
    required this.both,
    required this.total,
  });

  factory TrophyComparison.fromJson(Map<String, dynamic> json) {
    final game = json['game'];
    final trophies = [
      for (final trophy in json['trophies'] as List<dynamic>? ?? const [])
        if (trophy is Map<String, dynamic>) ComparedTrophy.fromJson(trophy),
    ];
    final totals = json['totals'] is Map ? json['totals'] as Map : const {};
    int total(String key, int Function() count) => (totals[key] as num?)?.toInt() ?? count();
    return TrophyComparison(
      titleId: json['titleId'] as String,
      gameNames: game is Map ? namesOf(game['names']) : const {},
      iconUrl: game is Map ? game['iconUrl'] as String? : null,
      me: ComparedPerson.fromJson(json['me'] as Map<String, dynamic>),
      them: ComparedPerson.fromJson(json['them'] as Map<String, dynamic>),
      trophies: trophies,
      mine: total('mine', () => trophies.where((trophy) => trophy.mine != null).length),
      theirs: total('theirs', () => trophies.where((trophy) => trophy.theirs != null).length),
      both: total('both', () => trophies.where((trophy) => trophy.mine != null && trophy.theirs != null).length),
      total: total('total', () => trophies.length),
    );
  }

  final String titleId;
  final Map<String, String> gameNames;
  final String? iconUrl;
  final ComparedPerson me;
  final ComparedPerson them;
  final List<ComparedTrophy> trophies;
  final int mine;
  final int theirs;
  final int both;
  final int total;

  String gameName(String language) => pickName(gameNames, language) ?? titleId;
}
