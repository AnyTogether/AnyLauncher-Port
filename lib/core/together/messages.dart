import 'dart:async';
import 'dart:math';

import 'account.dart';
import 'notifier.dart';
import 'people.dart';
import 'socket.dart';

/// A UUIDv7: the time first, then randomness; the id a message is sent with, so a message sent
/// twice is kept once.
String uuidv7([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  final ms = DateTime.now().millisecondsSinceEpoch;
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  bytes[6] = 0x70 | (bytes[6] & 0x0f);
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The reactions a message can get, one of each per person, in the API's order.
const messageReactions = ['like', 'love', 'laugh', 'wow', 'sad', 'fire', 'gg'];

/// How the clients draw them.
const reactionGlyphs = {'like': '👍', 'love': '❤️', 'laugh': '😂', 'wow': '😮', 'sad': '😢', 'fire': '🔥', 'gg': 'GG'};

/// One reaction on a message: how many added it, and who.
class ReactionCount {
  const ReactionCount({required this.name, required this.count, required this.userIds});

  static ReactionCount? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['reaction'];
    if (name is! String || !messageReactions.contains(name)) return null;
    final userIds = [
      for (final id in (json['userIds'] as List<dynamic>? ?? const []))
        if (id is String) id,
    ];
    return ReactionCount(name: name, count: (json['count'] as num? ?? userIds.length).toInt(), userIds: userIds);
  }

  /// A list as the API sends it; the ones this launcher does not know left out.
  static List<ReactionCount> list(Object? json) => [
    if (json is List<dynamic>)
      for (final item in json) ?ReactionCount.fromJson(item),
  ];

  final String name;
  final int count;
  final List<String> userIds;
}

/// How far another member has got: read (null unless both share read receipts) and delivered
/// (in a direct conversation only).
class Receipt {
  const Receipt({required this.userId, required this.readSeq, required this.deliveredSeq});

  factory Receipt.fromJson(Map<String, dynamic> json) => Receipt(
    userId: json['userId'] as String? ?? '',
    readSeq: (json['readSeq'] as num?)?.toInt(),
    deliveredSeq: (json['deliveredSeq'] as num?)?.toInt(),
  );

  final String userId;
  final int? readSeq;
  final int? deliveredSeq;
}

enum ReceiptKind { sent, delivered, read, seen }

/// Where a message of mine has got: sent, delivered or read in a direct conversation; seen by
/// [count] in a group, [everyone] once all have.
class MessageReceipt {
  const MessageReceipt(this.kind, {this.count = 0, this.everyone = false});

  final ReceiptKind kind;
  final int count;
  final bool everyone;
}

/// One message in a conversation; a deleted (unsent or removed) one keeps its place with no text
/// and no reactions. [pending] while it is on its way, [failed] when it did not get there.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.seq,
    required this.authorId,
    required this.text,
    required this.createdAt,
    this.edited = false,
    this.deleted = false,
    this.pending = false,
    this.failed = false,
    this.replyTo,
    this.editCount = 0,
    this.reactions = const [],
    this.kind = 'text',
    this.caption,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final deleted = json['deletedAt'] != null;
    final edited = json['editedAt'] != null;
    return ChatMessage(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      seq: (json['seq'] as num).toInt(),
      authorId: json['authorId'] as String?,
      text: deleted ? null : json['text'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      edited: edited,
      deleted: deleted,
      replyTo: (json['replyTo'] as num?)?.toInt(),
      // An older server leaves the count out: an edited one was edited once at least.
      editCount: (json['editCount'] as num?)?.toInt() ?? (edited ? 1 : 0),
      reactions: deleted ? const [] : ReactionCount.list(json['reactions']),
      kind: json['kind'] as String? ?? 'text',
      caption: json['caption'] as String?,
    );
  }

  final String id;
  final String conversationId;

  /// Its place in the conversation; 0 until the server gave it one.
  final int seq;
  final String? authorId;
  final String? text;
  final DateTime createdAt;
  final bool edited;
  final bool deleted;
  final bool pending;
  final bool failed;

  /// The seq of the message it answers, in the same conversation.
  final int? replyTo;

  /// How many times it was edited (20 at most).
  final int editCount;
  final List<ReactionCount> reactions;

  /// text, or a piece of media whose [text] is a stand-in and [caption] the caption alone.
  final String kind;
  final String? caption;

  /// Whether [userId] added the reaction [name].
  bool reacted(String name, String? userId) =>
      reactions.any((reaction) => reaction.name == name && reaction.userIds.contains(userId));

  /// What can be edited and quoted: the text, or a piece of media's caption.
  String? get words => kind == 'text' ? text : (caption ?? text);

  ChatMessage copyWith({
    String? text,
    int? replyTo,
    List<ReactionCount>? reactions,
    bool? pending,
    bool? failed,
    int? seq,
  }) => ChatMessage(
    id: id,
    conversationId: conversationId,
    seq: seq ?? this.seq,
    authorId: authorId,
    text: text ?? this.text,
    createdAt: createdAt,
    edited: edited,
    deleted: deleted,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
    replyTo: replyTo ?? this.replyTo,
    editCount: editCount,
    reactions: reactions ?? this.reactions,
    kind: kind,
    caption: caption,
  );

  /// Unsent: its place stays, nothing else.
  ChatMessage removed() => ChatMessage(
    id: id,
    conversationId: conversationId,
    seq: seq,
    authorId: authorId,
    text: null,
    createdAt: createdAt,
    edited: edited,
    deleted: true,
    replyTo: replyTo,
    editCount: editCount,
    kind: kind,
  );
}

/// A direct conversation with a friend or a group.
class Conversation {
  const Conversation({
    required this.id,
    required this.group,
    required this.title,
    required this.members,
    required this.lastSeq,
    required this.readSeq,
    required this.lastMessage,
    required this.updatedAt,
    this._unread,
    this.pinned = false,
    this.muted = false,
    this.receipts,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final receipts = json['receipts'];
    return Conversation(
      id: json['id'] as String,
      group: json['kind'] == 'group',
      title: json['title'] as String?,
      members: [
        for (final member in (json['members'] as List<dynamic>? ?? const []))
          Person.fromJson(member as Map<String, dynamic>),
      ],
      lastSeq: (json['lastSeq'] as num? ?? 0).toInt(),
      readSeq: (json['readSeq'] as num? ?? 0).toInt(),
      lastMessage: json['lastMessage'] is Map<String, dynamic>
          ? ChatMessage.fromJson(json['lastMessage'] as Map<String, dynamic>)
          : null,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      unread: (json['unread'] as num?)?.toInt(),
      pinned: json['pinned'] == true,
      muted: json['muted'] == true,
      receipts: receipts is List<dynamic>
          ? [
              for (final receipt in receipts)
                if (receipt is Map<String, dynamic>) Receipt.fromJson(receipt),
            ]
          : null,
    );
  }

  final String id;
  final bool group;
  final String? title;
  final List<Person> members;
  final int lastSeq;
  final int readSeq;
  final ChatMessage? lastMessage;
  final DateTime updatedAt;
  final int? _unread;

  /// Pinned to the top of the list; its notifications muted.
  final bool pinned;
  final bool muted;

  /// The other members' read and delivered marks; null from an older server.
  final List<Receipt>? receipts;

  /// The others' messages after the read mark that are still there, as the server counts them;
  /// an older server's from the marks.
  int get unread => _unread ?? max(0, lastSeq - readSeq);

  /// Everyone in it but [me].
  List<Person> others(String? me) => members.where((person) => person.id != me).toList();

  /// Its title, or the people in it.
  String name(String? me) =>
      title ?? (others(me).isEmpty ? '…' : others(me).map((person) => person.displayName).join(', '));

  Person? author(String? id) => members.where((person) => person.id == id).firstOrNull;

  Conversation copyWith({
    int? lastSeq,
    int? readSeq,
    ChatMessage? lastMessage,
    DateTime? updatedAt,
    int? unread,
    List<Receipt>? receipts,
  }) => Conversation(
    id: id,
    group: group,
    title: title,
    members: members,
    lastSeq: lastSeq ?? this.lastSeq,
    readSeq: readSeq ?? this.readSeq,
    lastMessage: lastMessage ?? this.lastMessage,
    updatedAt: updatedAt ?? this.updatedAt,
    unread: unread ?? _unread,
    pinned: pinned,
    muted: muted,
    receipts: receipts ?? this.receipts,
  );
}

/// Messages: the conversations (pinned first, then the newest) with what is unread, the one open
/// with its thread, sending (kept once however often it is sent), replies, edits, unsending,
/// reactions, read and delivered marks, pins and mutes, and everything live.
class Messages with Notifier {
  Messages({required this.account, required this.socket}) {
    _events = socket.events.listen(_event);
  }

  /// How long the author may edit a message, how many times, and how many conversations can be
  /// pinned: the server's limits.
  static const editWindow = Duration(minutes: 15);
  static const maxEdits = 20;
  static const maxPinned = 5;

  final TogetherAccount account;
  final TogetherSocket socket;
  late final StreamSubscription<TogetherEvent> _events;

  List<Conversation> conversations = const [];

  /// A message did not get there: why (a blocked link, no connection).
  void Function(Object error)? onSendFailed;

  /// Who is typing where, until when: the gateway's typing events, shown for a few seconds.
  final Map<String, Map<String, DateTime>> _typing = {};
  Timer? _typingExpiry;
  DateTime _toldTyping = DateTime.fromMillisecondsSinceEpoch(0);
  static const typingShown = Duration(seconds: 5);

  /// Messages not read yet, over every conversation.
  int unread = 0;
  bool loaded = false;

  /// The conversation shown, its messages oldest first, and whether older ones are left.
  String? openId;
  List<ChatMessage> thread = const [];
  bool more = false;
  bool loadingThread = false;
  bool _older = false;

  String? get _me => account.user?.id;

  Conversation? byId(String? id) => conversations.where((c) => c.id == id).firstOrNull;

  Conversation? get open => byId(openId);

  Future<void> refresh() async {
    final list = await account.call('GET', 'me/conversations');
    conversations = ordered([
      for (final json in (list['conversations'] as List<dynamic>? ?? const []))
        Conversation.fromJson(json as Map<String, dynamic>),
    ]);
    loaded = true;
    await _countUnread();
    final shown = open;
    if (shown != null && shown.unread > 0) await _read(shown);
  }

  Future<void> _countUnread() async {
    final count = await account.call('GET', 'me/conversations/unread');
    unread = (count['messages'] as num? ?? 0).toInt();
    notifyListeners();
  }

  /// Shows a conversation: its newest messages, and read up to them.
  Future<void> show(String id) async {
    openId = id;
    thread = const [];
    more = false;
    loadingThread = true;
    notifyListeners();
    try {
      final page = await account.call('GET', 'conversations/$id/messages?limit=50');
      if (openId != id) return;
      thread = _page(page);
      more = page['more'] == true;
    } finally {
      if (openId == id) {
        loadingThread = false;
        notifyListeners();
      }
    }
    final conversation = byId(id);
    if (conversation != null) await _read(conversation);
  }

  /// Nothing shown any more: new messages count as unread again.
  void hide() {
    openId = null;
    thread = const [];
    more = false;
    notifyListeners();
  }

  /// The conversation with a friend, made the first time, and shown.
  Future<void> withFriend(String userId) async {
    final json = await account.call('POST', 'conversations', {
      'members': [userId],
    });
    final conversation = Conversation.fromJson(json);
    if (byId(conversation.id) == null) {
      conversations = [conversation, ...conversations];
    }
    await show(conversation.id);
  }

  /// Older messages above the ones shown.
  Future<void> older() async {
    final id = openId;
    if (id == null || !more || thread.isEmpty || _older) return;
    _older = true;
    final Map<String, dynamic> page;
    try {
      page = await account.call('GET', 'conversations/$id/messages?limit=50&before=${thread.first.seq}');
    } finally {
      _older = false;
    }
    if (openId != id) return;
    final known = thread.map((m) => m.id).toSet();
    thread = [..._page(page).where((m) => !known.contains(m.id)), ...thread];
    more = page['more'] == true;
    notifyListeners();
  }

  /// Sends a text to the open conversation, an answer to the message at [replyTo] when given;
  /// it shows at once and settles when the server has it.
  Future<void> send(String text, {int? replyTo}) async {
    final id = openId;
    final trimmed = text.trim();
    if (id == null || trimmed.isEmpty) return;
    final message = ChatMessage(
      id: uuidv7(),
      conversationId: id,
      seq: 0,
      authorId: _me,
      text: trimmed,
      createdAt: DateTime.now(),
      pending: true,
      replyTo: replyTo,
    );
    thread = [...thread, message];
    notifyListeners();
    await _deliver(message);
  }

  /// Sends again a message that did not get there, with the same id.
  Future<void> retry(ChatMessage message) async {
    _replace(message.copyWith(seq: 0, pending: true, failed: false));
    await _deliver(message);
  }

  Future<void> _deliver(ChatMessage message) async {
    try {
      final json = await account.call('POST', 'conversations/${message.conversationId}/messages', {
        'clientId': message.id,
        'text': message.text,
        'replyTo': ?message.replyTo,
      });
      _arrived(ChatMessage.fromJson(json));
    } on Object catch (error) {
      onSendFailed?.call(error);
      _replace(message.copyWith(seq: 0, pending: false, failed: true));
    }
  }

  /// A message of mine with new words; thrown when the server says no (403 after the edit
  /// window, 409 edit_limit after the last edit).
  Future<void> edit(ChatMessage message, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || message.seq <= 0) return;
    final json = await account.call('PATCH', 'conversations/${message.conversationId}/messages/${message.seq}', {
      'text': trimmed,
    });
    _changed(ChatMessage.fromJson(json));
  }

  /// A message of mine unsent for everyone: its place stays.
  Future<void> unsend(ChatMessage message) async {
    if (message.seq <= 0) return;
    await account.call('DELETE', 'conversations/${message.conversationId}/messages/${message.seq}');
    _changed(message.removed());
  }

  /// Adds the reaction [name] to a message, or takes it back when this user had added it.
  Future<void> react(ChatMessage message, String name) async {
    if (message.seq <= 0 || message.deleted || !messageReactions.contains(name)) return;
    final json = await account.call(
      message.reacted(name, _me) ? 'DELETE' : 'PUT',
      'conversations/${message.conversationId}/messages/${message.seq}/reactions/$name',
    );
    _reactions(message.conversationId, message.seq, ReactionCount.list(json['reactions']));
  }

  void _reactions(String conversationId, int seq, List<ReactionCount> reactions) {
    ChatMessage update(ChatMessage message) =>
        message.conversationId == conversationId && message.seq == seq && !message.deleted
        ? message.copyWith(reactions: reactions)
        : message;
    if (conversationId == openId) thread = [for (final message in thread) update(message)];
    conversations = [
      for (final c in conversations)
        if (c.lastMessage case final ChatMessage last when c.id == conversationId && last.seq == seq)
          c.copyWith(lastMessage: update(last))
        else
          c,
    ];
    notifyListeners();
  }

  /// Pinned to the top of the list or not; thrown with code `full` when five are pinned.
  Future<void> setPinned(Conversation conversation, bool pinned) async {
    final json = await account.call('PUT', 'conversations/${conversation.id}/pin', {'pinned': pinned});
    _settled(conversation, json);
  }

  /// Its notifications muted or not.
  Future<void> setMuted(Conversation conversation, bool muted) async {
    final json = await account.call('PUT', 'conversations/${conversation.id}/mute', {'muted': muted});
    _settled(conversation, json);
  }

  void _settled(Conversation before, Map<String, dynamic> json) {
    final after = json['id'] == before.id ? Conversation.fromJson(json) : before;
    conversations = ordered([
      for (final c in conversations)
        if (c.id == before.id) after else c,
    ]);
    notifyListeners();
  }

  void _replace(ChatMessage message) {
    thread = [
      for (final m in thread)
        if (m.id == message.id) message else m,
    ];
    notifyListeners();
  }

  /// A message the server has (sent here, or live from the gateway): into the thread when it is
  /// open, and to the top of the list.
  void _arrived(ChatMessage message) {
    final mine = message.authorId == _me;
    if (message.conversationId == openId) {
      final at = thread.indexWhere((m) => m.id == message.id);
      if (at >= 0) {
        thread = [...thread]..[at] = message;
      } else {
        thread = [...thread, message]..sort(_order);
      }
    }
    final conversation = byId(message.conversationId);
    if (conversation == null) {
      unawaited(refresh().catchError((Object _) {}));
      notifyListeners();
      return;
    }
    if (message.seq <= conversation.readSeq && !mine) {
      notifyListeners();
      return;
    }
    // Mine is read already; one in the open conversation is read just after.
    final newer = message.seq > conversation.lastSeq;
    final next = conversation.copyWith(
      lastSeq: max(conversation.lastSeq, message.seq),
      readSeq: mine ? max(conversation.readSeq, message.seq) : null,
      lastMessage: message.seq >= conversation.lastSeq ? message : null,
      updatedAt: message.createdAt,
      unread: mine ? 0 : conversation.unread + (newer ? 1 : 0),
    );
    if (!mine && newer) unread++;
    // Sending reads the conversation up to it (on the server too).
    if (mine) unread = max(0, unread - conversation.unread);
    // To the top of its part of the list: the pinned ones stay first.
    conversations = ordered([next, ...conversations.where((c) => c.id != message.conversationId)], byTime: false);
    notifyListeners();
    if (message.conversationId == openId && !mine) {
      unawaited(_read(next).catchError((Object _) {}));
    }
  }

  /// An edit or a deletion: changed where it shows, nothing moves.
  void _changed(ChatMessage message) {
    if (message.conversationId == openId) _replace(message);
    conversations = [
      for (final c in conversations)
        if (c.lastMessage?.id == message.id) c.copyWith(lastMessage: message) else c,
    ];
    notifyListeners();
  }

  /// Someone else's message removed before it was read: one fewer unread, and the count again.
  void _removed(ChatMessage message) {
    final conversation = byId(message.conversationId);
    final known = message.conversationId == openId
        ? thread.where((m) => m.id == message.id).firstOrNull
        : conversation?.lastMessage?.id == message.id
        ? conversation?.lastMessage
        : null;
    final wasThere = known == null || !known.deleted;
    _changed(message);
    if (conversation == null || message.authorId == _me || message.seq <= conversation.readSeq || !wasThere) return;
    conversations = [
      for (final c in conversations)
        if (c.id == conversation.id) c.copyWith(unread: max(0, c.unread - 1)) else c,
    ];
    notifyListeners();
    unawaited(_countUnread().catchError((Object _) {}));
  }

  /// Another member's read or delivered mark: their receipt goes up, never down. Read is
  /// delivered too.
  void _mark(String conversationId, String userId, int upTo, {required bool read}) {
    conversations = [
      for (final c in conversations)
        if (c.id == conversationId && c.receipts != null)
          c.copyWith(
            receipts: [
              for (final r in c.receipts!)
                if (r.userId == userId)
                  Receipt(
                    userId: r.userId,
                    readSeq: read ? max(r.readSeq ?? 0, upTo) : r.readSeq,
                    deliveredSeq: r.deliveredSeq == null ? null : max(r.deliveredSeq!, upTo),
                  )
                else
                  r,
            ],
          )
        else
          c,
    ];
    notifyListeners();
  }

  /// A direct message from someone else reached this device while its conversation is not open:
  /// the sender sees it delivered. (Opening it reads it, which says so by itself.)
  void _delivered(ChatMessage message) {
    final conversation = byId(message.conversationId);
    if (conversation == null || conversation.group || message.authorId == _me) return;
    if (message.conversationId == openId || message.seq <= 0) return;
    unawaited(
      account
          .call('POST', 'conversations/${message.conversationId}/delivered', {'upToSeq': message.seq})
          .then((_) {}, onError: (Object _) {}),
    );
  }

  /// Where a message of mine has got, for the line under it; null for someone else's, a removed
  /// one, one on its way, or a server without receipts.
  static MessageReceipt? receiptOf(Conversation conversation, ChatMessage message, String? me) {
    final receipts = conversation.receipts;
    if (message.authorId != me || message.deleted || message.seq <= 0 || receipts == null) return null;
    if (conversation.group) {
      final count = receipts.where((r) => (r.readSeq ?? 0) >= message.seq).length;
      if (count == 0) return const MessageReceipt(ReceiptKind.sent);
      return MessageReceipt(ReceiptKind.seen, count: count, everyone: count == receipts.length);
    }
    final other = receipts.firstOrNull;
    if (other == null) return null;
    if ((other.readSeq ?? 0) >= message.seq) return const MessageReceipt(ReceiptKind.read);
    if ((other.deliveredSeq ?? 0) >= message.seq) return const MessageReceipt(ReceiptKind.delivered);
    return const MessageReceipt(ReceiptKind.sent);
  }

  /// One's own text (or caption), within the edit window and under the edit limit.
  static bool canEdit(ChatMessage message, String? me, DateTime now) {
    if (message.authorId != me || message.deleted || message.seq <= 0) return false;
    if (message.editCount >= maxEdits) return false;
    if (now.difference(message.createdAt) >= editWindow) return false;
    return message.kind == 'text' || message.caption != null;
  }

  /// Pinned ones first, then (with [byTime]) the newest; otherwise as they were.
  static List<Conversation> ordered(List<Conversation> list, {bool byTime = true}) {
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      if (a.$2.pinned != b.$2.pinned) return a.$2.pinned ? -1 : 1;
      if (byTime) {
        final time = b.$2.updatedAt.compareTo(a.$2.updatedAt);
        if (time != 0) return time;
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final (_, conversation) in indexed) conversation];
  }

  /// The message at [seq] in the open thread, if it is loaded.
  ChatMessage? inThread(int? seq) => seq == null ? null : thread.where((m) => m.seq == seq).firstOrNull;

  /// Read up to the newest message, here and on the server.
  Future<void> _read(Conversation conversation) async {
    final before = byId(conversation.id) ?? conversation;
    final upTo = before.lastSeq;
    if (before.readSeq >= upTo) return;
    unread = max(0, unread - before.unread);
    conversations = [
      for (final c in conversations)
        if (c.id == before.id) c.copyWith(readSeq: upTo, unread: 0) else c,
    ];
    notifyListeners();
    await account.call('POST', 'conversations/${before.id}/read', {'upToSeq': upTo});
  }

  /// The people typing in [conversationId] now (by user id), not counting this user.
  List<String> typingIn(String? conversationId) {
    final now = DateTime.now();
    final typing = _typing[conversationId] ?? const {};
    return [
      for (final entry in typing.entries)
        if (entry.value.isAfter(now) && entry.key != _me) entry.key,
    ];
  }

  /// Tells the others in the open conversation this user is typing, at most every 2 s.
  void typing() {
    final id = openId;
    if (id == null) return;
    final now = DateTime.now();
    if (now.difference(_toldTyping) < const Duration(seconds: 2)) return;
    _toldTyping = now;
    socket.send({'op': 'typing', 'conversation': id});
  }

  void _someoneTyping(String conversationId, String userId) {
    (_typing[conversationId] ??= {})[userId] = DateTime.now().add(typingShown);
    _typingExpiry?.cancel();
    _typingExpiry = Timer(typingShown + const Duration(milliseconds: 50), () {
      final now = DateTime.now();
      for (final people in _typing.values) {
        people.removeWhere((_, until) => !until.isAfter(now));
      }
      _typing.removeWhere((_, people) => people.isEmpty);
      notifyListeners();
    });
    notifyListeners();
  }

  void clear() {
    _typing.clear();
    conversations = const [];
    unread = 0;
    loaded = false;
    openId = null;
    thread = const [];
    more = false;
    notifyListeners();
  }

  void _event(TogetherEvent event) {
    final data = event.json;
    switch (event.type) {
      case 'live.ready':
        unawaited(refresh().then((_) => _catchUp()).catchError((Object _) {}));
      case 'message.created':
        final message = ChatMessage.fromJson(data);
        // A message ends its author's typing.
        _typing[message.conversationId]?.remove(message.authorId);
        _delivered(message);
        _arrived(message);
      case 'typing':
        final conversation = data['conversationId'];
        final user = data['userId'];
        if (conversation is String && user is String && user != _me) _someoneTyping(conversation, user);
      case 'message.updated':
        _changed(ChatMessage.fromJson(data));
      case 'message.deleted':
        _removed(ChatMessage.fromJson(data));
      case 'message.reactions':
        final id = data['conversationId'];
        final seq = data['seq'];
        if (id is String && seq is num) _reactions(id, seq.toInt(), ReactionCount.list(data['reactions']));
      case 'conversation.read' when data['userId'] == _me:
        // Read on another device: the server says what is left unread there.
        final id = data['conversationId'];
        final upTo = (data['upToSeq'] as num? ?? 0).toInt();
        final left = (data['unread'] as num?)?.toInt();
        conversations = [
          for (final c in conversations)
            if (c.id == id)
              c.copyWith(readSeq: max(c.readSeq, upTo), unread: left ?? max(0, c.lastSeq - max(c.readSeq, upTo)))
            else
              c,
        ];
        notifyListeners();
        unawaited(_countUnread().catchError((Object _) {}));
      case 'conversation.read' || 'conversation.delivered':
        // Another member's mark: their receipt.
        final id = data['conversationId'];
        final user = data['userId'];
        final upTo = data['upToSeq'];
        if (id is String && user is String && upTo is num) {
          _mark(id, user, upTo.toInt(), read: event.type == 'conversation.read');
        }
      case 'messages.settings':
        // Read receipts turned on or off on another device: what the others' receipts show
        // changes with it.
        unawaited(refresh().catchError((Object _) {}));
      case 'conversation.updated':
        if (data['removed'] == true && data['conversationId'] == openId) {
          hide();
        }
        unawaited(refresh().catchError((Object _) {}));
    }
  }

  /// After a reconnect, the open thread gets what came while the socket was away.
  Future<void> _catchUp() async {
    final id = openId;
    final last = thread.where((m) => m.seq > 0).lastOrNull;
    if (id == null || last == null) return;
    final page = await account.call('GET', 'conversations/$id/messages?limit=100&after=${last.seq}');
    _page(page).forEach(_arrived);
  }

  static List<ChatMessage> _page(Map<String, dynamic> page) => [
    for (final json in (page['messages'] as List<dynamic>? ?? const []))
      ChatMessage.fromJson(json as Map<String, dynamic>),
  ];

  /// By place in the conversation; the ones still on their way last.
  static int _order(ChatMessage a, ChatMessage b) {
    if (a.seq == 0 || b.seq == 0) return a.seq == 0 ? (b.seq == 0 ? 0 : 1) : -1;
    return a.seq.compareTo(b.seq);
  }

  void dispose() {
    _typingExpiry?.cancel();
    unawaited(_events.cancel());
  }
}
