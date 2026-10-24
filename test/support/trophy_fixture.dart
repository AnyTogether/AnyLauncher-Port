import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A trophy package: big-endian header, a table of 0x40-byte entries, then the files.
Uint8List ucp(Map<String, List<int>> files) {
  const toc = 0x40;
  final names = files.keys.toList();
  var cursor = toc + 0x20 + names.length * 0x40;
  final out = BytesBuilder();
  final header = Uint8List(toc + 0x20 + names.length * 0x40);
  void put(int at, int size, int value) {
    for (var index = 0; index < size; index++) {
      header[at + index] = value >> (8 * (size - 1 - index)) & 0xFF;
    }
  }

  put(0, 4, 0xB228C60A);
  put(4, 4, 1);
  put(0x10, 4, names.length);
  put(0x14, 4, toc);
  for (var index = 0; index < names.length; index++) {
    final entry = toc + 0x20 + index * 0x40;
    header.setRange(entry, entry + names[index].length, utf8.encode(names[index]));
    put(entry + 0x20, 8, cursor);
    put(entry + 0x28, 8, files[names[index]]!.length);
    cursor += files[names[index]]!.length;
  }
  out.add(header);
  for (final name in names) {
    out.add(files[name]!);
  }
  return out.toBytes();
}

List<int> json(Object value) => [0xEF, 0xBB, 0xBF, ...utf8.encode(jsonEncode(value))];

/// A small trophy set in a dump: a platinum, two golds, a progressive bronze and a hidden silver;
/// [earned] trophy numbers are recorded as unlocked in [installed].
void writeTrophies(String dump, {String? installed, List<int> earned = const [], List<int> Function()? icon}) {
  Directory(p.join(dump, 'sce_sys', 'trophy2')).createSync(recursive: true);
  File(p.join(dump, 'sce_sys', 'trophy2', 'trophy00.ucp')).writeAsBytesSync(
    ucp({
      'tropconf.json': json({
        'trophies': [
          {'id': '0000', 'grade': 'P'},
          {'id': '0001', 'grade': 'G'},
          {'id': '0002', 'grade': 'G'},
          {
            'id': '0003',
            'grade': 'B',
            'unlockCondition': {'progressive': true, 'udsStatId': '1', 'targetValue': 20},
          },
          {'id': '0004', 'grade': 'S', 'hidden': true},
        ],
      }),
      'tropmeta_en-US.json': json({
        'metadata': {
          'titleMetadata': {'name': 'Orbit Runner'},
          'trophyMetadata': [
            {'id': '0000', 'name': 'Every Orbit', 'detail': 'Earn every other trophy'},
            {'id': '0001', 'name': 'Liftoff', 'detail': 'Finish the first run'},
            {'id': '0002', 'name': 'Dark Side', 'detail': 'Reach the far side of the moon'},
            {'id': '0003', 'name': 'Collector', 'detail': 'Pick up twenty stars'},
            {'id': '0004', 'name': 'Ghost Signal', 'detail': 'Follow the signal'},
          ],
        },
      }),
    }),
  );
  if (installed == null) return;
  final records = Directory(p.join(installed, '_trophy'))..createSync(recursive: true);
  const tick = 62135596800000000 + 1792800000000000;
  File(p.join(records.path, '1_0.txt')).writeAsStringSync([for (final number in earned) '$number $tick'].join('\n'));
  File(p.join(records.path, '1_0.stats.txt')).writeAsStringSync('1 12\n');
}
