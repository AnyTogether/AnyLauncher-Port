import 'dart:io';

import 'package:anyps5_desktop/core/game_archives.dart' show UnpackCancelled;
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_updates.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// A game's update added from a dump: checked against the game, put beside it as
/// `<folder>-UPDATE`, the game's own folder never written to.
void main() {
  late Directory temp;
  late String root;
  late Game game;

  setUp(() {
    temp = temporaryFolder('updates');
    root = p.join(temp.path, 'Games');
    makeDump(root, 'Orbit', titleId: 'PPSA01001', version: '01.002.000');
    game = GameLibrary.scan(root).single;
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('versions compare number by number', () {
    expect(GameUpdates.compareVersions('01.010.000', '01.004.000'), 1);
    expect(GameUpdates.compareVersions('01.004.000', '01.004'), 0);
    expect(GameUpdates.compareVersions('1.2', '01.010.000'), -1);
  });

  test('only a newer dump of the same title is an update', () {
    final elsewhere = p.join(temp.path, 'Downloads');
    expect(GameUpdates.check(p.join(elsewhere, 'nothing'), game).problem, UpdateProblem.notADump);
    expect(
      GameUpdates.check(makeDump(elsewhere, 'a', titleId: 'PPSA02002', version: '09.000.000'), game).problem,
      UpdateProblem.otherGame,
    );
    expect(
      GameUpdates.check(makeDump(elsewhere, 'b', titleId: 'PPSA01001', version: '01.002.000'), game).problem,
      UpdateProblem.notNewer,
    );
    expect(GameUpdates.check(game.folder, game).problem, UpdateProblem.notNewer);
    final ok = GameUpdates.check(makeDump(elsewhere, 'c', titleId: 'ppsa01001', version: '01.003.000'), game);
    expect(ok.problem, isNull);
    expect(ok.update?.shortVersion, '01.003');
    expect(GameUpdates.target(game), p.join(root, 'Orbit-UPDATE'));
  });

  test('installed beside the game, which then reads it as its update', () async {
    final update = GameUpdates.check(
      makeDump(p.join(temp.path, 'Downloads'), 'patch', titleId: 'PPSA01001', version: '01.005.000'),
      game,
    ).update!;
    final moved = await GameUpdates.install(update, game);
    expect(moved, isTrue, reason: 'the same drive: a rename');
    final again = GameLibrary.scan(root).single;
    expect(again.update?.version, '01.005.000');
    expect(again.version, '01.002.000');
    // With an update there, an older or the same one is refused, a newer one asks for the old to go.
    final newer = makeDump(p.join(temp.path, 'Downloads'), 'newer', titleId: 'PPSA01001', version: '01.006.000');
    expect(GameUpdates.check(newer, again).problem, UpdateProblem.haveOlder);
    final same = makeDump(p.join(temp.path, 'Downloads'), 'same', titleId: 'PPSA01001', version: '01.005.000');
    expect(GameUpdates.check(same, again).problem, UpdateProblem.haveNewer);
  });

  test('a copy (another drive) hears its progress and leaves nothing when stopped', () {
    final from = makeDump(temp.path, 'from', files: {'sce_module/big.prx': 'x' * (20 * 1024 * 1024)});
    final into = p.join(temp.path, 'into');
    final heard = <int>[];
    GameUpdates.copySync(from, into, progress: (done, total) => heard.add(done));
    expect(File(p.join(into, 'sce_module', 'big.prx')).lengthSync(), 20 * 1024 * 1024);
    expect(File(p.join(into, 'eboot.bin')).existsSync(), isTrue);
    expect(heard.length, greaterThan(2));
    final stopped = p.join(temp.path, 'stopped');
    expect(
      () => GameUpdates.copySync(from, stopped, progress: (done, total) {}, cancelled: () => true),
      throwsA(isA<UnpackCancelled>()),
    );
    expect(Directory(stopped).existsSync(), isFalse);
  });
}
