import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  late Directory root;

  setUp(() => root = temporaryFolder('library'));
  tearDown(() => root.deleteSync(recursive: true));

  test('reads a dump: title ID, names, version, pictures and executable kind', () {
    final folder = makeDump(
      root.path,
      'Game',
      titleId: 'PPSA01234',
      version: '01.002.000',
      names: {'en-US': 'Astro', 'tr-TR': 'Astro TR', 'fr-FR': 'Astro FR'},
      pictures: ['icon0.png', 'pic0.png', 'snd0.at9'],
    );
    final game = GameLibrary.inspect(folder)!;
    expect(game.titleId, 'PPSA01234');
    expect(game.name, 'Astro');
    expect(game.names, {'en-US': 'Astro', 'tr-TR': 'Astro TR', 'fr-FR': 'Astro FR'});
    expect(game.version, '01.002.000');
    expect(game.executable, ExecutableKind.elf);
    expect(game.icon, p.join(folder, 'sce_sys', 'icon0.png'));
    expect(game.background, p.join(folder, 'sce_sys', 'pic0.png'));
    expect(game.music, p.join(folder, 'sce_sys', 'snd0.at9'));
    expect(game.slug, 'ppsa01234');
  });

  test('the default language picks the name, inside localizedParameters or at the top', () {
    final inside = makeDump(root.path, 'A', names: {'en-US': 'English', 'ja-JP': 'Japanese'}, defaultLanguage: 'ja-JP');
    final top = makeDump(
      root.path,
      'B',
      names: {'en-US': 'English', 'de-DE': 'German'},
      defaultLanguage: 'de-DE',
      defaultLanguageAtTop: true,
    );
    final missing = makeDump(root.path, 'C', names: {'en-US': 'English'}, defaultLanguage: 'ko-KR');
    expect(GameLibrary.inspect(inside)!.name, 'Japanese');
    expect(GameLibrary.inspect(top)!.name, 'German');
    expect(GameLibrary.inspect(missing)!.name, 'English');
  });

  test('nameFor follows the launcher language, by tag or by language prefix', () {
    final game = GameLibrary.inspect(makeDump(root.path, 'G', names: {'en-US': 'Hello', 'tr-TR': 'Merhaba'}))!;
    expect(game.nameFor(['tr-TR']), 'Merhaba');
    expect(game.nameFor(['tr']), 'Merhaba');
    expect(game.nameFor(['de-DE', 'tr-TR']), 'Merhaba');
    expect(game.nameFor(['de-DE']), 'Hello');
  });

  test('missing fields fall back: folder name as title ID, title ID as name, version 1.0', () {
    final folder = p.join(root.path, 'CUSA99999');
    Directory(p.join(folder, 'sce_sys')).createSync(recursive: true);
    File(p.join(folder, 'sce_sys', 'param.json')).writeAsStringSync('{}');
    File(p.join(folder, 'eboot.bin')).writeAsBytesSync(elfHead);
    final game = GameLibrary.inspect(folder)!;
    expect(game.titleId, 'CUSA99999');
    expect(game.name, 'CUSA99999');
    expect(game.version, '1.0');
    expect(game.icon, isNull);
  });

  test('a param.json with a byte order mark is read', () {
    final folder = makeDump(root.path, 'Bom', names: {'en-US': 'With BOM'}, bom: true);
    expect(GameLibrary.inspect(folder)!.name, 'With BOM');
  });

  test('executable kinds: SELF container, re-signed with .esbak, unreadable', () {
    final container = makeDump(root.path, 'Self', eboot: selfHead);
    final resigned = makeDump(root.path, 'Resigned', eboot: [1, 2, 3, 4]);
    File(p.join(resigned, 'eboot.bin.esbak')).writeAsBytesSync(elfHead);
    final encrypted = makeDump(root.path, 'Encrypted', eboot: [9, 9, 9, 9]);
    expect(GameLibrary.inspect(container)!.executable, ExecutableKind.container);
    expect(GameLibrary.inspect(resigned)!.executable, ExecutableKind.container);
    expect(GameLibrary.inspect(encrypted)!.executable, ExecutableKind.unreadable);
  });

  test('not a dump: no eboot.bin, no param.json, or param.json that is not an object', () {
    final noEboot = Directory(p.join(root.path, 'NoEboot', 'sce_sys'))..createSync(recursive: true);
    File(p.join(noEboot.path, 'param.json')).writeAsStringSync('{"titleId":"X"}');
    final noParam = Directory(p.join(root.path, 'NoParam'))..createSync();
    File(p.join(noParam.path, 'eboot.bin')).writeAsBytesSync(elfHead);
    final broken = makeDump(root.path, 'Broken');
    File(p.join(broken, 'sce_sys', 'param.json')).writeAsStringSync('[1, 2]');
    expect(GameLibrary.inspect(p.join(root.path, 'NoEboot')), isNull);
    expect(GameLibrary.inspect(noParam.path), isNull);
    expect(GameLibrary.inspect(broken), isNull);
  });

  test('scan finds dumps three levels down, sorted by name, skipping the store and hidden folders', () {
    makeDump(root.path, 'zeta', names: {'en-US': 'Zeta'});
    makeDump(p.join(root.path, 'one'), 'alpha', names: {'en-US': 'alpha'});
    makeDump(p.join(root.path, 'one', 'two'), 'Beta', names: {'en-US': 'Beta'});
    makeDump(p.join(root.path, 'a', 'b', 'c', 'd'), 'TooDeep', names: {'en-US': 'Too deep'});
    makeDump(p.join(root.path, GameLibrary.storeName), 'Stored', names: {'en-US': 'Stored'});
    makeDump(p.join(root.path, '.hidden'), 'Hidden', names: {'en-US': 'Hidden'});
    makeDump(p.join(root.path, 'sce_module'), 'Module', names: {'en-US': 'Module'});
    // A dump inside a dump is part of it, not another game.
    makeDump(p.join(root.path, 'zeta'), 'inner', names: {'en-US': 'Inner'});
    final games = GameLibrary.scan(root.path);
    expect(games.map((game) => game.name), ['alpha', 'Beta', 'Zeta']);
  });

  test('scan of a folder that does not exist finds nothing', () {
    expect(GameLibrary.scan(p.join(root.path, 'missing')), isEmpty);
  });

  test('size adds up the files', () {
    final folder = makeDump(root.path, 'Sized', files: {'data/a.bin': '12345', 'b.bin': '123'});
    expect(GameLibrary.size(folder), greaterThanOrEqualTo(8));
  });
}
