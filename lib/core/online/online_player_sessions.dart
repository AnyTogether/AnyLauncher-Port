import 'dart:convert';
import 'dart:math';

import 'online_json.dart';
import 'online_wire.dart';

/// The platform's Player Sessions (`sessionManager` web API group, `/v1/playerSessions…`),
/// answered here for one game run and kept in memory. Nothing goes to Sony, nothing to
/// AnyTogether (the Mac launcher's OnlinePlayerSessions, the same answers).
///
/// Games make a Player Session when they host, even when their own game traffic goes elsewhere:
/// Human Fall Flat (PPSA02429) hosts through Photon, but makes a `sessionManager` push context and
/// a Player Session first, and shows "Failed to Start a Server" when either fails. The bodies
/// follow public documentation of the console network's Session Manager API and are unverified;
/// every request body is in the title's observation log (the engine writes it with the request).
///
/// Changes the game makes itself bring it no push events (the platform does not tell a member
/// about its own change). Changes from elsewhere ([playerJoined], [playerLeft]) are pushed to
/// every push context the session's players registered, with the data types the game listens for
/// (`psn:sessionManager:ps:m:players:created`, …).
class OnlinePlayerSessions {
  /// [account] and [onlineId] are the signed-in player's ([OnlineIdentity]); [push] hands an
  /// event to the game (the bridge).
  OnlinePlayerSessions({
    required int account,
    required this.onlineId,
    DateTime Function()? now,
    void Function(WirePushEvent event)? push,
  }) : _account = account,
       me = OnlineWire.unsigned(account),
       _now = now ?? DateTime.now,
       _push = push ?? ((_) {});

  static const group = 'sessionManager';
  static const platform = 'PS5';
  static const maxSessions = 64;

  /// What the game may set at creation and with PATCH.
  static const settable = {
    'maxPlayers',
    'maxSpectators',
    'joinDisabled',
    'supportedPlatforms',
    'sessionName',
    'localizedSessionName',
    'joinableUserType',
    'invitableUserType',
    'leaderPrivileges',
    'exclusiveLeaderPrivileges',
    'disableSystemUiMenu',
    'swapSupported',
    'customData1',
    'customData2',
    'conditionalSession',
  };

  final int _account;
  final String me;
  final String onlineId;
  final DateTime Function() _now;
  final void Function(WirePushEvent event) _push;
  final _sessions = <String, _Session>{};
  final _order = <String>[];

  static final Random _random = Random.secure();

  /// A version 4 UUID, lowercase, as session IDs are written.
  static String uuid() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = OnlineWire.hex(bytes);
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  List<String> get sessionIds => List.unmodifiable(_order);

  /// The sessions open now, as GET answers them.
  List<Map<String, Object?>> get openSessions => [for (final id in _order) _view(_sessions[id]!)];

  WireWebReply handle(WireWebRequest request) {
    final (parts, query) = OnlineJson.split(request.path);
    final method = request.method.toUpperCase();
    if (parts.length < 2 || parts[0] != 'v1') return OnlineJson.problem(404, 'No such sessionManager call');
    final body = OnlineJson.object(request.body);
    if (body == null) return OnlineJson.problem(400, 'The body must be a JSON object');

    if (parts[1] == 'users' && parts.length == 4) {
      if (!_isMe(parts[2])) return OnlineJson.problem(403, 'Only your own sessions are offered');
      switch ((method, parts[3])) {
        case ('GET', 'playerSessions'):
          final mine = [
            for (final id in _order)
              if (_sessions[id]!.has(me)) {'sessionId': id, 'platform': platform},
          ];
          return OnlineJson.reply(200, {'playerSessions': mine});
        case ('GET', 'playerSessionsInvitations'):
          return OnlineJson.reply(200, {'invitations': <Object>[]});
        default:
          return OnlineJson.problem(404, 'No such sessionManager call');
      }
    }
    if (parts[1] != 'playerSessions') return OnlineJson.problem(404, 'No such sessionManager call');
    switch ((method, parts.length)) {
      case ('POST', 2):
        return _create(body);
      case ('GET', 3):
        final found = [
          for (final id in parts[2].split(','))
            if (_sessions[id] case final session?) _view(session),
        ];
        return found.isEmpty
            ? OnlineJson.problem(404, 'No such player session')
            : OnlineJson.reply(200, {'playerSessions': found});
      case ('PATCH', 3):
        return _change(parts[2], (session) {
          for (final entry in body.entries) {
            if (settable.contains(entry.key)) session.settings[entry.key] = entry.value;
          }
          return null;
        });
      case ('DELETE', 3):
        if (_sessions.remove(parts[2]) == null) return OnlineJson.problem(404, 'No such player session');
        _order.remove(parts[2]);
        return WireWebReply(status: 204);
    }
    if (parts.length < 4) return OnlineJson.problem(404, 'No such sessionManager call');
    final id = parts[2];
    switch ((method, parts.length, parts[3])) {
      case ('POST', 5, 'member') when parts[4] == 'players' || parts[4] == 'spectators':
        final spectators = parts[4] == 'spectators';
        final joining = _players(body[parts[4]]);
        return _change(id, (session) {
          for (final player in joining) {
            session.players.removeWhere((known) => known.accountId == player.accountId);
            session.spectators.removeWhere((known) => known.accountId == player.accountId);
            (spectators ? session.spectators : session.players).add(player);
          }
          return OnlineJson.reply(200, {
            parts[4]: [
              for (final player in joining) {'accountId': player.accountId, 'platform': player.platform},
            ],
          });
        });
      case ('DELETE', 5, 'members'):
        final who = _isMe(parts[4]) ? me : parts[4];
        // Leaving a session one is not in (or one that is gone) is done already: games leave the
        // last session they knew before they host again.
        final session = _sessions[id];
        if (session != null) {
          session.players.removeWhere((player) => player.accountId == who);
          session.spectators.removeWhere((player) => player.accountId == who);
          if (session.players.isEmpty && session.spectators.isEmpty) {
            _sessions.remove(id);
            _order.remove(id);
          } else if (session.leader == who) {
            session.leader = session.players.firstOrNull?.accountId ?? session.spectators.firstOrNull?.accountId ?? '';
          }
        }
        return WireWebReply(status: 204);
      case ('PUT', 4, 'leader'):
        final account = _accountId(body['accountId']);
        if (account == null) return OnlineJson.problem(400, 'accountId is required');
        return _change(id, (session) {
          if (!session.players.any((player) => player.accountId == account)) {
            return OnlineJson.problem(400, 'The leader must be a player');
          }
          session.leader = account;
          return null;
        });
      case ('POST', 4, 'invitations'):
        final made = <Map<String, Object?>>[];
        final reply = _change(id, (session) {
          for (final invitation in body['invitations'] as List<dynamic>? ?? const []) {
            if (invitation is! Map<String, dynamic>) continue;
            final to = invitation['to'];
            final account = to is Map<String, dynamic> ? _accountId(to['accountId']) ?? '' : '';
            final entry = <String, Object?>{
              'invitationId': uuid(),
              'to': {'accountId': account},
            };
            session.invitations.add(entry);
            made.add({'invitationId': entry['invitationId']});
          }
          return null;
        });
        return reply.status == 204 ? OnlineJson.reply(200, {'invitations': made}) : reply;
      case ('POST', 4, 'joinableSpecifiedUsers'):
        final users = [
          for (final user in body['joinableSpecifiedUsers'] as List<dynamic>? ?? const [])
            if (user is Map<String, dynamic>) ?_accountId(user['accountId']),
        ];
        final reply = _change(id, (session) {
          for (final user in users) {
            if (!session.joinableSpecifiedUsers.contains(user)) session.joinableSpecifiedUsers.add(user);
          }
          return null;
        });
        return reply.status == 204
            ? OnlineJson.reply(200, {
                'joinableSpecifiedUsers': [
                  for (final user in users) {'accountId': user},
                ],
              })
            : reply;
      case ('DELETE', 4, 'joinableSpecifiedUsers'):
        final users = (query['accountIds'] ?? '').split(',').toSet();
        return _change(id, (session) {
          session.joinableSpecifiedUsers.removeWhere(users.contains);
          return null;
        });
      case ('POST', 4, 'sessionMessage'):
        return _change(id, (_) => null);
      default:
        return OnlineJson.problem(404, 'No such sessionManager call');
    }
  }

  /// Another player joined session [sessionId] (from outside this game): kept, and pushed to the
  /// game as `psn:sessionManager:ps:m:players:created`. False when there is no such session.
  bool playerJoined({required String sessionId, required int account, required String onlineId}) {
    final session = _sessions[sessionId];
    if (session == null) return false;
    final player = _Player(
      accountId: OnlineWire.unsigned(account),
      platform: platform,
      onlineId: onlineId,
      joined: _millis(),
      pushContexts: const [],
    );
    final contexts = _pushContexts(session);
    session.players
      ..removeWhere((known) => known.accountId == player.accountId)
      ..add(player);
    _send(
      'psn:sessionManager:ps:m:players:created',
      {
        'playerSessionId': sessionId,
        'member': {
          'players': [
            {'accountId': player.accountId, 'platform': player.platform, 'onlineId': onlineId},
          ],
        },
      },
      to: contexts,
      from: account,
      fromOnlineId: onlineId,
    );
    return true;
  }

  /// Another player left session [sessionId]: pushed as `psn:sessionManager:ps:m:players:deleted`
  /// (and `…:ps:leader:updated` when they led it).
  void playerLeft({required String sessionId, required int account}) {
    final who = OnlineWire.unsigned(account);
    final session = _sessions[sessionId];
    final leaving = session?.players.where((player) => player.accountId == who).firstOrNull;
    if (session == null || leaving == null) return;
    session.players.removeWhere((player) => player.accountId == who);
    String? newLeader;
    if (session.leader == who && session.players.isNotEmpty) {
      newLeader = session.leader = session.players.first.accountId;
    }
    final contexts = _pushContexts(session);
    _send(
      'psn:sessionManager:ps:m:players:deleted',
      {
        'playerSessionId': sessionId,
        'member': {
          'players': [
            {'accountId': who, 'platform': platform},
          ],
        },
      },
      to: contexts,
      from: account,
      fromOnlineId: leaving.onlineId,
    );
    if (newLeader != null) {
      _send(
        'psn:sessionManager:ps:leader:updated',
        {
          'playerSessionId': sessionId,
          'leader': {'accountId': newLeader, 'platform': platform},
        },
        to: contexts,
        from: account,
        fromOnlineId: leaving.onlineId,
      );
    }
  }

  WireWebReply _create(Map<String, dynamic> body) {
    final asked = [
      for (final fields in body['playerSessions'] as List<dynamic>? ?? const [])
        if (fields is Map<String, dynamic>) fields,
    ];
    if (asked.isEmpty) return OnlineJson.problem(400, 'playerSessions is required');
    if (_sessions.length + asked.length > maxSessions) return OnlineJson.problem(429, 'Too many player sessions');
    final made = <Map<String, Object?>>[];
    for (final fields in asked) {
      final member = fields['member'] is Map<String, dynamic> ? fields['member'] as Map<String, dynamic> : const {};
      var playing = _players(member['players']);
      final watching = _players(member['spectators']);
      if (playing.isEmpty && watching.isEmpty) {
        playing = [
          _Player(accountId: me, platform: platform, onlineId: onlineId, joined: _millis(), pushContexts: const []),
        ];
      }
      final settings = <String, Object?>{
        for (final entry in fields.entries)
          if (settable.contains(entry.key)) entry.key: entry.value,
      };
      settings['maxPlayers'] ??= playing.length > 1 ? playing.length : 1;
      settings['maxSpectators'] ??= 0;
      final session = _Session(
        id: uuid(),
        created: _millis(),
        settings: settings,
        players: playing,
        spectators: watching,
        leader: playing.firstOrNull?.accountId ?? watching.firstOrNull?.accountId ?? me,
        joinableSpecifiedUsers: [
          for (final user in fields['joinableSpecifiedUsers'] as List<dynamic>? ?? const [])
            if (user is Map<String, dynamic>) ?_accountId(user['accountId']),
        ],
      );
      _sessions[session.id] = session;
      _order.add(session.id);
      made.add({
        'sessionId': session.id,
        'member': {
          'players': [
            for (final player in playing) {'accountId': player.accountId, 'platform': player.platform},
          ],
          'spectators': [
            for (final player in watching) {'accountId': player.accountId, 'platform': player.platform},
          ],
        },
      });
    }
    return OnlineJson.reply(200, {'playerSessions': made});
  }

  /// Runs [apply] on session [id]; its reply, or 204 when it returns null.
  WireWebReply _change(String id, WireWebReply? Function(_Session session) apply) {
    final session = _sessions[id];
    if (session == null) return OnlineJson.problem(404, 'No such player session');
    return apply(session) ?? WireWebReply(status: 204);
  }

  List<_Player> _players(Object? value) => [
    for (final entry in value is List ? value : const [])
      if (entry is Map<String, dynamic>)
        if (_accountId(entry['accountId']) case final account?)
          _Player(
            accountId: account,
            platform: switch (entry['platform']) {
              final String text when text.isNotEmpty && text != 'me' => text,
              _ => platform,
            },
            onlineId: account == me ? onlineId : '',
            joined: _millis(),
            pushContexts: [
              for (final context in entry['pushContexts'] as List<dynamic>? ?? const [])
                if (context is Map<String, dynamic> && context['pushContextId'] is String)
                  context['pushContextId'] as String,
            ],
            customData1: entry['customData1'],
          ),
  ];

  /// An account in a body: "me", our number, or another player's number (string or number).
  String? _accountId(Object? value) {
    if (value is String && value.isNotEmpty) return _isMe(value) ? me : value;
    if (value is int) return value.toString();
    if (value is double) return value == value.truncateToDouble() ? value.toInt().toString() : value.toString();
    return null;
  }

  bool _isMe(String who) => who == 'me' || who.startsWith('local_') || who == me;

  List<String> _pushContexts(_Session session) => [
    for (final player in [...session.players, ...session.spectators])
      if (player.accountId == me) ...player.pushContexts,
  ];

  void _send(
    String dataType,
    Map<String, Object?> data, {
    required List<String> to,
    required int from,
    required String fromOnlineId,
  }) {
    final body = utf8.encode(OnlineJson.encode(data));
    final online = String.fromCharCodes(fromOnlineId.runes.take(16));
    for (final context in to.isEmpty ? const [''] : to) {
      _push(
        WirePushEvent(
          service: group,
          pushContextId: context,
          dataType: dataType,
          data: body,
          to: _account,
          from: from,
          fromOnlineId: online,
        ),
      );
    }
  }

  Map<String, Object?> _view(_Session session) {
    Map<String, Object?> member(_Player player) => {
      'accountId': player.accountId,
      'platform': player.platform,
      'joinTimestamp': player.joined.toString(),
      if (player.onlineId.isNotEmpty) 'onlineId': player.onlineId,
      if (player.customData1 != null) 'customData1': player.customData1,
    };
    return {
      ...session.settings,
      'sessionId': session.id,
      'createdTimestamp': session.created.toString(),
      'member': {
        'players': [for (final player in session.players) member(player)],
        'spectators': [for (final player in session.spectators) member(player)],
      },
      'leader': {'accountId': session.leader, 'platform': platform},
      'joinableSpecifiedUsers': [
        for (final user in session.joinableSpecifiedUsers) {'accountId': user},
      ],
      'joinDisabled': session.settings['joinDisabled'] ?? false,
      'supportedPlatforms': session.settings['supportedPlatforms'] ?? [platform],
    };
  }

  int _millis() => _now().millisecondsSinceEpoch;
}

class _Player {
  _Player({
    required this.accountId,
    required this.platform,
    required this.onlineId,
    required this.joined,
    required this.pushContexts,
    this.customData1,
  });

  final String accountId;
  final String platform;
  final String onlineId;
  final int joined;
  final List<String> pushContexts;
  final Object? customData1;
}

class _Session {
  _Session({
    required this.id,
    required this.created,
    required this.settings,
    required this.players,
    required this.spectators,
    required this.leader,
    required this.joinableSpecifiedUsers,
  });

  final String id;
  final int created;
  final Map<String, Object?> settings;
  final List<_Player> players;
  final List<_Player> spectators;
  String leader;
  final List<String> joinableSpecifiedUsers;
  final invitations = <Map<String, Object?>>[];

  bool has(String account) =>
      players.any((player) => player.accountId == account) || spectators.any((player) => player.accountId == account);
}
