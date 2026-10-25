import 'package:anyps5_desktop/core/controllers/sdl_pads.dart';

/// SDL2 for tests: devices plugged and unplugged at will, their buttons and axes held, every
/// call into it written down.

/// An SDL GUID: bus, vendor, product and the driver letter where SDL2 puts them.
List<int> guid({int bus = 0x03, int vendor = 0, int product = 0, String driver = 'h'}) => [
  bus & 0xFF, bus >> 8, 0, 0, vendor & 0xFF, vendor >> 8, 0, 0, product & 0xFF, product >> 8, 0, 0, 0, 0, driver.codeUnitAt(0), 0, //
];

class FakeSdl implements SdlBackend {
  final List<SdlDevice> listed = [];
  final Map<int, SdlReading> readings = {};
  final Set<int> opened = {};
  final List<String> calls = [];
  final Set<int> leds = {};
  bool quitCalled = false;

  void plug(SdlDevice device, {int power = -1}) {
    listed.add(device);
    readings[device.instance] = SdlReading(held: const {}, axes: const [0, 0, 0, 0, 0, 0], powerLevel: power);
  }

  void unplug(int instance) => listed.removeWhere((device) => device.instance == instance);

  void hold(int instance, Set<int> buttons, {List<int> axes = const [0, 0, 0, 0, 0, 0], int power = -1}) =>
      readings[instance] = SdlReading(held: buttons, axes: axes, powerLevel: power);

  @override
  String get version => '2.32.10';
  @override
  void update() {}
  @override
  List<SdlDevice> devices() => List.of(listed);
  @override
  bool open(SdlDevice device) => opened.add(device.instance) || true;
  @override
  void close(int instance) {
    opened.remove(instance);
    calls.add('close $instance');
  }

  @override
  SdlReading? read(int instance) => opened.contains(instance) ? readings[instance] : null;
  @override
  bool hasRumble(int instance) => true;
  @override
  bool rumble(int instance, int low, int high, int milliseconds) {
    calls.add('rumble $instance $low $high $milliseconds');
    return true;
  }

  @override
  bool hasLed(int instance) => leds.contains(instance);
  @override
  bool setLed(int instance, int red, int green, int blue) {
    calls.add('led $instance $red $green $blue');
    return true;
  }

  @override
  void setPlayerIndex(int instance, int player) => calls.add('player $instance $player');
  @override
  void quit() => quitCalled = true;
}

SdlDevice dualSense(int instance, {int bus = 0x05}) => SdlDevice(
  instance: instance,
  index: instance,
  gameController: true,
  name: 'PS5 Controller',
  type: 7,
  guid: guid(bus: bus, vendor: 0x054C, product: 0x0CE6),
  vendor: 0x054C,
  product: 0x0CE6,
);

SdlDevice xbox360(int instance) => SdlDevice(
  instance: instance,
  index: instance,
  gameController: true,
  name: 'Xbox 360 Controller',
  type: 1,
  guid: guid(vendor: 0x045E, product: 0x028E, driver: 'x'),
  vendor: 0x045E,
  product: 0x028E,
);

SdlDevice steamPad(int instance) => SdlDevice(
  instance: instance,
  index: instance,
  gameController: true,
  name: 'Steam Virtual Gamepad',
  type: 1,
  guid: guid(vendor: 0x28DE, product: 0x11FF, driver: 'x'),
  vendor: 0x28DE,
  product: 0x11FF,
  virtual: true,
);

