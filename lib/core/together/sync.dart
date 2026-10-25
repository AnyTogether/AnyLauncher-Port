import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'account.dart';

/// A trophy as AnyTogether takes it: its id is the trophy package's service label × 1000 plus the
/// trophy's number, as the macOS launcher counts it.
class SyncTrophy {
  const SyncTrophy({
    required this.id,
    required this.grade,
    required this.hidden,
    required this.name,
    required this.detail,
    this.earnedAt,
  });

  factory SyncTrophy.fromJson(Map<String, dynamic> json) => SyncTrophy(
    id: (json['id'] as num).toInt(),
    grade: json['grade'] as String,
    hidden: json['hidden'] as bool? ?? false,
    name: json['name'] as String,
    detail: json['detail'] as String? ?? '',
    earnedAt: DateTime.tryParse(json['earnedAt'] as String? ?? ''),
  );

  static int idFor(int serviceLabel, int number) => serviceLabel * 1000 + number;

  final int id;

  /// platinum, gold, silver or bronze.
  final String grade;
  final bool hidden;
  final String name;
  final String detail;
  final DateTime? earnedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'grade': grade,
    'hidden': hidden,
    'name': name,
    'detail': detail,
    'earnedAt': earnedAt?.toUtc().toIso8601String(),
  };
}

/// A game's trophy set as the launcher reads it now, in [language] ("en", "tr").
class SyncTrophySet {
  const SyncTrophySet({required this.titleId, required this.gameName, required this.language, required this.trophies});

  factory SyncTrophySet.fromJson(Map<String, dynamic> json) => SyncTrophySet(
    titleId: json['titleId'] as String,
    gameName: json['gameName'] as String,
    language: json['language'] as String,
    trophies: [
      for (final trophy in json['trophies'] as List<dynamic>) SyncTrophy.fromJson(trophy as Map<String, dynamic>),
    ],
  );

  final String titleId;
  final String gameName;
  final String language;
  final List<SyncTrophy> trophies;

  /// The set by what it is (its trophies and their grades), not by the language it is read in:
  /// the first 8 bytes of SHA-256 over "id:grade:hidden,…" sorted by id, as hex.
  String get setHash {
    final sorted = [...trophies]..sort((a, b) => a.id.compareTo(b.id));
    final shape = sorted.map((trophy) => '${trophy.id}:${trophy.grade}:${trophy.hidden}').join(',');
    return sha256
        .convert(utf8.encode(shape))
        .bytes
        .take(8)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String get key => '$titleId/$setHash';

  Map<String, Object?> toJson() => {
    'titleId': titleId,
    'gameName': gameName,
    'language': language,
    'trophies': [for (final trophy in trophies) trophy.toJson()],
  };
}

/// What the launcher tells AnyTogether about playing: each session of a game, and the trophies
/// earned, with the game's name and its trophy set taught the first time. Everything waits in an
/// outbox on disk until the server has it, so playing offline loses nothing and nothing counts
/// twice. The macOS launcher's TogetherSync, rule for rule.
class TogetherSync {
  TogetherSync({
    required this.account,
    required this.file,
    required this.deviceName,
    required this.platform,
    this.model,
  }) {
    _load();
  }

  final TogetherAccount account;
  final String file;
  final String deviceName;

  /// windows or linux, as the server names them.
  final String platform;
  final String? model;

  /// A PlayStation title ID, the only kind the server takes.
  static final titleIdPattern = RegExp(r'^[A-Z]{4}[0-9]{5}$');

  late String deviceId;
  bool deviceRegistered = false;
  Map<String, String> gameNames = {};

  /// Each game's age ratings from its param.json, taught with its name.
  Map<String, Map<String, int>> gameAges = {};
  Set<String> taughtGames = {};
  Map<String, SyncTrophySet> sets = {};
  Set<String> uploadedSets = {};
  Set<String> sentTrophies = {};
  List<Map<String, dynamic>> sessions = [];
  bool _flushing = false;

  void _load() {
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(File(file).readAsStringSync());
      if (decoded is Map<String, dynamic>) json = decoded;
    } on Object {
      // A new outbox.
    }
    try {
      deviceId = json['deviceId'] as String? ?? uuidv4();
      deviceRegistered = json['deviceRegistered'] as bool? ?? false;
      gameNames = {
        for (final entry in (json['gameNames'] as Map<String, dynamic>? ?? const {}).entries)
          entry.key: entry.value as String,
      };
      gameAges = {
        for (final entry in (json['gameAges'] as Map<String, dynamic>? ?? const {}).entries)
          entry.key: {
            for (final level in (entry.value as Map<String, dynamic>).entries) level.key: (level.value as num).toInt(),
          },
      };
      taughtGames = {for (final id in json['taughtGames'] as List<dynamic>? ?? const []) id as String};
      sets = {
        for (final entry in (json['sets'] as Map<String, dynamic>? ?? const {}).entries)
          entry.key: SyncTrophySet.fromJson(entry.value as Map<String, dynamic>),
      };
      uploadedSets = {for (final key in json['uploadedSets'] as List<dynamic>? ?? const []) key as String};
      sentTrophies = {for (final key in json['sentTrophies'] as List<dynamic>? ?? const []) key as String};
      sessions = [
        for (final session in json['sessions'] as List<dynamic>? ?? const []) session as Map<String, dynamic>,
      ];
    } on Object {
      deviceId = uuidv4();
    }
  }

  void _save() {
    try {
      Directory(p.dirname(file)).createSync(recursive: true);
      final temporary = File('$file.tmp');
      temporary.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'deviceId': deviceId,
          'deviceRegistered': deviceRegistered,
          'gameNames': gameNames,
          'gameAges': gameAges,
          'taughtGames': taughtGames.toList(),
          'sets': {for (final entry in sets.entries) entry.key: entry.value.toJson()},
          'uploadedSets': uploadedSets.toList(),
          'sentTrophies': sentTrophies.toList(),
          'sessions': sessions,
        }),
      );
      temporary.renameSync(file);
    } on FileSystemException {
      // Kept in memory for this run.
    }
  }

  /// Nothing waits to be sent.
  bool get isEmpty =>
      sessions.isEmpty && _pendingTrophies().isEmpty && sets.values.every((set) => uploadedSets.contains(set.key));

  /// A game the catalogue should know: its name and its age ratings (param.json's ageLevel),
  /// taught again when the ratings change.
  void teachGame({required String titleId, required String gameName, Map<String, int>? ageLevels}) {
    if (!titleIdPattern.hasMatch(titleId)) return;
    _learn(titleId, gameName, ageLevels);
    _save();
  }

  void _learn(String titleId, String gameName, Map<String, int>? ageLevels) {
    gameNames[titleId] = gameName;
    if (ageLevels == null || ageLevels.isEmpty) return;
    final known = gameAges[titleId];
    final same =
        known != null &&
        known.length == ageLevels.length &&
        ageLevels.entries.every((entry) => known[entry.key] == entry.value);
    if (same) return;
    gameAges[titleId] = Map.of(ageLevels);
    taughtGames.remove(titleId);
  }

  /// A game played from [startedAt] to [endedAt]; a few seconds are no session. [exit] is normal,
  /// crashed or killed.
  void recordSession({
    required String titleId,
    required String gameName,
    required DateTime startedAt,
    required DateTime endedAt,
    String exit = 'normal',
    Map<String, int>? ageLevels,
  }) {
    if (!titleIdPattern.hasMatch(titleId) || !endedAt.isAfter(startedAt.add(const Duration(seconds: 5)))) return;
    _learn(titleId, gameName, ageLevels);
    sessions.add({
      'id': uuidv4(),
      'titleId': titleId,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'endedAt': endedAt.toUtc().toIso8601String(),
      'exit': exit,
    });
    _save();
  }

  /// The game's trophy set as the launcher reads it now; the earned ones not sent yet go up.
  void recordTrophies(SyncTrophySet set) {
    if (!titleIdPattern.hasMatch(set.titleId) || set.trophies.isEmpty) return;
    gameNames[set.titleId] = set.gameName;
    sets[set.titleId] = set;
    _save();
  }

  /// Sends what waits, in the order the server needs it: this computer, the games' names, the
  /// trophy sets, the sessions, the earned trophies. Stops at the first failure; what was not
  /// sent stays for the next time.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      if (!deviceRegistered) {
        await account.call('POST', 'me/devices', {
          'id': deviceId,
          'platform': platform,
          'name': deviceName,
          'model': ?model,
        });
        deviceRegistered = true;
        _save();
      }
      for (final entry in gameNames.entries.toList()) {
        if (taughtGames.contains(entry.key)) continue;
        await account.call('PUT', 'games/${entry.key}', {
          'names': {'en': entry.value},
          'ageLevels': ?gameAges[entry.key],
        });
        taughtGames.add(entry.key);
        _save();
      }
      for (final set in sets.values.toList()) {
        if (uploadedSets.contains(set.key)) continue;
        await account.call('PUT', 'trophy-sets/${set.titleId}/${set.setHash}', {
          'trophies': [
            for (final trophy in set.trophies)
              {
                'id': trophy.id,
                'grade': trophy.grade,
                'hidden': trophy.hidden,
                'texts': {
                  set.language: {'name': trophy.name, if (trophy.detail.trim().isNotEmpty) 'detail': trophy.detail},
                },
              },
          ],
        });
        uploadedSets.add(set.key);
        _save();
      }

      final batch = sessions.take(200).toList();
      if (batch.isNotEmpty) {
        final results = _results(
          await account.call('POST', 'me/sessions', {
            'sessions': [
              for (final session in batch) {...session, 'deviceId': deviceId},
            ],
          }),
        );
        if (results.any((result) => result.code == 'unknown_device')) deviceRegistered = false;
        // Stored and duplicate ones are done; ones rejected for a bad item are dropped too, as
        // sending them again cannot fix them. Only an unknown device keeps them.
        final keep = {
          for (final result in results)
            if (result.status == 'rejected' && result.code == 'unknown_device') result.index,
        };
        final done = {
          for (var index = 0; index < batch.length; index++)
            if (!keep.contains(index)) batch[index]['id'],
        };
        sessions.removeWhere((session) => done.contains(session['id']));
        _save();
      }

      final earned = _pendingTrophies().take(200).toList();
      if (earned.isNotEmpty) {
        final results = _results(
          await account.call('POST', 'me/trophies', {
            'trophies': [
              for (final trophy in earned)
                {
                  'titleId': trophy.titleId,
                  'setHash': trophy.setHash,
                  'trophyId': trophy.trophyId,
                  'earnedAt': trophy.earnedAt.toUtc().toIso8601String(),
                },
            ],
          }),
        );
        for (final result in results) {
          if (result.status == 'rejected' && result.code == 'unknown_trophy') continue;
          if (result.index >= 0 && result.index < earned.length) sentTrophies.add(earned[result.index].key);
        }
        // The server lost a set (or never had it): taught again next time.
        if (results.any((result) => result.code == 'unknown_trophy')) uploadedSets.clear();
        _save();
      }
    } finally {
      _flushing = false;
    }
  }

  List<({String titleId, String setHash, int trophyId, DateTime earnedAt, String key})> _pendingTrophies() => [
    for (final set in sets.values)
      for (final trophy in set.trophies)
        if (trophy.earnedAt != null && !sentTrophies.contains('${set.titleId}/${trophy.id}'))
          (
            titleId: set.titleId,
            setHash: set.setHash,
            trophyId: trophy.id,
            earnedAt: trophy.earnedAt!,
            key: '${set.titleId}/${trophy.id}',
          ),
  ];

  static List<({int index, String status, String? code})> _results(Map<String, dynamic> json) => [
    for (final result in json['results'] as List<dynamic>? ?? const [])
      if (result is Map<String, dynamic>)
        (
          index: (result['index'] as num? ?? -1).toInt(),
          status: result['status'] as String? ?? '',
          code: result['code'] as String?,
        ),
  ];
}

/// A random UUID (version 4).
String uuidv4([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = 0x40 | (bytes[6] & 0x0f);
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
