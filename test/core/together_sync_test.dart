import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/sync.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_together.dart';
import '../support/fixtures.dart';

void main() {
  late FakeTogether server;
  late TogetherAccount account;
  late Directory temp;
  late String file;

  TogetherSync outbox() =>
      TogetherSync(account: account, file: file, deviceName: 'Desk', platform: 'windows', model: 'ThinkPad X1');

  SyncTrophySet orbit({DateTime? second}) => SyncTrophySet(
    titleId: 'PPSA01001',
    gameName: 'Orbit Runner',
    language: 'en',
    trophies: [
      SyncTrophy(
        id: 1,
        grade: 'bronze',
        hidden: false,
        name: 'Lift Off',
        detail: 'Start',
        earnedAt: DateTime.utc(2026, 10, 1),
      ),
      SyncTrophy(id: 2, grade: 'gold', hidden: true, name: 'Far Side', detail: '', earnedAt: second),
      SyncTrophy(id: SyncTrophy.idFor(1, 0), grade: 'silver', hidden: false, name: 'Extra', detail: 'DLC'),
    ],
  );

  setUp(() async {
    server = await FakeTogether.start();
    account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-windows/0.1.0');
    await account.startEmail('utku@example.com');
    await account.verifyEmail('123456');
    temp = temporaryFolder('sync');
    file = p.join(temp.path, 'Together', 'outbox.json');
  });

  tearDown(() async {
    account.close();
    await server.close();
    temp.deleteSync(recursive: true);
  });

  test('the set hash is the trophies and grades, as the macOS launcher makes it', () {
    final set = orbit();
    final shape = '1:bronze:false,2:gold:true,1000:silver:false';
    final expected = sha256
        .convert(utf8.encode(shape))
        .bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(set.setHash, expected);
    expect(set.setHash, hasLength(16));
    final turkish = SyncTrophySet(
      titleId: 'PPSA01001',
      gameName: 'Yörünge',
      language: 'tr',
      trophies: [
        for (final trophy in set.trophies.reversed)
          SyncTrophy(id: trophy.id, grade: trophy.grade, hidden: trophy.hidden, name: 'x', detail: 'y'),
      ],
    );
    expect(turkish.setHash, set.setHash, reason: 'the language and the order do not change it');
    expect(SyncTrophy.idFor(2, 17), 2017);
  });

  test('sends the computer, the game, the set, the session and the earned trophies, once', () async {
    final sync = outbox();
    sync.recordSession(
      titleId: 'PPSA01001',
      gameName: 'Orbit Runner',
      startedAt: DateTime.utc(2026, 10, 24, 20),
      endedAt: DateTime.utc(2026, 10, 24, 21),
    );
    sync.recordSession(
      titleId: 'PPSA01001',
      gameName: 'Orbit Runner',
      startedAt: DateTime.utc(2026, 10, 24, 22),
      endedAt: DateTime.utc(2026, 10, 24, 22, 0, 3),
    );
    sync.recordSession(
      titleId: 'homebrew',
      gameName: 'Mine',
      startedAt: DateTime.utc(2026),
      endedAt: DateTime.utc(2026, 2),
    );
    sync.recordTrophies(orbit());
    expect(sync.sessions, hasLength(1), reason: 'a few seconds and a title the server cannot take are no session');
    expect(sync.isEmpty, isFalse);
    await sync.flush();
    expect(sync.isEmpty, isTrue);

    final device = server.devices.values.single;
    expect(device, {'id': sync.deviceId, 'platform': 'windows', 'name': 'Desk', 'model': 'ThinkPad X1'});
    expect(server.games['PPSA01001'], {
      'names': {'en': 'Orbit Runner'},
    });
    final set = server.trophySets['PPSA01001/${orbit().setHash}']!;
    final trophies = set['trophies'] as List<dynamic>;
    expect(trophies[1], {
      'id': 2,
      'grade': 'gold',
      'hidden': true,
      'texts': {
        'en': {'name': 'Far Side'},
      },
    });
    expect(server.playSessions.values.single['deviceId'], sync.deviceId);
    expect(server.playSessions.values.single['exit'], 'normal');
    expect(server.earned.keys, ['PPSA01001/1']);

    // A trophy earned later goes up alone; nothing is sent twice.
    final calls = server.calls.length;
    sync.recordTrophies(orbit(second: DateTime.utc(2026, 10, 25)));
    await sync.flush();
    expect(server.earned.keys, ['PPSA01001/1', 'PPSA01001/2']);
    final sent = server.calls.sublist(calls).map((call) => call.path).toList();
    expect(sent, ['me/trophies']);
  });

  test('offline, everything waits on disk; the next start sends it', () async {
    server.answers['POST me/devices'] = FakeTogether.problem(503, 'unavailable');
    final sync = outbox();
    sync.recordSession(
      titleId: 'PPSA02002',
      gameName: 'Neon Alley',
      startedAt: DateTime.utc(2026, 10, 24, 20),
      endedAt: DateTime.utc(2026, 10, 24, 20, 30),
      exit: 'crashed',
    );
    sync.recordTrophies(orbit());
    await expectLater(sync.flush(), throwsA(isA<TogetherProblem>()));
    expect(server.playSessions, isEmpty);

    server.answers.clear();
    final next = outbox();
    expect(next.deviceId, sync.deviceId);
    expect(next.sessions, hasLength(1));
    await next.flush();
    expect(server.playSessions.values.single['exit'], 'crashed');
    expect(server.earned, hasLength(1));
    expect(outbox().isEmpty, isTrue);
  });

  test('a device the server forgot is registered again; a set it lost is taught again', () async {
    final sync = outbox();
    sync.recordTrophies(orbit());
    await sync.flush();
    server.devices.clear();
    server.trophySets.clear();
    sync.recordSession(
      titleId: 'PPSA01001',
      gameName: 'Orbit Runner',
      startedAt: DateTime.utc(2026, 10, 24, 20),
      endedAt: DateTime.utc(2026, 10, 24, 21),
    );
    sync.recordTrophies(orbit(second: DateTime.utc(2026, 10, 25)));
    await sync.flush();
    expect(sync.deviceRegistered, isFalse);
    expect(sync.sessions, hasLength(1), reason: 'kept for the unknown device');
    expect(sync.uploadedSets, isEmpty);
    await sync.flush();
    expect(server.devices, hasLength(1));
    expect(server.playSessions, hasLength(1));
    expect(server.earned.keys, contains('PPSA01001/2'));
    expect(sync.isEmpty, isTrue);
  });
}
