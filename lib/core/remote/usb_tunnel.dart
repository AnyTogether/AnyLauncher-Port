import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// usbmuxd, which carries TCP to an iPhone over its cable: Apple Mobile Device Support's service
/// on Windows (127.0.0.1:27015, installed with iTunes or Apple Devices), libimobiledevice's
/// daemon on Linux (/var/run/usbmuxd). It says which phones are plugged in and opens a
/// connection to a port on one of them. Messages are a 16-byte header (length, version 1, type 8
/// for a property list, tag), little-endian, then an XML property list. The Dart form of the
/// macOS launcher's Usbmux.swift.
abstract final class Usbmux {
  static const linuxSocket = '/var/run/usbmuxd';
  static const windowsPort = 27015;

  /// Where usbmuxd is: USBMUXD_SOCKET_ADDRESS as libusbmuxd reads it ("UNIX:/path" or
  /// "host:port"), else the system's own place.
  static ({InternetAddress address, int port}) where({Map<String, String>? environment, bool? windows}) {
    final override = (environment ?? Platform.environment)['USBMUXD_SOCKET_ADDRESS'];
    if (override != null && override.isNotEmpty) {
      if (override.startsWith('UNIX:')) {
        return (address: InternetAddress(override.substring(5), type: InternetAddressType.unix), port: 0);
      }
      final colon = override.lastIndexOf(':');
      final port = colon < 0 ? null : int.tryParse(override.substring(colon + 1));
      final host = colon < 0 ? null : InternetAddress.tryParse(override.substring(0, colon));
      if (port != null && host != null) return (address: host, port: port);
    }
    return windows ?? Platform.isWindows
        ? (address: InternetAddress.loopbackIPv4, port: windowsPort)
        : (address: InternetAddress(linuxSocket, type: InternetAddressType.unix), port: 0);
  }

  /// A request as the Mac sends it.
  static Map<String, Object> request(String type, [Map<String, Object> extra = const {}]) => {
    'MessageType': type,
    'ClientVersionString': 'AnyPS5',
    'ProgName': 'AnyPS5',
    ...extra,
  };

  /// The connect request for [port] on [device]: usbmuxd takes the port in network order.
  static Map<String, Object> connect(int device, int port) =>
      request('Connect', {'DeviceID': device, 'PortNumber': ((port & 0xFF) << 8) | ((port >> 8) & 0xFF)});

  static Uint8List frame(Map<String, Object> message, {int tag = 1}) {
    final body = utf8.encode(plist(message));
    final header = ByteData(16)
      ..setUint32(0, 16 + body.length, Endian.little)
      ..setUint32(4, 1, Endian.little)
      ..setUint32(8, 8, Endian.little)
      ..setUint32(12, tag, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...body]);
  }

  /// The first whole message in [buffer] and what follows it; null until one has arrived.
  static (Map<String, Object?>, Uint8List)? take(Uint8List buffer) {
    if (buffer.length < 16) return null;
    final length = ByteData.sublistView(buffer).getUint32(0, Endian.little);
    if (length < 16 || length > 1 << 24) throw const FormatException('usbmuxd sent a message of an impossible size');
    if (buffer.length < length) return null;
    final body = utf8.decode(buffer.sublist(16, length), allowMalformed: true);
    return (parse(body), Uint8List.sublistView(buffer, length));
  }

  /// A phone plugged in over USB (usbmuxd's number for it and its UDID), or one unplugged.
  static UsbmuxEvent? event(Map<String, Object?> message) {
    switch (message['MessageType']) {
      case 'Attached':
        final id = message['DeviceID'];
        final properties = message['Properties'];
        if (id is! int || properties is! Map || properties['ConnectionType'] != 'USB') return null;
        return UsbmuxAttached(id, properties['SerialNumber'] as String? ?? '');
      case 'Detached':
        final id = message['DeviceID'];
        return id is int ? UsbmuxDetached(id) : null;
    }
    return null;
  }

  // Property lists: the few kinds usbmuxd uses.

  static String plist(Map<String, Object> message) {
    final out = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>\n')
      ..write(
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n',
      )
      ..write('<plist version="1.0">\n');
    void value(Object item) {
      switch (item) {
        case final String text:
          out.write('<string>${const HtmlEscape(HtmlEscapeMode.element).convert(text)}</string>');
        case final int number:
          out.write('<integer>$number</integer>');
        case final bool flag:
          out.write(flag ? '<true/>' : '<false/>');
        case final Map<String, Object> map:
          out.write('<dict>');
          for (final MapEntry(:key, value: inner) in map.entries) {
            out.write('<key>${const HtmlEscape(HtmlEscapeMode.element).convert(key)}</key>');
            value(inner);
          }
          out.write('</dict>');
        default:
          throw ArgumentError('No property list form for $item');
      }
    }

    value(message);
    out.write('\n</plist>\n');
    return out.toString();
  }

  static final _token = RegExp(r'<(/?)([a-zA-Z]+)(/?)>|([^<]+)');

  /// A dictionary from an XML property list; anything else is an empty one.
  static Map<String, Object?> parse(String xml) {
    final tokens = _token.allMatches(xml).toList();
    var index = 0;
    String unescape(String text) => text
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
    String textUntil(String tag) {
      final text = StringBuffer();
      while (index < tokens.length) {
        final token = tokens[index++];
        if (token.group(4) != null) {
          text.write(token.group(4));
        } else if (token.group(1) == '/' && token.group(2) == tag) {
          break;
        }
      }
      return unescape(text.toString());
    }

    Object? value() {
      while (index < tokens.length) {
        final token = tokens[index++];
        if (token.group(4) != null || token.group(1) == '/') continue;
        final tag = token.group(2)!;
        final empty = token.group(3) == '/';
        switch (tag) {
          case 'true':
            return true;
          case 'false':
            return false;
          case 'string' || 'data' || 'date':
            return empty ? '' : textUntil(tag);
          case 'integer':
            return int.tryParse(textUntil(tag).trim());
          case 'real':
            return double.tryParse(textUntil(tag).trim());
          case 'dict':
            final map = <String, Object?>{};
            if (empty) return map;
            while (index < tokens.length) {
              final next = tokens[index];
              if (next.group(1) == '/' && next.group(2) == 'dict') {
                index++;
                break;
              }
              if (next.group(2) == 'key' && next.group(1) != '/') {
                index++;
                final key = textUntil('key');
                map[key] = value();
              } else {
                index++;
              }
            }
            return map;
          case 'array':
            final list = <Object?>[];
            if (empty) return list;
            while (index < tokens.length) {
              final next = tokens[index];
              if (next.group(1) == '/' && next.group(2) == 'array') {
                index++;
                break;
              }
              if (next.group(4) != null) {
                index++;
                continue;
              }
              list.add(value());
            }
            return list;
          default:
            // <?xml …>, <!DOCTYPE …> and <plist> are not tokens of this pattern or carry nothing.
            continue;
        }
      }
      return null;
    }

    final found = value();
    return found is Map<String, Object?> ? found : {};
  }
}

sealed class UsbmuxEvent {
  const UsbmuxEvent(this.id);
  final int id;
}

class UsbmuxAttached extends UsbmuxEvent {
  const UsbmuxAttached(super.id, this.serial);
  final String serial;
}

class UsbmuxDetached extends UsbmuxEvent {
  const UsbmuxDetached(super.id);
}

/// usbmuxd's messages on one connection, and the bytes after the last one read.
class _Messages {
  _Messages(this.socket) {
    _subscription = socket.listen(
      (chunk) {
        _buffer = Uint8List.fromList([..._buffer, ...chunk]);
        _drain();
      },
      onError: (Object _) => _close(),
      onDone: _close,
      cancelOnError: true,
    );
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  Uint8List _buffer = Uint8List(0);
  final _waiting = <Completer<Map<String, Object?>?>>[];
  final _ready = <Map<String, Object?>>[];
  void Function(Map<String, Object?> message)? onMessage;
  void Function()? onClosed;
  bool _closed = false;

  void _drain() {
    while (true) {
      final (Map<String, Object?>, Uint8List)? next;
      try {
        next = Usbmux.take(_buffer);
      } on FormatException {
        socket.destroy();
        return _close();
      }
      if (next == null) return;
      _buffer = Uint8List.fromList(next.$2);
      final message = next.$1;
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(message);
      } else if (onMessage != null) {
        onMessage!(message);
      } else {
        _ready.add(message);
      }
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    for (final waiting in _waiting) {
      waiting.complete(null);
    }
    _waiting.clear();
    onClosed?.call();
  }

  /// The next message, null when the connection closed first.
  Future<Map<String, Object?>?> next({Duration timeout = const Duration(seconds: 5)}) {
    if (_ready.isNotEmpty) return Future.value(_ready.removeAt(0));
    if (_closed) return Future.value(null);
    final waiting = Completer<Map<String, Object?>?>();
    _waiting.add(waiting);
    return waiting.future.timeout(timeout, onTimeout: () => null);
  }

  /// From here on the connection is the phone's: the subscription and the bytes already read
  /// beyond the last message.
  (StreamSubscription<Uint8List>, Uint8List) handOver() => (_subscription, _buffer);
}

/// iPhones on a cable reach the launcher without Wi-Fi: for each one usbmuxd has plugged in, the
/// launcher keeps trying to open the phone app's port 47702 over the cable and, once it is open,
/// joins it to its own phone server, so the phone talks to the server as it would over Wi-Fi.
/// The Dart form of the macOS launcher's UsbTunnel.swift.
class UsbTunnel {
  UsbTunnel({
    required this.targetPort,
    this.phonePort = 47702,
    Future<Socket> Function()? usbmux,
    this.again = const Duration(seconds: 5),
    this.retry = const Duration(seconds: 2),
    this.changed,
  }) : _usbmux = usbmux ?? _systemUsbmux;

  /// The launcher's own phone server port.
  final int targetPort;

  /// The port the phone app listens on.
  final int phonePort;
  final Future<Socket> Function() _usbmux;

  /// usbmuxd missing or gone is looked for again after [again]; a phone whose app does not
  /// listen yet after [retry].
  final Duration again;
  final Duration retry;

  /// The serials of the phones joined, whenever that changes.
  final void Function(List<String> serials)? changed;

  bool _running = false;
  Socket? _watch;
  final Map<int, String> _plugged = {};
  final Map<int, (Socket, Socket)> _joined = {};
  final Set<int> _trying = {};

  static Future<Socket> _systemUsbmux() {
    final place = Usbmux.where();
    return Socket.connect(place.address, place.port, timeout: const Duration(seconds: 2));
  }

  /// The phones joined now, by serial.
  List<String> get joined => [for (final id in _joined.keys.toList()..sort()) ?_plugged[id]];

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_listen());
  }

  Future<void> stop() async {
    _running = false;
    _watch?.destroy();
    _watch = null;
    _plugged.clear();
    for (final (phone, server) in _joined.values) {
      phone.destroy();
      server.destroy();
    }
    _joined.clear();
  }

  /// Follows phones plugged in and out; usbmuxd going away (or not being there) is tried again
  /// a few seconds later.
  Future<void> _listen() async {
    if (!_running) return;
    Socket? socket;
    try {
      socket = await _usbmux();
      final messages = _Messages(socket);
      socket.add(Usbmux.frame(Usbmux.request('Listen')));
      final answer = await messages.next();
      if (answer == null || answer['MessageType'] != 'Result' || answer['Number'] != 0) {
        throw const SocketException('usbmuxd refused to tell of phones');
      }
      if (!_running) return socket.destroy();
      _watch = socket;
      final watched = socket;
      messages
        ..onClosed = () {
          if (_watch != watched) return;
          _watch = null;
          if (_running) Timer(again, () => unawaited(_listen()));
        }
        ..onMessage = _handle;
      for (final message in messages._ready.toList()) {
        _handle(message);
      }
      messages._ready.clear();
    } on Object {
      socket?.destroy();
      if (_running) Timer(again, () => unawaited(_listen()));
    }
  }

  void _handle(Map<String, Object?> message) {
    switch (Usbmux.event(message)) {
      case UsbmuxAttached(:final id, :final serial):
        _plugged[id] = serial;
        unawaited(_attempt(id));
      case UsbmuxDetached(:final id):
        _plugged.remove(id);
        final ends = _joined.remove(id);
        ends?.$1.destroy();
        ends?.$2.destroy();
        if (ends != null) changed?.call(joined);
      case null:
        break;
    }
  }

  /// Opens the phone app's port and joins it to the server; tried again every few seconds
  /// while the phone is plugged in and its app is not listening.
  Future<void> _attempt(int id) async {
    if (!_running || !_plugged.containsKey(id) || _joined.containsKey(id) || !_trying.add(id)) return;
    Socket? phone;
    Socket? server;
    try {
      phone = await _usbmux();
      final messages = _Messages(phone);
      phone.add(Usbmux.frame(Usbmux.connect(id, phonePort)));
      final answer = await messages.next();
      if (answer == null || answer['MessageType'] != 'Result' || answer['Number'] != 0) {
        throw const SocketException('nothing listens on the phone');
      }
      server = await Socket.connect(InternetAddress.loopbackIPv4, targetPort, timeout: const Duration(seconds: 2));
      server.setOption(SocketOption.tcpNoDelay, true);
      if (!_running || !_plugged.containsKey(id)) throw const SocketException('unplugged');
      final ends = (phone, server);
      _joined[id] = ends;
      changed?.call(joined);
      final (incoming, already) = messages.handOver();
      _join(phone, server, incoming, already, () {
        if (identical(_joined[id], ends)) {
          _joined.remove(id);
          changed?.call(joined);
        }
        if (_running) Timer(const Duration(seconds: 1), () => unawaited(_attempt(id)));
      });
    } on Object {
      phone?.destroy();
      server?.destroy();
      if (_running && _plugged.containsKey(id)) Timer(retry, () => unawaited(_attempt(id)));
    } finally {
      _trying.remove(id);
    }
  }

  /// Copies each way until either end closes, then closes both and calls [ended]; [already]
  /// (what the phone sent right behind usbmuxd's answer) goes first.
  static void _join(
    Socket phone,
    Socket server,
    StreamSubscription<Uint8List> incoming,
    Uint8List already,
    void Function() ended,
  ) {
    var open = true;
    void finish() {
      if (!open) return;
      open = false;
      phone.destroy();
      server.destroy();
      ended();
    }

    if (already.isNotEmpty) server.add(already);
    incoming
      ..onData((chunk) {
        try {
          server.add(chunk);
        } on Object {
          finish();
        }
      })
      ..onError((Object _) => finish())
      ..onDone(finish);
    server.listen(
      (chunk) {
        try {
          phone.add(chunk);
        } on Object {
          finish();
        }
      },
      onError: (Object _) => finish(),
      onDone: finish,
      cancelOnError: true,
    );
  }
}
