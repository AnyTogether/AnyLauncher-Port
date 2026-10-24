import 'dart:io';

import 'package:anyps5_desktop/core/cli.dart';
import 'package:anyps5_desktop/core/glibc.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_elf.dart';
import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';

void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('glibc'));
  tearDown(() => temp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final file = p.join(temp.path, name);
    File(file).writeAsBytesSync(bytes);
    return file;
  }

  test('the system version from ldd --version: Ubuntu, Fedora, Debian; none from musl', () {
    expect(Glibc.parseLddVersion('ldd (Ubuntu GLIBC 2.35-0ubuntu3.13) 2.35\nCopyright (C) 2022'), '2.35');
    expect(Glibc.parseLddVersion('ldd (GNU libc) 2.39\nCopyright'), '2.39');
    expect(Glibc.parseLddVersion('ldd (Debian GLIBC 2.36-9+deb12u10) 2.36\n'), '2.36');
    expect(Glibc.parseLddVersion('musl libc (x86_64)\nVersion 1.2.4\n'), isNull);
    expect(Glibc.parseLddVersion(''), isNull);
  });

  test('versions compare number by number', () {
    expect(Glibc.compare('2.38', '2.4'), greaterThan(0));
    expect(Glibc.compare('2.35', '2.38'), lessThan(0));
    expect(Glibc.compare('2.35', '2.35.0'), 0);
    expect(Glibc.compare('2.2.5', '2.17'), lessThan(0));
  });

  test('the newest GLIBC version an ELF needs; not GLIBCXX, nothing from what is not an ELF', () {
    final library = write(
      'libkernel.prx',
      elfNeeding(['GLIBC_2.2.5', 'GLIBC_2.38', 'GLIBC_2.34', 'GLIBCXX_3.4.31', 'GLIBC_PRIVATE']),
    );
    expect(Glibc.required(library), '2.38');
    expect(Glibc.required(write('cxx.prx', elfNeeding(['GLIBCXX_3.4.31'], library: 'libstdc++.so.6'))), isNull);
    expect(Glibc.required(write('text.prx', 'kernel library'.codeUnits)), isNull);
    final whole = File(library).readAsBytesSync();
    expect(Glibc.required(write('cut.prx', whole.sublist(0, 80))), isNull);
    expect(Glibc.required(p.join(temp.path, 'missing.prx')), isNull);
  });

  test('a shortfall only when the libraries need more than the system has', () {
    final files = [
      write('a.prx', elfNeeding(['GLIBC_2.17'])),
      write('b.prx', elfNeeding(['GLIBC_2.38', 'GLIBC_2.32'])),
      write('c.prx', 'not an elf'.codeUnits),
    ];
    expect(Glibc.requiredByAll(files), '2.38');
    expect(Glibc.shortfall(files, host: '2.35'), (needed: '2.38', host: '2.35'));
    expect(Glibc.shortfall(files, host: '2.38'), isNull);
    expect(Glibc.shortfall(files, host: '2.39'), isNull);
    expect(Glibc.shortfall(files, host: null), isNull);
    expect(Glibc.shortfall([files[2]], host: '2.35'), isNull);
  });

  test('on Linux the system glibc is read and covers the running Dart executable', () {
    final host = Glibc.host();
    expect(host, isNotNull);
    final needed = Glibc.required(Platform.resolvedExecutable);
    if (needed != null) expect(Glibc.compare(needed, host!), lessThanOrEqualTo(0));
  }, testOn: 'linux');

  test('install on the command line warns when the toolkit needs a newer glibc', () async {
    final toolkit = makeFakeToolkit(p.join(temp.path, 'toolkit'));
    File(p.join(toolkit, 'libs', 'libkernel.prx')).writeAsBytesSync(elfNeeding(['GLIBC_2.38']));
    final root = p.join(temp.path, 'Games');
    final game = makeDump(root, 'G', titleId: 'PPSA07007', eboot: const [0]);
    File(p.join(game, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    Future<String> install(String glibc) async {
      final out = StringBuffer();
      await runCli(
        ['install', game, root],
        out: out,
        err: StringBuffer(),
        environment: {'HOME': p.join(temp.path, 'home'), 'ANYPS5_TOOLKIT': toolkit, 'ANYPS5_HOST_GLIBC': glibc},
        system: HostSystem.linux,
      );
      return out.toString();
    }

    expect(await install('2.35'), contains('warning: games need glibc 2.38 or newer; this system has 2.35'));
    expect(await install('2.39'), isNot(contains('warning: games need glibc')));
  });
}
