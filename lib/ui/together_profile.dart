part of 'together_model.dart';

/// Profiles (the user's own and friends') with games, play time and trophies; and playing with
/// friends: while a game runs the launcher opens an AnyTogether game session for it (when the
/// user lets friends join), and a friend's Join starts the same game here when the game version
/// and the engine build match.
extension TogetherProfiles on TogetherModel {
  /// How many can play in a session the launcher opens; the game itself may take fewer.
  static const sessionCapacity = 4;

  Future<void> openMyProfile() {
    final me = user;
    if (me == null) return Future.value();
    return openProfile(
      me.handle,
      card: Person(id: me.id, handle: me.handle, displayName: me.displayName, avatar: me.avatar),
    );
  }

  /// Someone's profile, read in full; the layer shows it as it comes.
  Future<void> openProfile(String handle, {Person? card}) async {
    profileReturn = app.overlay == Layer.profile ? profileReturn : app.overlay;
    profile = null;
    profileCard = card;
    profileFailed = false;
    app.open(Layer.profile);
    profileIndex = 0;
    try {
      final page = await hub.profiles.page(handle, card: card);
      if (app.overlay != Layer.profile) return;
      profile = page;
    } on Object {
      profileFailed = true;
    }
    app.refresh();
  }

  void closeProfile() {
    final back = profileReturn;
    profile = null;
    if (back == null) {
      app.closeOverlay();
    } else {
      app.open(back, cue: Cue.back);
    }
  }

  /// Someone else's profile, read: their trophies can be compared with the user's.
  bool get canCompare {
    final page = profile;
    return page != null && !page.profile.isMe;
  }

  /// Where the games start among the items the keys move through: after Compare trophies.
  int get profileGamesFrom => canCompare ? 1 : 0;

  /// Items the keys move through: Compare trophies (on someone else's profile), the games, then
  /// the trophies.
  int get profileItems =>
      profileGamesFrom + (profile?.library.value?.length ?? 0) + (profile?.trophies.value?.length ?? 0);

  void profileCommand(Command command) {
    switch (command) {
      case Command.up || Command.down:
        final next = (profileIndex + (command == Command.down ? 1 : -1)).clamp(
          0,
          profileItems == 0 ? 0 : profileItems - 1,
        );
        if (next != profileIndex) app.sounds.play(Cue.move);
        profileIndex = next;
        app.refresh();
      case Command.select when canCompare && profileIndex == 0:
        compareProfile();
      case Command.back || Command.options:
        closeProfile();
      default:
        break;
    }
  }

  /// Compare trophies, from the profile shown.
  void compareProfile() {
    final page = profile;
    if (page == null || page.profile.isMe) return;
    final shown = page.profile;
    unawaited(
      openCompare(Person(id: shown.userId, handle: shown.handle, displayName: shown.displayName, avatar: shown.avatar)),
    );
  }

  // Comparing trophies.

  /// The games [person] and the user have trophies in, both-play first; the layer shows them as
  /// they come.
  Future<void> openCompare(Person person) async {
    compareReturn = app.overlay == Layer.compare ? compareReturn : app.overlay;
    compareWith = person;
    compareGames = null;
    compareIndex = 0;
    compareTitleId = null;
    comparison = null;
    comparisonIndex = 0;
    app.open(Layer.compare);
    final games = await hub.profiles.compareGames(person.handle);
    if (app.overlay != Layer.compare || compareWith?.id != person.id) return;
    compareGames = games;
    app.refresh();
  }

  /// One game's trophies side by side.
  Future<void> openComparedGame(ComparedGame game) async {
    final person = compareWith;
    if (person == null) return;
    app.sounds.play(Cue.select);
    compareTitleId = game.titleId;
    comparison = null;
    comparisonIndex = 0;
    app.refresh();
    final view = await hub.profiles.compareGame(person.handle, game.titleId);
    if (app.overlay != Layer.compare || compareTitleId != game.titleId) return;
    comparison = view;
    app.refresh();
  }

  void closeCompare() {
    if (compareTitleId != null) {
      compareTitleId = null;
      comparison = null;
      app.sounds.play(Cue.back);
      app.refresh();
      return;
    }
    final back = compareReturn;
    compareWith = null;
    compareGames = null;
    if (back == null) {
      app.closeOverlay();
    } else {
      // Back on the profile it came from, as it was.
      final index = profileIndex;
      app.open(back, cue: Cue.back);
      profileIndex = index;
      if (back == Layer.friendOptions) {
        app.panelRow = app.panelCategories().firstOrNull?.rows.indexWhere((row) => row.id == 'friend-compare') ?? 0;
      }
      app.refresh();
    }
  }

  void compareCommand(Command command) {
    final games = compareGames?.value ?? const <ComparedGame>[];
    final trophies = comparison?.value?.trophies ?? const <ComparedTrophy>[];
    final inGame = compareTitleId != null;
    switch (command) {
      case Command.up || Command.down:
        final count = inGame ? trophies.length : games.length;
        final current = inGame ? comparisonIndex : compareIndex;
        final next = (current + (command == Command.down ? 1 : -1)).clamp(0, count == 0 ? 0 : count - 1);
        if (next != current) app.sounds.play(Cue.move);
        if (inGame) {
          comparisonIndex = next;
        } else {
          compareIndex = next;
        }
        app.refresh();
      case Command.select when !inGame && compareIndex < games.length:
        unawaited(openComparedGame(games[compareIndex]));
      case Command.back || Command.options:
        closeCompare();
      default:
        break;
    }
  }

  /// 3 h 20 min, 4 h, 35 min.
  static String playTime(int seconds) {
    final minutes = seconds ~/ 60;
    final hours = minutes ~/ 60;
    if (hours == 0) return T.format('profileMinutes', [minutes]);
    if (minutes % 60 == 0) return T.format('profileHoursOnly', [hours]);
    return T.format('profileHoursMinutes', [hours, minutes % 60]);
  }

  static String rarity(String? label) => switch (label) {
    'common' => T.text('rarityCommon'),
    'uncommon' => T.text('rarityUncommon'),
    'rare' => T.text('rarityRare'),
    'very_rare' => T.text('rarityVeryRare'),
    'ultra_rare' => T.text('rarityUltraRare'),
    _ => '',
  };

  // Playing together.

  /// The engine a game was unlocked with: only the same build is relied on to talk to itself.
  String engineBuild(Game game) =>
      GameSession.cleanEngineBuild(app.records[game.id]?.toolkit ?? app.toolkit?.version ?? launcherVersion);

  String gameVersion(Game game) => GameSession.cleanGameVersion(game.version);

  /// A session while a game runs (when friends may join), none after; called whenever what runs
  /// changes.
  void followGameSession() {
    if (!signedIn) return;
    final running = app.running;
    final games = hub.games;
    if (running != null) {
      if (!app.preferences.friendsJoin || games.session != null || openingSession) return;
      final game = running.$1;
      if (!SyncTitle.valid(game.titleId)) return;
      openingSession = true;
      unawaited(() async {
        try {
          final session = await games.open(
            titleId: game.titleId,
            gameVersion: gameVersion(game),
            engineBuild: engineBuild(game),
            capacity: sessionCapacity,
          );
          // The game ended while the session was being opened.
          if (app.running?.$1.id != game.id && games.session?.id == session.id) await games.close();
        } on Object {
          // Played alone, then.
        } finally {
          openingSession = false;
        }
      }());
    } else if (games.session != null && app.starting == null) {
      // The game ended: the host's session ends with it (a Play Together game says the game
      // exited), a player leaves theirs.
      unawaited(games.close(gameExited: true));
    } else {
      // Left from a launcher that stopped without ending it.
      games.writeBridge();
    }
  }

  /// "Let friends join my game" turned on or off: a session open now follows.
  Future<void> setFriendsJoin(bool on) async {
    app.preferences.friendsJoin = on;
    app.savePreferences();
    final games = hub.games;
    if (games.session == null || !games.hosting) return followGameSession();
    try {
      await games.setJoinable(on);
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// A friend's game, from their presence or an invite: the same game here, checked first.
  Future<void> joinFriendGame(String sessionId, {required String titleId, required String host}) async {
    if (!signedIn) return;
    final game = app.games.where((game) => game.titleId == titleId).firstOrNull;
    if (game == null) return app.show(T.format('gameNotHere', [titleId]));
    final running = app.running;
    if (running != null) return app.show(T.format('gameCloseFirst', [running.$1.name]));
    if (app.stateOf(game) is! Installed) return app.show(T.format('gameUnlockFirst', [game.name]));
    final version = gameVersion(game);
    final engine = engineBuild(game);
    try {
      final session = await hub.games.get(sessionId);
      switch (session.mismatch(gameVersion: version, engineBuild: engine)) {
        case SessionMismatch.gameVersion:
          return app.show(T.format('gameVersionMismatch', [host, session.gameVersion, version]));
        case SessionMismatch.engineBuild:
          return app.show(
            T.format('gameEngineMismatch', [
              host,
              GameSession.release(session.engineBuild),
              GameSession.release(engine),
            ]),
          );
        case null:
          break;
      }
      await hub.games.join(sessionId, gameVersion: version, engineBuild: engine);
      app.show(T.format('gameJoined', [host, game.name]));
      if (app.overlay != null) app.closeOverlay();
      app.select(app.games.indexOf(game));
      unawaited(app.play(game));
    } on TogetherProblem catch (problem) {
      app.show(switch (problem.code) {
        'full' => T.text('gameSessionFull'),
        'version_mismatch' => problem.title,
        _ => message(problem),
      });
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> inviteToGame(Friend friend) async {
    try {
      await hub.games.invite([friend.person.id]);
      app.show(T.format('gameInvited', [friend.person.displayName]));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Friends panel rows: invites to answer, friends' games to join, and (while hosting) friends
  /// to invite.
  List<PanelRow> gameRows() {
    final games = hub.games;
    final session = games.session;
    final rows = <PanelRow>[
      ...togetherOfferRows(),
      for (final invite in games.invites) ...[
        PanelRow(
          id: 'game-accept-${invite.sessionId}',
          title: T.format('gameJoin', [invite.from?.displayName ?? '', gameName(invite.titleId)]),
          detail: T.text('gameInvitedDetail'),
          person: invite.from == null ? null : TogetherModel.card(invite.from!, status: PersonStatus.playing),
          kind: ActionRow(
            () => unawaited(
              joinFriendGame(invite.sessionId, titleId: invite.titleId, host: invite.from?.displayName ?? ''),
            ),
          ),
        ),
        PanelRow(
          id: 'game-decline-${invite.sessionId}',
          title: T.format('gameDecline', [invite.from?.displayName ?? '']),
          kind: ActionRow(
            () => unawaited(games.decline(invite.sessionId).catchError((Object _) {})),
            destructive: true,
          ),
        ),
      ],
      for (final friend in hub.friends.friends)
        if (friend.presence.game case final PresenceGame game
            when game.joinable &&
                game.sessionId != session?.id &&
                !games.invites.any((invite) => invite.sessionId == game.sessionId))
          PanelRow(
            id: 'game-join-${game.sessionId}',
            title: T.format('gameJoin', [friend.person.displayName, gameName(game.titleId)]),
            detail: T.format('gamePlayers', [game.players, game.capacity]),
            person: TogetherModel.card(friend.person, status: PersonStatus.playing),
            kind: ActionRow(
              () => unawaited(joinFriendGame(game.sessionId, titleId: game.titleId, host: friend.person.displayName)),
            ),
          ),
    ];
    if (session != null && games.hosting) {
      final inside = {for (final player in session.players) player.id};
      final invitable = hub.friends.friends.where(
        (friend) => friend.presence.online && !inside.contains(friend.person.id),
      );
      if (invitable.isNotEmpty) {
        rows.add(
          PanelRow(
            id: 'game-invite-title',
            title: T.format('gameInviteTitle', [gameName(session.titleId)]),
            kind: InfoRow(T.format('gamePlayers', [session.players.length, session.capacity])),
          ),
        );
        for (final friend in invitable) {
          rows.add(
            PanelRow(
              id: 'game-invite-${friend.person.id}',
              title: T.format('partyInvite', [friend.person.displayName]),
              detail: presenceText(friend.presence),
              person: TogetherModel.card(friend.person, status: TogetherModel.status(friend.presence)),
              kind: ActionRow(() => unawaited(inviteToGame(friend))),
            ),
          );
        }
      }
    }
    return rows;
  }
}

/// The title IDs AnyTogether takes.
abstract final class SyncTitle {
  static bool valid(String titleId) => TogetherSync.titleIdPattern.hasMatch(titleId);
}
