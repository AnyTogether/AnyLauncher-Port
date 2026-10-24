import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A phone the user allowed once; its key lets it connect again without asking.
class PairedDevice {
  const PairedDevice({required this.id, required this.name, required this.key, required this.added});

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    key: json['key'] as String,
    added: DateTime.parse(json['added'] as String),
  );

  final String id;
  final String name;
  final String key;
  final DateTime added;

  Map<String, Object> toJson() => {'added': added.toUtc().toIso8601String(), 'id': id, 'key': key, 'name': name};
}

/// The allowed phones, kept in a JSON file (the macOS launcher's RemoteDevices.json format).
class PairedDevices {
  PairedDevices(this.file) {
    try {
      final json = jsonDecode(File(file).readAsStringSync());
      if (json is List<dynamic>) {
        _devices.addAll(json.whereType<Map<String, dynamic>>().map(PairedDevice.fromJson));
      }
    } on Object {
      // No file yet, or one that cannot be read: no phones.
    }
  }

  final String file;
  final List<PairedDevice> _devices = [];
  static final _random = Random.secure();

  List<PairedDevice> get all => List.unmodifiable(_devices);

  PairedDevice? device(String id, String key) {
    for (final device in _devices) {
      if (device.id == id && _equal(device.key, key)) return device;
    }
    return null;
  }

  /// Allows the phone with a new random key, replacing an earlier pairing of the same phone.
  PairedDevice add(String id, String name) {
    final key = base64.encode(List.generate(32, (_) => _random.nextInt(256)));
    final device = PairedDevice(id: id, name: name, key: key, added: DateTime.now());
    _devices
      ..removeWhere((other) => other.id == id)
      ..add(device);
    _save();
    return device;
  }

  void remove(String id) {
    _devices.removeWhere((device) => device.id == id);
    _save();
  }

  void _save() {
    final target = File(file);
    target.parent.createSync(recursive: true);
    final temporary = File('$file.tmp');
    temporary.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert([for (final device in _devices) device.toJson()]),
      flush: true,
    );
    temporary.renameSync(file);
  }

  /// Compares keys in constant time.
  static bool _equal(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var index = 0; index < a.length; index++) {
      difference |= a.codeUnitAt(index) ^ b.codeUnitAt(index);
    }
    return difference == 0;
  }
}
