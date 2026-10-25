import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

import 'release_keys.dart';

/// Signed releases, as AnyPS5-ARM publishes them (docs/dev/SIGNED_UPDATES.md there): a release
/// carries SHA256SUMS (the sha256 of each of its files) and SHA256SUMS.sig (Ed25519 signatures of
/// SHA256SUMS by the release keys, tools/release/sign.sh). The launcher trusts the keys built into
/// it ([releaseKeys]), checks the signature, then each download against the sums.
abstract final class ReleaseSigning {
  static const sumsName = 'SHA256SUMS';
  static const signatureName = 'SHA256SUMS.sig';

  /// The sums and their signature are a few lines; anything larger is not them.
  static const largestFile = 1 << 20;

  /// The keys built into this launcher: the current release key and, during a rotation, the
  /// next one.
  static final List<ReleaseKey> trustedKeys = keysFrom(releaseKeys);

  /// The keys of release-signing.pub's lines, `ed25519 <base64> <name>`; other lines are skipped.
  static List<ReleaseKey> keysFrom(String text) => [
    for (final line in const LineSplitter().convert(text))
      if (ReleaseKey.parse(line) case final ReleaseKey key) key,
  ];

  /// The first 16 hex digits of the sha256 of a raw public key, as SHA256SUMS.sig names it.
  static String keyId(List<int> raw) => sha256.convert(raw).toString().substring(0, 16);

  /// The files and digests of SHA256SUMS as shasum writes it: `<64 hex digits>  <name>` a line
  /// (a "*" before the name, binary mode, is allowed). Anything else in it is refused.
  static Map<String, String> parseSums(List<int> bytes) {
    if (bytes.length > largestFile) throw const SigningFailure('SHA256SUMS cannot be read');
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const SigningFailure('SHA256SUMS cannot be read');
    }
    final digests = <String, String>{};
    final line = RegExp(r'^([0-9A-Fa-f]{64}) [ *]?(.+)$');
    for (final raw in const LineSplitter().convert(text)) {
      if (raw.isEmpty) continue;
      final match = line.firstMatch(raw);
      if (match == null) throw const SigningFailure('SHA256SUMS has a line it cannot read');
      final name = match.group(2)!;
      if (name.contains('/') || name.contains(r'\') || name == '.' || name == '..' || digests.containsKey(name)) {
        throw const SigningFailure('SHA256SUMS names a file it cannot');
      }
      digests[name] = match.group(1)!.toLowerCase();
    }
    if (digests.isEmpty) throw const SigningFailure('SHA256SUMS lists no file');
    return digests;
  }

  /// Checks [signature] (SHA256SUMS.sig: `ed25519 <key ID> <base64 signature>` a line) over
  /// [sums] with [keys]; one good signature by one of them is enough.
  static SignedSums verify(List<int> sums, List<int> signature, {List<ReleaseKey>? keys}) {
    final trusted = keys ?? trustedKeys;
    if (signature.length > largestFile) throw const SigningFailure('SHA256SUMS.sig cannot be read');
    final String text;
    try {
      text = utf8.decode(signature);
    } on FormatException {
      throw const SigningFailure('SHA256SUMS.sig cannot be read');
    }
    final unknown = <String>[];
    var known = false;
    var seen = false;
    final message = Uint8List.fromList(sums);
    for (final line in const LineSplitter().convert(text)) {
      final fields = line.split(' ');
      if (fields.length != 3 || fields[0] != 'ed25519') continue;
      seen = true;
      final matching = trusted.where((key) => key.id == fields[1]).toList();
      if (matching.isEmpty) {
        unknown.add(fields[1]);
        continue;
      }
      known = true;
      final Uint8List bytes;
      try {
        bytes = base64.decode(fields[2]);
      } on FormatException {
        continue;
      }
      if (bytes.length != 64) continue;
      for (final key in matching) {
        if (key.verifies(bytes, message)) return SignedSums(parseSums(sums), signer: key.name);
      }
    }
    if (!seen) throw const SigningFailure('SHA256SUMS.sig holds no signature');
    if (!known) {
      throw SigningFailure('the release is signed with a key this launcher does not trust (${unknown.join(', ')})');
    }
    throw const SigningFailure("the release's signature does not match its SHA256SUMS");
  }

  /// The last AnyPS5-ARM release published before releases were signed: its files and older
  /// ones may still be used unsigned, with a warning and GitHub's sha256; every later release
  /// must be signed.
  static const lastUnsignedRelease = '0.2.16';

  /// How far files of a release ([version]: 0.2.17-arm, v0.1.3) can be trusted.
  static ReleaseTrust trust(String version, {required bool signed, String lastUnsigned = lastUnsignedRelease}) {
    if (signed) return ReleaseTrust.signed;
    return isAfter(version, lastUnsigned) ? ReleaseTrust.unsignedRefused : ReleaseTrust.unsignedOlder;
  }

  /// Whether [version] is numbered past [last]; a version that cannot be read counts as past it.
  static bool isAfter(String version, String last) {
    List<int>? numbers(String text) {
      final bare = text.startsWith('v') ? text.substring(1) : text;
      final head = RegExp(r'^[0-9.]*').firstMatch(bare)!.group(0)!;
      final parts = head.split('.');
      final values = parts.map(int.tryParse).toList();
      if (head.isEmpty || values.contains(null)) return null;
      return [...values.nonNulls, for (var index = values.length; index < 3; index++) 0];
    }

    final offered = numbers(version);
    final before = numbers(last);
    if (offered == null || before == null) return true;
    for (var index = 0; index < offered.length || index < before.length; index++) {
      final x = index < offered.length ? offered[index] : 0;
      final y = index < before.length ? before[index] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

/// How far the files of a release can be trusted.
enum ReleaseTrust {
  /// The release is signed: downloads are checked against its signed sums.
  signed,

  /// Published before signing began: only GitHub's sha256 checks it, and the launcher says so.
  unsignedOlder,

  /// Published after signing began but without a signature: refused.
  unsignedRefused,
}

class SigningFailure implements Exception {
  const SigningFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One trusted Ed25519 public key.
class ReleaseKey {
  ReleaseKey._(this.name, this.raw) : id = ReleaseSigning.keyId(raw);

  /// A key of [raw] (32 bytes), null when it is not one.
  static ReleaseKey? of(String name, List<int> raw) {
    if (raw.length != 32) return null;
    return ReleaseKey._(name, Uint8List.fromList(raw));
  }

  /// A release-signing.pub line, `ed25519 <base64> <name>`; null for any other line.
  static ReleaseKey? parse(String line) {
    final fields = line.trim().split(' ');
    if (fields.length != 3 || fields[0] != 'ed25519') return null;
    try {
      return of(fields[2], base64.decode(fields[1]));
    } on FormatException {
      return null;
    }
  }

  final String name;
  final String id;
  final Uint8List raw;

  bool verifies(Uint8List signature, Uint8List message) {
    try {
      return nacl.VerifyKey(raw).verify(signature: nacl.Signature(signature), message: message);
    } on Object {
      return false;
    }
  }
}

/// SHA256SUMS once its signature has been checked.
class SignedSums {
  const SignedSums(this.digests, {required this.signer});

  /// The sha256 (lower-case hex) of each file by its name.
  final Map<String, String> digests;

  /// The name of the key whose signature was good.
  final String signer;

  String? digestFor(String name) => digests[name];

  /// Fails unless [file] is the one the sums list as [name].
  Future<void> check(String file, String name) async {
    final expected = digests[name];
    if (expected == null) throw SigningFailure('the signed release does not list $name');
    final actual = (await sha256.bind(File(file).openRead()).first).toString();
    if (actual != expected) throw SigningFailure('$name does not match the signed release (sha256)');
  }
}
