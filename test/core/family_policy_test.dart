import 'package:anyps5_desktop/core/family/family_policy.dart';
import 'package:anyps5_desktop/core/family/family_rules.dart';
import 'package:test/test.dart';

/// A child's status issued at [issuedAt] with [days] (every other day: any time, no limit).
FamilyStatus childStatus({
  required DateTime issuedAt,
  Map<String, Object?> days = const {},
  String? todayDate,
  String todayWeekday = 'mon',
  int played = 0,
  int bonus = 0,
  int? offsetMinutes,
  bool enabled = true,
  int? ageLimit,
}) => FamilyStatus.fromJson({
  'userId': 'u-kid',
  'restricted': true,
  'familyId': 'f-1',
  'role': 'child',
  'restrictions': {
    'ageLimit': ageLimit,
    'playTime': {
      'enabled': enabled,
      'timeZone': 'Europe/Istanbul',
      'whenLimitReached': 'close',
      'graceMinutes': 3,
      'notifyParents': true,
      'days': {
        for (final day in Weekday.values) day.name: {'limitMinutes': null, 'from': null, 'until': null},
        ...days,
      },
    },
  },
  'today': todayDate == null
      ? null
      : {
          'date': todayDate,
          'weekday': todayWeekday,
          'playedSeconds': played,
          'bonusMinutes': bonus,
          'utcOffsetMinutes': ?offsetMinutes,
        },
  'issuedAt': issuedAt.toUtc().toIso8601String(),
})!;

void main() {
  group('which clock the child\'s day is on', () {
    final issued = DateTime.utc(2026, 10, 26, 9); // 12:00 in Istanbul

    test('the computer\'s own clock when it agrees with the server\'s date', () {
      final offset = ChildClock.offset(
        now: issued.add(const Duration(hours: 5)),
        issuedAt: issued,
        serverDate: '2026-10-26',
        localOffset: (_) => const Duration(hours: 3),
      );
      expect(offset, const Duration(hours: 3));
    });

    test('the computer\'s clock follows a daylight saving change since the status', () {
      final offset = ChildClock.offset(
        now: DateTime.utc(2026, 10, 26, 9),
        issuedAt: DateTime.utc(2026, 10, 24, 9),
        serverDate: '2026-10-24',
        localOffset: (at) => at.isBefore(DateTime.utc(2026, 10, 25, 1)) ? const Duration(hours: 2) : Duration.zero,
        serverOffsetMinutes: 120,
      );
      expect(offset, Duration.zero);
    });

    test('the server\'s offset when the computer is on another zone', () {
      final offset = ChildClock.offset(
        now: issued,
        issuedAt: issued,
        serverDate: '2026-10-26',
        localOffset: (_) => const Duration(hours: -7),
        serverOffsetMinutes: 180,
      );
      expect(offset, const Duration(hours: 3));
    });

    test('without the server\'s offset, the nearest one that gives the server\'s date', () {
      // 22:00 UTC on the 25th is already the 26th on the child's clock: at least +2.
      final offset = ChildClock.offset(
        now: DateTime.utc(2026, 10, 25, 22),
        issuedAt: DateTime.utc(2026, 10, 25, 22),
        serverDate: '2026-10-26',
        localOffset: (_) => Duration.zero,
      );
      expect(offset, const Duration(hours: 2));
      // 02:00 UTC on the 26th is still the 25th: at most -2 h -15 min (whole quarters).
      final behind = ChildClock.offset(
        now: DateTime.utc(2026, 10, 26, 2),
        issuedAt: DateTime.utc(2026, 10, 26, 2),
        serverDate: '2026-10-25',
        localOffset: (_) => const Duration(hours: 3),
      );
      expect(behind, const Duration(hours: -2, minutes: -15));
    });

    test('nothing from the server: the computer\'s clock', () {
      expect(
        ChildClock.offset(now: issued, localOffset: (_) => const Duration(hours: 5, minutes: 30)),
        const Duration(hours: 5, minutes: 30),
      );
    });
  });

  group('how much the child has played today', () {
    // Monday 2026-10-26 on a UTC clock (the computer's too).
    final issued = DateTime.utc(2026, 10, 26, 12);
    final days = {
      'mon': {'limitMinutes': 60, 'from': null, 'until': null},
    };

    FamilyPolicy policy(FamilyStatus status, {List<PlaySpan> plays = const []}) =>
        FamilyPolicy(status, plays: plays, localOffset: (_) => Duration.zero);

    test('the server\'s seconds and extra time, on the server\'s day', () {
      final rules = policy(childStatus(issuedAt: issued, days: days, todayDate: '2026-10-26', played: 1200, bonus: 10));
      final today = rules.allowanceAt(issued.add(const Duration(minutes: 1)));
      expect(today.playedSeconds, 1200);
      expect(today.bonusMinutes, 10);
      expect(today.remainingSeconds, 70 * 60 - 1200);
    });

    test('a status from yesterday counts nothing played and no extra time today', () {
      final rules = policy(
        childStatus(
          issuedAt: issued.subtract(const Duration(days: 1)),
          days: days,
          todayDate: '2026-10-25',
          todayWeekday: 'sun',
          played: 3000,
          bonus: 30,
        ),
      );
      final today = rules.allowanceAt(issued);
      expect((today.playedSeconds, today.bonusMinutes, today.remainingSeconds), (0, 0, 3600));
    });

    test('plus play here since the status, and the game running, from the day\'s start', () {
      final rules = policy(
        childStatus(issuedAt: issued, days: days, todayDate: '2026-10-26', played: 600),
        plays: [
          // Before the status: the server has it.
          PlaySpan(DateTime.utc(2026, 10, 26, 10), DateTime.utc(2026, 10, 26, 10, 10)),
          // After it: not yet.
          PlaySpan(DateTime.utc(2026, 10, 26, 12, 5), DateTime.utc(2026, 10, 26, 12, 15)),
          // Played signed out, never reported: always counts.
          PlaySpan(DateTime.utc(2026, 10, 26, 8), DateTime.utc(2026, 10, 26, 8, 5), reported: false),
          // Signed out yesterday: not today.
          PlaySpan(DateTime.utc(2026, 10, 25, 8), DateTime.utc(2026, 10, 25, 9), reported: false),
        ],
      );
      final now = DateTime.utc(2026, 10, 26, 13);
      final today = rules.allowanceAt(now, runningSince: DateTime.utc(2026, 10, 26, 12, 50));
      expect(today.playedSeconds, 600 + 600 + 300 + 600);
      expect(rules.allowanceAt(now).playedSeconds, 600 + 600 + 300);
    });

    test('at midnight a new day starts from nothing, a running game counted from then', () {
      final rules = policy(childStatus(issuedAt: issued, days: days, todayDate: '2026-10-26', played: 3600));
      expect(rules.allowanceAt(DateTime.utc(2026, 10, 26, 23, 59)).allowed, isFalse);
      final tuesday = rules.allowanceAt(
        DateTime.utc(2026, 10, 27, 0, 10),
        runningSince: DateTime.utc(2026, 10, 26, 23, 30),
      );
      expect((tuesday.weekday, tuesday.playedSeconds, tuesday.allowed), (Weekday.tue, 600, true));
    });

    test('free accounts and play time switched off have no end', () {
      final free = FamilyPolicy(
        FamilyStatus.fromJson({'userId': 'u-mum', 'restricted': false, 'issuedAt': issued.toIso8601String()})!,
      );
      expect(free.restricted, isFalse);
      expect(free.allowanceAt(issued).allowed, isTrue);
      expect(free.allowanceAt(issued).remainingSeconds, isNull);
      expect(free.verdict('PPSA01234', {'default': 18}), TitleVerdict.allowed);
      final off = policy(childStatus(issuedAt: issued, days: days, enabled: false, todayDate: '2026-10-26'));
      expect(off.allowanceAt(issued).remainingSeconds, isNull);
    });

    test('age ratings follow the status', () {
      final rules = policy(childStatus(issuedAt: issued, ageLimit: 12));
      expect(rules.verdict('PPSA01234', {'default': 16}), TitleVerdict.age);
      expect(rules.verdict('PPSA01234', {'default': 7}), TitleVerdict.allowed);
    });

    test('older than a week is stale, still applied', () {
      final rules = policy(childStatus(issuedAt: issued, days: days, todayDate: '2026-10-26'));
      expect(rules.staleAt(issued.add(const Duration(days: 6))), isFalse);
      expect(rules.staleAt(issued.add(const Duration(days: 8))), isTrue);
    });
  });

  test('play spans keep two days and read back', () {
    final now = DateTime.utc(2026, 10, 26, 12);
    final spans = PlaySpan.prune([
      PlaySpan(now.subtract(const Duration(days: 3)), now.subtract(const Duration(days: 3, minutes: -5))),
      PlaySpan(now.subtract(const Duration(hours: 1)), now, reported: false),
    ], now);
    expect(spans, hasLength(1));
    final back = PlaySpan.fromJson(spans.single.toJson())!;
    expect((back.start, back.end, back.reported), (spans.single.start, now, false));
    expect(PlaySpan.fromJson({'start': 'x'}), isNull);
  });
}
