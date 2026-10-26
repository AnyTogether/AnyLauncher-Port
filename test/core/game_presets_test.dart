import 'dart:io';

import 'package:anyps5_desktop/core/game_presets.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('presets'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('nothing set passes nothing, so games start as on a fresh console', () {
    expect(const GamePresets().isEmpty, isTrue);
    expect(const GamePresets().environment, isEmpty);
  });

  test('every setting reaches the engine in one variable', () {
    const presets = GamePresets(
      difficulty: PresetDifficulty.hard,
      priority: PresetPriority.performance,
      invertVerticalFirstPerson: true,
      invertHorizontalThirdPerson: true,
      subtitles: PresetSubtitles.on,
      audioLanguage: 19,
    );
    expect(presets.isEmpty, isFalse);
    expect(presets.environment, {
      'ANYPS5_GAME_PRESETS':
          'difficulty=hard,priority=performance,invert_1st_v=1,invert_1st_h=0,invert_3rd_v=0,invert_3rd_h=1,subtitles=on,audio_language=19',
    });
    const other = GamePresets(priority: PresetPriority.resolution, subtitles: PresetSubtitles.off);
    expect(other.engineValue,
        'difficulty=default,priority=resolution,invert_1st_v=0,invert_1st_h=0,invert_3rd_v=0,invert_3rd_h=0,subtitles=off,audio_language=default');
  });

  test('copyWith changes one setting, and clears the audio language back to the default', () {
    const presets = GamePresets(audioLanguage: 4);
    expect(presets.copyWith(difficulty: PresetDifficulty.easy).difficulty, PresetDifficulty.easy);
    expect(presets.copyWith(difficulty: PresetDifficulty.easy).audioLanguage, 4);
    expect(presets.copyWith(audioLanguage: () => null).audioLanguage, isNull);
    expect(presets.copyWith(audioLanguage: () => null).isEmpty, isTrue);
  });

  test('the store keeps them in a file of their own', () {
    final store = GamePresetsStore(p.join(temp.path, 'config', 'GamePresets.json'));
    expect(store.load(), const GamePresets(), reason: 'no file is nothing set');
    const presets = GamePresets(difficulty: PresetDifficulty.easiest, invertVerticalThirdPerson: true, audioLanguage: 0);
    store.save(presets);
    expect(store.load(), presets);
    expect(store.load().audioLanguage, 0, reason: 'Japanese is a language, not the default');
  });

  test('a file from another version still loads', () {
    final file = File(p.join(temp.path, 'GamePresets.json'))
      ..writeAsStringSync('{"difficulty":"hard","priority":"turbo","future":true}');
    final presets = GamePresetsStore(file.path).load();
    expect(presets.difficulty, PresetDifficulty.hard);
    expect(presets.priority, PresetPriority.gameDefault, reason: 'a value this version does not know is the default');
    file.writeAsStringSync('not json');
    expect(GamePresetsStore(file.path).load(), const GamePresets());
  });
}
