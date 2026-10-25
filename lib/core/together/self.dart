import 'dart:async';

import 'account.dart';
import 'levels.dart';
import 'notifier.dart';
import 'socket.dart';

/// The signed-in user's own side of AnyTogether that the lists do not carry: their trophy level
/// and whether they appear offline. Read from /me when the socket is ready; `level.up` and
/// `presence.mode` keep it current, the second from the user's other devices.
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
  bool loaded = false;
  int _changing = 0;

  Future<void> refresh() async {
    final json = await account.call('GET', 'me');
    final profile = json['profile'];
    if (profile is Map<String, dynamic>) {
      // An older server leaves the level out: what was known stays.
      if (profile.containsKey('trophyLevel')) level = TrophyLevel.fromJson(profile['trophyLevel']);
      // Not while a change of ours is on its way: that answer decides.
      if (_changing == 0) appearOffline = profile['appearOffline'] == true;
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

  void clear() {
    level = null;
    appearOffline = false;
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
      case 'presence.mode':
        if (data['appearOffline'] is! bool) return;
        appearOffline = data['appearOffline'] as bool;
        notifyListeners();
    }
  }

  void dispose() => unawaited(_events.cancel());
}
