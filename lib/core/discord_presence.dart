import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'host.dart';

/// "Playing …" on the user's Discord profile, as the Mac launcher shows it: through the
/// Discord app's local IPC (a Unix socket on Linux, a named pipe on Windows), with the party the
/// user is in and a Join button that opens the party's join code page.

/// A frame on Discord's IPC: a little-endian opcode and length, then JSON.
abstract final class DiscordFrame {
  static Uint8List encode(int op, List<int> json) {
    final data = ByteData(8 + json.length)
      ..setUint32(0, op, Endian.little)
      ..setUint32(4, json.length, Endian.little);
    final bytes = data.buffer.asUint8List();
    bytes.setRange(8, bytes.length, json);
    return bytes;
  }

  /// One whole frame, or null when [bytes] is not exactly one.
  static (int, Object?)? decode(List<int> bytes) {
    if (bytes.length < 8) return null;
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final length = data.getUint32(4, Endian.little);
    if (bytes.length != 8 + length) return null;
    try {
      return (data.getUint32(0, Endian.little), jsonDecode(utf8.decode(bytes.sublist(8))));
    } on FormatException {
      return null;
    }
  }

  /// The length a frame starting with [header] (its first eight bytes) has in all.
  static int lengthOf(List<int> header) =>
      8 + ByteData.sublistView(Uint8List.fromList(header.sublist(0, 8))).getUint32(4, Endian.little);
}

/// The games Discord knows (its public applications/detectable list), by name: a game found in it
/// is shown on Discord as itself, with its own name and icon.
class DiscordGames {
  DiscordGames([Map<String, String> ids = const {}]) : _ids = ids;

  /// From the list as Discord serves it, or as the launcher caches it: objects with an id, a
  /// name and aliases.
  factory DiscordGames.fromJson(String text) {
    final ids = <String, String>{};
    Object? list;
    try {
      list = jsonDecode(text);
    } on FormatException {
      list = null;
    }
    for (final entry in list is List ? list : const []) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final name = entry['name'];
      if (id is! String || name is! String) continue;
      final aliases = entry['aliases'];
      for (final key in [name, if (aliases is List) ...aliases.whereType<String>()]) {
        final normal = normalized(key);
        if (normal.isNotEmpty) ids.putIfAbsent(normal, () => id);
      }
    }
    return DiscordGames(ids);
  }

  static final source = Uri.parse('https://discord.com/api/v9/applications/detectable');
  static const maxAge = Duration(days: 7);

  final Map<String, String> _ids;

  bool get isEmpty => _ids.isEmpty;

  String? applicationId(String game) => _ids[normalized(game)];

  /// Lowercase letters and digits only, accents taken off, so "Plants vs. Zombies™: Replanted"
  /// finds "Plants vs. Zombies: Replanted".
  static String normalized(String name) {
    final folded = _fold(name.toLowerCase());
    return folded.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((word) => word.isNotEmpty).join(' ');
  }

  /// Accented letters as their plain ones (written as code points, so no language's words are in
  /// the code).
  static const _accents = {
    '\u00e0': 'a',
    '\u00e1': 'a',
    '\u00e2': 'a',
    '\u00e3': 'a',
    '\u00e4': 'a',
    '\u00e5': 'a',
    '\u00e7': 'c',
    '\u010d': 'c',
    '\u00e8': 'e',
    '\u00e9': 'e',
    '\u00ea': 'e',
    '\u00eb': 'e',
    '\u00ec': 'i',
    '\u00ed': 'i',
    '\u00ee': 'i',
    '\u00ef': 'i',
    '\u0131': 'i',
    '\u00f1': 'n',
    '\u00f2': 'o',
    '\u00f3': 'o',
    '\u00f4': 'o',
    '\u00f5': 'o',
    '\u00f6': 'o',
    '\u00f8': 'o',
    '\u00f9': 'u',
    '\u00fa': 'u',
    '\u00fb': 'u',
    '\u00fc': 'u',
    '\u00fd': 'y',
    '\u00ff': 'y',
    '\u011f': 'g',
    '\u015f': 's',
    '\u0161': 's',
    '\u017e': 'z',
    '\u0142': 'l',
    '\u00df': 'ss',
  };

  static String _fold(String text) => text.split('').map((char) => _accents[char] ?? char).join();

  /// The list without what the launcher does not need: id, name, aliases.
  static String slim(String text) {
    final list = jsonDecode(text);
    if (list is! List || list.isEmpty) throw const FormatException('not a list of games');
    return jsonEncode([
      for (final entry in list)
        if (entry is Map) {'id': entry['id'] ?? '', 'name': entry['name'] ?? '', 'aliases': entry['aliases'] ?? []},
    ]);
  }

  /// The cached list at once, then a fresh one from Discord when the cache is a week old or
  /// missing. Without a network the cache, or an empty list, stays.
  static Future<void> load({
    required String cacheFile,
    required Future<String?> Function(Uri url) fetch,
    required void Function(DiscordGames games) update,
    DateTime? now,
  }) async {
    final file = File(cacheFile);
    DateTime? modified;
    try {
      if (file.existsSync()) {
        update(DiscordGames.fromJson(file.readAsStringSync()));
        modified = file.lastModifiedSync();
      }
    } on FileSystemException {
      modified = null;
    }
    if (modified != null && (now ?? DateTime.now()).difference(modified) < maxAge) return;
    try {
      final text = await fetch(source);
      if (text == null) return;
      final compact = slim(text);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(compact);
      update(DiscordGames.fromJson(compact));
    } on Object {
      // The cache, or nothing, stays.
    }
  }

  /// GET [url]'s body over HTTPS, null unless it answers 200.
  static Future<String?> httpGet(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url);
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// A button under the activity: Discord takes two at most, a label of 32 characters at most and
/// an https link of 512 at most.
class DiscordButton {
  const DiscordButton(this.label, this.url);

  static const maxLabel = 32;
  static const maxUrl = 512;

  final String label;
  final String url;

  /// As SET_ACTIVITY takes it; null when Discord would refuse it.
  Map<String, String>? get json {
    var text = label.trim();
    if (text.length > maxLabel) text = text.substring(0, maxLabel);
    final uri = Uri.tryParse(url);
    if (text.isEmpty || !url.toLowerCase().startsWith('https://') || utf8.encode(url).length > maxUrl) return null;
    if (uri == null || uri.host.isEmpty) return null;
    return {'label': text, 'url': url};
  }

  @override
  bool operator ==(Object other) => other is DiscordButton && other.label == label && other.url == url;

  @override
  int get hashCode => Object.hash(label, url);
}

/// The party, shown as "(2 of 8)".
class DiscordParty {
  const DiscordParty({required this.id, required this.size, required this.max});

  final String id;
  final int size;
  final int max;

  @override
  bool operator ==(Object other) => other is DiscordParty && other.id == id && other.size == size && other.max == max;

  @override
  int get hashCode => Object.hash(id, size, max);
}

/// What the user's Discord profile shows: the game, the party they are in (with its size), and a
/// Join button that opens the code's web page. Built here, with no socket, so it can be checked.
class DiscordActivity {
  const DiscordActivity({
    required this.system,
    required this.partyText,
    this.game,
    this.since,
    this.party,
    this.buttons = const [],
  });

  final HostSystem system;
  final String? game;
  final DateTime? since;
  final DiscordParty? party;
  final List<DiscordButton> buttons;

  /// "In a party", in the launcher's language.
  final String partyText;

  String get _platform => system == HostSystem.windows ? 'Windows' : 'Linux';

  /// The activity for SET_ACTIVITY, null when there is nothing to show (no game, no party). A
  /// game Discord knows ([knownGame]) shows as itself, so the launcher's name goes under it.
  Map<String, Object?>? json({required bool knownGame}) {
    if (game == null && party == null) return null;
    final activity = <String, Object?>{'type': 0};
    if (since case final since?) activity['timestamps'] = {'start': since.millisecondsSinceEpoch ~/ 1000};
    if (game case final game?) {
      if (knownGame) {
        activity['details'] = 'AnyPS5 Launcher · $_platform';
        // Discord shows the party's size next to the state.
        if (party != null) activity['state'] = partyText;
      } else {
        activity['details'] = game;
        activity['state'] = 'AnyPS5 · $_platform';
      }
    } else {
      activity['details'] = partyText;
      activity['state'] = 'AnyPS5 · $_platform';
    }
    if (party case final party?) {
      final size = max(1, party.size);
      activity['party'] = {
        'id': party.id,
        'size': [size, max(size, party.max)],
      };
    }
    final shown = buttons.map((button) => button.json).nonNulls.take(2).toList();
    if (shown.isNotEmpty) activity['buttons'] = shown;
    return activity;
  }

  @override
  bool operator ==(Object other) =>
      other is DiscordActivity &&
      other.system == system &&
      other.game == game &&
      other.since == since &&
      other.party == party &&
      other.partyText == partyText &&
      _sameButtons(other.buttons, buttons);

  static bool _sameButtons(List<DiscordButton> a, List<DiscordButton> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

  @override
  int get hashCode => Object.hash(system, game, since, party, partyText, Object.hashAll(buttons));
}

/// Which code the Join button on Discord opens: the party's when it works, else a new one made for
/// it, but only for the party's leader, and never again where the user stopped the code
/// themselves. (The Mac also offers the share play it hosts; the Port has no share play.)
sealed class DiscordJoinPlan {
  const DiscordJoinPlan();

  static DiscordJoinPlan of({
    required String? partyId,
    required Uri? codeUrl,
    required DateTime? codeExpires,
    required bool leader,
    required bool mayMake,
    DateTime? now,
  }) {
    if (partyId == null) return const DiscordJoinNone();
    if (codeUrl != null && (codeExpires == null || codeExpires.isAfter(now ?? DateTime.now()))) {
      return DiscordJoinButton(codeUrl.toString());
    }
    if (leader && mayMake) return DiscordJoinMake(partyId);
    return const DiscordJoinNone();
  }
}

class DiscordJoinNone extends DiscordJoinPlan {
  const DiscordJoinNone();
}

class DiscordJoinButton extends DiscordJoinPlan {
  const DiscordJoinButton(this.url);
  final String url;
}

class DiscordJoinMake extends DiscordJoinPlan {
  const DiscordJoinMake(this.partyId);
  final String partyId;
}

/// A connection to the Discord app: whole frames written, whole frames read (null after the
/// time given, or when Discord went).
abstract class DiscordPipe {
  Future<bool> write(Uint8List frame);
  Future<List<int>?> read(Duration timeout);
  void close();
}

/// Opens the first Discord IPC endpoint that answers; null without Discord.
typedef DiscordConnector = Future<DiscordPipe?> Function();

/// "Playing …" through the Discord app's IPC. Without Discord, or without an application ID,
/// nothing happens; a Discord started later is found on the next change.
class DiscordPresence {
  DiscordPresence({required this.applicationId, required this.connect, DiscordGames? games, int? pid})
    : _games = games ?? DiscordGames(),
      _pid = pid ?? pidOf();

  /// The AnyPS5 application in the Discord Developer Portal (the Mac launcher's).
  static const anyps5ApplicationId = '1562749843724566549';

  /// ANYPS5_DISCORD_APP_ID puts another application in its place; set but empty turns it off.
  static String applicationIdFrom(Map<String, String> environment) =>
      environment['ANYPS5_DISCORD_APP_ID']?.trim() ?? anyps5ApplicationId;

  static int pidOf() => pid;

  /// The launcher's own: a Unix socket or a named pipe, as [system] has them.
  factory DiscordPresence.system(HostSystem system, Map<String, String> environment) => DiscordPresence(
    applicationId: applicationIdFrom(environment),
    connect: system == HostSystem.windows
        ? WindowsDiscordPipe.connect
        : () => UnixDiscordPipe.connect(UnixDiscordPipe.socketPaths(environment)),
  );

  final String applicationId;

  /// Opens the IPC: the system's, or a fake in the tests.
  final DiscordConnector connect;
  final int _pid;
  DiscordGames _games;
  DiscordPipe? _pipe;
  String? _connectedAs;
  Future<void> _queue = Future.value();
  var _nonce = 0;

  /// How long Discord has to answer a frame.
  static const answerTime = Duration(seconds: 2);

  void use(DiscordGames games) => _games = games;

  /// The whole activity: the game (as itself when Discord knows it), the party and the Join
  /// button; null, or one with nothing to show, clears it.
  Future<void> show(DiscordActivity? activity) => _run(() async {
    final known = activity?.game == null ? null : _games.applicationId(activity!.game!);
    final json = activity?.json(knownGame: known != null);
    if (json == null) return _clearNow();
    await _setActivity(json, known ?? applicationId);
  });

  Future<void> clear() => _run(_clearNow);

  /// Clears and lets the connection go (the launcher quitting).
  Future<void> close() => _run(() async {
    await _clearNow();
    _pipe?.close();
    _pipe = null;
    _connectedAs = null;
  });

  Future<void> _run(Future<void> Function() job) {
    final next = _queue.then((_) => job()).catchError((Object _) {});
    _queue = next;
    return next;
  }

  Future<void> _clearNow() async {
    final as = _connectedAs;
    if (_pipe == null || as == null) return;
    await _setActivity(null, as);
  }

  Future<void> _setActivity(Map<String, Object?>? activity, String application) async {
    if (applicationId.isEmpty || application.isEmpty) return;
    // Discord ties a connection to the application it shook hands as: another one needs its own.
    if (_pipe != null && _connectedAs != application) {
      _pipe!.close();
      _pipe = null;
      _connectedAs = null;
    }
    final command = utf8.encode(
      jsonEncode({
        'cmd': 'SET_ACTIVITY',
        'args': {'pid': _pid, 'activity': activity},
        'nonce': '${DateTime.now().microsecondsSinceEpoch}-${_nonce++}',
      }),
    );
    // A Discord that restarted closed the old connection: connect once more and send again.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!await _connected(application)) return;
      final pipe = _pipe!;
      if (await pipe.write(DiscordFrame.encode(1, command)) && await pipe.read(answerTime) != null) return;
      pipe.close();
      _pipe = null;
      _connectedAs = null;
    }
  }

  Future<bool> _connected(String application) async {
    if (_pipe != null) return true;
    final pipe = await connect();
    if (pipe == null) return false;
    final hello = utf8.encode(jsonEncode({'v': 1, 'client_id': application}));
    if (await pipe.write(DiscordFrame.encode(0, hello))) {
      final ready = await pipe.read(answerTime);
      if (ready != null && DiscordFrame.decode(ready)?.$1 == 1) {
        _pipe = pipe;
        _connectedAs = application;
        return true;
      }
    }
    pipe.close();
    return false;
  }
}

/// Discord on Linux (and macOS, for the tests): discord-ipc-0 to 9 in the runtime folder (and the
/// Flatpak's and Snap's folders in it), the temporary folder, then /tmp.
class UnixDiscordPipe implements DiscordPipe {
  UnixDiscordPipe._(this._socket) {
    _socket.listen(_data, onDone: _done, onError: (Object _) => _done(), cancelOnError: true);
  }

  final Socket _socket;
  final List<int> _buffer = [];
  Completer<void>? _arrived;
  bool _closed = false;

  static List<String> socketPaths(Map<String, String> environment) {
    final folders = <String>[];
    void add(String? folder) {
      if (folder == null || folder.isEmpty) return;
      final normal = p.posix.normalize(folder);
      if (!folders.contains(normal)) folders.add(normal);
    }

    final runtime = environment['XDG_RUNTIME_DIR'];
    add(runtime);
    if (runtime != null && runtime.isNotEmpty) {
      add(p.posix.join(runtime, 'app', 'com.discordapp.Discord'));
      add(p.posix.join(runtime, 'app', 'com.discordapp.DiscordCanary'));
      add(p.posix.join(runtime, 'snap.discord'));
      add(p.posix.join(runtime, 'snap.discord-canary'));
    }
    add(environment['TMPDIR']);
    add(environment['TMP']);
    add(environment['TEMP']);
    add('/tmp');
    return [
      for (final folder in folders)
        for (var index = 0; index < 10; index++) p.posix.join(folder, 'discord-ipc-$index'),
    ];
  }

  /// The first of [paths] that takes a connection.
  static Future<DiscordPipe?> connect(List<String> paths) async {
    for (final path in paths) {
      try {
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) continue;
        final socket = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        ).timeout(const Duration(seconds: 2));
        return UnixDiscordPipe._(socket);
      } on Object {
        continue;
      }
    }
    return null;
  }

  void _data(List<int> data) {
    _buffer.addAll(data);
    _arrived?.complete();
    _arrived = null;
  }

  void _done() {
    _closed = true;
    _arrived?.complete();
    _arrived = null;
  }

  @override
  Future<bool> write(Uint8List frame) async {
    if (_closed) return false;
    try {
      _socket.add(frame);
      await _socket.flush().timeout(DiscordPresence.answerTime);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<List<int>?> read(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_buffer.length >= 8) {
        final length = DiscordFrame.lengthOf(_buffer);
        if (length > (1 << 20) + 8) return null;
        if (_buffer.length >= length) {
          final frame = _buffer.sublist(0, length);
          _buffer.removeRange(0, length);
          return frame;
        }
      }
      final left = deadline.difference(DateTime.now());
      if (_closed || left <= Duration.zero) return null;
      final arrived = _arrived = Completer<void>();
      try {
        await arrived.future.timeout(left);
      } on TimeoutException {
        return null;
      }
    }
  }

  @override
  void close() {
    _closed = true;
    _socket.destroy();
  }
}

typedef _CreateFileC = IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileDart = int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _ReadWriteC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _ReadWriteDart = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _PeekC = Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _PeekDart = int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _CloseC = Int32 Function(IntPtr);
typedef _CloseDart = int Function(int);

/// Discord on Windows: the named pipe \\.\pipe\discord-ipc-0 to 9, through kernel32. A read
/// waits for bytes with PeekNamedPipe, so a silent Discord never holds the launcher up.
class WindowsDiscordPipe implements DiscordPipe {
  WindowsDiscordPipe._(this._handle);

  int _handle;

  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _createFile = _kernel.lookupFunction<_CreateFileC, _CreateFileDart>('CreateFileW');
  static final _writeFile = _kernel.lookupFunction<_ReadWriteC, _ReadWriteDart>('WriteFile');
  static final _readFile = _kernel.lookupFunction<_ReadWriteC, _ReadWriteDart>('ReadFile');
  static final _peek = _kernel.lookupFunction<_PeekC, _PeekDart>('PeekNamedPipe');
  static final _closeHandle = _kernel.lookupFunction<_CloseC, _CloseDart>('CloseHandle');

  static const _genericRead = 0x80000000;
  static const _genericWrite = 0x40000000;
  static const _openExisting = 3;
  static const _invalidHandle = -1;

  static Future<DiscordPipe?> connect() async {
    if (!Platform.isWindows) return null;
    for (var index = 0; index < 10; index++) {
      final name = '\\\\.\\pipe\\discord-ipc-$index'.toNativeUtf16();
      try {
        final handle = _createFile(name, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, 0);
        if (handle != _invalidHandle && handle != 0) return WindowsDiscordPipe._(handle);
      } on Object {
        // The next one.
      } finally {
        calloc.free(name);
      }
    }
    return null;
  }

  @override
  Future<bool> write(Uint8List frame) async {
    if (_handle == 0) return false;
    final buffer = calloc<Uint8>(frame.length);
    final written = calloc<Uint32>();
    try {
      buffer.asTypedList(frame.length).setAll(0, frame);
      return _writeFile(_handle, buffer, frame.length, written, nullptr) != 0 && written.value == frame.length;
    } finally {
      calloc.free(buffer);
      calloc.free(written);
    }
  }

  /// Waits until [count] bytes are there (or the time is up), then reads them.
  Future<List<int>?> _readExactly(int count, DateTime deadline) async {
    final available = calloc<Uint32>();
    try {
      while (true) {
        if (_handle == 0) return null;
        if (_peek(_handle, nullptr, 0, nullptr, available, nullptr) == 0) return null;
        if (available.value >= count) break;
        if (DateTime.now().isAfter(deadline)) return null;
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    } finally {
      calloc.free(available);
    }
    final buffer = calloc<Uint8>(max(1, count));
    final read = calloc<Uint32>();
    try {
      if (count == 0) return const [];
      if (_readFile(_handle, buffer, count, read, nullptr) == 0 || read.value != count) return null;
      return List<int>.of(buffer.asTypedList(count));
    } finally {
      calloc.free(buffer);
      calloc.free(read);
    }
  }

  @override
  Future<List<int>?> read(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    final header = await _readExactly(8, deadline);
    if (header == null) return null;
    final length = DiscordFrame.lengthOf(header) - 8;
    if (length > 1 << 20) return null;
    final body = await _readExactly(length, deadline);
    return body == null ? null : [...header, ...body];
  }

  @override
  void close() {
    if (_handle == 0) return;
    _closeHandle(_handle);
    _handle = 0;
  }
}
