/// Gyro aiming, a game's setting (Controls › Gyro Aiming): the controller's or phone's turn moves
/// the right stick, as Steam Input's gyro to joystick camera. The engine does the aiming
/// (ANYPS5_GYRO_AIM, read through SDL); an engine without it ignores the variable. GyroAiming in
/// the macOS launcher is the same.
class GyroAiming {
  const GyroAiming({
    this.enabled = false,
    this.sensitivity = 10,
    this.invert = GyroInvert.none,
    this.activation = GyroActivation.always,
    this.deadzone = 2,
  });

  factory GyroAiming.fromJson(Map<String, dynamic> json) {
    T named<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((value) => value.name == name).firstOrNull ?? fallback;
    return GyroAiming(
      enabled: json['enabled'] as bool? ?? false,
      sensitivity: (json['sensitivity'] as num?)?.toInt() ?? 10,
      invert: named(GyroInvert.values, json['invert'], GyroInvert.none),
      activation: named(GyroActivation.values, json['activation'], GyroActivation.always),
      deadzone: (json['deadzone'] as num?)?.toInt() ?? 2,
    );
  }

  static const sensitivityMin = 1, sensitivityMax = 100;
  static const deadzoneMax = 45;

  final bool enabled;

  /// In tenths: 10 is a full stick at 90 degrees a second.
  final int sensitivity;
  final GyroInvert invert;
  final GyroActivation activation;

  /// Degrees a second a resting hand may turn without moving anything.
  final int deadzone;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'sensitivity': sensitivity,
    'invert': invert.name,
    'activation': activation.name,
    'deadzone': deadzone,
  };

  GyroAiming copyWith({
    bool? enabled,
    int? sensitivity,
    GyroInvert? invert,
    GyroActivation? activation,
    int? deadzone,
  }) => GyroAiming(
    enabled: enabled ?? this.enabled,
    sensitivity: sensitivity ?? this.sensitivity,
    invert: invert ?? this.invert,
    activation: activation ?? this.activation,
    deadzone: deadzone ?? this.deadzone,
  );

  /// ANYPS5_GYRO_AIM's value, clamped to what the engine accepts; null while off.
  String? get environment {
    if (!enabled) return null;
    final tenths = sensitivity.clamp(sensitivityMin, sensitivityMax);
    return 'sensitivity=${tenths / 10},invert=${invert.name},activate=${activation.name},deadzone=${deadzone.clamp(0, deadzoneMax)}';
  }

  @override
  bool operator ==(Object other) =>
      other is GyroAiming &&
      other.enabled == enabled &&
      other.sensitivity == sensitivity &&
      other.invert == invert &&
      other.activation == activation &&
      other.deadzone == deadzone;

  @override
  int get hashCode => Object.hash(enabled, sensitivity, invert, activation, deadzone);
}

enum GyroInvert { none, x, y, xy }

/// When the gyro aims: always, while L2 is held, or while a finger is on the touchpad.
enum GyroActivation { always, l2, touch }
