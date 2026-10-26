import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/online/online_identity.dart';
import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/online_play.dart';
import 'package:anyps5_desktop/core/online/online_web_router.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:test/test.dart';

import '../../support/online_fakes.dart';

/// Both ends of the bridge for real: the engine's NpManager, NpWebApi2, NetCtl and Net libraries
/// in its stand-in game (`online_probe`, built with the engine's tests) against this launcher's
/// own service, as the Mac launcher's OnlineEngineInteropTests and OnlineEngineP2pTests do.
/// Skipped unless ANYPS5_ONLINE_PROBE names the probe. Nothing here reaches a server: AnyTogether
/// is a fake, and the peer connections between the two launchers are in-process.
void main() {
  final probe = Platform.environment['ANYPS5_ONLINE_PROBE'];
  final skip = probe == null || probe.isEmpty ? 'ANYPS5_ONLINE_PROBE is not set' : false;
  const me = TogetherUser(id: '0190a0b1-0000-7000-8000-00000000000a', handle: 'alice', displayName: 'Alice');

  Future<Map<String, String>> run(
    Map<String, String> environment, {
    List<String> arguments = const [],
    Future<void> Function()? whileRunning,
  }) async {
    final clean = {
      for (final entry in Platform.environment.entries)
        if (!entry.key.startsWith('ANYPS5_')) entry.key: entry.value,
      ...environment,
    };
    final process = await Process.start(probe!, arguments, environment: clean, includeParentEnvironment: false);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    await whileRunning?.call();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    final text = await output;
    expect(code, 0, reason: '$text\n${await errors}');
    return {
      for (final line in const LineSplitter().convert(text))
        if (line.indexOf('=') case final at when at > 0) line.substring(0, at): line.substring(at + 1),
    };
  }

  test('a game signs in as the AnyTogether user and gets its friends', () async {
    final together = FakeOnlineTogether(friends: [('b-id', 'bob', 'online'), ('c-id', 'carol', 'offline')]);
    final play = OnlinePlay(
      call: together.call,
      user: me,
      game: const OnlineGame(titleId: 'PPSA00000', gameVersion: '01.000', engineBuild: 'x'),
      country: 'tr',
      language: 'tr',
    );
    final environment = await play.start();
    addTearDown(play.stop);
    final seen = await run(environment);
    expect(seen['state'], '2', reason: 'the game sees a signed-in user');
    expect(seen['online_id'], 'alice', reason: 'the online ID is the AnyTogether handle');
    expect(seen['account_id'], OnlineIdentity.account(me.id));
    expect(seen['country'], 'tr');
    expect(seen['friends_status'], '200');
    expect((jsonDecode(seen['friends_body']!) as Map)['friends'], [
      OnlineIdentity.account('b-id'),
      OnlineIdentity.account('c-id'),
    ], reason: 'the friends are the AnyTogether friends');
    expect(seen['profile_status'], '200');
    expect(seen['profile_body'], contains('"onlineId":"alice"'));
    expect(seen['tickets_error'], '0x80553406', reason: 'a group nobody offers fails as it does offline');
    expect(play.router.notOffered['matchmaking GET /v1/tickets'], 1);
    expect(together.calls.where((call) => call.$2 == 'me/friends'), hasLength(1));
  }, skip: skip);

  test('a game hosts a Player Session with a push context, as Human Fall Flat does', () async {
    final together = FakeOnlineTogether();
    final folder = Directory.systemTemp.createTempSync('online-host');
    addTearDown(() => folder.deleteSync(recursive: true));
    final log = OnlineHost.observationLog('PPSA02429', folder.path);
    final play = OnlinePlay(
      call: together.call,
      user: me,
      game: const OnlineGame(titleId: 'PPSA02429', gameVersion: '01.017', engineBuild: 'x'),
      observationLog: log,
    );
    final environment = await play.start();
    addTearDown(play.stop);
    final sessions = play.router.playerSessions!;
    final seen = await run(
      environment,
      arguments: ['host'],
      whileRunning: () async {
        expect(await eventually(() => sessions.sessionIds.isNotEmpty, timeout: const Duration(seconds: 20)), isTrue);
        expect(sessions.playerJoined(sessionId: sessions.sessionIds.first, account: 77, onlineId: 'bob'), isTrue);
      },
    );
    expect(seen['restriction_status'], '200', reason: 'the first restriction check is answered');
    expect(seen['blocks_status'], '200', reason: 'the first block list is answered');
    expect(seen['push_context_result'], '0x00000000', reason: 'a push context is made');
    final context = seen['push_context']!;
    expect(context, hasLength(36));
    expect(seen['create_status'], '200', reason: 'Host gets its Player Session');
    final sessionId = seen['session_id']!;
    expect(seen['get_status'], '200');
    expect(seen['patch_status'], '204');
    expect(seen['pushed_type'], 'psn:sessionManager:ps:m:players:created', reason: 'the news reaches the push context');
    expect(seen['pushed_context'], context);
    expect(seen['pushed_data'], contains(sessionId));
    expect(seen['leave_status'], '204');
    expect(seen['stale_leave_status'], '204', reason: 'leaving a session from an earlier lobby does not fail');
    expect(seen['after_status'], '200', reason: 'bob still plays in it');
    expect(seen['after_body'], contains('"leader":{"accountId":"77","platform":"PS5"}'), reason: 'and leads it');
    expect(play.router.notOffered, isEmpty);
    expect(together.calls, isEmpty);

    // The engine wrote the title's observation log, and sent each line to the launcher too.
    final lines = File(log).readAsLinesSync();
    expect(lines.any((line) => line.contains('sceNpWebApi2PushEventCreatePushContext') && line.contains(context)), isTrue);
    expect(lines.any((line) => line.contains('PushEventDelivered')), isTrue);
    expect(OnlineHost.lastLines(log, 5), hasLength(5));
    expect(play.observed, isNotEmpty);
  }, skip: skip);

  test('without the launcher the game stays signed out', () async {
    final seen = await run(const {});
    expect(seen['state'], '1');
    expect(seen['online_id_error'], '0x80550006');
    expect(seen['friends_error'], '0x80553406');
  }, skip: skip);

  /// Two engines (each probe its own process with its own bridge) behind two launchers, the mesh
  /// between them over in-process peer connections.
  Future<(List<Map<String, String>>, List<int>, OneSession)> twoLaunchers() async {
    final together = OneSession();
    final users = ['0190a0b1-0000-7000-8000-00000000000a', '0190a0b1-0000-7000-8000-00000000000b'];
    together
      ..add(users[0], 'dev-a')
      ..add(users[1], 'dev-b');
    final network = FakeGameNetwork();
    final environments = <Map<String, String>>[];
    final plays = <OnlinePlay>[];
    for (final (index, user) in users.indexed) {
      final play = OnlinePlay(
        call: together.call,
        user: TogetherUser(id: user, handle: index == 0 ? 'alice' : 'bob', displayName: user),
        game: const OnlineGame(titleId: 'PPSA00000', gameVersion: '01.000', engineBuild: 'mesh-test'),
        signal: together.relay(user, index == 0 ? 'dev-a' : 'dev-b'),
        transport: (context) => OnlinePeerMesh(context: context, links: network.links, iceServers: const []),
      );
      together.attach(user, play.receive);
      plays.add(play);
      environments.add(await play.start());
      addTearDown(play.stop);
    }
    for (final play in plays) {
      await play.follow(together.id);
    }
    final addresses = OnlineIdentity.addresses(users);
    return (environments, [addresses[users[0]]!, addresses[users[1]]!], together);
  }

  test('two games play peer to peer through two launchers', () async {
    final (environments, addresses, together) = await twoLaunchers();
    final (a, b) = (OnlineIdentity.dotted(addresses[0]), OnlineIdentity.dotted(addresses[1]));
    final pong = run(environments[1], arguments: ['p2p', a, 'pong']);
    final pinged = await run(environments[0], arguments: ['p2p', b, 'ping']);
    final ponged = await pong;
    expect(pinged['got'], 'pong', reason: '$pinged ${together.signals}');
    expect(pinged['from'], '$b:3658/1', reason: 'the answer comes from the other game\'s virtual address and ports');
    expect(ponged['got'], 'ping', reason: '$ponged');
    expect(ponged['from'], '$a:3658/1');
  }, skip: skip);

  test('a game\'s broadcast reaches the other game; the largest datagram crosses, a bigger one is refused', () async {
    final (environments, addresses, together) = await twoLaunchers();
    final (a, b) = (OnlineIdentity.dotted(addresses[0]), OnlineIdentity.dotted(addresses[1]));
    for (final (destination, size) in [('255.255.255.255', 65495), ('198.19.255.255', 4)]) {
      final pong = run(environments[1], arguments: ['udp', a, 'pong']);
      final pinged = await run(environments[0], arguments: ['udp', destination, 'ping', '$size']);
      final ponged = await pong;
      expect(pinged['oversize'], '0x80410128', reason: 'a datagram larger than UDP allows fails with EMSGSIZE: $pinged');
      expect(ponged['got'], 'ping', reason: '$destination: $ponged');
      expect(ponged['from'], '$a:3660', reason: 'the broadcast comes from the sender\'s virtual address');
      expect(ponged['size'], '$size');
      expect(pinged['got'], 'pong', reason: '$destination: $pinged ${together.signals}');
      expect(pinged['from'], '$b:3659');
      expect(pinged['size'], '$size');
    }
  }, skip: skip);
}
