import 'dart:async';

import 'account.dart';
import 'levels.dart';
import 'notifier.dart';
import 'people.dart';
import 'profile_look.dart';
import 'socket.dart';

/// The signed-in user's own side of AnyTogether that the lists do not carry: their trophy level,
/// whether they appear offline and whether they send read receipts. Read from /me when the socket
/// is ready; `level.up`, `presence.mode` and `messages.settings` keep it current, the last two
/// from the user's other devices. /me's name, handle and picture replace the kept user's when
/// they changed on the website ([refreshIfOlder] reads it again now and then).
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

  /// What friends see: online, idle, do not disturb, or offline (invisible); everything else
  /// keeps working whichever it is.
  PresenceStatus status = PresenceStatus.online;

  /// Friends see this user as offline.
  bool get appearOffline => status == PresenceStatus.invisible;
  set appearOffline(bool on) => status = on ? PresenceStatus.invisible : PresenceStatus.online;

  /// Others see when this user has read their messages (and this user sees theirs); on unless
  /// turned off.
  bool readReceipts = true;
  bool loaded = false;

  /// The name and picture only accepted friends see (null when not set, or an older server);
  /// the picture is a signed link that runs out, read again with the profile.
  String? privateName;
  String? privateAvatar;

  /// The Theme Hub theme on the user's profile; null for none (or a server before them).
  ProfileTheme? wornTheme;
  int _changing = 0;
  int _changingReceipts = 0;

  /// When /me was last read, null before the first time.
  DateTime? readAt;
  Future<void>? _reading;

  /// Reads /me again unless it was read in the last [age] or a read is on its way: a name,
  /// handle or picture changed on the website shows here (the server sends no event for it).
  /// Never throws.
  Future<void> refreshIfOlder(Duration age, {DateTime? now}) {
    if (account.user == null) return Future.value();
    final reading = _reading;
    if (reading != null) return reading;
    final read = readAt;
    if (read != null && (now ?? DateTime.now()).difference(read) < age) return Future.value();
    return refresh().catchError((Object _) {});
  }

  Future<void> refresh() {
    final reading = _reading ??= _read();
    return reading.whenComplete(() {
      if (identical(_reading, reading)) _reading = null;
    });
  }

  Future<void> _read() async {
    final who = account.user?.id;
    final json = await account.call('GET', 'me');
    // Signed out or someone else signed in meanwhile: the answer is not theirs.
    if (account.user?.id != who) return;
    readAt = DateTime.now();
    final profile = json['profile'];
    if (profile is Map<String, dynamic>) {
      _adoptIdentity(profile);
      // An older server leaves the level out: what was known stays.
      if (profile.containsKey('trophyLevel')) level = TrophyLevel.fromJson(profile['trophyLevel']);
      // Not while a change of ours is on its way: that answer decides.
      if (_changing == 0) status = _statusIn(profile) ?? status;
      if (_changingReceipts == 0) readReceipts = profile['readReceipts'] != false;
      privateName = _text(profile['privateName']);
      privateAvatar = _text(profile['privateAvatar']);
      if (profile.containsKey('theme')) wornTheme = ProfileTheme.fromJson(profile['theme']);
    }
    loaded = true;
    notifyListeners();
  }

  /// The status in a profile or a `presence.mode` event: its `status`, else (a server before
  /// statuses) online or invisible from `appearOffline`; null when it has neither.
  static PresenceStatus? _statusIn(Map<String, dynamic> json) {
    if (PresenceStatus.parse(json['status']) case final status?) return status;
    if (json['appearOffline'] case final bool hidden) return hidden ? PresenceStatus.invisible : PresenceStatus.online;
    // A profile from a server before appear offline: online.
    return json.containsKey('status') ? null : PresenceStatus.online;
  }

  /// Appear offline, or online again.
  Future<void> setAppearOffline(bool on) => setStatus(on ? PresenceStatus.invisible : PresenceStatus.online);

  /// Online, idle, do not disturb or invisible: shown at once, turned back (and thrown) when the
  /// server says no or does not have it yet (404). Both fields go, so a server before statuses
  /// still takes invisible; one that answers without `status` cannot keep idle or do not disturb,
  /// which throws [PresenceStatusUnsupported] with what it kept.
  Future<void> setStatus(PresenceStatus next) async {
    final before = status;
    status = next;
    _changing++;
    notifyListeners();
    try {
      final answer = await account.call('PATCH', 'me/presence', {
        'appearOffline': next == PresenceStatus.invisible,
        'status': next.name,
      });
      final kept = PresenceStatus.parse(answer['status']);
      if (kept != null) {
        status = kept;
      } else if (answer['appearOffline'] case final bool hidden) {
        status = hidden ? PresenceStatus.invisible : PresenceStatus.online;
        if (next == PresenceStatus.idle || next == PresenceStatus.dnd) throw const PresenceStatusUnsupported();
      }
    } on PresenceStatusUnsupported {
      rethrow;
    } on Object {
      status = before;
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

  static String? _text(Object? value) => value is String && value.trim().isNotEmpty ? value : null;

  /// The name, handle and picture /me has: the kept user follows them when one changed.
  void _adoptIdentity(Map<String, dynamic> profile) {
    final user = account.user;
    final handle = profile['handle'];
    final displayName = profile['displayName'];
    if (user == null || handle is! String || handle.isEmpty || displayName is! String) return;
    final avatar = profile.containsKey('avatar') ? _text(profile['avatar']) : user.avatar;
    if (handle == user.handle && displayName == user.displayName && avatar == user.avatar) return;
    account.updateUser(TogetherUser(id: user.id, handle: handle, displayName: displayName, avatar: avatar));
  }

  /// The friends-only name (PATCH /me/profile); blank clears it.
  Future<void> setPrivateName(String name) async {
    final trimmed = name.trim();
    final answer = await account.call('PATCH', 'me/profile', {'privateName': trimmed.isEmpty ? null : trimmed});
    privateName = answer.containsKey('privateName') ? _text(answer['privateName']) : (trimmed.isEmpty ? null : trimmed);
    notifyListeners();
  }

  /// The friends-only picture (PUT /me/avatar/private): a PNG or JPEG, at most 5 MB; the public
  /// picture stays.
  Future<void> uploadPrivateAvatar(List<int> picture) async {
    final png = picture.length > 8 && picture[0] == 0x89 && picture[1] == 0x50;
    final answer = await account.upload('PUT', 'me/avatar/private', picture, png ? 'image/png' : 'image/jpeg');
    privateAvatar = _text(answer['privateAvatar']);
    notifyListeners();
  }

  Future<void> removePrivateAvatar() async {
    await account.call('DELETE', 'me/avatar/private');
    privateAvatar = null;
    notifyListeners();
  }

  void clear() {
    privateName = null;
    privateAvatar = null;
    wornTheme = null;
    level = null;
    status = PresenceStatus.online;
    readReceipts = true;
    loaded = false;
    readAt = null;
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
        // Another device's choice: its status, or (a server before statuses) appear offline.
        final next =
            PresenceStatus.parse(data['status']) ??
            switch (data['appearOffline']) {
              final bool hidden => hidden ? PresenceStatus.invisible : PresenceStatus.online,
              _ => null,
            };
        if (next == null) return;
        status = next;
        notifyListeners();
    }
  }

  void dispose() => unawaited(_events.cancel());
}

/// The server kept online or invisible but has no idle or do not disturb yet.
class PresenceStatusUnsupported implements Exception {
  const PresenceStatusUnsupported();

  @override
  String toString() => 'this server has no idle or do not disturb yet';
}
