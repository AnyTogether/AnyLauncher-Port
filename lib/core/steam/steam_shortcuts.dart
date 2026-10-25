import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'binary_vdf.dart';
import 'steam_install.dart';

/// Steam's IDs for a non-Steam shortcut, the way Steam (and Steam ROM Manager) derive them:
/// the CRC-32 of the quoted Exe and the AppName, with the top bit set. Written into the
/// shortcut's appid field, so Steam uses it and the grid pictures named after it match.
abstract final class SteamAppId {
  static final List<int> _table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  /// CRC-32 (IEEE 802.3, as zlib's crc32).
  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// The 32-bit shortcut ID (unsigned): the grid pictures' names, `steam://rungameid/` after
  /// [gameId].
  static int shortcut(String exe, String appName) => crc32(utf8.encode(exe + appName)) | 0x80000000;

  /// The 64-bit game ID Big Picture and `steam://rungameid/<id>` use.
  static BigInt gameId(int shortcutId) => (BigInt.from(shortcutId) << 32) | BigInt.from(0x02000000);
}

/// One shortcut AnyPS5 puts in Steam.
class SteamShortcut {
  const SteamShortcut({
    required this.appName,
    required this.exe,
    required this.startDir,
    required this.launchOptions,
    this.icon = '',
    this.tags = const [SteamShortcuts.tag],
  });

  final String appName;

  /// The program, quoted as Steam stores it.
  final String exe;
  final String startDir;
  final String launchOptions;
  final String icon;
  final List<String> tags;

  /// Quotes a path the way Steam writes Exe and StartDir.
  static String quote(String path) => '"$path"';

  int get appId => SteamAppId.shortcut(exe, appName);

  /// The entry's fields in the order Steam itself writes them.
  VdfMap toVdf() => VdfMap([
    VdfEntry.int32('appid', appId),
    VdfEntry.string('AppName', appName),
    VdfEntry.string('Exe', exe),
    VdfEntry.string('StartDir', startDir),
    VdfEntry.string('icon', icon),
    VdfEntry.string('ShortcutPath', ''),
    VdfEntry.string('LaunchOptions', launchOptions),
    VdfEntry.int32('IsHidden', 0),
    VdfEntry.int32('AllowDesktopConfig', 1),
    VdfEntry.int32('AllowOverlay', 1),
    VdfEntry.int32('OpenVR', 0),
    VdfEntry.int32('Devkit', 0),
    VdfEntry.string('DevkitGameID', ''),
    VdfEntry.int32('DevkitOverrideAppID', 0),
    VdfEntry.int32('LastPlayTime', 0),
    VdfEntry.string('FlatpakAppID', ''),
    VdfEntry.map('tags', VdfMap([for (var i = 0; i < tags.length; i++) VdfEntry.string('$i', tags[i])])),
  ]);
}

/// The pictures Steam shows for a shortcut, in `userdata/<id>/config/grid`, by the file name's
/// ending after the shortcut ID.
enum SteamArt {
  /// The library's portrait capsule, 600 × 900.
  portrait('p.png', 600, 900),

  /// The wide capsule (recent games, Big Picture's shelves), 920 × 430.
  wide('.png', 920, 430),

  /// The banner across the top of the game's page, 1920 × 620.
  hero('_hero.png', 1920, 620),

  /// The name over the hero, transparent around it.
  logo('_logo.png', 1280, 720),

  /// The small square beside the name in lists, also the shortcut's icon field.
  icon('_icon.png', 256, 256);

  const SteamArt(this.suffix, this.width, this.height);

  final String suffix;
  final int width;
  final int height;

  String fileName(int appId) => '$appId$suffix';
}

/// A shortcut and the pictures that go with it.
class SteamEntry {
  const SteamEntry(this.shortcut, {this.art = const {}});

  final SteamShortcut shortcut;
  final Map<SteamArt, Uint8List> art;
}

/// What a shortcuts.vdf holds, with AnyPS5's entries told apart from everyone else's.
class ShortcutsFile {
  ShortcutsFile._(this._document, this._list);

  /// A file with no shortcuts, as Steam writes one.
  factory ShortcutsFile.empty() {
    final list = VdfMap();
    return ShortcutsFile._(VdfDocument(VdfMap([VdfEntry.map('shortcuts', list)])), list);
  }

  factory ShortcutsFile.decode(Uint8List bytes) {
    final document = BinaryVdf.decode(bytes);
    final list = document.root.map('shortcuts');
    if (list == null) throw const FormatException('shortcuts.vdf without its shortcuts list');
    return ShortcutsFile._(document, list);
  }

  final VdfDocument _document;
  final VdfMap _list;

  Uint8List encode() => BinaryVdf.encode(_document);

  /// Every shortcut, in file order.
  List<VdfMap> get shortcuts => [
    for (final entry in _list.entries)
      if (entry.value case final VdfMap map) map,
  ];

  /// AnyPS5's: tagged AnyPS5 and started with --steam (which the launcher's own entries
  /// always are), so a shortcut someone made by hand is never taken for one.
  static bool isOurs(VdfMap shortcut) =>
      shortcut.strings('tags').contains(SteamShortcuts.tag) &&
      (shortcut.string('LaunchOptions') ?? '').split(' ').contains(SteamShortcuts.launchFlag);

  /// The unsigned shortcut ID an entry carries (0 when it has none).
  static int appIdOf(VdfMap shortcut) => (shortcut.int32('appid') ?? 0).toUnsigned(32);

  List<VdfMap> get ours => shortcuts.where(isOurs).toList();

  /// Takes out AnyPS5's entries; the IDs they had. The others keep their bytes, renumbered
  /// only when one of ours sat before them.
  List<int> removeOurs() {
    final removed = <int>[];
    _list.entries.removeWhere((entry) {
      if (entry.value case final VdfMap map when isOurs(map)) {
        removed.add(appIdOf(map));
        return true;
      }
      return false;
    });
    _renumber();
    return removed;
  }

  /// Puts [shortcuts] at the end after taking out ours that are not among them; one of ours
  /// already there with the same ID is replaced where it is.
  void putOurs(List<SteamShortcut> wanted) {
    final ids = {for (final shortcut in wanted) shortcut.appId};
    _list.entries.removeWhere(
      (entry) =>
          entry.value is VdfMap && isOurs(entry.value as VdfMap) && !ids.contains(appIdOf(entry.value as VdfMap)),
    );
    for (final shortcut in wanted) {
      final at = _list.entries.indexWhere(
        (entry) =>
            entry.value is VdfMap && isOurs(entry.value as VdfMap) && appIdOf(entry.value as VdfMap) == shortcut.appId,
      );
      final entry = VdfEntry.map('${_list.entries.length}', shortcut.toVdf());
      if (at >= 0) {
        _list.entries[at] = entry;
      } else {
        _list.entries.add(entry);
      }
    }
    _renumber();
  }

  void _renumber() {
    for (var i = 0; i < _list.entries.length; i++) {
      if (_list.entries[i].name != '$i') _list.entries[i] = _list.entries[i].renamed('$i');
    }
  }
}

/// What adding or removing did.
class SteamChange {
  const SteamChange({required this.shortcutsFile, required this.appIds, this.backup, this.artFiles = const []});

  final String shortcutsFile;

  /// The shortcut IDs added or removed.
  final List<int> appIds;

  /// The copy of shortcuts.vdf made before it was written; null when there was no file.
  final String? backup;
  final List<String> artFiles;
}

/// AnyPS5's shortcuts in one Steam account: `userdata/<id>/config/shortcuts.vdf` and the
/// pictures in config/grid. Steam must be closed while they are written (see [SteamControl]).
class SteamShortcuts {
  SteamShortcuts(this.install, this.user);

  final SteamInstall install;
  final SteamUser user;

  /// The tag every AnyPS5 shortcut carries, a collection in the Steam library.
  static const tag = 'AnyPS5';

  /// The option every AnyPS5 shortcut starts the launcher with: it tells the launcher Steam
  /// started it, and tells AnyPS5's shortcuts from others.
  static const launchFlag = '--steam';

  static const backupSuffix = '.anyps5-backup';

  String get config => p.join(install.userdata, user.id, 'config');
  String get shortcutsFile => p.join(config, 'shortcuts.vdf');
  String get backupFile => '$shortcutsFile$backupSuffix';
  String get gridFolder => p.join(config, 'grid');

  ShortcutsFile read() {
    final file = File(shortcutsFile);
    if (!file.existsSync()) return ShortcutsFile.empty();
    final bytes = file.readAsBytesSync();
    return bytes.isEmpty ? ShortcutsFile.empty() : ShortcutsFile.decode(bytes);
  }

  /// AnyPS5's shortcuts there now.
  List<VdfMap> ours() {
    try {
      return read().ours;
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  /// Makes AnyPS5's shortcuts exactly [entries]: adds them, replaces the ones there, takes out
  /// ours no longer wanted (and their pictures), writes the pictures. Everything else in the
  /// file stays as it was; the file as it was is kept as shortcuts.vdf.anyps5-backup.
  SteamChange put(List<SteamEntry> entries) {
    final file = read();
    final before = {for (final shortcut in file.ours) ShortcutsFile.appIdOf(shortcut)};
    file.putOurs([for (final entry in entries) entry.shortcut]);
    final backup = _write(file);
    final wanted = {for (final entry in entries) entry.shortcut.appId};
    for (final gone in before.difference(wanted)) {
      _deleteArt(gone);
    }
    final written = <String>[];
    if (entries.any((entry) => entry.art.isNotEmpty)) Directory(gridFolder).createSync(recursive: true);
    for (final entry in entries) {
      for (final MapEntry(key: kind, value: bytes) in entry.art.entries) {
        final path = p.join(gridFolder, kind.fileName(entry.shortcut.appId));
        File(path).writeAsBytesSync(bytes, flush: true);
        written.add(path);
      }
    }
    return SteamChange(shortcutsFile: shortcutsFile, appIds: wanted.toList(), backup: backup, artFiles: written);
  }

  /// Takes out AnyPS5's shortcuts and their pictures; nothing else is touched. A file with
  /// none of ours is not written at all.
  SteamChange remove() {
    if (!File(shortcutsFile).existsSync()) return SteamChange(shortcutsFile: shortcutsFile, appIds: const []);
    final file = read();
    final removed = file.removeOurs();
    if (removed.isEmpty) return SteamChange(shortcutsFile: shortcutsFile, appIds: const []);
    final backup = _write(file);
    final deleted = [for (final id in removed) ..._deleteArt(id)];
    return SteamChange(shortcutsFile: shortcutsFile, appIds: removed, backup: backup, artFiles: deleted);
  }

  /// The grid picture's path for one of our shortcuts.
  String artPath(int appId, SteamArt kind) => p.join(gridFolder, kind.fileName(appId));

  List<String> _deleteArt(int appId) {
    final deleted = <String>[];
    for (final kind in SteamArt.values) {
      final file = File(artPath(appId, kind));
      if (file.existsSync()) {
        file.deleteSync();
        deleted.add(file.path);
      }
    }
    return deleted;
  }

  /// Backs the old file up, then writes the new one beside it and moves it over (never half a
  /// file in Steam's place). The backup's path, null when there was no file.
  String? _write(ShortcutsFile file) {
    final target = File(shortcutsFile);
    String? backup;
    if (target.existsSync()) {
      target.copySync(backupFile);
      backup = backupFile;
    } else {
      target.parent.createSync(recursive: true);
    }
    final temporary = File('$shortcutsFile.anyps5-new');
    temporary.writeAsBytesSync(file.encode(), flush: true);
    temporary.renameSync(shortcutsFile);
    return backup;
  }
}

/// The shortcuts this launcher makes: one for AnyPS5 itself, and with games on, one per
/// unlocked game that starts it with --play <title ID>.
abstract final class SteamPlan {
  static const appName = 'AnyPS5';

  /// The program Steam should start: the AppImage when the launcher runs from one ($APPIMAGE;
  /// the running file is inside its temporary mount), else the launcher's own executable.
  static String program({required String resolvedExecutable, Map<String, String> environment = const {}}) {
    final appImage = environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return appImage;
    return resolvedExecutable;
  }

  static String launchOptions({String? play, bool fullscreen = false}) => [
    SteamShortcuts.launchFlag,
    if (fullscreen) '--fullscreen',
    if (play != null) ...['--play', play],
  ].join(' ');

  static SteamShortcut launcher(String program, {bool fullscreen = false, SteamShortcuts? into}) =>
      _shortcut(program, appName, launchOptions(fullscreen: fullscreen), into);

  static SteamShortcut game(
    String program, {
    required String name,
    required String titleId,
    bool fullscreen = false,
    SteamShortcuts? into,
  }) => _shortcut(program, name, launchOptions(play: titleId, fullscreen: fullscreen), into);

  static SteamShortcut _shortcut(String program, String name, String options, SteamShortcuts? into) {
    final exe = SteamShortcut.quote(program);
    final appId = SteamAppId.shortcut(exe, name);
    return SteamShortcut(
      appName: name,
      exe: exe,
      startDir: SteamShortcut.quote(p.dirname(program)),
      launchOptions: options,
      icon: into == null ? '' : into.artPath(appId, SteamArt.icon),
    );
  }
}
