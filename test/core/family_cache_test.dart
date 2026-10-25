import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/family/family_cache.dart';
import 'package:anyps5_desktop/core/family/family_policy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/family_signer.dart';
import '../support/fixtures.dart';

void main() {
  final signer = FamilySigner('server key');
  final other = FamilySigner('someone else');
  final issued = DateTime.utc(2026, 10, 26, 12);
  Map<String, Object?> child({DateTime? at}) => FamilySigner.childStatus(issuedAt: at ?? issued);

  group('the signed status', () {
    test('a good signature opens to the status in the family claim', () {
      final document = FamilyDocument.open(signer.sign(child()), signer.publicKey)!;
      expect(document.status.userId, 'u-kid');
      expect(document.status.restricted, isTrue);
      expect(document.status.restrictions!.ageLimit, 12);
      expect(document.status.issuedAt, issued);
    });

    test('the JWKS key: the Ed25519 one with kid 1', () {
      final key = FamilySignature.keyFromJwks({
        'keys': [
          {'kty': 'RSA', 'kid': '1', 'n': 'x'},
          signer.jwk,
        ],
      });
      expect(key, signer.publicKey);
      expect(FamilySignature.keyFromJwks({'keys': []}), isNull);
      expect(
        FamilySignature.keyFromJwks({
          'keys': [
            {...signer.jwk, 'x': 'c2hvcnQ'},
          ],
        }),
        isNull,
      );
      expect(FamilySignature.keyFromJwks('nonsense'), isNull);
    });

    test('anything changed, another key, another audience or algorithm: refused', () {
      final signed = signer.sign(child());
      final [header, payload, signature] = signed.split('.');
      final changed = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))) as Map<String, dynamic>;
      (changed['family'] as Map<String, dynamic>)['restricted'] = false;
      final forged = '$header.${base64Url.encode(utf8.encode(jsonEncode(changed))).replaceAll('=', '')}.$signature';
      expect(FamilyDocument.open(forged, signer.publicKey), isNull);
      expect(FamilyDocument.open(signed, other.publicKey), isNull);
      expect(FamilyDocument.open(signer.sign(child(), audience: 'anytogether'), signer.publicKey), isNull);
      expect(FamilyDocument.open(signer.sign(child(), algorithm: 'none'), signer.publicKey), isNull);
      expect(FamilyDocument.open(signer.sign(child(), subject: 'u-other'), signer.publicKey), isNull);
      expect(FamilyDocument.open('a.b', signer.publicKey), isNull);
      expect(FamilyDocument.open('$signed.extra', signer.publicKey), isNull);
    });

    test('an expired document still opens: old limits are kept, not dropped', () {
      final old = issued.subtract(const Duration(days: 40));
      expect(FamilyDocument.open(signer.sign(child(at: old), issuedAt: old), signer.publicKey), isNotNull);
    });
  });

  group('the cache on disk', () {
    late Directory folder;
    late FamilyCache cache;
    setUp(() {
      folder = temporaryFolder('family');
      cache = FamilyCache(p.join(folder.path, 'Together', 'family.json'));
    });
    tearDown(() => folder.deleteSync(recursive: true));

    test('nothing kept: no limits', () {
      expect(cache.load(), isA<FamilyCacheEmpty>());
    });

    test('kept and read back with the play since', () {
      final document = FamilyDocument.open(signer.sign(child()), signer.publicKey)!;
      final plays = [PlaySpan(issued, issued.add(const Duration(minutes: 20)), reported: false)];
      cache.save(FamilyCacheKept(document, server: 'https://together.example', plays: plays));
      final read = cache.load();
      expect(read, isA<FamilyCacheKept>());
      read as FamilyCacheKept;
      expect(read.document.signed, document.signed);
      expect(read.document.status.restrictions!.ageLimit, 12);
      expect(read.server, 'https://together.example');
      expect(read.plays.single.reported, isFalse);
      expect(read.plays.single.end, issued.add(const Duration(minutes: 20)));
    });

    test('a changed file is tampered: locked until a fresh status comes', () {
      final document = FamilyDocument.open(signer.sign(child()), signer.publicKey)!;
      cache.save(FamilyCacheKept(document, server: 'https://together.example'));
      final file = File(cache.file);
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      file.writeAsStringSync(jsonEncode({...json, 'signed': signer.sign(child()).replaceRange(40, 44, 'AAAA')}));
      expect(cache.load(), isA<FamilyCacheTampered>());
      file.writeAsStringSync(jsonEncode({...json, 'key': other.jwk['x']}));
      expect(cache.load(), isA<FamilyCacheTampered>());
      file.writeAsStringSync('{not json');
      expect(cache.load(), isA<FamilyCacheTampered>());
      file.writeAsStringSync(jsonEncode({'plays': []}));
      expect(cache.load(), isA<FamilyCacheTampered>());
    });
  });

  group('what replaces the kept status', () {
    final childDocument = FamilyDocument.open(signer.sign(child()), signer.publicKey)!;
    final free = FamilyDocument.open(
      signer.sign(FamilySigner.freeStatus(issuedAt: issued.add(const Duration(hours: 1))), subject: 'u-mum'),
      signer.publicKey,
    )!;
    const server = 'https://together.example';

    test('anything replaces nothing, a free status or a tampered file', () {
      expect(FamilyCache.mayReplace(const FamilyCacheEmpty(), free, server: server), isTrue);
      expect(FamilyCache.mayReplace(const FamilyCacheTampered(), free, server: server), isTrue);
      expect(FamilyCache.mayReplace(FamilyCacheKept(free, server: server), childDocument, server: 'https://x'), isTrue);
    });

    test('a child\'s limits are replaced only from the same server: a parent signing in there', () {
      final kept = FamilyCacheKept(childDocument, server: server);
      expect(FamilyCache.mayReplace(kept, free, server: server), isTrue);
      expect(FamilyCache.mayReplace(kept, free, server: 'https://my-own-server.example'), isFalse);
    });
  });
}
