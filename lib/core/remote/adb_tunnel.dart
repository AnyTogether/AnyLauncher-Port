import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Android phones on a cable reach the launcher without Wi-Fi when adb is installed and the
/// phone allows USB debugging: adb forwards a port on the computer to the phone app's port 47702,
/// and the launcher joins each connection there to its own phone server. The phone then speaks
/// the WebSocket protocol over it, its pad as binary frames. The Dart form of the macOS
/// launcher's AdbTunnel.swift.
class AdbTunnel {
  AdbTunnel({
    required this.adb,
    required this.targetPort,
    this.phonePort = 47702,
    this.interval = const Duration(seconds: 3),
    this.retry = const Duration(seconds: 2),
    this.changed,
  });

  final String adb;

  /// The launcher's own phone server port.
  final int targetPort;

  /// The port the phone app listens on.
  final int phonePort;
  final Duration interval;
  final Duration retry;

  /// The serials of the phones joined, whenever that changes.
  final void Function(List<String> serials)? changed;

  bool _running = false;
  Timer? _look;
  final Map<String, int> _forwarded = {};
  final Map<String, (Socket, Socket)> _joined = {};
  final Set<String> _reported = {};

  /// adb where the Android SDK puts it on Windows and Linux, or on the PATH.
  static Future<String?> locate({Map<String, String>? environment, bool? windows}) async {
    final env = environment ?? Platform.environment;
    final isWindows = windows ?? Platform.isWindows;
    final name = isWindows ? 'adb.exe' : 'adb';
    final home = env[isWindows ? 'USERPROFILE' : 'HOME'];
    final candidates = <String>[
      for (final variable in ['ANDROID_HOME', 'ANDROID_SDK_ROOT'])
        if (env[variable] case final String root when root.isNotEmpty) p.join(root, 'platform-tools', name),
      if (isWindows && env['LOCALAPPDATA'] != null)
        p.join(env['LOCALAPPDATA']!, 'Android', 'Sdk', 'platform-tools', name),
      if (!isWindows && home != null) p.join(home, 'Android', 'Sdk', 'platform-tools', name),
      if (!isWindows) '/usr/bin/adb',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    try {
      final result = await Process.run(isWindows ? 'where' : 'which', [name]);
      final found = (result.stdout as String).split(RegExp(r'\r?\n')).first.trim();
      if (result.exitCode == 0 && found.isNotEmpty) return found;
    } on ProcessException {
      // Neither tool: no adb.
    }
    return null;
  }

  /// The serials of the phones ready in `adb devices` output; unauthorized ones are left out.
  static List<String> devices(String listing) => [
    for (final line in listing.split(RegExp(r'\r?\n')))
      if (line.split('\t') case [final serial, 'device']) serial,
  ];

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_lookOnce());
  }

  Future<void> stop() async {
    _running = false;
    _look?.cancel();
    for (final (phone, server) in _joined.values) {
      phone.destroy();
      server.destroy();
    }
    _joined.clear();
    for (final entry in _forwarded.entries) {
      await _run(['-s', entry.key, 'forward', '--remove', 'tcp:${entry.value}']);
    }
    _forwarded.clear();
  }

  /// The phones joined now.
  List<String> get joined => _reported.toList()..sort();

  Future<void> _lookOnce() async {
    if (!_running) return;
    final listed = devices(await _run(['devices']) ?? '');
    for (final serial in listed) {
      if (_forwarded.containsKey(serial)) continue;
      final answer = await _run(['-s', serial, 'forward', 'tcp:0', 'tcp:$phonePort']);
      final port = int.tryParse(answer?.trim() ?? '');
      if (port == null || !_running) continue;
      _forwarded[serial] = port;
      unawaited(_attempt(serial));
    }
    for (final serial in _forwarded.keys.toList()) {
      if (listed.contains(serial)) continue;
      _forwarded.remove(serial);
      final ends = _joined.remove(serial);
      ends?.$1.destroy();
      ends?.$2.destroy();
      _report(serial, false);
    }
    if (_running) _look = Timer(interval, () => unawaited(_lookOnce()));
  }

  /// adb takes the connection on the computer even when the phone app is not listening, and
  /// closes it at once then: joined or not, a phone still listed is tried again after a while.
  Future<void> _attempt(String serial) async {
    final port = _forwarded[serial];
    if (!_running || port == null || _joined.containsKey(serial)) return;
    Socket? phone;
    Socket? server;
    try {
      phone = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2));
      server = await Socket.connect(InternetAddress.loopbackIPv4, targetPort, timeout: const Duration(seconds: 2));
    } on SocketException {
      phone?.destroy();
      if (_running) Timer(retry, () => unawaited(_attempt(serial)));
      return;
    }
    final ends = (phone, server);
    _joined[serial] = ends;
    final started = DateTime.now();
    final held = Timer(const Duration(seconds: 1), () {
      if (identical(_joined[serial], ends)) _report(serial, true);
    });
    var open = 2;
    void ended() {
      if (--open > 0) return;
      held.cancel();
      if (identical(_joined[serial], ends)) _joined.remove(serial);
      // Only a connection that held counts as the phone being there.
      if (DateTime.now().difference(started) > const Duration(seconds: 1)) _report(serial, false);
      if (_running) Timer(retry, () => unawaited(_attempt(serial)));
    }

    unawaited(_pipe(phone, server).whenComplete(ended));
    unawaited(_pipe(server, phone).whenComplete(ended));
  }

  /// Copies [from] into [to]; when either end goes, both close.
  static Future<void> _pipe(Socket from, Socket to) async {
    try {
      await to.addStream(from);
    } on Object {
      // A reset on either side ends the join.
    }
    try {
      await to.close();
    } on Object {
      // Already gone.
    }
    from.destroy();
  }

  void _report(String serial, bool present) {
    final changedNow = present ? _reported.add(serial) : _reported.remove(serial);
    if (changedNow) changed?.call(joined);
  }

  /// What adb printed, null when it could not run or failed.
  Future<String?> _run(List<String> arguments) async {
    try {
      final result = await Process.run(adb, arguments);
      return result.exitCode == 0 ? result.stdout as String : null;
    } on ProcessException {
      return null;
    }
  }
}
