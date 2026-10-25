import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One request the fake server saw.
typedef Seen = ({String path, String? range});

/// A file server on loopback written on a raw socket, so it can do what a real one does when
/// things go wrong: drop the connection halfway, ignore Range, redirect to its storage.
class FakeFileServer {
  FakeFileServer._(this._socket, this.body);

  static Future<FakeFileServer> start(Uint8List body) async =>
      FakeFileServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), body).._listen();

  final ServerSocket _socket;
  Uint8List body;
  final List<Seen> seen = [];

  /// Requests that are cut off after this many bytes of the body, in order.
  final List<int> dropAfter = [];

  /// Answers every request with the whole file (200), whatever Range asks.
  bool ignoreRange = false;

  /// /zip answers with a redirect to /storage/zip, as GitHub does.
  bool redirect = false;

  Uri get url => Uri.parse('http://127.0.0.1:${_socket.port}/zip');

  void _listen() {
    _socket.listen((client) {
      final buffer = <int>[];
      late StreamSubscription<Uint8List> subscription;
      subscription = client.listen((data) {
        buffer.addAll(data);
        final text = latin1.decode(buffer);
        if (!text.contains('\r\n\r\n')) return;
        subscription.pause();
        unawaited(_answer(client, text));
      }, onError: (_) {});
    });
  }

  Future<void> _answer(Socket client, String request) async {
    final lines = request.split('\r\n');
    final path = lines.first.split(' ')[1];
    String? range;
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).toLowerCase() == 'range') range = line.substring(colon + 1).trim();
    }
    seen.add((path: path, range: range));
    try {
      if (redirect && path == '/zip') {
        client.write('HTTP/1.1 302 Found\r\nLocation: /storage/zip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
        return;
      }
      var start = 0;
      if (!ignoreRange && range != null) start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= body.length && range != null && !ignoreRange) {
        client.write('HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
        return;
      }
      final rest = body.sublist(start);
      final head = start > 0
          ? 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes $start-${body.length - 1}/${body.length}\r\n'
          : 'HTTP/1.1 200 OK\r\n';
      client.write('${head}Content-Length: ${rest.length}\r\nConnection: close\r\n\r\n');
      if (dropAfter.isNotEmpty) {
        client.add(rest.sublist(0, dropAfter.removeAt(0)));
        await client.flush();
        client.destroy();
        return;
      }
      client.add(rest);
    } finally {
      try {
        await client.flush();
        await client.close();
      } on Object {
        // Destroyed on purpose.
      }
    }
  }

  Future<void> close() => _socket.close();
}
