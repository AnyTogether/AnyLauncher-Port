import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../core/together/media.dart';

/// A media server room with LiveKit's Flutter SDK (on flutter_webrtc, as the mesh is), for share
/// play viewers without a pad and for party calls with more voices than the mesh holds.
/// Everything published in the room is subscribed; remote sound plays on the default output.
class LiveKitRoom implements SfuRoom {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _events;
  void Function()? _onChange;

  @override
  bool get connected => _room?.connectionState == lk.ConnectionState.connected;

  @override
  Future<void> connect(SfuAccess access) async {
    final room = lk.Room(
      // The picture as large as it is shown, paused while it is not. The microphone has the
      // SDK's echo cancellation, noise suppression and gain, as the mesh's has.
      roomOptions: const lk.RoomOptions(adaptiveStream: true),
    );
    _room = room;
    _events = room.createListener()..listen((_) => _onChange?.call());
    await room.connect(access.url, access.token);
    _onChange?.call();
  }

  @override
  Future<void> publishMicrophone({required bool enabled}) async {
    // Muted, nothing is published until the microphone goes on: the others hear nothing either way.
    if (enabled) await _room?.localParticipant?.setMicrophoneEnabled(true);
  }

  @override
  Future<void> setMicrophone(bool enabled) async {
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
  }

  @override
  Set<String> get participants => {...?_room?.remoteParticipants.keys};

  @override
  Set<String> get speaking => {for (final participant in _room?.activeSpeakers ?? const <lk.Participant>[]) participant.identity};

  @override
  Set<String> tracksOf(String identity) => {
    for (final publication in _room?.remoteParticipants[identity]?.trackPublications.values ?? const <lk.RemoteTrackPublication>[])
      if (publication.subscribed) publication.name,
  };

  /// Someone's subscribed video track by name, for [ServerPicture].
  lk.VideoTrack? videoOf(String identity, String name) {
    final publications = _room?.remoteParticipants[identity]?.videoTrackPublications ?? const [];
    return publications.where((publication) => publication.name == name).firstOrNull?.track;
  }

  @override
  set onChange(void Function()? handler) => _onChange = handler;

  @override
  Future<void> leave() async {
    final room = _room;
    final events = _events;
    _room = null;
    _events = null;
    _onChange = null;
    await events?.dispose();
    if (room == null) return;
    try {
      await room.disconnect();
    } finally {
      await room.dispose();
    }
  }
}

/// The host's game picture from the media server, letterboxed; [placeholder] until it comes (or
/// in tests, where the room is a fake).
class ServerPicture extends StatelessWidget {
  const ServerPicture({super.key, required this.room, required this.host, required this.placeholder});

  final SfuRoom? room;
  final String host;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    final server = room;
    final track = server is LiveKitRoom ? server.videoOf(host, sfuTrackNames.video) : null;
    if (track == null) return placeholder;
    return lk.VideoTrackRenderer(
      track,
      fit: lk.VideoViewFit.contain,
      mirrorMode: lk.VideoViewMirrorMode.off,
      placeholderBuilder: (_) => placeholder,
    );
  }
}
