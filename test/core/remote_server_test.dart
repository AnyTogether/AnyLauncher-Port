import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/remote/paired_devices.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart' as server;
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/phone/packets.dart';

/// A running game's pad bridge: it says hello to the launcher's bridge port and reads what comes.
class FakeGame {
  FakeGame._(this.socket, this.port);

  static Future<FakeGame> open(int bridgePort) async =>
      FakeGame._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0), bridgePort);

  final RawDatagramSocket socket;
  final int port;
  late final Stream<Datagram> received = socket
      .where((event) => event == RawSocketEvent.read)
      .map((_) => socket.receive())
      .where((datagram) => datagram != null)
      .cast<Datagram>()
      .asBroadcastStream();

  void hello({int player = 0, bool takesPresses = false}) => socket.send(
    server.RemotePacket.hello(player: player, takesPresses: takesPresses),
    InternetAddress.loopbackIPv4,
    port,
  );

  /// An output packet answering [sequence].
  void answer(int sequence) {
    final bytes = Uint8List(32);
    ByteData.sublistView(bytes)
      ..setUint32(0, server.RemotePacket.outputMagic, Endian.little)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 32, Endian.little)
      ..setUint32(8, sequence, Endian.little)
      ..setUint32(12, 250, Endian.little)
      ..setUint64(16, 123456, Endian.little);
    bytes[24] = 200; // large motor
    bytes[26] = 1;
    bytes[27] = 0x11;
    socket.send(bytes, InternetAddress.loopbackIPv4, port);
  }
}

void main() {
  late Directory temp;
  late PairedDevices devices;
  late RemoteServer remote;
  final pairings = <PairingRequest>[];
  final requests = <(server.RemoteMessage, String)>[];
  final log = <String>[];
  var playerChanges = 0;
  var wishes = 0;

  setUp(() async {
    temp = temporaryFolder('remote');
    devices = PairedDevices(p.join(temp.path, 'RemoteDevices.json'));
    pairings.clear();
    requests.clear();
    log.clear();
    playerChanges = 0;
    wishes = 0;
    remote = RemoteServer(
      name: 'Test PC',
      devices: devices,
      events: RemoteEvents(
        pairing: pairings.add,
        connected: (name) => log.add('connected $name'),
        disconnected: () => log.add('disconnected'),
        latency: (ms) => log.add('latency $ms'),
        request: (message, device) => requests.add((message, device)),
        connecting: (name) => log.add('connecting $name'),
        players: () => playerChanges++,
        streamWishes: () => wishes++,
      ),
    );
    await remote.start();
  });

  tearDown(() async {
    await remote.stop();
    temp.deleteSync(recursive: true);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  /// Pairs a new phone and returns it with its welcome.
  Future<(FakePhone, Welcome)> paired(String id, String name) async {
    final phone = await FakePhone.connect(remote.port!);
    phone.hello(id, name);
    await phone.next<Pairing>();
    await settle();
    remote.respond(pairings.last.id, allow: true);
    return (phone, await phone.next<Welcome>());
  }

  test('a new phone is paired with a four-digit code the user allows', () async {
    final phone = await FakePhone.connect(remote.port!);
    phone.hello('phone-1', 'Utku iPhone');
    final pairing = await phone.next<Pairing>();
    expect(pairing.code, matches(RegExp(r'^\d{4}$')));
    await settle();
    expect(pairings.single.code, pairing.code);
    expect(pairings.single.deviceName, 'Utku iPhone');
    expect(log, ['connecting Utku iPhone']);
    remote.respond(pairings.single.id, allow: true);
    final welcome = await phone.next<Welcome>();
    expect(welcome.macName, 'Test PC');
    expect(welcome.udpPort, remote.udpPort);
    expect(welcome.session, isNot(BigInt.zero));
    expect(welcome.session.isNegative, isFalse, reason: 'an unsigned decimal string');
    expect(base64.decode(welcome.key), hasLength(32));
    await settle();
    expect(log.last, 'connected Utku iPhone');
    expect(remote.connectedDevices, ['Utku iPhone']);
    // The pairing is kept in the file, in the macOS launcher's format.
    final saved = jsonDecode(File(p.join(temp.path, 'RemoteDevices.json')).readAsStringSync()) as List<dynamic>;
    expect((saved.single as Map<String, dynamic>).keys, containsAll(['id', 'name', 'key', 'added']));
    expect(PairedDevices(devices.file).device('phone-1', welcome.key), isNotNull);
    await phone.close();
  });

  test('a paired phone comes back with its key and is welcomed without asking', () async {
    final (first, welcome) = await paired('phone-1', 'Phone');
    await first.close();
    await settle();
    expect(log, contains('disconnected'));
    final again = await FakePhone.connect(remote.port!);
    again.hello('phone-1', 'Phone', key: welcome.key);
    final second = await again.next<Welcome>();
    expect(second.key, welcome.key);
    expect(second.session, isNot(welcome.session));
    expect(pairings, hasLength(1));
    await again.close();
  });

  test('a wrong key is asked about again; denied, rejected and closed', () async {
    final phone = await FakePhone.connect(remote.port!);
    phone.hello('phone-2', 'Stranger', key: 'not-the-key');
    await phone.next<Pairing>();
    await settle();
    remote.respond(pairings.single.id, allow: false);
    final rejected = await phone.next<Rejected>();
    expect(rejected.reason, 'denied');
    await phone.closed.future.timeout(const Duration(seconds: 5));
    expect(log, contains('connecting null'));
    expect(devices.all, isEmpty);
  });

  test('another protocol version is rejected', () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${remote.port}');
    socket.add(jsonEncode({'type': 'hello', 'protocol': 2, 'deviceID': 'x', 'deviceName': 'x', 'key': null}));
    final reply = await socket.first.timeout(const Duration(seconds: 5));
    expect(Message.fromJson(reply as String), isA<Rejected>().having((r) => r.reason, 'reason', 'protocol'));
  });

  test('one new phone is asked about at a time: a second one is busy', () async {
    final first = await FakePhone.connect(remote.port!);
    first.hello('a', 'A');
    await first.next<Pairing>();
    final second = await FakePhone.connect(remote.port!);
    second.hello('b', 'B');
    expect((await second.next<Rejected>()).reason, 'busy');
    await first.close();
  });

  test('four phones, one slot and bridge each; a fifth is busy', () async {
    final phones = <FakePhone>[];
    for (var index = 0; index < 4; index++) {
      phones.add((await paired('phone-$index', 'Phone $index')).$1);
    }
    expect(remote.connectedDevices, ['Phone 0', 'Phone 1', 'Phone 2', 'Phone 3']);
    expect(remote.bridgePorts, hasLength(4));
    expect(remote.bridgeEnvironment.keys, [
      'ANYPS5_REMOTE_PAD',
      'ANYPS5_REMOTE_PAD_2',
      'ANYPS5_REMOTE_PAD_3',
      'ANYPS5_REMOTE_PAD_4',
    ]);
    expect(remote.bridgeEnvironment['ANYPS5_REMOTE_PAD'], '127.0.0.1:${remote.bridgePorts.first}');
    final fifth = await FakePhone.connect(remote.port!);
    fifth.hello('phone-5', 'Five');
    expect((await fifth.next<Rejected>()).reason, 'busy');
    // A phone leaving frees its slot for the next.
    await phones[1].close();
    await settle();
    final (late, _) = await paired('phone-6', 'Six');
    expect(remote.connectedDevices, ['Phone 0', 'Six', 'Phone 2', 'Phone 3']);
    for (final phone in [...phones, late]) {
      await phone.close();
    }
  });

  test('the pad goes from the phone by UDP to its game bridge, and the answer comes back', () async {
    final (phone, welcome) = await paired('phone-1', 'Phone');
    final game = await FakeGame.open(remote.bridgePorts.first);
    game.hello(player: 1);
    await settle();
    expect(playerChanges, 1);
    expect(remote.phonePlayers, {'phone-1': 1});
    final udp = await phone.openUdp();
    final arrived = game.received.first.timeout(const Duration(seconds: 5));
    udp.send(phone.input(welcome.session, sequence: 7), InternetAddress.loopbackIPv4, welcome.udpPort);
    final datagram = await arrived;
    expect(datagram.data, phone.input(welcome.session, sequence: 7));
    expect(ByteData.sublistView(datagram.data).getUint32(32, Endian.little), PadButton.cross);
    // The game's answer reaches the phone, which reads it with its own decoder.
    final answered = udp
        .where((event) => event == RawSocketEvent.read)
        .map((_) => udp.receive())
        .where((d) => d != null)
        .first
        .timeout(const Duration(seconds: 5));
    game.answer(7);
    final output = decodeOutput((await answered)!.data)!;
    expect(output.sequence, 7);
    expect(output.large, 200);
    expect(output.lightValid, isTrue);
    expect(output.sentMicros, 123456);
    await phone.close();
  });

  test('pad packets with another session or from an unpaired phone are dropped', () async {
    final (phone, welcome) = await paired('phone-1', 'Phone');
    final game = await FakeGame.open(remote.bridgePorts.first);
    game.hello();
    await settle();
    final udp = await phone.openUdp();
    final got = <Datagram>[];
    final subscription = game.received.listen(got.add);
    udp.send(phone.input(welcome.session + BigInt.one), InternetAddress.loopbackIPv4, welcome.udpPort);
    udp.send(Uint8List(80), InternetAddress.loopbackIPv4, welcome.udpPort);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(got, isEmpty);
    await subscription.cancel();
    await phone.close();
  });

  test('on a cable the pad goes as binary frames on the control channel, and comes back so', () async {
    final (phone, welcome) = await paired('phone-1', 'Phone');
    final game = await FakeGame.open(remote.bridgePorts.first);
    game.hello(player: 2);
    await settle();
    final arrived = game.received.first.timeout(const Duration(seconds: 5));
    phone.socket.add(phone.input(welcome.session, sequence: 3));
    expect((await arrived).data, phone.input(welcome.session, sequence: 3));
    final back = phone.binary.stream.first.timeout(const Duration(seconds: 5));
    game.answer(3);
    expect(decodeOutput(await back)!.sequence, 3);
    await phone.close();
  });

  test('a second phone uses the second bridge', () async {
    final (first, _) = await paired('a', 'A');
    final (second, welcome) = await paired('b', 'B');
    final one = await FakeGame.open(remote.bridgePorts[0]);
    final two = await FakeGame.open(remote.bridgePorts[1]);
    one.hello(player: 1);
    two.hello(player: 2);
    await settle();
    expect(remote.phonePlayers, {'a': 1, 'b': 2});
    final arrived = two.received.first.timeout(const Duration(seconds: 5));
    final udp = await second.openUdp();
    udp.send(second.input(welcome.session), InternetAddress.loopbackIPv4, welcome.udpPort);
    expect((await arrived).data, second.input(welcome.session));
    await first.close();
    await second.close();
  });

  test('launcher-mode requests reach the launcher only from welcomed phones', () async {
    final stranger = await FakePhone.connect(remote.port!);
    stranger.send(const Launch('PPSA01234'));
    final (phone, _) = await paired('phone-1', 'Phone');
    phone
      ..send(const SelectGame('g1'))
      ..send(const Launch('g1'))
      ..send(const Command('left'))
      ..send(const WantArt('g1'))
      ..send(const CloseGame())
      ..send(const Home())
      ..send(const SaveLayout('g1', '{"x":1}'))
      ..send(const KeyFrame())
      ..send(const Latency(12.5))
      ..send(const StreamRequest(on: true, width: 100, height: 50));
    await settle();
    await settle();
    expect(requests.map((request) => request.$1.type), [
      'select',
      'launch',
      'command',
      'wantArt',
      'close',
      'home',
      'saveLayout',
      'keyFrame',
    ]);
    expect(requests.every((request) => request.$2 == 'phone-1'), isTrue);
    expect((requests[6].$1 as server.RemoteSaveLayout).layout, '{"x":1}');
    expect(log, contains('latency 12.5'));
    expect(wishes, 1);
    expect(remote.streamWishes, [('phone-1', 160, 90)], reason: 'the smallest picture the launcher makes');
    await stranger.close();
    await phone.close();
  });

  test('what the launcher publishes, the phone reads with its own code', () async {
    final (phone, _) = await paired('phone-1', 'Phone');
    remote.publish(
      const server.RemoteLibrary(
        games: [
          server.RemoteGame(
            id: 'g1',
            name: 'Astro',
            state: server.RemoteGameState.installed,
            art: 'a1',
            trophies: '3/40',
          ),
          server.RemoteGame(id: 'g2', name: 'Stray', state: server.RemoteGameState.locked, art: 'a2'),
        ],
        selected: 'g1',
        language: 'tr',
      ),
    );
    final library = await phone.next<Library>();
    expect(library.games.map((game) => game.name), ['Astro', 'Stray']);
    expect(library.games.first.state, GameState.installed);
    expect(library.games.first.trophies, '3/40');
    expect(library.selected, 'g1');
    expect(library.running, isNull);
    expect(library.language, 'tr');
    remote.tell(const server.RemoteLook(deep: '#101020', middle: '#303060', accent: '#7FA0FF'), 'phone-1');
    expect((await phone.next<LookUpdate>()).accent, '#7FA0FF');
    remote.publish(
      const server.RemoteActivityUpdate(
        server.RemoteActivity(id: 'g2', phase: server.RemotePhase.relink, updating: false, fraction: 0.5, elapsed: 12),
      ),
    );
    final activity = (await phone.next<ActivityUpdate>()).activity!;
    expect(activity.phase, ActivityPhase.relink);
    expect(activity.fraction, 0.5);
    expect(activity.elapsed, const Duration(seconds: 12));
    remote.publish(const server.RemoteTrophy(name: 'First', detail: 'Do it', grade: 'gold'));
    expect((await phone.next<TrophyEarned>()).grade, 'gold');
    remote.publish(const server.RemoteArt(id: 'g1', icon: 'AAEC'));
    expect((await phone.next<Art>()).icon, 'AAEC');
    await phone.close();
  });

  test('the same phone on a new connection takes over from its old one', () async {
    final (old, welcome) = await paired('phone-1', 'Phone');
    final fresh = await FakePhone.connect(remote.port!);
    fresh.hello('phone-1', 'Phone', key: welcome.key);
    await fresh.next<Welcome>();
    await old.closed.future.timeout(const Duration(seconds: 5));
    await settle();
    expect(remote.connectedDevices, ['Phone']);
    await fresh.close();
  });

  test('a plain HTTP request gets a short answer, not a crash', () async {
    final client = HttpClient();
    final request = await client.get('127.0.0.1', remote.port!, '/');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.upgradeRequired);
    client.close(force: true);
  });

  test('stop frees the ports', () async {
    final port = remote.port!;
    final udp = remote.udpPort!;
    await remote.stop();
    final again = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    final datagram = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udp);
    await again.close();
    datagram.close();
    await remote.start();
  });

  group('protocol', () {
    test('every message survives a round trip, with the JSON the phone writes', () {
      final messages = <server.RemoteMessage>[
        const server.RemoteHello(protocol: 1, deviceId: 'd', deviceName: 'n'),
        const server.RemotePairing('0042'),
        server.RemoteWelcome(session: BigInt.parse('18446744073709551615'), udpPort: 5, macName: 'm', key: 'k'),
        const server.RemoteRejected('busy'),
        const server.RemoteLatency(3.5),
        const server.RemoteLibrary(games: [], language: 'en'),
        const server.RemoteArt(id: 'i'),
        const server.RemoteWantArt('i'),
        const server.RemoteCommand('back'),
        const server.RemoteSelect('i'),
        const server.RemoteLaunch('i'),
        const server.RemoteClose(),
        const server.RemoteHome(),
        const server.RemoteSaveLayout('i', null),
        const server.RemoteTrophy(name: 'n', detail: 'd', grade: 'bronze'),
        const server.RemoteActivityUpdate(null),
        const server.RemoteLook(deep: '#000000', middle: '#111111', accent: '#222222'),
        const server.RemoteStream(on: false),
        const server.RemoteKeyFrame(),
        const server.RemoteStreaming('noGame'),
      ];
      for (final message in messages) {
        expect(server.RemoteMessage.decode(message.text), message, reason: message.type);
      }
      expect(server.RemoteMessage.decode('{"type":"nope"}'), isNull);
      expect(server.RemoteMessage.decode('not json'), isNull);
      expect(server.RemoteMessage.decode('{"type":"hello"}'), isNull);
      // What the phone app writes, the launcher reads.
      expect(
        server.RemoteMessage.decode(const Hello(deviceID: 'd', deviceName: 'n', key: null).toJson()),
        const server.RemoteHello(protocol: 1, deviceId: 'd', deviceName: 'n'),
      );
      expect(
        server.RemoteMessage.decode(const StreamRequest(on: true, width: 640, height: 360).toJson()),
        const server.RemoteStream(on: true, width: 640, height: 360),
      );
    });

    test('activities that look alike are not sent again', () {
      const a = server.RemoteActivity(
        id: 'g',
        phase: server.RemotePhase.copy,
        updating: false,
        fraction: 0.5,
        elapsed: 1,
      );
      const b = server.RemoteActivity(
        id: 'g',
        phase: server.RemotePhase.copy,
        updating: false,
        fraction: 0.505,
        elapsed: 9,
      );
      const c = server.RemoteActivity(
        id: 'g',
        phase: server.RemotePhase.copy,
        updating: false,
        fraction: 0.52,
        elapsed: 9,
      );
      expect(server.RemoteActivity.same(a, b), isTrue);
      expect(server.RemoteActivity.same(a, c), isFalse);
      expect(server.RemoteActivity.same(null, null), isTrue);
      expect(server.RemoteActivity.same(a, null), isFalse);
    });

    test('packets: input session, output, hello and its player', () {
      final input = encodeInput(
        sequence: 1,
        sentMicros: 2,
        session: BigInt.parse('18446744073709551615'),
        state: PadState(),
      );
      expect(server.RemotePacket.inputSession(input), -1, reason: 'all 64 bits set');
      expect(server.RemotePacket.inputSession(input.sublist(0, 79)), isNull);
      expect(server.RemotePacket.isHello(server.RemotePacket.hello(player: 3)), isTrue);
      expect(server.RemotePacket.helloPlayer(server.RemotePacket.hello(player: 3)), 3);
      expect(server.RemotePacket.helloPlayer(server.RemotePacket.hello()), isNull);
      expect(server.RemotePacket.isOutput(Uint8List(32)), isFalse);
    });

    test('a press (APRP): its 24 bytes, and the hello bit that says the engine takes it', () {
      final press = server.RemotePacket.press(id: 0x01020304, buttons: server.RemotePacket.options);
      expect(press, [
        0x41, 0x50, 0x52, 0x50, // APRP
        1, 0, 24, 0, // version 1, size 24
        0x04, 0x03, 0x02, 0x01, // the id
        0x08, 0, 0, 0, // Options
        160, 0, // held 160 ms
        0, 0, 0, 0, 0, 0,
      ]);
      expect(server.RemotePacket.helloTakesPresses(server.RemotePacket.hello(takesPresses: true)), isTrue);
      expect(server.RemotePacket.helloTakesPresses(server.RemotePacket.hello(player: 1)), isFalse);
      expect(server.RemotePacket.helloTakesPresses(Uint8List(16)), isFalse, reason: 'not a hello');
    });
  });

  test('Options pressed on the game\'s first player only when its hello says the engine takes presses', () async {
    final game = await FakeGame.open(remote.bridgePorts.first);
    final got = <Uint8List>[];
    final listening = game.received.listen((datagram) => got.add(datagram.data));
    expect(await remote.pressButtons(server.RemotePacket.options), isFalse, reason: 'no game said hello');
    game.hello(player: 1);
    await settle();
    expect(remote.gameTakesPresses, isFalse);
    expect(await remote.pressButtons(server.RemotePacket.options), isFalse, reason: 'an older engine drops presses');
    game.hello(player: 1, takesPresses: true);
    await settle();
    expect(remote.gameTakesPresses, isTrue);
    expect(await remote.pressButtons(server.RemotePacket.options), isTrue);
    await settle();
    expect(got, hasLength(3), reason: 'the same press three times against loss');
    expect(got.toSet().map((bytes) => bytes.join(',')).toSet(), hasLength(1));
    final view = ByteData.sublistView(got.first);
    expect(view.getUint32(0, Endian.little), server.RemotePacket.pressMagic);
    expect(view.getUint32(12, Endian.little), 0x0008);
    final first = view.getUint32(8, Endian.little);
    expect(await remote.pressButtons(server.RemotePacket.options), isTrue);
    await settle();
    expect(
      ByteData.sublistView(got.last).getUint32(8, Endian.little),
      (first + 1) & 0xFFFFFFFF,
      reason: 'a new id each press',
    );
    await listening.cancel();
    game.socket.close();
  });
}
