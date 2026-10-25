import 'dart:async';

import 'account.dart';
import 'levels.dart';
import 'notifier.dart';
import 'socket.dart';

/// The signed-in user's own side of AnyTogether that the lists do not carry: their trophy level,
/// whether they appear offline and whether they send read receipts. Read from /me when the socket
/// is ready; `level.up`, `presence.mode` and `messages.settings` keep it current, the last two
/// from the user's other devices.
class SelfProfile with Notifier {
  SelfProfile({required this.account, required this.socket}) {
    _events = socket.events.listen(_event);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final StreamSubscription<TogetherEvent> _events;

  /// A higher level was reached (the toast and its sound).
  void Function(LevelBadge level)? onLevelUp;

  /// null before it is read, on a server older than levels.
  TrophyLevel? level;

  /// Friends see this user as offline; everything else keeps working.
  bool appearOffline = false;

  /// Others see when this user has read their messages (and this user sees theirs); on unless
  /// turned off.
  bool readReceipts = true;
  bool loaded = false;
  int _changing = 0;
  int _changingReceipts = 0;

  Future<void> refresh() async {
    final json = await account.call('GET', 'me');
    final profile = json['profile'];
    if (profile is Map<String, dynamic>) {
      // An older server leaves the level out: what was known stays.
      if (profile.containsKey('trophyLevel')) level = TrophyLevel.fromJson(profile['trophyLevel']);
      // Not while a change of ours is on its way: that answer decides.
      if (_changing == 0) appearOffline = profile['appearOffline'] == true;
      if (_changingReceipts == 0) readReceipts = profile['readReceipts'] != false;
    }
    loaded = true;
    notifyListeners();
  }

  /// Appear offline, or online again: shown at once, turned back (and thrown) when the server
  /// says no or does not have it yet (404).
  Future<void> setAppearOffline(bool on) async {
    final before = appearOffline;
    appearOffline = on;
    _changing++;
    notifyListeners();
    try {
      final answer = await account.call('PATCH', 'me/presence', {'appearOffline': on});
      if (answer['appearOffline'] is bool) appearOffline = answer['appearOffline'] as bool;
    } on Object {
      appearOffline = before;
      rethrow;
    } finally {
      _changing--;
      notifyListeners();
    }
  }

  /// Read receipts on or off: shown at once, turned back (and thrown) when the server says no.
  Future<void> setReadReceipts(bool on) async {
    final before = readReceipts;
    readReceipts = on;
    _changingReceipts++;
    notifyListeners();
    try {
      final answer = await account.call('PATCH', 'me/read-receipts', {'readReceipts': on});
      if (answer['readReceipts'] is bool) readReceipts = answer['readReceipts'] as bool;
    } on Object {
      readReceipts = before;
      rethrow;
    } finally {
      _changingReceipts--;
      notifyListeners();
    }
  }

  void clear() {
    level = null;
    appearOffline = false;
    readReceipts = true;
    loaded = false;
    notifyListeners();
  }

  void _event(TogetherEvent event) {
    final data = event.json;
    switch (event.type) {
      case 'live.ready':
        unawaited(refresh().catchError((Object _) {}));
      case 'level.up' when data['userId'] == account.user?.id:
        final badge = LevelBadge.fromJson(data);
        if (badge == null) return;
        final higher = level == null || badge.level > level!.level;
        level = TrophyLevel.reached(badge, points: level?.points ?? 0);
        notifyListeners();
        if (higher) onLevelUp?.call(badge);
        // The points and the way to the next level.
        unawaited(refresh().catchError((Object _) {}));
      case 'messages.settings':
        if (data['readReceipts'] is! bool) return;
        readReceipts = data['readReceipts'] as bool;
        notifyListeners();
      case 'presence.mode':
        if (data['appearOffline'] is! bool) return;
        appearOffline = data['appearOffline'] as bool;
        notifyListeners();
    }
  }

  void dispose() => unawaited(_events.cancel());
}
