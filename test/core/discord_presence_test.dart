import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/discord_presence.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A Discord that answers in memory: READY to a handshake, an echo to a command.
class FakePipe implements DiscordPipe {
  FakePipe(this.frames, {this.ready = true});

  final List<(int, Map<String, dynamic>)> frames;
  final bool ready;
  final List<List<int>> _answers = [];
  bool closed = false;

  @override
  Future<bool> write(Uint8List frame) async {
    if (closed) return false;
    final (op, json) = DiscordFrame.decode(frame)!;
    frames.add((op, json as Map<String, dynamic>));
    if (op == 0 && !ready) return true;
    _answers.add(
      DiscordFrame.encode(1, utf8.encode(jsonEncode(op == 0 ? {'evt': 'READY'} : {'nonce': json['nonce']}))),
    );
    return true;
  }

  @override
  Future<List<int>?> read(Duration timeout) async => _answers.isEmpty ? null : _answers.removeAt(0);

  @override
  void close() => closed = true;
}

void main() {
  group('frames', () {
    test('an opcode and a length, little-endian, then the JSON', () {
      final frame = DiscordFrame.encode(1, utf8.encode('{"a":1}'));
      expect(frame.sublist(0, 8), [1, 0, 0, 0, 7, 0, 0, 0]);
      expect(DiscordFrame.decode(frame), isNotNull);
      final (op, json) = DiscordFrame.decode(frame)!;
      expect(op, 1);
      expect(json, {'a': 1});
      expect(DiscordFrame.lengthOf(frame), 15);
    });

    test('a short or long frame is not one', () {
      final frame = DiscordFrame.encode(0, utf8.encode('{}'));
      expect(DiscordFrame.decode(frame.sublist(0, 9)), isNull);
      expect(DiscordFrame.decode([...frame, 0]), isNull);
      expect(DiscordFrame.decode([1, 2, 3]), isNull);
    });
  });

  group('the games Discord knows', () {
    test('found by name or alias, whatever the case, accents and marks', () {
      final games = DiscordGames.fromJson(
        jsonEncode([
          {
            'id': '111',
            'name': 'Plants vs. Zombies: Replanted',
            'aliases': ['PvZ Replanted'],
          },
          {'id': '222', 'name': 'Pokémon Legends'},
          {'name': 'no id'},
        ]),
      );
      expect(games.applicationId('Plants vs. Zombies™: Replanted'), '111');
      expect(games.applicationId('pvz replanted'), '111');
      expect(games.applicationId('POKEMON LEGENDS'), '222');
      expect(games.applicationId('Orbit Runner'), isNull);
      expect(DiscordGames.fromJson('not json').isEmpty, isTrue);
    });

    test('the cached list at once; a fresh one only when the cache is a week old', () async {
      final folder = Directory.systemTemp.createTempSync('discord-games');
      addTearDown(() => folder.deleteSync(recursive: true));
      final cache = p.join(folder.path, 'cache', 'discord-games.json');
      final fetched = <Uri>[];
      final seen = <DiscordGames>[];
      Future<String?> fetch(Uri url) async {
        fetched.add(url);
        return jsonEncode([
          {'id': '9', 'name': 'Neon Alley', 'aliases': [], 'icon': 'dropped'},
        ]);
      }

      await DiscordGames.load(cacheFile: cache, fetch: fetch, update: seen.add);
      expect(fetched, [DiscordGames.source]);
      expect(seen.single.applicationId('Neon Alley'), '9');
      expect(File(cache).readAsStringSync(), isNot(contains('icon')), reason: 'only id, name and aliases are kept');

      seen.clear();
      await DiscordGames.load(cacheFile: cache, fetch: fetch, update: seen.add);
      expect(fetched, hasLength(1), reason: 'a fresh cache is enough');
      expect(seen.single.applicationId('Neon Alley'), '9');

      await DiscordGames.load(
        cacheFile: cache,
        fetch: fetch,
        update: seen.add,
        now: DateTime.now().add(const Duration(days: 8)),
      );
      expect(fetched, hasLength(2), reason: 'a week-old cache is read again from Discord');

      // No network: the cache stays.
      await DiscordGames.load(
        cacheFile: cache,
        fetch: (_) async => null,
        update: seen.add,
        now: DateTime.now().add(const Duration(days: 8)),
      );
      expect(File(cache).existsSync(), isTrue);
    });
  });

  group('the activity', () {
    final since = DateTime.utc(2026, 11, 1, 20);

    test('a game Discord does not know shows under AnyPS5, with the platform', () {
      final activity = DiscordActivity(
        system: HostSystem.linux,
        partyText: 'In a party',
        game: 'Orbit Runner',
        since: since,
      );
      expect(activity.json(knownGame: false), {
        'type': 0,
        'timestamps': {'start': since.millisecondsSinceEpoch ~/ 1000},
        'details': 'Orbit Runner',
        'state': 'AnyPS5 · Linux',
      });
    });

    test('a known game shows as itself, the launcher and the party under it', () {
      final activity = const DiscordActivity(
        system: HostSystem.windows,
        partyText: 'In a party',
        game: 'Neon Alley',
        party: DiscordParty(id: 'p1', size: 2, max: 8),
      );
      expect(activity.json(knownGame: true), {
        'type': 0,
        'details': 'AnyPS5 Launcher · Windows',
        'state': 'In a party',
        'party': {
          'id': 'p1',
          'size': [2, 8],
        },
      });
    });

    test('a party without a game; nothing to show is nothing', () {
      final activity = const DiscordActivity(
        system: HostSystem.linux,
        partyText: 'Partide',
        party: DiscordParty(id: 'p1', size: 0, max: 0),
      );
      expect(activity.json(knownGame: false)!['details'], 'Partide');
      expect(activity.json(knownGame: false)!['party'], {
        'id': 'p1',
        'size': [1, 1],
      });
      expect(const DiscordActivity(system: HostSystem.linux, partyText: '').json(knownGame: false), isNull);
    });

    test('buttons Discord would refuse are left out, two at most', () {
      final long = 'https://anytogether.net/${'x' * 600}';
      final activity = DiscordActivity(
        system: HostSystem.linux,
        partyText: '',
        game: 'Orbit Runner',
        buttons: [
          const DiscordButton('  ${'Join on AnyTogether, a long label'}  ', 'https://anytogether.net/join/K7QM3XPA'),
          const DiscordButton('Plain', 'http://anytogether.net/join/K7QM3XPA'),
          const DiscordButton('', 'https://anytogether.net/join/K7QM3XPA'),
          DiscordButton('Long', long),
          const DiscordButton('Second', 'https://anytogether.net/b'),
          const DiscordButton('Third', 'https://anytogether.net/c'),
        ],
      );
      expect(activity.json(knownGame: false)!['buttons'], [
        {'label': 'Join on AnyTogether, a long labe', 'url': 'https://anytogether.net/join/K7QM3XPA'},
        {'label': 'Second', 'url': 'https://anytogether.net/b'},
      ]);
    });

    test('the same activity is equal, so Discord is told only of changes', () {
      DiscordActivity make() => DiscordActivity(
        system: HostSystem.linux,
        partyText: 'In a party',
        game: 'Orbit Runner',
        since: since,
        buttons: const [DiscordButton('Join', 'https://anytogether.net/join/A')],
      );
      expect(make(), make());
      expect(
        make() == const DiscordActivity(system: HostSystem.linux, partyText: 'In a party', game: 'Orbit Runner'),
        isFalse,
      );
    });
  });

  group('the Join button', () {
    final now = DateTime.utc(2026, 11, 1, 20);
    final url = Uri.parse('https://anytogether.net/join/K7QM3XPA');

    test('a code that works is the button', () {
      final plan = DiscordJoinPlan.of(
        partyId: 'p1',
        codeUrl: url,
        codeExpires: now.add(const Duration(hours: 1)),
        leader: false,
        mayMake: false,
        now: now,
      );
      expect(plan, isA<DiscordJoinButton>().having((plan) => plan.url, 'url', url.toString()));
    });

    test('without one the leader gets one made, unless they stopped it', () {
      DiscordJoinPlan plan({required bool leader, required bool mayMake}) => DiscordJoinPlan.of(
        partyId: 'p1',
        codeUrl: url,
        codeExpires: now.subtract(const Duration(minutes: 1)),
        leader: leader,
        mayMake: mayMake,
        now: now,
      );
      expect(plan(leader: true, mayMake: true), isA<DiscordJoinMake>());
      expect(plan(leader: true, mayMake: false), isA<DiscordJoinNone>());
      expect(plan(leader: false, mayMake: true), isA<DiscordJoinNone>());
      expect(
        DiscordJoinPlan.of(partyId: null, codeUrl: url, codeExpires: null, leader: true, mayMake: true),
        isA<DiscordJoinNone>(),
      );
    });
  });

  group('the application', () {
    test("AnyPS5's own; ANYPS5_DISCORD_APP_ID puts another in its place, empty turns it off", () {
      expect(DiscordPresence.applicationIdFrom(const {}), DiscordPresence.anyps5ApplicationId);
      expect(DiscordPresence.applicationIdFrom(const {'ANYPS5_DISCORD_APP_ID': ' 42 '}), '42');
      expect(DiscordPresence.applicationIdFrom(const {'ANYPS5_DISCORD_APP_ID': ''}), '');
    });

    test('the sockets are looked for in the runtime folder, Flatpak and Snap, the temporary folder, /tmp', () {
      final paths = UnixDiscordPipe.socketPaths(const {'XDG_RUNTIME_DIR': '/run/user/1000', 'TMPDIR': '/tmp/'});
      expect(paths.first, '/run/user/1000/discord-ipc-0');
      expect(paths, contains('/run/user/1000/app/com.discordapp.Discord/discord-ipc-3'));
      expect(paths, contains('/run/user/1000/snap.discord/discord-ipc-0'));
      expect(paths.last, '/tmp/discord-ipc-9');
      expect(paths.where((path) => path == '/tmp/discord-ipc-0'), hasLength(1), reason: 'each folder once');
    });
  });

  group('talking to Discord', () {
    test('a handshake, SET_ACTIVITY, and a clear with a null activity', () async {
      final frames = <(int, Map<String, dynamic>)>[];
      final presence = DiscordPresence(applicationId: 'app', connect: () async => FakePipe(frames), pid: 77);
      await presence.show(const DiscordActivity(system: HostSystem.linux, partyText: '', game: 'Orbit Runner'));
      expect(frames[0].$1, 0);
      expect(frames[0].$2, {'v': 1, 'client_id': 'app'});
      expect(frames[1].$1, 1);
      expect(frames[1].$2['cmd'], 'SET_ACTIVITY');
      expect((frames[1].$2['args'] as Map)['pid'], 77);
      expect(((frames[1].$2['args'] as Map)['activity'] as Map)['details'], 'Orbit Runner');
      await presence.clear();
      expect(frames, hasLength(3), reason: 'the same connection');
      expect((frames[2].$2['args'] as Map)['activity'], isNull);
    });

    test('a known game shakes hands as its own application', () async {
      final frames = <(int, Map<String, dynamic>)>[];
      final pipes = <FakePipe>[];
      final presence = DiscordPresence(
        applicationId: 'app',
        connect: () async => FakePipe(frames)..let(pipes.add),
        games: DiscordGames({'neon alley': 'neon'}),
      );
      await presence.show(const DiscordActivity(system: HostSystem.linux, partyText: '', game: 'Orbit Runner'));
      await presence.show(const DiscordActivity(system: HostSystem.linux, partyText: '', game: 'Neon Alley'));
      expect(frames.where((frame) => frame.$1 == 0).map((frame) => frame.$2['client_id']), ['app', 'neon']);
      expect(pipes.first.closed, isTrue);
    });

    test('no Discord, or one that never says READY: nothing is sent and nothing hangs', () async {
      final none = DiscordPresence(applicationId: 'app', connect: () async => null);
      await none.show(const DiscordActivity(system: HostSystem.linux, partyText: '', game: 'Orbit Runner'));
      final frames = <(int, Map<String, dynamic>)>[];
      final silent = DiscordPresence(applicationId: 'app', connect: () async => FakePipe(frames, ready: false));
      await silent.show(const DiscordActivity(system: HostSystem.linux, partyText: '', game: 'Orbit Runner'));
      expect(frames.map((frame) => frame.$1), [0], reason: 'the handshake, then given up');
      final off = DiscordPresence(applicationId: '', connect: () async => FakePipe(frames));
      await off.show(const DiscordActivity(system: HostSystem.linux, partyText: '', game: 'Orbit Runner'));
      expect(frames, hasLength(1));
    });

    test('over a real Unix socket: handshake, activity, clear', () async {
      final folder = Directory.systemTemp.createTempSync('dipc');
      addTearDown(() => folder.deleteSync(recursive: true));
      final path = p.join(folder.path, 'discord-ipc-0');
      final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
      addTearDown(server.close);
      final received = <(int, Object?)>[];
      final got = StreamController<void>.broadcast();
      server.listen((client) {
        final buffer = <int>[];
        client.listen((data) {
          buffer.addAll(data);
          while (buffer.length >= 8 && buffer.length >= DiscordFrame.lengthOf(buffer)) {
            final length = DiscordFrame.lengthOf(buffer);
            final frame = DiscordFrame.decode(buffer.sublist(0, length))!;
            buffer.removeRange(0, length);
            received.add(frame);
            client.add(DiscordFrame.encode(1, utf8.encode(jsonEncode({'evt': frame.$1 == 0 ? 'READY' : null}))));
            got.add(null);
          }
        });
      });
      final presence = DiscordPresence(
        applicationId: 'app',
        connect: () => UnixDiscordPipe.connect([p.join(folder.path, 'discord-ipc-1'), path]),
      );
      await presence.show(const DiscordActivity(system: HostSystem.linux, partyText: '', game: 'Orbit Runner'));
      await presence.close();
      expect(received.map((frame) => frame.$1), [0, 1, 1]);
      expect((received[0].$2 as Map)['client_id'], 'app');
      final shown = ((received[1].$2 as Map)['args'] as Map)['activity'] as Map;
      expect(shown['details'], 'Orbit Runner');
      expect(shown['state'], 'AnyPS5 · Linux');
      expect(((received[2].$2 as Map)['args'] as Map)['activity'], isNull);
      await got.close();
    }, testOn: '!windows');
  });
}

extension<T> on T {
  T let(void Function(T) use) {
    use(this);
    return this;
  }
}
