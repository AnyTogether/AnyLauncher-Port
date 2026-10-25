import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controllers/troubleshooter.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:test/test.dart';

void main() {
  final sense = PadInfo(id: 'sdl0', name: 'PS5 Controller', kind: PadKind.dualSense, battery: PadBattery(60), driver: 'SDL HIDAPI');
  const xbox = PadInfo(id: 'sdl1', name: 'Xbox Controller', kind: PadKind.xbox, driver: 'SDL XInput');

  List<String> ids(PadFacts facts) => [for (final finding in PadTroubleshooter.diagnose(facts)) finding.id];

  group('Windows', () {
    test('nothing connected: the tips, the DualShock 3 driver', () {
      expect(ids(const PadFacts(system: HostSystem.windows)), ['noControllers', 'usbCable', 'bluetoothPairing', 'dualShock3Windows']);
    });

    test('Steam with PlayStation support on is in the way of a PlayStation pad', () {
      final facts = PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'}, steamPlayStationSupport: 2);
      final finding = PadTroubleshooter.diagnose(facts).single;
      expect(finding.id, 'steamPlayStation');
      expect(finding.problem, isTrue);
      // Turned off in Steam: only a tip that it runs.
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'}, steamPlayStationSupport: 0)), ['steamRunning']);
      // An Xbox pad only: Steam's PlayStation support is beside the point.
      expect(ids(const PadFacts(system: HostSystem.windows, pads: [xbox], processes: {'steam.exe'}, steamPlayStationSupport: 2)), ['steamRunning']);
      // Its setting unknown counts as on (Steam's default).
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'})), ['steamPlayStation']);
      // Started from Steam: its virtual pad is the one used.
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'}, launchedFromSteam: true)), ['steamLaunched']);
    });

    test('DS4Windows, DualSenseX, HidHide and ViGEm', () {
      final facts = PadFacts(
        system: HostSystem.windows,
        pads: [sense],
        processes: {'ds4windows.exe', 'dsx.exe'},
        services: {'hidhide', 'vigembus'},
        executable: r'C:\Program Files\AnyPS5 Desktop\anyps5_desktop.exe',
      );
      final findings = PadTroubleshooter.diagnose(facts);
      expect(findings.map((finding) => finding.id), ['ds4windows', 'dualSenseX', 'hidHide']);
      expect(findings[2].command, r'C:\Program Files\AnyPS5 Desktop\anyps5_desktop.exe');
      expect(findings[2].problem, isFalse, reason: 'a pad gets through: HidHide is only a tip');
      // Nothing gets through with HidHide installed: it may be hiding the pad.
      final hidden = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.windows, services: {'hidhide'}));
      expect(hidden.firstWhere((finding) => finding.id == 'hidHide').problem, isTrue);
      // ViGEm alone (no remapper running): a tip.
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], services: {'vigembus'})), ['vigem']);
    });

    test('SDL2 missing: the older readers, said so', () {
      final findings = PadTroubleshooter.diagnose(
        const PadFacts(system: HostSystem.windows, pads: [xbox], sdlLoaded: false, sdlFailure: 'SDL2 not found'),
      );
      expect(findings.single.id, 'sdlMissingWindows');
      expect(findings.single.arguments, ['SDL2 not found']);
    });

    test('a joystick without a mapping and a low battery are named', () {
      final findings = PadTroubleshooter.diagnose(
        PadFacts(system: HostSystem.windows, pads: [sense.copyWith(battery: PadBattery(9))], unmapped: ['Thrustmaster Wheel']),
      );
      expect(findings.map((finding) => finding.id), ['unmapped', 'lowBattery']);
      expect(findings[0].arguments, ['Thrustmaster Wheel']);
      expect(findings[1].arguments, ['PS5 Controller', 9]);
      expect(PadTroubleshooter.statusLine([sense.copyWith(battery: PadBattery(9))]), 'PS5 Controller · 9%');
      expect(PadTroubleshooter.statusLine([sense]), isNull);
    });

    test('tasklist and Steam config are read', () {
      expect(
        PadTroubleshooter.tasklistNames('"System Idle Process","0","Services","0","8 K"\r\n"steam.exe","1234","Console","1","90,000 K"\r\n"DS4Windows.exe","4321","Console","1","50 K"\r\n'),
        {'system idle process', 'steam.exe', 'ds4windows.exe'},
      );
      expect(
        PadTroubleshooter.steamPlayStationSupport(
          '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"SteamController_PSSupport"\t\t"2"\n',
        ),
        2,
      );
      expect(PadTroubleshooter.steamPlayStationSupport('"InstallConfigStore" {}'), isNull);
    });
  });

  group('Linux', () {
    test('a controller the user may not read: the input group, with the command', () {
      final findings = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.linux, refused: ['Sony Interactive Entertainment Wireless Controller']));
      expect(findings.first.id, 'linuxPermission');
      expect(findings.first.problem, isTrue);
      expect(findings.first.command, 'sudo usermod -aG input "\$USER"');
      expect(findings.map((finding) => finding.id), isNot(contains('noControllers')));
    });

    test('hidraw closed: the udev rule for PlayStation pads read without their motors', () {
      const evdevSense = PadInfo(id: 'sdl0', name: 'PS5 Controller', kind: PadKind.dualSense, driver: 'SDL evdev');
      final findings = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.linux, pads: [evdevSense], hidrawDenied: true));
      expect(findings.single.id, 'linuxHidraw');
      expect(findings.single.command, contains('/etc/udev/rules.d/70-anyps5-controllers.rules'));
      expect(findings.single.command, contains('ATTRS{idVendor}=="054c"'));
      // Read through HIDAPI already: nothing to say.
      expect(ids(PadFacts(system: HostSystem.linux, pads: [sense], hidrawDenied: true)), isEmpty);
    });

    test('SDL2 missing on Linux says how to install it', () {
      final findings = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.linux, pads: [xbox], sdlLoaded: false));
      expect(findings.single.id, 'sdlMissingLinux');
      expect(findings.single.command, startsWith('sudo apt install libsdl2-2.0-0'));
    });

    test('nothing connected on Linux', () {
      expect(ids(const PadFacts(system: HostSystem.linux, processes: {'steam'})), [
        'noControllers',
        'steamPlayStation',
        'usbCable',
        'bluetoothPairing',
        'dualShock3Linux',
      ]);
    });
  });
}
