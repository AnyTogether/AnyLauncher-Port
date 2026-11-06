import 'levels.dart';
import 'profiles.dart';

/// The accents a profile may pick, as AnyTogether names them, and their colours.
const profileAccents = {
  'blue': '#4f94ff',
  'mint': '#5cebbd',
  'coral': '#ff8066',
  'violet': '#a885ff',
  'gold': '#ffcc5c',
  'white': '#f0f0f0',
};

String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;

/// "#rrggbb", else null.
String? _hex(Object? value) => value is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value) ? value : null;

/// A profile's cover: a preset the server draws, or a game's artwork; [url] is its picture.
class ProfileCover {
  const ProfileCover({required this.kind, required this.id, required this.url});

  static ProfileCover? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = _text(json['kind']);
    final id = _text(json['id']);
    final url = _text(json['url']);
    if (kind == null || id == null || url == null) return null;
    return ProfileCover(kind: kind, id: id, url: url);
  }

  /// preset or game.
  final String kind;

  /// The preset ("cosmic-ribbons"), or the game's title ID.
  final String id;
  final String url;
}

/// A Theme Hub theme: the one a profile wears, or one to choose from. Its four colours are
/// "#rrggbb" (null when the server sent none), its stills 1280x720 and 640x360.
class ProfileTheme {
  const ProfileTheme({
    required this.id,
    required this.name,
    this.deep,
    this.middle,
    this.bright,
    this.accent,
    this.preview,
    this.thumb,
    this.makerHandle,
    this.makerName,
  });

  /// null when [json] lacks an id or a name.
  static ProfileTheme? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    final name = _text(json['name']);
    if (id == null || name == null) return null;
    final colours = json['colors'] is Map ? json['colors'] as Map : const {};
    final maker = json['maker'] is Map ? json['maker'] as Map : const {};
    return ProfileTheme(
      id: id,
      name: name,
      deep: _hex(colours['deep']),
      middle: _hex(colours['middle']),
      bright: _hex(colours['bright']),
      accent: _hex(colours['accent']),
      preview: _text(json['preview']),
      thumb: _text(json['thumb']),
      makerHandle: _text(maker['handle']),
      makerName: _text(maker['displayName']),
    );
  }

  final String id;
  final String name;
  final String? deep;
  final String? middle;
  final String? bright;
  final String? accent;
  final String? preview;
  final String? thumb;
  final String? makerHandle;
  final String? makerName;
}

/// How a profile looks: its cover, accent and the theme it wears, each null when not chosen (or
/// on a server before them). Every client draws it by the same rule: [picture] behind the
/// header, [accentHex] for its highlights, and with a theme the header tinted from its deep
/// colour into its middle one.
class ProfileLook {
  const ProfileLook({this.cover, this.accent, this.theme});

  /// The look in a profile or a PATCH /me/look answer: what is missing or unknown is null.
  factory ProfileLook.fromJson(Map<String, dynamic> json) {
    final accent = json['accent'];
    return ProfileLook(
      cover: ProfileCover.fromJson(json['cover']),
      accent: profileAccents.containsKey(accent) ? accent as String : null,
      theme: ProfileTheme.fromJson(json['theme']),
    );
  }

  final ProfileCover? cover;

  /// One of [profileAccents]' names.
  final String? accent;
  final ProfileTheme? theme;

  /// The picture behind the header: the cover's, else the theme's still.
  String? get picture => cover?.url ?? theme?.preview;

  /// The accent's colour, else the theme's.
  String? get accentHex => profileAccents[accent] ?? theme?.accent;

  bool get empty => cover == null && accent == null && theme == null;
}

/// A trophy pinned: its game and its number in the game's set.
typedef TrophyPin = ({String titleId, int trophyId});

/// What the user pins to the top of their profile while choosing: up to [max] trophies and
/// games together, in the order pinned.
class ShowcasePins {
  const ShowcasePins({this.trophies = const [], this.games = const []});

  /// The pins of [showcase] (the user's own), cut to six with trophies first as the server
  /// shows them.
  factory ShowcasePins.of(Showcase? showcase) {
    final trophies = <TrophyPin>[
      for (final trophy in showcase?.trophies ?? const <EarnedTrophy>[])
        (titleId: trophy.titleId, trophyId: trophy.trophyId),
    ].take(max).toList();
    final games = <String>[for (final game in showcase?.games ?? const <PlayedGame>[]) game.titleId]
        .take(max - trophies.length)
        .toList();
    return ShowcasePins(trophies: trophies, games: games);
  }

  /// Six pins in all.
  static const max = 6;

  final List<TrophyPin> trophies;
  final List<String> games;

  int get count => trophies.length + games.length;
  bool get full => count >= max;

  bool hasTrophy(String titleId, int trophyId) =>
      trophies.any((pin) => pin.titleId == titleId && pin.trophyId == trophyId);

  bool hasGame(String titleId) => games.contains(titleId);

  /// The trophy pinned, or taken off when it was; null when pinning it would make seven.
  ShowcasePins? toggleTrophy(String titleId, int trophyId) {
    if (hasTrophy(titleId, trophyId)) {
      return ShowcasePins(
        trophies: [
          for (final pin in trophies)
            if (pin.titleId != titleId || pin.trophyId != trophyId) pin,
        ],
        games: games,
      );
    }
    if (full) return null;
    return ShowcasePins(trophies: [...trophies, (titleId: titleId, trophyId: trophyId)], games: games);
  }

  /// The game pinned, or taken off when it was; null when pinning it would make seven.
  ShowcasePins? toggleGame(String titleId) {
    if (hasGame(titleId)) {
      return ShowcasePins(
        trophies: trophies,
        games: [
          for (final id in games)
            if (id != titleId) id,
        ],
      );
    }
    if (full) return null;
    return ShowcasePins(trophies: trophies, games: [...games, titleId]);
  }

  /// PUT /me/showcase's body: always both lists, as the server counts the stored other one too.
  Map<String, dynamic> toJson() => {
    'trophies': [
      for (final pin in trophies) {'titleId': pin.titleId, 'trophyId': pin.trophyId},
    ],
    'games': [...games],
  };
}
