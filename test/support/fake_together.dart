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
