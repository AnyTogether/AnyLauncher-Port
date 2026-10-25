import 'family_rules.dart';

/// The child's clock as a UTC offset. The server works the day out on the parent's chosen IANA
/// zone; this launcher has no time zone database, so it takes the computer's own clock (which
/// follows daylight saving by itself) whenever it agrees with what the server said, and the
/// server's word otherwise:
///
/// 1. the server sent `today.utcOffsetMinutes`: the computer's clock when it had the same offset
///    when the status was issued (the same zone, so its later changes are followed), else the
///    server's offset as it is;
/// 2. only `today.date`: the computer's clock when it gave the same date when the status was
///    issued, else the offset nearest to the computer's that does (whole quarter hours);
/// 3. nothing from the server: the computer's clock.
abstract final class ChildClock {
  static Duration systemOffset(DateTime at) => at.toLocal().timeZoneOffset;

  static Duration offset({
    required DateTime now,
    DateTime? issuedAt,
    String? serverDate,
    int? serverOffsetMinutes,
    Duration Function(DateTime at) localOffset = systemOffset,
  }) {
    final here = localOffset(now);
    if (issuedAt == null) return here;
    final then = localOffset(issuedAt);
    if (serverOffsetMinutes != null) {
      return then.inMinutes == serverOffsetMinutes ? here : Duration(minutes: serverOffsetMinutes);
    }
    final midnight = serverDate == null ? null : DateTime.tryParse('${serverDate}T00:00:00Z');
    if (midnight == null) return here;
    // The offsets that put the issuing instant on the server's date: [midnight - issued, +24 h).
    final low = midnight.difference(issuedAt.toUtc());
    final high = low + const Duration(hours: 24) - const Duration(seconds: 1);
    if (then >= low && then <= high) return here;
    const quarter = 15;
    final lowest = _max(low, const Duration(hours: -12)).inSeconds;
    final highest = _min(high, const Duration(hours: 14)).inSeconds;
    final up = (lowest / (quarter * 60)).ceil() * quarter;
    final down = (highest / (quarter * 60)).floor() * quarter;
    if (up > down) return then;
    return Duration(minutes: then.inMinutes.clamp(up, down));
  }

  static Duration _max(Duration a, Duration b) => a > b ? a : b;
  static Duration _min(Duration a, Duration b) => a < b ? a : b;
}

/// A game played on this computer: when, and whether it went to AnyTogether's outbox (a game
/// played signed out never reaches the server's count).
class PlaySpan {
  const PlaySpan(this.start, this.end, {this.reported = true});

  final DateTime start;
  final DateTime end;
  final bool reported;

  /// How long is kept: enough for today on any clock.
  static const kept = Duration(days: 2);

  /// The spans still worth keeping at [now].
  static List<PlaySpan> prune(List<PlaySpan> spans, DateTime now) => [
    for (final span in spans)
      if (span.end.isAfter(now.subtract(kept))) span,
  ];

  /// The seconds of this span between [from] and [to].
  int secondsWithin(DateTime from, DateTime to) {
    final start = this.start.isAfter(from) ? this.start : from;
    final end = this.end.isBefore(to) ? this.end : to;
    return end.isAfter(start) ? end.difference(start).inSeconds : 0;
  }

  Map<String, Object?> toJson() => {
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'reported': reported,
  };

  static PlaySpan? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final start = json['start'] is String ? DateTime.tryParse(json['start'] as String) : null;
    final end = json['end'] is String ? DateTime.tryParse(json['end'] as String) : null;
    if (start == null || end == null) return null;
    return PlaySpan(start.toUtc(), end.toUtc(), reported: json['reported'] != false);
  }
}

/// The family status the launcher applies, with the play on this computer since it was issued.
class FamilyPolicy {
  FamilyPolicy(this.status, {this.plays = const [], Duration Function(DateTime at)? localOffset})
    : localOffset = localOffset ?? ChildClock.systemOffset;

  final FamilyStatus status;
  final List<PlaySpan> plays;
  final Duration Function(DateTime at) localOffset;

  /// A status older than this is still applied, with a note to connect and refresh it.
  static const staleAfter = Duration(days: 7);

  bool get restricted => status.restricted && status.restrictions != null;

  FamilyRestrictions? get restrictions => restricted ? status.restrictions : null;

  bool staleAt(DateTime now) => now.difference(status.issuedAt) > staleAfter;

  /// The child's clock at [now].
  Duration offsetAt(DateTime now) => ChildClock.offset(
    now: now,
    issuedAt: status.issuedAt,
    serverDate: status.today?.date,
    serverOffsetMinutes: status.today?.utcOffsetMinutes,
    localOffset: localOffset,
  );

  TitleVerdict verdict(String titleId, Map<String, int>? levels) {
    final rules = restrictions;
    return rules == null ? TitleVerdict.allowed : titleVerdict(rules, titleId, levels);
  }

  /// Today's allowance at [now], a game running since [runningSince] counted in: the server's
  /// seconds and extra time when its day is today, plus what was played here that it cannot know
  /// yet (ended after the status was issued, or never reported), plus the running game, all from
  /// the start of the child's day.
  Allowance allowanceAt(DateTime now, {DateTime? runningSince}) {
    final rules = restrictions;
    final offset = offsetAt(now);
    if (rules == null) {
      return allowance(PlayTime.defaults(), now: now, offset: offset, playedSeconds: 0, bonusMinutes: 0);
    }
    final clock = localClock(now, offset);
    final dayStart = DateTime.parse('${clock.date}T00:00:00Z').subtract(offset);
    final today = status.today;
    final sameDay = today != null && today.date == clock.date;
    var played = sameDay ? today.playedSeconds : 0;
    for (final span in plays) {
      if (span.reported && !span.end.isAfter(status.issuedAt)) continue;
      played += span.secondsWithin(dayStart, now);
    }
    if (runningSince != null) played += PlaySpan(runningSince, now).secondsWithin(dayStart, now);
    return allowance(
      rules.playTime,
      now: now,
      offset: offset,
      playedSeconds: played,
      bonusMinutes: sameDay ? today.bonusMinutes : 0,
    );
  }
}
