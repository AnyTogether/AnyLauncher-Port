import '../gamepad/pad_navigation.dart';
import '../steam/steam_launch.dart';
import 'pad_info.dart';

/// SDL2's game controller numbers as the launcher's: buttons by place, its controller types as
/// pad families, its power levels as batteries, the bus in its GUIDs as the connection.
abstract final class SdlMaps {
  /// SDL_GameControllerButton (SDL_CONTROLLER_BUTTON_A = 0 ... TOUCHPAD = 20) by place: with
  /// SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS off, A is the south button on every pad (a
  /// Nintendo pad's B), as the launcher's PadButton is.
  static const buttons = <int, PadButton>{
    0: PadButton.south,
    1: PadButton.east,
    2: PadButton.west,
    3: PadButton.north,
    4: PadButton.select,
    5: PadButton.guide,
    6: PadButton.start,
    7: PadButton.l3,
    8: PadButton.r3,
    9: PadButton.l1,
    10: PadButton.r1,
    11: PadButton.dpadUp,
    12: PadButton.dpadDown,
    13: PadButton.dpadLeft,
    14: PadButton.dpadRight,
    15: PadButton.misc,
    20: PadButton.touchpad,
  };

  /// The highest button number asked for.
  static const lastButton = 20;

  /// SDL_GameControllerAxis: LEFTX, LEFTY, RIGHTX, RIGHTY, TRIGGERLEFT, TRIGGERRIGHT.
  static const leftX = 0, leftY = 1, rightX = 2, rightY = 3, triggerLeft = 4, triggerRight = 5;

  /// A trigger pressed further than this counts as L2 or R2 held.
  static const triggerPressed = 0.35;

  /// A pad's state from its buttons (SDL button number → held) and its six axes (-32768 to
  /// 32767; the triggers 0 to 32767).
  static PadState state(Set<int> held, List<int> axes) {
    double stick(int value) => (value / (value < 0 ? 32768 : 32767)).clamp(-1.0, 1.0);
    double trigger(int value) => (value / 32767).clamp(0.0, 1.0);
    final l2 = axes.length > triggerLeft ? trigger(axes[triggerLeft]) : 0.0;
    final r2 = axes.length > triggerRight ? trigger(axes[triggerRight]) : 0.0;
    return PadState(
      pressed: {
        for (final number in held) ?buttons[number],
        if (l2 >= triggerPressed) PadButton.l2,
        if (r2 >= triggerPressed) PadButton.r2,
      },
      leftX: axes.isNotEmpty ? stick(axes[leftX]) : 0,
      leftY: axes.length > leftY ? stick(axes[leftY]) : 0,
      rightX: axes.length > rightX ? stick(axes[rightX]) : 0,
      rightY: axes.length > rightY ? stick(axes[rightY]) : 0,
      l2: l2,
      r2: r2,
    );
  }

  /// SDL_GameControllerType as a family; UNKNOWN (0) and the others fall back to the USB numbers
  /// and the name.
  static PadKind kind(int type, {int? vendor, int? product, String name = ''}) => switch (type) {
    1 || 2 => PadKind.xbox, // XBOX360, XBOXONE
    3 => PadKind.dualShock3, // PS3
    4 => PadKind.dualShock4, // PS4
    5 => PadKind.switchPro, // NINTENDO_SWITCH_PRO
    7 => PadKind.dualSense, // PS5
    _ => PadKind.classify(vendor: vendor, product: product, name: name),
  };

  /// SDL_JoystickPowerLevel: UNKNOWN -1, EMPTY 0, LOW 1, MEDIUM 2, FULL 3, WIRED 4. SDL2 gives
  /// levels, not percentages: each is shown as its middle, marked approximate. WIRED is a
  /// controller on its cable (charging, or one without a battery): no battery shown.
  static PadBattery? battery(int level) => switch (level) {
    0 => PadBattery(5, approximate: true, charging: false),
    1 => PadBattery(20, approximate: true, charging: false),
    2 => PadBattery(55, approximate: true, charging: false),
    3 => PadBattery(100, approximate: true, charging: false),
    _ => null,
  };

  /// SDL2's joystick GUID begins with the bus as a little-endian 16-bit number: 0x03 USB, 0x05
  /// Bluetooth (SDL_HARDWARE_BUS_*); a wired power level says USB too.
  static PadConnection connection(List<int> guid, {int powerLevel = -1}) {
    if (guid.length >= 2) {
      final bus = guid[0] | guid[1] << 8;
      if (bus == 0x05) return PadConnection.bluetooth;
      if (bus == 0x03) return PadConnection.usb;
    }
    if (powerLevel == 4) return PadConnection.usb;
    return PadConnection.unknown;
  }

  /// The vendor and product inside an SDL2 GUID (bytes 4–5 and 8–9), when it holds them.
  static (int, int)? usbNumbers(List<int> guid) {
    if (guid.length < 10) return null;
    final vendor = guid[4] | guid[5] << 8;
    final product = guid[8] | guid[9] << 8;
    if (vendor == 0 && product == 0) return null;
    return (vendor, product);
  }

  /// The driver SDL read a pad with, from its GUID's byte 14: 'h' HIDAPI, 'x' XInput, 'w'
  /// Windows.Gaming.Input, 'r' RawInput, 'v' a virtual joystick; nothing there for DirectInput
  /// and Linux's evdev.
  static String driver(List<int> guid) {
    if (guid.length < 16) return 'SDL';
    return switch (String.fromCharCode(guid[14])) {
      'h' => 'SDL HIDAPI',
      'x' => 'SDL XInput',
      'w' => 'SDL WGI',
      'r' => 'SDL RawInput',
      'v' => 'SDL virtual',
      _ => 'SDL',
    };
  }
}

/// Steam and the remapping programs make virtual Xbox pads of the real controllers: the same
/// presses then arrive twice. Which of the pads the launcher listens to.
abstract final class PadDuplicates {
  static const steamVendor = 0x28DE;
  static const steamVirtualProduct = 0x11FF;
  static const xbox360Product = 0x028E;

  /// Steam's virtual gamepad (VID 28DE PID 11FF, or SDL's "Steam Virtual Gamepad" name).
  static bool isSteamVirtual(PadInfo pad) =>
      (pad.vendor == steamVendor && pad.product == steamVirtualProduct) || pad.name.toLowerCase().contains('steam virtual');

  /// A virtual Xbox 360 pad of the kind ViGEm makes for DS4Windows and DualSenseX (045E:028E;
  /// a real wired Xbox 360 pad has the same numbers, so it is told only while one runs).
  static bool isXbox360(PadInfo pad) => pad.vendor == PadKind.microsoft && pad.product == xbox360Product;

  /// Launched from Steam (a shortcut's --steam, SteamGameId or SteamAppId): SteamLaunch's reading.
  static bool launchedFromSteam(Map<String, String> environment, List<String> arguments) =>
      SteamLaunch.detect(arguments, environment).fromSteam;

  /// The pads to listen to: from Steam, its virtual pads stand for the real ones (the physical
  /// pads are left out while a virtual one is there); with DS4Windows or DualSenseX running, a
  /// PlayStation pad the launcher reads itself wins over the virtual Xbox 360 pad it is turned
  /// into (with HidHide hiding the real one, the virtual pad is all there is, and it stays).
  static List<PadInfo> visible(
    List<PadInfo> pads, {
    required bool steam,
    required bool remapper,
    bool Function(int vendor, int product)? steamTookOver,
  }) {
    var shown = pads;
    // The real controllers Steam Input said it took over (SDL_GAMECONTROLLER_IGNORE_DEVICES).
    if (steamTookOver != null) {
      shown = [
        for (final pad in shown)
          if (pad.vendor == null || pad.product == null || !steamTookOver(pad.vendor!, pad.product!)) pad,
      ];
    }
    if (steam && shown.any(isSteamVirtual)) shown = [for (final pad in shown) if (isSteamVirtual(pad)) pad];
    if (remapper && shown.any((pad) => pad.kind.isPlayStation && !pad.virtual)) {
      shown = [for (final pad in shown) if (!isXbox360(pad)) pad];
    }
    return shown;
  }
}
