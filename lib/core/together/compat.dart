import '../host.dart';
import 'account.dart';

/// Community compatibility on AnyTogether: after a session the player may say how far the game
/// got, with the launcher and engine versions and the computer; the game's settings show what
/// the community found on the same system. As the macOS launcher's TogetherCompat.

/// How far a game gets, worst to best.
enum CompatStatus {
  nothing,
  boots,
  menus,
  ingame,
  playable;

  static CompatStatus? named(Object? name) => values.where((status) => status.name == name).firstOrNull;
}

/// The community's verdict for a game on one platform: what the newest launcher version tested
/// reached.
class CompatSummary {
  const CompatSummary({required this.statusName, required this.version, this.testedAt, this.reports = 0});

  static CompatSummary? fromJson(Object? json) {
    if (json is! Map || json['status'] is! String) return null;
    return CompatSummary(
      statusName: json['status'] as String,
      version: json['version'] as String? ?? '',
      testedAt: DateTime.tryParse(json['testedAt'] as String? ?? ''),
      reports: (json['reports'] as num? ?? 0).toInt(),
    );
  }

  final String statusName;
  final String version;
  final DateTime? testedAt;
  final int reports;

  CompatStatus? get status => CompatStatus.named(statusName);
}

/// A game on the compatibility list, with each platform's verdict.
class CompatGame {
  const CompatGame({required this.titleId, this.name, this.platforms = const {}});

  factory CompatGame.fromJson(Map<String, dynamic> json) {
    final platforms = json['platforms'];
    return CompatGame(
      titleId: json['titleId'] as String? ?? '',
      name: json['name'] as String?,
      platforms: {
        if (platforms is Map)
          for (final entry in platforms.entries)
            entry.key as String: ?CompatSummary.fromJson(entry.value),
      },
    );
  }

  final String titleId;
  final String? name;

  /// "macos", "windows" or "linux" → the verdict there.
  final Map<String, CompatSummary> platforms;
}

/// A report on how a game ran.
class CompatReport {
  const CompatReport({
    required this.titleId,
    required this.platform,
    required this.status,
    required this.launcherVersion,
    this.name,
    this.engineVersion,
    this.machine,
    this.os,
    this.fpsAvg,
    this.gameVersion,
    this.note,
  });

  final String titleId;
  final String? name;

  /// "windows" or "linux".
  final String platform;
  final CompatStatus status;
  final String launcherVersion;
  final String? engineVersion;
  final String? machine;
  final String? os;
  final double? fpsAvg;
  final String? gameVersion;
  final String? note;

  static String platformOf(HostSystem system) => system == HostSystem.windows ? 'windows' : 'linux';

  /// A version as the server takes it: letters, digits and . _ + - only, at most 40.
  static String? version(String? text) {
    if (text == null) return null;
    final kept = text.replaceAll(RegExp(r'[^A-Za-z0-9._+\-]'), '');
    final cut = kept.length > 40 ? kept.substring(0, 40) : kept;
    return cut.isEmpty ? null : cut;
  }

  static String _cut(String text, int length) => text.length > length ? text.substring(0, length) : text;

  /// The JSON body: only what is known, cut to the server's lengths.
  Map<String, dynamic> get body {
    final name = this.name?.trim();
    final note = this.note?.trim();
    final engine = version(engineVersion);
    final fps = fpsAvg;
    return {
      'titleId': titleId,
      'platform': platform,
      'status': status.name,
      'launcherVersion': version(launcherVersion) ?? 'dev',
      if (name != null && name.isNotEmpty) 'name': _cut(name, 200),
      'engineVersion': ?engine,
      if (machine != null && machine!.isNotEmpty) 'machine': _cut(machine!, 120),
      if (os != null && os!.isNotEmpty) 'os': _cut(os!, 60),
      if (fps != null && fps >= 0 && fps <= 1000) 'fpsAvg': fps,
      if (gameVersion != null && gameVersion!.isNotEmpty) 'gameVersion': _cut(gameVersion!, 20),
      if (note != null && note.isNotEmpty) 'note': _cut(note, 500),
    };
  }
}

/// When the launcher asks "How did it run?" after a session: once per game and launcher version,
/// after a session long enough to tell.
abstract final class CompatPrompt {
  static const minimum = Duration(seconds: 60);

  /// [asked]: title ID → the launcher version last asked about it.
  static bool shouldAsk({
    required String titleId,
    required Duration played,
    required String launcherVersion,
    required Map<String, String> asked,
  }) => played >= minimum && asked[titleId] != launcherVersion;
}

/// The compatibility calls.
class Compat {
  const Compat(this.account);

  final TogetherAccount account;

  /// Sends a report; the game's verdict on the report's platform as it is now.
  Future<CompatSummary?> report(CompatReport report) async =>
      CompatSummary.fromJson((await account.call('POST', 'compat/reports', report.body))['summary']);

  /// The game's verdicts; null when no one reported it (or the server does not know it).
  Future<CompatGame?> game(String titleId) async {
    try {
      return CompatGame.fromJson(await account.call('GET', 'compat/${Uri.encodeComponent(titleId)}'));
    } on TogetherProblem catch (problem) {
      if (problem.status == 404) return null;
      rethrow;
    }
  }
}
