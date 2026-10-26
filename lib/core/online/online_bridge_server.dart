import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'online_wire.dart';

/// What the bridge hands on: the game's web requests, its packets, its stream frames, its
/// observation lines, and which engine is connected (null when it went).
class OnlineBridgeHandlers {
  const OnlineBridgeHandlers({this.web, this.datagram, this.stream, this.observation, this.engine});

  final Future<WireWebReply> Function(WireWebRequest request)? web;
  final void Function(WireDatagram datagram)? datagram;

  /// The game's stream frames, in the order the engine sent them.
  final void Function(WireStream frame)? stream;
  final void Function(String line)? observation;
  final void Function(WireHello? hello)? engine;
}

/// One frame off the socket.
class WireFrame {
  const WireFrame(this.header, this.payload);

  final WireHeader header;
  final Uint8List payload;
}

/// Frames from a byte stream, as they complete: awaited one at a time ([next], for the
/// handshake) or handed to [onFrame] as they come (after it). A header announcing more than
/// 16 MiB ends the stream, as it drops the connection.
class WireInbox {
  WireInbox(Stream<Uint8List> bytes) {
    _subscription = bytes.listen(_add, onDone: _end, onError: (Object _) => _end(), cancelOnError: true);
  }

  late final StreamSubscription<Uint8List> _subscription;
  Uint8List _buffer = Uint8List(64 * 1024);
  int _start = 0;
  int _tail = 0;
  final _ready = Queue<WireFrame>();
  Completer<WireFrame?>? _waiting;
  bool _closed = false;

  /// Frames from now on go here instead of to [next].
  void Function(WireFrame frame)? _sink;
  void Function()? _onEnd;

  bool get closed => _closed;

  /// The next frame, or null when the stream ended (or [timeout] passed first).
  Future<WireFrame?> next({Duration? timeout}) {
    if (_ready.isNotEmpty) return Future.value(_ready.removeFirst());
    if (_closed) return Future.value();
    final waiting = _waiting = Completer<WireFrame?>();
    if (timeout == null) return waiting.future;
    return waiting.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiting, waiting)) _waiting = null;
        return null;
      },
    );
  }

  /// Hands every frame from now on (those waiting first) to [frame]; [done] when the stream ends.
  void listen(void Function(WireFrame frame) frame, {void Function()? done}) {
    _sink = frame;
    _onEnd = done;
    while (_ready.isNotEmpty && _sink != null) {
      frame(_ready.removeFirst());
    }
    if (_closed) done?.call();
  }

  Future<void> cancel() async {
    _end();
    await _subscription.cancel();
  }

  void _add(Uint8List chunk) {
    if (_closed) return;
    final needed = _tail - _start + chunk.length;
    if (_start > 0 && _buffer.length - _tail < chunk.length) {
      // Move what is left to the front before growing.
      _buffer.setRange(0, _tail - _start, _buffer, _start);
      _tail -= _start;
      _start = 0;
    }
    if (_buffer.length < needed) {
      var size = _buffer.length;
      while (size < needed) {
        size *= 2;
      }
      _buffer = Uint8List(size)..setRange(0, _tail - _start, _buffer, _start);
      _tail -= _start;
      _start = 0;
    }
    _buffer.setRange(_tail, _tail + chunk.length, chunk);
    _tail += chunk.length;
    while (_tail - _start >= OnlineWire.headerSize) {
      final header = WireHeader.parse(Uint8List.sublistView(_buffer, _start, _start + OnlineWire.headerSize));
      if (header == null) {
        unawaited(cancel());
        return;
      }
      final total = OnlineWire.headerSize + header.length;
      if (_tail - _start < total) break;
      final payload = Uint8List.fromList(
        Uint8List.sublistView(_buffer, _start + OnlineWire.headerSize, _start + total),
      );
      _start += total;
      _deliver(WireFrame(header, payload));
      if (_closed) return;
    }
    if (_start == _tail) {
      _start = 0;
      _tail = 0;
      // A buffer grown for one big datagram does not stay big.
      if (_buffer.length > 1024 * 1024) _buffer = Uint8List(64 * 1024);
    }
  }

  void _deliver(WireFrame frame) {
    final sink = _sink;
    if (sink != null) return sink(frame);
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      _waiting = null;
      waiting.complete(frame);
      return;
    }
    _ready.add(frame);
  }

  void _end() {
    _closed = true;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete(null);
    final done = _onEnd;
    _onEnd = null;
    done?.call();
  }
}

/// The launcher's end of the engine's online bridge: a loopback TCP listener the running game
/// connects to with the per-start secret from [environment]. Both sides prove the secret with
/// HMAC; the secret itself never crosses the socket. One proven engine at a time: a game that
/// reconnects replaces its old connection.
class OnlineBridgeServer {
  OnlineBridgeServer({
    Uint8List? secret,
    this._account = WireAccount.signedOut,
    this.handlers = const OnlineBridgeHandlers(),
  }) : secret = secret ?? OnlineWire.randomBytes(OnlineWire.secretSize);

  final Uint8List secret;
  final OnlineBridgeHandlers handlers;
  WireAccount _account;
  ServerSocket? _listener;
  Socket? _engine;
  WireHello? _hello;
  bool _stopped = false;
  final _connections = <Socket>{};

  /// How long the engine has for each step of the handshake.
  static const handshakeTimeout = Duration(seconds: 5);

  /// The loopback port, once started (0 before).
  int get port => _listener?.port ?? 0;

  /// What the game is started with.
  Map<String, String> get environment => {
    'ANYPS5_ONLINE': '127.0.0.1:$port',
    'ANYPS5_ONLINE_SECRET': OnlineWire.hex(secret),
  };

  /// The engine that proved the secret last, while it is connected.
  WireHello? get engine => _engine == null ? null : _hello;

  WireAccount get account => _account;

  Future<void> start() async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _listener = listener;
    listener.listen(_accepted, onError: (Object _) {});
  }

  Future<void> stop() async {
    _stopped = true;
    final listener = _listener;
    _listener = null;
    _engine = null;
    for (final socket in _connections.toList()) {
      socket.destroy();
    }
    _connections.clear();
    await listener?.close();
  }

  /// Tells the game who is signed in, now and on every later connection.
  void setAccount(WireAccount account) {
    _account = account;
    final socket = _engine;
    if (socket != null) _write(socket, OnlineWire.frame(WireKind.account, account.payload));
  }

  /// Hands a packet from a peer to the game; false while no game is connected.
  bool deliver(WireDatagram datagram) {
    final socket = _engine;
    if (socket == null || datagram.data.length > OnlineWire.maxDatagram) return false;
    return _write(socket, OnlineWire.frame(WireKind.datagram, datagram.payload));
  }

  /// Hands a stream frame from a peer to the game; false while no game is connected.
  bool deliverStream(WireStream frame) {
    final socket = _engine;
    if (socket == null || frame.data.length > OnlineWire.maxStreamData) return false;
    return _write(socket, frame.frame);
  }

  /// Hands a push event (session news) to the game; false while no game is connected or when the
  /// event is not one the engine accepts.
  bool push(WirePushEvent event) {
    final socket = _engine;
    if (socket == null || !event.isValid) return false;
    return _write(socket, OnlineWire.frame(WireKind.pushEvent, event.payload));
  }

  void _accepted(Socket socket) {
    if (_stopped) return socket.destroy();
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // Only latency.
    }
    _connections.add(socket);
    unawaited(_serve(socket));
  }

  Future<void> _serve(Socket socket) async {
    final inbox = WireInbox(socket);
    unawaited(socket.done.catchError((Object _) {}));
    try {
      final first = await inbox.next(timeout: handshakeTimeout);
      final hello = first == null || first.header.kind != WireKind.hello.value ? null : WireHello.parse(first.payload);
      if (hello == null) return _drop(socket, inbox);
      if (hello.protocolVersion != OnlineWire.protocolVersion) {
        _write(
          socket,
          OnlineWire.frame(
            WireKind.refuse,
            OnlineWire.refuse(
              RefuseReason.protocolVersion,
              'this launcher speaks protocol ${OnlineWire.protocolVersion}',
            ),
          ),
        );
        return _drop(socket, inbox, flush: true);
      }
      final nonce = OnlineWire.randomBytes(OnlineWire.nonceSize);
      final launcherProof = OnlineWire.proof(secret, Side.launcher, hello.nonce, nonce);
      if (!_write(socket, OnlineWire.frame(WireKind.welcome, OnlineWire.welcome(nonce, launcherProof)))) {
        return _drop(socket, inbox);
      }
      final answer = await inbox.next(timeout: handshakeTimeout);
      if (answer == null || answer.header.kind != WireKind.proof.value) return _drop(socket, inbox);
      final expected = OnlineWire.proof(secret, Side.engine, hello.nonce, nonce);
      final given = answer.payload.length >= OnlineWire.proofSize
          ? answer.payload.sublist(0, OnlineWire.proofSize)
          : answer.payload;
      if (!OnlineWire.sameProof(given, expected)) {
        _write(
          socket,
          OnlineWire.frame(
            WireKind.refuse,
            OnlineWire.refuse(RefuseReason.badProof, 'this game was not started by this launcher'),
          ),
        );
        return _drop(socket, inbox, flush: true);
      }
      if (_stopped) return _drop(socket, inbox);
      final previous = _engine;
      _engine = socket;
      _hello = hello;
      if (previous != null) {
        _connections.remove(previous);
        previous.destroy();
      }
      _write(socket, OnlineWire.frame(WireKind.account, _account.payload));
      handlers.engine?.call(hello);
      final ended = Completer<void>();
      inbox.listen(
        (frame) => _dispatch(frame, socket),
        done: () {
          if (!ended.isCompleted) ended.complete();
        },
      );
      await ended.future;
      _connections.remove(socket);
      socket.destroy();
      if (identical(_engine, socket)) {
        _engine = null;
        handlers.engine?.call(null);
      }
    } on Object {
      _drop(socket, inbox);
    }
  }

  void _drop(Socket socket, WireInbox inbox, {bool flush = false}) {
    _connections.remove(socket);
    unawaited(inbox.cancel());
    if (flush) {
      // The refusal goes out before the connection closes.
      unawaited(socket.flush().then((_) => socket.destroy(), onError: (Object _) => socket.destroy()));
    } else {
      socket.destroy();
    }
  }

  void _dispatch(WireFrame frame, Socket socket) {
    final header = frame.header;
    if (header.isReply) return;
    switch (WireKind.of(header.kind)) {
      case WireKind.webRequest when header.call != 0:
        final request = WireWebRequest.parse(frame.payload);
        if (request == null) {
          _write(
            socket,
            OnlineWire.frame(
              WireKind.webRequest,
              Uint8List(0),
              flags: OnlineWire.flagReply | OnlineWire.flagUnsupported,
              call: header.call,
            ),
          );
          return;
        }
        unawaited(_answer(request, header.call, socket));
      case WireKind.datagram:
        final datagram = WireDatagram.parse(frame.payload);
        if (datagram != null) handlers.datagram?.call(datagram);
      case final kind? when kind.isStream:
        final parsed = WireStream.parse(kind, frame.payload);
        if (parsed != null) handlers.stream?.call(parsed);
      case WireKind.observation:
        final reader = WireReader(frame.payload);
        final line = reader.str();
        if (reader.ok) handlers.observation?.call(line);
      default:
        if (header.call != 0) {
          _write(
            socket,
            WireHeader(
              length: 0,
              kind: header.kind,
              flags: OnlineWire.flagReply | OnlineWire.flagUnsupported,
              call: header.call,
            ).bytes,
          );
        }
    }
  }

  Future<void> _answer(WireWebRequest request, int call, Socket socket) async {
    WireWebReply reply;
    try {
      reply = await (handlers.web?.call(request) ?? Future.value(WireWebReply.notOffered));
    } on Object {
      reply = WireWebReply.notOffered;
    }
    if (!identical(_engine, socket)) return;
    _write(socket, OnlineWire.frame(WireKind.webRequest, reply.payload, flags: OnlineWire.flagReply, call: call));
  }

  bool _write(Socket socket, Uint8List data) {
    try {
      socket.add(data);
      return true;
    } on Object {
      return false;
    }
  }
}
