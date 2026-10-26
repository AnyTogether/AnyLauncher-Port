import '../together/account.dart';
import 'online_identity.dart';
import 'online_json.dart';
import 'online_peer.dart';
import 'online_wire.dart';

/// The platform's `userProfile` web API group, answered from AnyTogether: the friends list, a
/// profile, basic presence and the block list. The shapes follow public community documentation
/// of the console network's web API and are unverified (the Mac launcher's OnlineUserProfile, the
/// same answers); they can be switched off with the router's other platform groups.
///
/// Account IDs are [OnlineIdentity.accountId] as unsigned decimal strings, as the platform writes
/// them in JSON. Friends are asked of AnyTogether at most every 30 s: games poll.
///
/// Games check that they may play with others before they go online: Human Fall Flat (PPSA02429)
/// asks for the block list (`GET /v1/users/me/blocks?offset=0&limit=0`) and, in the
/// `communicationRestrictionStatus` group, `GET /v3/users/<account>/communication/restriction/status`.
/// Nobody is blocked and nobody is restricted here.
class OnlineUserProfile {
  OnlineUserProfile({required this.call, required this.me, required this.language, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const group = 'userProfile';
  static const restrictionGroup = 'communicationRestrictionStatus';
  static const keepFriends = Duration(seconds: 30);
  static const pageLimit = 2000;

  final OnlineCall call;
  final TogetherUser me;
  final String language;
  final DateTime Function() _now;
  ({DateTime at, List<_Friend> list})? _friends;
  Future<List<_Friend>>? _asking;

  String get myAccount => OnlineIdentity.account(me.id);

  Future<WireWebReply> handle(WireWebRequest request) async {
    if (request.method.toUpperCase() != 'GET') return OnlineJson.problem(405, 'Only GET is offered');
    final (parts, query) = OnlineJson.split(request.path);
    if (parts.length < 3 || parts[0] != 'v1' || parts[1] != 'users') {
      return OnlineJson.problem(404, 'No such userProfile call');
    }
    try {
      final who = parts[2];
      final what = parts.length > 3 ? parts[3] : '';
      if (parts.length == 3 && who == 'basicPresences') {
        final wanted = (query['accountIds'] ?? '').split(',').where((id) => id.isNotEmpty);
        final people = await _everyone();
        return OnlineJson.reply(200, {
          'basicPresences': [
            for (final id in wanted)
              if (people[id] case final person?) _presence(id, person),
          ],
        });
      }
      if (parts.length != 4) return OnlineJson.problem(404, 'No such userProfile call');
      switch (what) {
        case 'friends':
          if (!_isMe(who)) return OnlineJson.problem(403, 'Only your own friends are offered');
          final list = [for (final friend in await _friendList()) OnlineIdentity.account(friend.userId)];
          final offset = _max(0, int.tryParse(query['offset'] ?? '') ?? 0);
          final limit = _min(pageLimit, _max(1, int.tryParse(query['limit'] ?? '') ?? pageLimit));
          final page = list.skip(offset).take(limit).toList();
          return OnlineJson.reply(200, {
            'friends': page,
            'totalItemCount': list.length,
            if (offset + page.length < list.length) 'nextOffset': offset + page.length,
            if (offset > 0) 'previousOffset': _max(0, offset - limit),
          });
        case 'profiles':
          final person = await _person(who);
          if (person == null) return OnlineJson.problem(404, 'No such user');
          return OnlineJson.reply(200, _profile(person, isMe: _isMe(who)));
        case 'basicPresences':
          final person = await _person(who);
          if (person == null) return OnlineJson.problem(404, 'No such user');
          return OnlineJson.reply(200, {'basicPresence': _presence(_isMe(who) ? myAccount : who, person)});
        case 'blocks':
          if (!_isMe(who)) return OnlineJson.problem(403, 'Only your own block list is offered');
          return OnlineJson.reply(200, {'blocks': <String>[], 'totalItemCount': 0});
        default:
          return OnlineJson.problem(404, 'No such userProfile call');
      }
    } on TogetherProblem catch (problem) {
      return OnlineJson.problem(problem.status, problem.title);
    } on Object {
      return OnlineJson.problem(502, 'AnyTogether could not be reached');
    }
  }

  /// The `communicationRestrictionStatus` group: our own account is never restricted.
  WireWebReply handleRestriction(WireWebRequest request) {
    if (request.method.toUpperCase() != 'GET') return OnlineJson.problem(405, 'Only GET is offered');
    final parts = OnlineJson.bare(request.path).split('/').where((part) => part.isNotEmpty).toList();
    if (parts.length != 6 ||
        parts[0] != 'v3' ||
        parts[1] != 'users' ||
        parts[3] != 'communication' ||
        parts[4] != 'restriction' ||
        parts[5] != 'status') {
      return OnlineJson.problem(404, 'No such communicationRestrictionStatus call');
    }
    if (!_isMe(parts[2])) return OnlineJson.problem(403, 'Only your own restriction status is offered');
    return OnlineJson.reply(200, {'restricted': false});
  }

  /// "me", "local_" and a user ID (the game's own user, as games write it) or our account number.
  bool _isMe(String who) => who == 'me' || who.startsWith('local_') || who == myAccount;

  Future<_Person?> _person(String who) async {
    if (_isMe(who)) return _Person(OnlineIdentity.onlineId(me.handle), online: true);
    return (await _everyone())[who];
  }

  /// Me and my friends by account number.
  Future<Map<String, _Person>> _everyone() async {
    final people = <String, _Person>{
      for (final friend in await _friendList())
        OnlineIdentity.account(friend.userId): _Person(OnlineIdentity.onlineId(friend.handle), online: friend.online),
    };
    people[myAccount] = _Person(OnlineIdentity.onlineId(me.handle), online: true);
    return people;
  }

  Future<List<_Friend>> _friendList() async {
    final time = _now();
    final kept = _friends;
    if (kept != null && time.difference(kept.at) < keepFriends) return kept.list;
    return _asking ??= () async {
      try {
        final json = await call('GET', 'me/friends');
        final list = [
          for (final friend in json['friends'] as List<dynamic>? ?? const [])
            if (friend is Map<String, dynamic> && friend['userId'] is String)
              _Friend(
                friend['userId'] as String,
                friend['handle'] as String? ?? '',
                online: ((friend['presence'] as Map<String, dynamic>?)?['state'] as String? ?? 'offline') != 'offline',
              ),
        ];
        _friends = (at: time, list: list);
        return list;
      } finally {
        _asking = null;
      }
    }();
  }

  Map<String, Object?> _profile(_Person person, {required bool isMe}) => {
    'onlineId': person.onlineId,
    'aboutMe': '',
    'avatars': <Object>[],
    'languages': isMe && language.isNotEmpty ? [language] : <String>[],
    'isPlus': false,
    'isOfficiallyVerified': false,
    'isMe': isMe,
  };

  Map<String, Object?> _presence(String account, _Person person) => {
    'accountId': account,
    'availability': person.online ? 'availableToPlay' : 'unavailable',
    'primaryPlatformInfo': {'onlineStatus': person.online ? 'online' : 'offline', if (person.online) 'platform': 'PS5'},
  };

  static int _max(int a, int b) => a > b ? a : b;
  static int _min(int a, int b) => a < b ? a : b;
}

class _Friend {
  const _Friend(this.userId, this.handle, {required this.online});

  final String userId;
  final String handle;
  final bool online;
}

class _Person {
  const _Person(this.onlineId, {required this.online});

  final String onlineId;
  final bool online;
}
