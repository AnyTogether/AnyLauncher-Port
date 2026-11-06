import 'dart:async';

import 'media.dart';
import 'share_play.dart';
import 'socket.dart';

/// How a viewer gets the host's game: nothing (not watching), the mesh (a direct connection to
/// the host, as every share play had before the media server), or the media server.
enum ShareWatchPath { none, mesh, sfu }

/// A viewer's side of a share play's media route, followed on every `share_play.updated`: in an
/// "sfu" share play a viewer without a pad watches from the media server (the host's "game" and
/// "game-audio" tracks) and sends no mesh signals at all; a viewer holding a pad, and every
/// viewer of a mesh share play, keeps the direct connection to the host. A pad handed over moves
/// to the mesh, taken back to a fresh room; a share play that turns "sfu" mid-way moves too.
/// The mesh connection itself is the viewer's own ([onMesh] says when it should run).
class ShareWatch {
  ShareWatch({required this.me, required this.room, required this.access, this.onMesh, this.changed});

  /// Who is watching, by user ID.
  final String me;

  /// Makes a media server room (LiveKit in the launcher).
  final SfuRoom Function() room;

  /// A fresh room token for the share play (GET /share-plays/:id/sfu).
  final Future<SfuAccess> Function(String sharePlayId) access;

  /// The direct connection to the host should run (true) or close (false); told on each change.
  final void Function(bool on)? onMesh;
  final void Function()? changed;

  SharePlay? sharePlay;
  ShareWatchPath path = ShareWatchPath.none;
  SfuRoom? _room;
  SfuAccess? _pending;
  bool _mesh = false;

  /// The media server could not be reached; tried again on the next update.
  bool problem = false;
  Future<void> _queue = Future.value();

  /// The room while connected to it.
  SfuRoom? get server => _room;

  /// The host's picture has come from the media server.
  bool get hasPicture {
    final host = sharePlay?.host?.id;
    return host != null && (_room?.tracksOf(host).contains(sfuTrackNames.video) ?? false);
  }

  static ShareWatchPath pathFor(SharePlay sharePlay, String me) {
    final mine = sharePlay.viewers.where((viewer) => viewer.user.id == me).firstOrNull;
    if (mine == null) return ShareWatchPath.none;
    return sharePlay.media == MediaRoute.sfu && mine.slot == null ? ShareWatchPath.sfu : ShareWatchPath.mesh;
  }

  /// Watching begins, from the join answer (its room is used while its token is fresh).
  Future<void> start(SharePlayStart joined) {
    _pending = joined.sfu;
    return apply(joined.sharePlay, replace: true);
  }

  /// The share play as the server has it now; another share play is not this one's business
  /// unless [replace].
  Future<void> apply(SharePlay update, {bool replace = false}) => _serial(() async {
    if (!replace && sharePlay?.id != update.id) return;
    if (replace && sharePlay != null && sharePlay!.id != update.id) await _leaveRoom();
    sharePlay = update;
    await _follow(pathFor(update, me));
  });

  /// Gateway events: the share play changed or ended.
  Future<void> handle(TogetherEvent event) async {
    final current = sharePlay;
    if (current == null) return;
    switch (event.type) {
      case 'share_play.updated':
        final SharePlay update;
        try {
          update = SharePlay.fromJson(event.json);
        } on Object {
          return;
        }
        await apply(update);
      case 'share_play.ended' when event.json['sharePlayId'] == current.id:
        await stop();
    }
  }

  /// Out of the room and off the mesh (left, taken out, or the share play ended).
  Future<void> stop() => _serial(() async {
    await _follow(ShareWatchPath.none);
    sharePlay = null;
    _pending = null;
  });

  Future<void> _follow(ShareWatchPath next) async {
    path = next;
    if (next != ShareWatchPath.sfu) await _leaveRoom();
    _setMesh(next == ShareWatchPath.mesh);
    if (next == ShareWatchPath.sfu && _room == null) await _join();
    changed?.call();
  }

  void _setMesh(bool on) {
    if (_mesh == on) return;
    _mesh = on;
    onMesh?.call(on);
  }

  Future<void> _join() async {
    final id = sharePlay!.id;
    final made = room();
    try {
      final pending = _pending;
      _pending = null;
      final token = pending != null && pending.fresh() ? pending : await access(id);
      made.onChange = changed;
      await made.connect(token);
      _room = made;
      problem = false;
    } on Object {
      problem = true;
      try {
        await made.leave();
      } on Object {
        // Never connected.
      }
    }
  }

  Future<void> _leaveRoom() async {
    final left = _room;
    _room = null;
    if (left == null) return;
    left.onChange = null;
    try {
      await left.leave();
    } on Object {
      // The server takes the person out of the room as well.
    }
  }

  Future<void> _serial(Future<void> Function() step) {
    final next = _queue.then((_) => step());
    _queue = next.catchError((Object _) {});
    return next;
  }
}
