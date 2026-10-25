import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_links.dart';

/// The console's font scripts a game can ask for (sceFontOpenFontSet), and the files the engine
/// looks for in ANYPS5_SYSTEM_FONTS for each, as the engine's libSceFont/src/SystemFont.cpp maps
/// them: the console's own file first, else an openly licensed Noto substitute.
enum FontScript {
  latin,
  latinItalic,
  typewriter,
  vietnamese,
  thai,
  japanese,
  chinese,
  korean,
  arabic;

  /// The console's files, by weight (light, regular, medium, bold).
  List<String> get consoleFiles => switch (this) {
    latin => const ['SST-Light.otf', 'SST-Roman.otf', 'SST-Medium.otf', 'SST-Bold.otf'],
    latinItalic => const ['SST-LightItalic.otf', 'SST-Italic.otf', 'SST-MediumItalic.otf', 'SST-BoldItalic.otf'],
    typewriter => const [
      'SSTTypewriter-Roman.otf',
      'SSTTypewriter-Roman.otf',
      'SSTTypewriter-Roman.otf',
      'SSTTypewriter-Bd.otf',
    ],
    vietnamese => const [
      'SSTVietnamese-Light.otf',
      'SSTVietnamese-Roman.otf',
      'SSTVietnamese-Medium.otf',
      'SSTVietnamese-Bold.otf',
    ],
    thai => const ['SSTThai-Light.otf', 'SSTThai-Roman.otf', 'SSTThai-Medium.otf', 'SSTThai-Bold.otf'],
    japanese => const ['SSTJpPro-Regular.otf', 'SSTJpPro-Regular.otf', 'SSTJpPro-Regular.otf', 'SSTJpPro-Bold.otf'],
    chinese => const ['DFHEI5-SONY.ttf', 'DFHEI5-SONY.ttf', 'DFHEI5-SONY.ttf', 'DFHEI5-SONY.ttf'],
    korean => const [
      'SCEPS4Yoongd-Medium.otf',
      'SCEPS4Yoongd-Medium.otf',
      'SCEPS4Yoongd-Medium.otf',
      'SCEPS4Yoongd-Bold.otf',
    ],
    arabic => const ['SSTArabic-Light.otf', 'SSTArabic-Roman.otf', 'SSTArabic-Medium.otf', 'SSTArabic-Bold.otf'],
  };

  /// The Noto files the engine takes in place of the console's, by weight. Japanese, Chinese
  /// and Korean share the CJK collections (faces 0, 2 and 1).
  List<String> get notoFiles {
    const weights = ['Light', 'Regular', 'Medium', 'Bold'];
    return switch (this) {
      latin || vietnamese => [for (final weight in weights) 'NotoSans-$weight.ttf'],
      latinItalic => const [
        'NotoSans-LightItalic.ttf',
        'NotoSans-Italic.ttf',
        'NotoSans-MediumItalic.ttf',
        'NotoSans-BoldItalic.ttf',
      ],
      typewriter => [for (final weight in weights) 'NotoSansMono-$weight.ttf'],
      thai => [for (final weight in weights) 'NotoSansThai-$weight.ttf'],
      japanese || chinese || korean => [for (final weight in weights) 'NotoSansCJK-$weight.ttc'],
      arabic => [for (final weight in weights) 'NotoSansArabic-$weight.ttf'],
    };
  }

  /// Japanese, Chinese and Korean: the large fonts the launcher downloads when a game needs them.
  bool get isCjk => this == japanese || this == chinese || this == korean;
}

/// The console's system font sets, decoded the way SystemFont.cpp decodes them.
abstract final class SystemFontSet {
  /// Every font set type the console has (SystemFont.cpp's SYSTEM_FONT_SET_TYPES); the engine
  /// gives no system font for any other.
  static const types = <int>{
    0x18070043, 0x18070044, 0x18070045, 0x18070047, 0x18070053, 0x18070054, //
    0x18070055, 0x18070057, 0x180700C3, 0x180700C4, 0x180700C5, 0x180700C7,
    0x18070444, 0x18070447, 0x18070454, 0x18070457, 0x180704C4, 0x180704C7,
    0x18071053, 0x18071054, 0x18071055, 0x18071057, 0x18071454, 0x18071457,
    0x18072444, 0x18072447, 0x180724C4, 0x180724C7, 0x18073454, 0x18073457,
    0x180734D4, 0x180734D7, 0x18078044, 0x180780C4, 0x18079054, 0x1807A044,
    0x1807A0C4, 0x1807A444, 0x1807A4C4, 0x1807AC44, 0x1807ACC4, 0x1807B054,
    0x1807B0D4, 0x1807B454, 0x1807B4D4, 0x1807BC54, 0x1807BCD4, 0x18080444,
    0x18080447, 0x18080454, 0x18080457, 0x180804C4, 0x180804C7, 0x18081454,
    0x18081457, 0x18082444, 0x18082447, 0x180824C4, 0x180824C7, 0x18083454,
    0x18083457, 0x180834D4, 0x180834D7, 0x1808A444, 0x1808A4C4, 0x1808B454,
    0x1808B4D4, 0x180C8044, 0x180C80C4, 0x180C9054, 0x180CA044, 0x180CA0C4,
    0x180CAC44, 0x180CACC4, 0x180CB054, 0x180CB0D4, 0x180CBC54, 0x180CBCD4,
    0x18170043, 0x18170044, 0x18170045, 0x18170047, 0x18170444, 0x18170447,
    0x18370044, 0x18370047, 0x18370444, 0x18370447, 0x1A070543, 0x1A070547,
    0x1A070553, 0x1A070557, 0x1A0705C3, 0x1A0705C7, 0x1A071553, 0x1A071557,
    0x1A072543, 0x1A072547, 0x1A0725C3, 0x1A0725C7, 0x1A073553, 0x1A073557,
    0x1A0735D3, 0x1A0735D7, 0x1A080543, 0x1A080547, 0x1A080553, 0x1A080557,
    0x1A0805C3, 0x1A0805C7, 0x1A081553, 0x1A081557, 0x1A082543, 0x1A082547,
    0x1A0825C3, 0x1A0825C7, 0x1A083553, 0x1A083557, 0x1A0835D3, 0x1A0835D7,
  };

  /// The script whose file a set opens first (SystemFont.cpp's FamilyOf).
  static FontScript primary(int type) {
    final region = (type >> 16) & 0xFF;
    final scripts = (type >> 8) & 0xFE;
    final vietnamese = type & 0x10 != 0;
    return switch (region) {
      0x17 => FontScript.latinItalic,
      0x37 => FontScript.typewriter,
      0x08 => scripts == 0x04 && vietnamese ? FontScript.vietnamese : FontScript.japanese,
      0x0C => FontScript.chinese,
      _ when scripts == 0x10 => FontScript.thai,
      _ when scripts == 0 && vietnamese => FontScript.vietnamese,
      _ => FontScript.latin,
    };
  }

  /// Every script a set opens: its own first, then the ones it falls back on for the characters
  /// its own file lacks (FallbackFamilies), in the engine's order. Empty for a type the console
  /// does not have.
  static List<FontScript> scripts(int type) {
    if (!types.contains(type)) return const [];
    final scripts = (type >> 8) & 0xFF;
    final found = [primary(type)];
    void add(bool wanted, FontScript script) {
      if (wanted && !found.contains(script)) found.add(script);
    }

    add(type & 0x10 != 0, FontScript.vietnamese);
    add(scripts & 0x10 != 0, FontScript.thai);
    add(scripts & 0x88 == 0x88, FontScript.chinese);
    add(scripts & 0x04 != 0, FontScript.japanese);
    add(scripts & 0x80 != 0, FontScript.chinese);
    add(scripts & 0x20 != 0, FontScript.korean);
    add(type & 0x80 != 0, FontScript.arabic);
    return found;
  }

  static final _logged = RegExp('fontSetType=0x([0-9A-Fa-f]{8})');

  /// The font set types in a game's log: the engine writes `fontSetType=0x…` for every
  /// sceFontOpenFontSet, whether it found a file for it or not.
  static Set<int> opened(String log) => {
    for (final match in _logged.allMatches(log)) int.parse(match.group(1)!, radix: 16),
  };

  /// The scripts the font sets in a log open.
  static Set<FontScript> scriptsIn(String log) => {for (final type in opened(log)) ...scripts(type)};
}

/// Reads the font sets a running game opens from its log as the log grows: only what this
/// session wrote, from [offset] on (the log's length before the game started).
class FontLogScanner {
  FontLogScanner(this.logFile, {this.offset = 0});

  final String logFile;
  int offset;

  /// The end of what was read before, kept so a `fontSetType=0x…` cut by a read is whole in
  /// the next.
  String _carry = '';

  /// Every font set type seen so far.
  final Set<int> types = {};

  /// Reads what the log gained since the last scan; returns the types seen for the first time.
  Set<int> scan() {
    final file = File(logFile);
    RandomAccessFile? handle;
    try {
      final length = file.lengthSync();
      if (length < offset) {
        offset = 0;
        _carry = '';
      }
      if (length == offset) return const {};
      handle = file.openSync();
      handle.setPositionSync(offset);
      final bytes = handle.readSync(length - offset);
      offset += bytes.length;
      // Latin-1 keeps every byte one character: the marker and its digits are ASCII.
      final text = _carry + String.fromCharCodes(bytes);
      _carry = text.length > 32 ? text.substring(text.length - 32) : text;
      final fresh = SystemFontSet.opened(text).difference(types);
      types.addAll(fresh);
      return fresh;
    } on FileSystemException {
      return const {};
    } finally {
      handle?.closeSync();
    }
  }
}

/// Where a font games get comes from.
enum FontSource { user, downloaded, builtIn }

/// One script as games get it now: the file and where it comes from.
class FontPick {
  const FontPick(this.file, this.source);

  final String file;
  final FontSource source;

  /// The console's own font rather than a Noto substitute.
  bool get isConsole => !file.startsWith('Noto');

  /// The font's family for people: "Noto Sans CJK", "SST Typewriter".
  String get family {
    final stem = file.split('-').first.split('.').first;
    if (stem == 'SST') return 'SST';
    if (stem.startsWith('SST')) return 'SST ${_words(stem.substring(3))}';
    if (stem.startsWith('NotoSans')) {
      final rest = stem.substring(8);
      return rest.isEmpty ? 'Noto Sans' : 'Noto Sans ${rest == 'CJK' ? rest : _words(rest)}';
    }
    return stem;
  }

  static String _words(String text) => text.replaceAllMapped(RegExp('(?<=[a-z])(?=[A-Z])'), (_) => ' ');

  @override
  bool operator ==(Object other) => other is FontPick && other.file == file && other.source == source;

  @override
  int get hashCode => Object.hash(file, source);

  @override
  String toString() => 'FontPick($file, $source)';
}

/// The fonts a game gets, put together from three folders into the one folder the engine reads
/// (ANYPS5_SYSTEM_FONTS).
///
/// Precedence is by file name: the user's own folder first, then the downloaded Japanese,
/// Chinese and Korean fonts, then the fonts that come with the launcher. So the user's files win
/// over the launcher's of the same name, and the launcher's fill in every name the user's folder
/// lacks; the engine itself prefers a console file (SST-Roman.otf, …) over any Noto substitute,
/// so a folder with the console's fonts is used for every script it covers.
///
/// The folder holds no copies where it can help it: on Linux each name is a symbolic link to
/// the file it stands for; on Windows (where symbolic links need Developer Mode) a hard link,
/// which needs the same volume and write access to the file, and a copy where neither works.
class SystemFonts {
  const SystemFonts({this.user, this.downloaded, this.builtIn});

  final String? user;
  final String? downloaded;
  final String? builtIn;

  static const extensions = {'.ttf', '.otf', '.ttc', '.otc'};

  /// Where the launcher's own fonts are on disk: ANYPS5_LAUNCHER_FONTS (a launcher run from its
  /// build folder), else the Flutter assets beside the executable (data/flutter_assets on
  /// Windows and Linux). Null when there are none.
  static String? locateBuiltIn({Map<String, String>? environment, String? executable}) {
    final env = environment ?? Platform.environment;
    final exe = executable ?? Platform.resolvedExecutable;
    final candidates = [
      if (env['ANYPS5_LAUNCHER_FONTS'] case final String path when path.isNotEmpty) path,
      p.join(p.dirname(exe), 'data', 'flutter_assets', assetFolder),
    ];
    for (final folder in candidates) {
      if (File(p.join(folder, 'NotoSans-Regular.ttf')).existsSync()) return folder;
    }
    return null;
  }

  /// The launcher's fonts in its Flutter assets.
  static const assetFolder = 'assets/system-fonts';

  List<(FontSource, String)> get _layers => [
    if (user case final String folder) (FontSource.user, folder),
    if (downloaded case final String folder) (FontSource.downloaded, folder),
    if (builtIn case final String folder) (FontSource.builtIn, folder),
  ];

  /// The font files in [folder], by name (not its subfolders, which the engine does not read).
  static List<String> fontsIn(String folder) {
    try {
      return [
        for (final entity in Directory(folder).listSync())
          if (entity is! Directory &&
              extensions.contains(p.extension(entity.path).toLowerCase()) &&
              !p.basename(entity.path).startsWith('.') &&
              FileSystemEntity.isFileSync(entity.path))
            p.basename(entity.path),
      ]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  /// Each font file games get, by name: the first folder that has it, and its path there.
  Map<String, (FontSource, String)> files() {
    final chosen = <String, (FontSource, String)>{};
    for (final (source, folder) in _layers) {
      for (final name in fontsIn(folder)) {
        chosen.putIfAbsent(name, () => (source, p.join(folder, name)));
      }
    }
    return chosen;
  }

  /// The file the engine opens for [script] at [weight] (regular by default), searched as the
  /// engine searches: the console's file, then the Noto one. Null when games get nothing for it.
  FontPick? pick(FontScript script, {int weight = 1, Map<String, (FontSource, String)>? files}) {
    final all = files ?? this.files();
    for (final name in [script.consoleFiles[weight], script.notoFiles[weight]]) {
      if (all[name] case (final source, _)) return FontPick(name, source);
    }
    return null;
  }

  /// Puts every font together in [folder]. Entries that already stand for the right file stay,
  /// so a game running from the folder keeps its open files and is given the fonts that came in
  /// after it started (the engine opens a font set only when the game asks for it). Returns
  /// the number of fonts; with none, no folder is left (the engine then looks beside the game
  /// as it always did).
  int assemble(String folder) {
    final wanted = files();
    final directory = Directory(folder);
    if (wanted.isEmpty) {
      if (directory.existsSync()) _quietly(() => directory.deleteSync(recursive: true));
      return 0;
    }
    directory.createSync(recursive: true);
    for (final entity in directory.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final source = wanted[name]?.$2;
      if (source == null || !_standsFor(entity.path, source)) _quietly(() => FileLinks.remove(entity.path));
    }
    for (final MapEntry(key: name, value: (_, source)) in wanted.entries) {
      final destination = p.join(folder, name);
      if (FileSystemEntity.typeSync(destination, followLinks: false) != FileSystemEntityType.notFound) continue;
      _place(source, destination);
    }
    return wanted.length;
  }

  /// Whether the entry at [path] is [source]: a link to it, or a hard link or copy of it (the
  /// same size and time; a hard link shares both, a copy is given the source's time).
  static bool _standsFor(String path, String source) {
    try {
      switch (FileSystemEntity.typeSync(path, followLinks: false)) {
        case FileSystemEntityType.link:
          return Link(path).targetSync() == source;
        case FileSystemEntityType.file:
          final have = File(path).statSync();
          final want = File(source).statSync();
          return have.size == want.size &&
              have.modified.millisecondsSinceEpoch ~/ 1000 == want.modified.millisecondsSinceEpoch ~/ 1000;
        default:
          return false;
      }
    } on FileSystemException {
      return false;
    }
  }

  static void _place(String source, String destination) {
    if (!Platform.isWindows) {
      try {
        Link(destination).createSync(source);
        return;
      } on FileSystemException {
        // A file system without links: a copy below.
      }
    } else if (FileLinks.hardLink(source, destination)) {
      return;
    }
    File(source).copySync(destination);
    File(destination).setLastModifiedSync(File(source).lastModifiedSync());
  }

  /// A file a running game holds open on Windows cannot go: it stays until the next time.
  static void _quietly(void Function() action) {
    try {
      action();
    } on FileSystemException {
      // Left for the next time the folder is put together.
    }
  }
}
