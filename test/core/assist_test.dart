import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/remote/assist.dart';
import 'package:anyps5_desktop/core/remote/paired_devices.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart' as server;
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';

void main() {
  group('wire', () {
    test('the assist datagram as the engine reads it', () {
      expect(server.RemotePacket.assist(controllers: true), [
        0x41,
        0x50,
        0x52,
        0x41,
        1,
        0,
        16,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(server.RemotePacket.assist(controllers: false)[8], 0);
      expect(
        server.RemotePacket.helloTakesAssist(server.RemotePacket.hello(takesPresses: true, takesText: true)),
        isFalse,
      );
      expect(server.RemotePacket.helloTakesAssist(server.RemotePacket.hello(takesAssist: true)), isTrue);
    });

    test('a helper\'s input is marked in byte 13, nothing else', () {
      final input = Uint8List(80);
      ByteData.sublistView(input)
        ..setUint32(0, server.RemotePacket.inputMagic, Endian.little)
        ..setUint16(4, 1, Endian.little)
        ..setUint16(6, 80, Endian.little)
        ..setUint64(24, 9, Endian.little);
      final marked = server.RemotePacket.helping(input);
      expect(marked[13], 1);
      expect([...marked]..[13] = 0, input);
      final hello = server.RemotePacket.hello();
      expect(server.RemotePacket.helping(hello), hello, reason: 'only inputs are marked');
    });
  });

  group('setting', () {
    test('kept as text, read back', () {
      expect(AssistTarget.stored(null), const AssistOff());
      expect(AssistTarget.stored(''), const AssistOff());
      expect(AssistTarget.stored('controllers'), const AssistControllers());
      expect(AssistTarget.stored('phone-1'), const AssistDevice('phone-1'));
      for (final target in [const AssistOff(), const AssistControllers(), const AssistDevice('browser-x')]) {
        expect(AssistTarget.stored(target.stored), target);
      }
      expect(const AssistControllers().controllers, isTrue);
      expect(const AssistControllers().devices, isEmpty);
      expect(const AssistDevice('phone-1').devices, {'phone-1'});
    });

    test('the choices keep a chosen device that left', () {
      final choices = AssistTarget.choices(
        [('phone-1', 'Pixel 8'), ('phone-2', 'iPhone')],
        const AssistDevice('phone-9'),
        {'phone-9': 'Galaxy'},
      );
      expect(
        [for (final (target, _) in choices) target],
        [
          const AssistOff(),
          const AssistControllers(),
          const AssistDevice('phone-1'),
          const AssistDevice('phone-2'),
          const AssistDevice('phone-9'),
        ],
      );
      expect(choices.last.$2, 'Galaxy');
    });
  });

  group('relay', () {
    late Directory temp;
    late PairedDevices devices;
    late RemoteServer remote;
    late RawDatagramSocket game;
    late StreamController<Datagram> fromLauncher;

    setUp(() async {
      temp = temporaryFolder('assist');
      devices = PairedDevices(p.join(temp.path, 'RemoteDevices.json'));
      remote = RemoteServer(name: 'Test PC', devices: devices);
      await remote.start();
      game = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      fromLauncher = StreamController<Datagram>.broadcast();
      game.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = game.receive();
        if (datagram != null) fromLauncher.add(datagram);
      });
    });

    tearDown(() async {
      game.close();
      await fromLauncher.close();
      await remote.stop();
      temp.deleteSync(recursive: true);
    });

    void hello({bool takesAssist = true}) => game.send(
      server.RemotePacket.hello(takesPresses: true, takesText: true, takesAssist: takesAssist),
      InternetAddress.loopbackIPv4,
      remote.bridgePorts.first,
    );

    Future<Datagram?> next() => fromLauncher.stream.first
        .then<Datagram?>((datagram) => datagram)
        .timeout(const Duration(milliseconds: 400), onTimeout: () => null);

    test('each hello is answered with whether controllers help; a change is said at once', () async {
      var answer = next();
      hello();
      expect((await answer)?.data, server.RemotePacket.assist(controllers: false));
      answer = next();
      remote.setAssist(devices: const {}, controllers: true);
      expect((await answer)?.data, server.RemotePacket.assist(controllers: true));
      answer = next();
      hello();
      expect((await answer)?.data, server.RemotePacket.assist(controllers: true));
      answer = next();
      hello(takesAssist: false);
      expect(await answer, isNull, reason: 'an engine that does not take assist is not told');
    });

    test('a helping phone\'s pad is marked, another\'s is not', () async {
      final device = devices.add('phone-1', 'Phone');
      final phone = await FakePhone.connect(remote.port!);
      phone.hello('phone-1', 'Phone', key: device.key);
      final welcome = await phone.next<Welcome>();
      var answer = next();
      hello();
      await answer;
      final udp = await phone.openUdp();
      answer = next();
      udp.send(phone.input(welcome.session, sequence: 1), InternetAddress.loopbackIPv4, welcome.udpPort);
      expect((await answer)!.data[13], 0);
      remote.setAssist(devices: const {'phone-1'}, controllers: false);
      answer = next();
      udp.send(phone.input(welcome.session, sequence: 2), InternetAddress.loopbackIPv4, welcome.udpPort);
      expect((await answer)!.data[13], 1, reason: 'set to help, its pad is marked');
      remote.setAssist(devices: const {}, controllers: false);
      answer = next();
      udp.send(phone.input(welcome.session, sequence: 3), InternetAddress.loopbackIPv4, welcome.udpPort);
      expect((await answer)!.data[13], 0);
      await phone.close();
    });
  });
}
