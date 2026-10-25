import '../family/family_cache.dart';
import 'account.dart';
import 'friends.dart';

/// The status the server sent does not verify with its key: not applied.
class FamilySignatureInvalid implements Exception {
  const FamilySignatureInvalid();

  @override
  String toString() => 'The family status is not signed by the server';
}

/// The family side of AnyTogether for the launcher: the signed status it enforces, a child's
/// requests to the parents (more time, a game, a friend) and telling them the limit was reached.
class FamilyClient {
  FamilyClient(this.account);

  final TogetherAccount account;

  /// GET me/family/restrictions, verified with the key from the server's JWKS.
  Future<FamilyDocument> fetch() async {
    final response = await account.call('GET', 'me/family/restrictions');
    final key = FamilySignature.keyFromJwks(await account.call('GET', '.well-known/jwks.json'));
    final signed = response['signed'];
    final document = signed is String && key != null ? FamilyDocument.open(signed, key) : null;
    // Signed for the account asking, not a status kept from someone else.
    final me = account.user?.id;
    if (document == null || (me != null && document.status.userId != me)) throw const FamilySignatureInvalid();
    return document;
  }

  /// More time today (5 to 240 minutes), for the game being played if there is one.
  Future<void> askForTime(int minutes, {String? titleId, String? note}) {
    if (minutes < 5 || minutes > 240) throw ArgumentError.value(minutes, 'minutes', '5 to 240');
    return _ask({'kind': 'more_time', 'minutes': minutes, 'titleId': ?_title(titleId), 'note': ?_note(note)});
  }

  /// A game the age rating keeps from the child.
  Future<void> askToPlay(String titleId, {String? name, String? note}) => _ask({
    'kind': 'play_game',
    'titleId': titleId,
    if (name != null && name.trim().isNotEmpty)
      'name': name.trim().length > 200 ? name.trim().substring(0, 200) : name.trim(),
    'note': ?_note(note),
  });

  /// Someone the child wants as a friend, by handle.
  Future<void> askToAddFriend(String handle, {String? note}) =>
      _ask({'kind': 'add_friend', 'handle': Friends.clean(handle), 'note': ?_note(note)});

  /// Today's limit was reached (the server tells the parents once a day).
  Future<void> limitReached({String? titleId}) =>
      account.call('POST', 'me/family/limit-reached', {'titleId': ?_title(titleId)});

  Future<void> _ask(Map<String, dynamic> body) => account.call('POST', 'me/family/requests', body);

  static final _titleId = RegExp(r'^[A-Z]{4}[0-9]{5}$');

  static String? _title(String? titleId) => titleId != null && _titleId.hasMatch(titleId) ? titleId : null;

  static String? _note(String? note) {
    final trimmed = note?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
  }
}

/// Whether [error] is the server refusing something a parent's family settings do not allow.
bool isFamilyRestriction(Object error) =>
    error is TogetherProblem && error.status == 403 && error.code == 'restricted_by_family';

/// The family feature [error] was refused for (friend_requests, messages, voice_chat, share_play,
/// public_matchmaking, profile_visibility, discovery, communities, media_sharing, age_rating,
/// family), or null.
/// Whose family limit refused [error]: "self" (the asker's own) or "other" (the other person's,
/// such as a friend request to a restricted child); null when the server did not say.
String? familySide(Object error) {
  if (!isFamilyRestriction(error)) return null;
  final side = (error as TogetherProblem).extra['side'];
  return side is String ? side : null;
}

String? familyFeature(Object error) {
  if (!isFamilyRestriction(error)) return null;
  final feature = (error as TogetherProblem).extra['feature'];
  return feature is String && feature.isNotEmpty ? feature : null;
}
