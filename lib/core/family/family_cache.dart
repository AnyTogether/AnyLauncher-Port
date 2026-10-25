import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pinenacl/ed25519.dart' as nacl;

import 'family_policy.dart';
import 'family_rules.dart';

/// The audience of AnyTogether's signed family documents.
const familyAudience = 'anytogether-family';

/// AnyTogether signs the family status (a compact JWS, EdDSA with Ed25519, kid "1") with the key it
/// lists in /.well-known/jwks.json, so the launcher can keep it offline without anyone changing it.
abstract final class FamilySignature {
  /// The raw Ed25519 public key in a JWKS: the OKP key with kid "1" (or the only OKP one).
  static Uint8List? keyFromJwks(Object? json, {String kid = '1'}) {
    if (json is! Map<String, dynamic> || json['keys'] is! List) return null;
    final keys = [
      for (final key in json['keys'] as List)
        if (key is Map<String, dynamic> && key['kty'] == 'OKP' && key['crv'] == 'Ed25519') key,
    ];
    final chosen = keys.where((key) => key['kid'] == kid).firstOrNull ?? (keys.length == 1 ? keys.single : null);
    final x = chosen?['x'];
    if (x is! String) return null;
    final raw = _base64(x);
    return raw != null && raw.length == 32 ? raw : null;
  }

  /// The payload of [jws] when [key] signed it with EdDSA, else null.
  static Map<String, dynamic>? verify(String jws, Uint8List key) {
    final parts = jws.split('.');
    if (parts.length != 3 || key.length != 32) return null;
    final header = _json(parts[0]);
    if (header == null || header['alg'] != 'EdDSA') return null;
    final signature = _base64(parts[2]);
    if (signature == null || signature.length != 64) return null;
    try {
      final good = nacl.VerifyKey(key).verify(
        signature: nacl.Signature(signature),
        message: Uint8List.fromList(ascii.encode('${parts[0]}.${parts[1]}')),
      );
      return good ? _json(parts[1]) : null;
    } on Object {
      return null;
    }
  }

  static Map<String, dynamic>? _json(String part) {
    final bytes = _base64(part);
    if (bytes == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List? _base64(String text) {
    if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(text)) return null;
    try {
      return base64Url.decode(base64Url.normalize(text));
    } on FormatException {
      return null;
    }
  }

  static String encodeKey(Uint8List key) => base64Url.encode(key).replaceAll('=', '');
}

/// A verified family document: the JWS as the server sent it, the key that signed it and the
/// status in its `family` claim.
class FamilyDocument {
  const FamilyDocument(this.signed, this.key, this.status);

  final String signed;
  final Uint8List key;
  final FamilyStatus status;

  /// The document when [key] signed [signed] for this audience and the status in it is about the
  /// subject; null otherwise. An expired one opens too: old limits are kept, not dropped.
  static FamilyDocument? open(String signed, Uint8List key) {
    final payload = FamilySignature.verify(signed, key);
    if (payload == null) return null;
    final audience = payload['aud'];
    final forUs = audience == familyAudience || (audience is List && audience.contains(familyAudience));
    if (!forUs) return null;
    final status = FamilyStatus.fromJson(payload['family']);
    if (status == null || payload['sub'] != status.userId) return null;
    return FamilyDocument(signed, key, status);
  }
}

/// What the family cache holds.
sealed class FamilyCacheRead {
  const FamilyCacheRead();
}

/// Nothing kept: no family limits are known on this computer.
class FamilyCacheEmpty extends FamilyCacheRead {
  const FamilyCacheEmpty();
}

/// The file is there but does not verify: someone changed it. No play until a fresh status.
class FamilyCacheTampered extends FamilyCacheRead {
  const FamilyCacheTampered();
}

/// The last verified status, the server it came from and the play on this computer since.
class FamilyCacheKept extends FamilyCacheRead {
  const FamilyCacheKept(this.document, {required this.server, this.plays = const []});

  final FamilyDocument document;
  final String server;
  final List<PlaySpan> plays;

  FamilyCacheKept withPlays(List<PlaySpan> next) => FamilyCacheKept(document, server: server, plays: next);
}

/// The last verified family status in the launcher's data folder, as the server signed it, with
/// the key; signing out keeps it (a parent signing in replaces it).
class FamilyCache {
  FamilyCache(this.file);

  final String file;

  static String defaultFile(String configFolder) => p.join(configFolder, 'Together', 'family.json');

  FamilyCacheRead load() {
    final String text;
    try {
      final handle = File(file);
      if (!handle.existsSync()) return const FamilyCacheEmpty();
      text = handle.readAsStringSync();
    } on FileSystemException {
      return const FamilyCacheTampered();
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return const FamilyCacheTampered();
      final signed = json['signed'];
      final key = json['key'] is String ? FamilySignature._base64(json['key'] as String) : null;
      if (signed is! String || key == null) return const FamilyCacheTampered();
      final document = FamilyDocument.open(signed, key);
      if (document == null) return const FamilyCacheTampered();
      return FamilyCacheKept(
        document,
        server: json['server'] is String ? json['server'] as String : '',
        plays: [for (final span in json['plays'] is List ? json['plays'] as List : const []) ?PlaySpan.fromJson(span)],
      );
    } on FormatException {
      return const FamilyCacheTampered();
    }
  }

  void save(FamilyCacheKept kept) {
    try {
      Directory(p.dirname(file)).createSync(recursive: true);
      final temporary = File('$file.tmp')
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'server': kept.server,
            'signed': kept.document.signed,
            'key': FamilySignature.encodeKey(kept.document.key),
            'plays': [for (final span in kept.plays) span.toJson()],
          }),
        );
      temporary.renameSync(file);
    } on FileSystemException {
      // Kept in memory for this run.
    }
  }

  /// Whether a fresh status from [server] replaces what is kept: always, unless a child's limits
  /// are kept from another server (a child cannot sign in to a server of their own to drop them).
  static bool mayReplace(FamilyCacheRead current, FamilyDocument fresh, {required String server}) => switch (current) {
    FamilyCacheKept(:final document, server: final kept) => !document.status.restricted || kept == server,
    _ => true,
  };
}
