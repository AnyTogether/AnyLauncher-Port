import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/remote/usb_tunnel.dart';
import 'package:test/test.dart';

/// usbmuxd for tests, on a loopback port as Windows' is: it tells of one phone on the cable,
/// and a connection to the phone's port 47702 reaches a phone app that speaks first.
class FakeUsbmux {
  FakeUsbmux._(this._server) {
    _server.listen(_serve);
  }

  static Future<FakeUsbmux> start() async => FakeUsbmux._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final requests = <Map<String, Object?>>[];
  final fromLauncher = BytesBuilder();
  bool appListening = false;
  final _listeners = <Socket>[];

  int get port => _server.port;

  void _serve(Socket socket) {
    var buffer = Uint8List(0);
    var raw = false;
    socket.listen((chunk) {
      if (raw) return fromLauncher.add(chunk);
      buffer = Uint8List.fromList([...buffer, ...chunk]);
      final taken = Usbmux.take(buffer);
      if (taken == null) return;
      final (message, _) = taken;
      requests.add(message);
      switch (message['MessageType']) {
        case 'Listen':
          _listeners.add(socket);
          socket.add(Usbmux.frame({'MessageType': 'Result', 'Number': 0}));
          socket.add(
            Usbmux.frame({
              'MessageType': 'Attached',
              'DeviceID': 7,
              'Properties': {'ConnectionType': 'USB', 'SerialNumber': 'UDID-1', 'ProductID': 4776},
            }),
          );
          // A phone over Wi-Fi sync is not on the cable.
          socket.add(
            Usbmux.frame({
              'MessageType': 'Attached',
              'DeviceID': 8,
              'Properties': {'ConnectionType': 'Network', 'SerialNumber': 'UDID-2'},
            }),
          );
        case 'Connect':
          if (!appListening) {
            socket.add(Usbmux.frame({'MessageType': 'Result', 'Number': 3}));
            return;
          }
          raw = true;
          // The phone app speaks first, right behind usbmuxd's answer.
          socket.add([
            ...Usbmux.frame({'MessageType': 'Result', 'Number': 0}),
            ...utf8.encode('GET / phone'),
          ]);
      }
    }, onError: (Object _) {});
  }

  void unplug() {
    for (final socket in _listeners) {
      socket.add(Usbmux.frame({'MessageType': 'Detached', 'DeviceID': 7}));
    }
  }

  Future<void> close() => _server.close();
}

void main() {
  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 200 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  test('messages: a 16-byte header and an XML property list, as the Mac writes them', () {
    final frame = Usbmux.frame(Usbmux.connect(7, 47702), tag: 3);
    final header = ByteData.sublistView(frame);
    expect(header.getUint32(0, Endian.little), frame.length);
    expect(
      [header.getUint32(4, Endian.little), header.getUint32(8, Endian.little), header.getUint32(12, Endian.little)],
      [1, 8, 3],
    );
    final (message, rest) = Usbmux.take(frame)!;
    expect(message, {
      'MessageType': 'Connect',
      'ClientVersionString': 'AnyPS5',
      'ProgName': 'AnyPS5',
      'DeviceID': 7,
      'PortNumber': 0x56BA,
    }, reason: 'the port in network order');
    expect(rest, isEmpty);
    expect(Usbmux.take(Uint8List.sublistView(frame, 0, 20)), isNull, reason: 'half a message waits');
    final escaped = Usbmux.parse(Usbmux.plist({'Name': 'A & <B>', 'On': true, 'Off': false}));
    expect(escaped, {'Name': 'A & <B>', 'On': true, 'Off': false});
  });

  test('events: a phone on the cable, one unplugged; Wi-Fi sync is not the cable', () {
    final attached = Usbmux.event({
      'MessageType': 'Attached',
      'DeviceID': 4,
      'Properties': {'ConnectionType': 'USB', 'SerialNumber': 'U'},
    });
    expect(attached, isA<UsbmuxAttached>().having((event) => event.serial, 'serial', 'U'));
    expect(Usbmux.event({'MessageType': 'Detached', 'DeviceID': 4}), isA<UsbmuxDetached>());
    expect(
      Usbmux.event({
        'MessageType': 'Attached',
        'DeviceID': 5,
        'Properties': {'ConnectionType': 'Network'},
      }),
      isNull,
    );
  });

  test('where usbmuxd is: the system\'s place, or USBMUXD_SOCKET_ADDRESS', () {
    expect(Usbmux.where(environment: {}, windows: true).port, 27015);
    final linux = Usbmux.where(environment: {}, windows: false);
    expect((linux.address.type, linux.address.address), (InternetAddressType.unix, '/var/run/usbmuxd'));
    expect(Usbmux.where(environment: {'USBMUXD_SOCKET_ADDRESS': '127.0.0.1:27016'}, windows: false).port, 27016);
    expect(
      Usbmux.where(environment: {'USBMUXD_SOCKET_ADDRESS': 'UNIX:/tmp/mux'}, windows: true).address.address,
      '/tmp/mux',
    );
  });

  test('a phone on the cable is joined to the phone server once its app listens, and let go when unplugged', () async {
    final usbmux = await FakeUsbmux.start();
    final phoneServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final atServer = BytesBuilder();
    phoneServer.listen((socket) {
      socket.listen(atServer.add, onError: (Object _) {});
      socket.add(utf8.encode('HTTP/1.1 101 launcher'));
    });
    final changes = <List<String>>[];
    final tunnel = UsbTunnel(
      targetPort: phoneServer.port,
      usbmux: () => Socket.connect(InternetAddress.loopbackIPv4, usbmux.port),
      retry: const Duration(milliseconds: 50),
      changed: changes.add,
    )..start();
    addTearDown(() async {
      await tunnel.stop();
      await usbmux.close();
      await phoneServer.close();
    });
    await until(() => usbmux.requests.any((request) => request['MessageType'] == 'Connect'));
    expect(tunnel.joined, isEmpty, reason: 'the app does not listen yet');
    usbmux.appListening = true;
    await until(() => tunnel.joined.isNotEmpty);
    expect(tunnel.joined, ['UDID-1']);
    await until(() => utf8.decode(atServer.toBytes()) == 'GET / phone');
    await until(() => utf8.decode(usbmux.fromLauncher.toBytes()) == 'HTTP/1.1 101 launcher');
    expect(
      usbmux.requests
          .where((request) => request['MessageType'] == 'Connect')
          .map((request) => request['DeviceID'])
          .toSet(),
      {7},
    );
    usbmux.unplug();
    await until(() => tunnel.joined.isEmpty);
    expect(changes.last, isEmpty);
  });
}
