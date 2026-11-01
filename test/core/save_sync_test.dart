import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anyps5_desktop/core/save_backup.dart';
import 'package:anyps5_desktop/core/save_sync.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/cloud_saves.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_cloud.dart';
import '../support/fixtures.dart';

void main() {
  late Directory root;
  setUp(() => root = temporaryFolder('sync'));
  tearDown(() => root.deleteSync(recursive: true));

  String game(String computer) => p.join(root.path, computer, 'game');
  String backups(String computer) => p.join(root.path, computer, 'Backups');

  void save(String text, {required String on, String slot = 'savedata0/save.dat', int bytes = 0}) {
    final file = File(p.join(game(on), '_sd', slot));
    file.parent.createSync(recursive: true);
    // Bytes that do not compress, for a zip of about [bytes].
    final random = Random(text.hashCode);
    file.writeAsBytesSync([...utf8.encode(text), 0, ...List.generate(bytes, (_) => random.nextInt(256))]);
  }

  String? read({required String on, String slot = 'savedata0/save.dat'}) {
    try {
      final bytes = File(p.join(game(on), '_sd', slot)).readAsBytesSync();
      return utf8.decode(bytes.takeWhile((byte) => byte != 0).toList());
    } on FileSystemException {
      return null;
    }
  }

  // The macOS launcher's SaveSyncTests: two computers sharing a sync folder.
  group('through a folder', () {
    String cloud() => SaveSync.folder(p.join(root.path, 'Cloud'), 'PPSA15065');
    SyncOutcome sync(String computer, int seconds) => SaveSync(
      game: game(computer),
      cloud: cloud(),
      backups: backups(computer),
      device: computer,
    ).sync(DateTime.utc(2023, 11, 14, 22, 13, 20).add(Duration(seconds: seconds)));

    test('the first computer puts its saves up', () {
      save('level 1', on: 'A');
      expect(sync('A', 0), isA<SyncUploaded>());
      expect(sync('A', 10), isA<SyncUnchanged>());
      final info = jsonDecode(File(p.join(cloud(), 'info.json')).readAsStringSync()) as Map<String, dynamic>;
      expect(info.keys.toSet(), {'date', 'digest', 'mac'}, reason: 'the Mac reads the same file');
      expect(info['mac'], 'A');
      expect(info['date'], '2023-11-14T22:13:20Z');
      expect(File(p.join(cloud(), 'saves.zip')).existsSync(), isTrue);
    });

    test('another computer takes them and plays on', () {
      save('level 1', on: 'A');
      sync('A', 0);
      expect(sync('B', 100), isA<SyncDownloaded>().having((outcome) => outcome.from, 'from', 'A'));
      expect(read(on: 'B'), 'level 1');
      save('level 2', on: 'B');
      expect(sync('B', 200), isA<SyncUploaded>());
      expect(sync('A', 300), isA<SyncDownloaded>().having((outcome) => outcome.from, 'from', 'B'));
      expect(read(on: 'A'), 'level 2');
    });

    test('saves played on both keep the newest and back up the other', () {
      save('level 1', on: 'A');
      sync('A', 0);
      sync('B', 10);
      save("A's level 2", on: 'A');
      sync('A', 20);
      // B played on without syncing in between, and later.
      sleep(const Duration(milliseconds: 1100));
      save("B's level 3", on: 'B');
      expect(sync('B', 30), isA<SyncUploaded>(), reason: "B's saves are newer");
      expect(SaveBackup.backups(p.join(cloud(), 'Older')), isNotEmpty);
      expect(sync('A', 40), isA<SyncDownloaded>());
      expect(read(on: 'A'), "B's level 3");
      expect(SaveBackup.backups(backups('A')), isNotEmpty);
    });

    test('a computer without saves just takes them', () {
      save('level 1', on: 'A');
      sync('A', 0);
      expect(sync('B', 5), isA<SyncDownloaded>());
      expect(SaveBackup.backups(backups('B')), isEmpty);
    });

    test('no saves anywhere is nothing to do', () {
      Directory(game('A')).createSync(recursive: true);
      expect(sync('A', 0), isA<SyncUnchanged>());
    });

    test('a profile after the first has its own folder and record', () {
      expect(
        SaveSync.folder('/sync', 'PPSA01001', profile: 'p2'),
        p.join('/sync', 'AnyPS5', 'Profiles', 'p2', 'Saves', 'PPSA01001'),
      );
      final sync = SaveSync(game: game('A'), cloud: cloud(), backups: backups('A'), device: 'A', profile: 'p2');
      expect(p.basename(sync.stateFile), 'anyps5-sync-p2.json');
    });

    test('an info.json that cannot be read is said', () {
      save('level 1', on: 'A');
      File(p.join(cloud(), 'info.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{');
      expect(() => sync('A', 0), throwsA(isA<SaveSyncFailure>()));
    });

    test('the digest is the Mac\'s: part, path from its slash, then the bytes', () {
      save('abc', on: 'A');
      // "_sd" + "/" + "/savedata0/save.dat" + "abc", as SaveSync.swift hashes it.
      final expected = sha256Hex([...utf8.encode('_sd//savedata0/save.databc'), 0]);
      expect(SaveSync.digest(game('A')), expected);
      expect(SaveSync.digest(game('nobody')), isNull);
    });

    test('iCloud Drive where iCloud for Windows set it up, nowhere else', () {
      final profile = Directory(p.join(root.path, 'User'))..createSync();
      expect(SaveSync.iCloudDrive({'USERPROFILE': profile.path}, windows: true), isNull);
      Directory(p.join(profile.path, 'iCloudDrive')).createSync();
      expect(SaveSync.iCloudDrive({'USERPROFILE': profile.path}, windows: true), p.join(profile.path, 'iCloudDrive'));
      expect(SaveSync.iCloudDrive({'USERPROFILE': profile.path}), isNull, reason: 'Linux has no iCloud Drive');
    });
  });

  // The macOS launcher's TogetherCloudSaveTests, on a pretend cloud.
  group('through AnyTogether', () {
    late FakeCloud cloud;
    late TogetherAccount account;
    late CloudStorage storage;

    setUp(() async {
      cloud = await FakeCloud.start();
      account = TogetherAccount(
        base: cloud.base,
        clientName: 'launcher-linux/test',
        store: MemoryTokenStore(
          SavedSession(
            accessToken: 'access',
            accessExpiry: DateTime.now().add(const Duration(hours: 1)),
            refreshToken: 'refresh',
            user: const TogetherUser(id: 'u1', handle: 'utku', displayName: 'Utku'),
          ),
        ),
      );
      await account.restore();
      storage = CloudStorage(account);
    });

    tearDown(() async {
      storage.close();
      account.close();
      await cloud.close();
    });

    Future<CloudOutcome> sync(
      String computer, {
      ConflictChoice choose = ConflictChoice.notNow,
      bool replace = false,
      List<SaveVersion?>? conflicts,
      List<SaveVersion?>? replaces,
    }) => TogetherCloudSave(
      storage: storage,
      game: game(computer),
      titleId: 'PPSA01001',
      backups: backups(computer),
      workspace: p.join(root.path, computer, 'CloudSaves', 'u1'),
      device: computer,
      conflict: (latest) async {
        conflicts?.add(latest);
        return choose;
      },
      replaceLatest: (latest) async {
        replaces?.add(latest);
        return replace;
      },
    ).sync();

    test('the server says whether it keeps files; a server without storage says no', () async {
      expect((await storage.info()).enabled, isTrue);
      cloud.enabled = false;
      expect((await storage.info()).enabled, isFalse);
      save('level 1', on: 'A');
      await expectLater(
        sync('A'),
        throwsA(isA<TogetherProblem>().having((p) => p.storageDisabled, 'disabled', isTrue)),
      );
    });

    test('the first computer uploads in parts and then has nothing to do', () async {
      save('level 1', on: 'A', bytes: 3000);
      expect(await sync('A'), isA<CloudUploaded>().having((outcome) => outcome.version, 'version', 1));
      expect(cloud.partsSent.toSet().length, greaterThanOrEqualTo(3));
      expect(cloud.slots.single.versions.single.device, 'A');
      expect(cloud.beginBodies.first['baseVersion'], 0);
      expect(cloud.beginBodies.first['slot'], TogetherCloudSave.slot);
      expect(await sync('A'), isA<CloudUnchanged>());
    });

    test('another computer takes the saves and plays on', () async {
      save('level 1', on: 'A', bytes: 2000);
      await sync('A');
      expect(await sync('B'), isA<CloudDownloaded>().having((outcome) => outcome.from, 'from', 'A'));
      expect(read(on: 'B'), 'level 1');
      save('level 2', on: 'B');
      expect(await sync('B'), isA<CloudUploaded>().having((outcome) => outcome.version, 'version', 2));
      expect(cloud.beginBodies.last['baseVersion'], 1);
      expect(await sync('A'), isA<CloudDownloaded>().having((outcome) => outcome.version, 'version', 2));
      expect(read(on: 'A'), 'level 2');
      expect(SaveBackup.backups(backups('A')), isNotEmpty);
    });

    test('an upload that stopped picks up where it was', () async {
      save('level 1', on: 'A', bytes: 4000);
      cloud.dropOnce.add(3);
      await expectLater(sync('A'), throwsA(isA<TogetherProblem>()));
      expect(cloud.uploads, hasLength(1), reason: 'the upload stays open');
      final before = cloud.partsSent.length;
      expect(await sync('A'), isA<CloudUploaded>());
      final resent = cloud.partsSent.skip(before).toList();
      expect(resent, isNot(contains(1)));
      expect(resent, contains(3));
      expect(cloud.beginBodies, hasLength(1));
    });

    test('played on both asks and keeps this computer\'s', () async {
      save('level 1', on: 'A');
      await sync('A');
      await sync('B');
      save("B's level 2", on: 'B');
      await sync('B');
      save("A's level 3", on: 'A');
      final conflicts = <SaveVersion?>[];
      final outcome = await sync('A', choose: ConflictChoice.keepThisComputer, conflicts: conflicts);
      expect(conflicts, hasLength(1));
      expect(conflicts.single?.device, 'B');
      expect(outcome, isA<CloudUploaded>().having((outcome) => outcome.version, 'version', 3));
      expect(cloud.beginBodies.last['baseVersion'], 2);
    });

    test('played on both can take the newer one', () async {
      save('level 1', on: 'A');
      await sync('A');
      await sync('B');
      save("B's level 2", on: 'B');
      await sync('B');
      save("A's level 3", on: 'A');
      expect(await sync('A', choose: ConflictChoice.takeCloud), isA<CloudDownloaded>());
      expect(read(on: 'A'), "B's level 2");
    });

    test('Not Now leaves both as they are', () async {
      save('level 1', on: 'A');
      await sync('A');
      cloud.put(utf8.encode('other'));
      save("A's level 2", on: 'A');
      expect(await sync('A'), isA<CloudSkipped>());
      expect(read(on: 'A'), "A's level 2");
      expect(cloud.slots.single.versions, hasLength(2));
    });

    test('a conflict at complete keeps the upload without sending it again', () async {
      save('level 1', on: 'A');
      await sync('A');
      save('level 2', on: 'A', bytes: 2000);
      cloud.beforeComplete = () => cloud.put(utf8.encode('from B'), device: 'B');
      final conflicts = <SaveVersion?>[];
      final before = cloud.partsSent.length;
      final outcome = await sync('A', choose: ConflictChoice.keepThisComputer, conflicts: conflicts);
      expect(conflicts, hasLength(1));
      expect(outcome, isA<CloudUploaded>().having((outcome) => outcome.version, 'version', 3));
      expect(cloud.completeBodies.last['baseVersion'], 2);
      final sent = cloud.partsSent.skip(before).toList();
      expect(sent.length, sent.toSet().length, reason: 'no part went twice');
    });

    test('a full cloud asks before replacing the newest', () async {
      save('level 1', on: 'A', bytes: 3000);
      await sync('A');
      cloud.quota = cloud.slots.single.versions.single.data.length + 500;
      save('level 2', on: 'A', bytes: 3000);
      final replaces = <SaveVersion?>[];
      await expectLater(
        sync('A', replaces: replaces),
        throwsA(isA<TogetherProblem>().having((p) => p.quotaExceeded && p.canReplace, 'replaceable', isTrue)),
      );
      expect(replaces, hasLength(1));
      expect(await sync('A', replace: true), isA<CloudUploaded>());
      expect(cloud.beginBodies.last['replaceLatest'], isTrue);
      expect(cloud.slots.single.versions, hasLength(1));
    });

    test('a full cloud with nothing to replace says so without asking', () async {
      cloud.quota = 100;
      save('level 1', on: 'A', bytes: 3000);
      final replaces = <SaveVersion?>[];
      await expectLater(
        sync('A', replaces: replaces),
        throwsA(isA<TogetherProblem>().having((p) => p.canReplace, 'replaceable', isFalse)),
      );
      expect(replaces, isEmpty);
    });

    test('a broken download goes on from where it stopped', () async {
      final random = Random(7);
      final version = cloud.put(List.generate(5000, (_) => random.nextInt(256)));
      final file = p.join(root.path, 'part.zip');
      File(file).writeAsBytesSync(version.data.sublist(0, 1200));
      await storage.download(version.id, file);
      expect(cloud.ranges, ['bytes=1200-']);
      expect(File(file).readAsBytesSync(), version.data);
    });

    test('an older version restored comes down', () async {
      save('level 1', on: 'A');
      await sync('A');
      save('level 2', on: 'A');
      await sync('A');
      final first = cloud.slots.single.versions.last;
      expect(first.number, 1);
      final restored = await storage.restore(first.id);
      expect(restored.version, 3);
      expect(await sync('A'), isA<CloudDownloaded>().having((outcome) => outcome.version, 'version', 3));
      expect(read(on: 'A'), 'level 1');
    });

    test('deleting a slot and a version', () async {
      final one = cloud.put(utf8.encode('one'));
      cloud.put(utf8.encode('two'));
      await storage.deleteVersion(one.id);
      expect(cloud.slots.single.versions, hasLength(1));
      final overview = await storage.overview();
      expect(overview.usage?.limit, cloud.quota);
      expect(overview.saves.single.titleId, 'PPSA01001');
      await storage.deleteSlot(cloud.slots.single.id);
      expect(cloud.slots, isEmpty);
    });

    test('the record is the Mac\'s: version, digest and the upload under way', () {
      const state = CloudState(
        version: 2,
        digest: 'abc',
        pending: CloudPending(uploadId: 'u', sha256: 's', size: 10, digest: 'd', baseVersion: 1, replaceLatest: false),
      );
      final json = state.toJson();
      expect(json.keys, ['version', 'digest', 'pending']);
      expect((json['pending'] as Map).keys, ['uploadId', 'sha256', 'size', 'digest', 'baseVersion', 'replaceLatest']);
      final back = CloudState.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(back.version, 2);
      expect(back.pending?.uploadId, 'u');
    });
  });
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
