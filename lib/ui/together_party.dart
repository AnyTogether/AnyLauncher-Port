part of 'together_model.dart';

/// Parties on AnyTogether: start one (invite only, or open to friends), invite friends, see who is
/// in it, accept an invite or walk into a friend's open party, leave; and its voice, with the
/// microphone, push-to-talk and the talk key.
extension TogetherParty on TogetherModel {
  int get partyBadge => hub.parties.invites.where((invite) => invite.partyId != hub.parties.party?.id).length;

  List<PanelRow> partyRows() {
    final me = user;
    if (me == null) {
      return [
        PanelRow(id: 'party-out', title: T.text('friendsSignIn'), kind: InfoRow(T.text('togetherIntroDetail'))),
        PanelRow(id: 'party-signin', title: T.text('togetherSignIn'), kind: ActionRow(openSettings)),
      ];
    }
    final parties = hub.parties;
    final party = parties.party;
    final rows = <PanelRow>[
      for (final invite in parties.invites)
        if (invite.partyId != party?.id) ...[
          PanelRow(
            id: 'party-accept-${invite.partyId}',
            title: T.format('partyJoinOf', [invite.from?.displayName ?? '?']),
            detail: invite.size == null ? null : T.format('partySize', [invite.size!, maxPartySize]),
            person: invite.from == null ? null : TogetherModel.card(invite.from!),
            kind: ActionRow(() => unawaited(joinParty(invite.partyId))),
          ),
          PanelRow(
            id: 'party-decline-${invite.partyId}',
            title: T.format('partyDecline', [invite.from?.displayName ?? '?']),
            kind: ActionRow(() => unawaited(declineParty(invite.partyId)), destructive: true),
          ),
        ],
    ];
    if (party == null) {
      rows.addAll([
        PanelRow(
          id: 'party-start',
          title: T.text('partyStart'),
          detail: T.text('partyStartDetail'),
          kind: ActionRow(() => unawaited(startParty())),
        ),
        PanelRow(
          id: 'party-open',
          title: T.text('partyOpen'),
          detail: T.text('partyOpenDetail'),
          kind: ToggleRow(partyStartsOpen, (value) {
            partyStartsOpen = value;
            app.refresh();
          }),
        ),
        // Friends whose party is open to them.
        for (final friend in hub.friends.friends)
          if (friend.presence.party case final PresenceParty open when open.open && open.size < open.max)
            PanelRow(
              id: 'party-walkin-${open.id}',
              title: T.format('partyJoinOf', [friend.person.displayName]),
              detail: T.format('partySize', [open.size, open.max]),
              person: TogetherModel.card(friend.person, status: TogetherModel.status(friend.presence)),
              kind: ActionRow(() => unawaited(joinParty(open.id))),
            ),
      ]);
      return rows;
    }
    final voice = hub.voice;
    final leader = party.leads(me.id);
    rows.addAll([
      ...voiceRows(party),
      PanelRow(
        id: 'party-members',
        title: T.format('partyMembers', [party.members.length, maxPartySize]),
        kind: const InfoRow(''),
      ),
      for (final member in party.members)
        PanelRow(
          id: 'party-member-${member.id}',
          title: member.id == me.id ? '${member.displayName} (${T.text('profileYou')})' : member.displayName,
          detail: [
            '@${member.handle}',
            if (party.leads(member.id)) T.text('partyLeader'),
            if (party.inCall.contains(member.id)) T.text('partyInVoice'),
            if (party.muted.contains(member.id)) T.text('voiceMuted'),
          ].join(' · '),
          person: TogetherModel.card(
            member,
            status: party.inCall.contains(member.id) ? PersonStatus.online : null,
            speaking: member.id == me.id ? voice.speaking : voice.speakingOf(member.id),
          ),
          kind: const InfoRow(''),
        ),
      if (leader)
        for (final member in party.members)
          if (member.id != me.id)
            PanelRow(
              id: 'party-kick-${member.id}',
              title: T.format('partyKick', [member.displayName]),
              kind: ActionRow(() => unawaited(kick(member)), destructive: true),
            ),
      if (leader)
        PanelRow(
          id: 'party-privacy',
          title: T.text('partyOpen'),
          detail: T.text('partyOpenDetail'),
          kind: ToggleRow(party.open, (value) => unawaited(setPartyOpen(value))),
        ),
    ]);
    final invitable = hub.friends.friends.where((friend) => !party.has(friend.person.id)).toList();
    final invited = {for (final person in party.invited) person.id};
    if (invitable.isNotEmpty && !party.full) {
      rows.add(PanelRow(id: 'party-invite-title', title: T.text('partyInviteFriends'), kind: const InfoRow('')));
      for (final friend in invitable) {
        final status = TogetherModel.status(friend.presence);
        rows.add(
          invited.contains(friend.person.id)
              ? PanelRow(
                  id: 'party-invited-${friend.person.id}',
                  title: friend.person.displayName,
                  detail: T.text('partyInvited'),
                  person: TogetherModel.card(friend.person, status: status),
                  kind: const InfoRow(''),
                )
              : PanelRow(
                  id: 'party-invite-${friend.person.id}',
                  title: T.format('partyInvite', [friend.person.displayName]),
                  detail: presenceText(friend.presence),
                  person: TogetherModel.card(friend.person, status: status),
                  kind: ActionRow(() => unawaited(inviteToParty(friend.person))),
                ),
        );
      }
    }
    rows.add(
      PanelRow(
        id: 'party-leave',
        title: T.text('partyLeave'),
        kind: ActionRow(() => unawaited(leaveParty()), destructive: true),
      ),
    );
    return rows;
  }

  /// The party's voice: joining, the microphone, push-to-talk and its key, leaving.
  List<PanelRow> voiceRows(Party party) {
    final voice = hub.voice;
    final key = talkKeyName;
    if (!voice.active) {
      final others = party.inCall.where((id) => id != user?.id).length;
      return [
        PanelRow(
          id: 'voice-join',
          title: T.text('voiceJoin'),
          detail: others > 0 ? T.format('voiceInCall', [others]) : T.text('voiceJoinDetail'),
          kind: ActionRow(() => unawaited(joinVoice())),
        ),
      ];
    }
    return [
      if (!voice.pushToTalk)
        PanelRow(
          id: 'voice-mic',
          title: T.text('voiceMic'),
          detail: T.format('voicePushToTalkOff', [key]),
          kind: ToggleRow(!voice.muted, (value) => voice.setMuted(!value)),
        ),
      PanelRow(
        id: 'voice-ptt',
        title: T.text('voicePushToTalk'),
        detail: voice.pushToTalk ? T.format('voicePushToTalkOn', [key]) : null,
        kind: ToggleRow(voice.pushToTalk, setPushToTalk),
      ),
      PanelRow(
        id: 'voice-key',
        title: T.text('voiceTalkKey'),
        detail: talkWatch == null ? T.text('voiceTalkKeyHere') : T.text('voiceTalkKeyDetail'),
        kind: KeysRow(['KEY:$key'], capturing: capturingTalkKey, capture: captureTalkKey),
      ),
      PanelRow(
        id: 'voice-leave',
        title: T.text('voiceLeave'),
        kind: ActionRow(() => unawaited(hub.voice.leave()), destructive: true),
      ),
    ];
  }

  String get talkKeyName => Controls.keyName(talkKey) ?? '?';

  Future<void> _partyCall(Future<void> Function() call) async {
    try {
      await call();
    } on TogetherProblem catch (problem) {
      app.show(problem.code == 'full' ? T.text('partyFull') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> startParty() => _partyCall(() => hub.parties.create(open: partyStartsOpen));

  Future<void> joinParty(String id) => _partyCall(() => hub.parties.join(id));

  Future<void> declineParty(String id) => _partyCall(() => hub.parties.decline(id));

  Future<void> setPartyOpen(bool open) => _partyCall(() => hub.parties.setOpen(open));

  Future<void> kick(Person person) => _partyCall(() => hub.parties.kick(person.id));

  Future<void> inviteToParty(Person person) => _partyCall(() async {
    if (hub.parties.party == null) await hub.parties.create(open: partyStartsOpen);
    await hub.parties.invite([person.id]);
    app.show(T.format('gameInvited', [person.displayName]));
  });

  Future<void> leaveParty() => _partyCall(() async {
    await hub.voice.leave();
    await hub.parties.leave();
  });

  Future<void> joinVoice() async {
    await hub.voice.join();
    switch (hub.voice.problem) {
      case VoiceProblem.microphone:
        app.show(T.text('voiceNoMic'));
      case VoiceProblem.failed:
        app.show(T.text('togetherUnreachable'));
      case null:
        if (hub.voice.active) app.show(T.text('voiceJoined'));
    }
  }

  void setPushToTalk(bool on) {
    app.preferences.pushToTalk = on;
    hub.voice.setPushToTalk(on);
    app.savePreferences();
  }

  void captureTalkKey() {
    capturingTalkKey = true;
    app.refresh();
  }

  /// A key pressed while the talk key is being chosen; false when it cannot be one.
  bool chooseTalkKey(int usage) {
    capturingTalkKey = false;
    if (!TalkKeys.supported(usage)) {
      app.refresh();
      return false;
    }
    app.preferences.talkKey = usage & 0xFFFF;
    talkWatch?.usage = talkKey;
    app.savePreferences();
    app.show(T.format('voiceTalkKeySet', [talkKeyName]));
    return true;
  }

  /// The talk key while the launcher has the keyboard, where it cannot be read from the desktop.
  bool talkKeyInWindow(int usage, {required bool down}) {
    if (talkWatch != null || !hub.voice.active || (usage & 0xFFFF) != talkKey) return false;
    hub.voice.talkKey(down);
    return true;
  }
}
