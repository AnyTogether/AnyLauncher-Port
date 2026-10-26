import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../together/account.dart';
import '../together/socket.dart';
import 'online_bridge_server.dart';
import 'online_identity.dart';
import 'online_peer.dart';
import 'online_player_sessions.dart';
import 'online_stream_relay.dart';
import 'online_user_profile.dart';
import 'online_web_router.dart';
import 'online_wire.dart';

typedef OnlineTransportFactory = OnlinePeerTransport Function(OnlinePeerContext context);

/// Online play for one game start: the bridge the game connects to, the web router onto
/// AnyTogether, and the transport that carries game packets to the other players. The account the
/// game sees is the signed-in AnyTogether user; the virtual address is the user's in the current
/// AnyTogether game session.
class OnlinePlay {
  OnlinePlay({
    required this.call,
    required this.user,
    required OnlineGame game,
    String country = '',
    String language = '',
    bool platformGroups = true,
    this.observationLog,
    OnlineSignal? signal,
    OnlineTransportFactory? transport,
  }) : baseAccount = user == null ? WireAccount.signedOut : account(user, country: country, language: language) {
    final context = OnlinePeerContext(
      deliver: (datagram) => bridge.deliver(datagram),
      call: call,
      signal: signal ?? (_, _, _, _, _) {},
      deliverStream: (peer, message) => streams.fromPeer(peer, message),
      peerGone: (peer) => streams.peerGone(peer),
    );
    streams = OnlineStreamRelay(
      toEngine: (frame) => bridge.deliverStream(frame),
      toPeer: (peer, message) => this.transport.sendStream(peer, message),
    );
    this.transport = transport?.call(context) ?? OnlineNoTransport();
    final me = user;
    router = OnlineWebRouter(
      call: call,
      game: game,
      profile: me == null ? null : OnlineUserProfile(call: call, me: me, language: baseAccount.language),
      playerSessions: me == null
          ? null
          : OnlinePlayerSessions(
              account: baseAccount.accountId,
              onlineId: baseAccount.onlineId,
              push: (event) => bridge.push(event),
            ),
      platformGroups: platformGroups,
      sessionChanged: (view) {
        sessionChanged(view);
        unawaited(follow(view?.id));
      },
    );
    bridge = OnlineBridgeServer(
      account: baseAccount,
      handlers: OnlineBridgeHandlers(
        web: router.handle,
        datagram: (datagram) => this.transport.send(datagram),
        stream: (frame) => streams.fromEngine(frame),
        observation: _keep,
        engine: (hello) {
          // A game that connects (again) or goes starts with no streams.
          streams.engineGone();
          if (hello != null) router.setEngineBuild(hello.build);
        },
      ),
    );
  }

  final OnlineCall call;
  final TogetherUser? user;
  final WireAccount baseAccount;

  /// Where the engine writes its observation log (ANYPS5_ONLINE_LOG), when one was asked for.
  final String? observationLog;
  late final OnlineBridgeServer bridge;
  late final OnlineWebRouter router;
  late final OnlinePeerTransport transport;

  /// The game's streams between the bridge and the transport.
  late final OnlineStreamRelay streams;
  OnlineSessionView? _session;
  String? _following;
  final _observations = <String>[];

  /// The observation lines kept in memory.
  static const keptLines = 2000;

  /// Starts listening for the game; the result is what the game is started with.
  Future<Map<String, String>> start() async {
    await bridge.start();
    return {...bridge.environment, 'ANYPS5_ONLINE_LOG': ?observationLog};
  }

  Future<void> stop() async {
    transport.stop();
    await bridge.stop();
  }

  OnlineSessionView? get currentSession => _session;

  /// The observation lines the game sent, newest last (at most [keptLines]).
  List<String> get observed => List.unmodifiable(_observations);

  /// Plays in AnyTogether game session [sessionId] (null: in none): publishes this launcher as a
  /// member, so the others' signals reach it, and takes the session with every player's device.
  Future<void> follow(String? sessionId) async {
    _following = sessionId;
    if (sessionId == null || user == null) return sessionChanged(null);
    Map<String, dynamic>? data;
    try {
      data = await call('PUT', 'game-sessions/$sessionId/members/me', {
        'properties': {'online': 1},
      });
    } on Object {
      try {
        data = await call('GET', 'game-sessions/$sessionId');
      } on Object {
        data = null;
      }
    }
    if (_following != sessionId || data == null) return;
    final view = OnlineSessionView.fromJson(data);
    if (view == null) return;
    sessionChanged(view.ended ? null : view);
  }

  /// The session changed on AnyTogether (someone joined, left or published): takes it again.
  Future<void> refresh() async {
    final sessionId = _following;
    if (sessionId == null) return;
    try {
      final view = OnlineSessionView.fromJson(await call('GET', 'game-sessions/$sessionId'));
      if (view == null || _following != sessionId) return;
      sessionChanged(view.ended ? null : view);
    } on Object {
      // The next change tries again.
    }
  }

  /// A signal from another player's launcher in the session followed now.
  void receive(OnlinePeerSignal signal, String sessionId) {
    if (_following != sessionId) return;
    transport.receive(signal);
  }

  void sessionChanged(OnlineSessionView? view) {
    _session = view;
    final addresses = view?.addresses ?? const <String, int>{};
    final me = user?.id;
    final own = me == null ? 0 : addresses[me] ?? 0;
    bridge.setAccount(baseAccount.copyWith(address: baseAccount.signedIn ? own : 0));
    if (view == null || me == null || own == 0) return transport.update(null);
    transport.update(OnlinePeerSession(id: view.id, me: me, addresses: addresses, devices: view.devices));
  }

  void _keep(String line) {
    _observations.add(line);
    if (_observations.length > keptLines) _observations.removeRange(0, _observations.length - keptLines);
  }

  /// The account the game sees for an AnyTogether user ([OnlineIdentity]), with the computer's
  /// country and language.
  static WireAccount account(TogetherUser user, {String country = '', String language = ''}) => WireAccount(
    signedIn: true,
    accountId: OnlineIdentity.accountId(user.id),
    onlineId: OnlineIdentity.onlineId(user.handle),
    country: country.length == 2 ? country.toLowerCase() : '',
    language: language,
  );

  /// "tr_TR.UTF-8" → (country: tr, language: tr); "en-US" → (us, en).
  static ({String country, String language}) locale(String name) {
    final bare = name.split('.').first.split('@').first;
    final parts = bare.split(RegExp('[-_]'));
    final language = parts.first.toLowerCase();
    final country = parts.length > 1 && parts.last.length == 2 ? parts.last.toLowerCase() : '';
    return (country: country, language: RegExp(r'^[a-z]{2,3}$').hasMatch(language) ? language : '');
  }
}

/// The one online session of the running game, switched on with Settings › AnyTogether › Online
/// play (experimental). Off, nothing changes for the game.
class OnlineHost {
  OnlineHost({
    required this.logFolder,
    required this.call,
    required this.user,
    required this.signal,
    this.transport,
    this.locale = '',
  });

  /// Where each title's observation log goes (Windows: %LOCALAPPDATA%\AnyPS5\Logs\Online, Linux:
  /// ~/.local/state/AnyPS5/online).
  final String logFolder;
  final OnlineCall call;
  final TogetherUser? Function() user;
  final OnlineSignal signal;

  /// How packets reach the other players (the launcher's WebRTC mesh); none: they are dropped.
  final OnlineTransportFactory? transport;

  /// The computer's locale name (Platform.localeName) for the account's country and language.
  final String locale;

  OnlinePlay? _current;
  String? _session;

  OnlinePlay? get running => _current;

  /// Off answers every platform web API group "not offered" (a clean observation run).
  bool platformGroups = true;

  /// What a game is started with for online play (empty when it fails to start).
  Future<Map<String, String>> environment({
    required String titleId,
    required String gameVersion,
    required String engineBuild,
  }) async {
    await stop();
    final place = OnlinePlay.locale(locale);
    final play = OnlinePlay(
      call: call,
      user: user(),
      game: OnlineGame(
        titleId: titleId,
        gameVersion: gameVersion.isEmpty ? '0' : gameVersion,
        engineBuild: engineBuild,
      ),
      country: place.country,
      language: place.language,
      platformGroups: platformGroups,
      observationLog: observationLog(titleId, logFolder),
      signal: signal,
      transport: transport,
    );
    _current = play;
    try {
      final environment = await play.start();
      final session = _session;
      if (session != null) unawaited(play.follow(session));
      return environment;
    } on Object {
      if (identical(_current, play)) _current = null;
      await play.stop().catchError((Object _) {});
      return const {};
    }
  }

  /// The AnyTogether game session the launcher keeps for the running game (null: none).
  void follow(String? sessionId) {
    if (_session == sessionId) return;
    _session = sessionId;
    final play = _current;
    if (play != null) unawaited(play.follow(sessionId));
  }

  /// A socket event about game sessions: news of the followed one, or a signal in it.
  void handle(TogetherEvent event) {
    final play = _current;
    if (play == null) return;
    switch (event.type) {
      case 'game_session.updated':
        unawaited(play.refresh());
      case 'game_session.signal':
        final sessionId = event.json['sessionId'];
        final signal = OnlinePeerSignal.fromEvent(event.json);
        if (sessionId is String && signal != null) play.receive(signal, sessionId);
    }
  }

  /// The game ended.
  Future<void> stop() async {
    final play = _current;
    _current = null;
    await play?.stop();
  }

  /// Where a title's observation log goes: one file per title, the last one kept as `.1` once it
  /// passes 20 MB. A title ID never leaves the folder.
  static String observationLog(String titleId, String folder) {
    final file = logFile(titleId, folder);
    try {
      Directory(folder).createSync(recursive: true);
      final existing = File(file);
      if (existing.existsSync() && existing.lengthSync() > 20 * 1024 * 1024) {
        final old = File('$file.1');
        if (old.existsSync()) old.deleteSync();
        existing.renameSync(old.path);
      }
    } on FileSystemException {
      // The engine says so when it cannot write it.
    }
    return file;
  }

  /// A title's observation log in [folder] (`<TitleID>.jsonl`), as it is now.
  static String logFile(String titleId, String folder) {
    final safe = titleId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return p.join(folder, '${safe.isEmpty ? 'game' : safe}.jsonl');
  }

  /// The last [count] lines of [file] (empty when there is none), read from its end only.
  static List<String> lastLines(String file, int count, {int maxBytes = 256 * 1024}) {
    try {
      final handle = File(file).openSync();
      try {
        final length = handle.lengthSync();
        final start = length > maxBytes ? length - maxBytes : 0;
        handle.setPositionSync(start);
        final text = utf8.decode(handle.readSync(length - start), allowMalformed: true);
        final lines = const LineSplitter().convert(text).where((line) => line.trim().isNotEmpty).toList();
        // A cut first line is not shown.
        if (start > 0 && lines.isNotEmpty) lines.removeAt(0);
        return lines.length > count ? lines.sublist(lines.length - count) : lines;
      } finally {
        handle.closeSync();
      }
    } on FileSystemException {
      return const [];
    }
  }
}
