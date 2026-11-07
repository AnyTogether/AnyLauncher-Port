import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../core/together/media.dart';
import '../core/together/share_host.dart';

/// A media server room with LiveKit's Flutter SDK (on flutter_webrtc, as the mesh is), for share
/// play viewers without a pad and for party calls with more voices than the mesh holds.
/// Everything published in the room is subscribed; remote sound plays on the default output.
class LiveKitRoom implements SfuRoom {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _events;
  void Function()? _onChange;
  bool _hearing = true;

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
    _events = room.createListener()
      ..listen((event) {
        // A voice subscribed while deafened stays unheard.
        if (event is lk.TrackSubscribedEvent && !_hearing && event.track is lk.RemoteAudioTrack) {
          unawaited(event.track.disable());
        }
        _onChange?.call();
      });
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
  Future<void> setHearing(bool on) async {
    _hearing = on;
    for (final participant in _room?.remoteParticipants.values ?? const <lk.RemoteParticipant>[]) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track == null) continue;
        await (on ? track.enable() : track.disable());
      }
    }
  }

  @override
  Set<String> get participants => {...?_room?.remoteParticipants.keys};

  @override
  Set<String> get speaking => {
    for (final participant in _room?.activeSpeakers ?? const <lk.Participant>[]) participant.identity,
  };

  @override
  Set<String> tracksOf(String identity) => {
    for (final publication
        in _room?.remoteParticipants[identity]?.trackPublications.values ?? const <lk.RemoteTrackPublication>[])
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

/// The host's side of a share play through the media server, as the Mac's SfuShareHost: the
/// game's window, captured once for the mesh, published to the room as the video track "game"
/// (720p60, simulcast so the media server sends smaller layers to viewers on a slow line,
/// frame rate kept before resolution), and the game's sound as the Opus track "game-audio" at
/// 128 kbit/s without DTX or RED, when the capture has it. The tracks stay the mesh's: leaving the
/// room never stops them.
class LiveKitShareHost implements SfuPublisher {
  LiveKitShareHost({required this.stream, required this.video, required this.changed, this.sound, this.soundStream});

  final rtc.MediaStream stream;
  final rtc.MediaStreamTrack video;
  final rtc.MediaStreamTrack? sound;
  final rtc.MediaStream? soundStream;
  final void Function() changed;

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _events;
  bool _published = false;

  /// 720p60 at up to 4.5 Mbit/s, as the Mac publishes. VP8: the encoder every libwebrtc build has,
  /// the one the mesh's viewers take from this launcher too.
  static const _encoding = lk.VideoEncoding(maxBitrate: 4500000, maxFramerate: 60);
  static final _videoOptions = lk.VideoPublishOptions(
    name: sfuTrackNames.video,
    stream: 'game',
    videoCodec: 'vp8',
    videoEncoding: _encoding,
    screenShareEncoding: _encoding,
    simulcast: true,
    degradationPreference: lk.DegradationPreference.maintainFramerate,
  );

  /// Music, not speech: no DTX (silence in a game is part of it), no RED.
  static final _audioOptions = lk.AudioPublishOptions(
    name: sfuTrackNames.audio,
    stream: 'game-sound',
    encoding: const lk.AudioEncoding(maxBitrate: 128000),
    dtx: false,
    red: false,
  );

  @override
  bool get connected => _published && _room?.connectionState == lk.ConnectionState.connected;

  @override
  Future<void> start(SfuAccess access) async {
    final room = lk.Room(roomOptions: const lk.RoomOptions(dynacast: true, stopLocalTrackOnUnpublish: false));
    _room = room;
    _events = room.createListener()..listen((_) => changed());
    try {
      await room.connect(access.url, access.token);
      final participant = room.localParticipant;
      if (participant == null) throw StateError('No local participant');
      // ignore: invalid_use_of_internal_member
      final picture = lk.LocalVideoTrack(
        lk.TrackSource.screenShareVideo,
        _KeptStream(stream),
        _KeptTrack(video),
        const lk.ScreenShareCaptureOptions(
          maxFrameRate: 60,
          params: lk.VideoParameters(dimensions: lk.VideoDimensionsPresets.h720_169, encoding: _encoding),
        ),
      );
      await participant.publishVideoTrack(picture, publishOptions: _videoOptions);
      _published = true;
      changed();
      final sound = this.sound;
      if (sound != null) {
        try {
          // ignore: invalid_use_of_internal_member
          final track = lk.LocalAudioTrack(
            lk.TrackSource.screenShareAudio,
            _KeptStream(soundStream ?? stream),
            _KeptTrack(sound),
            const lk.AudioCaptureOptions(noiseSuppression: false, echoCancellation: false, autoGainControl: false),
          );
          await participant.publishAudioTrack(track, publishOptions: _audioOptions);
        } on Object {
          // The picture goes without its sound; viewers holding a pad still hear it on the mesh.
        }
      }
    } on Object {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    final room = _room;
    final events = _events;
    _room = null;
    _events = null;
    _published = false;
    await events?.dispose();
    if (room != null) {
      try {
        await room.disconnect();
      } finally {
        await room.dispose();
      }
    }
    changed();
  }
}

/// The mesh's captured track as LiveKit holds it: everything goes to the real one except
/// stopping, disabling and disposing it, which the room does on leaving and the mesh still needs.
class _KeptTrack extends rtc.MediaStreamTrack {
  _KeptTrack(this._track);
  final rtc.MediaStreamTrack _track;

  @override
  String? get id => _track.id;
  @override
  String? get label => _track.label;
  @override
  String? get kind => _track.kind;
  @override
  bool get enabled => _track.enabled;
  @override
  set enabled(bool value) {}
  @override
  bool? get muted => _track.muted;
  @override
  Map<String, dynamic> getConstraints() => _track.getConstraints();
  @override
  Future<void> applyConstraints([Map<String, dynamic>? constraints]) async {}
  @override
  Map<String, dynamic> getSettings() => _track.getSettings();
  @override
  Future<ByteBuffer> captureFrame() => _track.captureFrame();
  @override
  Future<void> stop() async {}
  @override
  // ignore: deprecated_member_use
  Future<void> dispose() async {}
}

/// The capture's stream for LiveKit: its ID and tracks, and no dispose.
class _KeptStream extends rtc.MediaStream {
  _KeptStream(this._stream) : super(_stream.id, _stream.ownerTag);
  final rtc.MediaStream _stream;

  @override
  bool? get active => _stream.active;
  @override
  // ignore: deprecated_member_use
  Future<void> getMediaTracks() async {}
  @override
  Future<void> addTrack(rtc.MediaStreamTrack track, {bool addToNative = true}) async {}
  @override
  Future<void> removeTrack(rtc.MediaStreamTrack track, {bool removeFromNative = true}) async {}
  @override
  List<rtc.MediaStreamTrack> getTracks() => _stream.getTracks();
  @override
  List<rtc.MediaStreamTrack> getAudioTracks() => _stream.getAudioTracks();
  @override
  List<rtc.MediaStreamTrack> getVideoTracks() => _stream.getVideoTracks();
  @override
  Future<void> dispose() async {}
}
