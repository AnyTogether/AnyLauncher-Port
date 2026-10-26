import 'dart:async';
import 'dart:io';

import 'browser_pad_access.dart';
import 'browser_pad_input.dart';
import 'paired_devices.dart';
import 'remote_protocol.dart';

/// Play from a browser (the macOS launcher's BrowserPadServer.swift): a phone with no app scans
/// the launcher's QR code and its browser becomes a pad. The server listens on the computer's
/// local network address only, hands out the page (assets/browser_pad/index.html, the same file
/// as the Mac's), turns the QR code's one-time token into a session cookie and takes the page's
/// WebSocket. Each browser then goes through the phone server exactly as the phone app does, on
/// a loopback control channel of its own: the same hello and pairing card, the same seats
/// (players 2 to 4 after the first), the same pad packets to the game and the game's vibration
/// and light bar back.
class BrowserPadServer {
  BrowserPadServer({
    required this.host,
    required this.page,
    required this.controlPort,
    this.port = 0,
    BrowserPadAccess? access,
    this.devices,
    Map<String, int> Function()? players,
    void Function()? changed,
  }) : access = access ?? BrowserPadAccess(),
       _players = players ?? (() => const {}),
       _changed = changed ?? (() {});

  /// The port tried first, so a phone that saved the page finds it again.
  static const preferredPort = 47710;

  final String host;
  final List<int> page;
  final int controlPort;
  final int port;
  final BrowserPadAccess access;
  final PairedDevices? devices;
  final Map<String, int> Function() _players;
  final void Function() _changed;

  HttpServer? _http;
  Timer? _timer;
  int _ticks = 0;
  final List<_Link> _links = [];

  /// Page loads and WebSocket opens per peer address, and token tries per peer address.
  final _requests = RateLimiter(capacity: 30, perSecond: 2);
  final _tokenTries = RateLimiter(capacity: 5, perSecond: 0.1);

  /// Starts on [preferredPort], else a port the system picks.
  static Future<BrowserPadServer> startPreferred({
    required String host,
    required List<int> page,
    required int controlPort,
    PairedDevices? devices,
    Map<String, int> Function()? players,
    void Function()? changed,
  }) async {
    for (final port in const [preferredPort, 0]) {
      final server = BrowserPadServer(
        host: host,
        page: page,
        controlPort: controlPort,
        port: port,
        devices: devices,
        players: players,
        changed: changed,
      );
      try {
        await server.start();
        return server;
      } on SocketException {
        await server.stop();
      }
    }
    throw const SocketException('the browser pad server did not start');
  }

  Future<void> start() async {
    // Browser pads a launcher that quit left among the allowed phones are of no use now.
    for (final device in devices?.all ?? const <PairedDevice>[]) {
      if (device.id.startsWith(BrowserPadAccess.devicePrefix)) devices?.remove(device.id);
    }
    final http = await HttpServer.bind(InternetAddress(host, type: InternetAddressType.IPv4), port);
    http.defaultResponseHeaders.clear();
    http.idleTimeout = const Duration(seconds: 10);
    _http = http;
    http.listen(_request, onError: (_) {});
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) => _tick());
  }

  /// Stops: every browser is let go, every session ends and the port is free again.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    for (final link in List.of(_links)) {
      await link.close();
    }
    _links.clear();
    for (final session in access.endAll()) {
      devices?.remove(session.deviceId);
    }
    await _http?.close(force: true);
    _http = null;
  }

  int? get boundPort => _http?.port;

  /// The QR code's link: this server and the current one-time token.
  Uri? get pairingUrl {
    final bound = boundPort;
    if (bound == null) return null;
    return Uri.parse('http://$host:$bound/?t=${access.currentToken().value}');
  }

  /// The browsers with an open page now: name, device ID, and whether the launcher let it in.
  List<(String, String, bool)> get connected => [
    for (final link in _links)
      if (access.session(link.sessionId) case final session?) (session.name, session.deviceId, link.padSession != null),
  ]..sort((a, b) => a.$2.compareTo(b.$2));

  /// The computer's address on the local network: a private IPv4 address of Wi-Fi or Ethernet.
  static Future<String?> lanAddress() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } on Object {
      return null;
    }
    const virtual = ['docker', 'veth', 'br-', 'virbr', 'vmnet', 'vboxnet', 'tun', 'tap', 'zt', 'tailscale', 'wg', 'lo'];
    final found = <(String, String)>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (virtual.any(name.startsWith) || name.contains('virtual') || name.contains('vethernet')) continue;
      for (final address in interface.addresses) {
        final text = address.address;
        if (address.isLoopback || text.startsWith('169.254.') || !BrowserPadAccess.isLocal(text)) continue;
        found.add((name, text));
      }
    }
    int rank((String, String) entry) {
      final name = entry.$1;
      if (name.startsWith('wl') || name.contains('wi-fi') || name.contains('wlan')) return 0;
      if (name.startsWith('en') || name.startsWith('eth') || name.contains('ethernet')) return 1;
      return 2;
    }

    found.sort((a, b) => rank(a).compareTo(rank(b)));
    return found.isEmpty ? null : found.first.$2;
  }

  // HTTP.

  Future<void> _request(HttpRequest request) async {
    final response = request.response;
    final peer = request.connectionInfo?.remoteAddress.address ?? '';
    // Local network only, whatever reaches the address.
    if (!BrowserPadAccess.isLocal(peer)) {
      await _respond(response, HttpStatus.forbidden);
      return;
    }
    if (!_requests.allow(peer)) {
      response.headers.set('Retry-After', '5');
      await _respond(response, HttpStatus.tooManyRequests);
      return;
    }
    if (request.method != 'GET') {
      await _respond(response, HttpStatus.methodNotAllowed);
      return;
    }
    final bound = boundPort;
    if (bound == null) return;
    final socket = request.uri.path == '/ws';
    if (!BrowserPadAccess.allowed(
      origin: request.headers.value('origin'),
      host: request.headers.value('host'),
      serverHost: host,
      port: bound,
      requireOrigin: socket,
    )) {
      await _respond(response, HttpStatus.forbidden);
      return;
    }
    switch (request.uri.path) {
      case '/':
        final token = request.uri.queryParameters['t'];
        if (token != null) {
          // A few scans at once, then one every ten seconds: no guessing tokens.
          if (!_tokenTries.allow(peer)) {
            response.headers.set('Retry-After', '10');
            await _respond(response, HttpStatus.tooManyRequests);
            return;
          }
          final session = access.redeem(
            token,
            deviceName: BrowserPadAccess.deviceName(request.headers.value('user-agent')),
          );
          if (session != null) {
            _changed();
            // The token leaves the address bar (and the history) at once.
            response.headers
              ..set('Location', '/')
              ..set('Set-Cookie', BrowserPadAccess.setCookie(session))
              ..set('Cache-Control', 'no-store');
            await _respond(response, HttpStatus.seeOther);
            return;
          }
        }
        response.headers
          ..set('Content-Type', 'text/html; charset=utf-8')
          ..set('Cache-Control', 'no-store')
          ..set('X-Content-Type-Options', 'nosniff')
          ..set('X-Frame-Options', 'DENY')
          ..set('Referrer-Policy', 'no-referrer')
          ..set(
            'Content-Security-Policy',
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; "
                "connect-src ws://$host:$bound; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
          );
        response.statusCode = HttpStatus.ok;
        response.add(page);
        await response.close();
      case '/ws':
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          await _respond(response, HttpStatus.upgradeRequired);
          return;
        }
        final session = access.sessionForCookie(request.headers.value('cookie'));
        if (session == null) {
          await _respond(response, HttpStatus.forbidden);
          return;
        }
        final WebSocket page;
        try {
          page = await WebSocketTransformer.upgrade(request);
        } on Object {
          return;
        }
        _open(page, session);
      default:
        await _respond(response, HttpStatus.notFound);
    }
  }

  Future<void> _respond(HttpResponse response, int status) async {
    response
      ..statusCode = status
      ..headers.set('Content-Type', 'text/plain; charset=utf-8')
      ..write('$status\n');
    try {
      await response.close();
    } on Object {
      // The peer went.
    }
  }

  void _open(WebSocket page, BrowserPadSession session) {
    // One page per session: a reload takes over from the page it replaces.
    for (final other in List.of(_links)) {
      if (other.sessionId == session.id) unawaited(other.close());
    }
    access.setConnected(session.id, true);
    final link = _Link(this, page, session);
    _links.add(link);
    _changed();
    final messages = RateLimiter(capacity: 120, perSecond: 120);
    page.listen(
      (data) {
        if (data is! String || !messages.allow('page')) return;
        final message = BrowserPadMessage.parse(data);
        if (message != null) link.heard(message);
      },
      onDone: () => _ended(link),
      onError: (_) => _ended(link),
      cancelOnError: true,
    );
    unawaited(link.connect());
  }

  void _ended(_Link link) {
    if (!_links.remove(link)) return;
    unawaited(link.close());
    // A reload's new page may hold the session already.
    if (!_links.any((other) => other.sessionId == link.sessionId)) access.setConnected(link.sessionId, false);
    _changed();
  }

  void _tick() {
    final now = DateTime.now();
    for (final link in List.of(_links)) {
      link.tick(now);
    }
    if (++_ticks % 200 == 0) {
      for (final session in access.expireIdle()) {
        devices?.remove(session.deviceId);
      }
    }
  }
}

/// A browser's place on the phone server: a loopback control channel that says hello as the
/// phone app does, and the pad it relays.
class _Link {
  _Link(this.server, this.page, BrowserPadSession session)
    : sessionId = session.id,
      deviceId = session.deviceId,
      name = session.name;

  final BrowserPadServer server;
  final WebSocket page;
  final String sessionId;
  final String deviceId;
  final String name;
  WebSocket? _remote;

  /// The pad packets' session, once the phone server welcomed this browser.
  int? padSession;
  int _sequence = 0;
  BrowserPadState? _state;
  DateTime _heardAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _neutralSent = true;
  String? _lastOutput;
  int? _player;
  DateTime _playerCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _ended = false;
  Timer? _retry;

  void _toPage(String text) {
    try {
      page.add(text);
    } on Object {
      // Closing.
    }
  }

  Future<void> connect() async {
    if (_ended) return;
    _toPage(BrowserPadReply.wait());
    final WebSocket remote;
    try {
      remote = await WebSocket.connect('ws://127.0.0.1:${server.controlPort}/');
    } on Object {
      _scheduleRetry(const Duration(seconds: 2));
      return;
    }
    if (_ended) {
      await remote.close();
      return;
    }
    _remote = remote;
    remote.listen(
      (data) {
        if (!identical(remote, _remote)) return;
        if (data is List<int>) {
          _output(data);
        } else if (data is String) {
          final message = RemoteMessage.decode(data);
          if (message != null) _fromPhoneServer(message);
        }
      },
      onDone: () => _remoteEnded(remote),
      onError: (_) => _remoteEnded(remote),
      cancelOnError: true,
    );
    _tell(
      RemoteHello(
        protocol: RemoteMessage.protocolVersion,
        deviceId: deviceId,
        deviceName: name,
        key: server.access.session(sessionId)?.key,
      ),
    );
  }

  void _scheduleRetry(Duration after) {
    if (_ended) return;
    _retry?.cancel();
    _retry = Timer(after, () => unawaited(connect()));
  }

  void _fromPhoneServer(RemoteMessage message) {
    switch (message) {
      case RemotePairing(:final code):
        _toPage(BrowserPadReply.pairing(code));
        server._changed();
      case RemoteWelcome(:final session, :final macName, :final key):
        padSession = session.toUnsigned(64).toSigned(64).toInt();
        server.access.setKey(sessionId, key);
        _toPage(BrowserPadReply.welcome(macName));
        _player = null;
        _playerCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
        server._changed();
      case RemoteRejected(:final reason):
        padSession = null;
        // The phone server closes the channel after this; that end is no failure.
        _remote = null;
        if (reason == 'busy') {
          // Every seat taken, or another phone being asked about: try again shortly.
          _toPage(BrowserPadReply.busy());
          _scheduleRetry(const Duration(seconds: 3));
        } else {
          _toPage(BrowserPadReply.rejected(reason));
          _ended = true;
          if (reason == 'denied') {
            // Not allowed: this session is over, the QR code has to be scanned again.
            server.access.end(sessionId);
            server.devices?.remove(deviceId);
          }
          Timer(const Duration(milliseconds: 300), () => unawaited(page.close(4001)));
        }
      case RemoteLook(:final deep, :final middle, :final accent):
        _toPage(BrowserPadReply.look(deep, middle, accent));
      default:
        break;
    }
  }

  void _remoteEnded(WebSocket remote) {
    if (_ended || !identical(remote, _remote)) return;
    _remote = null;
    final wasWelcomed = padSession != null;
    padSession = null;
    // The phone server went away (the launcher restarting it): try again.
    if (wasWelcomed) _toPage(BrowserPadReply.wait());
    _scheduleRetry(const Duration(seconds: 2));
  }

  void _output(List<int> packet) {
    final reply = BrowserPadReply.output(packet);
    if (reply == null || reply == _lastOutput) return;
    _lastOutput = reply;
    _toPage(reply);
  }

  void _tell(RemoteMessage message) {
    try {
      _remote?.add(message.text);
    } on Object {
      // Closing.
    }
  }

  void _sendPad(BrowserPadState pad) {
    final session = padSession;
    if (session == null) return;
    _sequence = (_sequence + 1) & 0xFFFFFFFF;
    final now = DateTime.now();
    try {
      _remote?.add(pad.packet(sequence: _sequence, sentMicros: now.microsecondsSinceEpoch, session: session));
    } on Object {
      // Closing.
    }
    _sentAt = now;
    _neutralSent = pad.neutral;
  }

  /// What the page said.
  void heard(BrowserPadMessage message) {
    _heardAt = DateTime.now();
    switch (message) {
      case BrowserPadInput(:final state):
        _state = state;
        _sendPad(state);
      case BrowserPadButton(:final name):
        if (padSession != null) _tell(name == 'ps' ? const RemoteHome() : const RemoteCommand('capture'));
      case BrowserPadPing(:final at):
        _toPage(BrowserPadReply.pong(at));
      case BrowserPadLatency(:final milliseconds):
        if (padSession != null) _tell(RemoteLatency(milliseconds));
    }
  }

  /// Every 150 ms: the pad again while the page is there (the engine lets a pad go after 500 ms
  /// of silence), released once the page has gone quiet; the player now and then.
  void tick(DateTime now) {
    if (padSession == null) return;
    final state = _state;
    if (state != null && now.difference(_heardAt) < const Duration(milliseconds: 600)) {
      if (now.difference(_sentAt) >= const Duration(milliseconds: 140)) _sendPad(state);
    } else if (!_neutralSent) {
      _state = null;
      _sendPad(BrowserPadState());
    }
    if (now.difference(_playerCheckedAt) >= const Duration(milliseconds: 500)) {
      _playerCheckedAt = now;
      final number = server._players()[deviceId] ?? 0;
      if (number != _player) {
        _player = number;
        _toPage(BrowserPadReply.player(number));
      }
    }
  }

  Future<void> close() async {
    if (!_ended) {
      _ended = true;
      _retry?.cancel();
      if (padSession != null) _sendPad(BrowserPadState());
    }
    final remote = _remote;
    _remote = null;
    // The neutral pad goes out before the channel closes.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      await remote?.close();
    } on Object {
      // Gone already.
    }
    try {
      await page.close();
    } on Object {
      // Gone already.
    }
  }
}
