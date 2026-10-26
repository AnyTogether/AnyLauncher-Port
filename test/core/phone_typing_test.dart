import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/remote/browser_pad_input.dart';
import 'package:anyps5_desktop/core/remote/paired_devices.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart' as server;
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';

/// A prompt exactly as the engine lays it out (RemotePad::EncodePrompt).
Uint8List enginePrompt({
  required int id,
  int kind = 2,
  int flags = 0,
  int type = 0,
  int enter = 0,
  int maxLength = 16,
  String title = '',
  String placeholder = '',
  String text = '',
}) {
  final parts = [
    for (final part in [title, placeholder, text]) utf8.encode(part),
  ];
  final bytes = Uint8List(24 + parts.fold<int>(0, (sum, part) => sum + part.length));
  final view = ByteData.sublistView(bytes)
    ..setUint32(0, 0x4B525041, Endian.little)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, bytes.length, Endian.little)
    ..setUint32(8, id, Endian.little)
    ..setUint16(16, maxLength, Endian.little);
  bytes
    ..[12] = kind
    ..[13] = flags
    ..[14] = type
    ..[15] = enter;
  var at = 24;
  for (var index = 0; index < 3; index++) {
    view.setUint16(18 + index * 2, parts[index].length, Endian.little);
    bytes.setRange(at, at + parts[index].length, parts[index]);
    at += parts[index].length;
  }
  return bytes;
}

void main() {
  group('packets', () {
    test('the engine\'s prompt is read, and a stand-in game writes the same bytes', () {
      final packet = enginePrompt(
        id: 9,
        flags: 1,
        type: 4,
        enter: 3,
        maxLength: 12,
        title: 'Kod gir',
        placeholder: '0000',
        text: '12',
      );
      final prompt = server.RemotePacket.prompt(packet)!.prompt!;
      expect(
        prompt,
        const server.RemoteTextPrompt(
          id: 9,
          title: 'Kod gir',
          placeholder: '0000',
          text: '12',
          maxLength: 12,
          multiline: true,
          keyboard: 'number',
          enter: 'go',
        ),
      );
      expect(server.RemotePacket.promptPacket(prompt), packet);
      expect(server.RemotePacket.prompt(enginePrompt(id: 2, kind: 1))!.prompt!.kind, 'keyboard');
    });

    test('a closed prompt and foreign packets are told apart', () {
      final closed = server.RemotePacket.prompt(enginePrompt(id: 0, kind: 0));
      expect(closed, isNotNull, reason: 'a closed prompt is a prompt');
      expect(closed!.prompt, isNull);
      final short = enginePrompt(id: 3, title: 'abc');
      expect(server.RemotePacket.prompt(short.sublist(0, short.length - 1)), isNull);
      final kind = enginePrompt(id: 3)..[12] = 7;
      expect(server.RemotePacket.prompt(kind), isNull);
      expect(server.RemotePacket.prompt(server.RemotePacket.hello()), isNull);
    });

    test('the typed text, as the engine reads it (RemotePad::DecodeText)', () {
      final packet = server.RemotePacket.text(
        prompt: 9,
        id: 4,
        action: server.RemoteTypedAction.submit,
        text: 'Ayşe 😀',
      );
      final utf = utf8.encode('Ayşe 😀');
      expect(packet.length, 20 + utf.length);
      expect(packet.sublist(0, 4), [0x41, 0x50, 0x52, 0x54]);
      expect(packet.sublist(4, 8), [1, 0, packet.length & 0xFF, packet.length >> 8]);
      expect(packet.sublist(8, 17), [9, 0, 0, 0, 4, 0, 0, 0, 1]);
      expect(packet.sublist(18, 20), [utf.length, 0]);
      expect(packet.sublist(20), utf);
      expect(server.RemotePacket.text(prompt: 1, id: 1, action: server.RemoteTypedAction.cancel, text: '')[16], 2);
      final long = server.RemotePacket.text(
        prompt: 1,
        id: 1,
        action: server.RemoteTypedAction.update,
        text: 'ğ' * 6000,
      );
      expect(long.length, lessThanOrEqualTo(server.RemotePacket.largestText));
      expect((long.length - 20) % 2, 0, reason: 'cut on a character');
    });

    test('the hello says the engine takes text', () {
      expect(server.RemotePacket.helloTakesText(server.RemotePacket.hello(takesPresses: true)), isFalse);
      expect(server.RemotePacket.helloTakesText(server.RemotePacket.hello(takesText: true)), isTrue);
    });
  });

  group('messages', () {
    test('round trips, and the phone\'s own code reads them', () {
      const prompt = server.RemoteTextPrompt(id: 7, title: 'Name', placeholder: 'Hero', text: 'Ab', maxLength: 16);
      for (final message in [
        const server.RemoteTextInput(prompt),
        const server.RemoteTextInput(null),
        const server.RemoteTyped(prompt: 7, typed: 'Kral ü', action: server.RemoteTypedAction.submit),
      ]) {
        expect(server.RemoteMessage.decode(message.text), message);
      }
      final read = Message.fromJson(const server.RemoteTextInput(prompt).text)! as TextInputUpdate;
      expect(read.prompt!.title, 'Name');
      expect(read.prompt!.maxLength, 16);
      final typed = server.RemoteMessage.decode(
        const Typed(prompt: 7, text: 'abc', action: TypedAction.update).toJson(),
      );
      expect(typed, const server.RemoteTyped(prompt: 7, typed: 'abc', action: server.RemoteTypedAction.update));
    });

    test('the browser pad\'s side', () {
      final typed = BrowserPadMessage.parse('{"t":"type","id":7,"text":"Selam","a":"submit"}');
      expect(typed, isA<BrowserPadTyped>());
      final page = typed! as BrowserPadTyped;
      expect(page.text, 'Selam');
      expect(page.action, server.RemoteTypedAction.submit);
      expect(BrowserPadMessage.parse('{"t":"type","id":7,"text":"x","a":"explode"}'), isNull);
      expect(BrowserPadMessage.parse('{"t":"type","id":0,"text":"x","a":"submit"}'), isNull);
      expect(BrowserPadMessage.parse('{"t":"type","id":7,"a":"submit"}'), isNull);
      expect(BrowserPadMessage.parse('{"t":"type","id":7,"a":"update","text":"${'a' * 3000}"}'), isNotNull);
      final open = jsonDecode(
        BrowserPadReply.ime(
          const server.RemoteTextPrompt(id: 7, title: 'Name', text: 'Ab', maxLength: 16, keyboard: 'number'),
        ),
      ) as Map<String, dynamic>;
      expect(open['t'], 'ime');
      expect(open['id'], 7);
      expect(open['max'], 16);
      expect(open['kb'], 'number');
      expect(BrowserPadReply.ime(null), '{"id":0,"t":"ime"}');
    });
  });

  group('relay', () {
    late Directory temp;
    late PairedDevices devices;
    late RemoteServer remote;
    late RawDatagramSocket game;
    late StreamController<Datagram> fromLauncher;

    setUp(() async {
      temp = temporaryFolder('typing');
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

    Future<FakePhone> welcomed(String id) async {
      final device = devices.add(id, 'Phone $id');
      final phone = await FakePhone.connect(remote.port!);
      phone.hello(id, 'Phone $id', key: device.key);
      await phone.next<Welcome>();
      return phone;
    }

    void say(List<int> data) => game.send(data, InternetAddress.loopbackIPv4, remote.bridgePorts.first);
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

    test('the prompt reaches the phone, and the text the game, twice', () async {
      final phone = await welcomed('phone-1');
      say(server.RemotePacket.hello(takesPresses: true, takesText: true));
      await settle();
      say(enginePrompt(id: 5, title: 'Name your save', text: 'Save'));
      final told = await phone.next<TextInputUpdate>();
      expect(told.prompt!.id, 5);
      expect(told.prompt!.title, 'Name your save');
      expect(remote.textPrompt?.id, 5);
      say(enginePrompt(id: 5, title: 'Name your save', text: 'Save'));
      final copies = fromLauncher.stream.take(2).toList().timeout(const Duration(seconds: 5));
      phone.send(const Typed(prompt: 5, text: 'Kral', action: TypedAction.submit));
      final sent = await copies;
      expect(sent.first.data.sublist(0, 4), [0x41, 0x50, 0x52, 0x54]);
      expect(utf8.decode(sent.first.data.sublist(20)), 'Kral');
      expect(sent.last.data, sent.first.data, reason: 'the same text twice, the engine counts it once');
      final away = await phone.next<TextInputUpdate>();
      expect(away.prompt, isNull, reason: 'answered, the keyboard goes away');
      say(enginePrompt(id: 5, title: 'Name your save', text: 'Save'));
      await settle();
      expect(remote.textPrompt, isNull, reason: 'the answered prompt said again does not come back');
      await phone.close();
    });

    test('text for another prompt, or for an engine that takes none, is dropped', () async {
      final phone = await welcomed('phone-1');
      say(server.RemotePacket.hello(takesPresses: true));
      await settle();
      say(enginePrompt(id: 5));
      await phone.next<TextInputUpdate>();
      final nothing = fromLauncher.stream.first.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => Datagram(Uint8List(0), InternetAddress.loopbackIPv4, 0),
      );
      phone.send(const Typed(prompt: 5, text: 'x', action: TypedAction.submit));
      expect((await nothing).data, isEmpty, reason: 'an older engine gets no text');
      say(server.RemotePacket.hello(takesText: true));
      await settle();
      final stillNothing = fromLauncher.stream.first.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => Datagram(Uint8List(0), InternetAddress.loopbackIPv4, 0),
      );
      phone.send(const Typed(prompt: 4, text: 'x', action: TypedAction.submit));
      expect((await stillNothing).data, isEmpty, reason: 'text for a prompt not open is dropped');
      await phone.close();
    });

    test('a phone that comes later sees the prompt; a closed one goes; a silent one ends', () async {
      final phone = await welcomed('phone-1');
      say(server.RemotePacket.hello(takesText: true));
      await settle();
      say(enginePrompt(id: 8, text: 'abc'));
      await phone.next<TextInputUpdate>();
      final late = await welcomed('phone-2');
      expect((await late.next<TextInputUpdate>()).prompt!.text, 'abc');
      say(enginePrompt(id: 0, kind: 0, maxLength: 0));
      expect((await late.next<TextInputUpdate>()).prompt, isNull);
      say(enginePrompt(id: 9));
      expect((await late.next<TextInputUpdate>()).prompt!.id, 9);
      final ended = await late.next<TextInputUpdate>();
      expect(ended.prompt, isNull, reason: 'a game gone with its keyboard open leaves the phones');
      expect(remote.textPrompt, isNull);
      await late.close();
      await phone.close();
    });
  });
}
