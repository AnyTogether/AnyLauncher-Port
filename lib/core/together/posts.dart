import 'account.dart';
import 'people.dart';

/// Captures on AnyTogether: screenshots and clips players share as posts, liked and commented on
/// by the people who may see them. A post holds one to four pictures or one clip, uploaded first
/// as media ([MediaFiles.upload]); the server decides on every read who sees what. The same as
/// the Mac launcher's TogetherPosts.

/// Who sees a post: the author's friends (and the author), or anyone signed in who is not blocked
/// either way. A child's posts are always for friends.
enum PostVisibility { friends, public }

/// What a post takes (`postLimits` on the server).
abstract final class PostLimits {
  /// The longest clip a post takes, and how much over it the server lets a clip run (a
  /// recording that ends a frame late).
  static const clipMs = 60000;
  static const clipSlackMs = 500;

  /// A clip's bytes when the server does not say.
  static const clipBytes = 25 * 1024 * 1024;
  static const images = 4;
  static const caption = 500;
  static const comment = 500;
}

/// Whether a clip fits a post, checked before anything goes up.
sealed class ClipCheck {
  const ClipCheck();

  static ClipCheck check({int? durationMs, required int bytes, int maxBytes = PostLimits.clipBytes}) {
    if (durationMs != null && durationMs > PostLimits.clipMs + PostLimits.clipSlackMs) return ClipTooLong(durationMs);
    if (bytes > maxBytes) return ClipTooBig(bytes);
    return const ClipFits();
  }

  /// Posting is refused before the upload.
  bool get blocks => this is ClipTooLong;
}

class ClipFits extends ClipCheck {
  const ClipFits();
}

/// Longer than a post takes: it cannot be posted as it is.
class ClipTooLong extends ClipCheck {
  const ClipTooLong(this.ms);
  final int ms;
}

/// More bytes than a clip may have: it is made smaller first.
class ClipTooBig extends ClipCheck {
  const ClipTooBig(this.bytes);
  final int bytes;
}

/// A picture or clip as AnyTogether shows it (MediaView, PostMedia): signed links that run out
/// in 12 to 24 hours.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.kind,
    required this.url,
    this.thumb,
    this.poster,
    this.width,
    this.height,
    this.durationMs,
    this.hidden = false,
  });

  static MediaItem? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String) return null;
    return MediaItem(
      id: json['id'] as String,
      kind: json['kind'] as String? ?? 'image',
      url: json['url'] as String? ?? '',
      thumb: json['thumb'] as String?,
      poster: json['poster'] as String?,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      hidden: json['hidden'] == true,
    );
  }

  final String id;

  /// image, clip or voice.
  final String kind;
  final String url;
  final String? thumb;
  final String? poster;
  final int? width;
  final int? height;
  final int? durationMs;

  /// Hidden by a moderator: only its owner still gets it.
  final bool hidden;

  bool get clip => kind == 'clip';

  /// The still a list shows: the thumbnail, a clip's poster, else the file.
  String get still => thumb ?? poster ?? url;
}

/// The game a post is from, with its names by language.
class PostGame {
  const PostGame({required this.titleId, this.names = const {}, this.iconUrl});

  static PostGame? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['titleId'] is! String) return null;
    final names = json['names'];
    return PostGame(
      titleId: json['titleId'] as String,
      names: {
        if (names is Map)
          for (final entry in names.entries)
            if (entry.value is String) '${entry.key}': entry.value as String,
      },
      iconUrl: json['iconUrl'] as String?,
    );
  }

  final String titleId;
  final Map<String, String> names;
  final String? iconUrl;

  /// Its name in [language] (or English, or any), else the title ID.
  String name(String language) => names[language] ?? names['en'] ?? names.values.firstOrNull ?? titleId;
}

/// A post as the reader may see it (PostView).
class Post {
  const Post({
    required this.id,
    required this.author,
    required this.media,
    required this.createdAt,
    this.caption,
    this.game,
    this.visibility = PostVisibility.friends,
    this.commentsOff = false,
    this.likes = 0,
    this.liked = false,
    this.comments = 0,
    this.mine = false,
    this.source,
  });

  factory Post.fromJson(Map<String, dynamic> json) => Post(
    id: json['id'] as String,
    author: Person.fromJson(json['author'] as Map<String, dynamic>),
    caption: json['caption'] as String?,
    game: PostGame.fromJson(json['game']),
    // A visibility this launcher does not know yet reads as the narrower one.
    visibility: json['visibility'] == 'public' ? PostVisibility.public : PostVisibility.friends,
    commentsOff: json['commentsOff'] == true,
    media: [for (final item in json['media'] as List<dynamic>? ?? const []) ?MediaItem.fromJson(item)],
    likes: (json['likes'] as num?)?.toInt() ?? 0,
    liked: json['liked'] == true,
    comments: (json['comments'] as num?)?.toInt() ?? 0,
    mine: json['mine'] == true,
    source: json['source'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String id;
  final Person author;
  final String? caption;
  final PostGame? game;
  final PostVisibility visibility;
  final bool commentsOff;
  final List<MediaItem> media;
  final int likes;
  final bool liked;

  /// Comments and replies the reader may see.
  final int comments;

  /// The reader wrote it: they may delete it.
  final bool mine;

  /// launcher, phone, web or null.
  final String? source;
  final DateTime createdAt;

  /// The clip, when the post is one.
  MediaItem? get clip => media.where((item) => item.clip).firstOrNull;

  /// What is shown: everything but what a moderator hid (which only the owner still gets).
  List<MediaItem> get shown => [
    for (final item in media)
      if (!item.hidden) item,
  ];

  Post copyWith({int? likes, bool? liked, int? comments}) => Post(
    id: id,
    author: author,
    caption: caption,
    game: game,
    visibility: visibility,
    commentsOff: commentsOff,
    media: media,
    likes: likes ?? this.likes,
    liked: liked ?? this.liked,
    comments: comments ?? this.comments,
    mine: mine,
    source: source,
    createdAt: createdAt,
  );
}

/// A comment (CommentView): top-level ones carry their replies, oldest first, one level deep.
class PostComment {
  const PostComment({
    required this.id,
    required this.postId,
    required this.author,
    required this.text,
    required this.createdAt,
    this.replyTo,
    this.canDelete = false,
    this.replies = const [],
  });

  factory PostComment.fromJson(Map<String, dynamic> json) => PostComment(
    id: json['id'] as String,
    postId: json['postId'] as String,
    author: Person.fromJson(json['author'] as Map<String, dynamic>),
    text: json['text'] as String? ?? '',
    replyTo: json['replyTo'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    canDelete: json['canDelete'] == true,
    replies: [
      for (final reply in json['replies'] as List<dynamic>? ?? const [])
        if (reply is Map<String, dynamic>) PostComment.fromJson(reply),
    ],
  );

  final String id;
  final String postId;
  final Person author;
  final String text;

  /// The top-level comment this answers; null for a top-level one.
  final String? replyTo;
  final DateTime createdAt;

  /// The reader may delete it: its author, or the post's.
  final bool canDelete;
  final List<PostComment> replies;

  PostComment withReplies(List<PostComment> next) => PostComment(
    id: id,
    postId: postId,
    author: author,
    text: text,
    replyTo: replyTo,
    createdAt: createdAt,
    canDelete: canDelete,
    replies: next,
  );
}

/// A post being written in the gallery: its caption, who sees it and the game it is from.
class PostDraft {
  PostDraft({this.caption = '', this.visibility = PostVisibility.friends, this.titleId, this.commentsOff = false});

  String caption;
  PostVisibility visibility;

  /// The game the capture is from; sent only when it is a title ID the server takes.
  String? titleId;
  bool commentsOff;

  static const source = 'launcher';

  /// The caption as it goes: trimmed, at most 500 characters, nothing when empty.
  String? get sentCaption {
    final trimmed = String.fromCharCodes(caption.trim().runes.take(PostLimits.caption));
    return trimmed.isEmpty ? null : trimmed;
  }

  /// PPSA01234: four capitals and five digits.
  static bool isTitleId(String text) => RegExp(r'^[A-Z]{4}[0-9]{5}$').hasMatch(text);

  /// POST /posts. The visibility is always sent, so the choice made here is the one kept.
  Map<String, dynamic> body(List<String> media) => {
    'media': media,
    'visibility': visibility.name,
    'source': source,
    'caption': ?sentCaption,
    if (titleId case final String id when isTitleId(id)) 'titleId': id,
    if (commentsOff) 'commentsOff': true,
  };
}

/// Why AnyTogether refused something about a post or a comment, for the launcher to say in words.
enum PostRefusal {
  commentsOff,
  linkBlocked,
  accountMuted,
  family,
  familyFriends,
  rateLimited,
  storageDisabled,
  clipTooLong,
  badMedia,
  quotaFull,
  tooBig,

  /// The post or comment is gone, or the reader may no longer see it.
  gone;

  static PostRefusal? of(Object error) {
    if (error is! TogetherProblem) return null;
    return switch (error.code) {
      'comments_off' => commentsOff,
      'link_blocked' => linkBlocked,
      'account_muted' => accountMuted,
      'restricted_by_family' => error.extra['feature'] == 'profile_visibility' ? familyFriends : family,
      'rate_limited' => rateLimited,
      'storage_disabled' => storageDisabled,
      'bad_media' || 'bad_image' => error.extra['maxMs'] != null ? clipTooLong : badMedia,
      'quota_exceeded' => quotaFull,
      'payload_too_large' => tooBig,
      'not_found' => gone,
      _ => error.status == 404 ? gone : null,
    };
  }
}

/// The Captures feed as the launcher holds it: newest first (IDs are time-ordered UUIDv7s), one
/// post per ID.
class CapturesFeed {
  List<Post> items = const [];
  String? next;
  bool loaded = false;

  /// The first page, in place of whatever was read before.
  void load(List<Post> page, String? next) {
    items = const [];
    loaded = true;
    this.next = next;
    page.forEach(upsert);
  }

  /// An older page, after what is there.
  void loadOlder(List<Post> page, String? next) {
    this.next = next;
    page.forEach(upsert);
  }

  /// A new or changed post: it replaces the one with its ID, or goes in at its place.
  void upsert(Post post) {
    final at = indexOf(post.id);
    if (at >= 0) {
      items = [...items]..[at] = post;
      return;
    }
    final place = items.indexWhere((other) => other.id.compareTo(post.id) < 0);
    items = [...items]..insert(place < 0 ? items.length : place, post);
  }

  void remove(String id) => items = [
    for (final post in items)
      if (post.id != id) post,
  ];

  int indexOf(String id) => items.indexWhere((post) => post.id == id);

  /// Likes or takes the like back at once; the likes as they were, to put back on a failure.
  (int, bool)? toggleLike(String id) {
    final at = indexOf(id);
    if (at < 0) return null;
    final post = items[at];
    items = [...items]
      ..[at] = post.copyWith(liked: !post.liked, likes: (post.likes + (post.liked ? -1 : 1)).clamp(0, 1 << 30));
    return (post.likes, post.liked);
  }

  void setLikes(String id, int likes, bool liked) {
    final at = indexOf(id);
    if (at >= 0) items = [...items]..[at] = items[at].copyWith(likes: likes, liked: liked);
  }

  /// Comments added (or, negative, deleted) under a post.
  void addComments(String id, int delta) {
    final at = indexOf(id);
    if (at < 0) return;
    items = [...items]..[at] = items[at].copyWith(comments: (items[at].comments + delta).clamp(0, 1 << 30));
  }
}

/// One line of the comments sheet: a top-level comment or a reply under one.
class CommentLine {
  const CommentLine(this.comment, this.parent);
  final PostComment comment;

  /// The top-level comment a reply is under; null for a top-level one.
  final String? parent;
  bool get isReply => parent != null;
}

/// A post's comments as the comments sheet holds them: top-level newest first, each with its
/// replies oldest first, read a page at a time.
class CommentThread {
  CommentThread(this.postId);

  final String postId;
  List<PostComment> items = const [];
  String? next;
  bool loaded = false;

  void load(List<PostComment> page, String? next) {
    items = page;
    this.next = next;
    loaded = true;
  }

  void loadOlder(List<PostComment> page, String? next) {
    final have = {for (final comment in items) comment.id};
    items = [
      ...items,
      for (final comment in page)
        if (!have.contains(comment.id)) comment,
    ];
    this.next = next;
  }

  /// A comment just made: a top-level one first, a reply last under the one it answers.
  void add(PostComment comment) {
    final parent = comment.replyTo;
    if (parent != null) {
      final at = items.indexWhere((top) => top.id == parent);
      if (at < 0 || items[at].replies.any((reply) => reply.id == comment.id)) return;
      items = [...items]..[at] = items[at].withReplies([...items[at].replies, comment]);
    } else if (!items.any((top) => top.id == comment.id)) {
      items = [comment, ...items];
    }
  }

  /// Takes a comment out (a top-level one with its replies); how many went.
  int remove(String id) {
    final at = items.indexWhere((top) => top.id == id);
    if (at >= 0) {
      final gone = items[at];
      items = [...items]..removeAt(at);
      return 1 + gone.replies.length;
    }
    for (var index = 0; index < items.length; index++) {
      final replies = items[index].replies;
      if (replies.any((reply) => reply.id == id)) {
        items = [...items]
          ..[index] = items[index].withReplies([
            for (final reply in replies)
              if (reply.id != id) reply,
          ]);
        return 1;
      }
    }
    return 0;
  }

  /// The sheet's lines in order: each top-level comment, then its replies.
  List<CommentLine> get lines => [
    for (final comment in items) ...[
      CommentLine(comment, null),
      for (final reply in comment.replies) CommentLine(reply, comment.id),
    ],
  ];

  PostComment? comment(String id) => lines.where((line) => line.comment.id == id).firstOrNull?.comment;
}

/// The API for posts, as the Mac's TogetherClient extension calls it.
class Posts {
  const Posts(this.account);

  final TogetherAccount account;

  static String _paging(String? before, int? limit) {
    final query = [if (before != null) 'before=${Uri.encodeQueryComponent(before)}', if (limit != null) 'limit=$limit'];
    return query.isEmpty ? '' : '?${query.join('&')}';
  }

  static String _path(String id) => Uri.encodeComponent(id);

  /// Makes a post of media already uploaded; the post as the server keeps it.
  Future<Post> create(List<String> media, PostDraft draft) async =>
      Post.fromJson(await account.call('POST', 'posts', draft.body(media)));

  /// The Captures feed: one's own posts, friends' and public ones of people one played with.
  Future<(List<Post>, String?)> captures({String? before, int? limit}) async {
    final page = await account.call('GET', 'me/captures${_paging(before, limit)}');
    return (
      [
        for (final item in page['items'] as List<dynamic>? ?? const [])
          if (item is Map<String, dynamic>) Post.fromJson(item),
      ],
      page['next'] as String?,
    );
  }

  /// Likes a post, or takes the like back; its likes as they are now.
  Future<(int, bool)> setLiked(bool liked, String id) async {
    final answer = await account.call(liked ? 'PUT' : 'DELETE', 'posts/${_path(id)}/like');
    return ((answer['likes'] as num?)?.toInt() ?? 0, answer['liked'] == true);
  }

  Future<(List<PostComment>, String?)> comments(String post, {String? before, int? limit}) async {
    final page = await account.call('GET', 'posts/${_path(post)}/comments${_paging(before, limit)}');
    return (
      [
        for (final item in page['items'] as List<dynamic>? ?? const [])
          if (item is Map<String, dynamic>) PostComment.fromJson(item),
      ],
      page['next'] as String?,
    );
  }

  /// A comment, or a reply to a top-level one.
  Future<PostComment> comment(String post, String text, {String? replyTo}) async => PostComment.fromJson(
    await account.call('POST', 'posts/${_path(post)}/comments', {
      'text': String.fromCharCodes(text.trim().runes.take(PostLimits.comment)),
      'replyTo': ?replyTo,
    }),
  );

  Future<void> deleteComment(String id, String post) =>
      account.call('DELETE', 'posts/${_path(post)}/comments/${_path(id)}');

  Future<void> delete(String id) => account.call('DELETE', 'posts/${_path(id)}');
}
