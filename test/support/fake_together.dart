import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A request the fake AnyTogether got.
class FakeCall {
  FakeCall(this.method, this.path, this.body, this.headers);

  final String method;
  final String path;
  final Map<String, dynamic> body;
  final HttpHeaders headers;

  @override
  String toString() => '$method $path ${jsonEncode(body)}';
}

/// AnyTogether for the tests, on localhost: the API under /api/v1 as the launcher uses it, in
/// memory, and the realtime gateway on /rt. Everyone is a user named by a token; a test pushes
/// events to the sockets and looks at the calls and frames that came in.
class FakeTogether {
  FakeTogether._(this._server) {
    _server.listen(_serve);
  }

  static Future<FakeTogether> start() async => FakeTogether._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  final List<FakeCall> calls = [];

  /// The user signing in, and the code the mail would carry.
  Map<String, dynamic> me = {'id': 'u-me', 'handle': 'utku', 'displayName': 'Utku'};
  String emailCode = '123456';

  /// How long an access token lives; a refresh gives a new one.
  int expiresIn = 900;
  int _tokens = 0;
  final Set<String> validAccess = {};
  final Set<String> validRefresh = {};

  /// Sign-ins waiting for an approval: device codes and hand-offs, by their secret.
  final Map<String, bool> _pending = {};
  final Map<String, String> _handoffSecrets = {};
  String? lastHandoff;
  String? lastDeviceCode;

  /// Answers for paths the tests choose: a status and a JSON body.
  final Map<String, (int, Object?)> answers = {};

  /// The gateway's sockets and the frames they sent.
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> frames = [];
  final _frameAdded = StreamController<Map<String, dynamic>>.broadcast();
  int heartbeatSeconds = 25;
  int _sessions = 0;

  /// People on the server by handle (their name cards), friends with their presence, and
  /// requests both ways.
  final Map<String, Map<String, dynamic>> people = {};
  final List<Map<String, dynamic>> friends = [];
  final List<Map<String, dynamic>> incoming = [];
  final List<Map<String, dynamic>> outgoing = [];

  /// A person card as the API sends it.
  static Map<String, dynamic> card(String id, String handle, String name) => {
    'userId': id,
    'handle': handle,
    'displayName': name,
    'avatar': null,
  };

  /// Someone the server knows, and so can be asked by handle.
  Map<String, dynamic> person(String id, String handle, String name) => people[handle] = card(id, handle, name);

  /// A friend with a presence (null is offline).
  void friend(String id, String handle, String name, {Map<String, dynamic>? presence}) {
    person(id, handle, name);
    friends.add({
      ...card(id, handle, name),
      'presence': presence ?? {'state': 'offline'},
    });
  }

  /// What the launcher's outbox sent: this computer, the games' names, the trophy sets, the
  /// sessions and the earned trophies (by "titleId/trophyId").
  final Map<String, Map<String, dynamic>> devices = {};
  final Map<String, Map<String, dynamic>> games = {};
  final Map<String, Map<String, dynamic>> trophySets = {};
  final Map<String, Map<String, dynamic>> playSessions = {};
  final Map<String, Map<String, dynamic>> earned = {};

  /// Conversations by id with their messages, the party the user is in and the invites, the
  /// party's call (who is in it, by user, with their device).
  final Map<String, Map<String, dynamic>> conversations = {};
  final Map<String, List<Map<String, dynamic>>> threads = {};
  Map<String, dynamic>? party;
  final List<Map<String, dynamic>> partyInvites = [];
  final Map<String, String> callPeers = {};
  int _ids = 0;

  /// A conversation with [others] (cards), and its messages as [texts] by author id.
  Map<String, dynamic> conversation(
    String id,
    List<Map<String, dynamic>> others, {
    List<(String, String)> texts = const [],
    int readSeq = 0,
  }) {
    final members = [card(me['id'] as String, me['handle'] as String, me['displayName'] as String), ...others];
    final messages = threads[id] = [
      for (var index = 0; index < texts.length; index++) _message(id, index + 1, texts[index].$1, texts[index].$2),
    ];
    return conversations[id] = {
      'id': id,
      'kind': others.length > 1 ? 'group' : 'direct',
      'title': null,
      'members': members,
      'lastSeq': messages.length,
      'readSeq': readSeq,
      'lastMessage': messages.isEmpty ? null : messages.last,
      'updatedAt': '2026-10-24T20:00:00Z',
    };
  }

  Map<String, dynamic> _message(String conversation, int seq, String author, String text, {String? id}) => {
    'id': id ?? 'm-$conversation-$seq',
    'conversationId': conversation,
    'seq': seq,
    'authorId': author,
    'text': text,
    'createdAt': '2026-10-24T20:${seq.toString().padLeft(2, '0')}:00Z',
  };

  /// A message from someone else, as the gateway brings it.
  void receive(String conversation, String author, String text) {
    final thread = threads[conversation]!;
    final message = _message(conversation, thread.length + 1, author, text);
    thread.add(message);
    conversations[conversation]!['lastSeq'] = thread.length;
    conversations[conversation]!['lastMessage'] = message;
    push('message.created', message);
  }

  Map<String, dynamic> _party(List<Map<String, dynamic>> members, {String? leader}) => party = {
    'id': 'party-${++_ids}',
    'leaderId': leader ?? me['id'],
    'privacy': 'invite',
    'members': members,
    'invited': <Map<String, dynamic>>[],
    'call': null,
  };

  /// The user is in a party with [others].
  Map<String, dynamic> inParty(List<Map<String, dynamic>> others, {String? leader}) => _party([
    card(me['id'] as String, me['handle'] as String, me['displayName'] as String),
    ...others,
  ], leader: leader);

  /// Handlers a test adds for its own paths: return null to fall through.
  final List<FutureOr<(int, Object?)?> Function(FakeCall call)> handlers = [];

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await _frameAdded.close();
    await _server.close(force: true);
  }

  /// Approves the device code shown on the website, or a hand-off the phone was asked about.
  void approveDevice() => _pending[lastDeviceCode!] = true;

  void approveHandoff([String? id]) {
    final secret = _handoffSecrets[id ?? lastHandoff];
    if (secret != null) _pending[secret] = true;
  }

  /// Calls to [path] (and [method]).
  List<FakeCall> callsTo(String path, {String? method}) =>
      calls.where((call) => call.path == path && (method == null || call.method == method)).toList();

  /// An event to every connected socket.
  void push(String type, Object? data, {String? id}) {
    final frame = jsonEncode({
      'op': 'event',
      'id': id ?? 'e-${DateTime.now().microsecondsSinceEpoch}',
      'type': type,
      'data': data,
    });
    for (final socket in sockets) {
      socket.add(frame);
    }
  }

  /// The next frame a socket sends with this op (and passing [test]).
  Future<Map<String, dynamic>> nextFrame(String op, {bool Function(Map<String, dynamic>)? test}) {
    for (final frame in frames) {
      if (frame['op'] == op && (test == null || test(frame))) {
        frames.remove(frame);
        return Future.value(frame);
      }
    }
    return _frameAdded.stream
        .firstWhere((frame) => frame['op'] == op && (test == null || test(frame)))
        .then((frame) {
          frames.remove(frame);
          return frame;
        })
        .timeout(const Duration(seconds: 5));
  }

  /// Closes every socket with [code] (4001 refused token, 4003 signed out elsewhere).
  Future<void> dropSockets([int code = 1001]) async {
    for (final socket in List.of(sockets)) {
      await socket.close(code);
    }
    sockets.clear();
  }

  Map<String, dynamic> _tokensFor() {
    _tokens++;
    final access = 'access-$_tokens';
    final refresh = 'refresh-$_tokens';
    validAccess.add(access);
    validRefresh.add(refresh);
    return {'accessToken': access, 'expiresIn': expiresIn, 'refreshToken': refresh, 'user': me};
  }

  Future<void> _serve(HttpRequest request) async {
    if (request.uri.path == '/rt' && WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket(socket);
      return;
    }
    final text = await utf8.decodeStream(request);
    final body = text.isEmpty ? <String, dynamic>{} : (jsonDecode(text) as Map<String, dynamic>? ?? {});
    final prefix = '/api/v1/';
    final path = request.uri.path.startsWith(prefix)
        ? request.uri.path.substring(prefix.length) + (request.uri.hasQuery ? '?${request.uri.query}' : '')
        : request.uri.path;
    final call = FakeCall(request.method, path, body, request.headers);
    calls.add(call);
    final (status, json) = await _route(call, request.headers.value(HttpHeaders.authorizationHeader));
    request.response.statusCode = status;
    if (json != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(json));
    }
    await request.response.close();
  }

  static (int, Object?) problem(int status, String code, [String title = '']) =>
      (status, {'type': 'about:blank', 'status': status, 'code': code, 'title': title.isEmpty ? code : title});

  Future<(int, Object?)> _route(FakeCall call, String? authorization) async {
    final answer = answers['${call.method} ${call.path}'] ?? answers[call.path];
    if (answer != null) return answer;
    switch ((call.method, call.path)) {
      case ('POST', 'auth/email/start'):
        return (202, null);
      case ('POST', 'auth/email/verify'):
        return call.body['code'] == emailCode ? (200, _tokensFor()) : problem(400, 'code_invalid');
      case ('POST', 'auth/device'):
        lastDeviceCode = 'device-code-${_tokens}0000000000000000000000';
        _pending[lastDeviceCode!] = false;
        return (
          201,
          {
            'deviceCode': lastDeviceCode,
            'userCode': 'ABCD-EFGH',
            'verificationUri': '$base/link',
            'expiresIn': 600,
            'interval': 5,
          },
        );
      case ('POST', 'auth/handoff/start'):
        lastHandoff = 'handoff-${_handoffSecrets.length + 1}';
        final secret = 'secret-${_handoffSecrets.length + 1}';
        _handoffSecrets[lastHandoff!] = secret;
        _pending[secret] = false;
        return (201, {'handoffId': lastHandoff, 'secret': secret});
      case ('POST', 'auth/token'):
        switch (call.body['grantType']) {
          case 'refresh_token':
            final refresh = call.body['refreshToken'] as String?;
            if (!validRefresh.remove(refresh)) return problem(400, 'invalid_grant');
            return (200, _tokensFor());
          case 'device_code' || 'handoff':
            final secret = (call.body['deviceCode'] ?? call.body['secret']) as String?;
            final approved = _pending[secret];
            if (approved == null) return problem(400, 'expired_token');
            if (!approved) return problem(400, 'authorization_pending');
            _pending.remove(secret);
            return (200, _tokensFor());
        }
        return problem(400, 'bad_request');
    }
    for (final handler in handlers) {
      final handled = await handler(call);
      if (handled != null) return handled;
    }
    // Everything else needs a valid access token.
    final token = authorization?.replaceFirst('Bearer ', '');
    if (token == null || !validAccess.contains(token)) return problem(401, 'unauthorized');
    final handoffApprove = RegExp(r'^auth/handoff/([^/]+)/approve$').firstMatch(call.path);
    if (call.method == 'POST' && handoffApprove != null) {
      final secret = _handoffSecrets[handoffApprove.group(1)];
      if (secret == null) return problem(404, 'not_found');
      _pending[secret] = true;
      return (204, null);
    }
    switch ((call.method, call.path)) {
      case ('POST', 'auth/logout'):
        validAccess.remove(token);
        return (204, null);
      case ('GET', 'me'):
        return (
          200,
          {
            'account': {'id': me['id']},
            'profile': me,
          },
        );
      case ('GET', 'me/friends'):
        return (200, {'friends': friends});
      case ('GET', 'me/friends/requests'):
        return (200, {'incoming': incoming, 'outgoing': outgoing});
      case ('POST', 'me/friends/requests'):
        final someone = people[call.body['handle']];
        if (someone == null) return problem(404, 'not_found', 'No such user');
        if (incoming.any((person) => person['userId'] == someone['userId'])) {
          incoming.removeWhere((person) => person['userId'] == someone['userId']);
          friends.add({
            ...someone,
            'presence': {'state': 'online'},
          });
          return (200, {'state': 'accepted'});
        }
        outgoing.add(someone);
        return (201, {'state': 'pending'});
    }
    switch ((call.method, call.path)) {
      case ('POST', 'me/devices'):
        devices[call.body['id'] as String] = call.body;
        return (201, call.body);
      case ('POST', 'me/sessions'):
        final items = call.body['sessions'] as List<dynamic>;
        return (
          200,
          {
            'results': [
              for (var index = 0; index < items.length; index++)
                () {
                  final item = items[index] as Map<String, dynamic>;
                  if (!devices.containsKey(item['deviceId'])) {
                    return {'index': index, 'status': 'rejected', 'code': 'unknown_device'};
                  }
                  final duplicate = playSessions.containsKey(item['id']);
                  playSessions[item['id'] as String] = item;
                  return {'index': index, 'status': duplicate ? 'duplicate' : 'stored'};
                }(),
            ],
          },
        );
      case ('POST', 'me/trophies'):
        final items = call.body['trophies'] as List<dynamic>;
        return (
          200,
          {
            'results': [
              for (var index = 0; index < items.length; index++)
                () {
                  final item = items[index] as Map<String, dynamic>;
                  if (!trophySets.containsKey('${item['titleId']}/${item['setHash']}')) {
                    return {'index': index, 'status': 'rejected', 'code': 'unknown_trophy'};
                  }
                  final key = '${item['titleId']}/${item['trophyId']}';
                  final duplicate = earned.containsKey(key);
                  earned[key] = item;
                  return {'index': index, 'status': duplicate ? 'duplicate' : 'stored'};
                }(),
            ],
          },
        );
    }
    switch ((call.method, call.path)) {
      case ('GET', 'me/conversations'):
        return (200, {'conversations': conversations.values.toList()});
      case ('GET', 'me/conversations/unread'):
        var unread = 0;
        for (final conversation in conversations.values) {
          unread += (conversation['lastSeq'] as int) - (conversation['readSeq'] as int);
        }
        return (200, {'messages': unread});
      case ('POST', 'conversations'):
        final other = (call.body['members'] as List<dynamic>).single as String;
        final existing = conversations.values.where(
          (conversation) =>
              conversation['kind'] == 'direct' &&
              (conversation['members'] as List<dynamic>).any((member) => (member as Map)['userId'] == other),
        );
        if (existing.isNotEmpty) return (200, existing.first);
        final person = people.values.firstWhere((person) => person['userId'] == other);
        return (201, conversation('c-${++_ids}', [person]));
      case ('GET', 'me/party'):
        return (200, {'party': party, 'invites': partyInvites});
      case ('POST', 'parties'):
        final created = inParty(const []);
        created['privacy'] = call.body['privacy'] ?? 'invite';
        return (201, created);
      case ('POST', 'calls'):
        final current = party;
        if (current == null || current['id'] != call.body['partyId']) return problem(404, 'not_found');
        final id = (current['call'] as Map<String, dynamic>?)?['id'] as String? ?? 'call-${++_ids}';
        current['call'] = {
          'id': id,
          'in': [...callPeers.keys, me['id']],
          'muted': <String>[],
        };
        return (
          201,
          {
            'call': {
              'id': id,
              'kind': 'party',
              'partyId': current['id'],
              'in': [
                for (final peer in callPeers.entries) {'userId': peer.key, 'device': peer.value, 'muted': false},
              ],
            },
            'iceServers': [
              {
                'urls': ['stun:stun.example.org:3478'],
              },
            ],
            'expiresAt': DateTime.now().add(const Duration(hours: 12)).toUtc().toIso8601String(),
          },
        );
      case ('GET', 'ice-servers'):
        return (200, {'iceServers': <Object>[], 'expiresAt': null});
    }
    final thread = RegExp(r'^conversations/([^/]+)/messages(\?.*)?$').firstMatch(call.path);
    if (thread != null) {
      final id = thread.group(1)!;
      final messages = threads[id];
      if (messages == null) return problem(404, 'not_found');
      if (call.method == 'GET') return (200, {'messages': messages, 'more': false});
      final text = call.body['text'] as String;
      if (text.contains('blocked.example')) return problem(400, 'link_blocked', 'That link is blocked');
      final message = _message(id, messages.length + 1, me['id'] as String, text, id: call.body['clientId'] as String?);
      messages.add(message);
      conversations[id]!
        ..['lastSeq'] = messages.length
        ..['readSeq'] = messages.length
        ..['lastMessage'] = message;
      return (201, message);
    }
    final read = RegExp(r'^conversations/([^/]+)/read$').firstMatch(call.path);
    if (call.method == 'POST' && read != null) {
      conversations[read.group(1)]?['readSeq'] = call.body['upToSeq'];
      return (204, null);
    }
    final partyCall = RegExp(r'^parties/([^/]+)(/[a-z]+)?$').firstMatch(call.path);
    if (partyCall != null) {
      final id = partyCall.group(1)!;
      switch ((call.method, partyCall.group(2))) {
        case ('POST', '/invites'):
          final invited = party!['invited'] as List<Map<String, dynamic>>;
          for (final userId in call.body['userIds'] as List<dynamic>) {
            invited.add(people.values.firstWhere((person) => person['userId'] == userId));
          }
          return (200, party);
        case ('POST', '/join'):
          final invite = partyInvites.where((invite) => invite['partyId'] == id).firstOrNull;
          if (invite == null) return problem(404, 'not_found');
          if (invite['full'] == true) return problem(409, 'full', 'The party is full');
          partyInvites.remove(invite);
          final from = invite['from'] as Map<String, dynamic>;
          final joined = inParty([from], leader: from['userId'] as String);
          joined['id'] = id;
          return (200, joined);
        case ('POST', '/decline'):
          partyInvites.removeWhere((invite) => invite['partyId'] == id);
          return (204, null);
        case ('POST', '/leave'):
          party = null;
          return (204, null);
        case ('POST', '/kick'):
          (party!['members'] as List<Map<String, dynamic>>).removeWhere(
            (member) => member['userId'] == call.body['userId'],
          );
          return (204, null);
        case ('PATCH', null):
          party!['privacy'] = call.body['privacy'];
          return (200, party);
      }
    }
    final callAction = RegExp(r'^calls/([^/]+)/(leave|mute)$').firstMatch(call.path);
    if (call.method == 'POST' && callAction != null) return (204, null);
    final teach = RegExp(r'^games/([A-Z]{4}[0-9]{5})$').firstMatch(call.path);
    if (call.method == 'PUT' && teach != null) {
      games[teach.group(1)!] = call.body;
      return (200, {'titleId': teach.group(1)});
    }
    final set = RegExp(r'^trophy-sets/([A-Z]{4}[0-9]{5})/([A-Za-z0-9._-]+)$').firstMatch(call.path);
    if (call.method == 'PUT' && set != null) {
      trophySets['${set.group(1)}/${set.group(2)}'] = call.body;
      return (200, {'stored': true});
    }
    final reply = RegExp(r'^me/friends/requests/([^/]+)/(accept|decline)$').firstMatch(call.path);
    if (call.method == 'POST' && reply != null) {
      final asking = incoming.where((person) => person['userId'] == reply.group(1)).firstOrNull;
      if (asking == null) return problem(404, 'not_found');
      incoming.remove(asking);
      if (reply.group(2) == 'accept') {
        friends.add({
          ...asking,
          'presence': {'state': 'online'},
        });
      }
      return (204, null);
    }
    final unfriend = RegExp(r'^me/friends/([^/]+)$').firstMatch(call.path);
    if (call.method == 'DELETE' && unfriend != null) {
      friends.removeWhere((friend) => friend['userId'] == unfriend.group(1));
      return (204, null);
    }
    return problem(404, 'not_found', 'No route for ${call.method} ${call.path}');
  }

  void _socket(WebSocket socket) {
    sockets.add(socket);
    socket.listen((data) {
      if (data is! String) return;
      final frame = jsonDecode(data) as Map<String, dynamic>;
      if (_frameAdded.isClosed) return;
      if (frame['op'] == 'hello') {
        if (!validAccess.contains(frame['token'])) {
          socket.close(4001);
          return;
        }
        _sessions++;
        socket.add(jsonEncode({'op': 'ready', 'session': 'session-$_sessions', 'heartbeat': heartbeatSeconds}));
      }
      frames.add(frame);
      // A socket still talking while the server shuts down at the end of a test.
      if (!_frameAdded.isClosed) _frameAdded.add(frame);
    }, onDone: () => sockets.remove(socket));
  }
}
