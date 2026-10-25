import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host.dart';
import 'text_vdf.dart';

/// A Steam installation: its folder and the accounts that signed in on this computer.
class SteamInstall {
  SteamInstall(this.root, {this.flatpak = false});

  /// The folder holding userdata/ and config/ (on Linux, what ~/.steam/steam points to).
  final String root;

  /// Steam from Flathub (com.valvesoftware.Steam): it sees the host only through its sandbox.
  final bool flatpak;

  static const flatpakId = 'com.valvesoftware.Steam';

  String get userdata => p.join(root, 'userdata');
  String get loginUsers => p.join(root, 'config', 'loginusers.vdf');

  /// The accounts with a userdata folder, the most recently signed in first.
  List<SteamUser> users() {
    final folder = Directory(userdata);
    if (!folder.existsSync()) return const [];
    final logins = <String, Map<String, Object>>{};
    try {
      final users = TextVdf.get(TextVdf.parse(File(loginUsers).readAsStringSync()), 'users');
      if (users is Map<String, Object>) {
        for (final entry in users.entries) {
          final steamId = BigInt.tryParse(entry.key);
          final value = entry.value;
          if (steamId == null || value is! Map<String, Object>) continue;
          logins[SteamUser.accountIdOf(steamId).toString()] = value;
        }
      }
    } on FileSystemException {
      // No sign-ins file: the folders alone.
    } on FormatException {
      // A file Steam is writing: the folders alone.
    }
    final found = <SteamUser>[];
    for (final entity in folder.listSync()) {
      final id = p.basename(entity.path);
      // 0 is the anonymous account some clients leave behind.
      if (entity is! Directory || int.tryParse(id) == null || id == '0') continue;
      final login = logins[id];
      String? field(String key) => login == null ? null : TextVdf.get(login, key) as String?;
      found.add(
        SteamUser(
          id: id,
          persona: field('PersonaName'),
          account: field('AccountName'),
          mostRecent: field('MostRecent') == '1',
          lastLogin: int.tryParse(field('Timestamp') ?? '') ?? 0,
        ),
      );
    }
    found.sort((a, b) {
      if (a.mostRecent != b.mostRecent) return a.mostRecent ? -1 : 1;
      if (a.lastLogin != b.lastLogin) return b.lastLogin.compareTo(a.lastLogin);
      return a.id.compareTo(b.id);
    });
    return found;
  }

  @override
  String toString() => 'SteamInstall($root${flatpak ? ', flatpak' : ''})';
}

/// A Steam account on this computer, by its userdata folder.
class SteamUser {
  const SteamUser({required this.id, this.persona, this.account, this.mostRecent = false, this.lastLogin = 0});

  /// The userdata folder's name: the account's 32-bit ID.
  final String id;
  final String? persona;
  final String? account;

  /// Signed in last (loginusers.vdf's MostRecent).
  final bool mostRecent;

  /// When it last signed in, Unix seconds; 0 when unknown.
  final int lastLogin;

  String get label => persona ?? account ?? id;

  /// The userdata folder of a 64-bit Steam ID: its low 32 bits.
  static int accountIdOf(BigInt steamId) => (steamId & BigInt.from(0xFFFFFFFF)).toInt();
}

/// Finds Steam where it installs itself on [system].
abstract final class SteamLocator {
  /// Every distinct Steam folder with a userdata folder, the usual one first. [registry] reads
  /// HKCU\Software\Valve\Steam's SteamPath on Windows (`reg query` by default).
  static Future<List<SteamInstall>> find({
    required HostSystem system,
    Map<String, String>? environment,
    Future<String?> Function()? registry,
  }) async {
    final env = environment ?? Platform.environment;
    final candidates = <(String, bool)>[];
    if (system == HostSystem.windows) {
      final fromRegistry = await (registry ?? windowsRegistrySteamPath)();
      if (fromRegistry != null && fromRegistry.isNotEmpty) candidates.add((fromRegistry, false));
      final x86 = env['ProgramFiles(x86)'] ?? env['PROGRAMFILES(X86)'] ?? r'C:\Program Files (x86)';
      candidates
        ..add((p.join(x86, 'Steam'), false))
        ..add((p.join(env['ProgramFiles'] ?? env['PROGRAMFILES'] ?? r'C:\Program Files', 'Steam'), false));
    } else {
      final home = env['HOME'];
      if (home == null) return const [];
      final data = env['XDG_DATA_HOME'];
      candidates
        ..add((p.join(home, '.steam', 'steam'), false))
        ..add((p.join(home, '.steam', 'root'), false))
        ..add((p.join(data != null && p.isAbsolute(data) ? data : p.join(home, '.local', 'share'), 'Steam'), false))
        ..add((p.join(home, '.local', 'share', 'Steam'), false))
        ..add((p.join(home, '.var', 'app', SteamInstall.flatpakId, '.local', 'share', 'Steam'), true))
        ..add((p.join(home, '.var', 'app', SteamInstall.flatpakId, 'data', 'Steam'), true));
    }
    final seen = <String>{};
    final found = <SteamInstall>[];
    for (final (path, flatpak) in candidates) {
      final folder = p.normalize(path);
      if (!Directory(p.join(folder, 'userdata')).existsSync()) continue;
      String real;
      try {
        real = Directory(folder).resolveSymbolicLinksSync();
      } on FileSystemException {
        real = folder;
      }
      final key = system == HostSystem.windows ? real.toLowerCase() : real;
      if (!seen.add(key)) continue;
      found.add(SteamInstall(real, flatpak: flatpak));
    }
    return found;
  }

  /// SteamPath from the registry, with Windows' separators; null without Steam or `reg`.
  static Future<String?> windowsRegistrySteamPath() async {
    try {
      final result = await Process.run('reg', const ['query', r'HKCU\Software\Valve\Steam', '/v', 'SteamPath']);
      if (result.exitCode != 0) return null;
      return parseRegQuery(result.stdout as String, 'SteamPath');
    } on ProcessException {
      return null;
    }
  }

  /// The value of [name] in `reg query` output ("    SteamPath    REG_SZ    c:/program files (x86)/steam").
  static String? parseRegQuery(String output, String name) {
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final match = RegExp(
        '^\\s*${RegExp.escape(name)}\\s+REG_\\w+\\s+(.*?)\\s*\$',
        caseSensitive: false,
      ).firstMatch(line);
      if (match != null) return match.group(1)!.replaceAll('/', r'\');
    }
    return null;
  }
}

/// Whether Steam runs, and asking it to quit: shortcuts.vdf is written only while it is closed,
/// as Steam writes its own copy over the file when it exits.
class SteamControl {
  SteamControl(
    this.install, {
    required this.system,
    this.procRoot = '/proc',
    Future<ProcessResult> Function(String executable, List<String> arguments)? run,
    Future<void> Function(String executable, List<String> arguments)? start,
  }) : _run = run ?? Process.run,
       _start = start ?? _startDetached;

  final SteamInstall install;
  final HostSystem system;

  /// Where Linux lists its processes (a fake folder in tests).
  final String procRoot;
  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<void> Function(String, List<String>) _start;

  static Future<void> _startDetached(String executable, List<String> arguments) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  Future<bool> running() async {
    if (system == HostSystem.windows) {
      try {
        final result = await _run('tasklist', const ['/FI', 'IMAGENAME eq steam.exe', '/NH']);
        return (result.stdout as String).toLowerCase().contains('steam.exe');
      } on ProcessException {
        return false;
      }
    }
    final proc = Directory(procRoot);
    if (!proc.existsSync()) return false;
    for (final entity in proc.listSync(followLinks: false)) {
      if (int.tryParse(p.basename(entity.path)) == null) continue;
      try {
        final name = File(p.join(entity.path, 'comm')).readAsStringSync().trim();
        if (name == 'steam') return true;
      } on FileSystemException {
        // Gone, or not ours to read.
      }
    }
    return false;
  }

  /// The ways to ask Steam to quit, tried in order until one starts.
  List<List<String>> get shutdownCommands => switch (system) {
    HostSystem.windows => [
      [p.join(install.root, 'steam.exe'), '-shutdown'],
      ['cmd', '/c', 'start', '', 'steam://exit'],
    ],
    HostSystem.linux when install.flatpak => [
      ['flatpak', 'run', SteamInstall.flatpakId, '-shutdown'],
      ['xdg-open', 'steam://exit'],
    ],
    HostSystem.linux => [
      ['steam', '-shutdown'],
      [p.join(install.root, 'steam.sh'), '-shutdown'],
      ['xdg-open', 'steam://exit'],
    ],
  };

  /// Asks Steam to quit and waits up to [timeout] for it; true once it is gone.
  Future<bool> shutdown({
    Duration timeout = const Duration(seconds: 40),
    Duration poll = const Duration(milliseconds: 500),
  }) async {
    if (!await running()) return true;
    for (final command in shutdownCommands) {
      try {
        await _start(command.first, command.sublist(1));
        break;
      } on ProcessException {
        continue;
      }
    }
    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(poll);
      if (!await running()) {
        // Steam writes its files as it goes: a moment for the last of them.
        await Future<void>.delayed(poll * 2);
        return true;
      }
    }
    return false;
  }
}
