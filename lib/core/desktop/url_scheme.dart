import 'dart:io';

import 'package:path/path.dart' as p;

import '../deep_link.dart';

/// Runs a program and gives its exit code and output; Process.run by default.
typedef SchemeRunner = Future<(int, String)> Function(String executable, List<String> arguments);

Future<(int, String)> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  return (result.exitCode, '${result.stdout}');
}

/// Makes the system open anyps5:// links with this launcher, for the user alone (no
/// administrator rights): the URL protocol under HKCU\Software\Classes on Windows, a hidden
/// desktop entry with the x-scheme-handler/anyps5 type in the user's applications folder on
/// Linux. Done at every start, and only written when it names another program than this one
/// (the launcher moved, or a portable copy started). The installer and the .deb register the
/// scheme too; this covers the zip, the AppImage and the tar.gz.
abstract final class UrlScheme {
  static const _key = r'HKCU\Software\Classes\' + DeepLink.scheme;

  /// The entry's file name on Linux.
  static const desktopFile = 'anyps5-desktop-links.desktop';

  /// The command Windows runs for a link.
  static String windowsCommand(String program) => '"$program" "%1"';

  /// The `reg add` calls that register [program] for anyps5:// links.
  static List<List<String>> windowsRegistration(String program) => [
    ['add', _key, '/ve', '/d', 'URL:AnyPS5', '/f'],
    ['add', _key, '/v', 'URL Protocol', '/d', '', '/f'],
    ['add', '$_key\\DefaultIcon', '/ve', '/d', '"$program",0', '/f'],
    ['add', '$_key\\shell\\open\\command', '/ve', '/d', windowsCommand(program), '/f'],
  ];

  /// The hidden desktop entry that opens anyps5:// links with [program].
  static String linuxEntry(String program) {
    // The Desktop Entry spec quotes an Exec argument in double quotes, with ", `, $ and \ escaped.
    final quoted = program.replaceAllMapped(RegExp(r'["`$\\]'), (match) => '\\${match[0]}');
    return [
      '[Desktop Entry]',
      'Type=Application',
      'Name=AnyPS5 Desktop',
      'NoDisplay=true',
      'Exec="$quoted" %u',
      'Icon=anyps5-desktop',
      'Terminal=false',
      'MimeType=x-scheme-handler/${DeepLink.scheme};',
      '',
    ].join('\n');
  }

  /// The program a link should start: the AppImage itself where the launcher runs from one.
  static String program({required String resolvedExecutable, required Map<String, String> environment}) {
    final appImage = environment['APPIMAGE'];
    return appImage != null && appImage.isNotEmpty ? appImage : resolvedExecutable;
  }

  /// Registers the launcher on this system; whether anything was written. Never throws.
  static Future<bool> register({
    String? resolvedExecutable,
    Map<String, String>? environment,
    SchemeRunner? run,
    bool? windows,
  }) async {
    final env = environment ?? Platform.environment;
    final runner = run ?? _run;
    final onWindows = windows ?? Platform.isWindows;
    final launcher = program(resolvedExecutable: resolvedExecutable ?? Platform.resolvedExecutable, environment: env);
    try {
      if (onWindows) return await _registerWindows(launcher, runner);
      return await _registerLinux(launcher, env, runner);
    } on Object {
      // Links stay unregistered; the launcher works without them.
      return false;
    }
  }

  static Future<bool> _registerWindows(String program, SchemeRunner run) async {
    final (code, output) = await run('reg', ['query', '$_key\\shell\\open\\command', '/ve']);
    if (code == 0 && output.toLowerCase().contains(windowsCommand(program).toLowerCase())) return false;
    for (final arguments in windowsRegistration(program)) {
      final (added, _) = await run('reg', arguments);
      if (added != 0) return false;
    }
    return true;
  }

  static Future<bool> _registerLinux(String program, Map<String, String> env, SchemeRunner run) async {
    // The .deb's own entry (in /usr/share/applications) already says it opens the links.
    if (p.isWithin('/opt/anyps5-desktop', program)) return false;
    final home = env['HOME'];
    final data = env['XDG_DATA_HOME']?.isNotEmpty == true
        ? env['XDG_DATA_HOME']!
        : (home == null ? null : p.join(home, '.local', 'share'));
    if (data == null) return false;
    final folder = p.join(data, 'applications');
    final file = File(p.join(folder, desktopFile));
    final entry = linuxEntry(program);
    if (file.existsSync() && file.readAsStringSync() == entry) return false;
    Directory(folder).createSync(recursive: true);
    file.writeAsStringSync(entry);
    // The default handler for the scheme, and the folder's cache; neither is needed to have.
    try {
      await run('xdg-mime', ['default', desktopFile, 'x-scheme-handler/${DeepLink.scheme}']);
    } on Object {
      // xdg-utils missing: the entry alone still lists the launcher for the links.
    }
    try {
      await run('update-desktop-database', [folder]);
    } on Object {
      // desktop-file-utils missing.
    }
    return true;
  }
}
