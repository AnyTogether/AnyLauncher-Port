import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'online_wire.dart';

/// Who an AnyTogether user is to a game: the same account number and virtual address on every
/// computer and in every session, worked out from the user ID alone, so no server has to hand
/// them out and every launcher in a session agrees without asking (the Mac launcher's
/// OnlineIdentity, the same numbers).
abstract final class OnlineIdentity {
  /// The platform's longest online ID.
  static const onlineIdLength = 16;

  /// The first 8 bytes of SHA-256 of the user ID, never 0 (0 means "nobody" to a game). Above
  /// 2^63 it is negative as a Dart int; [OnlineWire.unsigned] writes it as the platform does.
  static int accountId(String userId) {
    final bytes = _digest(userId);
    var number = 0;
    for (var index = 0; index < 8; index++) {
      number = (number << 8) | bytes[index];
    }
    return number == 0 ? 1 : number;
  }

  /// The account number as games see it in JSON (unsigned decimal).
  static String account(String userId) => OnlineWire.unsigned(accountId(userId));

  /// The handle cut to the platform's 16 letters ("player" for an empty one).
  static String onlineId(String handle) {
    final runes = handle.runes.take(onlineIdLength);
    final cut = String.fromCharCodes(runes);
    return cut.isEmpty ? 'player' : cut;
  }

  /// Each player's address in 198.18.0.0/15, from bytes 8 to 10 of the same digest. A last octet
  /// of 0 or 255 is skipped (some games treat them as network or broadcast addresses), and when
  /// two players land on one address the one with the smaller user ID keeps it and the other
  /// moves up, so the result depends only on who is in the session, not on join order: someone
  /// leaving never moves anyone else.
  static Map<String, int> addresses(Iterable<String> userIds) {
    final taken = <int>{};
    final result = <String, int>{};
    final sorted = userIds.toSet().toList()..sort(_byUtf8);
    const hostMask = ~OnlineWire.virtualMask & 0xFFFFFFFF;
    for (final userId in sorted) {
      final bytes = _digest(userId);
      var host = ((bytes[8] << 16) | (bytes[9] << 8) | bytes[10]) & hostMask;
      while (true) {
        host &= hostMask;
        final low = host & 0xFF;
        if (low != 0 && low != 0xFF && !taken.contains(host)) break;
        host += 1;
      }
      taken.add(host);
      result[userId] = OnlineWire.virtualNetwork | host;
    }
    return result;
  }

  /// Swift sorts strings by Unicode scalars; for the IDs AnyTogether gives (UUIDs, ASCII) that is
  /// byte order, which this keeps for any text.
  static int _byUtf8(String left, String right) {
    final a = utf8.encode(left);
    final b = utf8.encode(right);
    for (var index = 0; index < a.length && index < b.length; index++) {
      if (a[index] != b[index]) return a[index] - b[index];
    }
    return a.length - b.length;
  }

  /// Whether [left] sorts before [right] the way every launcher compares user IDs (who offers).
  static bool before(String left, String right) => _byUtf8(left, right) < 0;

  static List<int> _digest(String userId) => sha256.convert(utf8.encode(userId)).bytes;

  /// "198.18.0.2".
  static String dotted(int address) =>
      '${(address >> 24) & 0xFF}.${(address >> 16) & 0xFF}.${(address >> 8) & 0xFF}.${address & 0xFF}';
}
