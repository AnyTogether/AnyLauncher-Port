import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/family.dart';
import 'package:anyps5_desktop/core/together/sync.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_together.dart';
import '../support/family_signer.dart';
import '../support/fixtures.dart';

void main() {
  late FakeTogether server;
  late TogetherAccount account;
  late FamilyClient family;
  final signer = FamilySigner('server key');
  final issued = DateTime.utc(2026, 10, 26, 12);

  setUp(() async {
    server = await FakeTogether.start();
    server.me = {'id': 'u-kid', 'handle': 'kid', 'displayName': 'Kid'};
    account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
    await account.startEmail('kid@example.com');
    await account.verifyEmail('123456');
    family = FamilyClient(account);
  });

  tearDown(() async {
    account.close();
    await server.close();
  });

  test('the status, checked with the server\'s key from the JWKS', () async {
    server.answers['GET me/family/restrictions'] = (200, signer.response(FamilySigner.childStatus(issuedAt: issued)));
    server.answers['GET .well-known/jwks.json'] = (200, signer.jwks);
    final document = await family.fetch();
    expect(document.status.restricted, isTrue);
    expect(document.status.restrictions!.ageLimit, 12);
    expect(document.key, signer.publicKey);
    // Someone else's status is not this account's.
    server.answers['GET me/family/restrictions'] = (200, signer.response(FamilySigner.freeStatus(issuedAt: issued)));
    await expectLater(family.fetch(), throwsA(isA<FamilySignatureInvalid>()));
    final call = server.calls.firstWhere((call) => call.path == 'me/family/restrictions');
    expect(call.headers.value(HttpHeaders.authorizationHeader), startsWith('Bearer '));
  });

  test('a status the key does not sign is refused', () async {
    server.answers['GET me/family/restrictions'] = (
      200,
      FamilySigner('impostor').response(FamilySigner.childStatus(issuedAt: issued)),
    );
    server.answers['GET .well-known/jwks.json'] = (200, signer.jwks);
    await expectLater(family.fetch(), throwsA(isA<FamilySignatureInvalid>()));
    server.answers['GET me/family/restrictions'] = (200, {'restricted': false});
    await expectLater(family.fetch(), throwsA(isA<FamilySignatureInvalid>()));
  });

  test('asking a parent: more time, a game, a friend; and the limit reached', () async {
    server.answers['POST me/family/requests'] = (201, {'id': 'r-1', 'status': 'pending'});
    server.answers['POST me/family/limit-reached'] = (204, null);
    await family.askForTime(30, titleId: 'PPSA01234');
    await family.askToPlay('PPSA01234', name: 'Astro');
    await family.askToAddFriend('@ana ');
    await family.limitReached(titleId: 'PPSA01234');
    await family.limitReached(titleId: 'homebrew');
    final asked = [
      for (final call in server.calls)
        if (call.path.startsWith('me/family/')) [call.path, call.body],
    ];
    expect(asked, [
      [
        'me/family/requests',
        {'kind': 'more_time', 'minutes': 30, 'titleId': 'PPSA01234'},
      ],
      [
        'me/family/requests',
        {'kind': 'play_game', 'titleId': 'PPSA01234', 'name': 'Astro'},
      ],
      [
        'me/family/requests',
        {'kind': 'add_friend', 'handle': 'ana'},
      ],
      [
        'me/family/limit-reached',
        {'titleId': 'PPSA01234'},
      ],
      ['me/family/limit-reached', <String, dynamic>{}],
    ]);
    expect(() => family.askForTime(2), throwsArgumentError);
  });

  test('a family limit answered by any call names its feature', () async {
    server.answers['POST me/friends/requests'] = FakeTogether.problem(403, 'restricted_by_family');
    try {
      await account.call('POST', 'me/friends/requests', {'handle': 'ana'});
      fail('refused');
    } on TogetherProblem catch (problem) {
      expect(familyFeature(problem), isNull, reason: 'without a feature member');
    }
    server.answers['POST me/friends/requests'] = (
      403,
      {
        'type': 'about:blank',
        'status': 403,
        'code': 'restricted_by_family',
        'title': 'No',
        'feature': 'friend_requests',
      },
    );
    try {
      await account.call('POST', 'me/friends/requests', {'handle': 'ana'});
      fail('refused');
    } on TogetherProblem catch (problem) {
      expect(familyFeature(problem), 'friend_requests');
      expect(isFamilyRestriction(problem), isTrue);
    }
    expect(isFamilyRestriction(const TogetherProblem(403, 'forbidden', '')), isFalse);
  });

  test('the catalogue learns a game\'s age ratings, and again when they change', () async {
    final temp = temporaryFolder('family-sync');
    addTearDown(() => temp.deleteSync(recursive: true));
    final sync = TogetherSync(
      account: account,
      file: p.join(temp.path, 'outbox.json'),
      deviceName: 'Desk',
      platform: 'linux',
    );
    sync.recordSession(
      titleId: 'PPSA01001',
      gameName: 'Orbit Runner',
      startedAt: DateTime.utc(2026, 10, 24, 20),
      endedAt: DateTime.utc(2026, 10, 24, 21),
      ageLevels: {'default': 16, 'US': 13},
    );
    sync.teachGame(titleId: 'PPSA02002', gameName: 'Quiet Game');
    await sync.flush();
    expect(server.games['PPSA01001'], {
      'names': {'en': 'Orbit Runner'},
      'ageLevels': {'default': 16, 'US': 13},
    });
    expect(server.games['PPSA02002'], {
      'names': {'en': 'Quiet Game'},
    });
    server.games.clear();
    sync.teachGame(titleId: 'PPSA01001', gameName: 'Orbit Runner', ageLevels: {'default': 16, 'US': 13});
    await sync.flush();
    expect(server.games, isEmpty, reason: 'taught once');
    sync.teachGame(titleId: 'PPSA01001', gameName: 'Orbit Runner', ageLevels: {'default': 18});
    await sync.flush();
    expect(server.games['PPSA01001']!['ageLevels'], {'default': 18});
    // Kept on disk with the rest of the outbox.
    final again = TogetherSync(
      account: account,
      file: p.join(temp.path, 'outbox.json'),
      deviceName: 'Desk',
      platform: 'linux',
    );
    expect(again.gameAges['PPSA01001'], {'default': 18});
  });
}
