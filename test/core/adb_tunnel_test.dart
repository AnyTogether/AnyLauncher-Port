import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/remote/adb_tunnel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('adb'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// An adb that lists one ready phone and one unauthorized, and forwards to [phonePort].
  String fakeAdb(int phonePort) {
    final log = p.join(temp.path, 'adb.log');
    final script = p.join(temp.path, 'adb');
    File(script).writeAsStringSync('''
#!/bin/sh
echo "\$@" >> "$log"
case "\$*" in
  devices) printf 'List of devices attached\\nR58M123\\tdevice\\nemulator-5554\\tunauthorized\\n' ;;
  "-s R58M123 forward tcp:0 tcp:47702") echo $phonePort ;;
  *forward\\ --remove*) ;;
  *) exit 1 ;;
esac
''');
    Process.runSync('chmod', ['755', script]);
    return script;
  }

  test('devices: only phones that are ready', () {
    expect(AdbTunnel.devices('List of devices attached\nA1\tdevice\nB2\tunauthorized\nC3\toffline\n\n'), ['A1']);
    expect(AdbTunnel.devices('List of devices attached\r\nA1\tdevice\r\n'), ['A1']);
  });

  test('locate finds adb in the Android SDK or nowhere', () async {
    final sdk = p.join(temp.path, 'sdk');
    File(p.join(sdk, 'platform-tools', 'adb')).createSync(recursive: true);
    expect(
      await AdbTunnel.locate(environment: {'ANDROID_HOME': sdk}, windows: false),
      p.join(sdk, 'platform-tools', 'adb'),
    );
    final windowsSdk = p.join(temp.path, 'local');
    File(p.join(windowsSdk, 'Android', 'Sdk', 'platform-tools', 'adb.exe')).createSync(recursive: true);
    expect(
      await AdbTunnel.locate(environment: {'LOCALAPPDATA': windowsSdk}, windows: true),
      p.join(windowsSdk, 'Android', 'Sdk', 'platform-tools', 'adb.exe'),
    );
  });

  test('the phone end and the launcher end are joined, again after a drop, and unforwarded at the end', () async {
    // The phone app's port (through adb) and the launcher's server, here an echo.
    final phoneApp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final launcher = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    launcher.listen((socket) => socket.listen(socket.add, onDone: socket.close));
    final reports = <List<String>>[];
    final tunnel = AdbTunnel(
      adb: fakeAdb(phoneApp.port),
      targetPort: launcher.port,
      interval: const Duration(milliseconds: 200),
      retry: const Duration(milliseconds: 200),
      changed: reports.add,
    );
    final connections = StreamIterator(phoneApp);
    tunnel.start();
    expect(await connections.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    final first = connections.current;
    final echoed = StreamIterator(first);
    first.write('hello over the cable');
    expect(await echoed.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(utf8.decode(echoed.current), 'hello over the cable');
    // Held for over a second, the phone counts as there.
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(tunnel.joined, ['R58M123']);
    expect(reports.last, ['R58M123']);
    // The phone app goes away; the tunnel tries again.
    first.destroy();
    expect(await connections.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    connections.current.destroy();
    await tunnel.stop();
    await phoneApp.close();
    await launcher.close();
    final log = File(p.join(temp.path, 'adb.log')).readAsLinesSync();
    expect(log, contains('-s R58M123 forward tcp:0 tcp:47702'));
    expect(log, contains('-s R58M123 forward --remove tcp:${phoneApp.port}'));
    expect(log.where((line) => line.contains('emulator-5554')), isEmpty, reason: 'unauthorized is left alone');
  });
}
