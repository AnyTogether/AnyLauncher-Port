import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/font_download.dart';
import 'package:anyps5_desktop/core/free_space.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// One request the fake server saw.
typedef Seen = ({String path, String? range});

/// A file server on loopback written on a raw socket, so it can do what a real one does when
/// things go wrong: drop the connection halfway, ignore Range, redirect to its storage.
class FakeFileServer {
  FakeFileServer._(this._socket, this.body);

  static Future<FakeFileServer> start(Uint8List body) async =>
      FakeFileServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), body).._listen();

  final ServerSocket _socket;
  Uint8List body;
  final List<Seen> seen = [];

  /// Requests that are cut off after this many bytes of the body, in order.
  final List<int> dropAfter = [];

  /// Answers every request with the whole file (200), whatever Range asks.
  bool ignoreRange = false;

  /// /zip answers with a redirect to /storage/zip, as GitHub does.
  bool redirect = false;

  Uri get url => Uri.parse('http://127.0.0.1:${_socket.port}/zip');

  void _listen() {
    _socket.listen((client) {
      final buffer = <int>[];
      late StreamSubscription<Uint8List> subscription;
      subscription = client.listen((data) {
        buffer.addAll(data);
        final text = latin1.decode(buffer);
        if (!text.contains('\r\n\r\n')) return;
        subscription.pause();
        unawaited(_answer(client, text));
      }, onError: (_) {});
    });
  }

  Future<void> _answer(Socket client, String request) async {
    final lines = request.split('\r\n');
    final path = lines.first.split(' ')[1];
    String? range;
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).toLowerCase() == 'range') range = line.substring(colon + 1).trim();
    }
    seen.add((path: path, range: range));
    try {
      if (redirect && path == '/zip') {
        client.write('HTTP/1.1 302 Found\r\nLocation: /storage/zip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
        return;
      }
      var start = 0;
      if (!ignoreRange && range != null) start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= body.length && range != null && !ignoreRange) {
        client.write('HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
        return;
      }
      final rest = body.sublist(start);
      final head = start > 0
          ? 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes $start-${body.length - 1}/${body.length}\r\n'
          : 'HTTP/1.1 200 OK\r\n';
      client.write('${head}Content-Length: ${rest.length}\r\nConnection: close\r\n\r\n');
      if (dropAfter.isNotEmpty) {
        client.add(rest.sublist(0, dropAfter.removeAt(0)));
        await client.flush();
        client.destroy();
        return;
      }
      client.add(rest);
    } finally {
      try {
        await client.flush();
        await client.close();
      } on Object {
        // Destroyed on purpose.
      }
    }
  }

  Future<void> close() => _socket.close();
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory temp;
  late String folder;
  late FakeFileServer server;
  // Noise, so the zip is about as large as the fonts in it.
  final random = Random(5);
  final regular = Uint8List.fromList(List.generate(60000, (_) => random.nextInt(256)));
  final bold = Uint8List.fromList(List.generate(40000, (_) => random.nextInt(256)));
  final licence = utf8.encode('SIL Open Font License, Version 1.1');

  Uint8List zip({List<int>? boldBytes}) {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('NotoSansCJK-Regular.ttc', regular))
      ..addFile(ArchiveFile.bytes('fonts/NotoSansCJK-Bold.ttc', boldBytes ?? bold))
      ..addFile(ArchiveFile.bytes('NotoSansCJK-Black.ttc', [1, 2, 3]))
      ..addFile(ArchiveFile.bytes('LICENSE', licence));
    return ZipEncoder().encodeBytes(archive);
  }

  FontArchive package(Uint8List body, {String? sha, String? boldSha}) => FontArchive(
    url: server.url,
    size: body.length,
    sha256: sha ?? _sha(body),
    members: [
      FontArchiveMember('NotoSansCJK-Regular.ttc', size: regular.length, sha256: _sha(regular)),
      FontArchiveMember('NotoSansCJK-Bold.ttc', size: bold.length, sha256: boldSha ?? _sha(bold)),
      FontArchiveMember('LICENSE', savedAs: 'LICENSE-NotoSansCJK.txt', size: licence.length, sha256: _sha(licence)),
    ],
  );

  FontInstaller installer(FontArchive archive, {int? free, int attempts = 4}) =>
      FontInstaller(folder, archive: archive, attempts: attempts, retryDelay: Duration.zero, freeSpace: (_) => free);

  void expectInstalled() {
    expect(File(p.join(folder, 'NotoSansCJK-Regular.ttc')).readAsBytesSync(), regular);
    expect(File(p.join(folder, 'NotoSansCJK-Bold.ttc')).readAsBytesSync(), bold);
    expect(File(p.join(folder, 'LICENSE-NotoSansCJK.txt')).readAsBytesSync(), licence);
    expect(File(p.join(folder, 'NotoSansCJK-Black.ttc')).existsSync(), isFalse, reason: 'only the members asked for');
    expect(Directory(p.join(folder, '.download')).existsSync(), isFalse, reason: 'the zip is deleted');
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fontdownload');
    folder = p.join(temp.path, 'Downloaded');
    server = await FakeFileServer.start(zip());
  });

  tearDown(() async {
    await server.close();
    temp.deleteSync(recursive: true);
  });

  test('downloads, checks and unpacks only the fonts asked for', () async {
    final fonts = installer(package(server.body));
    expect(fonts.installed, isFalse);
    final progress = <double>[];
    await fonts.install(onProgress: progress.add);
    expectInstalled();
    expect(fonts.installed, isTrue);
    expect(progress.last, 1);
    expect(progress, orderedEquals([...progress]..sort()));
    expect(server.seen.single.range, isNull);
    // Already there: nothing is asked for again.
    await fonts.install();
    expect(server.seen, hasLength(1));
  });

  test('carries on from where a dropped connection stopped, asking for the rest', () async {
    server.dropAfter.addAll([4000, 9000]);
    final fonts = installer(package(server.body));
    await fonts.install();
    expectInstalled();
    expect(server.seen.map((request) => request.range), [null, 'bytes=4000-', 'bytes=13000-']);
  });

  test('keeps the range across the redirect to the storage', () async {
    server
      ..redirect = true
      ..dropAfter.add(5000);
    await installer(package(server.body)).install();
    expectInstalled();
    expect(server.seen.map((request) => '${request.path} ${request.range}'), [
      '/zip null',
      '/storage/zip null',
      '/zip bytes=5000-',
      '/storage/zip bytes=5000-',
    ]);
  });

  test('starts again when the server ignores the range and sends the whole file', () async {
    server
      ..ignoreRange = true
      ..dropAfter.add(6000);
    await installer(package(server.body)).install();
    expectInstalled();
    expect(server.seen.map((request) => request.range), [null, 'bytes=6000-']);
  });

  test('a finished part is checked and used without asking again', () async {
    final archive = package(server.body);
    final part = File(p.join(folder, '.download', '${archive.fileName}.part'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(server.body);
    expect(part.existsSync(), isTrue);
    await installer(archive).install();
    expectInstalled();
    expect(server.seen, isEmpty);
  });

  test('gives up after its tries when the connection keeps dropping, keeping the part', () async {
    server.dropAfter.addAll([1000, 1000, 1000]);
    final archive = package(server.body);
    await expectLater(installer(archive, attempts: 3).install(), throwsA(isA<FontInstallFailure>()));
    expect(server.seen, hasLength(3));
    expect(File(p.join(folder, '.download', '${archive.fileName}.part')).lengthSync(), 3000);
    // The next install carries on.
    await installer(archive).install();
    expectInstalled();
    expect(server.seen.last.range, 'bytes=3000-');
  });

  test('refuses a zip whose SHA-256 is not the expected one', () async {
    final archive = package(server.body, sha: 'f' * 64);
    await expectLater(
      installer(archive).install(),
      throwsA(isA<FontInstallFailure>().having((failure) => failure.message, 'message', contains('checksum'))),
    );
    expect(server.seen, hasLength(1), reason: 'a wrong file is not downloaded again and again');
    expect(SystemFontsFiles.inFolder(folder), isEmpty);
    expect(File(p.join(folder, '.download', '${archive.fileName}.part')).existsSync(), isFalse);
  });

  test('refuses a member that is not the expected file, keeping none of it', () async {
    final archive = package(server.body, boldSha: '0' * 64);
    await expectLater(
      installer(archive).install(),
      throwsA(isA<FontInstallFailure>().having((failure) => failure.message, 'message', contains('NotoSansCJK-Bold'))),
    );
    expect(File(p.join(folder, 'NotoSansCJK-Bold.ttc')).existsSync(), isFalse);
    expect(File(p.join(folder, 'NotoSansCJK-Bold.ttc.part')).existsSync(), isFalse);
    expect(installer(archive).installed, isFalse);
  });

  test('refuses an archive without a member it needs', () async {
    server.body = ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.bytes('LICENSE', licence)));
    await expectLater(
      installer(package(server.body)).install(),
      throwsA(isA<FontInstallFailure>().having((failure) => failure.message, 'message', contains('has no'))),
    );
  });

  test('says so before downloading when the disk is too full', () async {
    final archive = package(server.body);
    await expectLater(
      installer(archive, free: 1000).install(),
      throwsA(isA<FontInstallFailure>().having((failure) => failure.message, 'message', contains('free space'))),
    );
    expect(server.seen, isEmpty);
    expect(installer(archive).bytesNeeded, archive.size + archive.installedSize + FontInstaller.spare);
  });

  test('removal deletes the fonts and what a stopped download left', () async {
    final archive = package(server.body);
    await installer(archive).install();
    File(p.join(folder, '.download', 'x.part'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('left');
    installer(archive).remove();
    expect(SystemFontsFiles.inFolder(folder), isEmpty);
    expect(Directory(p.join(folder, '.download')).existsSync(), isFalse);
  });

  test('the real package is Noto Sans CJK 2.004 with the hashes checked by hand', () {
    final real = FontArchive.notoSansCjk;
    expect(real.url.host, 'github.com');
    expect(real.size, 104680673);
    expect(real.members.map((member) => member.savedAs), [
      'NotoSansCJK-Light.ttc',
      'NotoSansCJK-Regular.ttc',
      'NotoSansCJK-Medium.ttc',
      'NotoSansCJK-Bold.ttc',
      'LICENSE-NotoSansCJK.txt',
    ]);
    expect(real.installedSize, 76054549);
  });

  test('df output gives the available bytes', () {
    const output =
        'Filesystem     1024-blocks      Used Available Capacity Mounted on\n'
        '/dev/disk3s3s1   482797652  12345678   7340032    63%    /\n';
    expect(FreeSpace.parseDf(output), 7340032 * 1024);
    expect(FreeSpace.parseDf('nonsense'), isNull);
    expect(FreeSpace.of(temp.path), anyOf(isNull, greaterThan(0)));
  });
}

/// The files the tests look for in a folder, without its hidden download folder.
abstract final class SystemFontsFiles {
  static List<String> inFolder(String folder) => Directory(folder).existsSync()
      ? [
          for (final entity in Directory(folder).listSync())
            if (entity is File) p.basename(entity.path),
        ]
      : const [];
}
