import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/remote/browser_pad_access.dart';
import 'package:anyps5_desktop/core/remote/browser_pad_input.dart';
import 'package:anyps5_desktop/core/remote/browser_pad_server.dart';
import 'package:anyps5_desktop/core/remote/paired_devices.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart';
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';

/// A game's pad channel on one bridge: says hello, reads the pad packets.
class Game {
  Game._(this.socket, this.bridge);
  static Future<Game> open(int bridge) async =>
      Game._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0), bridge);
  final RawDatagramSocket socket;
  final int bridge;
  late final Stream<Uint8List> packets = socket
      .where((event) => event == RawSocketEvent.read)
      .map((_) => socket.receive())
      .where((datagram) => datagram != null && RemotePacket.inputSession(datagram.data) != null)
      .map((datagram) => datagram!.data)
      .asBroadcastStream();

  void hello(int player) => socket.send(RemotePacket.hello(player: player), InternetAddress.loopbackIPv4, bridge);
  void send(List<int> data) => socket.send(data, InternetAddress.loopbackIPv4, bridge);
  int buttons(Uint8List packet) => ByteData.sublistView(packet).getUint32(32, Endian.little);
}

/// A headless browser's page socket.
class Page {
  Page._(this.socket);
  final WebSocket socket;
  final List<Map<String, dynamic>> _got = [];
  final _arrivals = StreamController<void>.broadcast();
  bool closed = false;

  static Future<Page> open(int port, {required String? cookie, String? origin}) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {'Origin': origin ?? 'http://127.0.0.1:$port', 'Cookie': ?cookie},
    );
    final page = Page._(socket);
    socket.listen(
      (data) {
        if (data is String) page._got.add(jsonDecode(data) as Map<String, dynamic>);
        page._arrivals.add(null);
      },
      onDone: () {
        page.closed = true;
        page._arrivals.add(null);
      },
    );
    return page;
  }

  void send(Map<String, Object> message) => socket.add(jsonEncode(message));

  /// The next message of [type] (skipping others), or null when none comes in [seconds].
  Future<Map<String, dynamic>?> next(String type, {int seconds = 5, bool Function(Map<String, dynamic>)? where}) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(deadline)) {
      while (_got.isNotEmpty) {
        final message = _got.removeAt(0);
        if (message['t'] == type && (where == null || where(message))) return message;
      }
      if (closed) return null;
      await _arrivals.stream.first.timeout(deadline.difference(DateTime.now()), onTimeout: () {});
    }
    return null;
  }

  Future<void> close() => socket.close();
}

void main() {
  late Directory temp;
  late PairedDevices devices;
  late RemoteServer remote;
  late BrowserPadServer pads;
  final pairings = <PairingRequest>[];
  final requests = <RemoteMessage>[];
  final page = utf8.encode('<!doctype html><title>pad</title>');
  final client = HttpClient();

  setUp(() async {
    temp = temporaryFolder('browserpad');
    devices = PairedDevices(p.join(temp.path, 'RemoteDevices.json'));
    pairings.clear();
    requests.clear();
    remote = RemoteServer(
      name: 'Test PC',
      devices: devices,
      events: RemoteEvents(pairing: pairings.add, request: (message, _) => requests.add(message)),
    );
    await remote.start();
    pads = BrowserPadServer(
      host: '127.0.0.1',
      page: page,
      controlPort: remote.port!,
      devices: devices,
      players: () => remote.phonePlayers,
    );
    await pads.start();
  });

  tearDown(() async {
    await pads.stop();
    await remote.stop();
    temp.deleteSync(recursive: true);
  });

  int port() => pads.boundPort!;

  Future<(int, HttpHeaders, List<int>)> get(String target, {Map<String, String> headers = const {}}) async {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:${port()}$target'));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return (response.statusCode, response.headers, body);
  }

  Future<int> refusedWith({String? origin, String? cookie, String? host}) async {
    final socket = await Socket.connect('127.0.0.1', port());
    socket.write(
      'GET /ws HTTP/1.1\r\nHost: ${host ?? '127.0.0.1:${port()}'}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n'
      '${origin == null ? '' : 'Origin: $origin\r\n'}${cookie == null ? '' : 'Cookie: $cookie\r\n'}\r\n',
    );
    final head = await utf8.decoder.bind(socket).first;
    socket.destroy();
    return int.parse(head.split(' ')[1]);
  }

  /// Scans the QR code: the cookie the token turns into.
  Future<String> scan() async {
    final url = pads.pairingUrl!;
    expect(url.host, '127.0.0.1');
    final (status, headers, _) = await get(
      '/?${url.query}',
      headers: {'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)'},
    );
    expect(status, 303);
    expect(headers.value('location'), '/');
    return headers.value('set-cookie')!.split(';').first;
  }

  Future<void> waitFor(bool Function() condition) async {
    for (var tries = 0; tries < 200 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  /// A browser through pairing, the user answering on the computer.
  Future<Page> joined(String cookie, {bool allow = true}) async {
    final browser = await Page.open(port(), cookie: cookie);
    final code = (await browser.next('pairing'))!['code'] as String;
    expect(code, matches(RegExp(r'^\d{4}$')));
    await waitFor(() => pairings.any((request) => request.code == code));
    final request = pairings.lastWhere((request) => request.code == code);
    expect(request.deviceName, 'iPhone · Web', reason: "the computer's pairing card names the browser");
    remote.respond(request.id, allow: allow);
    return browser;
  }

  Future<Uint8List?> packetWith(Game game, bool Function(Uint8List) test) => game.packets
      .firstWhere(test)
      .timeout(const Duration(seconds: 3))
      .then<Uint8List?>((value) => value, onError: (_) => null);

  test('a browser scans, pairs and drives the game', () async {
    final cookie = await scan();
    final (status, headers, body) = await get('/', headers: {'Cookie': cookie});
    expect(status, 200);
    expect(body, page);
    expect(headers.value('content-security-policy'), contains('connect-src ws://127.0.0.1:${port()}'));
    expect(headers.value('referrer-policy'), 'no-referrer');

    final browser = await joined(cookie);
    expect((await browser.next('welcome'))!['host'], 'Test PC');
    expect(pads.connected.map((pad) => pad.$3), [true]);
    expect(
      devices.all.where((device) => device.id.startsWith(BrowserPadAccess.devicePrefix)).single.name,
      'iPhone · Web',
    );

    final game = await Game.open(remote.bridgePorts[0]);
    game.hello(1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final arrived = packetWith(game, (packet) => game.buttons(packet) != 0);
    browser.send({
      't': 'pad',
      'b': PadBits.cross,
      's': [10, 20, 30, 40],
      'l2': 0,
      'r2': 200,
    });
    final input = (await arrived)!;
    expect(game.buttons(input), PadBits.cross | PadBits.r2);
    expect(input.sublist(36, 42), [10, 20, 30, 40, 0, 200]);
    expect(await browser.next('player', where: (m) => m['n'] == 1), isNotNull);

    // The game's vibration and light bar come back to the page.
    final output = Uint8List(32);
    ByteData.sublistView(output)
      ..setUint32(0, RemotePacket.outputMagic, Endian.little)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 32, Endian.little);
    output
      ..[24] = 180
      ..[26] = 1
      ..[28] = 0x60
      ..[29] = 0xFF;
    game.send(output);
    final out = (await browser.next('out'))!;
    expect(out['big'], 180);
    expect(out['rgb'], '#0060ff');

    // PS and Create are the launcher's, as on the phone app.
    browser
      ..send({'t': 'btn', 'n': 'ps'})
      ..send({'t': 'btn', 'n': 'create'});
    await waitFor(() => requests.length >= 2);
    expect(requests, [const RemoteHome(), const RemoteCommand('capture')]);

    // Quiet page, held keys: the keep-alive repeats the pad, then lets go.
    var repeats = 0;
    final released = Completer<void>();
    final watch = game.packets.listen((packet) {
      if (game.buttons(packet) == 0) {
        if (!released.isCompleted) released.complete();
      } else {
        repeats++;
      }
    });
    await released.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    await watch.cancel();
    expect(repeats, greaterThanOrEqualTo(2));
    expect(released.isCompleted, isTrue, reason: 'a page gone quiet lets the buttons go');

    browser.send({'t': 'ping', 'at': 123.5});
    expect((await browser.next('pong'))!['at'], 123.5);
    await browser.close();
  });

  test('a reload comes back without asking again', () async {
    final cookie = await scan();
    final first = await joined(cookie);
    expect(await first.next('welcome'), isNotNull);
    final again = await Page.open(port(), cookie: cookie);
    expect(await again.next('welcome'), isNotNull);
    expect(pairings, hasLength(1), reason: "the session's key let it straight in");
    expect(await first.next('anything', seconds: 1), isNull);
    expect(first.closed, isTrue, reason: 'the page it replaced is let go');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(remote.connectedDeviceIds, hasLength(1));
    await again.close();
  });

  test('denied ends the session', () async {
    final cookie = await scan();
    final browser = await joined(cookie, allow: false);
    expect((await browser.next('rejected'))!['reason'], 'denied');
    expect(
      await refusedWith(origin: 'http://127.0.0.1:${port()}', cookie: cookie),
      403,
      reason: 'a refused browser scans again',
    );
    expect(devices.all.where((device) => device.id.startsWith(BrowserPadAccess.devicePrefix)), isEmpty);
  });

  test('browsers take the next seats after the phone app', () async {
    final known = devices.add('phone-1', 'Pixel 8');
    final phone = await FakePhone.connect(remote.port!);
    phone.hello('phone-1', 'Pixel 8', key: known.key);
    await phone.next<Welcome>();
    final first = await joined(await scan());
    expect(await first.next('welcome'), isNotNull);
    final second = await joined(await scan());
    expect(await second.next('welcome'), isNotNull);
    expect(remote.connectedDeviceIds, hasLength(3));

    // The game's third phone channel answers to the second browser alone.
    final games = [for (var slot = 0; slot < 3; slot++) await Game.open(remote.bridgePorts[slot])];
    for (var slot = 0; slot < 3; slot++) {
      games[slot].hello(slot + 1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final reached = packetWith(games[2], (packet) => games[2].buttons(packet) == PadBits.triangle);
    second.send({'t': 'pad', 'b': PadBits.triangle});
    expect(await reached, isNotNull);
    expect(await second.next('player', where: (m) => m['n'] == 3), isNotNull);
    expect(await first.next('player', where: (m) => m['n'] == 2), isNotNull);
    await phone.close();
    await first.close();
    await second.close();
  });

  test('a browser waits while another is asked about', () async {
    final first = await Page.open(port(), cookie: await scan());
    expect(await first.next('pairing'), isNotNull);
    final second = await Page.open(port(), cookie: await scan());
    expect(await second.next('busy'), isNotNull, reason: 'one new device is asked about at a time');
    await waitFor(() => pairings.isNotEmpty);
    remote.respond(pairings.first.id, allow: true);
    expect(await first.next('welcome'), isNotNull);
    expect(await second.next('pairing', seconds: 6), isNotNull, reason: 'then it is its turn');
    await first.close();
    await second.close();
  });

  test('every seat taken', () async {
    final browsers = <Page>[];
    for (var index = 0; index < RemoteServer.maxPhones; index++) {
      final browser = await joined(await scan());
      expect(await browser.next('welcome'), isNotNull);
      browsers.add(browser);
    }
    final late = await Page.open(port(), cookie: await scan());
    expect(await late.next('busy'), isNotNull);
    for (final browser in [...browsers, late]) {
      await browser.close();
    }
  });

  test('other origins and hosts are refused', () async {
    final cookie = await scan();
    final origin = 'http://127.0.0.1:${port()}';
    expect(await refusedWith(origin: 'http://evil.example', cookie: cookie), 403);
    expect(await refusedWith(cookie: cookie), 403);
    expect(await refusedWith(origin: origin), 403);
    expect(await refusedWith(origin: origin, cookie: '${BrowserPadAccess.cookieName}=forged'), 403);
    expect(await refusedWith(origin: origin, cookie: cookie, host: 'rebound.example:${port()}'), 403);
    expect((await get('/', headers: {'Origin': 'http://evil.example'})).$1, 403);
    expect((await get('/admin')).$1, 404);
  });

  test('a spent or wrong token gives no cookie', () async {
    final url = pads.pairingUrl!;
    expect((await get('/?${url.query}')).$1, 303);
    final again = await get('/?${url.query}');
    expect(again.$1, 200, reason: 'the page, which then says to scan again');
    expect(again.$2.value('set-cookie'), isNull);
    expect((await get('/?t=guess')).$2.value('set-cookie'), isNull);
  });

  test('token guessing is slowed down', () async {
    final statuses = [for (var i = 0; i < 8; i++) (await get('/?t=guess$i')).$1];
    expect(statuses.take(5), everyElement(200));
    expect(statuses.last, 429);
  });

  test('request floods are slowed down', () async {
    final statuses = [for (var i = 0; i < 40; i++) (await get('/')).$1];
    expect(statuses.first, 200);
    expect(statuses, contains(429));
  });

  test('stopping ends sessions and forgets the browsers', () async {
    final cookie = await scan();
    final browser = await joined(cookie);
    expect(await browser.next('welcome'), isNotNull);
    await pads.stop();
    expect(await browser.next('anything', seconds: 1), isNull);
    expect(browser.closed, isTrue);
    expect(devices.all.where((device) => device.id.startsWith(BrowserPadAccess.devicePrefix)), isEmpty);
    expect(pads.access.all, isEmpty);
    await pads.start();
    expect(await refusedWith(origin: 'http://127.0.0.1:${port()}', cookie: cookie), 403);
  });

  test('the LAN address is private', () async {
    final address = await BrowserPadServer.lanAddress();
    if (address == null) return;
    expect(BrowserPadAccess.isLocal(address), isTrue);
    expect(address, isNot(startsWith('127.')));
  });
}
