import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'messages.dart';
import 'packets.dart';

/// A phone for the tests: the phone app's own protocol code on a WebSocket and a UDP socket.
class FakePhone {
  FakePhone._(this.socket, this.messages, this.binary);

  static Future<FakePhone> connect(int port, {String host = '127.0.0.1'}) async {
    final socket = await WebSocket.connect('ws://$host:$port');
    final messages = StreamController<Message>.broadcast();
    final binary = StreamController<Uint8List>.broadcast();
    final phone = FakePhone._(socket, messages, binary);
    socket.listen(
      (data) {
        if (data is String) {
          final message = Message.fromJson(data);
          if (message != null) {
            phone.received.add(message);
            messages.add(message);
          }
        } else if (data is List<int>) {
          binary.add(Uint8List.fromList(data));
        }
      },
      onDone: () {
        phone.closed.complete();
        messages.close();
        binary.close();
      },
    );
    return phone;
  }

  final WebSocket socket;
  final StreamController<Message> messages;
  final StreamController<Uint8List> binary;
  final List<Message> received = [];
  final Completer<void> closed = Completer<void>();
  RawDatagramSocket? udp;

  void send(Message message) => socket.add(message.toJson());

  void hello(String deviceId, String name, {String? key}) =>
      send(Hello(deviceID: deviceId, deviceName: name, key: key));

  /// The next message of type [T], waiting for it.
  Future<T> next<T extends Message>() async {
    for (final message in received) {
      if (message is T) {
        received.remove(message);
        return message;
      }
    }
    final message = await messages.stream.firstWhere((message) => message is T).timeout(const Duration(seconds: 5));
    received.remove(message);
    return message as T;
  }

  Uint8List input(BigInt session, {int sequence = 1, int buttons = PadButton.cross}) =>
      encodeInput(sequence: sequence, sentMicros: 123456, session: session, state: PadState()..buttons = buttons);

  Future<RawDatagramSocket> openUdp() async => udp ??= await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

  Future<void> close() async {
    udp?.close();
    await socket.close();
  }
}
