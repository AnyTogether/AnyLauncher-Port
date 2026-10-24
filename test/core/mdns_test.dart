import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/remote/mdns.dart';
import 'package:test/test.dart';

void main() {
  MdnsResponder responder({int mdnsPort = 5353}) => MdnsResponder(
    instance: 'Utku PC',
    serviceType: '_anyps5-remote._tcp',
    port: 47700,
    hostName: 'utku-pc.home',
    addresses: [InternetAddress('192.168.1.20')],
    mdnsPort: mdnsPort,
  );

  test('names encode as labels and decode back, following compression pointers', () {
    expect(DnsPacket.encodeName('_anyps5-remote._tcp.local'), [
      14, ...'_anyps5-remote'.codeUnits, 4, ...'_tcp'.codeUnits, 5, ...'local'.codeUnits, 0, //
    ]);
    // A question for "a.local" then an answer whose name points back at it (0xC00C).
    final bytes = Uint8List.fromList([
      0, 7, 0x84, 0, 0, 1, 0, 1, 0, 0, 0, 0, //
      1, 0x61, 5, ...'local'.codeUnits, 0, 0, 1, 0, 1,
      0xC0, 12, 0, 1, 0x80, 1, 0, 0, 0, 120, 0, 4, 10, 0, 0, 2,
    ]);
    final packet = DnsPacket.decode(bytes)!;
    expect(packet.id, 7);
    expect(packet.isResponse, isTrue);
    expect(packet.questions.single.name, 'a.local');
    expect(packet.answers.single.name, 'a.local');
    expect(packet.answers.single.cacheFlush, isTrue);
    expect(packet.answers.single.data, [10, 0, 0, 2]);
    expect(DnsPacket.decode([1, 2, 3]), isNull);
    // A pointer loop is refused, not followed forever.
    expect(DnsPacket.decode([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]), isNull);
  });

  test('a browse for the service gets its PTR, with SRV, TXT and the address beside it', () async {
    final response = (await responder().respond(
      const DnsPacket(questions: [DnsQuestion('_anyps5-remote._tcp.local', DnsType.ptr)]),
    ))!;
    expect(response.flags, 0x8400);
    expect(response.id, 0);
    expect(response.questions, isEmpty);
    expect(response.answers.single.type, DnsType.ptr);
    expect(DnsPacket.decodeName(response.answers.single.data), 'Utku PC._anyps5-remote._tcp.local');
    final srv = response.additionals.firstWhere((record) => record.type == DnsType.srv);
    expect(srv.name, 'Utku PC._anyps5-remote._tcp.local');
    expect(srv.data[4] << 8 | srv.data[5], 47700);
    expect(DnsPacket.decodeName(srv.data.sublist(6)), 'utku-pc.local');
    expect(response.additionals.any((record) => record.type == DnsType.txt), isTrue);
    final address = response.additionals.firstWhere((record) => record.type == DnsType.a);
    expect(address.name, 'utku-pc.local');
    expect(address.data, [192, 168, 1, 20]);
  });

  test('resolving the instance and the host; questions about others get nothing', () async {
    final server = responder();
    final srv = (await server.respond(
      const DnsPacket(questions: [DnsQuestion('utku pc._ANYPS5-REMOTE._tcp.local', DnsType.srv)]),
    ))!;
    expect(srv.answers.single.type, DnsType.srv);
    final host = (await server.respond(const DnsPacket(questions: [DnsQuestion('utku-pc.local', DnsType.a)])))!;
    expect(host.answers.single.data, [192, 168, 1, 20]);
    expect(await server.respond(const DnsPacket(questions: [DnsQuestion('utku-pc.local', DnsType.aaaa)])), isNull);
    expect(await server.respond(const DnsPacket(questions: [DnsQuestion('_other._tcp.local', DnsType.ptr)])), isNull);
    final services = (await server.respond(
      const DnsPacket(questions: [DnsQuestion('_services._dns-sd._udp.local', DnsType.ptr)]),
    ))!;
    expect(DnsPacket.decodeName(services.answers.single.data), '_anyps5-remote._tcp.local');
  });

  test('a one-shot question from another port is answered to it, with its id and short TTLs', () async {
    final probe = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final port = probe.port;
    probe.close();
    final server = responder(mdnsPort: port);
    await server.start();
    addTearDown(server.stop);
    final asker = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(asker.close);
    final answer = asker
        .where((event) => event == RawSocketEvent.read)
        .map((_) => asker.receive())
        .where((datagram) => datagram != null)
        .map((datagram) => DnsPacket.decode(datagram!.data))
        .where((packet) => packet != null && packet.id == 0x1234)
        .first
        .timeout(const Duration(seconds: 5));
    final query = const DnsPacket(id: 0x1234, questions: [DnsQuestion('_anyps5-remote._tcp.local', DnsType.ptr)]);
    asker.send(query.encode(), InternetAddress.loopbackIPv4, port);
    final response = (await answer)!;
    expect(response.questions.single.name, '_anyps5-remote._tcp.local');
    expect(response.answers.single.ttl, 10);
    expect(DnsPacket.decodeName(response.answers.single.data), 'Utku PC._anyps5-remote._tcp.local');
  });
}
