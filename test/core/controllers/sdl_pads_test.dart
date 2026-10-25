import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controllers/sdl_maps.dart';
import 'package:anyps5_desktop/core/controllers/sdl_pads.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/steam/steam_launch.dart';
import 'package:test/test.dart';

import '../../support/fake_sdl.dart';

void main() {
  group('SdlMaps', () {
    test('buttons by place, the triggers held past a third', () {
      final state = SdlMaps.state({0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 14, 15, 20}, [16000, -32768, 0, 32767, 32767, 3000]);
      expect(state.pressed, {
        PadButton.south,
        PadButton.east,
        PadButton.west,
        PadButton.north,
        PadButton.select,
        PadButton.guide,
        PadButton.start,
        PadButton.l1,
        PadButton.r1,
        PadButton.dpadUp,
        PadButton.dpadRight,
        PadButton.misc,
        PadButton.touchpad,
        PadButton.l2,
      });
      expect(state.leftX, closeTo(0.488, 0.001));
      expect(state.leftY, -1);
      expect(state.rightY, 1);
      expect(state.l2, 1);
      expect(state.r2, closeTo(0.09, 0.01));
    });

    test('controller types are families', () {
      expect(SdlMaps.kind(7), PadKind.dualSense);
      expect(SdlMaps.kind(4), PadKind.dualShock4);
      expect(SdlMaps.kind(3), PadKind.dualShock3);
      expect(SdlMaps.kind(1), PadKind.xbox);
      expect(SdlMaps.kind(2), PadKind.xbox);
      expect(SdlMaps.kind(5), PadKind.switchPro);
      expect(SdlMaps.kind(0, name: '8BitDo Pro 2'), PadKind.generic);
      expect(SdlMaps.kind(0, vendor: 0x054C, product: 0x0268), PadKind.dualShock3);
    });

    test('power levels are batteries; wired is none', () {
      expect(SdlMaps.battery(3), PadBattery(100, approximate: true, charging: false));
      expect(SdlMaps.battery(1)!.low, isFalse);
      expect(SdlMaps.battery(0)!.low, isTrue);
      expect(SdlMaps.battery(4), isNull);
      expect(SdlMaps.battery(-1), isNull);
    });

    test('the GUID tells the bus, the numbers and the driver', () {
      expect(SdlMaps.connection(guid(bus: 0x05)), PadConnection.bluetooth);
      expect(SdlMaps.connection(guid(bus: 0x03)), PadConnection.usb);
      expect(SdlMaps.connection(guid(bus: 0x00)), PadConnection.unknown);
      expect(SdlMaps.connection(guid(bus: 0x00), powerLevel: 4), PadConnection.usb);
      expect(SdlMaps.usbNumbers(guid(vendor: 0x054C, product: 0x0CE6)), (0x054C, 0x0CE6));
      expect(SdlMaps.usbNumbers(guid()), isNull);
      expect(SdlMaps.driver(guid(driver: 'h')), 'SDL HIDAPI');
      expect(SdlMaps.driver(guid(driver: 'x')), 'SDL XInput');
      expect(SdlMaps.driver(guid(driver: '\u0000')), 'SDL');
    });
  });

  group('PadDuplicates', () {
    PadInfo info(SdlDevice device) => PadInfo(
      id: 'sdl${device.instance}',
      name: device.name,
      kind: SdlMaps.kind(device.type, vendor: device.vendor, product: device.product),
      driver: 'SDL',
      vendor: device.vendor,
      product: device.product,
      virtual: device.virtual,
    );

    test('from Steam, its virtual pad stands for the real ones', () {
      final pads = [info(dualSense(0)), info(steamPad(1))];
      expect(PadDuplicates.visible(pads, steam: true, remapper: false).map((pad) => pad.name), ['Steam Virtual Gamepad']);
      expect(PadDuplicates.visible(pads, steam: false, remapper: false), hasLength(2));
      // From Steam with Steam Input off for it: no virtual pad, the real one stays.
      expect(PadDuplicates.visible([info(dualSense(0))], steam: true, remapper: false), hasLength(1));
    });

    test('with DS4Windows running the real PlayStation pad wins over its virtual Xbox pad', () {
      final pads = [info(dualSense(0)), info(xbox360(1))];
      expect(PadDuplicates.visible(pads, steam: false, remapper: true).map((pad) => pad.kind), [PadKind.dualSense]);
      // HidHide hiding the real one: the virtual pad is all there is.
      expect(PadDuplicates.visible([info(xbox360(1))], steam: false, remapper: true), hasLength(1));
      expect(PadDuplicates.visible(pads, steam: false, remapper: false), hasLength(2));
    });

    test('the controllers Steam Input took over are left to it', () {
      final launch = SteamLaunch.detect(['--steam'], {'SDL_GAMECONTROLLER_IGNORE_DEVICES': '0x054c/0x0ce6'});
      final pads = [info(dualSense(0)), info(xbox360(1))];
      expect(
        PadDuplicates.visible(pads, steam: true, remapper: false, steamTookOver: launch.skipPhysicalPad).map((pad) => pad.kind),
        [PadKind.xbox],
      );
    });

    test('launched from Steam', () {
      expect(PadDuplicates.launchedFromSteam({'SteamAppId': '480'}, []), isTrue);
      expect(PadDuplicates.launchedFromSteam({'SteamAppId': '0'}, []), isFalse, reason: 'a non-Steam game has 0 there');
      expect(PadDuplicates.launchedFromSteam({'SteamGameId': '123'}, []), isTrue);
      expect(PadDuplicates.launchedFromSteam({}, ['--steam']), isTrue);
      expect(PadDuplicates.launchedFromSteam({'SteamAppId': ''}, []), isFalse);
      expect(PadDuplicates.launchedFromSteam({}, []), isFalse);
    });
  });

  group('SdlPadSource', () {
    test('hot-plug: a pad is opened when it comes and let go when it goes', () {
      final sdl = FakeSdl();
      final source = SdlPadSource(sdl);
      final events = <PadEvent>[];
      var changes = 0;
      source.onPadsChanged = () => changes++;
      source.start(events.add);
      expect(source.pads, isEmpty);
      sdl.plug(dualSense(3), power: 2);
      source.poll();
      expect(changes, 1);
      final pad = source.pads.single;
      expect(pad.id, 'sdl3');
      expect(pad.kind, PadKind.dualSense);
      expect(pad.connection, PadConnection.bluetooth);
      expect(pad.battery!.percent, 55);
      expect(pad.driver, 'SDL HIDAPI');
      expect(pad.usbId, '054c:0ce6');
      sdl.hold(3, {0});
      source.poll();
      expect(events.whereType<PadButtonEvent>().single.button, PadButton.south);
      expect(source.state('sdl3')!.pressed, {PadButton.south});
      sdl.unplug(3);
      source.poll();
      expect(source.pads, isEmpty);
      expect(events.last, isA<PadGone>().having((event) => event.pad, 'pad', 'sdl3'));
      expect(sdl.calls, contains('close 3'));
      expect(changes, 2);
      source.stop();
      expect(sdl.quitCalled, isTrue);
    });

    test('several pads at once, each its own id; a joystick without a mapping is listed apart', () {
      final sdl = FakeSdl()
        ..plug(dualSense(0, bus: 0x03))
        ..plug(xbox360(1))
        ..plug(const SdlDevice(instance: 2, index: 2, gameController: false, name: 'Thrustmaster Wheel'));
      final source = SdlPadSource(sdl)..poll();
      expect(source.pads.map((pad) => pad.id), ['sdl0', 'sdl1']);
      expect(source.pads.first.connection, PadConnection.usb);
      expect(source.unmapped, ['Thrustmaster Wheel']);
    });

    test('the stick moves, its drift does not', () {
      final sdl = FakeSdl()..plug(dualSense(0));
      final events = <PadEvent>[];
      final source = SdlPadSource(sdl)..start(events.add);
      sdl.hold(0, {}, axes: [2000, -1500, 0, 0, 0, 0]);
      source.poll();
      expect(events.whereType<PadAxisEvent>(), isEmpty);
      sdl.hold(0, {}, axes: [32767, 0, 0, 0, 0, 0]);
      source.poll();
      expect(events.whereType<PadAxisEvent>().single.value, 1);
      source.stop();
    });

    test('a pad Steam stands in for is left out from Steam, and lets go of what it held', () {
      final sdl = FakeSdl()..plug(dualSense(0));
      final events = <PadEvent>[];
      final source = SdlPadSource(sdl, steam: true)..start(events.add);
      sdl.hold(0, {0});
      source.poll();
      expect(events.whereType<PadButtonEvent>(), hasLength(1));
      sdl.plug(steamPad(1));
      source.poll();
      expect(source.pads.map((pad) => pad.name), ['Steam Virtual Gamepad']);
      expect(events.whereType<PadGone>().map((event) => event.pad), contains('sdl0'));
      source.stop();
    });

    test('a remapper running hides its virtual Xbox pad', () {
      var remapper = false;
      final sdl = FakeSdl()
        ..plug(dualSense(0))
        ..plug(xbox360(1));
      final source = SdlPadSource(sdl, remapperRunning: () => remapper)..poll();
      expect(source.pads, hasLength(2));
      remapper = true;
      source.poll();
      expect(source.pads.single.kind, PadKind.dualSense);
    });

    test('motors, light bar and player lights go through SDL', () {
      final sdl = FakeSdl()
        ..plug(dualSense(0))
        ..plug(xbox360(1))
        ..leds.add(0);
      final source = SdlPadSource(sdl)..poll();
      expect(source.canRumble('sdl0'), isTrue);
      expect(source.canRumble('xinput0'), isFalse);
      source.rumble('sdl0', 1, 0.5, const Duration(milliseconds: 30));
      expect(sdl.calls.last, 'rumble 0 65535 32768 50');
      source.rumble('sdl0', 0, 0, Duration.zero);
      expect(sdl.calls.last, 'rumble 0 0 0 0');
      expect(source.setLight('sdl0', 10, 20, 30), isTrue);
      expect(sdl.calls.last, 'led 0 10 20 30');
      expect(source.setLight('sdl1', 10, 20, 30), isFalse, reason: 'an Xbox pad has no light bar');
      source.setPlayerLights(['sdl1', 'sdl0']);
      expect(sdl.calls.sublist(sdl.calls.length - 2), ['player 1 0', 'player 0 1']);
    });

    test('where SDL2 is looked for', () {
      expect(SdlLibrary.candidates(executable: r'C:\Games\AnyPS5\anyps5_desktop.exe', windows: true).last, 'SDL2.dll');
      expect(SdlLibrary.candidates(executable: '/opt/anyps5-desktop/anyps5_desktop', windows: false), [
        '/opt/anyps5-desktop/lib/libSDL2-2.0.so.0',
        'libSDL2-2.0.so.0',
        'libSDL2.so',
      ]);
      String? why;
      expect(SdlLibrary.load(paths: ['/nonexistent/libSDL2.so'], failure: (reason) => why = reason), isNull);
      expect(why, startsWith('SDL2 not found'));
    });
  });
}
