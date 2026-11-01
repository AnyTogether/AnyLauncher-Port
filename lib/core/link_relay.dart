import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Hands an anyps5:// link to the launcher that is already open. The system starts a new
/// launcher for every link it opens; that one finds the open launcher's address in a small file
/// in the config folder, sends it the link over the loopback with the secret in the same file,
/// and quits before it shows a window. Without an open launcher it stays and opens the link
/// itself.
class LinkRelay {
  LinkRelay._(this._server, this._file, this._secret);

  /// The file the open launcher keeps its port and secret in.
  static String fileIn(String configFolder) => p.join(configFolder, 'link-relay.json');

  final ServerSocket _server;
  final String _file;
  final String _secret;
  final _links = StreamController<String>.broadcast();

  /// The links other launchers sent, as they arrive.
  Stream<String> get links => _links.stream;

  /// Listens on the loopback for links and writes where in [file]; null when it cannot.
  static Future<LinkRelay?> listen(String file) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final random = Random.secure();
      final secret = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final relay = LinkRelay._(server, file, secret);
      Directory(p.dirname(file)).createSync(recursive: true);
      final temporary = File('$file.tmp')..writeAsStringSync(jsonEncode({'port': server.port, 'secret': secret}));
      temporary.renameSync(file);
      server.listen(relay._serve);
      return relay;
    } on Object {
      return null;
    }
  }

  void _serve(Socket socket) {
    final lines = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    final timeout = Timer(const Duration(seconds: 5), socket.destroy);
    var trusted = false;
    var done = false;
    lines.listen(
      (line) {
        if (done) return;
        if (!trusted) {
          trusted = line == _secret;
          if (!trusted) {
            // Whatever else came with it is not read.
            done = true;
            timeout.cancel();
            socket.destroy();
          }
          return;
        }
        // One link per connection, short and plain.
        done = true;
        if (line.length <= 512) _links.add(line);
        timeout.cancel();
        socket.write('ok\n');
        unawaited(socket.flush().whenComplete(socket.destroy));
      },
      onError: (Object _) => socket.destroy(),
      cancelOnError: true,
    );
  }

  /// Sends [link] to the launcher whose address [file] holds; whether it took it.
  static Future<bool> send(String file, String link, {Duration timeout = const Duration(seconds: 3)}) async {
    final int port;
    final String secret;
    try {
      final json = jsonDecode(File(file).readAsStringSync());
      if (json is! Map || json['port'] is! int || json['secret'] is! String) return false;
      port = json['port'] as int;
      secret = json['secret'] as String;
    } on Object {
      return false;
    }
    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: timeout);
      socket.write('$secret\n$link\n');
      await socket.flush();
      final answer = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout);
      return answer == 'ok';
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// Stops listening and takes the file away when it is still this launcher's.
  Future<void> close() async {
    await _server.close();
    await _links.close();
    try {
      final json = jsonDecode(File(_file).readAsStringSync());
      if (json is Map && json['secret'] == _secret) File(_file).deleteSync();
    } on Object {
      // Gone already, or another launcher's now.
    }
  }
}
