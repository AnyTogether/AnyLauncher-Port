import 'dart:async';
import 'dart:io';

import '../core/audio/tones.dart';
import '../core/game_library.dart';
import '../core/gamepad/feel.dart' show HapticCue;
import '../core/host.dart';
import '../core/online/online_peer.dart';
import '../core/online/online_peer_mesh.dart';
import '../core/online/online_play.dart';
import '../core/profiles/profiles.dart' show ProfileMode;
import '../core/remote/remote_protocol.dart';
import '../core/together/account.dart';
import '../core/together/family.dart';
import '../core/together/friends.dart';
import '../core/together/hub.dart';
import '../core/together/levels.dart';
import '../core/together/people.dart';
import '../core/together/server.dart';
import '../core/together/socket.dart';
import '../core/together/game_sessions.dart';
import '../core/together/messages.dart';
import '../core/together/private_identity.dart';
import '../core/together/profiles.dart';
import '../core/together/parties.dart';
import '../core/together/play_together.dart';
import '../core/together/sync.dart';
import '../core/together/talk_key.dart';
import '../core/together/voice.dart';
import '../core/controls.dart';
import '../core/together/token_store.dart';
import '../core/trophies.dart';
import '../core/game_settings.dart';
import 'app_model.dart';
import 'family_gate.dart';
import 'online_webrtc.dart';
import 'strings.dart';
import 'voice_webrtc.dart';

part 'together_messages.dart';
part 'together_ask.dart';
part 'together_party.dart';
part 'together_play.dart';
part 'together_profile.dart';

/// The launcher's version, as AnyTogether hears it.
const launcherVersion = '0.1.11';

/// AnyTogether in the launcher: the account and how it signs in (an email code, a code approved
/// on the website, or the paired phone), the server it uses, and the rows the settings show for
/// it. The interface reads it through [AppModel].
class TogetherModel {
  TogetherModel(this.app) : environment = app.services.environment ?? Platform.environment {
    // The session of the profile playing; another profile's goes in when it plays.
    sessions = ProfileTokenStore(app.tokenStoreFor(app.sessionProfileId));
    account = TogetherAccount(
      base: app.services.togetherServer ?? TogetherServer.base(environment, app.preferences.togetherServer),
      store: sessions,
      clientName: clientName(app.system),
      pollEvery: app.services.togetherPollEvery,
    );
    hub = TogetherHub(
      account: account,
      voiceEngine: app.services.voiceEngine ?? WebRtcVoice.new,
      bridgeFile: GameSessions.defaultBridgeFile(app.paths.config),
    );
    hub.games.onInvite = (invite) {
      _noticeSound();
      app.vibrate(HapticCue.ring);
      app.show(T.format('gameInvitedYou', [invite.from?.displayName ?? '', gameName(invite.titleId)]));
    };
    hub.games.onEnded = (host) => app.show(
      T.format(hub.games.ended?.together == true ? 'togetherEnded' : 'sessionEnded', [host?.displayName ?? '']),
    );
    hub.games.onStarted = togetherStarted;
    hub.games.onAnyEnded = togetherEnded;
    hub.games.onPlayersChanged = () => unawaited(hub.parties.refresh().catchError((Object _) {}));
    app.onUnlocked = togetherUnlockDone;
    hub.parties.onRequest = (person, via) {
      _noticeSound();
      app.show(
        via == 'code' ? T.format('partyAsksCode', [person.displayName]) : T.format('partyAsks', [person.displayName]),
      );
    };
    hub.parties.onRequestAnswered = (accepted) {
      // A yes is an invite, which says so itself.
      if (!accepted) app.show(T.text('partyRequestDeclined'));
    };
    hub.addListener(app.refresh);
    // The friends-only names and pictures the friends list brought, for every card shown.
    identities = hub.friends.identities;
    hub.friends.onRequest = (person) {
      _noticeSound();
      app.show(T.format('friendsAsked', [person.displayName]));
    };
    hub.friends.onAccepted = (person) => app.show(T.format('friendsNowFriends', [person.displayName]));
    // A trophy level reached: the trophy's sound (heard over a game too) and the toast with the
    // badge.
    hub.self.onLevelUp = (level) {
      app.sounds.play(Cue.unlocked, overGame: true);
      app.show(T.format('levelUp', [level.level]), level: level);
    };
    sync = TogetherSync(
      account: account,
      file: app.outboxFile(app.sessionProfileId),
      deviceName: deviceName,
      platform: app.system.name,
      model: machineModel(app.system),
    );
    online = OnlineHost(
      logFolder: app.paths.onlineLogs,
      call: account.call,
      user: () => account.user,
      // Signals to the other players' launchers go out on the gateway socket.
      signal: (to, device, sessionId, kind, data) =>
          hub.socket.send(OnlinePeerSignal.frame(to: to, device: device, sessionId: sessionId, kind: kind, data: data)),
      transport: (context) =>
          OnlinePeerMesh(context: context, links: app.services.gameLinks?.call() ?? WebRtcGameLinks()),
      locale: Platform.localeName,
    );
    // Online play follows the game session this launcher keeps for the running game.
    hub.games.addListener(() => online.follow(hub.games.session?.id));
    _ready = hub.socket.events.listen(_event);
    hub.messages.onSendFailed = (error) => sendFailed(error);
    hub.voice
      ..pushToTalk = app.preferences.pushToTalk
      ..addListener(_voiceChanged);
    final reader = app.services.talkKeys != null ? app.services.talkKeys!() : KeyStateReader.system();
    if (reader != null) {
      talkWatch = TalkKeyWatch(reader: reader, onChange: hub.voice.talkKey, ignore: () => app.editingRow != null)
        ..usage = talkKey;
    }
    account.addListener(_accountChanged);
  }

  /// Play sessions and trophies on their way to the server.
  late final TogetherSync sync;

  /// The store the account keeps its session in: the profile playing's.
  late final ProfileTokenStore sessions;

  /// The friends' private names and pictures as the friends list said (the model's in use).
  static IdentityBook identities = IdentityBook();

  /// Someone as the launcher shows them: their friends-only name and picture when they let this
  /// user see them, the handle beside.
  static ShownIdentity shown(Person person) => ShownIdentity.of(person, identities);

  /// Online play for the running game (Settings › AnyTogether › Online play): the bridge the game
  /// connects to, the platform's web API answered from AnyTogether, the peer mesh.
  late final OnlineHost online;

  /// Family limits: the kept status, play time, age ratings, asking a parent.
  late final FamilyGate family = FamilyGate(this);
  late final StreamSubscription<TogetherEvent> _ready;
  Timer? _flush;

  final AppModel app;
  final Map<String, String> environment;
  late final TogetherAccount account;

  /// The live side: the gateway socket and the lists it keeps current.
  late final TogetherHub hub;

  /// The talk key read anywhere on the desktop; null where it is read only in the launcher.
  TalkKeyWatch? talkWatch;

  /// Waiting for the key to become the talk key.
  bool capturingTalkKey = false;

  int get talkKey => app.preferences.talkKey ?? TalkKeys.standard;

  /// Party: whether a party started now is open to friends.
  bool partyStartsOpen = false;

  /// Party: a join code being typed, what the code looked up opens, and the Discord link being
  /// typed (null while it is not).
  String joinCodeDraft = '';
  JoinPreview? codePreview;
  String? discordDraft;

  /// Messages: the conversation or friend chosen on the left, whether the keys are in the thread,
  /// which quick reply (or the field, the last) is focused there, and what is typed.
  int messagesIndex = 0;
  bool messagesInThread = false;
  int messageFocus = 0;
  String draft = '';

  /// Messages: the message the keys are on (counted from the newest; null while they are on
  /// the quick replies and the field), the menu open over the thread (a message's or a
  /// conversation's), and what the composer is doing: answering a message (its seq) or editing
  /// one of the user's.
  int? messageCursor;
  MessageMenu? messageMenu;
  int? replyingTo;
  ChatMessage? editingMessage;

  /// The profile shown: the page once read, the card it was opened with, whether reading failed,
  /// the row the keys are on, and the layer it goes back to.
  ProfilePage? profile;
  Person? profileCard;
  bool profileFailed = false;
  int profileIndex = 0;
  Layer? profileReturn;

  /// Comparing trophies: with whom, their games (once read), the game the keys are on; one
  /// game's trophies side by side once one is opened, and the trophy the keys are on; the layer
  /// it goes back to.
  Person? compareWith;
  Section<List<ComparedGame>>? compareGames;
  int compareIndex = 0;
  String? compareTitleId;
  Section<TrophyComparison>? comparison;
  int comparisonIndex = 0;
  Layer? compareReturn;

  /// A game session being opened for the game that just started.
  bool openingSession = false;

  /// Play Together: party members' games to join, a join waiting for its game to unlock, and the
  /// session the next game starts in with online play on whatever the setting.
  List<PlayTogetherOffer> togetherOffers = const [];
  (String, PlayTogetherOffer)? togetherAfterUnlock;
  String? togetherSession;

  /// Play Together games the user chose to join with a game version that does not fit (Try
  /// anyway), and games the server refused for the version though the check here let them by.
  Set<String> togetherTryAnyway = {};
  Set<String> togetherVersionRefused = {};

  /// The row whose social step is asking first (together_ask.dart): it shows the question instead.
  String? askingRow;

  /// Update Required was shown for AnyTogether's client_too_old (once a run).
  bool _updateRequiredShown = false;

  /// A handle typed in the friends panel, and the friend whose options are open.
  String friendHandle = '';
  Friend? chosen;

  /// What is typed in the sign-in rows, until it is sent.
  String email = '';
  String code = '';
  String serverDraft = '';
  String? _signedIn;

  TogetherUser? get user => account.user;
  bool get signedIn => account.user != null;

  /// launcher-windows/0.1.0 (Windows 10.0.22631), as the server's AnyTogether-Client header wants.
  static String clientName(HostSystem system) {
    final os = Platform.operatingSystemVersion.replaceAll(RegExp(r'[()"]'), '').trim();
    final short = os.length > 48 ? os.substring(0, 48) : os;
    return 'launcher-${system.name}/$launcherVersion (${system == HostSystem.windows ? 'Windows' : 'Linux'} $short)';
  }

  /// This computer's name as the server and the phone show it.
  String get deviceName {
    final name = app.services.computerName ?? Platform.localHostname;
    final trimmed = name.trim().isEmpty ? (app.system == HostSystem.windows ? 'Windows PC' : 'Linux PC') : name.trim();
    return trimmed.length > 60 ? trimmed.substring(0, 60) : trimmed;
  }

  /// The session from the last run, then whatever follows from being signed in. A session kept
  /// from before profiles makes the profile just migrated online; an offline profile, or the
  /// picker at start, leaves the session where it is.
  Future<void> start() async {
    family.load();
    if (app.profiles.migrated) {
      final saved = await sessions.load();
      if (saved != null) app.profiles.adoptLegacySession(saved.user);
    }
    final profile = app.profiles.book.currentProfile;
    if (!app.profileFlow.atLaunch && (profile == null || profile.mode == ProfileMode.online)) await account.restore();
    _accountChanged();
  }

  void _accountChanged() {
    // AnyTogether retired this version: Update Required, once.
    if (account.tooOld case final ClientTooOld old when !_updateRequiredShown) {
      _updateRequiredShown = true;
      app.showUpdateRequired(old);
    }
    final id = account.user?.id;
    if (id != _signedIn) {
      _signedIn = id;
      signedInChanged();
    }
    app.refresh();
  }

  /// Signed in or out: what depends on it starts or stops.
  void signedInChanged() {
    app.remote?.togetherServer = account.base.toString();
    if (!signedIn) {
      friendHandle = '';
      chosen = null;
      draft = '';
      joinCodeDraft = '';
      codePreview = null;
      discordDraft = null;
      messagesIndex = 0;
      messagesInThread = false;
      messageCursor = null;
      messageMenu = null;
      replyingTo = null;
      editingMessage = null;
      profile = null;
      compareWith = null;
      compareGames = null;
      comparison = null;
      compareTitleId = null;
      if (const {Layer.friendOptions, Layer.messages, Layer.profile, Layer.compare}.contains(app.overlay)) {
        app.closeOverlay();
      }
    } else {
      // Every game's trophies go up once, the earned ones with their dates.
      for (final game in app.games) {
        final set = app.trophies[game.id];
        if (set != null) recordTrophies(game, set, flush: false);
      }
      flushSoon();
    }
    family.signedInChanged();
    _followGame();
  }

  // Play and trophies.

  /// The computer's model for the devices list: the firmware's product name.
  static String? machineModel(HostSystem system) {
    try {
      if (system == HostSystem.linux) {
        final name = File('/sys/devices/virtual/dmi/id/product_name').readAsStringSync().trim();
        return name.isEmpty ? null : name;
      }
      if (!Platform.isWindows) return null;
      final result = Process.runSync('reg', [
        'query',
        r'HKLM\HARDWARE\DESCRIPTION\System\BIOS',
        '/v',
        'SystemProductName',
      ]);
      final match = RegExp(r'SystemProductName\s+REG_SZ\s+(.+)').firstMatch(result.stdout as String);
      final name = match?.group(1)?.trim();
      return name == null || name.isEmpty ? null : (name.length > 120 ? name.substring(0, 120) : name);
    } on Object {
      return null;
    }
  }

  /// A game played for a while: the session goes to AnyTogether, or waits until it can.
  void recordPlay(Game game, DateTime start, DateTime end, {String exit = 'normal'}) {
    family.played(start, end, reported: signedIn && TogetherSync.titleIdPattern.hasMatch(game.titleId));
    if (!signedIn) return;
    sync.recordSession(
      titleId: game.titleId,
      gameName: game.name,
      startedAt: start,
      endedAt: end,
      exit: exit,
      ageLevels: game.ageLevels,
    );
    flushSoon();
  }

  /// The game's trophy set as read now: the earned ones not sent yet go to AnyTogether.
  void recordTrophies(Game game, TrophySet set, {bool flush = true}) {
    if (!signedIn || set.trophies.isEmpty) return;
    final tag = ConsoleLanguage.tag(T.language.consoleLanguage);
    sync.recordTrophies(
      SyncTrophySet(
        titleId: game.titleId,
        gameName: game.name,
        language: tag?.split('-').first.toLowerCase() ?? 'en',
        trophies: [
          for (final trophy in set.trophies)
            SyncTrophy(
              id: SyncTrophy.idFor(trophy.serviceLabel, trophy.number),
              grade: trophy.grade.name,
              hidden: trophy.hidden,
              name: trophy.name,
              detail: trophy.detail,
              earnedAt: trophy.unlocked,
            ),
        ],
      ),
    );
    if (flush) flushSoon();
  }

  /// Sends what waits, a moment later, so a burst of changes goes up together.
  void flushSoon() {
    _flush?.cancel();
    _flush = Timer(app.services.togetherPollEvery ?? const Duration(seconds: 2), () {
      if (signedIn) unawaited(sync.flush().catchError((Object _) {}));
    });
  }

  // Presence.

  /// A game started or stopped: friends see it.
  void gameChanged() => _followGame();

  void _followGame() {
    family.followGame();
    followGameSession();
    final running = app.running;
    final since = running == null ? null : DateTime.tryParse(app.preferences.lastPlayed[running.$1.id] ?? '');
    hub.socket.presence = running == null
        ? const PresenceOnline()
        : PresenceInGame(running.$1.titleId, since ?? DateTime.now());
  }

  bool get connected => hub.socket.status == SocketStatus.ready;

  /// Friends see this user as offline (their choice); the socket and heartbeats go on as ever.
  bool get appearingOffline => hub.self.appearOffline;

  /// The user as their own rows show them: a grey dot while appearing offline.
  PanelPerson get myCard => PanelPerson(
    name: user?.displayName ?? '',
    avatar: user?.avatar,
    status: appearingOffline ? PersonStatus.offline : null,
  );

  /// Online or appear offline: shown at once, turned back with a word when the server cannot.
  Future<void> setAppearOffline(bool on) async {
    if (on == appearingOffline) return;
    try {
      await hub.self.setAppearOffline(on);
    } on TogetherProblem catch (problem) {
      app.show(problem.status == 404 ? T.text('presenceNotYet') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  /// Read receipts on or off: shown at once, turned back with a word when the server cannot; the
  /// others' receipts change with it, so the conversations are read again.
  Future<void> setReadReceipts(bool on) async {
    if (on == hub.self.readReceipts) return;
    try {
      await hub.self.setReadReceipts(on);
      unawaited(hub.messages.refresh().catchError((Object _) {}));
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  // Signing in.

  Future<void> sendCode() async {
    final address = email.trim();
    if (!address.contains('@') || account.step is SignInBusy) return app.show(T.text('togetherEmailInvalid'));
    try {
      await account.startEmail(address);
      code = '';
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> verify() async {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) return;
    try {
      _welcome(await account.verifyEmail(digits));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void otherEmail() {
    code = '';
    account.cancel();
  }

  /// A code to type on the website, which opens in the browser with the code filled in: passkeys
  /// and every other way the website signs in work there.
  Future<void> signInWithWebsite() async {
    try {
      _welcome(await account.signInWithWebsite(deviceName, show: (page) => app.services.openUrl?.call(page)));
    } on TogetherCancelled {
      // Given up here.
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// The first connected phone's name, when one is connected.
  String? get phoneName => app.remote?.connectedDevices.firstOrNull;

  /// The paired phone signs this launcher in: the launcher starts a hand-off and asks the phone,
  /// signed in to AnyTogether, to approve it.
  Future<void> signInWithPhone() async {
    final phone = phoneName;
    final remote = app.remote;
    if (phone == null || remote == null) return;
    try {
      final handoff = await account.startHandoff(deviceName, phone);
      remote.publish(RemoteTogetherHandoff(id: handoff.id, deviceName: deviceName));
      _welcome(await account.waitForPhone(handoff));
    } on TogetherCancelled {
      // Given up, or the phone said no.
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void cancel() => account.cancel();

  /// Something a friend did while the launcher is behind another window: the sound of a notice
  /// (the Mac shows it over the other window with the same sound).
  void _noticeSound() {
    if (!app.active) app.sounds.play(Cue.unlocked);
  }

  void _welcome(TogetherUser user) {
    code = '';
    app.sounds.play(Cue.select);
    app.show(T.format('togetherWelcome', [user.displayName]));
    app.profileSignedIn(user);
  }

  Future<void> signOut() async {
    await account.signOut();
  }

  /// A phone's side of a hand-off: it asks to be signed in as us, or answers ours.
  void phoneMessage(RemoteMessage received, String deviceId) {
    switch (received) {
      case RemoteTogetherHandoff(:final id, :final deviceName):
        // Only phones paired with this launcher get here; signed in, it approves at once.
        if (!signedIn) {
          app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: false), deviceId);
          return;
        }
        unawaited(() async {
          try {
            await account.approveHandoff(id);
            app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: true), deviceId);
            app.show(T.format('togetherPhoneSignedIn', [deviceName]));
          } on Object catch (error) {
            app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: false), deviceId);
            app.show(message(error));
          }
        }());
      case RemoteTogetherHandoffAnswer(:final id, approved: false):
        final step = account.step;
        if (step is! SignInWaitingForPhone || step.handoff.id != id) return;
        account.cancel();
        app.show(T.text('togetherPhoneDeclined'));
      default:
        break;
    }
  }

  // Server.

  /// ANYTOGETHER_URL, when set, decides the server.
  Uri? get forcedServer => TogetherServer.forced(environment);

  /// Another server: a session belongs to one server, so this one is signed out first.
  Future<void> useServer(String text) async {
    if (forcedServer != null) return;
    if (family.serverLocked) return app.show(T.text('familyServerLocked'));
    final url = TogetherServer.address(text.trim().isEmpty ? account.base.toString() : text);
    if (url == null) return app.show(T.text('togetherServerInvalid'));
    if (url == account.base) return;
    account.cancel();
    if (signedIn) await account.signOut();
    account.base = url;
    app.preferences.togetherServer = url == TogetherServer.standard ? null : url.toString();
    serverDraft = '';
    app.remote?.togetherServer = url.toString();
    app.savePreferences();
    app.show(T.format('togetherServerNow', [url.host]));
  }

  // Friends.

  Future<void> askFriend() async {
    final handle = Friends.clean(friendHandle);
    if (handle.isEmpty) return;
    // A parent approves whom the child befriends: they are asked instead.
    if (family.friendsThroughParent) {
      friendHandle = '';
      return family.askToAddFriend(handle);
    }
    try {
      final now = await hub.friends.add(handle);
      friendHandle = '';
      app.show(T.format(now ? 'friendsNowFriends' : 'friendsRequestSent', [handle]));
    } on TogetherProblem catch (problem) {
      if (familyFeature(problem) == 'friend_requests' && family.restricted) {
        friendHandle = '';
        return family.askToAddFriend(handle);
      }
      app.show(problem.status == 404 ? T.format('friendsNoOne', [handle]) : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> answerFriend(Person person, {required bool accept}) async {
    try {
      await hub.friends.answer(person.id, accept: accept);
      if (accept) app.show(T.format('friendsNowFriends', [person.displayName]));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> removeFriend(Friend friend) async {
    try {
      await hub.friends.remove(friend.person.id);
      app.show(T.format('friendsRemoved', [friend.person.displayName]));
      if (app.overlay == Layer.friendOptions) app.open(Layer.friends);
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Opens the settings at the AnyTogether rows.
  void openSettings() {
    app.open(Layer.settings);
    final index = app.panelCategories().indexWhere((category) => category.id == 'together');
    if (index >= 0) app.selectCategory(index);
  }

  void openFriend(Friend friend) {
    chosen = friend;
    app.open(Layer.friendOptions);
  }

  /// A game's name in this library, else its title ID.
  String gameName(String titleId) =>
      app.games.where((game) => game.titleId == titleId).firstOrNull?.nameFor([T.language.code]) ?? titleId;

  /// "Playing Neon Alley · 25 min", "Online", "Offline", with the party they are in.
  String presenceText(Presence presence, {DateTime? now}) {
    if (!presence.online) return T.text('friendsOffline');
    final titleId = presence.titleId;
    var text = switch (presence.state) {
      PresenceState.inGame when titleId != null =>
        presence.since == null
            ? T.format('friendsPlaying', [gameName(titleId)])
            : T.format('friendsPlayingFor', [
                gameName(titleId),
                ((now ?? DateTime.now()).difference(presence.since!).inMinutes).clamp(1, 1 << 30),
              ]),
      PresenceState.away => T.text('friendsAway'),
      _ => T.text('friendsOnline'),
    };
    // Playing together with their party: "Playing Minecraft together (2/8)".
    final game = presence.game;
    if (game != null && game.together) {
      return T.format('togetherPresence', [gameName(game.titleId), game.players, game.capacity]);
    }
    if (presence.game?.joinable == true) text += ' · ${T.text('gameJoinable')}';
    final party = presence.party;
    if (party != null) text += ' · ${T.format('friendsInParty', [party.size, party.max])}';
    return text;
  }

  static PersonStatus status(Presence presence) => switch (presence.state) {
    PresenceState.inGame => PersonStatus.playing,
    PresenceState.online => PersonStatus.online,
    PresenceState.away => PersonStatus.away,
    PresenceState.offline => PersonStatus.offline,
  };

  /// A person's avatar on a row: their friends-only name and picture when there.
  static PanelPerson card(Person person, {PersonStatus? status, bool speaking = false}) {
    final identity = shown(person);
    return PanelPerson(name: identity.name, avatar: identity.avatar, status: status, speaking: speaking);
  }

  /// The friends panel: requests to answer, adding someone by handle, the friends by what they
  /// do, the requests waiting for an answer.
  List<PanelRow> friendRows() {
    final me = user;
    if (me == null) {
      return [
        PanelRow(id: 'friends-out', title: T.text('friendsSignIn'), kind: InfoRow(T.text('togetherIntroDetail'))),
        PanelRow(id: 'friends-signin', title: T.text('togetherSignIn'), kind: ActionRow(openSettings)),
      ];
    }
    final friends = hub.friends;
    return [
      PanelRow(
        id: 'friends-me',
        title: T.text('profileMine'),
        detail: appearingOffline
            ? '${T.text('presenceAppearing')} · ${T.text('profileMineDetail')}'
            : T.text('profileMineDetail'),
        person: myCard,
        level: hub.self.level,
        kind: ActionRow(() => unawaited(openMyProfile())),
      ),
      ...gameRows(),
      for (final person in friends.incoming) ...[
        PanelRow(
          id: 'accept-${person.id}',
          title: T.format('friendsAccept', [person.displayName]),
          detail: '@${person.handle} · ${T.text('friendsWantsToBe')}',
          person: card(person),
          kind: ActionRow(() => unawaited(answerFriend(person, accept: true))),
        ),
        PanelRow(
          id: 'decline-${person.id}',
          title: T.format('friendsDecline', [person.displayName]),
          kind: ActionRow(() => unawaited(answerFriend(person, accept: false)), destructive: true),
        ),
      ],
      PanelRow(
        id: 'friends-handle',
        title: T.text('friendsAddByHandle'),
        kind: TextRow(
          friendHandle,
          (text) => friendHandle = text,
          submit: () => unawaited(askFriend()),
          hint: '@handle',
        ),
      ),
      PanelRow(
        id: 'friends-ask',
        title: T.text(family.friendsThroughParent ? 'familyAskFriend' : 'friendsSendRequest'),
        kind: ActionRow(() => unawaited(askFriend())),
      ),
      if (friends.loaded && friends.friends.isEmpty)
        PanelRow(
          id: 'friends-none',
          title: T.text('friendsNone'),
          kind: InfoRow(T.format('friendsYourHandle', [me.handle])),
        ),
      for (final friend in friends.friends)
        PanelRow(
          id: 'friend-${friend.person.id}',
          // Their friends-only name when they set one, the handle (and public name) beside.
          title: shown(friend.person).name,
          detail: '${shown(friend.person).handleLine} · ${presenceText(friend.presence)}',
          person: card(friend.person, status: status(friend.presence)),
          level: friend.level,
          kind: ActionRow(() => openFriend(friend)),
        ),
      for (final person in friends.outgoing)
        PanelRow(
          id: 'waiting-${person.id}',
          title: person.displayName,
          detail: '@${person.handle} · ${T.text('friendsWaiting')}',
          person: card(person),
          kind: const InfoRow(''),
        ),
    ];
  }

  /// What can be done with the chosen friend.
  List<PanelRow> friendOptionRows() {
    final friend = chosen == null ? null : hub.friends.byId(chosen!.person.id) ?? chosen;
    if (friend == null) return const [];
    return [
      PanelRow(
        id: 'friend-card',
        title: friend.person.displayName,
        detail: '@${friend.person.handle} · ${presenceText(friend.presence)}',
        person: card(friend.person, status: status(friend.presence)),
        level: friend.level,
        kind: const InfoRow(''),
      ),
      PanelRow(
        id: 'friend-profile',
        title: T.text('profileTitle'),
        detail: T.text('profileMineDetail'),
        kind: ActionRow(() => unawaited(openProfile(friend.person.handle, card: friend.person))),
      ),
      PanelRow(
        id: 'friend-compare',
        title: T.text('compareTrophies'),
        detail: T.text('compareTrophiesDetail'),
        kind: ActionRow(() => unawaited(openCompare(friend.person))),
      ),
      if (friend.presence.game case final PresenceGame game when game.joinable)
        PanelRow(
          id: 'friend-game',
          title: T.format('gameJoin', [friend.person.displayName, gameName(game.titleId)]),
          detail: T.format('gamePlayers', [game.players, game.capacity]),
          kind: ActionRow(
            () => unawaited(joinFriendGame(game.sessionId, titleId: game.titleId, host: friend.person.displayName)),
          ),
        ),
      if (family.messagesAllowed)
        PanelRow(
          id: 'friend-message',
          title: T.text('friendsMessage'),
          kind: ActionRow(() => unawaited(messageFriend(friend.person))),
        ),
      if (hub.parties.party case final Party party when !party.has(friend.person.id) && !party.full)
        PanelRow(
          id: 'friend-party',
          title: T.format('partyInvite', [friend.person.displayName]),
          kind: ActionRow(() => unawaited(inviteToParty(friend.person))),
        ),
      ...askingFirst(
        PanelRow(
          id: 'friend-remove',
          title: T.text('friendsRemove'),
          kind: ActionRow(() => unawaited(removeFriend(friend)), destructive: true),
        ),
        T.format('askRemoveFriend', [friend.person.displayName]),
      ),
      PanelRow(id: 'friend-back', title: T.text('back'), kind: ActionRow(() => app.open(Layer.friends))),
    ];
  }

  // Rows.

  /// The sign-in screen's rows: the ways in, without the server's rows.
  List<PanelRow> signInRows() => [
    for (final row in settingsRows(signingIn: true))
      if (!row.id.startsWith('together-server') && row.id != 'together-intro') row,
  ];

  List<PanelRow> settingsRows({bool signingIn = false}) {
    final me = user;
    // An offline profile that had an account (it went offline, its session kept): going online
    // is the way in. One that never had one signs in here as ever, and is online then.
    final profile = app.currentProfile;
    if (!signingIn &&
        me == null &&
        profile?.mode == ProfileMode.offline &&
        profile?.account != null &&
        app.profileFlow.pendingId == null) {
      return [
        PanelRow(
          id: 'together-offline',
          title: T.text('profileOfflineTogether'),
          kind: InfoRow(T.text('profileOfflineTogetherDetail')),
        ),
        PanelRow(
          id: 'together-go-online',
          title: T.text('profileGoOnline'),
          detail: T.text('profileGoOnlineDetail'),
          kind: ActionRow(() => unawaited(app.toggleProfileMode())),
        ),
      ];
    }
    if (me != null) {
      return [
        PanelRow(
          id: 'together-user',
          title: '@${me.handle}',
          detail: appearingOffline ? '${me.displayName} · ${T.text('presenceAppearing')}' : me.displayName,
          person: myCard,
          level: hub.self.level,
          kind: const InfoRow(''),
        ),
        PanelRow(
          id: 'together-online',
          title: T.text('togetherOnline'),
          kind: InfoRow(connected ? T.text('togetherConnected') : T.text('togetherConnecting')),
        ),
        PanelRow(
          id: 'together-presence',
          title: T.text('presenceShowAs'),
          detail: T.text('presenceHint'),
          kind: ChoiceRow(
            [T.text('presenceOnline'), T.text('presenceAppearOffline')],
            appearingOffline ? 1 : 0,
            (index) => unawaited(setAppearOffline(index == 1)),
          ),
        ),
        PanelRow(
          id: 'together-receipts',
          title: T.text('readReceipts'),
          detail: T.text('readReceiptsHint'),
          kind: ToggleRow(hub.self.readReceipts, (value) => unawaited(setReadReceipts(value))),
        ),
        ?family.settingsRow(),
        PanelRow(
          id: 'together-profile',
          title: T.text('profileMine'),
          detail: T.text('profileMineDetail'),
          kind: ActionRow(() => unawaited(openMyProfile())),
        ),
        ...privateIdentityRows(),
        PanelRow(
          id: 'together-join',
          title: T.text('togetherFriendsJoin'),
          detail: T.text('togetherFriendsJoinDetail'),
          kind: ToggleRow(app.preferences.friendsJoin, (value) => unawaited(setFriendsJoin(value))),
        ),
        PanelRow(
          id: 'together-online-play',
          title: T.text('togetherOnlinePlay'),
          detail: T.format('togetherOnlinePlayDetail', [me.handle]),
          kind: ToggleRow(app.preferences.onlinePlay, setOnlinePlay),
        ),
        PanelRow(
          id: 'together-online-log',
          title: T.text('togetherOnlineLog'),
          detail: T.text('togetherOnlineLogDetail'),
          kind: ActionRow(openOnlineLog),
        ),
        PanelRow(
          id: 'together-signout',
          title: T.text('togetherSignOut'),
          kind: ActionRow(() => unawaited(signOut()), destructive: true),
        ),
        ..._serverRows(),
      ];
    }
    final rows = [
      ?family.settingsRow(),
      PanelRow(id: 'together-intro', title: T.text('togetherIntro'), kind: InfoRow(T.text('togetherIntroDetail'))),
    ];
    switch (account.step) {
      case SignInIdle() || SignInBusy():
        final phone = phoneName;
        rows.addAll([
          if (phone != null)
            PanelRow(
              id: 'together-phone',
              title: T.text('togetherWithPhone'),
              detail: T.format('togetherWithPhoneDetail', [phone]),
              kind: ActionRow(() => unawaited(signInWithPhone())),
            ),
          PanelRow(
            id: 'together-web',
            title: T.text('togetherWithWebsite'),
            detail: T.text('togetherWithWebsiteDetail'),
            kind: ActionRow(() => unawaited(signInWithWebsite())),
          ),
          PanelRow(
            id: 'together-email',
            title: T.text('togetherEmail'),
            kind: TextRow(email, (text) => email = text, submit: () => unawaited(sendCode()), hint: 'name@example.com'),
          ),
          PanelRow(
            id: 'together-send',
            title: T.text('togetherSendCode'),
            kind: ActionRow(() => unawaited(sendCode())),
          ),
          ..._serverRows(),
        ]);
      case SignInCodeSent(email: final address):
        rows.addAll([
          PanelRow(id: 'together-sent', title: T.format('togetherCodeSent', [address]), kind: const InfoRow('')),
          PanelRow(
            id: 'together-code',
            title: T.text('togetherCode'),
            kind: TextRow(
              code,
              (text) {
                code = text;
                if (text.replaceAll(RegExp(r'\D'), '').length == 6) unawaited(verify());
              },
              submit: () => unawaited(verify()),
              hint: '123456',
            ),
          ),
          PanelRow(id: 'together-verify', title: T.text('togetherSignIn'), kind: ActionRow(() => unawaited(verify()))),
          PanelRow(id: 'together-other', title: T.text('togetherOtherEmail'), kind: ActionRow(otherEmail)),
        ]);
      case SignInDeviceCode(:final userCode, :final page):
        rows.addAll([
          PanelRow(
            id: 'together-device',
            title: userCode,
            kind: InfoRow(T.format('togetherTypeCode', ['${page.scheme}://${page.authority}'])),
          ),
          PanelRow(
            id: 'together-open',
            title: T.text('togetherOpenWebsite'),
            kind: ActionRow(() => app.services.openUrl?.call(page)),
          ),
          PanelRow(id: 'together-cancel', title: T.text('cancel'), kind: ActionRow(cancel)),
        ]);
      case SignInWaitingForPhone(:final phone):
        rows.addAll([
          PanelRow(id: 'together-onphone', title: T.format('togetherOnPhone', [phone]), kind: const InfoRow('')),
          PanelRow(id: 'together-cancel', title: T.text('cancel'), kind: ActionRow(cancel)),
        ]);
    }
    return rows;
  }

  List<PanelRow> _serverRows() {
    if (family.serverLocked) {
      return [
        PanelRow(
          id: 'together-server',
          title: T.text('togetherServer'),
          detail: T.text('familyServerLocked'),
          kind: InfoRow(account.base.toString()),
        ),
      ];
    }
    final forced = forcedServer;
    if (forced != null) {
      return [
        PanelRow(
          id: 'together-server',
          title: T.text('togetherServer'),
          detail: T.text('togetherServerForced'),
          kind: InfoRow(forced.toString()),
        ),
      ];
    }
    return [
      PanelRow(
        id: 'together-server',
        title: T.text('togetherServer'),
        detail: T.text('togetherServerDetail'),
        kind: TextRow(
          serverDraft.isEmpty ? account.base.toString() : serverDraft,
          (text) => serverDraft = text,
          submit: () => unawaited(useServer(serverDraft)),
        ),
      ),
      PanelRow(
        id: 'together-server-use',
        title: T.text('togetherServerUse'),
        kind: ActionRow(() => unawaited(useServer(serverDraft))),
      ),
    ];
  }

  // Online play.

  /// Online play (experimental) on or off; a game started from now on gets it.
  void setOnlinePlay(bool on) {
    app.preferences.onlinePlay = on;
    app.savePreferences();
    app.refresh();
  }

  /// Shows the folder of the games' online logs (made first, so it opens even before a game
  /// wrote one).
  void openOnlineLog() {
    final folder = app.paths.onlineLogs;
    try {
      Directory(folder).createSync(recursive: true);
    } on FileSystemException {
      // The file manager says so.
    }
    app.services.openFolder?.call(folder);
  }

  /// What [game] is started with for online play: nothing while the setting is off.
  Future<Map<String, String>> onlineEnvironment(Game game) async {
    // A Play Together game has online play on for that start whatever the setting.
    if (!app.preferences.onlinePlay && togetherSession == null) return const {};
    online.platformGroups = app.preferences.onlinePlatformGroups;
    return online.environment(titleId: game.titleId, gameVersion: gameVersion(game), engineBuild: engineBuild(game));
  }

  /// The game ended: its online bridge closes.
  Future<void> onlineGameEnded() {
    togetherSession = null;
    return online.stop();
  }

  /// What to tell the user about a failed call.
  String message(Object error) {
    if (isFamilyRestriction(error)) {
      return FamilyGate.restrictedText(familyFeature(error), side: familySide(error));
    }
    if (error is TogetherProblem) {
      return switch (error.code) {
        'code_invalid' => T.text('togetherCodeWrong'),
        'code_expired' || 'expired_token' => T.text('togetherCodeExpired'),
        'code_locked' => T.text('togetherCodeLocked'),
        'rate_limited' => T.text('togetherTooMany'),
        'handle_taken' => T.text('togetherHandleTaken'),
        'handle_reserved' => T.text('togetherHandleReserved'),
        'links_not_allowed' => T.text('togetherNoLinks'),
        _ => error.title.isEmpty ? T.text('togetherUnreachable') : error.title,
      };
    }
    return T.text('togetherUnreachable');
  }

  /// Gateway events worth a word on screen, and the outbox's chance after a reconnect.
  void _event(TogetherEvent event) {
    // Online play follows the same game session: players joining, leaving, signalling.
    online.handle(event);
    final data = event.json;
    switch (event.type) {
      case 'live.ready':
        // Back online: whatever waited goes up.
        flushSoon();
      case 'family.updated':
        // A parent changed the limits or gave extra time.
        unawaited(family.refresh());
      case 'message.created':
        _messageArrived(data);
      case 'party.invite':
        final from = data['from'];
        _noticeSound();
        app.vibrate(HapticCue.ring);
        app.show(
          T.format('partyInvitedYou', [from is Map<String, dynamic> ? (from['displayName'] as String?) ?? '' : '']),
        );
      case 'party.member_joined' when data['partyId'] == hub.parties.party?.id:
        final member = data['member'];
        if (member is Map<String, dynamic> && member['userId'] != user?.id) {
          app.show(T.format('partyJoined', [(member['displayName'] as String?) ?? '']));
        }
      case 'party.member_left':
        if (data['userId'] == user?.id) {
          if (data['reason'] == 'kicked') app.show(T.text('partyKicked'));
        } else {
          final name = hub.parties.party?.members.where((person) => person.id == data['userId']).firstOrNull;
          if (name != null) app.show(T.format('partyLeft', [name.displayName]));
        }
      case 'party.ended' when data['partyId'] == hub.parties.party?.id:
        app.show(T.text('partyEnded'));
    }
  }

  void _voiceChanged() {
    final watch = talkWatch;
    if (watch == null) return;
    if (hub.voice.active) {
      watch.start();
    } else {
      watch.stop();
    }
  }

  // The friends-only name and picture.

  /// What is typed as the friends-only name, until it is saved (null: the one kept).
  static String? privateNameDraft;

  List<PanelRow> privateIdentityRows() {
    final self = hub.self;
    if (!self.loaded) return const [];
    final draft = privateNameDraft ?? self.privateName ?? '';
    return [
      PanelRow(id: 'private-title', title: T.text('privateTitle'), kind: InfoRow(T.text('privateDetail'))),
      PanelRow(
        id: 'private-name',
        title: T.text('privateName'),
        kind: TextRow(
          draft,
          (text) => privateNameDraft = text,
          submit: () => unawaited(savePrivateName()),
          hint: user?.displayName ?? '',
        ),
      ),
      PanelRow(
        id: 'private-name-save',
        title: T.text(draft.trim().isEmpty && self.privateName != null ? 'privateNameClear' : 'privateNameSave'),
        kind: ActionRow(() => unawaited(savePrivateName())),
      ),
      PanelRow(
        id: 'private-picture',
        title: T.text('privatePicture'),
        detail: T.text('privatePictureDetail'),
        person: self.privateAvatar == null
            ? null
            : PanelPerson(name: self.privateName ?? user?.displayName ?? '', avatar: self.privateAvatar),
        kind: ActionRow(() => unawaited(choosePrivatePicture())),
      ),
      if (self.privateAvatar != null)
        PanelRow(
          id: 'private-picture-remove',
          title: T.text('privatePictureRemove'),
          kind: ActionRow(() => unawaited(removePrivatePicture()), destructive: true),
        ),
    ];
  }

  Future<void> savePrivateName() async {
    final text = (privateNameDraft ?? hub.self.privateName ?? '').trim();
    try {
      await hub.self.setPrivateName(text);
      privateNameDraft = null;
      app.show(T.text(hub.self.privateName == null ? 'privateNameCleared' : 'privateNameSaved'));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// A PNG or JPEG chosen on this computer, as the friends-only picture (the public one stays).
  Future<void> choosePrivatePicture() async {
    final path = await app.services.pickImage?.call();
    if (path == null) return;
    try {
      final bytes = File(path).readAsBytesSync();
      if (bytes.length > 5 * 1024 * 1024) return app.show(T.text('privatePictureFailed'));
      await hub.self.uploadPrivateAvatar(bytes);
      app.show(T.text('privatePictureSaved'));
    } on FileSystemException {
      app.show(T.text('privatePictureFailed'));
    } on Object catch (error) {
      app.show('${T.text('privatePictureFailed')}: ${message(error)}');
    }
  }

  Future<void> removePrivatePicture() async {
    try {
      await hub.self.removePrivateAvatar();
      app.show(T.text('privatePictureRemoved'));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void dispose() {
    unawaited(online.stop());
    family.dispose();
    talkWatch?.stop();
    talkWatch?.reader.close();
    hub.voice.removeListener(_voiceChanged);
    _flush?.cancel();
    unawaited(_ready.cancel());
    account.removeListener(_accountChanged);
    hub.dispose();
    account.close();
  }
}
