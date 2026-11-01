@DefaultAsset('package:anyps5_desktop/core/capture/game_sound_native.dart')
library;

import 'dart:ffi';

// native/capture/anyps5_sound.c, built by hook/build.dart: WASAPI loopback on Windows, nothing
// elsewhere.
@Native<Pointer<Void> Function(Uint32, Int32)>(symbol: 'anyps5_sound_open')
external Pointer<Void> soundOpen(int pid, int allowSystem);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'anyps5_sound_state')
external int soundState(Pointer<Void> handle);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(symbol: 'anyps5_sound_read')
external int soundRead(Pointer<Void> handle, Pointer<Uint8> out, int size);

@Native<Void Function(Pointer<Void>)>(symbol: 'anyps5_sound_close')
external void soundClose(Pointer<Void> handle);

/// What anyps5_sound_state says.
abstract final class NativeSoundState {
  static const starting = 0;
  static const game = 1;
  static const system = 2;
  static const failed = -1;
}
