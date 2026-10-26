import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The QR code's one-time token.
class BrowserPadToken {
  const BrowserPadToken(this.value, this.expires);
  final String value;
  final DateTime expires;

  @override
  bool operator ==(Object other) => other is BrowserPadToken && other.value == value && other.expires == expires;

  @override
  int get hashCode => Object.hash(value, expires);
}

/// A browser that redeemed a token: its cookie, the device ID and name it pairs with, and the key
/// the launcher gave it once allowed.
class BrowserPadSession {
  BrowserPadSession({required this.id, required this.deviceId, required this.name, required this.lastSeen});
  final String id;
  final String deviceId;
  final String name;
  String? key;
  DateTime lastSeen;

  /// Connected now (its socket is open), so it does not expire.
  bool connected = false;
}

/// Who may use the browser pad (the macOS launcher's BrowserPadAccess.swift): the QR code's
/// one-time token, the session cookie a redeemed token turns into, the origin and host a request
/// must name, and which peers count as the local network. No sockets here.
class BrowserPadAccess {
  BrowserPadAccess({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The QR code's link stays good this long, and for one phone only.
  static const tokenLifetime = Duration(seconds: 120);

  /// A browser session ends this long after it was last connected.
  static const sessionIdle = Duration(minutes: 30);

  /// At most this many browsers hold a session at a time; the oldest idle one gives way.
  static const maxSessions = 8;
  static const cookieName = 'anyps5_pad';

  /// Device IDs of browser pads in the paired devices start with this.
  static const devicePrefix = 'browser-';

  final DateTime Function() _clock;
  BrowserPadToken? _token;
  final Map<String, BrowserPadSession> _sessions = {};
  static final _random = Random.secure();

  /// The QR code's token: the current one while it is good, else a new one.
  BrowserPadToken currentToken() {
    final token = _token;
    if (token != null && token.expires.isAfter(_clock())) return token;
    return _token = BrowserPadToken(random(18), _clock().add(tokenLifetime));
  }

  /// A new token now, the old one no longer good.
  BrowserPadToken renewToken() {
    _token = null;
    return currentToken();
  }

  /// Trades a good token for a new session, once: the token is spent whatever happens next.
  BrowserPadSession? redeem(String value, {required String deviceName}) {
    final token = _token;
    if (token == null || !token.expires.isAfter(_clock()) || !same(token.value, value)) return null;
    _token = null;
    expireIdle();
    if (_sessions.length >= maxSessions) {
      final idle = _sessions.values.where((session) => !session.connected).toList()
        ..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
      if (idle.isNotEmpty) _sessions.remove(idle.first.id);
    }
    if (_sessions.length >= maxSessions) return null;
    final session = BrowserPadSession(
      id: random(24),
      deviceId: devicePrefix + random(8, hex: true),
      name: deviceName,
      lastSeen: _clock(),
    );
    return _sessions[session.id] = session;
  }

  /// The session a request's Cookie header carries, null when it has none or it ended.
  BrowserPadSession? sessionForCookie(String? header) {
    final id = cookie(cookieName, header);
    if (id == null) return null;
    expireIdle();
    for (final session in _sessions.values) {
      if (same(session.id, id)) return session;
    }
    return null;
  }

  BrowserPadSession? session(String id) => _sessions[id];

  List<BrowserPadSession> get all => List.unmodifiable(_sessions.values);

  void setKey(String id, String key) => _sessions[id]?.key = key;

  void setConnected(String id, bool connected) {
    final session = _sessions[id];
    if (session == null) return;
    session
      ..connected = connected
      ..lastSeen = _clock();
  }

  /// Ends a session (the launcher said no); returns it.
  BrowserPadSession? end(String id) => _sessions.remove(id);

  /// Ends every session and the token; returns the sessions that were.
  List<BrowserPadSession> endAll() {
    final ended = List.of(_sessions.values);
    _sessions.clear();
    _token = null;
    return ended;
  }

  /// Sessions idle for longer than [sessionIdle] that just ended.
  List<BrowserPadSession> expireIdle() {
    final now = _clock();
    final ended = [
      for (final session in _sessions.values)
        if (!session.connected && now.difference(session.lastSeen) > sessionIdle) session,
    ];
    for (final session in ended) {
      _sessions.remove(session.id);
    }
    return ended;
  }

  /// The Set-Cookie header value for a session: HttpOnly, SameSite=Strict, this site only.
  static String setCookie(BrowserPadSession session) =>
      '$cookieName=${session.id}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${sessionIdle.inSeconds * 24}';

  /// Whether a request names this server: Host must be the address and port it listens on (no
  /// other name, so a rebound DNS name gets nowhere), and Origin, when there is one (a WebSocket
  /// always has one: [requireOrigin]), must be this same site over http.
  static bool allowed({
    required String? origin,
    required String? host,
    required String serverHost,
    required int port,
    required bool requireOrigin,
  }) {
    final site = '$serverHost:$port'.toLowerCase();
    if (host == null || host.trim().toLowerCase() != site) return false;
    if (origin == null) return !requireOrigin;
    return origin.trim().toLowerCase() == 'http://$site';
  }

  /// Whether a peer's address is on the local network: private IPv4 (10/8, 172.16/12,
  /// 192.168/16), link-local (169.254/16), loopback, or the IPv6 equivalents.
  static bool isLocal(String address) {
    var text = address.split('%').first;
    if (text.toLowerCase().startsWith('::ffff:')) text = text.substring(7);
    final parsed = InternetAddress.tryParse(text);
    if (parsed == null) return false;
    final bytes = parsed.rawAddress;
    if (parsed.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          bytes[0] == 127 ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 169 && bytes[1] == 254) ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31);
    }
    if (parsed.isLoopback) return true;
    // fe80::/10 link-local, fc00::/7 unique local.
    return (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) || bytes[0] & 0xFE == 0xFC;
  }

  /// A short name for the browser's device from its User-Agent, as the pairing card shows it.
  static String deviceName(String? userAgent) {
    final agent = userAgent ?? '';
    final String device;
    if (agent.contains('iPad')) {
      device = 'iPad';
    } else if (agent.contains('iPhone') || agent.contains('iPod')) {
      device = 'iPhone';
    } else if (agent.contains('Android')) {
      device = 'Android';
    } else if (agent.contains('Macintosh') && agent.contains('Mobile')) {
      device = 'iPad';
    } else {
      device = 'Phone';
    }
    return '$device · Web';
  }

  /// A cookie's value in a Cookie header.
  static String? cookie(String name, String? header) {
    if (header == null) return null;
    for (final part in header.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      if (part.substring(0, index).trim() == name) {
        final value = part.substring(index + 1).trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  /// Compares secrets in time that does not depend on where they differ.
  static bool same(String a, String b) {
    final left = utf8.encode(a), right = utf8.encode(b);
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  static String random(int count, {bool hex = false}) {
    final bytes = List.generate(count, (_) => _random.nextInt(256));
    if (hex) return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

/// A token bucket per key (a peer's address): [capacity] at once, refilled at [perSecond].
class RateLimiter {
  RateLimiter({required this.capacity, required this.perSecond, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final double capacity;
  final double perSecond;
  final DateTime Function() _clock;
  final Map<String, (double, DateTime)> _buckets = {};

  /// Takes one from the key's bucket; false (and nothing taken) when it is empty.
  bool allow(String key) {
    final now = _clock();
    final (tokens, at) = _buckets[key] ?? (capacity, now);
    final filled = min(capacity, tokens + now.difference(at).inMicroseconds / 1e6 * perSecond);
    final allowed = filled >= 1;
    _buckets[key] = (allowed ? filled - 1 : filled, now);
    if (_buckets.length > 256) {
      _buckets.removeWhere((_, bucket) => now.difference(bucket.$2) > const Duration(minutes: 1));
    }
    return allowed;
  }
}
