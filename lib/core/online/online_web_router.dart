import 'dart:convert';

import '../together/account.dart';
import 'online_identity.dart';
import 'online_json.dart';
import 'online_peer.dart';
import 'online_player_sessions.dart';
import 'online_user_profile.dart';
import 'online_wire.dart';

/// A game session as AnyTogether shows it, as much as online play needs: the players and the
/// devices their launchers published (where signals for them go).
class OnlineSessionView {
  const OnlineSessionView({
    required this.id,
    required this.titleId,
    required this.gameVersion,
    required this.engineBuild,
    required this.players,
    this.devices = const {},
    this.ended = false,
  });

  final String id;
  final String titleId;
  final String gameVersion;
  final String engineBuild;

  /// The players' user IDs.
  final List<String> players;

  /// Each player's published device, for those who published one.
  final Map<String, String> devices;
  final bool ended;

  /// The virtual address of each player ([OnlineIdentity.addresses]): the same on every
  /// launcher, and nobody's moves when someone leaves.
  Map<String, int> get addresses => OnlineIdentity.addresses(players);

  static OnlineSessionView? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final titleId = json['titleId'];
    if (id is! String || titleId is! String) return null;
    final players = <String>[
      for (final player in json['players'] as List<dynamic>? ?? const [])
        if (player is Map<String, dynamic> && player['userId'] is String) player['userId'] as String,
    ];
    final devices = <String, String>{};
    for (final member in json['members'] as List<dynamic>? ?? const []) {
      if (member is! Map<String, dynamic>) continue;
      final userId = member['userId'];
      final device = member['device'];
      if (userId is String && device is String) devices.putIfAbsent(userId, () => device);
    }
    return OnlineSessionView(
      id: id,
      titleId: titleId,
      gameVersion: json['gameVersion'] as String? ?? '',
      engineBuild: json['engineBuild'] as String? ?? '',
      players: players,
      devices: devices,
      ended: json['endedAt'] != null,
    );
  }
}

/// The running game, as AnyTogether's game sessions need it.
class OnlineGame {
  const OnlineGame({required this.titleId, required this.gameVersion, required this.engineBuild});

  final String titleId;
  final String gameVersion;
  final String engineBuild;

  OnlineGame withEngineBuild(String build) =>
      OnlineGame(titleId: titleId, gameVersion: gameVersion, engineBuild: build);
}

/// Answers the engine's web API requests. The `anyps5` group maps onto AnyTogether's game
/// sessions and invitations for this game; `userProfile` is answered from AnyTogether friends
/// ([OnlineUserProfile], unverified), `communicationRestrictionStatus` with "not restricted" and
/// `sessionManager` Player Sessions locally ([OnlinePlayerSessions]) while [platformGroups] is on;
/// every other platform group is answered "not offered" until its format is known from
/// observation, and every such request is counted so it shows up. Nothing of a platform group goes
/// anywhere, and nothing ever goes to Sony.
class OnlineWebRouter {
  OnlineWebRouter({
    required this.call,
    required this._game,
    this.profile,
    this.playerSessions,
    this.platformGroups = true,
    void Function(OnlineSessionView? view)? sessionChanged,
  }) : _sessionChanged = sessionChanged ?? ((_) {});

  static const group = 'anyps5';

  final OnlineCall call;
  final OnlineUserProfile? profile;

  /// The `sessionManager` group (Player Sessions), kept for this game run; null while signed out.
  final OnlinePlayerSessions? playerSessions;

  /// Off answers every platform group "not offered", for a clean observation run.
  final bool platformGroups;
  final void Function(OnlineSessionView? view) _sessionChanged;
  OnlineGame _game;
  final _unanswered = <String, int>{};

  OnlineGame get game => _game;

  /// Platform groups and paths the game asked for that nobody answers yet, with counts.
  Map<String, int> get notOffered => Map.unmodifiable(_unanswered);

  void setEngineBuild(String build) => _game = _game.withEngineBuild(build);

  static final _sessionId = RegExp(r'^[0-9A-Fa-f-]{1,64}$');

  Future<WireWebReply> handle(WireWebRequest request) async {
    final profile = this.profile;
    final sessions = playerSessions;
    if (request.apiGroup == OnlineUserProfile.group && platformGroups && profile != null) {
      return profile.handle(request);
    }
    if (request.apiGroup == OnlineUserProfile.restrictionGroup && platformGroups && profile != null) {
      return profile.handleRestriction(request);
    }
    if (request.apiGroup == OnlinePlayerSessions.group && platformGroups && sessions != null) {
      return sessions.handle(request);
    }
    if (request.apiGroup != group) {
      final key = '${request.apiGroup} ${request.method} ${OnlineJson.bare(request.path)}';
      _unanswered[key] = (_unanswered[key] ?? 0) + 1;
      return WireWebReply.notOffered;
    }
    final game = _game;
    final parts = OnlineJson.bare(request.path).split('/').where((part) => part.isNotEmpty).toList();
    final method = request.method.toUpperCase();
    final id = parts.length >= 3 && parts[0] == 'v1' && parts[1] == 'sessions' ? parts[2] : null;
    if (id != null && !_sessionId.hasMatch(id)) return _problem(404, 'not_found', 'No such game session');
    final action = parts.length == 4 ? parts[3] : null;
    try {
      switch ((method, parts.length, id, action)) {
        case ('POST', 2, _, _) when parts[0] == 'v1' && parts[1] == 'sessions':
          final fields = _object(request.body)
            ..['titleId'] = game.titleId
            ..['gameVersion'] = game.gameVersion
            ..['engineBuild'] = game.engineBuild;
          fields['capacity'] ??= 2;
          return await _session('POST', 'game-sessions', fields, status: 201);
        case ('GET', 3, final String id, null):
          return await _session('GET', 'game-sessions/$id', null, status: 200);
        case ('PATCH', 3, final String id, null):
          return await _session('PATCH', 'game-sessions/$id', _object(request.body), status: 200);
        case ('POST', 4, final String id, 'join'):
          return await _session('POST', 'game-sessions/$id/join', {
            'gameVersion': game.gameVersion,
            'engineBuild': game.engineBuild,
          }, status: 200);
        case ('POST', 4, final String id, 'leave'):
          await call('POST', 'game-sessions/$id/leave', {});
          _sessionChanged(null);
          return WireWebReply(status: 204);
        case ('POST', 4, final String id, 'invites'):
          return _json(200, await call('POST', 'game-sessions/$id/invites', _object(request.body)));
        case ('GET', 3, _, _) when parts[0] == 'v1' && parts[1] == 'me' && parts[2] == 'session':
          return _json(200, await call('GET', 'me/game-session'));
        default:
          return _problem(404, 'not_found', 'No such $group call');
      }
    } on TogetherProblem catch (problem) {
      return _problem(problem.status, problem.code, problem.title);
    } on Object {
      return _problem(502, 'unavailable', 'AnyTogether could not be reached');
    }
  }

  Future<WireWebReply> _session(String method, String path, Map<String, dynamic>? fields, {required int status}) async {
    final data = await call(method, path, fields);
    final view = OnlineSessionView.fromJson(data);
    if (view != null) _sessionChanged(view.ended ? null : view);
    return _json(status, data);
  }

  Map<String, dynamic> _object(List<int> body) {
    final fields = OnlineJson.object(body);
    if (fields == null) throw const TogetherProblem(400, 'invalid_input', 'The body must be a JSON object');
    return fields;
  }

  WireWebReply _json(int status, Map<String, dynamic> data) =>
      WireWebReply(status: status, headers: const [OnlineJson.contentType], body: utf8.encode(jsonEncode(data)));

  WireWebReply _problem(int status, String code, String title) => WireWebReply(
    status: status.clamp(0, 0xFFFF),
    headers: const [WirePair('Content-Type', 'application/problem+json')],
    body: utf8.encode(jsonEncode({'status': status, 'code': code, 'title': title})),
  );
}
