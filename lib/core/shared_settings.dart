import 'dart:convert';

import 'game_settings.dart';

/// Not an AnyPS5 settings file.
class SharedSettingsRefused implements Exception {
  const SharedSettingsRefused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// A game's settings as a file to share (Game Settings › Export Settings): the macOS launcher's
/// SharedSettings, key for key and sorted the same way, so a file made on one system imports on
/// the other.
class SharedSettings {
  const SharedSettings({required this.titleId, required this.game, required this.settings});

  static const format = 'anyps5-settings';
  static const version = 1;

  final String titleId;

  /// The game's name where the file was made.
  final String game;
  final GameSettings settings;

  /// The file's text: pretty-printed JSON with its keys sorted.
  String encode() => const JsonEncoder.withIndent('  ').convert(
    _sorted({'format': format, 'version': version, 'titleID': titleId, 'game': game, 'settings': settings.toJson()}),
  );

  /// The settings in a file's [text]; throws [SharedSettingsRefused] for anything else.
  static SharedSettings decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const SharedSettingsRefused('not JSON');
    }
    if (json is! Map<String, dynamic> || json['format'] != format) {
      throw const SharedSettingsRefused('not an AnyPS5 settings file');
    }
    final settings = json['settings'];
    final titleId = json['titleID'];
    final game = json['game'];
    if (settings is! Map<String, dynamic> || titleId is! String || game is! String) {
      throw const SharedSettingsRefused('an AnyPS5 settings file without its settings');
    }
    try {
      return SharedSettings(titleId: titleId, game: game, settings: GameSettings.fromJson(settings));
    } on Object {
      throw const SharedSettingsRefused('settings that cannot be read');
    }
  }

  static Object? _sorted(Object? value) => switch (value) {
    final Map<String, Object?> map => {for (final key in map.keys.toList()..sort()) key: _sorted(map[key])},
    final Map<dynamic, dynamic> map => {
      for (final key in map.keys.map((key) => '$key').toList()..sort()) key: _sorted(map[key]),
    },
    final List<Object?> list => [for (final item in list) _sorted(item)],
    _ => value,
  };
}
