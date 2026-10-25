import 'steam_shortcuts.dart';

/// How this launch came from Steam, read from the arguments and the environment: Steam starts
/// a non-Steam shortcut with SteamGameId / SteamAppId set (and AnyPS5's shortcuts pass
/// --steam), and with Steam Input on it hides the physical controllers it took over through
/// SDL_GAMECONTROLLER_IGNORE_DEVICES, offering its virtual pad (28de:11ff) in their place.
class SteamLaunch {
  const SteamLaunch({
    this.fromSteam = false,
    this.gameMode = false,
    this.gameId,
    this.ignoredPads = const {},
    this.onlyPads,
  });

  factory SteamLaunch.detect(List<String> arguments, Map<String, String> environment) {
    String? value(String name) {
      final text = environment[name];
      return text == null || text.isEmpty || text == '0' ? null : text;
    }

    final gameId = value('SteamGameId') ?? value('SteamAppId');
    final desktop = (environment['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
    return SteamLaunch(
      fromSteam: arguments.contains(SteamShortcuts.launchFlag) || gameId != null,
      gameMode: desktop == 'gamescope' || value('GAMESCOPE_WAYLAND_DISPLAY') != null,
      gameId: gameId,
      ignoredPads: parseDevices(environment['SDL_GAMECONTROLLER_IGNORE_DEVICES']),
      onlyPads: environment.containsKey('SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT')
          ? parseDevices(environment['SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT'])
          : null,
    );
  }

  /// Started from a Steam shortcut (or any Steam game launch).
  final bool fromSteam;

  /// Inside gamescope: the Steam Deck's (or SteamOS's) Game Mode, where Steam is the whole
  /// session and cannot be closed to write shortcuts.
  final bool gameMode;

  /// What Steam calls this launch (the shortcut's 64-bit game ID), when it said.
  final String? gameId;

  /// The controllers Steam Input took over: read through its virtual pad instead.
  final Set<(int, int)> ignoredPads;

  /// When set, every controller but these is Steam's to read.
  final Set<(int, int)>? onlyPads;

  /// Valve's vendor ID and Steam Input's virtual gamepad.
  static const valveVendor = 0x28DE;
  static const virtualPadProduct = 0x11FF;

  static bool isSteamVirtualPad(int vendor, int product) => vendor == valveVendor && product == virtualPadProduct;

  /// Whether a physical controller should be left alone because Steam Input reads it and
  /// offers it again as its virtual pad. Steam's own virtual pad is never skipped.
  bool skipPhysicalPad(int vendor, int product) {
    if (!fromSteam || isSteamVirtualPad(vendor, product)) return false;
    final only = onlyPads;
    if (only != null) return !only.contains((vendor, product));
    return ignoredPads.contains((vendor, product));
  }

  /// SDL's device list: "0x054c/0x0ce6,0x28de/0x1142" (vendor/product, hex).
  static Set<(int, int)> parseDevices(String? text) {
    if (text == null) return const {};
    final found = <(int, int)>{};
    for (final item in text.split(',')) {
      final parts = item.trim().split('/');
      if (parts.length != 2) continue;
      int? hex(String part) => int.tryParse(part.trim().toLowerCase().replaceFirst('0x', ''), radix: 16);
      final vendor = hex(parts[0]);
      final product = hex(parts[1]);
      if (vendor != null && product != null) found.add((vendor, product));
    }
    return found;
  }
}
