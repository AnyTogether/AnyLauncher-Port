import 'package:anyps5_desktop/core/family/family_rules.dart';
import 'package:test/test.dart';

/// A play-time block with [days] over every day's "any time, no limit".
Map<String, Object?> playTimeJson({
  bool enabled = true,
  Map<String, Object?> days = const {},
  String whenLimitReached = 'close',
  int graceMinutes = 3,
}) => {
  'enabled': enabled,
  'timeZone': 'Europe/Istanbul',
  'whenLimitReached': whenLimitReached,
  'graceMinutes': graceMinutes,
  'notifyParents': true,
  'days': {
    for (final day in Weekday.values) day.name: {'limitMinutes': null, 'from': null, 'until': null},
    ...days,
  },
};

void main() {
  group('restrictions', () {
    test('a new child is careful by default, like defaultRestrictions', () {
      final rules = FamilyRestrictions.defaults('Europe/Istanbul');
      expect(rules.friendRequests, FriendRequestRule.approved);
      expect(rules.messages, MessageRule.friends);
      expect(rules.voiceChat, isFalse);
      expect(rules.sharePlay, isFalse);
      expect(rules.publicMatchmaking, isFalse);
      expect(rules.profileVisibility, 'friends');
      expect(rules.discovery, isFalse);
      expect(rules.ageLimit, isNull);
      expect(rules.unknownAge, UnknownAge.allow);
      expect(rules.ageRegion, 'default');
      expect(rules.allowedTitles, isEmpty);
      expect(rules.playTime.enabled, isFalse);
      expect(rules.playTime.timeZone, 'Europe/Istanbul');
      expect(rules.playTime.whenLimitReached, LimitAction.close);
      expect(rules.playTime.graceMinutes, 3);
      expect(rules.playTime.notifyParents, isTrue);
      expect(rules.playTime.days.keys, Weekday.values);
      expect(rules.playTime.days.values.every((day) => day == DayPlan.any), isTrue);
    });

    test('read field by field: whatever is unknown or invalid falls back, like restrictionsOf', () {
      final rules = FamilyRestrictions.fromJson({
        'friendRequests': 'friends_of_friends',
        'messages': 'shouting',
        'voiceChat': true,
        'sharePlay': 'yes',
        'publicMatchmaking': true,
        'profileVisibility': 'nobody',
        'discovery': true,
        'ageLimit': 12,
        'unknownAge': 'block',
        'ageRegion': 'TR',
        'allowedTitles': ['PPSA01234', 'CUSA00001'],
        'approvedContacts': ['not-a-uuid'],
        'playTime': {
          'enabled': true,
          'timeZone': 'Europe/Berlin',
          'whenLimitReached': 'explode',
          'graceMinutes': 99,
          'notifyParents': false,
          'days': {
            'mon': {'limitMinutes': 60, 'from': '08:00', 'until': '20:30'},
            'tue': {'limitMinutes': 30, 'from': '20:00', 'until': '08:00'},
            'wed': {'limitMinutes': 45.0, 'from': null, 'until': null},
            'thu': {'limitMinutes': 30, 'from': '10:00', 'until': null},
            'fri': {'limitMinutes': 2000, 'from': null, 'until': null},
            'sat': {'from': null, 'until': null},
          },
        },
        'surprise': 1,
      });
      expect(rules.friendRequests, FriendRequestRule.friendsOfFriends);
      expect(rules.messages, MessageRule.friends);
      expect(rules.voiceChat, isTrue);
      expect(rules.sharePlay, isFalse);
      expect(rules.publicMatchmaking, isTrue);
      expect(rules.profileVisibility, 'nobody');
      expect(rules.discovery, isTrue);
      expect(rules.ageLimit, 12);
      expect(rules.unknownAge, UnknownAge.block);
      expect(rules.ageRegion, 'TR');
      expect(rules.allowedTitles, ['PPSA01234', 'CUSA00001']);
      expect(rules.approvedContacts, isEmpty);
      final time = rules.playTime;
      expect(time.enabled, isTrue);
      expect(time.timeZone, 'Europe/Berlin');
      expect(time.whenLimitReached, LimitAction.close);
      expect(time.graceMinutes, 3);
      expect(time.notifyParents, isFalse);
      expect(time.days[Weekday.mon], const DayPlan(limitMinutes: 60, from: '08:00', until: '20:30'));
      // until before from, one bound only, a limit over a day, a missing limit: any time, no limit.
      expect(time.days[Weekday.tue], DayPlan.any);
      expect(time.days[Weekday.wed], const DayPlan(limitMinutes: 45));
      expect(time.days[Weekday.thu], DayPlan.any);
      expect(time.days[Weekday.fri], DayPlan.any);
      expect(time.days[Weekday.sat], DayPlan.any);
      expect(time.days[Weekday.sun], DayPlan.any);
    });

    test('a null age limit is "any", and nothing at all is the defaults', () {
      expect(FamilyRestrictions.fromJson({'ageLimit': null, 'ageRegion': 'tr'}).ageRegion, 'default');
      expect(FamilyRestrictions.fromJson({'ageLimit': 120}).ageLimit, isNull);
      expect(FamilyRestrictions.fromJson(null).friendRequests, FriendRequestRule.approved);
      expect(FamilyRestrictions.fromJson('nonsense').playTime.timeZone, 'UTC');
    });
  });

  group('age ratings', () {
    const levels = {'default': 16, 'US': 13, 'DE': 12};

    test('the region\'s own rating, else the game\'s default, else none', () {
      expect(ageLevelFor(levels, 'US'), 13);
      expect(ageLevelFor(levels, 'TR'), 16);
      expect(ageLevelFor(levels, 'default'), 16);
      expect(ageLevelFor({'US': 13}, 'TR'), isNull);
      expect(ageLevelFor(null, 'US'), isNull);
    });

    FamilyRestrictions rules({
      int? limit,
      String unknown = 'allow',
      String region = 'default',
      List<String>? allowed,
    }) => FamilyRestrictions.fromJson({
      'ageLimit': limit,
      'unknownAge': unknown,
      'ageRegion': region,
      'allowedTitles': allowed ?? <String>[],
    });

    test('titleVerdict: allowed, too old a rating, or an unknown rating blocked', () {
      expect(titleVerdict(rules(), 'PPSA01234', levels), TitleVerdict.allowed);
      expect(titleVerdict(rules(limit: 12), 'PPSA01234', levels), TitleVerdict.age);
      expect(titleVerdict(rules(limit: 12, region: 'DE'), 'PPSA01234', levels), TitleVerdict.allowed);
      expect(titleVerdict(rules(limit: 16), 'PPSA01234', levels), TitleVerdict.allowed);
      expect(titleVerdict(rules(limit: 12, allowed: ['PPSA01234']), 'PPSA01234', levels), TitleVerdict.allowed);
      expect(titleVerdict(rules(limit: 12), 'PPSA01234', null), TitleVerdict.allowed);
      expect(titleVerdict(rules(limit: 12, unknown: 'block'), 'PPSA01234', null), TitleVerdict.unknown);
      expect(titleVerdict(rules(limit: 12, unknown: 'block'), 'PPSA01234', {'US': 3}), TitleVerdict.unknown);
      expect(titleVerdict(rules(unknown: 'block'), 'PPSA01234', null), TitleVerdict.allowed);
    });

    test('param.json\'s ageLevel read as the server takes it', () {
      expect(AgeLevels.parse({'default': 16, 'US': 13, 'de': 3, 'XX1': 2, 'FR': 'old', 'JP': 120}), {
        'default': 16,
        'US': 13,
      });
      expect(AgeLevels.parse({'default': 7.0}), {'default': 7});
      expect(AgeLevels.parse({}), isNull);
      expect(AgeLevels.parse('16'), isNull);
    });
  });

  group('the child\'s clock', () {
    test('date, weekday, minute and second of the day at an offset', () {
      final now = DateTime.utc(2026, 10, 25, 21, 30, 15); // a Sunday
      final utc = localClock(now, Duration.zero);
      expect((utc.date, utc.weekday, utc.minutes, utc.seconds), ('2026-10-25', Weekday.sun, 21 * 60 + 30, 77415));
      final istanbul = localClock(now, const Duration(hours: 3));
      expect((istanbul.date, istanbul.weekday, istanbul.minutes), ('2026-10-26', Weekday.mon, 30));
      final newYork = localClock(now, const Duration(hours: -4));
      expect((newYork.date, newYork.weekday), ('2026-10-25', Weekday.sun));
      expect(localClock(DateTime(2026, 1, 1, 12).toUtc(), Duration.zero).date, startsWith('20'));
    });
  });

  group('allowance, as the TypeScript one', () {
    // Monday 2026-10-26, 15:00 on a UTC clock.
    final monday = DateTime.utc(2026, 10, 26, 15);

    Allowance at(
      DateTime now, {
      Map<String, Object?> days = const {},
      bool enabled = true,
      int played = 0,
      int bonus = 0,
    }) => allowance(
      PlayTime.fromJson(playTimeJson(enabled: enabled, days: days)),
      now: now,
      offset: Duration.zero,
      playedSeconds: played,
      bonusMinutes: bonus,
    );

    test('play time off: no limit, any time', () {
      final today = at(
        monday,
        enabled: false,
        days: {
          'mon': {'limitMinutes': 0, 'from': null, 'until': null},
        },
      );
      expect(today.allowed, isTrue);
      expect(today.limitMinutes, isNull);
      expect(today.remainingSeconds, isNull);
      expect(today.from, isNull);
      expect(today.reason, isNull);
      expect((today.date, today.weekday), ('2026-10-26', Weekday.mon));
    });

    test('a daily limit with the extra time granted today', () {
      final days = {
        'mon': {'limitMinutes': 60, 'from': null, 'until': null},
      };
      expect(at(monday, days: days, played: 600).remainingSeconds, 3000);
      final bonus = at(monday, days: days, played: 3600, bonus: 15);
      expect(bonus.limitMinutes, 75);
      expect(bonus.bonusMinutes, 15);
      expect(bonus.remainingSeconds, 900);
      expect(bonus.allowed, isTrue);
      final spent = at(monday, days: days, played: 4000);
      expect(spent.remainingSeconds, 0);
      expect(spent.allowed, isFalse);
      expect(spent.reason, AllowanceReason.limit);
      // Only today's plan counts: Tuesday has no limit.
      expect(at(monday.add(const Duration(days: 1)), days: days, played: 99999).allowed, isTrue);
    });

    test('a window: before, inside and after; the earlier end wins', () {
      final days = {
        'mon': {'limitMinutes': 120, 'from': '14:00', 'until': '15:30'},
      };
      final inside = at(monday, days: days, played: 0);
      expect(inside.allowed, isTrue);
      expect(inside.remainingSeconds, 1800);
      expect((inside.from, inside.until), ('14:00', '15:30'));
      expect(at(monday, days: days, played: 7200 - 600).remainingSeconds, 600);
      final before = at(DateTime.utc(2026, 10, 26, 13, 59, 59), days: days);
      expect((before.allowed, before.reason, before.remainingSeconds), (false, AllowanceReason.window, 0));
      final after = at(DateTime.utc(2026, 10, 26, 15, 30), days: days);
      expect((after.allowed, after.reason), (false, AllowanceReason.window));
      // Out of the window with the limit spent too: the window is the reason.
      expect(at(DateTime.utc(2026, 10, 26, 16), days: days, played: 99999).reason, AllowanceReason.window);
      // A window without a limit.
      final open = at(
        monday,
        days: {
          'mon': {'limitMinutes': null, 'from': '14:00', 'until': '15:30'},
        },
      );
      expect((open.limitMinutes, open.remainingSeconds), (null, 1800));
    });

    test('the same instant on another clock is another day and another plan', () {
      final days = {
        'mon': {'limitMinutes': 0, 'from': null, 'until': null},
      };
      final sundayNight = DateTime.utc(2026, 10, 25, 22);
      final plan = PlayTime.fromJson(playTimeJson(days: days));
      expect(
        allowance(plan, now: sundayNight, offset: Duration.zero, playedSeconds: 0, bonusMinutes: 0).allowed,
        isTrue,
      );
      final istanbul = allowance(
        plan,
        now: sundayNight,
        offset: const Duration(hours: 3),
        playedSeconds: 0,
        bonusMinutes: 0,
      );
      expect((istanbul.weekday, istanbul.allowed), (Weekday.mon, false));
    });

    test('the server\'s today block reads back', () {
      final today = Allowance.fromJson({
        'date': '2026-10-26',
        'weekday': 'mon',
        'limitMinutes': 75,
        'bonusMinutes': 15,
        'playedSeconds': 1200,
        'from': '14:00',
        'until': '20:00',
        'remainingSeconds': 3300,
        'allowed': true,
        'reason': null,
        'utcOffsetMinutes': 180,
      })!;
      expect(today.date, '2026-10-26');
      expect(today.weekday, Weekday.mon);
      expect(today.bonusMinutes, 15);
      expect(today.playedSeconds, 1200);
      expect(today.utcOffsetMinutes, 180);
      expect(Allowance.fromJson({'weekday': 'mon'}), isNull);
      expect(Allowance.fromJson(null), isNull);
    });
  });

  group('status', () {
    test('a child\'s status and a free account\'s', () {
      final child = FamilyStatus.fromJson({
        'userId': 'u-kid',
        'restricted': true,
        'familyId': 'f-1',
        'role': 'child',
        'restrictions': {'ageLimit': 12},
        'today': {'date': '2026-10-26', 'weekday': 'mon', 'playedSeconds': 60, 'bonusMinutes': 0},
        'issuedAt': '2026-10-26T12:00:00.000Z',
      })!;
      expect(child.restricted, isTrue);
      expect(child.role, 'child');
      expect(child.restrictions!.ageLimit, 12);
      expect(child.today!.playedSeconds, 60);
      expect(child.issuedAt, DateTime.utc(2026, 10, 26, 12));
      final free = FamilyStatus.fromJson({
        'userId': 'u-mum',
        'restricted': false,
        'familyId': null,
        'role': null,
        'restrictions': null,
        'today': null,
        'issuedAt': '2026-10-26T12:00:00.000Z',
      })!;
      expect(free.restricted, isFalse);
      expect(free.restrictions, isNull);
      // A restricted status without its limits is the careful defaults, not "no limits".
      final bare = FamilyStatus.fromJson({
        'userId': 'u-kid',
        'restricted': true,
        'issuedAt': '2026-10-26T12:00:00.000Z',
      })!;
      expect(bare.restrictions!.voiceChat, isFalse);
      expect(FamilyStatus.fromJson({'restricted': true}), isNull);
    });
  });
}
