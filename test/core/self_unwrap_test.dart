import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/binary.dart';
import 'package:anyps5_desktop/core/self_unwrap.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/self_builder.dart';

/// Upstream's reference unwrapper, read where the macOS project is checked out (never changed).
final referenceScript =
    Platform.environment['ANYPS5_UNWRAP_SELF_PY'] ?? '/Users/dc/Desktop/Projects/anyps5/AnyPS5/tools/unwrap_self.py';

class Header {
  Header(List<int> data, int at)
    : type = Binary.u32(data, at),
      offset = Binary.u64(data, at + 8),
      vaddr = Binary.u64(data, at + 16),
      paddr = Binary.u64(data, at + 24),
      size = Binary.u64(data, at + 32),
      memory = Binary.u64(data, at + 40),
      align = Binary.u64(data, at + 48);
  final int type, offset, vaddr, paddr, size, memory, align;
}

List<Header> headersOf(Uint8List elf) {
  final table = Binary.u64(elf, 0x20);
  final count = Binary.u16(elf, 0x38);
  return [for (var index = 0; index < count; index++) Header(elf, table + index * 56)];
}

/// A random container: loads, segments inside them, segments without a vaddr, records that
/// name their header or only match by size, sometimes broken on purpose.
Uint8List randomSelf(int seed) {
  final random = Random(seed);
  final segments = <FakeSegment>[];
  var at = 0x400 + random.nextInt(8) * 0x10;
  var vaddr = 0;
  var elfOffset = 0;
  final loads = 1 + random.nextInt(3);
  final hosts = <(int vaddr, int size)>[];
  for (var index = 0; index < loads; index++) {
    final align = [0x10, 0x1000, 0x4000, 0x10000][random.nextInt(4)];
    final size = 0x40 + random.nextInt(0x1800);
    vaddr = (vaddr + align - 1) ~/ align * align + random.nextInt(3) * align;
    hosts.add((vaddr, size));
    segments.add(
      FakeSegment(
        type: ptLoad,
        flags: 5 + index,
        vaddr: vaddr,
        fileSize: size,
        memorySize: size + random.nextInt(0x800),
        align: align,
        elfOffset: elfOffset,
        at: at,
        recorded: random.nextInt(5) != 0,
        encrypted: random.nextInt(9) == 0,
      ),
    );
    at = (at + size + 0x10 + random.nextInt(0x100)) ~/ 0x10 * 0x10;
    vaddr += size + 0x800;
    elfOffset += 0x4000;
  }
  final inside = random.nextInt(4);
  for (var index = 0; index < inside; index++) {
    final (base, size) = hosts[random.nextInt(hosts.length)];
    final offset = random.nextInt(size);
    final length = random.nextInt(9) == 0 ? size : random.nextInt(max(1, size - offset));
    segments.add(
      FakeSegment(
        type: [ptDynamic, ptTls, ptGnuEhFrame, ptSceProcParam][random.nextInt(4)],
        vaddr: random.nextInt(12) == 0 ? 0x7FFF0000 : base + offset,
        fileSize: length,
        align: [1, 4, 8, 0x10][random.nextInt(4)],
        elfOffset: elfOffset + offset,
      ),
    );
  }
  final unaddressed = random.nextInt(4);
  for (var index = 0; index < unaddressed; index++) {
    final size = random.nextInt(0x300);
    final stored = random.nextInt(3) != 0;
    segments.add(
      FakeSegment(
        type: [ptSceDynlibData, ptNote, 0x6FFFFF01, 0x61000002][random.nextInt(4)],
        fileSize: size,
        align: 0x10,
        elfOffset: 0x8000 + index * 0x400,
        at: stored ? at : null,
        recorded: random.nextBool(),
      ),
    );
    if (stored) at = (at + size + 0x10) ~/ 0x10 * 0x10;
  }
  if (random.nextInt(4) == 0) {
    segments.add(
      FakeSegment(
        type: ptLoad,
        vaddr: 0x40000 + random.nextInt(0x100) * 0x10,
        fileSize: 0,
        memorySize: 0x2000,
        align: [0x10, 0x4000, 0x100000][random.nextInt(3)],
      ),
    );
  }
  if (random.nextInt(10) == 0) segments.shuffle(random);
  final data = buildSelf(segments, seed: seed, length: random.nextInt(6) == 0 ? at - random.nextInt(0x200) : null);
  if (random.nextInt(20) == 0) data[0] ^= 0xFF;
  if (random.nextInt(25) == 0) {
    // A program header table that is cut or claims a strange entry size.
    final inner = data.indexOf(0x7F, 0x40);
    data[inner + 0x36] = random.nextBool() ? 0x30 : 56;
    data[inner + 0x38] = random.nextBool() ? 0 : 0xFF;
  }
  return data;
}

void main() {
  late Directory folder;

  setUp(() => folder = temporaryFolder('unwrap'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('isContainer reads both magics', () {
    final normal = p.join(folder.path, 'a');
    final kernel = p.join(folder.path, 'b');
    final elf = p.join(folder.path, 'c');
    File(normal).writeAsBytesSync([0x4F, 0x15, 0x3D, 0x1D, 0]);
    File(kernel).writeAsBytesSync([0x54, 0x14, 0xF5, 0xEE]);
    File(elf).writeAsBytesSync(elfHead);
    expect(SelfUnwrap.isContainer(normal), isTrue);
    expect(SelfUnwrap.isContainer(kernel), isTrue);
    expect(SelfUnwrap.isContainer(elf), isFalse);
    expect(SelfUnwrap.isContainer(p.join(folder.path, 'missing')), isFalse);
  });

  test('a typical container: segments land aligned, the bytes follow, the header is clean', () {
    final input = typicalSelf();
    final output = SelfUnwrap.unwrap(input);
    expect(output.sublist(0, 4), [0x7F, 0x45, 0x4C, 0x46]);
    // Section header fields are cleared; the rest of the ELF header is kept.
    expect(Binary.u64(output, 0x28), 0);
    expect(Binary.u16(output, 0x3C), 0);
    expect(Binary.u16(output, 0x3E), 0);
    expect(Binary.u64(output, 0x18), 0x1230);
    final headers = headersOf(output);
    expect(headers, hasLength(10));
    for (final header in headers) {
      expect(header.paddr, header.vaddr);
      if (header.type == ptLoad && header.size != 0 && header.align > 1) {
        expect(header.offset % header.align, header.vaddr % header.align, reason: 'p_offset ≡ p_vaddr mod p_align');
      }
      expect(header.offset + header.size, lessThanOrEqualTo(output.length));
    }
    // The code load's bytes are the container's bytes at its record.
    final code = headers[0];
    expect(output.sublist(code.offset, code.offset + code.size), input.sublist(0x500, 0x500 + 0x2345));
    // The dynamic segment is read through the data load's mapping.
    final data = headers[1];
    final dynamic = headers[2];
    expect(dynamic.offset, data.offset + 0x100);
    // The recorded dynlib data keeps its bytes; the trailing note has none; the version segment
    // after it is stored right behind the dynlib data.
    final dynlib = headers[6];
    expect(output.sublist(dynlib.offset, dynlib.offset + 0x300), input.sublist(0x3a60, 0x3a60 + 0x300));
    expect(headers[7].size, 0);
    expect(headers[7].offset, 0);
    expect(headers[8].size, 0x18);
    expect(output.sublist(headers[8].offset, headers[8].offset + 0x18), input.sublist(0x3d60, 0x3d60 + 0x18));
    // The empty load sits at its vaddr's offset within its alignment.
    expect(headers[9].offset, 0x10000 % 0x4000);
  });

  test('a load without a has-segment record is matched by size', () {
    final input = buildSelf([
      FakeSegment(type: ptLoad, vaddr: 0x4000, fileSize: 0x800, align: 0x4000, at: 0x400, recorded: false),
    ]);
    final output = SelfUnwrap.unwrap(input);
    final header = headersOf(output).single;
    expect(header.offset % 0x4000, 0);
    expect(output.sublist(header.offset, header.offset + 0x800), input.sublist(0x400, 0xC00));
  });

  test('refusals', () {
    expect(() => SelfUnwrap.unwrap(Uint8List(0x100)), throwsA(isA<SelfRefused>()));
    final notSelf = typicalSelf()..[0] = 0;
    expect(
      () => SelfUnwrap.unwrap(notSelf),
      throwsA(predicate((e) => e.toString().startsWith('not a SELF container (magic 0x'))),
    );
    final encrypted = buildSelf([
      FakeSegment(type: ptLoad, vaddr: 0, fileSize: 0x4000, align: 0x4000, at: 0x400, encrypted: true),
    ]);
    expect(
      () => SelfUnwrap.unwrap(encrypted),
      throwsA(predicate((e) => e.toString().startsWith('every load segment looks encrypted: segment 0 at 0x400 ('))),
    );
    final noElf = Uint8List(0x800)..setRange(0, 4, [0x4F, 0x15, 0x3D, 0x1D]);
    expect(() => SelfUnwrap.unwrap(noElf), throwsA(predicate((e) => e.toString() == 'no inner ELF header')));
    final outside = buildSelf([
      FakeSegment(type: ptLoad, vaddr: 0, fileSize: 0x100, align: 0x10, at: 0x400),
      FakeSegment(type: ptDynamic, vaddr: 0x9000, fileSize: 0x10),
    ]);
    expect(
      () => SelfUnwrap.unwrap(outside),
      throwsA(predicate((e) => e.toString() == 'segment 1 vaddr 0x9000 is in no PT_LOAD')),
    );
  });

  test('unwrapFile writes the output and refuses to overwrite its input', () {
    final input = p.join(folder.path, 'eboot.bin');
    final output = p.join(folder.path, 'out', 'eboot.elf');
    File(input).writeAsBytesSync(typicalSelf());
    final size = SelfUnwrap.unwrapFile(input, output);
    expect(File(output).lengthSync(), size);
    expect(() => SelfUnwrap.unwrapFile(input, input), throwsA(isA<SelfRefused>()));
    final link = p.join(folder.path, 'link');
    Link(link).createSync(input);
    expect(() => SelfUnwrap.unwrapFile(input, link), throwsA(isA<SelfRefused>()));
    expect(SelfUnwrap.isContainer(input), isTrue, reason: 'the input stays as it was');
  });

  test('entropy matches the Shannon formula', () {
    expect(SelfUnwrap.entropy([]), 0);
    expect(SelfUnwrap.entropy(List.filled(100, 7)), 0);
    expect(SelfUnwrap.entropy(List.generate(256, (index) => index)), closeTo(8, 1e-9));
    expect(SelfUnwrap.entropy([0, 1, 0, 1]), closeTo(1, 1e-9));
  });

  group('byte-identical to upstream tools/unwrap_self.py', () {
    final python = Process.runSync('python3', ['--version']).exitCode == 0;
    final skip = !python
        ? 'python3 is not installed'
        : !File(referenceScript).existsSync()
        ? 'unwrap_self.py not found (set ANYPS5_UNWRAP_SELF_PY)'
        : null;

    test('on the typical container and 300 random ones', () {
      final inputs = <String>[];
      final containers = <Uint8List>[typicalSelf(), for (var seed = 1; seed <= 300; seed++) randomSelf(seed)];
      for (var index = 0; index < containers.length; index++) {
        final path = p.join(folder.path, 'in$index.self');
        File(path).writeAsBytesSync(containers[index]);
        inputs.add(path);
      }
      // One Python process unwraps them all through the script's own unwrap().
      final driver = p.join(folder.path, 'driver.py');
      File(driver).writeAsStringSync('''
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("unwrap_self", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
results = []
for path in sys.argv[2:]:
    try:
        module.unwrap(path, path + ".py.elf")
        results.append("ok")
    except module.Refused as error:
        results.append("refused: " + str(error))
    except Exception as error:
        results.append("malformed")
print(json.dumps(results))
''');
      final run = Process.runSync('python3', ['-I', driver, referenceScript, ...inputs]);
      expect(run.exitCode, 0, reason: run.stderr.toString());
      final expected = (jsonDecode(run.stdout as String) as List<dynamic>).cast<String>();
      var unwrapped = 0;
      var refused = 0;
      for (var index = 0; index < inputs.length; index++) {
        String outcome;
        try {
          SelfUnwrap.unwrapFile(inputs[index], '${inputs[index]}.dart.elf');
          outcome = 'ok';
        } on SelfMalformed {
          outcome = 'malformed';
        } on SelfRefused catch (error) {
          outcome = 'refused: ${error.reason}';
        }
        expect(outcome, expected[index], reason: 'container $index');
        if (outcome == 'ok') {
          unwrapped++;
          final mine = File('${inputs[index]}.dart.elf').readAsBytesSync();
          final theirs = File('${inputs[index]}.py.elf').readAsBytesSync();
          expect(mine.length, theirs.length, reason: 'container $index size');
          expect(mine, theirs, reason: 'container $index bytes');
        } else {
          refused++;
        }
      }
      // The random set exercises both outcomes.
      expect(unwrapped, greaterThan(100));
      expect(refused, greaterThan(10));
    }, skip: skip);
  });
}
