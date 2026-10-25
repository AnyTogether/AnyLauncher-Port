part of 'together_model.dart';

/// Something the messages list holds: a conversation, or a friend without one yet.
sealed class MessageTarget {
  const MessageTarget();
}

class ConversationTarget extends MessageTarget {
  const ConversationTarget(this.conversation);
  final Conversation conversation;
}

class FriendTarget extends MessageTarget {
  const FriendTarget(this.friend);
  final Friend friend;
}

/// Messages on AnyTogether: the conversations (and friends to start one with) on the left, the
/// thread on the right with quick replies a controller can send and a field to type in.
extension TogetherMessages on TogetherModel {
  static List<String> get quickReplies => [
    T.text('quickHello'),
    'GG',
    T.text('quickOnMyWay'),
    T.text('quickJoinMe'),
    T.text('quickOneSec'),
  ];

  /// The composer's place among the thread's buttons: after the quick replies.
  static int get composer => quickReplies.length;

  static const draftRow = 'message-draft';

  int get unread => hub.messages.unread;

  List<MessageTarget> get messageTargets {
    final me = user?.id;
    final conversations = hub.messages.conversations;
    final talking = {
      for (final conversation in conversations)
        if (!conversation.group) ...conversation.others(me).map((person) => person.id),
    };
    return [
      for (final conversation in conversations) ConversationTarget(conversation),
      for (final friend in hub.friends.friends)
        if (!talking.contains(friend.person.id)) FriendTarget(friend),
    ];
  }

  MessageTarget? get selectedTarget {
    final targets = messageTargets;
    return targets.isEmpty ? null : targets[messagesIndex.clamp(0, targets.length - 1)];
  }

  Future<void> openMessages() async {
    messagesIndex = 0;
    messagesInThread = false;
    messageFocus = composer;
    app.open(Layer.messages);
    if (!signedIn) return;
    try {
      if (!hub.messages.loaded) await hub.messages.refresh();
      await _showSelected();
    } on Object {
      // The list shows what it has; the socket brings the rest.
    }
  }

  /// The conversation with [person], made the first time, opened with the keys in it.
  Future<void> messageFriend(Person person) async {
    app.open(Layer.messages);
    messagesInThread = true;
    messageFocus = composer;
    try {
      await hub.messages.withFriend(person.id);
      final at = messageTargets.indexWhere(
        (target) => target is ConversationTarget && target.conversation.id == hub.messages.openId,
      );
      if (at >= 0) messagesIndex = at;
      app.refresh();
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> _showSelected() async {
    final target = selectedTarget;
    switch (target) {
      case ConversationTarget(:final conversation) when hub.messages.openId != conversation.id:
        await hub.messages.show(conversation.id);
      case FriendTarget():
        hub.messages.hide();
      default:
        break;
    }
  }

  /// Into the thread: a friend's first conversation is made now.
  Future<void> _enterThread() async {
    final target = selectedTarget;
    if (target == null) return;
    messagesInThread = true;
    messageFocus = composer;
    app.sounds.play(Cue.select);
    app.refresh();
    if (target is FriendTarget) await messageFriend(target.friend.person);
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    app.sounds.play(Cue.select);
    if (hub.messages.openId == null) {
      final target = selectedTarget;
      if (target is! FriendTarget) return;
      await messageFriend(target.friend.person);
    }
    await hub.messages.send(text);
  }

  void messagesCommand(Command command) {
    final targets = messageTargets;
    if (!messagesInThread) {
      switch (command) {
        case Command.up || Command.down:
          final next = (messagesIndex + (command == Command.down ? 1 : -1)).clamp(
            0,
            targets.isEmpty ? 0 : targets.length - 1,
          );
          if (next == messagesIndex) return;
          messagesIndex = next;
          app.sounds.play(Cue.move);
          app.refresh();
          unawaited(_showSelected().catchError((Object _) {}));
        case Command.right || Command.select:
          unawaited(_enterThread().catchError((Object _) {}));
        case Command.back || Command.options:
          hub.messages.hide();
          app.closeOverlay();
        default:
          break;
      }
      return;
    }
    switch (command) {
      case Command.left:
        if (messageFocus == 0) {
          messagesInThread = false;
          app.sounds.play(Cue.back);
        } else {
          messageFocus--;
          app.sounds.play(Cue.move);
        }
        app.refresh();
      case Command.right:
        final next = (messageFocus + 1).clamp(0, composer);
        if (next != messageFocus) app.sounds.play(Cue.move);
        messageFocus = next;
        app.refresh();
      case Command.up:
        unawaited(hub.messages.older().catchError((Object _) {}));
      case Command.select:
        final failed = hub.messages.thread.where((message) => message.failed).lastOrNull;
        if (messageFocus == composer) {
          if (failed != null && draft.isEmpty) {
            unawaited(hub.messages.retry(failed));
          } else {
            app.startEditing(draftRow);
          }
        } else {
          unawaited(sendMessage(quickReplies[messageFocus]));
        }
      case Command.back:
        messagesInThread = false;
        app.sounds.play(Cue.back);
        app.refresh();
      default:
        break;
    }
  }

  /// The composer as a text row, for the field the thread shows.
  PanelRow get draftField => PanelRow(
    id: draftRow,
    title: '',
    kind: TextRow(
      draft,
      (text) {
        draft = text;
        hub.messages.typing();
      },
      submit: () {
        final text = draft;
        draft = '';
        unawaited(sendMessage(text));
      },
      hint: T.text('messagesWrite'),
    ),
  );

  /// Who someone in a conversation is, for the thread.
  String authorName(Conversation? conversation, String? userId) =>
      conversation?.author(userId)?.displayName ?? hub.friends.byId(userId ?? '')?.person.displayName ?? '';

  /// A message that came while its conversation is not on screen: a word at the bottom.
  void _messageArrived(Map<String, dynamic> data) {
    final author = data['authorId'];
    if (author == null || author == user?.id) return;
    final conversation = data['conversationId'];
    if (app.overlay == Layer.messages && hub.messages.openId == conversation) return;
    final text = data['text'];
    if (text is! String) return;
    final name =
        hub.messages.byId(conversation as String?)?.author(author as String?)?.displayName ??
        hub.friends.byId(author as String)?.person.displayName ??
        '';
    app.sounds.play(Cue.move);
    _noticeSound();
    app.show(T.format('messagesFrom', [name, text.length > 80 ? '${text.substring(0, 80)}…' : text]));
  }

  void sendFailed(Object error) {
    app.show(
      error is TogetherProblem && error.code == 'link_blocked'
          ? T.text('messagesLinkBlocked')
          : isFamilyRestriction(error)
          ? FamilyGate.restrictedText(familyFeature(error), side: familySide(error))
          : T.text('messagesFailed'),
    );
  }
}
