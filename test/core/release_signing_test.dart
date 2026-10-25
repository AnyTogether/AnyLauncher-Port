import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/signing.dart';

void main() {
  String? failure(Object? Function() body) {
    try {
      body();
    } on SigningFailure catch (error) {
      return error.message;
    }
    return null;
  }

  final current = SignShFixture.keys([SignShFixture.current]);

  test('a signature made by sign.sh (OpenSSL) checks out, and so do the files it lists', () async {
    final sums = ReleaseSigning.verify(SignShFixture.sums, utf8.encode(SignShFixture.byCurrent), keys: current);
    expect(sums.signer, 'key0');
    expect(sums.digestFor('AnyPS5-macOS.zip'), '8c4f364e8a663e1affcb5020608c70ef48b9582fc3fa123f5c89fcb8888ed4ec');
    final temp = temporaryFolder('signing');
    addTearDown(() => temp.deleteSync(recursive: true));
    final app = p.join(temp.path, 'download.zip');
    File(app).writeAsBytesSync(SignShFixture.app);
    await sums.check(app, 'AnyPS5-macOS.zip');
    final toolkit = p.join(temp.path, 'toolkit.zip');
    File(toolkit).writeAsBytesSync(SignShFixture.toolkit);
    await sums.check(toolkit, 'AnyPS5-toolkit-macos-0.2.17-arm.zip');
  });

  test('key IDs are the ones the scripts write', () {
    expect(SignShFixture.keys([SignShFixture.current, SignShFixture.next, SignShFixture.stray]).map((key) => key.id), [
      'c7095b742ad5c7a1',
      'a8e2582b8f333670',
      'f91ae443c133eeec',
    ]);
  });

  test('sign and check round trip', () {
    final key = TestReleaseKey('round trip');
    final sums = sumsOf({'AnyPS5-Desktop-Setup-0.1.3-x64.exe': utf8.encode('installer')});
    final signed = ReleaseSigning.verify(sums, utf8.encode(key.signatureLine(sums)), keys: [key.key]);
    expect(signed.digests.keys, ['AnyPS5-Desktop-Setup-0.1.3-x64.exe']);
  });

  test('a tampered file is refused', () async {
    final sums = ReleaseSigning.verify(SignShFixture.sums, utf8.encode(SignShFixture.byCurrent), keys: current);
    final temp = temporaryFolder('signing');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = p.join(temp.path, 'download.zip');
    File(file).writeAsStringSync('AnyPS5 0.2.17 with something else\n');
    await expectLater(
      sums.check(file, 'AnyPS5-macOS.zip'),
      throwsA(predicate((e) => '$e' == 'AnyPS5-macOS.zip does not match the signed release (sha256)')),
    );
    File(file).writeAsBytesSync(SignShFixture.app);
    await expectLater(
      sums.check(file, 'other.zip'),
      throwsA(predicate((e) => '$e' == 'the signed release does not list other.zip')),
    );
  });

  test('tampered sums are refused', () {
    final sums = [...SignShFixture.sums]..[0] = '9'.codeUnitAt(0);
    expect(
      failure(() => ReleaseSigning.verify(sums, utf8.encode(SignShFixture.byCurrent), keys: current)),
      "the release's signature does not match its SHA256SUMS",
    );
  });

  test('a signature by another key is refused', () {
    expect(
      failure(() => ReleaseSigning.verify(SignShFixture.sums, utf8.encode(SignShFixture.byStray), keys: current)),
      'the release is signed with a key this launcher does not trust (f91ae443c133eeec)',
    );
    final forged = 'ed25519 c7095b742ad5c7a1 ${SignShFixture.byStray.split(' ')[2]}';
    expect(
      failure(() => ReleaseSigning.verify(SignShFixture.sums, utf8.encode(forged), keys: current)),
      "the release's signature does not match its SHA256SUMS",
    );
  });

  test('a missing signature is refused', () {
    expect(
      failure(() => ReleaseSigning.verify(SignShFixture.sums, const [], keys: current)),
      'SHA256SUMS.sig holds no signature',
    );
    expect(
      failure(() => ReleaseSigning.verify(SignShFixture.sums, utf8.encode('not a signature\n'), keys: current)),
      'SHA256SUMS.sig holds no signature',
    );
  });

  test('rotation: a release signed by the current key brings the next one, which then signs alone', () {
    final both = '${SignShFixture.byCurrent}\n${SignShFixture.byNext}\n';
    expect(ReleaseSigning.verify(SignShFixture.sums, utf8.encode(both), keys: current).signer, 'key0');
    expect(failure(() => ReleaseSigning.verify(SignShFixture.sums, utf8.encode(SignShFixture.byNext), keys: current)), isNotNull);
    final updated = ReleaseSigning.keysFrom(
      '# comment\ned25519 ${SignShFixture.current} release-2026-10\ned25519 ${SignShFixture.next} next-2026-10\n',
    );
    expect(updated.map((key) => key.name), ['release-2026-10', 'next-2026-10']);
    expect(
      ReleaseSigning.verify(SignShFixture.sums, utf8.encode(SignShFixture.byNext), keys: updated).signer,
      'next-2026-10',
    );
    final retired = SignShFixture.keys([SignShFixture.next]);
    expect(failure(() => ReleaseSigning.verify(SignShFixture.sums, utf8.encode(SignShFixture.byCurrent), keys: retired)), isNotNull);
  });

  test('SHA256SUMS is read strictly', () {
    final hash = '0' * 64;
    expect(ReleaseSigning.parseSums(utf8.encode('$hash *a.zip\r\n${hash.toUpperCase()}  b.zip\n')), {'a.zip': hash, 'b.zip': hash});
    for (final bad in ['$hash  ../a.zip', '$hash  dir/a.zip', '$hash  a.zip\n$hash  a.zip', 'nothex  a.zip', '', '${hash}a.zip']) {
      expect(failure(() => ReleaseSigning.parseSums(utf8.encode(bad))), isNotNull, reason: bad);
    }
  });

  test('unsigned releases: older ones with a warning, later ones refused', () {
    expect(ReleaseSigning.trust('0.2.15-arm', signed: false), ReleaseTrust.unsignedOlder);
    expect(ReleaseSigning.trust('0.2.16-arm', signed: false), ReleaseTrust.unsignedOlder);
    expect(ReleaseSigning.trust('0.2.17-arm', signed: false), ReleaseTrust.unsignedRefused);
    expect(ReleaseSigning.trust('v0.2.17-arm-nightly.20261025.1', signed: false), ReleaseTrust.unsignedRefused);
    expect(ReleaseSigning.trust('nonsense', signed: false), ReleaseTrust.unsignedRefused);
    expect(ReleaseSigning.trust('0.2.15-arm', signed: true), ReleaseTrust.signed);
  });

  test('the built-in keys are the release keys', () {
    expect(ReleaseSigning.trustedKeys, isNotEmpty);
    final file = File('../anyps5/AnyPS5/tools/release/release-signing.pub');
    if (!file.existsSync()) return;
    expect(
      ReleaseSigning.trustedKeys.map((key) => key.raw),
      ReleaseSigning.keysFrom(file.readAsStringSync()).map((key) => key.raw),
    );
  });
}
