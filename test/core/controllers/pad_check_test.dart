import 'package:anyps5_desktop/core/controllers/pad_check.dart';
import 'package:anyps5_desktop/core/controllers/troubleshooter.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:test/test.dart';

class FakeProbe implements SystemProbe {
  @override
  Future<Set<String>> processes() async => {'steam.exe', 'ds4windows.exe'};
  @override
  Future<Set<String>> services(List<String> names) async => {'hidhide', 'vigembus'};
  @override
  Future<int?> steamPlayStationSupport() async => 1;
  @override
  Future<bool> hidrawDenied() async => false;
  @override
  Future<List<String>> unreadableControllers() async => const [];
}

void main() {
  test('anyps5_tool pads: without SDL2 it says so, then what is in the way', () async {
    final out = StringBuffer();
    final code = await padCheck(
      out: out,
      system: HostSystem.windows,
      sdlPath: '/nonexistent/SDL2.dll',
      seconds: 0,
      probe: FakeProbe(),
      executable: r'C:\AnyPS5\anyps5_desktop.exe',
    );
    expect(code, 0);
    final text = '$out';
    expect(text, contains('SDL2: not loaded: SDL2 not found: /nonexistent/SDL2.dll'));
    expect(text, contains('steam PlayStation support: 1'));
    expect(text, contains('drivers: hidhide, vigembus'));
    expect(text, contains('problem noControllers'));
    expect(text, contains('problem steamPlayStation'));
    expect(text, contains('problem ds4windows'));
    expect(text, contains('problem hidHide'));
    expect(text, contains(r'    C:\AnyPS5\anyps5_desktop.exe'));
    expect(text, contains('problem sdlMissingWindows'));
  });
}
