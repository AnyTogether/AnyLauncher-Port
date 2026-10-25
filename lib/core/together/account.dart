import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'notifier.dart';
import 'token_store.dart';

export 'token_store.dart' show TogetherUser;

/// An error AnyTogether answered with: RFC 9457 problem details with a stable code.
class TogetherProblem implements Exception {
  const TogetherProblem(this.status, this.code, this.title, {this.extra = const {}});

  final int status;
  final String code;
  final String title;

  /// The problem's other members (a profile section, when a handle may change again).
  final Map<String, dynamic> extra;

  @override
  String toString() => title;
}

/// Waiting for an approval was given up.
class TogetherCancelled implements Exception {
  const TogetherCancelled();
}

/// A sign-in someone else approves: the phone, or another launcher.
class Handoff {
  const Handoff(this.id, this.secret);

  final String id;
  final String secret;
}

/// Where the sign-in is.
sealed class SignInStep {
  const SignInStep();
}

class SignInIdle extends SignInStep {
  const SignInIdle();
}

class SignInBusy extends SignInStep {
  const SignInBusy();
}

/// A code went to [email]; it is typed in next.
class SignInCodeSent extends SignInStep {
  const SignInCodeSent(this.email);

  final String email;
}

/// A code to type on the website; [page] opens it with the code filled in.
class SignInDeviceCode extends SignInStep {
  const SignInDeviceCode(this.userCode, this.page);

  final String userCode;
  final Uri page;
}

/// Waiting for [phone], signed in to AnyTogether, to approve this launcher.
class SignInWaitingForPhone extends SignInStep {
  const SignInWaitingForPhone(this.phone, this.handoff);

  final String phone;
  final Handoff handoff;
}

/// The launcher's AnyTogether account: signing in with an email code, a code approved on the
/// website (where passkeys work) or the paired phone; the session kept in [store] with the
/// access token refreshed on its own; approving a phone's sign-in.
class TogetherAccount with Notifier {
  TogetherAccount({required this.base, required this.store, required this.clientName, this.pollEvery});

  /// The server in use.
  Uri base;
  final TokenStore store;

  /// The AnyTogether-Client header: launcher-windows/0.1.0 (Windows 10.0).
  final String clientName;

  /// How often an approval is asked for; null takes the server's interval (tests go faster).
  final Duration? pollEvery;

  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  TogetherUser? user;
  SignInStep step = const SignInIdle();
  String? _access;
  DateTime _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  String? _refresh;

  /// The tokens held now, taken out of a crash report wherever they appear.
  List<String> get secrets => [?_access, ?_refresh];

  Future<String>? _refreshing;
  int _waiting = 0;

  bool get signedIn => user != null;

  /// The session kept from the last run, if there is one.
  Future<void> restore() async {
    final saved = await store.load();
    if (saved == null) return;
    _access = saved.accessToken;
    _accessExpiry = saved.accessExpiry;
    _refresh = saved.refreshToken;
    user = saved.user;
    notifyListeners();
  }

  void _setStep(SignInStep next) {
    step = next;
    notifyListeners();
  }

  // Signing in.

  Future<void> startEmail(String email) async {
    _setStep(const SignInBusy());
    try {
      await _send('POST', 'auth/email/start', {'email': email.trim()});
      _setStep(SignInCodeSent(email.trim()));
    } on Object {
      _setStep(const SignInIdle());
      rethrow;
    }
  }

  Future<TogetherUser> verifyEmail(String code) async {
    final sent = step;
    if (sent is! SignInCodeSent) throw const TogetherProblem(400, 'code_invalid', 'No code was sent');
    return _keep(await _send('POST', 'auth/email/verify', {'email': sent.email, 'code': code}));
  }

  /// A code for the website: [show] gets the page with the code in it (the launcher opens it in
  /// the browser), then this waits until it is approved there.
  Future<TogetherUser> signInWithWebsite(String deviceName, {void Function(Uri page)? show}) async {
    _setStep(const SignInBusy());
    final mine = ++_waiting;
    final Map<String, dynamic> device;
    try {
      device = await _send('POST', 'auth/device', {'deviceName': deviceName});
    } on Object {
      if (_waiting == mine) _setStep(const SignInIdle());
      rethrow;
    }
    if (_waiting != mine) throw const TogetherCancelled();
    final code = device['userCode'] as String;
    final verification = Uri.parse(device['verificationUri'] as String);
    final page = verification.replace(queryParameters: {...verification.queryParameters, 'code': code});
    _setStep(SignInDeviceCode(code, page));
    show?.call(page);
    return _poll(
      {'grantType': 'device_code', 'deviceCode': device['deviceCode']},
      every: pollEvery ?? Duration(seconds: (device['interval'] as num? ?? 5).toInt()),
      within: Duration(seconds: (device['expiresIn'] as num? ?? 600).toInt()),
      mine: mine,
    );
  }

  /// A hand-off for [phone] to approve; the caller tells the phone its id, then waits with
  /// [waitForPhone].
  Future<Handoff> startHandoff(String deviceName, String phone) async {
    _setStep(const SignInBusy());
    try {
      final json = await _send('POST', 'auth/handoff/start', {'deviceName': deviceName});
      final handoff = Handoff(json['handoffId'] as String, json['secret'] as String);
      _setStep(SignInWaitingForPhone(phone, handoff));
      return handoff;
    } on Object {
      _setStep(const SignInIdle());
      rethrow;
    }
  }

  Future<TogetherUser> waitForPhone(Handoff handoff) => _poll(
    {'grantType': 'handoff', 'handoffId': handoff.id, 'secret': handoff.secret},
    every: pollEvery ?? const Duration(seconds: 2),
    within: const Duration(minutes: 5),
    mine: ++_waiting,
  );

  /// Asks until the sign-in is approved, refused, given up with [cancel] or out of time.
  Future<TogetherUser> _poll(
    Map<String, dynamic> grant, {
    required Duration every,
    required Duration within,
    required int mine,
  }) async {
    final deadline = DateTime.now().add(within);
    var wait = every;
    while (DateTime.now().isBefore(deadline)) {
      if (_waiting != mine) throw const TogetherCancelled();
      try {
        final json = await _send('POST', 'auth/token', grant);
        if (_waiting != mine) throw const TogetherCancelled();
        return _keep(json);
      } on TogetherProblem catch (problem) {
        if (problem.code != 'authorization_pending' && problem.code != 'slow_down') {
          if (_waiting == mine) _setStep(const SignInIdle());
          rethrow;
        }
        if (problem.code == 'slow_down') wait += const Duration(seconds: 5);
        await Future<void>.delayed(wait);
      }
    }
    if (_waiting == mine) _setStep(const SignInIdle());
    throw const TogetherProblem(400, 'expired_token', 'The sign-in was not approved in time');
  }

  /// Stops waiting for an approval and goes back to the start.
  void cancel() {
    _waiting++;
    _setStep(const SignInIdle());
  }

  /// Signs in the device that started this hand-off (the phone) as us.
  Future<void> approveHandoff(String id) => _authorized('POST', 'auth/handoff/$id/approve');

  Future<void> signOut() async {
    if (user == null) return;
    try {
      await _authorized('POST', 'auth/logout');
    } on Object {
      // Signed out here whatever the server says.
    }
    await _forget();
  }

  /// The session ended on another device or the website: forgotten here too.
  Future<void> signedOutElsewhere() => _forget();

  Future<void> _forget() async {
    user = null;
    _access = null;
    _refresh = null;
    _waiting++;
    step = const SignInIdle();
    notifyListeners();
    await store.save(null);
  }

  /// The kept user changed (a new name or handle on the profile); the tokens stay.
  void updateUser(TogetherUser next) {
    if (user == null) return;
    user = next;
    unawaited(_persist());
    notifyListeners();
  }

  TogetherUser _keep(Map<String, dynamic> json) {
    _access = json['accessToken'] as String;
    _accessExpiry = DateTime.now().add(Duration(seconds: (json['expiresIn'] as num).toInt()));
    _refresh = json['refreshToken'] as String;
    user = TogetherUser.fromJson(json['user'] as Map<String, dynamic>);
    unawaited(_persist());
    step = const SignInIdle();
    notifyListeners();
    return user!;
  }

  Future<void> _persist() async {
    final access = _access;
    final refresh = _refresh;
    final who = user;
    if (access == null || refresh == null || who == null) return;
    await store.save(SavedSession(accessToken: access, accessExpiry: _accessExpiry, refreshToken: refresh, user: who));
  }

  // Calls.

  /// A signed-in call to AnyTogether's API, JSON both ways.
  Future<Map<String, dynamic>> call(String method, String path, [Map<String, dynamic>? body]) =>
      _authorized(method, path, body);

  /// The access token for the realtime gateway; [renew] refreshes it first, after the gateway
  /// turned it down.
  Future<String> accessToken({bool renew = false}) {
    if (renew) _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
    return _accessToken();
  }

  /// The access token, refreshed first when it is about to expire; one refresh at a time.
  Future<String> _accessToken() async {
    final access = _access;
    if (access == null || _refresh == null) throw const TogetherProblem(401, 'unauthorized', 'Not signed in');
    if (_accessExpiry.difference(DateTime.now()) > const Duration(seconds: 30)) return access;
    return _refreshing ??= _refreshNow().whenComplete(() => _refreshing = null);
  }

  Future<String> _refreshNow() async {
    try {
      final json = await _send('POST', 'auth/token', {'grantType': 'refresh_token', 'refreshToken': _refresh});
      _keep(json);
      return _access!;
    } on TogetherProblem catch (problem) {
      if (problem.status == 400 || problem.status == 401) await _forget();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _authorized(String method, String path, [Map<String, dynamic>? body]) async {
    try {
      return await _send(method, path, body, token: await _accessToken());
    } on TogetherProblem catch (problem) {
      if (problem.status != 401 || _refresh == null) rethrow;
      _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
      return _send(method, path, body, token: await _accessToken());
    }
  }

  Future<Map<String, dynamic>> _send(String method, String path, Map<String, dynamic>? body, {String? token}) async {
    final request = await _http.openUrl(
      method,
      Uri.parse('${base.toString().replaceAll(RegExp(r'/+$'), '')}/api/v1/$path'),
    );
    request.headers
      ..set('AnyTogether-Client', clientName)
      ..set(HttpHeaders.acceptHeader, 'application/json');
    if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decodeStream(response);
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (json is Map<String, dynamic> && json['code'] is String) {
        throw TogetherProblem(response.statusCode, json['code'] as String, json['title'] as String? ?? '', extra: json);
      }
      throw TogetherProblem(response.statusCode, 'internal', 'AnyTogether answered ${response.statusCode}');
    }
    return json is Map<String, dynamic> ? json : const {};
  }

  void close() => _http.close(force: true);
}
