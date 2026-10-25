import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

/// AnyTogether's family document signing for the tests: a compact JWS (EdDSA, kid "1") over the
/// status in the `family` claim, as the server's signDocument makes it, with a key made from a
/// seed.
class FamilySigner {
  FamilySigner(String seed)
    : signing = nacl.SigningKey.fromSeed(Uint8List.fromList(sha256.convert(utf8.encode(seed)).bytes));

  final nacl.SigningKey signing;

  Uint8List get publicKey => Uint8List.fromList(signing.verifyKey.asTypedList);

  /// The key as /.well-known/jwks.json lists it.
  Map<String, Object?> get jwk => {
    'kty': 'OKP',
    'crv': 'Ed25519',
    'x': _base64(publicKey),
    'alg': 'EdDSA',
    'use': 'sig',
    'kid': '1',
  };

  Map<String, Object?> get jwks => {
    'keys': [jwk],
  };

  String sign(
    Map<String, Object?> status, {
    String audience = 'anytogether-family',
    String algorithm = 'EdDSA',
    String? subject,
    DateTime? issuedAt,
  }) {
    final iat = (issuedAt ?? DateTime.parse(status['issuedAt'] as String)).millisecondsSinceEpoch ~/ 1000;
    final header = _base64(utf8.encode(jsonEncode({'alg': algorithm, 'kid': '1'})));
    final payload = _base64(
      utf8.encode(
        jsonEncode({
          'family': status,
          'sub': subject ?? status['userId'],
          'iss': 'https://together.example',
          'aud': audience,
          'iat': iat,
          'exp': iat + 30 * 86400,
        }),
      ),
    );
    final signature = signing.sign(Uint8List.fromList(utf8.encode('$header.$payload'))).signature;
    return '$header.$payload.${_base64(signature.asTypedList)}';
  }

  /// The whole answer of GET me/family/restrictions for [status].
  Map<String, Object?> response(Map<String, Object?> status) => {...status, 'signed': sign(status)};

  static String _base64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  /// A child with an age limit of 12 and [days] of play time (every other day: no limit).
  static Map<String, Object?> childStatus({
    required DateTime issuedAt,
    Map<String, Object?> days = const {},
    bool playTime = false,
    int played = 0,
    int bonus = 0,
    String whenLimitReached = 'close',
    String friendRequests = 'approved',
    String messages = 'friends',
    bool voiceChat = false,
  }) {
    final date = issuedAt.toUtc().toIso8601String().substring(0, 10);
    const names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    return {
      'userId': 'u-kid',
      'restricted': true,
      'familyId': 'f-1',
      'role': 'child',
      'restrictions': {
        'friendRequests': friendRequests,
        'messages': messages,
        'voiceChat': voiceChat,
        'sharePlay': false,
        'publicMatchmaking': false,
        'profileVisibility': 'friends',
        'discovery': false,
        'communities': false,
        'mediaSharing': false,
        'ageLimit': 12,
        'unknownAge': 'allow',
        'ageRegion': 'default',
        'allowedTitles': <String>[],
        'approvedContacts': <String>[],
        'playTime': {
          'enabled': playTime,
          'timeZone': 'UTC',
          'whenLimitReached': whenLimitReached,
          'graceMinutes': 3,
          'notifyParents': true,
          'days': {
            for (final day in names) day: {'limitMinutes': null, 'from': null, 'until': null},
            ...days,
          },
        },
      },
      'today': {
        'date': date,
        'weekday': names[issuedAt.toUtc().weekday - 1],
        'limitMinutes': null,
        'bonusMinutes': bonus,
        'playedSeconds': played,
        'from': null,
        'until': null,
        'remainingSeconds': null,
        'allowed': true,
        'reason': null,
      },
      'issuedAt': issuedAt.toUtc().toIso8601String(),
    };
  }

  static Map<String, Object?> freeStatus({required DateTime issuedAt, String userId = 'u-mum'}) => {
    'userId': userId,
    'restricted': false,
    'familyId': 'f-1',
    'role': 'manager',
    'restrictions': null,
    'today': null,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
  };
}
