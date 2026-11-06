import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoView, RTCVideoViewObjectFit;

import '../core/capture/game_sound.dart';
import '../core/capture/stream_packet.dart';
import '../core/capture/video_encoders.dart';
import '../core/controllers/pad_info.dart';
import '../core/desktop/desktop.dart';
import '../core/remote/remote_server.dart';
import '../core/together/account.dart';
import '../core/together/share_host.dart';
import '../core/together/share_play.dart';
import '../core/together/share_watch.dart';
import '../core/together/socket.dart';
import 'app_model.dart';
import 'share_speaker.dart';
import 'share_webrtc.dart';
import 'strings.dart';

/// Pads go nowhere: no phone server, so no bridges to the game.
class _NoBridges implements SharePadBridges {
  @override
  int? reservePadBridge() => null;
  @override
  void releasePadBridge(int bridge) {}
  @override
  void sendPad(Uint8List data, int bridge) {}
}

/// Share play, as the Mac launcher has it. Hosting: while a game runs, friends watch it live in a
/// browser, on their phone or in their launcher, and a viewer the user lets play joins in as
/// player 2, 3 or 4. Picture and sound go from this computer straight to each viewer (WebRTC);
/// AnyTogether introduces them. In the quick menu while a game plays. Watching: a friend's share
/// play full screen here, its sound, and the user's controller as their player once they let the
/// user play; from an invite, a friend sharing in the Friends panel, or Find Players' Live now.
class SharePlayModel {
  SharePlayModel(this.app);

  final AppModel app;

  /// Tests: a stand-in for flutter_webrtc, the game's sound, the speaker and the server.
  ShareEngine Function()? engineOverride;
  WatchEngine Function()? watchEngineOverride;
  GameSound Function(int pid)? soundOverride;
  ShareSoundOut Function()? speakerOverride;
  PadState? Function()? padOverride;
  SharePlayClient? clientOverride;

  SharePlayClient get _client => clientOverride ?? SharePlayClient(app.together.account);

  ShareHostSession? _session;
  SharePlay? hosting;
  bool starting = false;
  Timer? _renewal;
  Timer? _measure;
  GameSound? _sound;

  /// Friends may walk in without an invite; how many may watch at once.
  bool openToFriends = true;
  int maxViewers = 2;

  bool get active => _session != null;

  /// Why share play cannot start here, or null when it can.
  String? get unavailable {
    if (!app.together.signedIn) return T.text('sharePlaySignInFirst');
    if (!(app.together.family.rules?.sharePlay ?? true)) return T.text('familyNoSharePlay');
    if (engineOverride == null && !ScreenGrab.supported(app.system, app.services.environment ?? Platform.environment)) {
      return T.text('replayNoScreen');
    }
    return null;
  }

  Future<void> start() async {
    final playing = app.running;
    if (playing == null || active || starting) return;
    final reason = unavailable;
    if (reason != null) return app.show(reason);
    final desktop = app.desktop;
    final title = desktop is GameAreas ? (desktop as GameAreas).gameTitle(playing.$2.pid) : null;
    starting = true;
    app.refresh();
    final engine = engineOverride?.call() ?? WebRtcShare();
    try {
      if (title == null || !await engine.start(windowTitle: title)) {
        await engine.stop();
        app.show(T.text('sharePlayNoWindow'));
        return;
      }
      final game = playing.$1;
      final started = await _client.start(titleId: game.titleId, title: game.name, open: openToFriends, maxViewers: maxViewers);
      if (app.running?.$2.pid != playing.$2.pid) {
        await engine.stop();
        unawaited(_client.end(started.sharePlay.id).catchError((Object _) {}));
        return;
      }
      final remote = app.remote;
      final SharePadBridges bridges = remote ?? _NoBridges();
      final session = ShareHostSession(
        id: started.sharePlay.id,
        engine: engine,
        iceServers: started.iceServers,
        router: SharePadRouter(bridges),
        signal: (to, device, kind, data) => app.together.hub.socket.send(
          ShareSignal.frame(to: to, device: device, share: started.sharePlay.id, kind: kind, data: data),
        ),
        changed: app.refresh,
      );
      _session = session;
      remote?.padOutput = session.padOutput;
      _renew(started.expiresAt);
      _measure = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(session.measure()));
      await _apply(started.sharePlay);
      app.show(T.format('sharePlayStarted', [game.name]));
      await _startSound(session, playing.$2.pid);
      final opus = engine.hasSound ? 'Opus track on request' : 'no Opus track';
      app.addRecentLine('${DateTime.now().toIso8601String()} share play: $opus, PCM ${_sound?.reach.name ?? 'none'}');
    } on Object catch (error) {
      await engine.stop();
      app.show('${T.text('sharePlayCouldNotStart')}: ${app.together.message(error)}');
    } finally {
      starting = false;
      app.refresh();
    }
  }

  /// The game's sound for viewers who take PCM (the phone app, older launchers, any viewer
  /// until their Opus track is taken): the launcher's own capture of the game, in 5 ms packets.
  Future<void> _startSound(ShareHostSession session, int pid) async {
    final sound = soundOverride?.call(pid) ?? app.media.soundOf(pid);
    final chunker = SoundChunker();
    final clock = Stopwatch()..start();
    _sound = sound;
    try {
      await sound.start((samples) {
        if (_session != session) return;
        for (final packet in chunker.add(samples, clock.elapsedMilliseconds)) {
          session.pushSound(packet);
        }
      });
    } on Object {
      // No way to hear the game here: viewers who ask still get the Opus track, if any.
    }
  }

  Future<void> _apply(SharePlay sharePlay) async {
    final session = _session;
    if (session == null || session.id != sharePlay.id) return;
    hosting = sharePlay;
    await session.apply(sharePlay);
    app.refresh();
  }

  /// New relay credentials ten minutes before the old ones end.
  void _renew(DateTime? expiresAt) {
    _renewal?.cancel();
    if (expiresAt == null) return;
    final wait = expiresAt.difference(DateTime.now()) - const Duration(minutes: 10);
    _renewal = Timer(wait.isNegative ? const Duration(seconds: 1) : wait, () async {
      final session = _session;
      if (session == null) return;
      try {
        final renewed = await _client.iceServers(session.id);
        await session.renew(renewed.iceServers);
        _renew(renewed.expiresAt);
      } on Object {
        // The connections keep their relays until they run out.
      }
    });
  }

  /// The gateway's share play events (from TogetherModel), for the share play hosted and the
  /// one watched, and the invites.
  void event(TogetherEvent event) {
    final data = event.json;
    if (_watchEvent(event)) return;
    final session = _session;
    switch (event.type) {
      case 'live.ready':
        unawaited(loadInvites());
      case 'share_play.invite':
        final invite = ShareInvite.fromJson(data);
        if (invite == null) return;
        invites = [...invites.where((known) => known.sharePlayId != invite.sharePlayId), invite];
        app.show(T.format('sharePlayInvitedYou', [invite.from?.displayName ?? '', _gameName(invite.titleId, invite.title)]));
        app.refresh();
      case 'share_play.updated' when session != null:
        try {
          unawaited(_apply(SharePlay.fromJson(data)));
        } on Object {
          // Not a share play: nothing to follow.
        }
      case 'share_play.signal' when session != null:
        final signal = ShareSignal.fromJson(data);
        if (signal != null) unawaited(session.receive(signal));
      case 'share_play.ended':
        final id = data['sharePlayId'];
        if (invites.any((invite) => invite.sharePlayId == id)) {
          invites = [...invites.where((invite) => invite.sharePlayId != id)];
          app.refresh();
        }
        // Ended from elsewhere (the website, another launcher): this one lets go too.
        if (session != null && id == session.id) unawaited(_end());
    }
  }

  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    unawaited(_client.end(session.id).catchError((Object _) {}));
    await _end();
    app.show(T.text('sharePlayStopped'));
  }

  Future<void> _end() async {
    final session = _session;
    _session = null;
    hosting = null;
    _renewal?.cancel();
    _measure?.cancel();
    _measure = null;
    final sound = _sound;
    _sound = null;
    unawaited(sound?.stop().catchError((Object _) {}));
    final remote = app.remote;
    if (remote is RemoteServer) remote.padOutput = null;
    await session?.close();
    app.refresh();
  }

  /// A share play only while its game runs.
  void gameEnded() {
    if (active) unawaited(stop());
  }

  Future<void> _call(Future<SharePlay?> Function(String id) change) async {
    final session = _session;
    if (session == null) return;
    try {
      final updated = await change(session.id);
      if (updated != null) await _apply(updated);
    } on Object catch (error) {
      app.show(app.together.message(error));
    }
  }

  void letPlay(ShareViewer viewer) {
    final pad = ShareRoster.freePad(hosting?.viewers ?? const []);
    if (pad == null) return app.show(T.text('sharePlayNoPadFree'));
    unawaited(
      _call((id) async {
        final updated = await _client.setPad(id, viewer.user.id, pad);
        app.show(T.format('sharePlayNowPlays', [viewer.user.displayName, pad]));
        return updated;
      }),
    );
  }

  void stopPlaying(ShareViewer viewer) => unawaited(_call((id) => _client.setPad(id, viewer.user.id, null)));

  void remove(ShareViewer viewer) => unawaited(
    _call((id) async {
      await _client.remove(id, viewer.user.id);
      return null;
    }),
  );

  void invite(String userId, String name) => unawaited(
    _call((id) async {
      await _client.invite(id, [userId]);
      app.show(T.format('sharePlayInvited', [name]));
      return null;
    }),
  );

  void setOpen(bool open) {
    openToFriends = open;
    unawaited(_call((id) => _client.update(id, open: open)));
  }

  void setMaxViewers(int count) {
    maxViewers = count;
    if ((hosting?.viewers.length ?? 0) > count) return app.refresh();
    unawaited(_call((id) => _client.update(id, maxViewers: count)));
  }

  /// The quick menu's share play rows: start, or who watches and plays, friends to invite, stop.
  List<PanelRow> rows() {
    final playing = app.running;
    final sharing = hosting;
    if (sharing == null) {
      if (playing == null || unavailable != null) return const [];
      return [
        PanelRow(
          id: 'share-start',
          title: starting ? T.text('sharePlayStarting') : T.format('sharePlayStart', [playing.$1.name]),
          detail: T.text('sharePlayStartDetail'),
          kind: ActionRow(() => unawaited(start())),
        ),
      ];
    }
    final links = _session?.links ?? const {};
    final stats = _session?.stats ?? const {};
    final rows = <PanelRow>[
      PanelRow(
        id: 'share-on',
        title: T.format('sharePlaySharing', [sharing.title ?? playing?.$1.name ?? sharing.titleId]),
        kind: InfoRow(T.format('sharePlayWatching', [sharing.viewers.length, sharing.maxViewers])),
      ),
    ];
    for (final viewer in sharing.viewers) {
      final name = viewer.user.displayName;
      final detail = linkText(
        connected: links[viewer.user.id] == 'connected',
        stats: stats[viewer.user.id],
        pad: viewer.slot,
      );
      if (viewer.slot != null) {
        rows.add(
          PanelRow(
            id: 'share-stop-${viewer.user.id}',
            title: T.format('sharePlayStopPlaying', [name]),
            detail: detail,
            person: PanelPerson(name: name, avatar: viewer.user.avatar, status: PersonStatus.playing),
            kind: ActionRow(() => stopPlaying(viewer)),
          ),
        );
      } else {
        rows.add(
          PanelRow(
            id: 'share-play-${viewer.user.id}',
            title: T.format('sharePlayLetPlay', [name, ShareRoster.freePad(sharing.viewers) ?? 0]),
            detail: detail,
            person: PanelPerson(name: name, avatar: viewer.user.avatar, status: PersonStatus.online),
            kind: ActionRow(() => letPlay(viewer)),
          ),
        );
      }
      rows.add(
        PanelRow(
          id: 'share-remove-${viewer.user.id}',
          title: T.format('sharePlayRemove', [name]),
          kind: ActionRow(() => remove(viewer), destructive: true),
        ),
      );
    }
    rows
      ..add(
        PanelRow(
          id: 'share-open',
          title: T.text('sharePlayOpenToFriends'),
          detail: T.text('sharePlayOpenToFriendsDetail'),
          kind: ToggleRow(sharing.open, setOpen),
        ),
      )
      ..add(
        PanelRow(
          id: 'share-max',
          title: T.text('sharePlayMaxViewers'),
          detail: T.text('sharePlayMaxViewersDetail'),
          kind: StepperRow(
            value: sharing.maxViewers,
            min: sharing.viewers.isEmpty ? 1 : sharing.viewers.length,
            max: ShareRoster.maxViewers,
            step: 1,
            format: (count) => '$count',
            set: setMaxViewers,
          ),
        ),
      );
    final watching = {for (final viewer in sharing.viewers) viewer.user.id};
    final invited = {for (final person in sharing.invited) person.id};
    for (final friend in app.together.hub.friends.friends) {
      if (!friend.presence.online || watching.contains(friend.person.id)) continue;
      final name = friend.person.displayName;
      rows.add(
        PanelRow(
          id: 'share-invite-${friend.person.id}',
          title: T.format('sharePlayInvite', [name]),
          detail: invited.contains(friend.person.id) ? T.text('sharePlayInvitedAlready') : null,
          person: PanelPerson(
            name: name,
            avatar: friend.person.avatar,
            status: friend.presence.playing ? PersonStatus.playing : PersonStatus.online,
          ),
          kind: ActionRow(() => invite(friend.person.id, name)),
        ),
      );
    }
    rows.add(PanelRow(id: 'share-stop', title: T.text('sharePlayStop'), kind: ActionRow(() => unawaited(stop()), destructive: true)));
    return rows;
  }

  /// A viewer's line, as the Mac writes it: player or watching, then the path, its round trip
  /// and the picture once connected.
  static String linkText({required bool connected, ShareLinkStats? stats, int? pad}) {
    final parts = [if (pad != null) T.format('sharePlayPlayer', [pad]) else T.text('sharePlayOnlyWatches')];
    if (!connected) return [...parts, T.text('sharePlayConnecting')].join(' · ');
    if (stats?.relayed case final relayed?) parts.add(T.text(relayed ? 'sharePlayRelayed' : 'sharePlayDirect'));
    if (stats?.roundTripMs case final roundTrip?) parts.add(T.format('sharePlayRoundTrip', [roundTrip.round()]));
    if ((stats?.framesPerSecond, stats?.frameHeight) case (final fps?, final height?)) parts.add('${height}p${fps.round()}');
    return parts.join(' · ');
  }

  String _gameName(String titleId, String? title) =>
      app.games.where((game) => game.titleId == titleId).firstOrNull?.name ?? title ?? titleId;

  // Watching.

  ShareWatchSession? _watch;
  WatchEngine? _watchEngine;
  ShareSoundOut? _speaker;
  SharePadPump? _pump;
  Timer? _watchStatsTimer;
  bool joining = false;

  /// The share play watched, as the server has it now.
  SharePlay? watching;
  WatchStats? watchStats;

  /// Invites waiting, newest last.
  List<ShareInvite> invites = const [];

  /// Where the watch was opened from, to go back to.
  PanelSpot? _watchReturn;

  bool get isWatching => _watch != null;
  bool get watchConnected => _watch?.connected ?? false;

  /// The pad the host handed the user, null while they only watch.
  int? get watchSlot {
    final me = app.together.user?.id;
    return watching?.viewers.where((viewer) => viewer.user.id == me).firstOrNull?.slot;
  }

  /// The host's picture, drawn by flutter_webrtc; nothing in tests.
  Widget? watchVideo() {
    final engine = _watchEngine;
    if (engine is! WebRtcWatch) return null;
    return RTCVideoView(engine.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);
  }

  /// Invites waiting, and a share play a launcher that quit left behind (ended).
  Future<void> loadInvites() async {
    if (!app.together.signedIn) return;
    try {
      final mine = await _client.mine();
      invites = mine.invites;
      final stale = mine.hosting;
      if (stale != null && stale.id != _session?.id) unawaited(_client.end(stale.id).catchError((Object _) {}));
      app.refresh();
    } on Object {
      // Offline: the invites come with the next connection.
    }
  }

  void decline(ShareInvite invite) {
    invites = [...invites.where((known) => known.sharePlayId != invite.sharePlayId)];
    app.refresh();
    unawaited(_client.decline(invite.sharePlayId).catchError((Object _) {}));
  }

  /// Watches [id] here, full screen.
  Future<void> watch(String id) async {
    if (!(app.together.family.rules?.sharePlay ?? true)) return app.show(T.text('familyNoSharePlay'));
    final me = app.together.user;
    if (me == null) return app.show(T.text('sharePlaySignInFirst'));
    if (_watch?.id == id) return app.open(Layer.shareWatch);
    if (joining) return;
    await leaveWatching();
    joining = true;
    app.refresh();
    try {
      final joined = await _client.join(id);
      final host = joined.sharePlay.host;
      if (host == null) return;
      final engine = watchEngineOverride?.call() ?? WebRtcWatch();
      final speaker = speakerOverride?.call() ?? SoloudShareSound();
      final session = ShareWatchSession(
        id: id,
        hostId: host.id,
        hostDevice: joined.sharePlay.hostDevice,
        engine: engine,
        iceServers: joined.iceServers,
        signal: (to, device, kind, data) =>
            app.together.hub.socket.send(ShareSignal.frame(to: to, device: device, share: id, kind: kind, data: data)),
        onSound: speaker.push,
        changed: app.refresh,
      );
      _watch = session;
      _watchEngine = engine;
      _speaker = speaker;
      watching = joined.sharePlay;
      watchStats = null;
      invites = [...invites.where((invite) => invite.sharePlayId != id)];
      _watchReturn = app.overlay == Layer.shareWatch ? _watchReturn : app.spot;
      unawaited(app.startSound());
      app.open(Layer.shareWatch);
      session.start();
      _followSlot();
      _watchStatsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        final stats = await session.stats();
        if (_watch != session) return;
        watchStats = stats;
        app.refresh();
      });
    } on TogetherProblem catch (problem) {
      app.show(problem.code == 'full' ? T.text('sharePlayFull') : '${T.text('sharePlayCouldNotWatch')}: ${app.together.message(problem)}');
    } on Object catch (error) {
      app.show('${T.text('sharePlayCouldNotWatch')}: ${app.together.message(error)}');
    } finally {
      joining = false;
      app.refresh();
    }
  }

  /// The controller goes to the host while they let the user play, and stops when they take it.
  void _followSlot() {
    final session = _watch;
    if (session == null) return;
    if (watchSlot == null) {
      _pump?.stop();
      _pump = null;
      return;
    }
    _pump ??= SharePadPump(read: padOverride ?? _readPad, send: session.sendPad)..start();
  }

  /// Player 1's controller now, as the controller test reads it.
  PadState? _readPad() {
    final controllers = app.controllers;
    final pad = controllers.playerOne;
    if (pad == null) return null;
    return controllers.inventory?.state(pad.id);
  }

  Future<void> leaveWatching({bool tellServer = true}) async {
    final session = _watch;
    if (session == null) return;
    _watch = null;
    _pump?.stop();
    _pump = null;
    _watchStatsTimer?.cancel();
    _speaker?.stop();
    _speaker = null;
    final engine = _watchEngine;
    _watchEngine = null;
    watching = null;
    watchStats = null;
    await session.close();
    if (engine is WebRtcWatch) unawaited(engine.dispose());
    if (tellServer) unawaited(_client.leave(session.id).catchError((Object _) {}));
    if (app.overlay == Layer.shareWatch) app.returnTo(_watchReturn);
    app.refresh();
  }

  /// The share play watched changed (a pad handed over or taken back), a signal came, or it
  /// ended; false for anything else.
  bool _watchEvent(TogetherEvent event) {
    final session = _watch;
    if (session == null) return false;
    final data = event.json;
    switch (event.type) {
      case 'share_play.updated' when data['id'] == session.id:
        final SharePlay sharePlay;
        try {
          sharePlay = SharePlay.fromJson(data);
        } on Object {
          return false;
        }
        final before = watchSlot;
        watching = sharePlay;
        final now = watchSlot;
        if (now != before) app.show(now == null ? T.text('sharePlayYouWatch') : T.format('sharePlayYouPlay', [now]));
        _followSlot();
        app.refresh();
        return true;
      case 'share_play.signal' when data['sharePlayId'] == session.id:
        final signal = ShareSignal.fromJson(data);
        if (signal != null) unawaited(session.receive(signal));
        return true;
      case 'share_play.ended' when data['sharePlayId'] == session.id:
        final host = watching?.host?.displayName ?? '';
        unawaited(leaveWatching(tellServer: false));
        app.show(T.format(data['reason'] == 'removed' ? 'sharePlayTookYouOut' : 'sharePlayHostStopped', [host]));
        return true;
    }
    return false;
  }

  /// While watching the controller is the game's: only PS (Esc and ○ too while only watching,
  /// or without a controller) leaves.
  void watchCommand(Command command) {
    final noPad = app.controllers.playerOne == null && padOverride == null;
    if (command == Command.home || (command == Command.back && (watchSlot == null || noPad))) {
      unawaited(leaveWatching());
    }
  }

  /// The Friends panel's rows: invites to watch (and to decline), and friends sharing who let
  /// friends walk in.
  List<PanelRow> watchRows() {
    if (!(app.together.family.rules?.sharePlay ?? true)) return const [];
    final rows = <PanelRow>[];
    for (final invite in invites) {
      final from = invite.from?.displayName ?? '';
      rows
        ..add(
          PanelRow(
            id: 'share-watch-${invite.sharePlayId}',
            title: T.format('sharePlayWatchFriend', [from, _gameName(invite.titleId, invite.title)]),
            detail: T.text('sharePlayWatchDetail'),
            person: invite.from == null
                ? null
                : PanelPerson(name: from, avatar: invite.from!.avatar, status: PersonStatus.playing),
            kind: ActionRow(() => unawaited(watch(invite.sharePlayId))),
          ),
        )
        ..add(
          PanelRow(
            id: 'share-decline-${invite.sharePlayId}',
            title: T.format('sharePlayDecline', [from]),
            kind: ActionRow(() => decline(invite), destructive: true),
          ),
        );
    }
    for (final friend in app.together.hub.friends.friends) {
      final shared = friend.presence.share;
      if (shared == null || !shared.open || invites.any((invite) => invite.sharePlayId == shared.sharePlayId)) continue;
      final name = friend.person.displayName;
      rows.add(
        PanelRow(
          id: 'share-friend-${shared.sharePlayId}',
          title: T.format('sharePlayWatchFriend', [name, _gameName(shared.titleId, shared.title)]),
          detail: T.format('sharePlayWatching', [shared.viewers, shared.maxViewers]),
          person: PanelPerson(name: name, avatar: friend.person.avatar, status: PersonStatus.playing),
          kind: ActionRow(() => unawaited(watch(shared.sharePlayId))),
        ),
      );
    }
    return rows;
  }

  void dispose() {
    if (active) unawaited(stop());
    if (isWatching) unawaited(leaveWatching());
  }
}
