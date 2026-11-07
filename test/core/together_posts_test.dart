import 'package:anyps5_desktop/core/capture/clip_tools.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/posts.dart';
import 'package:test/test.dart';

/// Captures' pieces, as the Mac launcher's TogetherPosts tests have them.
void main() {
  Map<String, dynamic> person(String id) => {'userId': id, 'handle': id, 'displayName': id.toUpperCase()};

  Post post(String id, {int likes = 0, bool liked = false, int comments = 0}) => Post.fromJson({
    'id': id,
    'author': person('ana'),
    'media': [
      {'id': 'm-$id', 'kind': 'image', 'url': 'https://x/m.png'},
    ],
    'likes': likes,
    'liked': liked,
    'comments': comments,
    'createdAt': '2026-11-07T10:00:00Z',
  });

  PostComment comment(String id, {String? replyTo, List<PostComment> replies = const []}) => PostComment(
    id: id,
    postId: 'p1',
    author: Person.fromJson(person('cem')),
    text: id,
    replyTo: replyTo,
    createdAt: DateTime.utc(2026, 11, 7),
    replies: replies,
  );

  test('a post reads what it may: an unknown visibility is the narrower one, hidden media is not shown', () {
    final read = Post.fromJson({
      'id': '01',
      'author': person('ana'),
      'visibility': 'everyone-later',
      'media': [
        {'id': 'a', 'kind': 'clip', 'url': 'https://x/a.mp4', 'poster': 'https://x/a.jpg', 'durationMs': 12000},
        {'id': 'b', 'kind': 'image', 'url': 'https://x/b.png', 'hidden': true},
      ],
      'createdAt': '2026-11-07T10:00:00Z',
      'game': {
        'titleId': 'PPSA01234',
        'names': {'en': 'Orbit Runner', 'tr': 'Yörünge'},
      },
    });
    expect(read.visibility, PostVisibility.friends);
    expect(read.clip?.id, 'a');
    expect(read.clip?.still, 'https://x/a.jpg');
    expect(read.shown.map((item) => item.id), ['a']);
    expect(read.game?.name('tr'), 'Yörünge');
    expect(read.game?.name('de'), 'Orbit Runner');
  });

  test('the feed keeps the newest first, one post per ID; likes at once and put back', () {
    final feed = CapturesFeed()..load([post('02'), post('01')], 'next');
    feed.upsert(post('03'));
    feed.upsert(post('015'));
    expect(feed.items.map((item) => item.id), ['03', '02', '015', '01']);
    feed.upsert(post('02', likes: 4));
    expect(feed.items[1].likes, 4);
    final before = feed.toggleLike('02');
    expect(before, (4, false));
    expect((feed.items[1].likes, feed.items[1].liked), (5, true));
    feed.setLikes('02', before!.$1, before.$2);
    expect((feed.items[1].likes, feed.items[1].liked), (4, false));
    feed.addComments('02', -3);
    expect(feed.items[1].comments, 0, reason: 'never below nothing');
    feed.remove('03');
    expect(feed.items.first.id, '02');
  });

  test('comments: a reply goes last under its comment; removing one takes its replies along', () {
    final thread = CommentThread('p1')
      ..load([
        comment('c2'),
        comment('c1', replies: [comment('r1', replyTo: 'c1')]),
      ], null);
    thread.add(comment('c3'));
    thread.add(comment('r2', replyTo: 'c1'));
    thread.add(comment('r2', replyTo: 'c1'));
    expect(thread.lines.map((line) => line.comment.id), ['c3', 'c2', 'c1', 'r1', 'r2']);
    expect(thread.lines.last.parent, 'c1');
    expect(thread.remove('r1'), 1);
    expect(thread.remove('c1'), 2);
    expect(thread.lines.map((line) => line.comment.id), ['c3', 'c2']);
  });

  test('a draft sends its visibility always, a trimmed caption, and a title ID only when it is one', () {
    final draft = PostDraft(caption: '  GG  ', visibility: PostVisibility.public, titleId: 'PPSA01234');
    expect(draft.body(['m1']), {
      'media': ['m1'],
      'visibility': 'public',
      'source': 'launcher',
      'caption': 'GG',
      'titleId': 'PPSA01234',
    });
    expect(PostDraft(caption: ' ', titleId: 'not-one').body(['m1']), {
      'media': ['m1'],
      'visibility': 'friends',
      'source': 'launcher',
    });
    expect(PostDraft(caption: 'x' * 600).sentCaption!.length, PostLimits.caption);
  });

  test('a clip a post cannot take is told apart from one only too big', () {
    expect(ClipCheck.check(durationMs: 60400, bytes: 10), isA<ClipFits>());
    expect(ClipCheck.check(durationMs: 61000, bytes: 10).blocks, isTrue);
    final big = ClipCheck.check(durationMs: 30000, bytes: 30 * 1024 * 1024);
    expect(big, isA<ClipTooBig>());
    expect(big.blocks, isFalse);
  });

  test('refusals in words: the codes the server sends', () {
    expect(PostRefusal.of(const TogetherProblem(403, 'comments_off', '')), PostRefusal.commentsOff);
    expect(
      PostRefusal.of(const TogetherProblem(403, 'restricted_by_family', '', extra: {'feature': 'profile_visibility'})),
      PostRefusal.familyFriends,
    );
    expect(
      PostRefusal.of(const TogetherProblem(400, 'bad_media', '', extra: {'maxMs': 60000})),
      PostRefusal.clipTooLong,
    );
    expect(PostRefusal.of(const TogetherProblem(404, 'whatever', '')), PostRefusal.gone);
    expect(PostRefusal.of(StateError('x')), isNull);
  });

  test('ffmpeg: a clip\'s length from what it says, and a bitrate that fits', () {
    expect(FfmpegClipTools.parseDuration('  Duration: 00:01:02.50, start: 0.000000, bitrate: 6000 kb/s'), 62500);
    expect(FfmpegClipTools.parseDuration('no such file'), isNull);
    final rate = FfmpegClipTools.videoBitrate(25 * 1024 * 1024, 60000);
    expect((rate + 96000) * 60 / 8, lessThan(25 * 1024 * 1024));
    expect(rate, greaterThan(2000000));
  });
}
