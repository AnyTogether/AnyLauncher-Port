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

/// The menu over the thread: a message's (react, reply, edit, unsend, then asked again) or a
/// conversation's (pin, mute); the row the keys are on and, on the reactions, which one.
class MessageMenu {
  MessageMenu.message(ChatMessage this.message) : conversationId = message.conversationId;
  MessageMenu.conversation(this.conversationId) : message = null;

  final ChatMessage? message;
  final String conversationId;
  int row = 0;
  int reaction = 0;
  bool confirming = false;
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
    _resetThread();
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
    _resetThread();
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

  /// Sends [text] to the conversation shown, as the answer to the message being replied to.
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    app.sounds.play(Cue.select);
    final reply = replyingTo;
    replyingTo = null;
    if (hub.messages.openId == null) {
      final target = selectedTarget;
      if (target is! FriendTarget) return;
      await messageFriend(target.friend.person);
    }
    await hub.messages.send(text, replyTo: reply);
  }

  void messagesCommand(Command command) {
    if (messageMenu != null) return _menuCommand(command);
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
          _resetThread();
          app.sounds.play(Cue.move);
          app.refresh();
          unawaited(_showSelected().catchError((Object _) {}));
        case Command.right || Command.select:
          unawaited(_enterThread().catchError((Object _) {}));
        // △ on a conversation: pin it, mute it.
        case Command.options when selectedTarget is ConversationTarget:
          openConversationMenu((selectedTarget as ConversationTarget).conversation);
        case Command.back || Command.options:
          _resetThread();
          hub.messages.hide();
          app.closeOverlay();
        default:
          break;
      }
      return;
    }
    final focused = focusedMessage;
    if (focused != null) return _onMessage(command, focused);
    switch (command) {
      case Command.left:
        if (messageFocus == 0) {
          _leaveThread();
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
        // Up from the field: onto the newest message, then older ones.
        if (hub.messages.thread.isEmpty) {
          unawaited(hub.messages.older().catchError((Object _) {}));
        } else {
          messageCursor = 0;
          app.sounds.play(Cue.move);
          app.refresh();
        }
      case Command.select:
        final failed = hub.messages.thread.where((message) => message.failed).lastOrNull;
        if (messageFocus == composer) {
          if (failed != null && draft.isEmpty && editingMessage == null) {
            unawaited(hub.messages.retry(failed));
          } else {
            app.startEditing(draftRow);
          }
        } else {
          unawaited(sendMessage(quickReplies[messageFocus]));
        }
      case Command.options:
        if (hub.messages.open case final Conversation conversation) openConversationMenu(conversation);
      case Command.back:
        // A reply or an edit is dropped first.
        if (replyingTo != null || editingMessage != null) {
          cancelComposerNote();
          app.sounds.play(Cue.back);
        } else {
          _leaveThread();
        }
        app.refresh();
      default:
        break;
    }
  }

  /// The keys on a message: up and down through the thread, its menu on Enter or △.
  void _onMessage(Command command, ChatMessage message) {
    final thread = hub.messages.thread;
    switch (command) {
      case Command.up:
        if (messageCursor! < thread.length - 1) {
          messageCursor = messageCursor! + 1;
          app.sounds.play(Cue.move);
          app.refresh();
        } else {
          unawaited(hub.messages.older().catchError((Object _) {}));
        }
      case Command.down:
        messageCursor = messageCursor! == 0 ? null : messageCursor! - 1;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left:
        _leaveThread();
        app.refresh();
      case Command.select || Command.options:
        if (message.failed) {
          unawaited(hub.messages.retry(message));
        } else {
          openMessageMenu(message);
        }
      case Command.back:
        messageCursor = null;
        app.sounds.play(Cue.back);
        app.refresh();
      default:
        break;
    }
  }

  void _leaveThread() {
    messagesInThread = false;
    messageCursor = null;
    app.sounds.play(Cue.back);
  }

  /// A reply, an edit, the message the keys were on and an open menu belong to one conversation:
  /// moving to another drops them.
  void _resetThread() {
    messageCursor = null;
    messageMenu = null;
    replyingTo = null;
    if (editingMessage != null) {
      editingMessage = null;
      draft = '';
    }
  }

  /// The message the keys are on, if they are on one.
  ChatMessage? get focusedMessage {
    final cursor = messageCursor;
    final thread = hub.messages.thread;
    if (!messagesInThread || cursor == null || thread.isEmpty) return null;
    return thread[thread.length - 1 - cursor.clamp(0, thread.length - 1)];
  }

  /// The keys onto [message] (clicked, or for the tests).
  void focusMessage(ChatMessage message) {
    final thread = hub.messages.thread;
    final at = thread.indexWhere((m) => m.id == message.id);
    if (at < 0) return;
    messagesInThread = true;
    messageCursor = thread.length - 1 - at;
    app.refresh();
  }

  /// A message as the thread has it now (its reactions may have changed since the menu opened).
  ChatMessage _current(ChatMessage message) =>
      hub.messages.thread.where((m) => m.id == message.id).firstOrNull ?? message;

  /// What a message can have done to it: react and reply; the user's own edited (while it may
  /// be) and unsent. Nothing for one removed or still on its way.
  void openMessageMenu(ChatMessage message) {
    if (message.deleted || message.seq <= 0) return;
    focusMessage(message);
    messageMenu = MessageMenu.message(message);
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void openConversationMenu(Conversation conversation) {
    messageMenu = MessageMenu.conversation(conversation.id);
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void closeMessageMenu() {
    messageMenu = null;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  /// The menu's rows by id: `react` (the seven reactions, left and right), `reply`, `edit`,
  /// `unsend`, then asked again (`unsend-confirm`, `cancel`); a conversation's `pin` and `mute`.
  List<String> get messageMenuItems {
    final menu = messageMenu;
    if (menu == null) return const [];
    final shown = menu.message;
    if (shown == null) return const ['pin', 'mute'];
    if (menu.confirming) return const ['unsend-confirm', 'cancel'];
    final message = _current(shown);
    final me = user?.id;
    return [
      'react',
      'reply',
      if (Messages.canEdit(message, me, DateTime.now())) 'edit',
      if (message.authorId == me) 'unsend',
    ];
  }

  String menuLabel(String item) {
    final conversation = hub.messages.byId(messageMenu?.conversationId);
    return switch (item) {
      'react' => T.text('messagesReact'),
      'reply' => T.text('messagesReply'),
      'edit' => T.text('messagesEdit'),
      'unsend' || 'unsend-confirm' => T.text('messagesUnsend'),
      'pin' => T.text(conversation?.pinned == true ? 'conversationUnpin' : 'conversationPin'),
      'mute' => T.text(conversation?.muted == true ? 'conversationUnmute' : 'conversationMute'),
      _ => T.text('cancel'),
    };
  }

  /// The words a reaction has, for the menu.
  static String reactionLabel(String name) => switch (name) {
    'like' => T.text('reactionLike'),
    'love' => T.text('reactionLove'),
    'laugh' => T.text('reactionLaugh'),
    'wow' => T.text('reactionWow'),
    'sad' => T.text('reactionSad'),
    'fire' => T.text('reactionFire'),
    _ => T.text('reactionGg'),
  };

  void _menuCommand(Command command) {
    final menu = messageMenu!;
    final items = messageMenuItems;
    switch (command) {
      case Command.up || Command.down:
        final next = (menu.row + (command == Command.down ? 1 : -1)).clamp(0, items.length - 1);
        if (next == menu.row) return;
        menu.row = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left || Command.right when items[menu.row] == 'react':
        final next = (menu.reaction + (command == Command.right ? 1 : -1)).clamp(0, messageReactions.length - 1);
        if (next == menu.reaction) return;
        menu.reaction = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        runMenuItem(items[menu.row.clamp(0, items.length - 1)]);
      case Command.back || Command.options:
        closeMessageMenu();
      default:
        break;
    }
  }

  /// Does what a row of the open menu says.
  void runMenuItem(String item) {
    final menu = messageMenu;
    if (menu == null) return;
    final message = menu.message == null ? null : _current(menu.message!);
    final conversation = hub.messages.byId(menu.conversationId);
    switch (item) {
      case 'react' when message != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(toggleReaction(message, messageReactions[menu.reaction]));
      case 'reply' when message != null:
        startReply(message);
      case 'edit' when message != null:
        startEdit(message);
      case 'unsend':
        menu
          ..confirming = true
          ..row = 0;
        app.sounds.play(Cue.select);
      case 'unsend-confirm' when message != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(unsendMessage(message));
      case 'pin' when conversation != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(setPinned(conversation, !conversation.pinned));
      case 'mute' when conversation != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(setMuted(conversation, !conversation.muted));
      default:
        closeMessageMenu();
        return;
    }
    app.refresh();
  }

  /// Answers [message]: the composer says to whom, and the cursor goes into it.
  void startReply(ChatMessage message) {
    if (editingMessage != null) draft = '';
    editingMessage = null;
    replyingTo = message.seq;
    _toComposer();
  }

  /// New words for a message of the user's: its text into the composer.
  void startEdit(ChatMessage message) {
    replyingTo = null;
    editingMessage = message;
    draft = message.words ?? '';
    _toComposer();
  }

  void _toComposer() {
    messageMenu = null;
    messageCursor = null;
    messagesInThread = true;
    messageFocus = composer;
    app.sounds.play(Cue.select);
    app.startEditing(draftRow);
    app.refresh();
  }

  /// The reply or the edit dropped; an edit's words with it.
  void cancelComposerNote() {
    replyingTo = null;
    if (editingMessage != null) {
      editingMessage = null;
      draft = '';
    }
    app.refresh();
  }

  /// What the line above the composer says while it answers or edits: the title (Replying to
  /// Ana, Edit) and the words.
  (String, String)? get composerNote {
    final editing = editingMessage;
    if (editing != null) return (T.text('messagesEdit'), editing.words ?? '');
    final seq = replyingTo;
    if (seq == null) return null;
    final target = hub.messages.inThread(seq);
    final name = authorName(hub.messages.open, target?.authorId);
    return (T.format('messagesReplyingTo', [name]), _quoted(target));
  }

  /// The message [message] answers, as its quote shows it: who wrote it and what (an earlier
  /// message when it is not loaded, Message removed when it is gone).
  (String, String)? quoteOf(ChatMessage message) {
    final seq = message.replyTo;
    if (seq == null) return null;
    final target = hub.messages.inThread(seq);
    if (target == null) return ('', T.text('messagesEarlier'));
    return (authorName(hub.messages.byId(message.conversationId), target.authorId), _quoted(target));
  }

  static String _quoted(ChatMessage? target) => target == null
      ? T.text('messagesEarlier')
      : target.deleted
      ? T.text('messagesDeleted')
      : (target.words ?? '');

  /// The message of the user's that gets the receipt line: their newest one in the thread.
  ChatMessage? receiptFor(Conversation conversation) {
    if (hub.messages.openId != conversation.id) return null;
    final me = user?.id;
    return hub.messages.thread.where((m) => m.authorId == me && m.seq > 0).lastOrNull;
  }

  /// Sent, Delivered, Read; Seen by 2, Seen by everyone; nothing for someone else's message or
  /// from a server without receipts.
  String? receiptText(Conversation conversation, ChatMessage message) {
    final receipt = Messages.receiptOf(conversation, message, user?.id);
    if (receipt == null) return null;
    return switch (receipt.kind) {
      ReceiptKind.sent => T.text('receiptSent'),
      ReceiptKind.delivered => T.text('receiptDelivered'),
      ReceiptKind.read => T.text('receiptRead'),
      ReceiptKind.seen when receipt.everyone => T.text('receiptSeenByEveryone'),
      ReceiptKind.seen => T.format('receiptSeenBy', [receipt.count]),
    };
  }

  Future<void> toggleReaction(ChatMessage message, String name) async {
    try {
      await hub.messages.react(_current(message), name);
    } on Object catch (error) {
      app.show(this.message(error));
    }
  }

  Future<void> unsendMessage(ChatMessage message) async {
    try {
      await hub.messages.unsend(message);
    } on Object catch (error) {
      app.show(this.message(error));
    }
  }

  Future<void> _finishEdit(ChatMessage editing, String text) async {
    if (text.trim().isEmpty || text.trim() == (editing.words ?? '').trim()) return;
    try {
      await hub.messages.edit(editing, text);
    } on TogetherProblem catch (problem) {
      app.show(
        problem.code == 'edit_limit' || problem.code == 'forbidden' ? T.text('messagesEditLimit') : message(problem),
      );
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Pinned to the top or not (five at most); the keys stay on the conversation they were on.
  Future<void> setPinned(Conversation conversation, bool pinned) =>
      _keepingSelection(() => hub.messages.setPinned(conversation, pinned));

  Future<void> setMuted(Conversation conversation, bool muted) =>
      _keepingSelection(() => hub.messages.setMuted(conversation, muted));

  Future<void> _keepingSelection(Future<void> Function() change) async {
    final selected = selectedTarget;
    try {
      await change();
    } on TogetherProblem catch (problem) {
      app.show(problem.code == 'full' ? T.format('conversationPinFull', [Messages.maxPinned]) : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
    if (selected is ConversationTarget) {
      final at = messageTargets.indexWhere(
        (target) => target is ConversationTarget && target.conversation.id == selected.conversation.id,
      );
      if (at >= 0) messagesIndex = at;
    }
    app.refresh();
  }

  /// The composer as a text row, for the field the thread shows; Enter sends, or saves an edit.
  PanelRow get draftField => PanelRow(
    id: draftRow,
    title: '',
    kind: TextRow(
      draft,
      (text) {
        draft = text;
        if (editingMessage == null) hub.messages.typing();
      },
      submit: () {
        final text = draft;
        draft = '';
        final editing = editingMessage;
        if (editing != null) {
          editingMessage = null;
          unawaited(_finishEdit(editing, text));
        } else {
          unawaited(sendMessage(text));
        }
        app.refresh();
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
    // Muted: it comes in, unread, without a word.
    if (hub.messages.byId(conversation as String?)?.muted == true) return;
    final text = data['text'];
    if (text is! String) return;
    final name =
        hub.messages.byId(conversation)?.author(author as String?)?.displayName ??
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
