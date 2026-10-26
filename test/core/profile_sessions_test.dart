import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/sync.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_together.dart';
import '../support/fixtures.dart';

/// Each profile's AnyTogether session in a store of its own: one never signs another in or out.
void main() {
  late Directory temp;
  setUp(() => temp = temporaryFolder('sessions'));
  tearDown(() => temp.deleteSync(recursive: true));

  SavedSession session(String user) => SavedSession(
    accessToken: 'access-$user',
    accessExpiry: DateTime.now().add(const Duration(minutes: 10)),
    refreshToken: 'refresh-$user',
    user: TogetherUser(id: user, handle: user, displayName: user),
  );

  test('the first profile keeps the store it had; the others get their own', () {
    final paths = AppPaths.forSystem(HostSystem.linux, environment: {'HOME': temp.path});
    final legacy = TokenStore.forProfile(paths, HostSystem.linux, 'default', legacy: true) as SecretServiceStore;
    final other = TokenStore.forProfile(paths, HostSystem.linux, 'p2', legacy: false) as SecretServiceStore;
    expect(legacy.fallback.file, p.join(paths.config, 'Together', 'session.json'), reason: 'no migration needed');
    expect(other.fallback.file, p.join(paths.config, 'Together', 'profiles', 'p2', 'session.json'));
    expect(other.attributes, containsAllInOrder(['profile', 'p2']));
    expect(legacy.attributes, isNot(contains('profile')), reason: 'the item from before profiles is still found');
    final windows = TokenStore.forProfile(paths, HostSystem.windows, 'p2', legacy: false) as FileTokenStore;
    expect(windows.file, endsWith(p.join('profiles', 'p2', 'session.bin')));
  });

  test('a Secret Service item per profile', () async {
    if (Platform.isWindows) return;
    final keyring = p.join(temp.path, 'keyring');
    Directory(keyring).createSync();
    final tool = p.join(temp.path, 'secret-tool');
    // Keeps one item per attribute list, as a keyring would.
    File(tool).writeAsStringSync('''#!/bin/sh
cmd="\$1"; shift
key=""
for a in "\$@"; do case "\$a" in --label=*) ;; *) key="\${key}_\$a" ;; esac; done
case "\$cmd" in
  store) cat > "$keyring/\$key" ;;
  lookup) [ -f "$keyring/\$key" ] && cat "$keyring/\$key" || exit 1 ;;
  clear) rm -f "$keyring/\$key" ;;
esac
''');
    Process.runSync('chmod', ['+x', tool]);
    final first = SecretServiceStore(fallback: FileTokenStore(p.join(temp.path, 'a.json')), tool: tool);
    final second = SecretServiceStore(fallback: FileTokenStore(p.join(temp.path, 'b.json')), tool: tool, profile: 'p2');
    await first.save(session('utku'));
    await second.save(session('selin'));
    expect((await first.load())?.user.handle, 'utku');
    expect((await second.load())?.user.handle, 'selin');
    await second.save(null);
    expect(await second.load(), isNull);
    expect((await first.load())?.user.handle, 'utku', reason: 'forgetting one keeps the other');
  });

  group('switching the account between profiles', () {
    late FakeTogether server;
    late ProfileTokenStore store;
    late TogetherAccount account;
    final stores = {'default': MemoryTokenStore(), 'p2': MemoryTokenStore()};

    setUp(() async {
      server = await FakeTogether.start();
      stores['default'] = MemoryTokenStore(session('utku'));
      stores['p2'] = MemoryTokenStore();
      store = ProfileTokenStore(stores['default']!);
      account = TogetherAccount(base: server.base, store: store, clientName: 'launcher-linux/test');
      await account.restore();
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('a switch keeps each session where it is', () async {
      expect(account.user?.handle, 'utku');
      account.detach();
      expect(account.user, isNull);
      expect(stores['default']!.session?.user.handle, 'utku', reason: 'detaching ends nothing');
      store.use(stores['p2']!);
      await account.restore();
      expect(account.user, isNull, reason: 'the second profile has no session yet');
      await account.startEmail('selin@example.com');
      server.me = {'id': 'u2', 'handle': 'selin', 'displayName': 'Selin'};
      await account.verifyEmail(server.emailCode);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(stores['p2']!.session?.user.handle, 'selin');
      expect(stores['default']!.session?.user.handle, 'utku', reason: 'signing one in signs no other in');

      await account.signOut();
      expect(stores['p2']!.session, isNull);
      expect(stores['default']!.session?.user.handle, 'utku', reason: 'signing one out keeps the other');
      account.detach();
      store.use(stores['default']!);
      await account.restore();
      expect(account.user?.handle, 'utku');
    });
  });

  test('each profile has its own outbox', () {
    final account = TogetherAccount(base: Uri.parse('http://127.0.0.1:1'), store: MemoryTokenStore(), clientName: 'x');
    final first = p.join(temp.path, 'outbox.json');
    final sync = TogetherSync(account: account, file: first, deviceName: 'Desk', platform: 'linux');
    sync.recordSession(
      titleId: 'PPSA01001',
      gameName: 'Orbit Runner',
      startedAt: DateTime(2026, 10, 26, 10),
      endedAt: DateTime(2026, 10, 26, 11),
    );
    expect(sync.sessions, hasLength(1));
    sync.useFile(p.join(temp.path, 'profiles', 'p2', 'outbox.json'));
    expect(sync.sessions, isEmpty, reason: 'what one profile played is never sent as another\'s');
    sync.useFile(first);
    expect(sync.sessions, hasLength(1));
    account.close();
  });
}
