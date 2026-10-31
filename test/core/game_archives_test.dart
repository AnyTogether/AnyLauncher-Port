import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_archives.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// A game dropped into the games folder as a .zip: found, read, unpacked into the folder beside
/// it and never outside it.
void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = temporaryFolder('archives');
    root = p.join(temp.path, 'Games');
    Directory(root).createSync(recursive: true);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  final parameters = utf8.encode(
    jsonEncode({
      'titleId': 'PPSA07007',
      'contentVersion': '01.000.000',
      'localizedParameters': {
        'defaultLanguage': 'en-US',
        'en-US': {'titleName': 'Zipped Quest'},
      },
    }),
  );

  /// A zip of [files] (name to bytes) written into the games folder as [name].
  String zip(String name, Map<String, List<int>> files, {List<String> folders = const []}) {
    final archive = Archive();
    for (final folder in folders) {
      archive.addFile(ArchiveFile.directory(folder));
    }
    for (final MapEntry(:key, :value) in files.entries) {
      archive.addFile(ArchiveFile.bytes(key, value));
    }
    final path = p.join(root, name);
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    return path;
  }

  Map<String, List<int>> dump(String prefix) => {
    '${prefix}eboot.bin': List.filled(3000, 7),
    '${prefix}sce_sys/param.json': parameters,
    '${prefix}sce_module/libc.prx': List.filled(20 * 1024 * 1024, 1),
  };

  test('a zip with a dump in one folder unpacks into the folder beside it, that folder left out', () async {
    final path = zip('PPSA07007.zip', dump('Zipped Quest (PPSA07007)/'), folders: ['Zipped Quest (PPSA07007)/']);
    final found = GameArchives.find([root]);
    expect(found.map((archive) => archive.name), ['PPSA07007.zip']);
    final archive = found.single;
    expect(archive.folder, p.join(root, 'PPSA07007'));
    final plan = GameArchives.plan(path);
    expect(plan.strip, 'Zipped Quest (PPSA07007)/');
    expect(plan.looksLikeGame, isTrue);
    expect(plan.refused, isEmpty);
    expect(plan.files, 3);
    expect(plan.size, 3000 + parameters.length + 20 * 1024 * 1024);

    final heard = <(int, int)>[];
    await GameArchives.unpack(archive, progress: (done, total) => heard.add((done, total)));
    expect(File(p.join(archive.folder, 'eboot.bin')).lengthSync(), 3000);
    expect(File(p.join(archive.folder, 'sce_module', 'libc.prx')).lengthSync(), 20 * 1024 * 1024);
    expect(Directory(archive.partial).existsSync(), isFalse);
    expect(heard.last, (plan.size, plan.size));
    expect(heard.length, greaterThan(1), reason: 'a large file is heard while it is written');
    // The library reads it as any other dump; the zip is not offered again.
    expect(GameLibrary.scan(root).single.titleId, 'PPSA07007');
    expect(GameArchives.find([root]), isEmpty);
    expect(File(path).existsSync(), isTrue, reason: 'the zip itself is the user\'s to remove');
  });

  test('a dump at the top of the zip unpacks as it is; one folder down is looked in too', () async {
    Directory(p.join(root, 'Downloads')).createSync();
    zip(p.join('Downloads', 'game.zip'), dump(''));
    final archive = GameArchives.find([root]).single;
    expect(archive.folder, p.join(root, 'Downloads', 'game'));
    expect(GameArchives.plan(archive.path).strip, '');
    await GameArchives.unpack(archive);
    expect(File(p.join(root, 'Downloads', 'game', 'sce_sys', 'param.json')).existsSync(), isTrue);
  });

  test('a zip with no game in it is not a game, and a zip already unpacked is not offered', () {
    final path = zip('photos.zip', {
      'a.png': [1, 2, 3],
    });
    expect(GameArchives.plan(path).looksLikeGame, isFalse);
    zip('Done.zip', dump(''));
    Directory(p.join(root, 'Done')).createSync();
    expect(GameArchives.find([root]).map((archive) => archive.name), ['photos.zip']);
    File(p.join(root, '.hidden.zip')).writeAsBytesSync([1]);
    expect(GameArchives.find([root]).map((archive) => archive.name), ['photos.zip']);
  });

  test('a name that would land outside the folder: the archive is refused and nothing is written', () async {
    expect(GameArchives.safePath(root, '../evil.txt'), isNull);
    expect(GameArchives.safePath(root, 'a/../../evil.txt'), isNull);
    expect(GameArchives.safePath(root, r'a\..\..\evil.txt'), isNull);
    expect(GameArchives.safePath(root, '/etc/passwd'), isNull);
    expect(GameArchives.safePath(root, r'C:\Windows\evil.dll'), isNull);
    expect(GameArchives.safePath(root, 'C:evil.dll'), isNull);
    expect(GameArchives.safePath(root, 'eboot.bin:stream'), isNull);
    expect(GameArchives.safePath(root, 'sce_sys/param.json'), p.join(root, 'sce_sys', 'param.json'));
    expect(GameArchives.safePath(root, './sce_sys//param.json'), p.join(root, 'sce_sys', 'param.json'));

    final path = zip('Evil.zip', {...dump(''), '../../escaped.txt': utf8.encode('out')});
    final plan = GameArchives.plan(path);
    expect(plan.refused, ['../../escaped.txt']);
    final archive = GameArchives.find([root]).single;
    await expectLater(GameArchives.unpack(archive), throwsA(isA<ArchiveException>()));
    expect(File(p.join(temp.path, 'escaped.txt')).existsSync(), isFalse);
    expect(File(p.join(p.dirname(temp.path), 'escaped.txt')).existsSync(), isFalse);
    expect(Directory(archive.folder).existsSync(), isFalse);
    expect(Directory(archive.partial).existsSync(), isFalse);
  });

  test('a stop asked for removes what was written', () async {
    zip('Stopped.zip', dump(''));
    final archive = GameArchives.find([root]).single;
    final cancel = UnpackCancel(p.join(temp.path, 'stop'));
    await expectLater(
      GameArchives.unpack(archive, cancel: cancel, progress: (done, total) => cancel.cancel()),
      throwsA(isA<UnpackCancelled>()),
    );
    expect(Directory(archive.folder).existsSync(), isFalse);
    expect(Directory(archive.partial).existsSync(), isFalse);
    expect(File(cancel.marker).existsSync(), isFalse);
  });

  test('a file that is not a zip is no game, and unpacking it throws and leaves nothing', () async {
    File(p.join(root, 'Broken.zip')).writeAsStringSync('not a zip at all');
    final archive = GameArchives.find([root]).single;
    final plan = GameArchives.plan(archive.path);
    expect(plan.files, 0);
    expect(plan.looksLikeGame, isFalse);
    await expectLater(GameArchives.unpack(archive), throwsA(anything));
    expect(Directory(archive.partial).existsSync(), isFalse);
  });
}
