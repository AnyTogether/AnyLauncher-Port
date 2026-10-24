import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../host.dart';

/// Who is signed in to AnyTogether.
class TogetherUser {
  const TogetherUser({required this.id, required this.handle, required this.displayName, this.avatar});

  factory TogetherUser.fromJson(Map<String, dynamic> json) => TogetherUser(
    id: json['id'] as String,
    handle: json['handle'] as String,
    displayName: json['displayName'] as String,
    avatar: json['avatar'] as String?,
  );

  final String id;
  final String handle;
  final String displayName;
  final String? avatar;

  Map<String, Object?> toJson() => {'id': id, 'handle': handle, 'displayName': displayName, 'avatar': avatar};
}

/// The session kept between starts: the tokens and who they are for.
class SavedSession {
  const SavedSession({
    required this.accessToken,
    required this.accessExpiry,
    required this.refreshToken,
    required this.user,
  });

  factory SavedSession.fromJson(Map<String, dynamic> json) => SavedSession(
    accessToken: json['accessToken'] as String,
    accessExpiry: DateTime.parse(json['accessExpiry'] as String),
    refreshToken: json['refreshToken'] as String,
    user: TogetherUser.fromJson(json['user'] as Map<String, dynamic>),
  );

  final String accessToken;
  final DateTime accessExpiry;
  final String refreshToken;
  final TogetherUser user;

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'accessExpiry': accessExpiry.toUtc().toIso8601String(),
    'refreshToken': refreshToken,
    'user': user.toJson(),
  };

  static SavedSession? decode(String text) {
    try {
      final json = jsonDecode(text);
      return json is Map<String, dynamic> ? SavedSession.fromJson(json) : null;
    } on Object {
      return null;
    }
  }
}

/// Where the session is kept: the system's own secret store where there is a usable one.
abstract class TokenStore {
  Future<SavedSession?> load();

  /// Keeps [session]; null forgets it.
  Future<void> save(SavedSession? session);

  /// How it is kept, for the settings: dpapi, secret-service, file or memory.
  String get kind;

  /// Windows: a file in the config folder sealed with DPAPI for this Windows user. Linux: the
  /// Secret Service (GNOME Keyring, KWallet) through secret-tool when it is installed and a
  /// keyring answers, else a file only this user can read (0600, as the macOS launcher keeps
  /// it).
  static TokenStore forSystem(AppPaths paths, HostSystem system) {
    final folder = p.join(paths.config, 'Together');
    if (system == HostSystem.windows) {
      return FileTokenStore(p.join(folder, 'session.bin'), sealer: Platform.isWindows ? DpapiSealer() : null);
    }
    return SecretServiceStore(fallback: FileTokenStore(p.join(folder, 'session.json')));
  }
}

/// Kept for this run only (tests, previews).
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.session]);

  SavedSession? session;

  @override
  Future<SavedSession?> load() async => session;

  @override
  Future<void> save(SavedSession? session) async => this.session = session;

  @override
  String get kind => 'memory';
}

/// Seals bytes so that only this user on this computer opens them again.
abstract class Sealer {
  List<int> seal(List<int> data);

  /// null when the data cannot be opened (another user, another computer, damaged).
  List<int>? open(List<int> data);
}

/// The session in a file. With a [sealer] (DPAPI on Windows) the file holds sealed bytes; on
/// POSIX the file and its folder are made readable by this user only before anything is
/// written.
class FileTokenStore implements TokenStore {
  FileTokenStore(this.file, {this.sealer});

  final String file;
  final Sealer? sealer;

  @override
  String get kind => sealer == null ? 'file' : 'dpapi';

  @override
  Future<SavedSession?> load() async {
    try {
      final bytes = File(file).readAsBytesSync();
      final opened = sealer == null ? bytes : sealer!.open(bytes);
      if (opened == null) return null;
      return SavedSession.decode(utf8.decode(opened));
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(SavedSession? session) async {
    if (session == null) {
      try {
        File(file).deleteSync();
      } on FileSystemException {
        // Nothing kept.
      }
      return;
    }
    final folder = Directory(p.dirname(file))..createSync(recursive: true);
    Posix.chmod(folder.path, 448); // 0700
    final bytes = utf8.encode(jsonEncode(session.toJson()));
    final temporary = File('$file.tmp');
    // Empty and private first, then the secret.
    temporary.writeAsBytesSync(const []);
    Posix.chmod(temporary.path, 384); // 0600
    temporary.writeAsBytesSync(sealer == null ? bytes : sealer!.seal(bytes), flush: true);
    temporary.renameSync(file);
  }
}

/// chmod(2), which dart:io does not offer; nothing on Windows.
abstract final class Posix {
  static final int Function(Pointer<Utf8>, int)? _chmod = _load();

  static int Function(Pointer<Utf8>, int)? _load() {
    if (Platform.isWindows) return null;
    try {
      return DynamicLibrary.process()
          .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod');
    } on Object {
      return null;
    }
  }

  static bool chmod(String path, int mode) {
    final chmod = _chmod;
    if (chmod == null) return false;
    final native = path.toNativeUtf8();
    try {
      return chmod(native, mode) == 0;
    } finally {
      calloc.free(native);
    }
  }
}

/// The Secret Service through secret-tool (libsecret), with a file kept as [fallback] where
/// there is no secret-tool or no keyring answers (a headless session, a desktop without one).
class SecretServiceStore implements TokenStore {
  SecretServiceStore({required this.fallback, this.tool = 'secret-tool'});

  final FileTokenStore fallback;

  /// The secret-tool to run; tests give a fake one.
  final String tool;
  bool _usable = true;

  static const _attributes = ['application', 'anyps5', 'kind', 'anytogether-session'];

  @override
  String get kind => _usable ? 'secret-service' : fallback.kind;

  @override
  Future<SavedSession?> load() async {
    if (_usable) {
      try {
        final result = await Process.run(tool, ['lookup', ..._attributes]);
        if (result.exitCode == 0) {
          final session = SavedSession.decode((result.stdout as String).trim());
          if (session != null) return session;
        }
      } on ProcessException {
        _usable = false;
      }
    }
    return fallback.load();
  }

  @override
  Future<void> save(SavedSession? session) async {
    if (_usable) {
      try {
        if (session == null) {
          await Process.run(tool, ['clear', ..._attributes]);
          await fallback.save(null);
          return;
        }
        final process = await Process.start(tool, ['store', '--label=AnyPS5 AnyTogether session', ..._attributes]);
        process.stdin.write(jsonEncode(session.toJson()));
        await process.stdin.close();
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
          await fallback.save(null);
          return;
        }
        _usable = false;
      } on ProcessException {
        _usable = false;
      }
    }
    await fallback.save(session);
  }
}

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

/// DPAPI (CryptProtectData) for the current Windows user, with the launcher's own entropy, so
/// another account or computer cannot open the file.
class DpapiSealer implements Sealer {
  DpapiSealer() {
    final crypt = DynamicLibrary.open('crypt32.dll');
    _protect = crypt
        .lookupFunction<
          Int32 Function(
            Pointer<_Blob>,
            Pointer<Utf16>,
            Pointer<_Blob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_Blob>,
          ),
          int Function(
            Pointer<_Blob>,
            Pointer<Utf16>,
            Pointer<_Blob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_Blob>,
          )
        >('CryptProtectData');
    _unprotect = crypt
        .lookupFunction<
          Int32 Function(
            Pointer<_Blob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_Blob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_Blob>,
          ),
          int Function(
            Pointer<_Blob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_Blob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_Blob>,
          )
        >('CryptUnprotectData');
    _free = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
  }

  static const _uiForbidden = 0x1;
  static final _entropy = utf8.encode('AnyPS5 AnyTogether session');

  late final int Function(
    Pointer<_Blob>,
    Pointer<Utf16>,
    Pointer<_Blob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_Blob>,
  )
  _protect;
  late final int Function(
    Pointer<_Blob>,
    Pointer<Pointer<Utf16>>,
    Pointer<_Blob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_Blob>,
  )
  _unprotect;
  late final Pointer<Void> Function(Pointer<Void>) _free;

  List<int>? _run(List<int> input, bool sealing) {
    final arena = Arena();
    try {
      Pointer<_Blob> blob(List<int> bytes) {
        final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
        data.asTypedList(bytes.length).setAll(0, bytes);
        return arena<_Blob>()
          ..ref.length = bytes.length
          ..ref.data = data;
      }

      final source = blob(input);
      final entropy = blob(_entropy);
      final out = arena<_Blob>();
      final ok = sealing
          ? _protect(source, nullptr, entropy, nullptr, nullptr, _uiForbidden, out)
          : _unprotect(source, nullptr, entropy, nullptr, nullptr, _uiForbidden, out);
      if (ok == 0) return null;
      final result = List<int>.of(out.ref.data.asTypedList(out.ref.length));
      _free(out.ref.data.cast());
      return result;
    } finally {
      arena.releaseAll();
    }
  }

  @override
  List<int> seal(List<int> data) => _run(data, true) ?? (throw const FileSystemException('DPAPI refused to seal'));

  @override
  List<int>? open(List<int> data) => _run(data, false);
}
