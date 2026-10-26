import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/profiles/profile_saves.dart';
import 'package:anyps5_desktop/core/profiles/profiles.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  late Directory temp;
  late String folder;
  const fresh = ExistingSetup(onboarded: false, name: 'Utku');

  setUp(() {
    temp = temporaryFolder('profiles');
    folder = p.join(temp.path, 'Profiles');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  group('the store', () {
    test('a first start has no profile and asks for a mode', () {
      final store = ProfileStore(folder, existing: fresh);
      expect(store.book.profiles, isEmpty);
      expect(store.launchScreen, const LaunchScreen.welcome());
      expect(File(store.file).existsSync(), isFalse, reason: 'nothing written until a profile is made');
    });

    test('profiles are added, renamed and kept for the next start', () {
      final store = ProfileStore(folder, existing: fresh);
      final first = store.add(name: '  Utku  ', mode: ProfileMode.offline);
      expect(first.name, 'Utku');
      expect(first.id, LauncherProfile.legacyId, reason: 'the first profile owns the saves from before profiles');
      expect(store.book.current, first.id);
      expect(store.book.legacyOwner, first.id);
      final second = store.add(name: 'Selin', mode: ProfileMode.online);
      expect(second.id, isNot(first.id));
      expect(second.color, isNot(first.color), reason: 'each profile gets its own colour');
      store.rename(second.id, 'Selin K.');
      final again = ProfileStore(folder, existing: fresh);
      expect(again.book.profiles.map((profile) => profile.name), ['Utku', 'Selin K.']);
      expect(again.book.profiles.map((profile) => profile.mode), [ProfileMode.offline, ProfileMode.online]);
      expect(again.book.current, first.id);
    });

    test('a name is never empty nor too long', () {
      final store = ProfileStore(folder, existing: fresh);
      expect(store.add(name: '   ', mode: ProfileMode.offline).name, 'Player');
      expect(store.add(name: 'a' * 60, mode: ProfileMode.offline).name.length, LauncherProfile.maxName);
    });

    test('one profile goes straight in; several, or Ask every time, show the picker', () {
      final store = ProfileStore(folder, existing: fresh);
      final first = store.add(name: 'Utku', mode: ProfileMode.offline);
      expect(store.launchScreen, LaunchScreen.home(first.id));
      store.setAskEveryTime(true);
      expect(store.launchScreen, const LaunchScreen.picker());
      store.setAskEveryTime(false);
      store.add(name: 'Selin', mode: ProfileMode.offline);
      expect(store.launchScreen, const LaunchScreen.picker());
    });

    test('the profile in use and the last one cannot be deleted', () {
      final store = ProfileStore(folder, existing: fresh);
      final first = store.add(name: 'Utku', mode: ProfileMode.offline);
      expect(() => store.remove(first.id), throwsA(ProfileRefusal.onlyProfile));
      final second = store.add(name: 'Selin', mode: ProfileMode.offline);
      expect(() => store.remove(first.id), throwsA(ProfileRefusal.inUse));
      store.remove(second.id);
      expect(store.book.profiles.map((profile) => profile.id), [first.id]);
    });

    test('settings, mode and account are each profile\'s own', () {
      final store = ProfileStore(folder, existing: fresh);
      final first = store.add(name: 'Utku', mode: ProfileMode.offline);
      final second = store.add(name: 'Selin', mode: ProfileMode.offline);
      store.setSettings(first.id, {'theme': 2});
      store.setMode(second.id, ProfileMode.online);
      store.setAccount(second.id, const ProfileAccount(userId: 'u2', handle: 'selin'));
      final again = ProfileStore(folder, existing: fresh);
      expect(again.profile(first.id)?.settings, {'theme': 2});
      expect(again.profile(second.id)?.settings, isNull);
      expect(again.profile(second.id)?.mode, ProfileMode.online);
      expect(again.profile(second.id)?.account?.handle, 'selin');
    });

    test('the picker shows the profile in use first', () {
      final store = ProfileStore(folder, existing: fresh);
      final first = store.add(name: 'Utku', mode: ProfileMode.offline);
      final second = store.add(name: 'Selin', mode: ProfileMode.online);
      store.select(second.id);
      expect(store.book.pickerOrder.map((profile) => profile.id), [second.id, first.id]);
    });
  });

  group('migration', () {
    test('an existing setup becomes the first profile without the welcome', () {
      final store = ProfileStore(folder, existing: const ExistingSetup(onboarded: true, name: 'Utku'));
      expect(store.book.profiles, hasLength(1));
      final profile = store.book.profiles.single;
      expect(profile.id, LauncherProfile.legacyId);
      expect(profile.mode, ProfileMode.offline);
      expect(store.launchScreen, LaunchScreen.home(profile.id));
      expect(store.migrated, isTrue);
      expect(File(store.file).existsSync(), isTrue, reason: 'written at once');
    });

    test('a session kept from before makes the migrated profile online, with its account', () {
      final store = ProfileStore(folder, existing: const ExistingSetup(onboarded: true, name: 'Utku'));
      store.adoptLegacySession(const TogetherUser(id: 'u1', handle: 'utku', displayName: 'Utku Halis'));
      final profile = ProfileStore(
        folder,
        existing: const ExistingSetup(onboarded: true, name: 'Utku'),
      ).book.profiles.single;
      expect(profile.mode, ProfileMode.online);
      expect(profile.account?.handle, 'utku');
      expect(profile.name, 'Utku Halis');
    });

    test('the migration runs once and a kept book wins', () {
      final store = ProfileStore(folder, existing: const ExistingSetup(onboarded: true, name: 'Utku'));
      store.add(name: 'Selin', mode: ProfileMode.offline);
      final again = ProfileStore(folder, existing: const ExistingSetup(onboarded: true, name: 'Utku'));
      expect(again.book.profiles, hasLength(2));
      expect(again.migrated, isFalse);
      again.adoptLegacySession(const TogetherUser(id: 'u1', handle: 'utku', displayName: 'Utku'));
      expect(
        again.book.profiles.first.mode,
        ProfileMode.offline,
        reason: 'only a profile just migrated takes the old session',
      );
    });

    test('a broken book file is not taken for a first start', () {
      Directory(folder).createSync(recursive: true);
      File(p.join(folder, 'profiles.json')).writeAsStringSync('{ not json');
      final store = ProfileStore(folder, existing: const ExistingSetup(onboarded: true, name: 'Utku'));
      expect(store.book.profiles, hasLength(1));
    });
  });

  group('switching', () {
    test('it waits for the game to close', () {
      final store = ProfileStore(folder, existing: fresh);
      final first = store.add(name: 'Utku', mode: ProfileMode.offline);
      final second = store.add(name: 'Selin', mode: ProfileMode.offline);
      ProfileRefusal? check(String id, {String? running, String? starting, bool syncing = false}) =>
          ProfileSwitch.check(id, store.book, running: running, starting: starting, syncing: syncing);
      expect(check(second.id, running: 'Neon Alley'), ProfileRefusal.gameRunning);
      expect(check(second.id, starting: 'Quiet Forest'), ProfileRefusal.gameRunning);
      expect(check(second.id, syncing: true), ProfileRefusal.syncing);
      expect(check('nobody'), ProfileRefusal.unknown);
      expect(check(first.id), ProfileRefusal.alreadyCurrent);
      expect(check(second.id), isNull);
      expect(ProfileSwitch.checkModeChange(running: 'Neon Alley'), ProfileRefusal.gameRunning);
      expect(ProfileSwitch.checkModeChange(), isNull);
    });

    test('personal settings come out of and go back into the settings', () {
      final personal = ProfileSettings.pick(
        {'theme', 'sounds', 'accent'},
        {'theme': 2, 'sounds': false, 'gamesFolder': '/Games'},
      );
      expect(personal, {'theme': 2, 'sounds': false});
      final merged = ProfileSettings.merge(
        personal,
        {'theme', 'sounds', 'accent'},
        {'theme': 0, 'sounds': true, 'accent': 'red', 'gamesFolder': '/Games'},
      );
      expect(merged['theme'], 2);
      expect(merged['sounds'], isFalse);
      expect(merged.containsKey('accent'), isFalse, reason: 'unset goes back to the default');
      expect(merged['gamesFolder'], '/Games');
    });
  });

  group('saves', () {
    late String game;
    String? read(String path) {
      final file = File(p.join(game, path));
      return file.existsSync() ? file.readAsStringSync() : null;
    }

    void write(String text, String path) {
      File(p.join(game, path))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);
    }

    setUp(() {
      game = p.join(temp.path, 'installed');
      write("utku's save", '_sd/slot/data.bin');
      write("utku's memory", '_sd_mem/u1/slot0.bin');
      write("utku's trophies", '_trophy/1_0.txt');
      write('the game', 'app0/eboot.bin');
    });

    test('saves from before profiles are the first profile\'s', () {
      expect(ProfileSaves.owner(game, legacyOwner: 'default'), 'default');
    });

    test('another profile starts with no saves and the first ones come back', () {
      ProfileSaves.activate('selin', game, legacyOwner: 'default');
      expect(read('_sd/slot/data.bin'), isNull);
      expect(read('_trophy/1_0.txt'), isNull);
      expect(read('app0/eboot.bin'), 'the game');
      write("selin's save", '_sd/slot/data.bin');
      ProfileSaves.activate('default', game, legacyOwner: 'default');
      expect(read('_sd/slot/data.bin'), "utku's save");
      expect(read('_sd_mem/u1/slot0.bin'), "utku's memory");
      expect(read('_trophy/1_0.txt'), "utku's trophies");
      ProfileSaves.activate('selin', game, legacyOwner: 'default');
      expect(read('_sd/slot/data.bin'), "selin's save");
    });

    test('a half-done swap is finished next time', () {
      final parked = ProfileSaves.parked('default', game);
      Directory(parked).createSync(recursive: true);
      for (final part in ProfileSaves.parts) {
        Directory(p.join(game, part)).renameSync(p.join(parked, part));
      }
      ProfileSaves.activate('default', game, legacyOwner: 'default');
      expect(read('_sd/slot/data.bin'), "utku's save");
    });

    test('removing a profile takes only its saves', () {
      ProfileSaves.activate('selin', game, legacyOwner: 'default');
      write("selin's save", '_sd/slot/data.bin');
      ProfileSaves.activate('default', game, legacyOwner: 'default');
      ProfileSaves.remove('selin', game, legacyOwner: 'default');
      expect(Directory(ProfileSaves.parked('selin', game)).existsSync(), isFalse);
      expect(read('_sd/slot/data.bin'), "utku's save");
    });

    test('the macOS launcher\'s layout: the same mark and parking folder', () {
      ProfileSaves.activate('selin', game, legacyOwner: 'default');
      expect(File(p.join(game, '.anyps5-profile')).readAsStringSync(), 'selin');
      expect(Directory(p.join(game, '_profiles', 'default', '_sd')).existsSync(), isTrue);
    });

    test('the parked saves move with the game when it is installed again', () {
      ProfileSaves.activate('selin', game, legacyOwner: 'default');
      final staged = p.join(temp.path, 'staged');
      Directory(staged).createSync();
      Installer.carryOver(game, staged);
      expect(File(p.join(staged, '_profiles', 'default', '_sd', 'slot', 'data.bin')).existsSync(), isTrue);
      expect(ProfileSaves.owner(staged, legacyOwner: 'default'), 'selin');
    });
  });

  test('the book is plain JSON', () {
    final store = ProfileStore(folder, existing: fresh);
    store.add(name: 'Utku', mode: ProfileMode.offline);
    final json = jsonDecode(File(store.file).readAsStringSync()) as Map<String, dynamic>;
    expect((json['profiles'] as List).single['name'], 'Utku');
  });
}
