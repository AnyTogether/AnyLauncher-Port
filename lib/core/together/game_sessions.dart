import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'account.dart';
import 'notifier.dart';
import 'people.dart';
import 'socket.dart';

enum SessionMismatch { gameVersion, engineBuild }

/// A game someone runs that friends can join: the same game version on the same engine build.
/// [json] is the session as the server sent it (players' own properties included), kept whole
/// for the engine's online bridge.
class GameSession {
  const GameSession({
    required this.id,
    required this.titleId,
    required this.gameVersion,
    required this.engineBuild,
    required this.capacity,
    required this.joinable,
    required this.players,
    this.host,
    this.json = const {},
  });

  factory GameSession.fromJson(Map<String, dynamic> json) => GameSession(
    id: json['id'] as String,
    host: json['host'] is Map<String, dynamic> ? Person.fromJson(json['host'] as Map<String, dynamic>) : null,
    titleId: json['titleId'] as String,
    gameVersion: json['gameVersion'] as String? ?? '',
    engineBuild: json['engineBuild'] as String? ?? '',
    capacity: (json['capacity'] as num? ?? 2).toInt(),
    joinable: json['joinable'] as bool? ?? false,
    players: [
      for (final player in json['players'] as List<dynamic>? ?? const [])
        Person.fromJson(player as Map<String, dynamic>),
    ],
    json: json,
  );

  final String id;
  final Person? host;
  final String titleId;
  final String gameVersion;
  final String engineBuild;
  final int capacity;
  final bool joinable;
  final List<Person> players;
  final Map<String, dynamic> json;

  /// Why this computer's copy cannot join, or null when it can.
  SessionMismatch? mismatch({required String gameVersion, required String engineBuild}) {
    if (gameVersion != this.gameVersion) return SessionMismatch.gameVersion;
    if (engineBuild != this.engineBuild) return SessionMismatch.engineBuild;
    return null;
  }

  /// An engine build as the server takes it: letters, digits and . _ + -, at most 64.
  static String cleanEngineBuild(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '-');
    final short = cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
    return short.isEmpty ? 'unknown' : short;
  }

  /// A game version as the server takes it (at most 32 of the same characters).
  static String cleanGameVersion(String raw) {
    final cleaned = cleanEngineBuild(raw);
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  /// "0.2.13-a1b2c3d4e5f6" → "0.2.13 (a1b2c3)": the release, then which build of it.
  static String release(String engine) {
    final at = engine.indexOf('-');
    if (at < 0) return engine;
    final build = engine.substring(at + 1);
    return '${engine.substring(0, at)} (${build.length > 6 ? build.substring(0, 6) : build})';
  }
}

/// An invitation to a friend's game.
class GameInvite {
  const GameInvite({
    required this.sessionId,
    required this.titleId,
    required this.gameVersion,
    required this.engineBuild,
    this.from,
  });

  factory GameInvite.fromJson(Map<String, dynamic> json) => GameInvite(
    sessionId: json['sessionId'] as String,
    from: json['from'] is Map<String, dynamic> ? Person.fromJson(json['from'] as Map<String, dynamic>) : null,
    titleId: json['titleId'] as String? ?? '',
    gameVersion: json['gameVersion'] as String? ?? '',
    engineBuild: json['engineBuild'] as String? ?? '',
  );

  final String sessionId;
  final Person? from;
  final String titleId;
  final String gameVersion;
  final String engineBuild;
}

/// The game session this launcher hosts or joined, and the invites to friends' games; written for
/// the engine's online bridge (ANYPS5_TOGETHER_SESSION points at [bridgeFile]), which does the
/// playing together.
class GameSessions with Notifier {
  GameSessions({required this.account, required this.socket, required this.bridgeFile}) {
    _events = socket.events.listen(_event);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  final String bridgeFile;
  late final StreamSubscription<TogetherEvent> _events;

  GameSession? session;
  List<GameInvite> invites = const [];

  /// The host ended the session this launcher joined (their card).
  void Function(Person? host)? onEnded;
  void Function(GameInvite invite)? onInvite;

  bool get hosting => session != null && session!.host?.id == account.user?.id;

  Future<void> refresh() async {
    final json = await account.call('GET', 'me/game-session');
    invites = [
      for (final invite in json['invites'] as List<dynamic>? ?? const [])
        GameInvite.fromJson(invite as Map<String, dynamic>),
    ];
    notifyListeners();
  }

  /// A session for the game this launcher runs (ending any other the user is in).
  Future<GameSession> open({
    required String titleId,
    required String gameVersion,
    required String engineBuild,
    required int capacity,
    bool joinable = true,
  }) async => _kept(
    GameSession.fromJson(
      await account.call('POST', 'game-sessions', {
        'titleId': titleId,
        'gameVersion': gameVersion,
        'engineBuild': engineBuild,
        'capacity': capacity,
        'joinable': joinable,
      }),
    ),
  );

  Future<GameSession> get(String id) async => GameSession.fromJson(await account.call('GET', 'game-sessions/$id'));

  Future<GameSession> setJoinable(bool joinable) async {
    final current = session!;
    return _kept(
      GameSession.fromJson(await account.call('PATCH', 'game-sessions/${current.id}', {'joinable': joinable})),
    );
  }

  /// Refused with version_mismatch (409) unless both match the host's, full when it is.
  Future<GameSession> join(String id, {required String gameVersion, required String engineBuild}) async {
    final joined = _kept(
      GameSession.fromJson(
        await account.call('POST', 'game-sessions/$id/join', {'gameVersion': gameVersion, 'engineBuild': engineBuild}),
      ),
    );
    invites = invites.where((invite) => invite.sessionId != id).toList();
    notifyListeners();
    return joined;
  }

  Future<void> invite(List<String> userIds) async {
    final current = session;
    if (current == null) return;
    await account.call('POST', 'game-sessions/${current.id}/invites', {'userIds': userIds});
  }

  Future<void> decline(String id) async {
    invites = invites.where((invite) => invite.sessionId != id).toList();
    notifyListeners();
    await account.call('POST', 'game-sessions/$id/decline', {});
  }

  /// Out of the session: the host ends it, a guest leaves it.
  Future<void> close() async {
    final current = session;
    if (current == null) return;
    final hosted = hosting;
    keep(null);
    try {
      if (hosted) {
        await account.call('DELETE', 'game-sessions/${current.id}');
      } else {
        await account.call('POST', 'game-sessions/${current.id}/leave', {});
      }
    } on Object {
      // The server ends it when this launcher stops answering.
    }
  }

  /// The session as it is now, here and in the bridge file; null removes the file.
  void keep(GameSession? next) {
    session = next;
    writeBridge();
    notifyListeners();
  }

  GameSession _kept(GameSession next) {
    keep(next);
    return next;
  }

  /// {role, userId, session}: the engine's bridge reads who hosts and the session's details.
  void writeBridge() {
    final file = File(bridgeFile);
    final current = session;
    final me = account.user?.id;
    try {
      if (current == null || me == null) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      file.parent.createSync(recursive: true);
      final temporary = File('$bridgeFile.tmp')
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ')
              .convert({'role': current.host?.id == me ? 'host' : 'guest', 'userId': me, 'session': current.json}),
        );
      temporary.renameSync(bridgeFile);
    } on FileSystemException {
      // Without the file the game plays alone.
    }
  }

  void clear() {
    keep(null);
    invites = const [];
    notifyListeners();
  }

  void _event(TogetherEvent event) {
    final data = event.json;
    switch (event.type) {
      case 'live.ready':
        unawaited(refresh().catchError((Object _) {}));
      case 'game_session.invite':
        final invite = GameInvite.fromJson(data);
        invites = [...invites.where((known) => known.sessionId != invite.sessionId), invite];
        notifyListeners();
        onInvite?.call(invite);
      case 'game_session.updated':
        final updated = GameSession.fromJson(data);
        if (updated.id == session?.id) keep(updated);
      case 'game_session.ended':
        final id = data['sessionId'];
        invites = invites.where((invite) => invite.sessionId != id).toList();
        final current = session;
        if (current != null && current.id == id) {
          final host = current.host;
          final hosted = hosting;
          keep(null);
          if (!hosted) onEnded?.call(host);
        } else {
          notifyListeners();
        }
    }
  }

  void dispose() => unawaited(_events.cancel());

  static String defaultBridgeFile(String configFolder) => p.join(configFolder, 'Together', 'game-session.json');
}
