/// AnyTogether's family rules as the launcher enforces them: what a child may do, read from
/// GET me/family/restrictions, and the policy over them. The server's packages/shared/src/family.ts,
/// rule for rule: [FamilyRestrictions.fromJson] is restrictionsOf, [titleVerdict] and [allowance]
/// are the same functions. Only the clock differs: Dart has no time zone database here, so the
/// child's clock is a UTC offset (see ChildClock in family_policy.dart).
library;

/// The days of the week as the server names them, Monday first (DateTime.weekday - 1).
enum Weekday {
  mon,
  tue,
  wed,
  thu,
  fri,
  sat,
  sun;

  static Weekday of(DateTime date) => values[date.weekday - 1];

  static Weekday? byName(Object? name) => values.where((day) => day.name == name).firstOrNull;
}

/// Who may send the child friend requests, and whom the child may ask.
enum FriendRequestRule {
  everyone('everyone'),
  friendsOfFriends('friends_of_friends'),
  approved('approved'),
  nobody('nobody');

  const FriendRequestRule(this.wire);
  final String wire;
}

/// Whom the child may message and call (family members always).
enum MessageRule { friends, approved, nobody }

/// What happens when the time is up: a notice only, or the game closes after the grace period.
enum LimitAction { notify, close }

/// A game whose rating is unknown.
enum UnknownAge { allow, block }

/// Whether the child may play a game.
enum TitleVerdict { allowed, age, unknown }

/// Why the child may not play now.
enum AllowanceReason { limit, window }

final _clock = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');
final _region = RegExp(r'^([A-Z]{2}|default)$');
final _titleId = RegExp(r'^[A-Z]{4}[0-9]{5}$');
final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// "07:30" as minutes of the day.
int clockMinutes(String value) => int.parse(value.substring(0, 2)) * 60 + int.parse(value.substring(3, 5));

/// A whole number (JSON's 30.0 too) within [min]..[max], else null.
int? _int(Object? value, int min, int max) {
  if (value is! num || value != value.truncate()) return null;
  final whole = value.toInt();
  return whole < min || whole > max ? null : whole;
}

T? _enum<T extends Enum>(List<T> values, Object? name) => values.where((value) => value.name == name).firstOrNull;

/// Is [json] a valid nullable field: present, and null or what [read] accepts? (zod's .nullable()
/// refuses a missing key.)
bool _nullable(Map<String, dynamic> json, String key, bool Function(Object value) read) =>
    json.containsKey(key) && (json[key] == null || read(json[key] as Object));

/// One day of the week: how long the child may play (null: no limit) and between which times
/// (null: any time).
class DayPlan {
  const DayPlan({this.limitMinutes, this.from, this.until});

  static const any = DayPlan();

  final int? limitMinutes;
  final String? from;
  final String? until;

  /// The day as the server keeps it, or null when it is not a valid one.
  static DayPlan? parse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    if (!_nullable(json, 'limitMinutes', (value) => _int(value, 0, 1440) != null)) return null;
    bool clock(Object value) => value is String && _clock.hasMatch(value);
    if (!_nullable(json, 'from', clock) || !_nullable(json, 'until', clock)) return null;
    final from = json['from'] as String?;
    final until = json['until'] as String?;
    if ((from == null) != (until == null)) return null;
    if (from != null && until != null && clockMinutes(until) <= clockMinutes(from)) return null;
    final limit = json['limitMinutes'];
    return DayPlan(limitMinutes: limit == null ? null : _int(limit, 0, 1440), from: from, until: until);
  }

  @override
  bool operator ==(Object other) =>
      other is DayPlan && other.limitMinutes == limitMinutes && other.from == from && other.until == until;

  @override
  int get hashCode => Object.hash(limitMinutes, from, until);

  @override
  String toString() => 'DayPlan($limitMinutes, $from-$until)';
}

/// When and how long the child may play.
class PlayTime {
  const PlayTime({
    required this.enabled,
    required this.days,
    required this.timeZone,
    required this.whenLimitReached,
    required this.graceMinutes,
    required this.notifyParents,
  });

  factory PlayTime.defaults([String timeZone = 'UTC']) => PlayTime(
    enabled: false,
    days: {for (final day in Weekday.values) day: DayPlan.any},
    timeZone: timeZone,
    whenLimitReached: LimitAction.close,
    graceMinutes: 3,
    notifyParents: true,
  );

  /// Field by field over the defaults, each day on its own.
  factory PlayTime.fromJson(Object? json) {
    final time = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    final zone = time['timeZone'];
    final base = PlayTime.defaults(zone is String && zone.isNotEmpty && zone.length <= 64 ? zone : 'UTC');
    final days = time['days'] is Map<String, dynamic> ? time['days'] as Map<String, dynamic> : const {};
    return PlayTime(
      enabled: time['enabled'] is bool ? time['enabled'] as bool : base.enabled,
      days: {for (final day in Weekday.values) day: DayPlan.parse(days[day.name]) ?? DayPlan.any},
      timeZone: base.timeZone,
      whenLimitReached: _enum(LimitAction.values, time['whenLimitReached']) ?? base.whenLimitReached,
      graceMinutes: _int(time['graceMinutes'], 0, 30) ?? base.graceMinutes,
      notifyParents: time['notifyParents'] is bool ? time['notifyParents'] as bool : base.notifyParents,
    );
  }

  final bool enabled;
  final Map<Weekday, DayPlan> days;

  /// The child's clock (an IANA name); the launcher uses the offset the server and the computer
  /// agree on for it.
  final String timeZone;
  final LimitAction whenLimitReached;

  /// Minutes between the big notice and the game closing, to save.
  final int graceMinutes;
  final bool notifyParents;
}

/// What a child may do.
class FamilyRestrictions {
  const FamilyRestrictions({
    required this.friendRequests,
    required this.messages,
    required this.voiceChat,
    required this.sharePlay,
    required this.publicMatchmaking,
    required this.profileVisibility,
    required this.discovery,
    required this.communities,
    required this.mediaSharing,
    required this.ageLimit,
    required this.unknownAge,
    required this.ageRegion,
    required this.allowedTitles,
    required this.approvedContacts,
    required this.playTime,
  });

  /// A new child's limits: careful, the parent opens up what they want.
  factory FamilyRestrictions.defaults([String timeZone = 'UTC']) => FamilyRestrictions(
    friendRequests: FriendRequestRule.approved,
    messages: MessageRule.friends,
    voiceChat: false,
    sharePlay: false,
    publicMatchmaking: false,
    profileVisibility: 'friends',
    discovery: false,
    communities: false,
    mediaSharing: false,
    ageLimit: null,
    unknownAge: UnknownAge.allow,
    ageRegion: 'default',
    allowedTitles: const [],
    approvedContacts: const [],
    playTime: PlayTime.defaults(timeZone),
  );

  /// The stored limits over the defaults; anything unknown or invalid falls back to the default.
  factory FamilyRestrictions.fromJson(Object? json) {
    final saved = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    final playTime = PlayTime.fromJson(saved['playTime']);
    final base = FamilyRestrictions.defaults(playTime.timeZone);
    bool? flag(String key) => saved[key] is bool ? saved[key] as bool : null;
    List<String>? list(String key, RegExp pattern, int max) {
      final value = saved[key];
      if (value is! List || value.length > max) return null;
      if (!value.every((item) => item is String && pattern.hasMatch(item))) return null;
      return List.unmodifiable(value.cast<String>());
    }

    final region = saved['ageRegion'];
    return FamilyRestrictions(
      friendRequests:
          FriendRequestRule.values.where((rule) => rule.wire == saved['friendRequests']).firstOrNull ??
          base.friendRequests,
      messages: _enum(MessageRule.values, saved['messages']) ?? base.messages,
      voiceChat: flag('voiceChat') ?? base.voiceChat,
      sharePlay: flag('sharePlay') ?? base.sharePlay,
      publicMatchmaking: flag('publicMatchmaking') ?? base.publicMatchmaking,
      profileVisibility: const {'friends', 'nobody'}.contains(saved['profileVisibility'])
          ? saved['profileVisibility'] as String
          : base.profileVisibility,
      discovery: flag('discovery') ?? base.discovery,
      communities: flag('communities') ?? base.communities,
      mediaSharing: flag('mediaSharing') ?? base.mediaSharing,
      ageLimit: _nullable(saved, 'ageLimit', (value) => _int(value, 0, 99) != null)
          ? (saved['ageLimit'] == null ? null : _int(saved['ageLimit'], 0, 99))
          : base.ageLimit,
      unknownAge: _enum(UnknownAge.values, saved['unknownAge']) ?? base.unknownAge,
      ageRegion: region is String && _region.hasMatch(region) ? region : base.ageRegion,
      allowedTitles: list('allowedTitles', _titleId, 500) ?? base.allowedTitles,
      approvedContacts: list('approvedContacts', _uuid, 200) ?? base.approvedContacts,
      playTime: playTime,
    );
  }

  final FriendRequestRule friendRequests;
  final MessageRule messages;
  final bool voiceChat;

  /// Share play: hosting and watching.
  final bool sharePlay;

  /// Public parties, the looking-for-group board and public share plays.
  final bool publicMatchmaking;

  /// friends or nobody: the most any part of the profile may show.
  final String profileVisibility;
  final bool discovery;
  final bool communities;
  final bool mediaSharing;

  /// The highest age rating the child may play; null: any.
  final int? ageLimit;
  final UnknownAge unknownAge;

  /// Which region's rating counts ("TR", "US"); "default" is the game's own default.
  final String ageRegion;

  /// Games a parent allowed whatever their rating.
  final List<String> allowedTitles;
  final List<String> approvedContacts;
  final PlayTime playTime;
}

/// A game's age ratings as sce_sys/param.json's `ageLevel` has them and the server takes them:
/// "default" or a two-letter region, to a whole age.
abstract final class AgeLevels {
  /// The valid entries of [json]; null when there are none.
  static Map<String, int>? parse(Object? json) {
    if (json is! Map) return null;
    final levels = <String, int>{
      for (final entry in json.entries)
        if (entry.key is String && _region.hasMatch(entry.key as String) && _int(entry.value, 0, 99) != null)
          entry.key as String: _int(entry.value, 0, 99)!,
    };
    return levels.isEmpty || levels.length > 120 ? null : levels;
  }
}

/// The rating that counts for a region: the region's own, else the game's default; null when the
/// game has none.
int? ageLevelFor(Map<String, int>? levels, String region) {
  if (levels == null) return null;
  final own = region != 'default' ? levels[region] : null;
  return own ?? levels['default'];
}

/// Whether the child may play a game: allowed, too old a rating, or an unknown rating blocked.
TitleVerdict titleVerdict(FamilyRestrictions rules, String titleId, Map<String, int>? levels) {
  if (rules.allowedTitles.contains(titleId) || rules.ageLimit == null) return TitleVerdict.allowed;
  final level = ageLevelFor(levels, rules.ageRegion);
  if (level == null) return rules.unknownAge == UnknownAge.allow ? TitleVerdict.allowed : TitleVerdict.unknown;
  return level <= rules.ageLimit! ? TitleVerdict.allowed : TitleVerdict.age;
}

/// The date, weekday and minute of the day on a clock [offset] from UTC.
class ClockReading {
  const ClockReading(this.date, this.weekday, this.minutes, this.seconds);

  /// 2026-10-26
  final String date;
  final Weekday weekday;
  final int minutes;
  final int seconds;
}

ClockReading localClock(DateTime now, Duration offset) {
  final local = now.toUtc().add(offset);
  String two(int value) => value.toString().padLeft(2, '0');
  return ClockReading(
    '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}',
    Weekday.of(local),
    local.hour * 60 + local.minute,
    local.hour * 3600 + local.minute * 60 + local.second,
  );
}

/// How much the child may still play today.
class Allowance {
  const Allowance({
    required this.date,
    required this.weekday,
    required this.limitMinutes,
    required this.bonusMinutes,
    required this.playedSeconds,
    required this.from,
    required this.until,
    required this.remainingSeconds,
    required this.allowed,
    required this.reason,
    this.utcOffsetMinutes,
  });

  /// The server's `today` block; null without a date and weekday.
  static Allowance? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final date = json['date'];
    final weekday = Weekday.byName(json['weekday']);
    if (date is! String || weekday == null) return null;
    final allowed = json['allowed'];
    return Allowance(
      date: date,
      weekday: weekday,
      limitMinutes: _int(json['limitMinutes'], 0, 1 << 20),
      bonusMinutes: _int(json['bonusMinutes'], 0, 1 << 20) ?? 0,
      playedSeconds: _int(json['playedSeconds'], 0, 1 << 30) ?? 0,
      from: json['from'] is String ? json['from'] as String : null,
      until: json['until'] is String ? json['until'] as String : null,
      remainingSeconds: _int(json['remainingSeconds'], 0, 1 << 30),
      allowed: allowed is bool ? allowed : true,
      reason: _enum(AllowanceReason.values, json['reason']),
      utcOffsetMinutes: _int(json['utcOffsetMinutes'], -14 * 60, 14 * 60),
    );
  }

  final String date;
  final Weekday weekday;

  /// Today's limit with extra time granted today; null: no limit.
  final int? limitMinutes;
  final int bonusMinutes;
  final int playedSeconds;
  final String? from;
  final String? until;

  /// Seconds left before the limit or the window's end, whichever comes first; null: no end.
  final int? remainingSeconds;
  final bool allowed;
  final AllowanceReason? reason;

  /// The child's clock at the time the server worked this out, when it says (not in the TS type
  /// yet; read when present).
  final int? utcOffsetMinutes;
}

/// How much the child may still play today, on a clock [offset] from UTC.
Allowance allowance(
  PlayTime playTime, {
  required DateTime now,
  required Duration offset,
  required int playedSeconds,
  required int bonusMinutes,
}) {
  final clock = localClock(now, offset);
  final day = playTime.days[clock.weekday] ?? DayPlan.any;
  if (!playTime.enabled) {
    return Allowance(
      date: clock.date,
      weekday: clock.weekday,
      limitMinutes: null,
      bonusMinutes: bonusMinutes,
      playedSeconds: playedSeconds,
      from: null,
      until: null,
      remainingSeconds: null,
      allowed: true,
      reason: null,
    );
  }
  final limitMinutes = day.limitMinutes == null ? null : day.limitMinutes! + bonusMinutes;
  final left = limitMinutes == null ? null : (limitMinutes * 60 - playedSeconds).clamp(0, 1 << 31);
  int? windowLeft;
  var inWindow = true;
  if (day.from != null && day.until != null) {
    final from = clockMinutes(day.from!) * 60;
    final until = clockMinutes(day.until!) * 60;
    inWindow = clock.seconds >= from && clock.seconds < until;
    windowLeft = inWindow ? until - clock.seconds : 0;
  }
  final remaining = left == null
      ? windowLeft
      : windowLeft == null
      ? left
      : (left < windowLeft ? left : windowLeft);
  final reason = !inWindow
      ? AllowanceReason.window
      : left != null && left <= 0
      ? AllowanceReason.limit
      : null;
  return Allowance(
    date: clock.date,
    weekday: clock.weekday,
    limitMinutes: limitMinutes,
    bonusMinutes: bonusMinutes,
    playedSeconds: playedSeconds,
    from: day.from,
    until: day.until,
    remainingSeconds: remaining,
    allowed: reason == null,
    reason: reason,
  );
}

/// What GET me/family/restrictions answers (and signs): whether any limit applies, the limits
/// and today on the child's clock.
class FamilyStatus {
  const FamilyStatus({
    required this.userId,
    required this.restricted,
    required this.familyId,
    required this.role,
    required this.restrictions,
    required this.today,
    required this.issuedAt,
  });

  /// null without a user and a time it was issued. A restricted status always has limits: the
  /// careful defaults when they are missing.
  static FamilyStatus? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final userId = json['userId'];
    final issuedAt = json['issuedAt'] is String ? DateTime.tryParse(json['issuedAt'] as String) : null;
    if (userId is! String || userId.isEmpty || issuedAt == null) return null;
    final restricted = json['restricted'] == true;
    return FamilyStatus(
      userId: userId,
      restricted: restricted,
      familyId: json['familyId'] is String ? json['familyId'] as String : null,
      role: json['role'] is String ? json['role'] as String : null,
      restrictions: restricted ? FamilyRestrictions.fromJson(json['restrictions']) : null,
      today: restricted ? Allowance.fromJson(json['today']) : null,
      issuedAt: issuedAt.toUtc(),
    );
  }

  final String userId;
  final bool restricted;
  final String? familyId;

  /// manager, parent, adult or child.
  final String? role;
  final FamilyRestrictions? restrictions;
  final Allowance? today;
  final DateTime issuedAt;
}
