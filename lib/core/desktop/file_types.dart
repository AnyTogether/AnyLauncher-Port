import 'dart:io';

import 'package:path/path.dart' as p;

import '../host.dart';

/// Runs a program and says whether it ended well, with what it printed.
typedef RunCommand = Future<({bool ok, String out})> Function(String executable, List<String> arguments);

/// Makes `.anyps5theme` files open with this launcher (double-click in Explorer or the file
/// manager installs the theme). The installer and the .deb register it for their installs; this
/// covers the zip on Windows and the AppImage and the archive on Linux, which install nothing, and
/// a launcher that moved. It only writes what is not set yet, to the user's own registry and
/// data folder, never the system's.
class ThemeFileType {
  ThemeFileType({required this.system, required this.executable, required this.environment, RunCommand? run})
    : _run = run ?? _runSystem;

  static const extension = '.anyps5theme';
  static const mimeType = 'application/x-anyps5theme';
  static const progId = 'AnyPS5.Theme';

  /// The desktop entry that opens theme files, hidden from the menus (the launcher's own entry
  /// is the one shown).
  static const desktopEntry = 'anyps5-desktop-theme.desktop';

  final HostSystem system;

  /// The program to open the files with: the AppImage itself when the launcher runs from one.
  final String executable;
  final Map<String, String> environment;
  final RunCommand _run;

  static Future<({bool ok, String out})> _runSystem(String executable, List<String> arguments) async {
    try {
      final result = await Process.run(executable, arguments);
      return (ok: result.exitCode == 0, out: '${result.stdout}');
    } on Object {
      return (ok: false, out: '');
    }
  }

  /// The open command Windows keeps for the type.
  String get windowsCommand => '"$executable" "%1"';

  /// Registers the type where it is not registered yet for this program; true when something was
  /// written.
  Future<bool> register() => system == HostSystem.windows ? _windows() : _linux();

  Future<bool> _windows() async {
    const classes = r'HKCU\Software\Classes';
    final command = '$classes\\$progId\\shell\\open\\command';
    final now = await _run('reg', ['query', command, '/ve']);
    if (now.ok && now.out.contains(windowsCommand)) return false;
    final writes = [
      ['$classes\\$extension', '/ve', '/d', progId],
      ['$classes\\$extension', '/v', 'Content Type', '/d', mimeType],
      ['$classes\\$progId', '/ve', '/d', 'AnyPS5 theme'],
      ['$classes\\$progId\\DefaultIcon', '/ve', '/d', '"$executable",0'],
      [command, '/ve', '/d', windowsCommand],
    ];
    for (final write in writes) {
      if (!(await _run('reg', ['add', ...write, '/f'])).ok) return false;
    }
    return true;
  }

  /// The user's data folder (XDG_DATA_HOME, else ~/.local/share).
  String get _dataHome {
    final data = environment['XDG_DATA_HOME'];
    if (data != null && data.isNotEmpty && p.posix.isAbsolute(data)) return data;
    return p.posix.join(environment['HOME'] ?? '/tmp', '.local', 'share');
  }

  /// The shared-mime-info package naming the type.
  static String get mimePackage =>
      '''<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="$mimeType">
    <comment>AnyPS5 theme</comment>
    <sub-class-of type="application/zip"/>
    <glob pattern="*$extension"/>
  </mime-type>
</mime-info>
''';

  String get _desktopFile => [
    '[Desktop Entry]',
    'Type=Application',
    'Name=AnyPS5 Desktop',
    'Comment=Install an AnyPS5 theme',
    'Exec=${_quoted(executable)} %f',
    'Icon=anyps5-desktop',
    'Terminal=false',
    'NoDisplay=true',
    'MimeType=$mimeType;',
    '',
  ].join('\n');

  /// A path quoted for a desktop entry's Exec key.
  static String _quoted(String path) =>
      RegExp(r'[\s"\\`$]').hasMatch(path) ? '"${path.replaceAllMapped(RegExp(r'["\\`$]'), (m) => '\\${m[0]}')}"' : path;

  Future<bool> _linux() async {
    // The .deb's own registration (its desktop entry and MIME package) covers /opt.
    if (p.posix.isWithin('/opt/anyps5-desktop', executable) || p.posix.isWithin('/usr', executable)) return false;
    final mime = File(p.posix.join(_dataHome, 'mime', 'packages', 'anyps5-desktop.xml'));
    final entry = File(p.posix.join(_dataHome, 'applications', desktopEntry));
    var wrote = false;
    try {
      if (!mime.existsSync() || mime.readAsStringSync() != mimePackage) {
        mime.parent.createSync(recursive: true);
        mime.writeAsStringSync(mimePackage);
        await _run('update-mime-database', [p.posix.join(_dataHome, 'mime')]);
        wrote = true;
      }
      if (!entry.existsSync() || entry.readAsStringSync() != _desktopFile) {
        entry.parent.createSync(recursive: true);
        entry.writeAsStringSync(_desktopFile);
        await _run('update-desktop-database', [entry.parent.path]);
        await _run('xdg-mime', ['default', desktopEntry, mimeType]);
        wrote = true;
      }
    } on FileSystemException {
      return wrote;
    }
    return wrote;
  }

  /// This launcher as the program to open the files: the AppImage on Linux when run from one.
  static String launcherProgram(Map<String, String> environment) {
    final appImage = environment['APPIMAGE'];
    return appImage != null && appImage.isNotEmpty ? appImage : Platform.resolvedExecutable;
  }
}
