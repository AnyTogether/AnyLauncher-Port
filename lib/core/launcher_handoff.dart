import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// Files opened with the launcher while it already runs (a `.anyps5theme` double-clicked in the
/// file manager): the second launcher hands them to the first over a loopback socket and quits
/// before it shows a window, the way macOS gives an open file to the running app.
///
/// The running launcher listens on a free loopback port and writes it, with a random token, to
/// [fileName] in the config folder, which only this user can read. A message is one line of JSON,
/// `{"token": …, "open": [paths]}`, answered `ok`.
class LauncherHandoff {
  LauncherHandoff._(this._server, this._file, this._token, this._open) {
    _server.listen(_serve);
  }

  static const fileName = 'launcher-handoff.json';

  final ServerSocket _server;
  final String _file;
  final String _token;
  final void Function(String path) _open;

  /// Listens for files handed over, each given to [open]; null when no socket could be opened.
  static Future<LauncherHandoff?> listen(String configFolder, void Function(String path) open) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final random = math.Random.secure();
      final token = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final file = p.join(configFolder, fileName);
      Directory(configFolder).createSync(recursive: true);
      File(file).writeAsStringSync(jsonEncode({'port': server.port, 'pid': pid, 'token': token}));
      // Only this user reads the token (the config folder is the user's own on Windows already).
      if (!Platform.isWindows) Process.runSync('chmod', ['600', file]);
      return LauncherHandoff._(server, file, token, open);
    } on Object {
      return null;
    }
  }

  void _serve(Socket socket) {
    final lines = utf8.decoder.bind(socket).transform(const LineSplitter());
    late final StreamSubscription<String> reading;
    final timeout = Timer(const Duration(seconds: 5), () => socket.destroy());
    reading = lines.listen(
      (line) {
        timeout.cancel();
        unawaited(reading.cancel());
        try {
          final message = jsonDecode(line);
          if (message is Map<String, dynamic> && message['token'] == _token && message['open'] is List<dynamic>) {
            for (final path in message['open'] as List<dynamic>) {
              if (path is String) _open(path);
            }
            socket.write('ok\n');
          }
        } on FormatException {
          // Not one of ours.
        }
        unawaited(socket.flush().whenComplete(socket.destroy));
      },
      onError: (Object _) => socket.destroy(),
      cancelOnError: true,
    );
  }

  /// Stops listening and takes the file away (the launcher quitting).
  Future<void> close() async {
    await _server.close();
    try {
      final saved = jsonDecode(File(_file).readAsStringSync());
      if (saved is Map<String, dynamic> && saved['token'] == _token) File(_file).deleteSync();
    } on Object {
      // Gone already, or another launcher's now.
    }
  }

  /// Hands [paths] to a launcher already running; false when there is none (or it did not
  /// answer), and this one then opens them itself.
  static Future<bool> send(
    String configFolder,
    List<String> paths, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final saved = jsonDecode(File(p.join(configFolder, fileName)).readAsStringSync());
      if (saved is! Map<String, dynamic> || saved['port'] is! int || saved['token'] is! String) return false;
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, saved['port'] as int, timeout: timeout);
      try {
        socket.write('${jsonEncode({'token': saved['token'], 'open': paths})}\n');
        await socket.flush();
        final answer = await utf8.decoder.bind(socket).transform(const LineSplitter()).first.timeout(timeout);
        return answer == 'ok';
      } finally {
        socket.destroy();
      }
    } on Object {
      return false;
    }
  }

  /// The files among the launcher's [arguments]: paths and `file://` URIs (what a desktop entry's
  /// %U gives) of files that exist, the options left out.
  static List<String> files(List<String> arguments) {
    final found = <String>[];
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      // --play takes the next argument as a title ID.
      if (argument == '--play') {
        index++;
        continue;
      }
      if (argument.startsWith('-')) continue;
      var path = argument;
      if (argument.startsWith('file:')) {
        try {
          path = Uri.parse(argument).toFilePath();
        } on Object {
          continue;
        }
      }
      final absolute = p.absolute(path);
      if (File(absolute).existsSync() && !found.contains(absolute)) found.add(absolute);
    }
    return found;
  }
}
