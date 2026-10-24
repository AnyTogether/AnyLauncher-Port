import 'account.dart';
import 'people.dart';

/// The user's language, then English, then any.
String? pickName(Map<String, String> names, String language) {
  if (names.isEmpty) return null;
  return names[language] ?? names['en'] ?? names[(names.keys.toList()..sort()).first];
}

Map<String, String> _names(Object? json) => {
  if (json is Map)
    for (final entry in json.entries)
      if (entry.value is String) entry.key as String: entry.value as String,
};

/// Someone's profile as AnyTogether shows it to this user.
class TogetherProfile {
  const TogetherProfile({
    required this.userId,
    required this.handle,
    required this.displayName,
    this.avatar,
    this.bio,
    this.country,
    this.friendship = 'none',
  });

  factory TogetherProfile.fromJson(Map<String, dynamic> json) => TogetherProfile(
    userId: json['userId'] as String,
    handle: json['handle'] as String,
    displayName: json['displayName'] as String,
    avatar: json['avatar'] as String?,
    bio: json['bio'] as String?,
    country: json['country'] as String?,
    friendship: json['friendship'] as String? ?? 'none',
  );

  final String userId;
  final String handle;
  final String displayName;
  final String? avatar;
  final String? bio;
  final String? country;

  /// me, friends, none, pending_out (this user asked) or pending_in (they asked).
  final String friendship;

  bool get isMe => friendship == 'me';
}

/// A game in someone's library: its names, play time and trophy progress.
class PlayedGame {
  const PlayedGame({
    required this.titleId,
    required this.names,
    this.iconUrl,
    this.lastPlayedAt,
    this.secondsPlayed = 0,
    this.trophiesEarned,
    this.trophiesTotal,
    this.progress,
    this.points,
  });

  factory PlayedGame.fromJson(Map<String, dynamic> json) => PlayedGame(
    titleId: json['titleId'] as String,
    names: _names(json['names']),
    iconUrl: json['iconUrl'] as String?,
    lastPlayedAt: DateTime.tryParse(json['lastPlayedAt'] as String? ?? ''),
    secondsPlayed: (json['secondsPlayed'] as num? ?? 0).toInt(),
    trophiesEarned: (json['trophiesEarned'] as num?)?.toInt(),
    trophiesTotal: (json['trophiesTotal'] as num?)?.toInt(),
    progress: (json['progress'] as num?)?.toInt(),
    points: (json['points'] as num?)?.toInt(),
  );

  final String titleId;
  final Map<String, String> names;
  final String? iconUrl;
  final DateTime? lastPlayedAt;
  final int secondsPlayed;

  /// null where the owner keeps their trophies from this user.
  final int? trophiesEarned;
  final int? trophiesTotal;

  /// 0-100, null when the game's trophy set is unknown or kept private.
  final int? progress;
  final int? points;

  String name(String language) => pickName(names, language) ?? titleId;
}

/// A trophy someone earned, with how rare it is among AnyTogether's players of the game.
class EarnedTrophy {
  const EarnedTrophy({
    required this.titleId,
    required this.gameNames,
    required this.trophyId,
    required this.grade,
    required this.hidden,
    required this.names,
    required this.earnedAt,
    this.rarity,
    this.rarityLabel,
  });

  factory EarnedTrophy.fromJson(Map<String, dynamic> json) {
    final texts = json['texts'];
    return EarnedTrophy(
      titleId: json['titleId'] as String,
      gameNames: _names(json['gameNames']),
      trophyId: (json['trophyId'] as num).toInt(),
      grade: json['grade'] as String? ?? 'bronze',
      hidden: json['hidden'] as bool? ?? false,
      names: {
        if (texts is Map)
          for (final entry in texts.entries)
            if (entry.value is Map && (entry.value as Map)['name'] is String)
              entry.key as String: (entry.value as Map)['name'] as String,
      },
      earnedAt: DateTime.tryParse(json['earnedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      rarity: (json['rarity'] as num?)?.toDouble(),
      rarityLabel: json['rarityLabel'] as String?,
    );
  }

  final String titleId;
  final Map<String, String> gameNames;
  final int trophyId;
  final String grade;
  final bool hidden;

  /// Its name per language; empty for a hidden trophy this user has not earned.
  final Map<String, String> names;
  final DateTime earnedAt;

  /// The share of the game's players who have it, 0-1.
  final double? rarity;

  /// common, uncommon, rare, very_rare or ultra_rare.
  final String? rarityLabel;

  String? name(String language) => pickName(names, language);

  String gameName(String language) => pickName(gameNames, language) ?? titleId;
}

/// A section of a profile: shown, kept private by its owner (or for friends), or not read.
sealed class Section<T> {
  const Section();

  T? get value => this is SectionShown<T> ? (this as SectionShown<T>).items : null;
}

class SectionShown<T> extends Section<T> {
  const SectionShown(this.items);
  final T items;
}

class SectionPrivate<T> extends Section<T> {
  const SectionPrivate();
}

class SectionFailed<T> extends Section<T> {
  const SectionFailed();
}

/// Everything a profile shows, read together.
class ProfilePage {
  const ProfilePage({
    required this.profile,
    required this.library,
    required this.trophies,
    this.detailsPrivate = false,
  });

  final TogetherProfile profile;

  /// The profile's details (bio, country) are private: the card the launcher knew stands in.
  final bool detailsPrivate;
  final Section<List<PlayedGame>> library;
  final Section<List<EarnedTrophy>> trophies;

  /// Games, play time, trophies and points, from the library; null when it is not shown.
  ({int games, int seconds, int trophies, int points})? get totals {
    final games = library.value;
    if (games == null) return null;
    return (
      games: games.length,
      seconds: games.fold(0, (sum, game) => sum + game.secondsPlayed),
      trophies: games.fold(0, (sum, game) => sum + (game.trophiesEarned ?? 0)),
      points: games.fold(0, (sum, game) => sum + (game.points ?? 0)),
    );
  }
}

/// Profiles: someone's card, their library and their recent trophies, each section private or
/// shown as its owner chose.
class Profiles {
  const Profiles(this.account);

  final TogetherAccount account;

  /// A handle as a path component: without the @, escaped.
  static String path(String handle) => Uri.encodeComponent(handle.trim().replaceFirst(RegExp('^@'), ''));

  static bool isPrivate(TogetherProblem problem) =>
      problem.status == 403 || problem.code == 'private' || problem.code == 'forbidden';

  /// The profile, its library and its recent trophies at once. A section the server keeps
  /// private (403, or `private: true`) comes back private; profile details kept private fall
  /// back to [card], the person as the friends list knows them.
  Future<ProfilePage> page(String handle, {Person? card}) async {
    final library = _section(() async {
      final json = await account.call('GET', 'users/${path(handle)}/library');
      if (json['private'] == true) return null;
      return [
        for (final game in json['games'] as List<dynamic>? ?? const [])
          PlayedGame.fromJson(game as Map<String, dynamic>),
      ];
    });
    final trophies = _section(() async {
      final json = await account.call('GET', 'users/${path(handle)}/trophies');
      if (json['private'] == true) return null;
      return [
        for (final trophy in json['trophies'] as List<dynamic>? ?? const [])
          EarnedTrophy.fromJson(trophy as Map<String, dynamic>),
      ];
    });
    TogetherProfile profile;
    var detailsPrivate = false;
    try {
      profile = TogetherProfile.fromJson(await account.call('GET', 'users/${path(handle)}'));
    } on TogetherProblem catch (problem) {
      if (!isPrivate(problem) || card == null) rethrow;
      detailsPrivate = true;
      profile = TogetherProfile(
        userId: card.id,
        handle: card.handle,
        displayName: card.displayName,
        avatar: card.avatar,
      );
    }
    return ProfilePage(
      profile: profile,
      detailsPrivate: detailsPrivate,
      library: await library,
      trophies: await trophies,
    );
  }

  /// A section read: null from [read] or a refusal is private, anything else that fails is
  /// failed. Signing out on the way (a refused refresh) still throws.
  Future<Section<T>> _section<T>(Future<T?> Function() read) async {
    try {
      final value = await read();
      return value == null ? SectionPrivate<T>() : SectionShown<T>(value);
    } on TogetherProblem catch (problem) {
      if (isPrivate(problem)) return SectionPrivate<T>();
      if (problem.status == 401) rethrow;
      return SectionFailed<T>();
    } on Object {
      return SectionFailed<T>();
    }
  }
}
