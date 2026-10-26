import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'paired_devices.dart';
import 'remote_protocol.dart';

/// A phone that is not paired yet, waiting for the user to allow it on the computer.
class PairingRequest {
  const PairingRequest({required this.id, required this.deviceName, required this.code});
  final String id;
  final String deviceName;
  final String code;
}

/// What the server tells the launcher.
class RemoteEvents {
  const RemoteEvents({
    this.pairing,
    this.connected,
    this.disconnected,
    this.latency,
    this.request,
    this.connecting,
    this.players,
    this.streamWishes,
  });

  final void Function(PairingRequest request)? pairing;
  final void Function(String name)? connected;
  final void Function()? disconnected;
  final void Function(double milliseconds)? latency;

  /// What a welcomed phone asks the launcher to do (launcher mode), with the phone's device ID.
  final void Function(RemoteMessage message, String deviceId)? request;

  /// A phone that said hello and is not welcomed yet, by name; null when it gave up or was
  /// refused before that.
  final void Function(String? name)? connecting;

  /// The game said a phone became another player, or none ([RemoteServer.phonePlayers]).
  final void Function()? players;

  /// A phone asked for Remote Play or stopped wanting it ([RemoteServer.streamWishes]).
  final void Function()? streamWishes;
}

/// The phone on the control channel, from its hello to the end of its socket.
class _Client {
  _Client(this.socket);
  final WebSocket socket;
  String? deviceId;
  String? name;
  PairingRequest? pending;

  /// The session's 64 bits as a Dart int (the packet's bytes, read little-endian).
  int? session;

  /// Which bridge, and so which of the game's phone channels, carries this phone's pad.
  int? slot;

  /// Where the phone sends its pad from, and the socket it came in on.
  (InternetAddress, int, RawDatagramSocket)? address;
  (int, int)? streamSize;

  /// The phone sends its pad on this channel (on a cable, with no UDP path), and is answered on it.
  bool padOnChannel = false;
}

/// The launcher's side of the phone controller (section 12.4 of the AnyTogether platform
/// notes): pairs phones over a WebSocket control channel, tells each where to send its pad, and
/// relays pad packets between the phones and the running game's bridges. Up to four phones at a
/// time, one per player, each with its own bridge to the game; one new phone is asked about at
/// a time. Advertising on the network is [MdnsAdvertiser]'s job.
class RemoteServer {
  RemoteServer({
    required this.name,
    required this.devices,
    this.events = const RemoteEvents(),
    this.controlPort = 0,
    this.bridgePort = 0,
    this.pingInterval = const Duration(seconds: 5),
  });

  static const serviceType = '_anyps5-remote._tcp';

  /// The control port the launcher tries first; the phone's manual address field assumes it.
  static const preferredPort = 47700;

  /// The game bridge port the launcher tries first, so a game started before the launcher
  /// restarted still reaches it.
  static const preferredBridgePort = 47701;
  static const maxPhones = 4;

  /// The computer's name the phone shows.
  final String name;

  /// The AnyTogether server the launcher uses, told to each phone it welcomes.
  String? togetherServer;
  final PairedDevices devices;
  final RemoteEvents events;

  /// The ports asked for; 0 lets the system choose.
  final int controlPort;
  final int bridgePort;

  /// WebSocket pings notice a phone that vanished without closing.
  final Duration pingInterval;

  HttpServer? _http;
  final List<_Client> _clients = [];

  /// The welcomed phones, by slot.
  final List<_Client> _phones = [];
  _Client? _asking;
  final List<RawDatagramSocket> _phoneSockets = [];
  final List<RawDatagramSocket> _bridges = [];
  final List<(InternetAddress, int)?> _gameAddresses = [];
  final List<int?> _gamePlayers = [];

  /// Whether each bridge's game said (in its hello) that its engine takes presses.
  final List<bool> _gameTakesPresses = [];

  /// When each bridge's game last said hello (it does every second): one quiet for longer has
  /// ended, and its address no longer takes presses.
  final List<DateTime?> _gameHelloAt = [];
  static const _helloLapse = Duration(seconds: 3);

  /// The next press's id: a random start, one more for each press.
  int _pressId = Random().nextInt(0x7FFFFFFF);
  static final _random = Random.secure();

  /// Starts with the preferred ports, else ports the system picks; returns the started server.
  static Future<RemoteServer> startPreferred({
    required String name,
    required PairedDevices devices,
    RemoteEvents events = const RemoteEvents(),
  }) async {
    for (final (control, bridge) in const [(preferredPort, preferredBridgePort), (0, 0)]) {
      final server = RemoteServer(
        name: name,
        devices: devices,
        events: events,
        controlPort: control,
        bridgePort: bridge,
      );
      try {
        await server.start();
        return server;
      } on SocketException {
        await server.stop();
      }
    }
    throw const SocketException('the phone server did not start');
  }

  /// Starts listening; completes once the control port and the pad sockets are open.
  Future<void> start() async {
    final http = await HttpServer.bind(InternetAddress.anyIPv6, controlPort, v6Only: false);
    _http = http;
    http.listen(_request, onError: (_) {});
    await _startRelay();
  }

  /// Stops and frees every port.
  Future<void> stop() async {
    final http = _http;
    _http = null;
    for (final client in List.of(_clients)) {
      await client.socket.close(WebSocketStatus.goingAway);
    }
    _clients.clear();
    _phones.clear();
    _asking = null;
    for (final socket in [..._phoneSockets, ..._bridges]) {
      socket.close();
    }
    _phoneSockets.clear();
    _bridges.clear();
    _gameAddresses.clear();
    _gamePlayers.clear();
    _gameTakesPresses.clear();
    _gameHelloAt.clear();
    await http?.close(force: true);
  }

  int? get port => _http?.port;

  /// The UDP port the phone sends its pad to.
  int? get udpPort => _phoneSockets.isEmpty ? null : _phoneSockets.first.port;

  /// The loopback UDP ports of the game's phone channels, by slot.
  List<int> get bridgePorts => [for (final bridge in _bridges) bridge.port];

  /// What a game is started with so that it reads the phones (ANYPS5_REMOTE_PAD, then
  /// ANYPS5_REMOTE_PAD_2 to _4).
  Map<String, String> get bridgeEnvironment => {
    for (var slot = 0; slot < _bridges.length; slot++)
      slot == 0 ? 'ANYPS5_REMOTE_PAD' : 'ANYPS5_REMOTE_PAD_${slot + 1}': '127.0.0.1:${_bridges[slot].port}',
  };

  /// Every welcomed phone's name, by slot.
  List<String> get connectedDevices => [for (final phone in _phones) ?phone.name];

  /// Every welcomed phone's device ID, by slot.
  List<String> get connectedDeviceIds => [for (final phone in _phones) ?phone.deviceId];

  /// Which player each welcomed phone is in the game, from 1, by device ID; a phone that is no
  /// player yet is left out.
  Map<String, int> get phonePlayers => {
    for (final phone in _phones)
      if (phone.deviceId != null && phone.slot != null && _gamePlayers[phone.slot!] != null)
        phone.deviceId!: _gamePlayers[phone.slot!]!,
  };

  /// The phones that want Remote Play, and the picture size each asked for.
  List<(String, int, int)> get streamWishes => [
    for (final phone in _phones)
      if (phone.streamSize case (final width, final height)) (phone.deviceId ?? '', width, height),
  ];

  /// The user's answer to a pairing request.
  void respond(String requestId, {required bool allow}) {
    final client = _asking;
    final request = client?.pending;
    final deviceId = client?.deviceId;
    if (client == null || request == null || request.id != requestId || deviceId == null) return;
    client.pending = null;
    if (allow) {
      _asking = null;
      final device = devices.add(deviceId, request.deviceName);
      _welcome(client, device.key);
    } else {
      _reject(client, 'denied');
    }
  }

  /// Sends to every welcomed phone.
  void publish(RemoteMessage message) {
    for (final phone in _phones) {
      _send(message, phone);
    }
  }

  /// Sends to one phone, by device ID.
  void tell(RemoteMessage message, String deviceId) {
    for (final phone in _phones) {
      if (phone.deviceId == deviceId) _send(message, phone);
    }
  }

  // Control channel.

  Future<void> _request(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.upgradeRequired
        ..headers.contentType = ContentType.text
        ..write('AnyPS5 phone server\n');
      await request.response.close();
      return;
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } on Object {
      return;
    }
    socket.pingInterval = pingInterval;
    final client = _Client(socket);
    _clients.add(client);
    socket.listen(
      (data) => _received(client, data),
      onDone: () => _ended(client),
      onError: (_) => _ended(client),
      cancelOnError: true,
    );
  }

  void _received(_Client client, Object? data) {
    if (data is List<int>) {
      final session = RemotePacket.inputSession(data);
      if (session != null) return _padFromChannel(data, session, client);
      final message = RemoteMessage.decode(utf8.decode(data, allowMalformed: true));
      if (message != null) _handle(message, client);
    } else if (data is String) {
      final message = RemoteMessage.decode(data);
      if (message != null) _handle(message, client);
    }
  }

  void _handle(RemoteMessage message, _Client client) {
    switch (message) {
      case RemoteHello(:final protocol, :final deviceId, :final deviceName, :final key):
        if (protocol != RemoteMessage.protocolVersion) return _reject(client, 'protocol');
        // The same phone back on a new connection: the old one is dead, it takes over.
        for (final old in [..._phones, ?_asking]) {
          if (!identical(old, client) && old.deviceId == deviceId) {
            _phones.remove(old);
            if (identical(_asking, old)) _asking = null;
            _clients.remove(old);
            unawaited(old.socket.close(WebSocketStatus.normalClosure));
          }
        }
        client
          ..deviceId = deviceId
          ..name = deviceName;
        final device = key == null ? null : devices.device(deviceId, key);
        if (device != null) {
          if (_phones.length >= maxPhones) return _reject(client, 'busy');
          events.connecting?.call(deviceName);
          _welcome(client, device.key);
        } else {
          if (_asking != null || _phones.length >= maxPhones) return _reject(client, 'busy');
          _asking = client;
          events.connecting?.call(deviceName);
          final request = PairingRequest(
            id: '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}',
            deviceName: deviceName,
            code: _random.nextInt(10000).toString().padLeft(4, '0'),
          );
          client.pending = request;
          _send(RemotePairing(request.code), client);
          events.pairing?.call(request);
        }
      case RemoteLatency(:final milliseconds):
        if (_phones.isNotEmpty && identical(client, _phones.first)) events.latency?.call(milliseconds);
      case RemoteWantArt() ||
          RemoteCommand() ||
          RemoteSelect() ||
          RemoteLaunch() ||
          RemoteClose() ||
          RemoteHome() ||
          RemoteSaveLayout() ||
          RemoteKeyFrame() ||
          RemoteTogetherHandoff() ||
          RemoteTogetherHandoffAnswer():
        if (_phones.contains(client)) events.request?.call(message, client.deviceId ?? '');
      case RemoteStream(:final on, :final width, :final height):
        if (!_phones.contains(client)) return;
        client.streamSize = on ? (max(160, width), max(90, height)) : null;
        events.streamWishes?.call();
      default:
        // The launcher's own messages coming back are ignored.
        break;
    }
  }

  void _welcome(_Client client, String key) {
    int? slot;
    for (var candidate = 0; candidate < maxPhones; candidate++) {
      if (!_phones.any((phone) => phone.slot == candidate)) {
        slot = candidate;
        break;
      }
    }
    if (slot == null) return _reject(client, 'busy');
    var session = 0;
    while (session == 0) {
      session = _random.nextInt(1 << 32) << 32 | _random.nextInt(1 << 32);
    }
    client
      ..session = session
      ..slot = slot;
    _phones
      ..add(client)
      ..sort((a, b) => (a.slot ?? 0).compareTo(b.slot ?? 0));
    _send(
      RemoteWelcome(
        session: BigInt.from(session).toUnsigned(64),
        udpPort: udpPort ?? 0,
        macName: name,
        key: key,
        togetherServer: togetherServer,
      ),
      client,
    );
    final phoneName = client.name;
    if (phoneName != null) events.connected?.call(phoneName);
  }

  void _reject(_Client client, String reason) {
    if (identical(_asking, client)) {
      _asking = null;
      events.connecting?.call(null);
    }
    _send(RemoteRejected(reason), client);
    unawaited(client.socket.close(WebSocketStatus.normalClosure));
  }

  void _ended(_Client client) {
    if (!_clients.remove(client)) return;
    if (identical(_asking, client)) {
      _asking = null;
      events.connecting?.call(null);
    } else if (_phones.remove(client)) {
      final slot = client.slot;
      if (slot != null && slot < _gamePlayers.length) _gamePlayers[slot] = null;
      events.disconnected?.call();
      if (client.streamSize != null) events.streamWishes?.call();
    }
  }

  void _send(RemoteMessage message, _Client client) {
    try {
      client.socket.add(message.text);
    } on Object {
      // A socket that is closing; its end is handled by _ended.
    }
  }

  // Pad relay.

  Future<void> _startRelay() async {
    // The phone's socket: IPv6 (dual-stack where the system allows it) and IPv4 on the same port,
    // so phones reach it on either.
    RawDatagramSocket? v6;
    try {
      v6 = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
    } on SocketException {
      v6 = null;
    }
    RawDatagramSocket? v4;
    try {
      v4 = await RawDatagramSocket.bind(InternetAddress.anyIPv4, v6?.port ?? 0);
    } on SocketException {
      // Taken by the dual-stack IPv6 socket.
      v4 = null;
    }
    if (v6 == null && v4 == null) throw const SocketException('the phone pad socket could not be opened');
    for (final socket in [?v6, ?v4]) {
      _phoneSockets.add(socket);
      socket.listen((event) {
        if (event == RawSocketEvent.read) _fromPhone(socket);
      });
    }
    for (var slot = 0; slot < maxPhones; slot++) {
      final bridge = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, slot == 0 ? bridgePort : 0);
      _bridges.add(bridge);
      _gameAddresses.add(null);
      _gamePlayers.add(null);
      _gameTakesPresses.add(false);
      _gameHelloAt.add(null);
      bridge.listen((event) {
        if (event == RawSocketEvent.read) _fromGame(slot);
      });
    }
  }

  /// Pad packets from a welcomed phone go to the game through its slot's bridge; anything else
  /// is dropped.
  void _fromPhone(RawDatagramSocket socket) {
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) return;
      final session = RemotePacket.inputSession(datagram.data);
      if (session == null) continue;
      _Client? client;
      for (final phone in _phones) {
        if (phone.session == session) client = phone;
      }
      final slot = client?.slot;
      if (client == null || slot == null) continue;
      client.address = (datagram.address, datagram.port, socket);
      final game = _gameAddresses[slot];
      if (game != null) _bridges[slot].send(datagram.data, game.$1, game.$2);
    }
  }

  /// A pad packet on a welcomed phone's own control channel goes to the game as if it had come
  /// on UDP.
  void _padFromChannel(List<int> data, int session, _Client client) {
    final slot = client.slot;
    if (client.session != session || !_phones.contains(client) || slot == null || slot >= _gameAddresses.length) {
      return;
    }
    client.padOnChannel = true;
    final game = _gameAddresses[slot];
    if (game != null) _bridges[slot].send(data, game.$1, game.$2);
  }

  /// A hello names the game to send to on that bridge; its answers go back to the slot's phone.
  void _fromGame(int slot) {
    if (slot >= _bridges.length) return;
    final bridge = _bridges[slot];
    while (true) {
      final datagram = bridge.receive();
      if (datagram == null) return;
      final data = datagram.data;
      if (RemotePacket.isHello(data)) {
        _gameAddresses[slot] = (datagram.address, datagram.port);
        _gameTakesPresses[slot] = RemotePacket.helloTakesPresses(data);
        _gameHelloAt[slot] = DateTime.now();
        final player = RemotePacket.helloPlayer(data);
        if (_gamePlayers[slot] != player) {
          _gamePlayers[slot] = player;
          events.players?.call();
        }
      } else if (RemotePacket.isOutput(data)) {
        final game = _gameAddresses[slot];
        if (game == null || game.$1 != datagram.address || game.$2 != datagram.port) continue;
        _Client? client;
        for (final phone in _phones) {
          if (phone.slot == slot) client = phone;
        }
        if (client == null) continue;
        if (client.padOnChannel) {
          try {
            client.socket.add(Uint8List.fromList(data));
          } on Object {
            // Closing.
          }
        } else if (client.address case (final address, final port, final socket)) {
          socket.send(data, address, port);
        }
      }
    }
  }

  /// Whether a game's bridge said it takes presses ([pressButtons] can reach it).
  bool get gameTakesPresses => _pressSlot != null;

  /// The first bridge whose game said hello lately and takes presses.
  int? get _pressSlot {
    final now = DateTime.now();
    for (var slot = 0; slot < _bridges.length; slot++) {
      final said = _gameHelloAt[slot];
      if (_gameAddresses[slot] != null &&
          _gameTakesPresses[slot] &&
          said != null &&
          now.difference(said) < _helloLapse) {
        return slot;
      }
    }
    return null;
  }

  /// Holds [buttons] (the input packet's bits) [holdMs] on the game's first player's pad,
  /// whoever drives it, through the first bridge whose game takes presses: the same datagram sent
  /// three times, 40 ms apart, against loss (the engine drops the copies). False when no game
  /// said it takes them (an older engine, or none started with the bridges).
  Future<bool> pressButtons(int buttons, {int holdMs = 160, Duration gap = const Duration(milliseconds: 40)}) async {
    final slot = _pressSlot;
    if (slot != null) {
      final game = _gameAddresses[slot]!;
      final packet = RemotePacket.press(id: _pressId, buttons: buttons, holdMs: holdMs);
      _pressId = (_pressId + 1) & 0xFFFFFFFF;
      final bridge = _bridges[slot];
      for (var copy = 0; copy < 3; copy++) {
        if (copy > 0) await Future<void>.delayed(gap);
        try {
          bridge.send(packet, game.$1, game.$2);
        } on Object {
          // Closing.
        }
      }
      return true;
    }
    return false;
  }

  /// Remote Play's packets to every phone that wants them: by UDP to where its pad comes from, or
  /// on its control channel when it is on a cable.
  void sendStream(List<Uint8List> packets) {
    for (final phone in _phones) {
      if (phone.streamSize == null) continue;
      if (phone.padOnChannel) {
        for (final packet in packets) {
          phone.socket.add(packet);
        }
      } else if (phone.address case (final address, final port, final socket)) {
        for (final packet in packets) {
          socket.send(packet, address, port);
        }
      }
    }
  }
}
