import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host.dart';
import 'e2ee.dart';
import 'token_store.dart';

/// Where this device keeps its end-to-end encryption secrets: as the session is kept
/// (token_store.dart), never sent anywhere. One item per AnyTogether user, so another account
/// signing in on the same launcher profile gets keys of its own and the two are not linked by a
/// device ID.
abstract class E2eeKeyStore {
  Future<DeviceSecrets?> load(String userId);

  Future<void> save(String userId, DeviceSecrets secrets);

  /// How they are kept: dpapi, secret-service, file or memory.
  String get kind;

  /// Windows: a file sealed with DPAPI for this Windows user (entropy of its own). Linux: the
  /// Secret Service through secret-tool, else a file only this user can read. The first launcher
  /// profile keeps them beside its session, every other profile in its own folder.
  static E2eeKeyStore forProfile(AppPaths paths, HostSystem system, String profile, {required bool legacy}) {
    final folder = legacy
        ? p.join(paths.config, 'Together', 'e2ee')
        : p.join(paths.config, 'Together', 'profiles', profile, 'e2ee');
    if (system == HostSystem.windows) {
      return FileE2eeKeyStore(folder, sealer: Platform.isWindows ? DpapiSealer(entropy: _entropy) : null);
    }
    return SecretServiceE2eeKeyStore(fallback: FileE2eeKeyStore(folder), profile: legacy ? null : profile);
  }

  static const _entropy = 'AnyPS5 AnyTogether E2EE device keys';

  /// A user ID as a file name: AnyTogether's are UUIDs; anything else is cut to safe letters.
  static String fileName(String userId) => userId.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');
}

/// Kept for this run only (tests, previews).
class MemoryE2eeKeyStore implements E2eeKeyStore {
  final Map<String, DeviceSecrets> kept = {};

  @override
  Future<DeviceSecrets?> load(String userId) async => kept[userId];

  @override
  Future<void> save(String userId, DeviceSecrets secrets) async => kept[userId] = secrets;

  @override
  String get kind => 'memory';
}

/// A file per user in [folder]: sealed with [sealer] (DPAPI) when there is one, else made
/// readable by this user only before anything is written.
class FileE2eeKeyStore implements E2eeKeyStore {
  FileE2eeKeyStore(this.folder, {this.sealer});

  final String folder;
  final Sealer? sealer;

  String fileOf(String userId) =>
      p.join(folder, '${E2eeKeyStore.fileName(userId)}${sealer == null ? '.json' : '.bin'}');

  @override
  String get kind => sealer == null ? 'file' : 'dpapi';

  @override
  Future<DeviceSecrets?> load(String userId) async {
    try {
      final bytes = File(fileOf(userId)).readAsBytesSync();
      final opened = sealer == null ? bytes : sealer!.open(bytes);
      if (opened == null) return null;
      return await DeviceSecrets.fromJson(jsonDecode(utf8.decode(opened)));
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(String userId, DeviceSecrets secrets) async {
    final bytes = utf8.encode(jsonEncode(secrets.toJson()));
    writePrivately(fileOf(userId), sealer == null ? bytes : sealer!.seal(bytes));
  }

  /// Forgets what was kept (the keyring took it over).
  void forget(String userId) {
    try {
      File(fileOf(userId)).deleteSync();
    } on FileSystemException {
      // Nothing kept.
    }
  }
}

/// The Secret Service through secret-tool (libsecret), with a file kept as [fallback] where
/// there is no secret-tool or no keyring answers.
class SecretServiceE2eeKeyStore implements E2eeKeyStore {
  SecretServiceE2eeKeyStore({required this.fallback, this.tool = 'secret-tool', this.profile});

  final FileE2eeKeyStore fallback;
  final String tool;

  /// The launcher profile whose items these are; null for the first one's.
  final String? profile;
  bool _usable = true;

  List<String> attributes(String userId) => [
    'application',
    'anyps5',
    'kind',
    'anytogether-e2ee-device',
    'user',
    userId,
    if (profile != null) ...['profile', profile!],
  ];

  @override
  String get kind => _usable ? 'secret-service' : fallback.kind;

  @override
  Future<DeviceSecrets?> load(String userId) async {
    if (_usable) {
      try {
        final result = await Process.run(tool, ['lookup', ...attributes(userId)]);
        if (result.exitCode == 0) {
          final secrets = await DeviceSecrets.fromJson(_json((result.stdout as String).trim()));
          if (secrets != null) return secrets;
        }
      } on ProcessException {
        _usable = false;
      }
    }
    return fallback.load(userId);
  }

  static Object? _json(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(String userId, DeviceSecrets secrets) async {
    if (_usable) {
      try {
        final process = await Process.start(tool, [
          'store',
          '--label=AnyPS5 AnyTogether encryption keys',
          ...attributes(userId),
        ]);
        try {
          process.stdin.write(jsonEncode(secrets.toJson()));
          await process.stdin.close();
        } on IOException {
          // The tool ended without reading: its exit code tells.
        }
        final drained = [process.stdout.drain<void>(), process.stderr.drain<void>()];
        // A keyring that asks to be unlocked waits for the user; one that never answers is given up.
        final code = await process.exitCode.timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
        await Future.wait(drained);
        if (code == 0) {
          // Kept by the keyring: no copy left on disk.
          fallback.forget(userId);
          return;
        }
        _usable = false;
      } on IOException {
        _usable = false;
      }
    }
    await fallback.save(userId, secrets);
  }
}

/// What this device remembers about encrypted conversations, per user: the devices it last saw
/// in each, whether it ever saw one encrypted, the safety number marked as compared, and a
/// devices-changed notice not dismissed yet. No secret, but nobody else's business: kept like
/// the keys' fallback file.
abstract class E2eeNotesStore {
  Future<Map<String, dynamic>> load(String userId);

  Future<void> save(String userId, Map<String, dynamic> notes);

  static E2eeNotesStore forProfile(AppPaths paths, String profile, {required bool legacy}) => FileE2eeNotesStore(
    legacy ? p.join(paths.config, 'Together', 'e2ee') : p.join(paths.config, 'Together', 'profiles', profile, 'e2ee'),
  );
}

class MemoryE2eeNotesStore implements E2eeNotesStore {
  final Map<String, Map<String, dynamic>> kept = {};

  @override
  Future<Map<String, dynamic>> load(String userId) async =>
      jsonDecode(jsonEncode(kept[userId] ?? const {})) as Map<String, dynamic>;

  @override
  Future<void> save(String userId, Map<String, dynamic> notes) async =>
      kept[userId] = jsonDecode(jsonEncode(notes)) as Map<String, dynamic>;
}

class FileE2eeNotesStore implements E2eeNotesStore {
  FileE2eeNotesStore(this.folder);

  final String folder;

  String fileOf(String userId) => p.join(folder, '${E2eeKeyStore.fileName(userId)}-conversations.json');

  @override
  Future<Map<String, dynamic>> load(String userId) async {
    try {
      final json = jsonDecode(File(fileOf(userId)).readAsStringSync());
      return json is Map<String, dynamic> ? json : {};
    } on Object {
      return {};
    }
  }

  @override
  Future<void> save(String userId, Map<String, dynamic> notes) async =>
      writePrivately(fileOf(userId), utf8.encode(jsonEncode(notes)));
}
