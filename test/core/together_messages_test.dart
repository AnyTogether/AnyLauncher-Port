import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:flutter_test/flutter_test.dart';

/// Messages as the API sends them: reactions, replies, edits, unsent ones, receipts, pins and the
/// server's unread count, each one left out by an older server; and what the thread works out
/// from them (where a message of mine has got, whether it can still be edited, the list's order).
void main() {
  Map<String, dynamic> member(String id, String name) => {
    'userId': id,
    'handle': name.toLowerCase(),
    'displayName': name,
    'avatar': null,
  };

  Map<String, dynamic> messageJson(int seq, String author, {Map<String, dynamic> extra = const {}}) => {
    'id': 'm-$seq',
    'conversationId': 'c-1',
    'seq': seq,
    'authorId': author,
    'kind': 'text',
    'text': 'Hello $seq',
    'caption': null,
    'attachments': <Object>[],
    'replyTo': null,
    'editedAt': null,
    'deletedAt': null,
    'createdAt': '2026-10-26T20:00:00Z',
    ...extra,
  };

  ChatMessage message(
    int seq, {
    String author = 'u-me',
    DateTime? at,
    int editCount = 0,
    bool deleted = false,
    String kind = 'text',
    String? text = 'Hi',
    String? caption,
  }) => ChatMessage(
    id: 'm-$seq',
    conversationId: 'c-1',
    seq: seq,
    authorId: author,
    text: text,
    createdAt: at ?? DateTime.now(),
    editCount: editCount,
    deleted: deleted,
    kind: kind,
    caption: caption,
  );

  Conversation conversation({bool group = false, List<Receipt>? receipts, bool pinned = false, DateTime? updated}) =>
      Conversation(
        id: 'c-${updated?.millisecondsSinceEpoch ?? 0}-$pinned',
        group: group,
        title: null,
        members: const [
          Person(id: 'u-me', handle: 'utku', displayName: 'Utku'),
          Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
        ],
        lastSeq: 9,
        readSeq: 9,
        lastMessage: null,
        updatedAt: updated ?? DateTime.utc(2026, 10, 26),
        pinned: pinned,
        receipts: receipts,
      );

  group('decoding', () {
    test('a message with reactions, a reply and edits', () {
      final decoded = ChatMessage.fromJson(
        messageJson(
          7,
          'u-ana',
          extra: {
            'replyTo': 3,
            'editedAt': '2026-10-26T20:05:00Z',
            'editCount': 2,
            'reactions': [
              {
                'reaction': 'like',
                'count': 2,
                'userIds': ['u-me', 'u-cem'],
              },
              {
                'reaction': 'gg',
                'count': 1,
                'userIds': ['u-ana'],
              },
              {
                'reaction': 'party',
                'count': 1,
                'userIds': ['u-ana'],
              },
            ],
          },
        ),
      );
      expect(decoded.replyTo, 3);
      expect(decoded.edited, isTrue);
      expect(decoded.editCount, 2);
      expect(decoded.reactions.map((r) => r.name), ['like', 'gg'], reason: 'one it does not know is left out');
      expect(decoded.reactions.first.count, 2);
      expect(decoded.reacted('like', 'u-me'), isTrue);
      expect(decoded.reacted('gg', 'u-me'), isFalse);
    });

    test('an older server: no reactions, no edit count, no reply', () {
      final old = ChatMessage.fromJson({
        'id': 'm-1',
        'conversationId': 'c-1',
        'seq': 1,
        'authorId': 'u-ana',
        'text': 'Hi',
        'createdAt': '2026-10-26T20:00:00Z',
        'editedAt': '2026-10-26T20:01:00Z',
      });
      expect(old.reactions, isEmpty);
      expect(old.editCount, 1, reason: 'edited once at least');
      expect(old.replyTo, isNull);
      expect(old.kind, 'text');
      final nulls = ChatMessage.fromJson(messageJson(2, 'u-ana', extra: {'reactions': null, 'editCount': null}));
      expect(nulls.reactions, isEmpty);
      expect(nulls.editCount, 0);
    });

    test('an unsent message keeps its place with no text and no reactions', () {
      final removed = ChatMessage.fromJson(
        messageJson(
          4,
          'u-ana',
          extra: {
            'text': null,
            'deletedAt': '2026-10-26T20:10:00Z',
            'reactions': [
              {
                'reaction': 'love',
                'count': 1,
                'userIds': ['u-me'],
              },
            ],
          },
        ),
      );
      expect(removed.deleted, isTrue);
      expect(removed.text, isNull);
      expect(removed.reactions, isEmpty);
      final unsent = message(5, text: 'Oops').removed();
      expect(unsent.deleted, isTrue);
      expect(unsent.text, isNull);
      expect(unsent.seq, 5);
    });

    test('a conversation with its pin, mute, receipts and the server\'s unread count', () {
      final decoded = Conversation.fromJson({
        'id': 'c-1',
        'kind': 'direct',
        'title': null,
        'members': [member('u-me', 'Utku'), member('u-ana', 'Ana')],
        'lastSeq': 9,
        'readSeq': 4,
        'unread': 3,
        'lastMessage': null,
        'updatedAt': '2026-10-26T20:00:00Z',
        'pinned': true,
        'muted': true,
        'receipts': [
          {'userId': 'u-ana', 'readSeq': null, 'deliveredSeq': 8},
        ],
      });
      expect(decoded.unread, 3, reason: 'the server leaves out unsent ones and mine');
      expect(decoded.pinned, isTrue);
      expect(decoded.muted, isTrue);
      expect(decoded.receipts!.single.userId, 'u-ana');
      expect(decoded.receipts!.single.readSeq, isNull);
      expect(decoded.receipts!.single.deliveredSeq, 8);
    });

    test('an older server: counted from the marks, not pinned, no receipts', () {
      final old = Conversation.fromJson({
        'id': 'c-1',
        'kind': 'group',
        'members': [member('u-me', 'Utku')],
        'lastSeq': 9,
        'readSeq': 4,
        'updatedAt': '2026-10-26T20:00:00Z',
      });
      expect(old.unread, 5);
      expect(old.pinned, isFalse);
      expect(old.muted, isFalse);
      expect(old.receipts, isNull);
    });
  });

  group('receipts', () {
    test('a direct conversation: sent, delivered, read', () {
      final mine = message(5);
      Receipt ana({int? read, int? delivered}) => Receipt(userId: 'u-ana', readSeq: read, deliveredSeq: delivered);
      expect(
        Messages.receiptOf(conversation(receipts: [ana(read: 4, delivered: 4)]), mine, 'u-me')!.kind,
        ReceiptKind.sent,
      );
      expect(
        Messages.receiptOf(conversation(receipts: [ana(read: 4, delivered: 5)]), mine, 'u-me')!.kind,
        ReceiptKind.delivered,
      );
      expect(
        Messages.receiptOf(conversation(receipts: [ana(read: 6, delivered: 6)]), mine, 'u-me')!.kind,
        ReceiptKind.read,
      );
      expect(
        Messages.receiptOf(conversation(receipts: [ana(delivered: 9)]), mine, 'u-me')!.kind,
        ReceiptKind.delivered,
        reason: 'read receipts off: delivered still shows',
      );
    });

    test('a group: seen by how many, or everyone', () {
      final mine = message(5);
      final group = conversation(
        group: true,
        receipts: const [
          Receipt(userId: 'u-ana', readSeq: 5, deliveredSeq: null),
          Receipt(userId: 'u-cem', readSeq: 3, deliveredSeq: null),
          Receipt(userId: 'u-bora', readSeq: null, deliveredSeq: null),
        ],
      );
      final seen = Messages.receiptOf(group, mine, 'u-me')!;
      expect(seen.kind, ReceiptKind.seen);
      expect(seen.count, 1);
      expect(seen.everyone, isFalse);
      final all = conversation(
        group: true,
        receipts: const [
          Receipt(userId: 'u-ana', readSeq: 5, deliveredSeq: null),
          Receipt(userId: 'u-cem', readSeq: 7, deliveredSeq: null),
        ],
      );
      expect(Messages.receiptOf(all, mine, 'u-me')!.everyone, isTrue);
      final none = conversation(
        group: true,
        receipts: const [Receipt(userId: 'u-ana', readSeq: 2, deliveredSeq: null)],
      );
      expect(Messages.receiptOf(none, mine, 'u-me')!.count, 0);
      expect(Messages.receiptOf(none, mine, 'u-me')!.everyone, isFalse);
    });

    test('nothing for someone else\'s message, a removed one, one on its way, or an older server', () {
      final receipts = [const Receipt(userId: 'u-ana', readSeq: 9, deliveredSeq: 9)];
      expect(Messages.receiptOf(conversation(receipts: receipts), message(5, author: 'u-ana'), 'u-me'), isNull);
      expect(Messages.receiptOf(conversation(receipts: receipts), message(5, deleted: true), 'u-me'), isNull);
      expect(Messages.receiptOf(conversation(receipts: receipts), message(0), 'u-me'), isNull);
      expect(Messages.receiptOf(conversation(), message(5), 'u-me'), isNull);
    });
  });

  group('editing', () {
    final now = DateTime.utc(2026, 10, 26, 20, 30);

    test('my own text, within 15 minutes and 20 edits', () {
      expect(Messages.canEdit(message(1, at: now.subtract(const Duration(minutes: 14))), 'u-me', now), isTrue);
      expect(Messages.canEdit(message(1, at: now.subtract(const Duration(minutes: 15))), 'u-me', now), isFalse);
      expect(Messages.canEdit(message(1, at: now, editCount: 19), 'u-me', now), isTrue);
      expect(Messages.canEdit(message(1, at: now, editCount: 20), 'u-me', now), isFalse);
    });

    test('not someone else\'s, a removed one, one on its way, or media without a caption', () {
      expect(Messages.canEdit(message(1, at: now, author: 'u-ana'), 'u-me', now), isFalse);
      expect(Messages.canEdit(message(1, at: now, deleted: true), 'u-me', now), isFalse);
      expect(Messages.canEdit(message(0, at: now), 'u-me', now), isFalse);
      expect(Messages.canEdit(message(1, at: now, kind: 'image', text: '[photo]'), 'u-me', now), isFalse);
      expect(Messages.canEdit(message(1, at: now, kind: 'image', text: 'Look', caption: 'Look'), 'u-me', now), isTrue);
    });
  });

  test('the list: pinned first, then the newest', () {
    final old = conversation(updated: DateTime.utc(2026, 10, 20));
    final newest = conversation(updated: DateTime.utc(2026, 10, 26));
    final pinnedOld = conversation(updated: DateTime.utc(2026, 10, 1), pinned: true);
    final pinnedNew = conversation(updated: DateTime.utc(2026, 10, 25), pinned: true);
    expect(Messages.ordered([old, newest, pinnedOld, pinnedNew]), [pinnedNew, pinnedOld, newest, old]);
    final same = [conversation(updated: DateTime.utc(2026, 10, 2)), conversation(updated: DateTime.utc(2026, 10, 2))];
    expect(Messages.ordered(same), same, reason: 'ties keep their order');
  });

  test('the reactions, in their order, with the glyphs the clients draw', () {
    expect(messageReactions, ['like', 'love', 'laugh', 'wow', 'sad', 'fire', 'gg']);
    expect(messageReactions.map((name) => reactionGlyphs[name]), ['👍', '❤️', '😂', '😮', '😢', '🔥', 'GG']);
  });
}
