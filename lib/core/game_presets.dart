import 'dart:convert';
import 'dart:io';

/// The difficulty a game that reads the console's Game Presets starts with.
enum PresetDifficulty { gameDefault, easiest, easy, normal, hard, hardest }

/// Performance Mode or Resolution Mode.
enum PresetPriority { gameDefault, performance, resolution }

enum PresetSubtitles { gameDefault, on, off }

/// The console's Game Presets (Settings › Game Presets): the difficulty, performance or
/// resolution, camera inversion, subtitles and audio language a game that asks the console
/// (sceUserServiceGetGamePresets) starts with. Games that keep their own settings ignore them.
class GamePresets {
  const GamePresets({
    this.difficulty = PresetDifficulty.gameDefault,
    this.priority = PresetPriority.gameDefault,
    this.invertVerticalFirstPerson = false,
    this.invertHorizontalFirstPerson = false,
    this.invertVerticalThirdPerson = false,
    this.invertHorizontalThirdPerson = false,
    this.subtitles = PresetSubtitles.gameDefault,
    this.audioLanguage,
  });

  /// Every field optional: a file from an older or newer launcher still loads, and a value this
  /// version does not know is the default.
  factory GamePresets.fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((value) => value.name == name).firstOrNull ?? fallback;
    bool flag(Object? value) => value == true;
    final language = json['audioLanguage'];
    return GamePresets(
      difficulty: pick(PresetDifficulty.values, json['difficulty'], PresetDifficulty.gameDefault),
      priority: pick(PresetPriority.values, json['priority'], PresetPriority.gameDefault),
      invertVerticalFirstPerson: flag(json['invertVerticalFirstPerson']),
      invertHorizontalFirstPerson: flag(json['invertHorizontalFirstPerson']),
      invertVerticalThirdPerson: flag(json['invertVerticalThirdPerson']),
      invertHorizontalThirdPerson: flag(json['invertHorizontalThirdPerson']),
      subtitles: pick(PresetSubtitles.values, json['subtitles'], PresetSubtitles.gameDefault),
      audioLanguage: language is int ? language : null,
    );
  }

  final PresetDifficulty difficulty;
  final PresetPriority priority;
  final bool invertVerticalFirstPerson;
  final bool invertHorizontalFirstPerson;
  final bool invertVerticalThirdPerson;
  final bool invertHorizontalThirdPerson;
  final PresetSubtitles subtitles;

  /// A console language number ([ConsoleLanguage]), null for the game's default.
  final int? audioLanguage;

  /// Whether nothing is set: games start as they would on a fresh console.
  bool get isEmpty => this == const GamePresets();

  GamePresets copyWith({
    PresetDifficulty? difficulty,
    PresetPriority? priority,
    bool? invertVerticalFirstPerson,
    bool? invertHorizontalFirstPerson,
    bool? invertVerticalThirdPerson,
    bool? invertHorizontalThirdPerson,
    PresetSubtitles? subtitles,
    int? Function()? audioLanguage,
  }) => GamePresets(
    difficulty: difficulty ?? this.difficulty,
    priority: priority ?? this.priority,
    invertVerticalFirstPerson: invertVerticalFirstPerson ?? this.invertVerticalFirstPerson,
    invertHorizontalFirstPerson: invertHorizontalFirstPerson ?? this.invertHorizontalFirstPerson,
    invertVerticalThirdPerson: invertVerticalThirdPerson ?? this.invertVerticalThirdPerson,
    invertHorizontalThirdPerson: invertHorizontalThirdPerson ?? this.invertHorizontalThirdPerson,
    subtitles: subtitles ?? this.subtitles,
    audioLanguage: audioLanguage == null ? this.audioLanguage : audioLanguage(),
  );

  static String _engineName(Enum value) => value.name == 'gameDefault' ? 'default' : value.name;

  /// ANYPS5_GAME_PRESETS as the engine reads it: comma-separated key=value parts.
  String get engineValue {
    String flag(bool on) => on ? '1' : '0';
    return [
      'difficulty=${_engineName(difficulty)}',
      'priority=${_engineName(priority)}',
      'invert_1st_v=${flag(invertVerticalFirstPerson)}',
      'invert_1st_h=${flag(invertHorizontalFirstPerson)}',
      'invert_3rd_v=${flag(invertVerticalThirdPerson)}',
      'invert_3rd_h=${flag(invertHorizontalThirdPerson)}',
      'subtitles=${_engineName(subtitles)}',
      'audio_language=${audioLanguage ?? 'default'}',
    ].join(',');
  }

  /// The environment a game starts with; empty when nothing is set.
  Map<String, String> get environment => isEmpty ? const {} : {'ANYPS5_GAME_PRESETS': engineValue};

  Map<String, Object> toJson() => {
    'difficulty': difficulty.name,
    'priority': priority.name,
    'invertVerticalFirstPerson': invertVerticalFirstPerson,
    'invertHorizontalFirstPerson': invertHorizontalFirstPerson,
    'invertVerticalThirdPerson': invertVerticalThirdPerson,
    'invertHorizontalThirdPerson': invertHorizontalThirdPerson,
    'subtitles': subtitles.name,
    'audioLanguage': ?audioLanguage,
  };

  @override
  bool operator ==(Object other) =>
      other is GamePresets &&
      other.difficulty == difficulty &&
      other.priority == priority &&
      other.invertVerticalFirstPerson == invertVerticalFirstPerson &&
      other.invertHorizontalFirstPerson == invertHorizontalFirstPerson &&
      other.invertVerticalThirdPerson == invertVerticalThirdPerson &&
      other.invertHorizontalThirdPerson == invertHorizontalThirdPerson &&
      other.subtitles == subtitles &&
      other.audioLanguage == audioLanguage;

  @override
  int get hashCode => Object.hash(
    difficulty,
    priority,
    invertVerticalFirstPerson,
    invertHorizontalFirstPerson,
    invertVerticalThirdPerson,
    invertHorizontalThirdPerson,
    subtitles,
    audioLanguage,
  );
}

/// Where the presets are kept: one small file of their own, so that a profile can own its file
/// later (each profile's folder holding a GamePresets.json) without touching the rest.
class GamePresetsStore {
  const GamePresetsStore(this.file);

  final String file;

  GamePresets load() {
    try {
      final json = jsonDecode(File(file).readAsStringSync());
      return json is Map<String, dynamic> ? GamePresets.fromJson(json) : const GamePresets();
    } on Object {
      return const GamePresets();
    }
  }

  void save(GamePresets presets) {
    final target = File(file);
    target.parent.createSync(recursive: true);
    final temporary = File('$file.tmp')..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(presets.toJson()));
    temporary.renameSync(target.path);
  }
}
