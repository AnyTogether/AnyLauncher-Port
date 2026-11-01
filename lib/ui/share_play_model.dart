import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/capture/video_encoders.dart';
import '../core/desktop/desktop.dart';
import '../core/remote/remote_server.dart';
import '../core/together/share_host.dart';
import '../core/together/share_play.dart';
import '../core/together/socket.dart';
import 'app_model.dart';
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

/// Hosting share play, as the Mac launcher does: while a game runs, friends watch it live in a
/// browser, on their phone or in their launcher, and a viewer the user lets play joins in as
/// player 2, 3 or 4. Picture and sound go from this computer straight to each viewer (WebRTC);
/// AnyTogether introduces them. In the quick menu while a game plays.
class SharePlayModel {
  SharePlayModel(this.app);

  final AppModel app;

  /// Tests: a stand-in for flutter_webrtc and for the server.
  ShareEngine Function()? engineOverride;
  SharePlayClient? clientOverride;

  SharePlayClient get _client => clientOverride ?? SharePlayClient(app.together.account);

  ShareHostSession? _session;
  SharePlay? hosting;
  bool starting = false;
  StreamSubscription<TogetherEvent>? _events;
  Timer? _renewal;

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
      _events = app.together.hub.socket.events.listen(_event);
      _renew(started.expiresAt);
      await _apply(started.sharePlay);
      app.show(T.format('sharePlayStarted', [game.name]));
      if (!engine.hasSound) app.addRecentLine('${DateTime.now().toIso8601String()} share play: no sound capture');
    } on Object catch (error) {
      await engine.stop();
      app.show('${T.text('sharePlayCouldNotStart')}: ${app.together.message(error)}');
    } finally {
      starting = false;
      app.refresh();
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

  void _event(TogetherEvent event) {
    final session = _session;
    if (session == null) return;
    final data = event.json;
    switch (event.type) {
      case 'share_play.updated':
        try {
          unawaited(_apply(SharePlay.fromJson(data)));
        } on Object {
          // Not a share play: nothing to follow.
        }
      case 'share_play.signal':
        final signal = ShareSignal.fromJson(data);
        if (signal != null) unawaited(session.receive(signal));
      case 'share_play.ended' when data['sharePlayId'] == session.id:
        // Ended from elsewhere (the website, another launcher): this one lets go too.
        unawaited(_end());
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
    await _events?.cancel();
    _events = null;
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
    final rows = <PanelRow>[
      PanelRow(
        id: 'share-on',
        title: T.format('sharePlaySharing', [sharing.title ?? playing?.$1.name ?? sharing.titleId]),
        kind: InfoRow(T.format('sharePlayWatching', [sharing.viewers.length, sharing.maxViewers])),
      ),
    ];
    for (final viewer in sharing.viewers) {
      final name = viewer.user.displayName;
      final link = links[viewer.user.id] == 'connected' ? null : T.text('sharePlayConnecting');
      if (viewer.slot case final pad?) {
        rows.add(
          PanelRow(
            id: 'share-stop-${viewer.user.id}',
            title: T.format('sharePlayStopPlaying', [name]),
            detail: link ?? T.format('sharePlayPlayer', [pad]),
            person: PanelPerson(name: name, avatar: viewer.user.avatar, status: PersonStatus.playing),
            kind: ActionRow(() => stopPlaying(viewer)),
          ),
        );
      } else {
        rows.add(
          PanelRow(
            id: 'share-play-${viewer.user.id}',
            title: T.format('sharePlayLetPlay', [name, ShareRoster.freePad(sharing.viewers) ?? 0]),
            detail: link ?? T.text('sharePlayOnlyWatches'),
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

  void dispose() {
    if (active) unawaited(stop());
  }
}
