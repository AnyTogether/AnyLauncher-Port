import 'package:anyps5_desktop/core/together/media.dart';

/// A media server room for the tests: what it was told, and tracks, people and speakers a test
/// sets.
class FakeSfuRoom implements SfuRoom {
  FakeSfuRoom({this.fail = false});

  /// Connecting throws (the media server cannot be reached).
  final bool fail;
  final List<String> calls = [];
  SfuAccess? access;
  bool left = false;
  bool? microphone;
  void Function()? changed;

  @override
  Set<String> participants = {};
  @override
  Set<String> speaking = {};
  final Map<String, Set<String>> tracks = {};

  @override
  bool get connected => access != null && !left;

  @override
  Future<void> connect(SfuAccess access) async {
    calls.add('connect ${access.room}');
    if (fail) throw StateError('no media server');
    this.access = access;
  }

  @override
  Future<void> publishMicrophone({required bool enabled}) async {
    calls.add('publish mic ${enabled ? 'on' : 'off'}');
    microphone = enabled;
  }

  @override
  Future<void> setMicrophone(bool enabled) async {
    calls.add('mic ${enabled ? 'on' : 'off'}');
    microphone = enabled;
  }

  /// Whether the others are heard (false while deafened).
  bool hearing = true;

  @override
  Future<void> setHearing(bool on) async {
    calls.add('hear ${on ? 'on' : 'off'}');
    hearing = on;
  }

  @override
  Set<String> tracksOf(String identity) => tracks[identity] ?? const {};

  @override
  set onChange(void Function()? handler) => changed = handler;

  @override
  Future<void> leave() async {
    calls.add('leave');
    left = true;
  }
}
