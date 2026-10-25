import 'dart:math' as math;

import '../controls.dart';
import '../gamepad/pad_navigation.dart';

// The controllers the launcher knows about, whatever reads them (SDL, or XInput, winmm and evdev
// when SDL is missing): what each one is, how it is connected, its battery, which one is Player
// 1, and a log line for every connect and disconnect that crash reports carry. The macOS
// launcher (AnyPS5Core/Pads.swift) keeps the same model and the same log lines.

/// The family a controller belongs to: its icon, its button glyphs and what it can do.
enum PadKind {
  dualSense,
  dualShock4,
  dualShock3,
  xbox,
  switchPro,
  generic;

  /// The PlayStation pads: ✕ ○ □ △ glyphs, a PS button.
  bool get isPlayStation => this == dualSense || this == dualShock4 || this == dualShock3;

  /// A light bar the launcher can colour.
  bool get hasLightBar => this == dualSense || this == dualShock4;

  /// The English name the log and the reports use.
  String get reportName => switch (this) {
    dualSense => 'DualSense',
    dualShock4 => 'DualShock 4',
    dualShock3 => 'DualShock 3',
    xbox => 'Xbox',
    switchPro => 'Switch Pro',
    generic => 'generic',
  };

  static const sony = 0x054C;
  static const microsoft = 0x045E;
  static const nintendo = 0x057E;
  static const valve = 0x28DE;

  /// What a controller is from its USB vendor and product numbers, and failing those its name.
  static PadKind classify({int? vendor, int? product, String name = ''}) {
    if (vendor != null && product != null) {
      switch ((vendor, product)) {
        case (sony, 0x0CE6) || (sony, 0x0DF2) || (sony, 0x0E5F):
          return dualSense;
        case (sony, 0x05C4) || (sony, 0x09CC) || (sony, 0x0BA0):
          return dualShock4;
        case (sony, 0x0268):
          return dualShock3;
        case (microsoft, _):
          return xbox;
        case (nintendo, 0x2009):
          return switchPro;
        // Steam's virtual pad is an Xbox 360 pad to the games.
        case (valve, 0x11FF):
          return xbox;
      }
    }
    final lower = name.toLowerCase();
    if (lower.contains('dualsense')) return dualSense;
    if (lower.contains('dualshock 4') || lower.contains('dualshock4') || (vendor == sony && lower.contains('wireless controller'))) {
      return dualShock4;
    }
    if (lower.contains('playstation(r)3') || lower.contains('dualshock 3') || lower.contains('ps3') || lower.contains('sixaxis')) {
      return dualShock3;
    }
    if (lower.contains('xbox') || lower.contains('x-box') || lower.contains('xinput')) return xbox;
    if (lower.contains('pro controller')) return switchPro;
    return generic;
  }
}

/// How a controller reaches the computer.
enum PadConnection {
  usb,
  bluetooth,
  unknown;

  String get reportName => switch (this) {
    usb => 'USB',
    bluetooth => 'Bluetooth',
    unknown => 'connection unknown',
  };
}

/// A controller's battery: a percentage (a level's middle where the reader only gives levels)
/// and whether it charges, where that is known.
class PadBattery {
  PadBattery(int percent, {this.approximate = false, this.charging}) : percent = percent.clamp(0, 100);

  final int percent;

  /// The reader gives only a few levels.
  final bool approximate;
  final bool? charging;

  /// Low enough to say so (the troubleshooter, the controller indicator).
  bool get low => percent <= 15 && charging != true;

  String get reportText => '${approximate ? 'about ' : ''}$percent%${charging == true ? ' charging' : ''}';

  @override
  bool operator ==(Object other) =>
      other is PadBattery && other.percent == percent && other.approximate == approximate && other.charging == charging;

  @override
  int get hashCode => Object.hash(percent, approximate, charging);
}

/// One controller as the launcher shows it.
class PadInfo {
  const PadInfo({
    required this.id,
    required this.name,
    required this.kind,
    this.connection = PadConnection.unknown,
    this.battery,
    required this.driver,
    this.vendor,
    this.product,
    this.hasRumble = false,
    this.hasLight = false,
    this.virtual = false,
  });

  /// The reader's own id, kept while it stays connected.
  final String id;
  final String name;
  final PadKind kind;
  final PadConnection connection;
  final PadBattery? battery;

  /// What reads it: "SDL HIDAPI", "SDL XInput", "XInput", "winmm", "evdev".
  final String driver;
  final int? vendor;
  final int? product;
  final bool hasRumble;
  final bool hasLight;

  /// A pad a program makes (Steam's, DS4Windows' and DualSenseX's virtual Xbox pads).
  final bool virtual;

  PadInfo copyWith({PadConnection? connection, PadBattery? battery, bool clearBattery = false}) => PadInfo(
    id: id,
    name: name,
    kind: kind,
    connection: connection ?? this.connection,
    battery: clearBattery ? null : battery ?? this.battery,
    driver: driver,
    vendor: vendor,
    product: product,
    hasRumble: hasRumble,
    hasLight: hasLight,
    virtual: virtual,
  );

  /// "054c:0ce6", or null.
  String? get usbId => vendor != null && product != null
      ? '${vendor!.toRadixString(16).padLeft(4, '0')}:${product!.toRadixString(16).padLeft(4, '0')}'
      : null;

  /// "DualSense Wireless Controller (DualSense, Bluetooth, battery 80%, SDL HIDAPI, 054c:0ce6)".
  String get reportLine {
    final parts = [
      kind.reportName,
      connection.reportName,
      if (battery case final battery?) 'battery ${battery.reportText}',
      driver,
      if (virtual) 'virtual',
      ?usbId,
    ];
    return '$name (${parts.join(', ')})';
  }

  @override
  bool operator ==(Object other) =>
      other is PadInfo &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.connection == connection &&
      other.battery == battery &&
      other.driver == driver &&
      other.vendor == vendor &&
      other.product == product &&
      other.virtual == virtual;

  @override
  int get hashCode => Object.hash(id, name, kind, connection, battery, driver, vendor, product, virtual);
}

/// The controllers connected now, in the order they came, and Player 1: the one used last (the
/// one the launcher's vibration and light go to). Every connect and disconnect gives a log line.
class PadRoster {
  final List<PadInfo> _pads = [];
  final Map<String, DateTime> _connectedAt = {};
  String? _playerOne;

  List<PadInfo> get pads => List.unmodifiable(_pads);
  String? get playerOne => _playerOne;

  PadInfo? pad(String id) => _pads.where((pad) => pad.id == id).firstOrNull;

  /// The pads with Player 1 first.
  List<PadInfo> get ordered => [..._pads.where((pad) => pad.id == _playerOne), ..._pads.where((pad) => pad.id != _playerOne)];

  /// A controller came (or a reader saw it again with new facts): the log line when it is new.
  String? connect(PadInfo info, {DateTime? now}) {
    final index = _pads.indexWhere((pad) => pad.id == info.id);
    if (index >= 0) {
      _pads[index] = info;
      return null;
    }
    _pads.add(info);
    _connectedAt[info.id] = now ?? DateTime.now();
    _playerOne ??= info.id;
    return 'controller connected: ${info.reportLine}';
  }

  /// A controller left: its log line (null when it was not known). Player 1 passes to the
  /// controller that came first among those left.
  String? disconnect(String id, {DateTime? now}) {
    final index = _pads.indexWhere((pad) => pad.id == id);
    if (index < 0) return null;
    final info = _pads.removeAt(index);
    final since = _connectedAt.remove(id);
    if (_playerOne == id) _playerOne = _pads.firstOrNull?.id;
    var line = 'controller disconnected: ${info.name} (${info.kind.reportName}, ${info.connection.reportName}, ${info.driver})';
    if (since != null) line += ' after ${duration((now ?? DateTime.now()).difference(since))}';
    return line;
  }

  /// A battery or connection reading changed; nothing is logged. Returns whether it changed.
  bool update(PadInfo info) {
    final index = _pads.indexWhere((pad) => pad.id == info.id);
    if (index < 0 || _pads[index] == info) return false;
    _pads[index] = info;
    return true;
  }

  /// A press from [id]: it becomes Player 1. Returns whether Player 1 changed.
  bool used(String id) {
    if (_playerOne == id || pad(id) == null) return false;
    _playerOne = id;
    return true;
  }

  /// For readers that poll: the controllers present now against those known. Returns the log
  /// lines of those that came and went.
  List<String> sync(List<PadInfo> present, {DateTime? now}) {
    final ids = {for (final pad in present) pad.id};
    return [
      for (final gone in [for (final pad in _pads) pad.id])
        if (!ids.contains(gone)) ?disconnect(gone, now: now),
      for (final info in present) ?connect(info, now: now),
    ];
  }

  static String duration(Duration elapsed) {
    final seconds = math.max(0, elapsed.inSeconds);
    if (seconds < 60) return '$seconds s';
    if (seconds < 3600) return '${seconds ~/ 60} min';
    return '${seconds ~/ 3600} h ${seconds % 3600 ~/ 60} min';
  }
}

/// The last controller log lines with their times, for the crash report and the issue.
class PadLog {
  static const capacity = 40;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String line, {DateTime? at}) {
    final time = at ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    _lines.add('${two(time.hour)}:${two(time.minute)}:${two(time.second)} $line');
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);
  }

  /// The report's lines: the controllers connected now (Player 1 first), then the log.
  static List<String> report(PadRoster roster, PadLog log) {
    final ordered = roster.ordered;
    return [
      if (ordered.isEmpty) 'none connected',
      for (final (index, pad) in ordered.indexed) '${index == 0 ? 'Player 1' : 'Also'}: ${pad.reportLine}',
      if (log.lines.isNotEmpty) ...['Recent:', for (final line in log.lines) '  $line'],
    ];
  }
}

/// Everything a controller holds at one moment, for the controller test: the buttons, both
/// sticks (-1 to 1, down positive as the screen draws it) and both triggers (0 to 1).
class PadState {
  const PadState({
    this.pressed = const {},
    this.leftX = 0,
    this.leftY = 0,
    this.rightX = 0,
    this.rightY = 0,
    this.l2 = 0,
    this.r2 = 0,
  });

  static const idle = PadState();

  final Set<PadButton> pressed;
  final double leftX;
  final double leftY;
  final double rightX;
  final double rightY;
  final double l2;
  final double r2;

  @override
  bool operator ==(Object other) =>
      other is PadState &&
      other.pressed.length == pressed.length &&
      other.pressed.containsAll(pressed) &&
      other.leftX == leftX &&
      other.leftY == leftY &&
      other.rightX == rightX &&
      other.rightY == rightY &&
      other.l2 == l2 &&
      other.r2 == r2;

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(pressed), leftX, leftY, rightX, rightY, l2, r2);
}

/// Settings › Controllers › Stick Dead Zone: a stick resting a little off its middle (drift)
/// reads as centred. Radial, rescaled so the edge is still the edge.
abstract final class StickDeadzone {
  static const maximum = 30;
  static const step = 2;

  /// [percent] of the stick's travel is ignored; what is left is stretched back to 0…1.
  static (double, double) apply(double x, double y, int percent) {
    final zone = percent.clamp(0, maximum) / 100;
    if (zone == 0) return (x, y);
    final length = math.sqrt(x * x + y * y);
    if (length <= zone) return (0, 0);
    final scaled = math.min(1.0, (length - zone) / (1 - zone));
    return (x / length * scaled, y / length * scaled);
  }

  /// The tuning a game starts with: its own dead zones where it set them, the controllers'
  /// dead zone where it did not.
  static InputTuning tuning(InputTuning? own, int percent) {
    final tuning = own ?? const InputTuning();
    if (percent <= 0) return tuning;
    return tuning.copyWith(
      leftDeadzone: tuning.leftDeadzone == 0 ? percent : tuning.leftDeadzone,
      rightDeadzone: tuning.rightDeadzone == 0 ? percent : tuning.rightDeadzone,
    );
  }
}

/// The dead zone between the readers and the launcher's input gate: each pad's left stick
/// passed on with [StickDeadzone] applied to both axes together.
class DeadzoneStage {
  DeadzoneStage(this.forward);

  final void Function(PadEvent event) forward;

  /// In percent; 0 passes the stick on as it is.
  int percent = 0;

  final Map<String, (double, double)> _raw = {};
  final Map<String, (double, double)> _sent = {};

  void handle(PadEvent event) {
    if (event is PadGone) {
      _raw.remove(event.pad);
      _sent.remove(event.pad);
      return forward(event);
    }
    if (event is! PadAxisEvent) return forward(event);
    final (x, y) = _raw[event.pad] ?? (0.0, 0.0);
    final raw = event.axis == PadAxis.leftX ? (event.value, y) : (x, event.value);
    _raw[event.pad] = raw;
    final zoned = StickDeadzone.apply(raw.$1, raw.$2, percent);
    final (sentX, sentY) = _sent[event.pad] ?? (0.0, 0.0);
    _sent[event.pad] = zoned;
    if (zoned.$1 != sentX) forward(PadAxisEvent(event.pad, PadAxis.leftX, zoned.$1));
    if (zoned.$2 != sentY) forward(PadAxisEvent(event.pad, PadAxis.leftY, zoned.$2));
  }
}

/// The colour of a DualSense's or DualShock 4's light bar while the launcher is in front.
enum PadLight {
  theme,
  blue,
  red,
  green,
  purple,
  pink,
  orange,
  white,
  off;

  /// Red, green and blue, 0 to 255; null for the theme's accent, which the launcher supplies.
  (int, int, int)? get rgb => switch (this) {
    theme => null,
    blue => (0, 64, 255),
    red => (255, 13, 13),
    green => (13, 230, 51),
    purple => (140, 26, 255),
    pink => (255, 51, 153),
    orange => (255, 115, 0),
    white => (255, 255, 255),
    off => (0, 0, 0),
  };

  static PadLight parse(String? name) => PadLight.values.where((light) => light.name == name).firstOrNull ?? theme;
}

/// The confirm button: Cross (the West's layout) or Circle (Japan's), and the hints to match.
abstract final class ConfirmButton {
  /// The command a south or east press gives when Circle confirms.
  static PadCommand command(PadCommand command, {required bool circleConfirms}) {
    if (!circleConfirms) return command;
    return switch (command) {
      PadCommand.select => PadCommand.back,
      PadCommand.back => PadCommand.select,
      _ => command,
    };
  }

  /// A hint's glyphs as shown: ✕ and ○ change places when Circle confirms.
  static String glyphs(String text, {required bool circleConfirms}) {
    if (!circleConfirms) return text;
    return text.split('').map((char) => char == '✕' ? '○' : char == '○' ? '✕' : char).join();
  }
}
