import 'account.dart';
import 'people.dart';
import 'social.dart';

/// Challenges on AnyTogether (packages/shared/src/challenges.ts): a time-boxed race on one game,
/// made on the website for friends, a community or everyone. The launcher shows them where the
/// leaderboards are, and lets the user join, leave and read the standings. Only what happened
/// between the start and the end counts; results are final an hour after the end.

/// What counts: trophy points, trophies earned, or seconds played in the window. [other] is a
/// word a later server added.
enum ChallengeMetric {
  points,
  trophies,
  time,
  other;

  static ChallengeMetric named(Object? name) => switch (name) {
    'points' => points,
    'trophies' => trophies,
    'time' => time,
    _ => other,
  };
}

/// Who it is for.
enum ChallengeAudience {
  friends,
  community,
  public,
  other;

  static ChallengeAudience named(Object? name) => switch (name) {
    'friends' => friends,
    'community' => community,
    'public' => public,
    _ => other,
  };
}

/// Not started, running, over (final once [Challenge.isFinal]), or called off.
enum ChallengeState {
  upcoming,
  active,
  ended,
  cancelled,
  other;

  static ChallengeState named(Object? name) => switch (name) {
    'upcoming' => upcoming,
    'active' => active,
    'ended' => ended,
    'cancelled' => cancelled,
    _ => other,
  };

  /// Still open to join or leave.
  bool get open => this == upcoming || this == active;
}

int _int(Object? value) => value is num ? value.toInt() : 0;

DateTime _time(Object? value) =>
    (value is String ? DateTime.tryParse(value) : null) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

Person? _person(Object? json) =>
    json is Map<String, dynamic> && json['userId'] is String && json['handle'] is String
        ? Person.fromJson({...json, 'displayName': json['displayName'] is String ? json['displayName'] : json['handle']})
        : null;

/// One place in a challenge. Ranks are shared on ties (1, 2, 2, 4).
class ChallengeStanding {
  const ChallengeStanding({required this.rank, this.user, required this.value, this.me = false});

  static ChallengeStanding? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    return ChallengeStanding(
      rank: _int(json['rank']),
      user: _person(json['user']),
      value: _int(json['value']),
      me: json['me'] == true,
    );
  }

  final int rank;

  /// Null for someone this user may not see (a block either way); their place still counts.
  final Person? user;

  /// Trophy points, trophies, or seconds played, as the challenge's metric says.
  final int value;

  /// The user's own row.
  final bool me;
}

/// The community a challenge is for.
class ChallengeCommunity {
  const ChallengeCommunity({required this.id, required this.name, this.icon, this.iconUrl});

  static ChallengeCommunity? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    return ChallengeCommunity(
      id: json['id'] as String,
      name: json['name'] is String ? json['name'] as String : '',
      icon: json['icon'] is String ? json['icon'] as String : null,
      iconUrl: json['iconUrl'] is String ? json['iconUrl'] as String : null,
    );
  }

  final String id;
  final String name;
  final String? icon;
  final String? iconUrl;
}

/// A challenge as the reader sees it (ChallengeView).
class Challenge {
  const Challenge({
    required this.id,
    required this.title,
    this.description,
    required this.game,
    required this.metric,
    required this.audience,
    this.community,
    this.creator,
    required this.startsAt,
    required this.endsAt,
    required this.state,
    this.isFinal = false,
    this.entrants = 0,
    this.joined = false,
    this.mine = false,
    this.canCancel = false,
    this.leader,
    this.myStanding,
    required this.createdAt,
  });

  /// Null for something that is not one; fields of a later server are left out.
  static Challenge? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String) return null;
    final mine = json['myStanding'];
    return Challenge(
      id: json['id'] as String,
      title: json['title'] is String ? json['title'] as String : '',
      description: json['description'] is String ? json['description'] as String : null,
      game: SocialGame.fromJson(json['game']) ?? const SocialGame(titleId: ''),
      metric: ChallengeMetric.named(json['metric']),
      audience: ChallengeAudience.named(json['audience']),
      community: ChallengeCommunity.fromJson(json['community']),
      creator: _person(json['creator']),
      startsAt: _time(json['startsAt']),
      endsAt: _time(json['endsAt']),
      state: ChallengeState.named(json['state']),
      isFinal: json['final'] == true,
      entrants: _int(json['entrants']),
      joined: json['joined'] == true,
      mine: json['mine'] == true,
      canCancel: json['canCancel'] == true,
      leader: ChallengeStanding.fromJson(json['leader']),
      myStanding: mine is Map ? (rank: _int(mine['rank']), value: _int(mine['value'])) : null,
      createdAt: _time(json['createdAt']),
    );
  }

  final String id;
  final String title;
  final String? description;
  final SocialGame game;
  final ChallengeMetric metric;
  final ChallengeAudience audience;
  final ChallengeCommunity? community;

  /// Who made it; null once their account is gone.
  final Person? creator;

  /// UTC; shown in the computer's time zone.
  final DateTime startsAt;
  final DateTime endsAt;
  final ChallengeState state;

  /// Over and past the grace hour: the standings will not change.
  final bool isFinal;
  final int entrants;
  final bool joined;

  /// The user made it (and may not leave it, only cancel it on the website).
  final bool mine;
  final bool canCancel;

  /// First place while it runs, the winner once over; null before the start or with no one
  /// above zero.
  final ChallengeStanding? leader;

  /// The user's place, once they joined and it started.
  final ({int rank, int value})? myStanding;
  final DateTime createdAt;
}

/// A challenge with its first rows and the user's neighbours past them.
class ChallengeDetail {
  const ChallengeDetail({
    required this.challenge,
    this.standings = const [],
    this.around = const [],
    required this.updatedAt,
  });

  static ChallengeDetail? fromJson(Object? json) {
    final challenge = Challenge.fromJson(json);
    if (challenge == null || json is! Map<String, dynamic>) return null;
    List<ChallengeStanding> rows(Object? list) => [
      if (list is List)
        for (final item in list) ?ChallengeStanding.fromJson(item),
    ];
    return ChallengeDetail(
      challenge: challenge,
      standings: rows(json['standings']),
      around: rows(json['around']),
      updatedAt: _time(json['updatedAt']),
    );
  }

  final Challenge challenge;
  final List<ChallengeStanding> standings;
  final List<ChallengeStanding> around;
  final DateTime updatedAt;
}

/// The challenge endpoints, signed in.
class Challenges {
  Challenges(this.account);

  final TogetherAccount account;

  /// Running and coming ones on a game the user may see, soonest first.
  Future<List<Challenge>> forGame(String titleId) => _list('challenges?titleId=${Uri.encodeQueryComponent(titleId)}');

  /// The user's own (joined or made): running and coming first, then the last 30 days' ended ones.
  Future<List<Challenge>> mine() => _list('me/challenges');

  Future<ChallengeDetail> detail(String id) async {
    final json = await account.call('GET', 'challenges/${Uri.encodeComponent(id)}');
    final detail = ChallengeDetail.fromJson(json);
    if (detail == null) throw const TogetherProblem(502, 'bad_answer', 'Unexpected answer');
    return detail;
  }

  Future<Challenge> join(String id) => _post(id, 'join');

  Future<Challenge> leave(String id) => _post(id, 'leave');

  Future<Challenge> _post(String id, String action) async {
    final json = await account.call('POST', 'challenges/${Uri.encodeComponent(id)}/$action', <String, dynamic>{});
    final challenge = Challenge.fromJson(json);
    if (challenge == null) throw const TogetherProblem(502, 'bad_answer', 'Unexpected answer');
    return challenge;
  }

  /// A server before challenges answers 404: none.
  Future<List<Challenge>> _list(String path) async {
    final Map<String, dynamic> page;
    try {
      page = await account.call('GET', path);
    } on TogetherProblem catch (problem) {
      if (problem.status == 404) return const [];
      rethrow;
    }
    final list = page['challenges'];
    return [
      if (list is List)
        for (final item in list) ?Challenge.fromJson(item),
    ];
  }
}
