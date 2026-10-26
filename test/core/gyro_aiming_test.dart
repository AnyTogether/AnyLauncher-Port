import 'dart:convert';

import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/gyro_aiming.dart';
import 'package:test/test.dart';

/// Gyro aiming as a game's setting and the ANYPS5_GYRO_AIM the engine reads (GyroAim::Parse);
/// the same strings as the macOS launcher's.
void main() {
  test('off passes nothing', () {
    expect(const GyroAiming().environment, isNull);
    expect(const GameSettings().environment(launcherLanguage: 1).containsKey('ANYPS5_GYRO_AIM'), isFalse);
    expect(
      const GameSettings(gyro: GyroAiming()).environment(launcherLanguage: 1).containsKey('ANYPS5_GYRO_AIM'),
      isFalse,
      reason: 'kept but off',
    );
  });

  test('on passes every setting', () {
    expect(const GyroAiming(enabled: true).environment, 'sensitivity=1.0,invert=none,activate=always,deadzone=2');
    const aim = GyroAiming(
      enabled: true,
      sensitivity: 25,
      invert: GyroInvert.y,
      activation: GyroActivation.l2,
      deadzone: 6,
    );
    expect(
      const GameSettings(gyro: aim).environment(launcherLanguage: 1)['ANYPS5_GYRO_AIM'],
      'sensitivity=2.5,invert=y,activate=l2,deadzone=6',
    );
    expect(
      aim.copyWith(activation: GyroActivation.touch, invert: GyroInvert.xy).environment,
      'sensitivity=2.5,invert=xy,activate=touch,deadzone=6',
    );
  });

  test('values are kept to what the engine takes', () {
    expect(
      const GyroAiming(enabled: true, sensitivity: 0, deadzone: 99).environment,
      'sensitivity=0.1,invert=none,activate=always,deadzone=45',
    );
    expect(
      const GyroAiming(enabled: true, sensitivity: 500, deadzone: -3).environment,
      'sensitivity=10.0,invert=none,activate=always,deadzone=0',
    );
  });

  test('saved settings round trip; older and odd ones still read', () {
    const settings = GameSettings(gyro: GyroAiming(enabled: true, sensitivity: 15, activation: GyroActivation.touch));
    final again = GameSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);
    expect(again.gyro, settings.gyro);
    expect(again, settings);
    expect(GameSettings.fromJson({'fullscreen': false}).gyro, isNull);
    final odd = GyroAiming.fromJson({'enabled': true, 'activation': 'sideways'});
    expect(odd.enabled, isTrue);
    expect(odd.activation, GyroActivation.always, reason: 'an unknown value keeps the default');
    expect(odd.sensitivity, 10);
    expect(settings.copyWith(gyro: null).gyro, isNull);
  });
}
