import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The launcher's half of the engine's online bridge protocol (AnyPS5's docs/dev/ONLINE_PLAY.md):
/// 12-byte little-endian frame headers, fields packed in order, an HMAC handshake over a
/// per-start secret. Byte for byte the same as the engine's
/// core/libs/prx/libSceNetCtl/src/OnlineWire.cpp and the Mac launcher's OnlineWire.swift; the
/// tests check the same reference bytes.
abstract final class OnlineWire {
  static const protocolVersion = 1;
  static const headerSize = 12;
  static const maxPayload = 16 * 1024 * 1024;
  static const maxDatagram = 65535;
  static const nonceSize = 16;
  static const proofSize = 32;
  static const secretSize = 32;
  static const virtualNetwork = 0xC6120000;
  static const virtualMask = 0xFFFE0000;

  /// The virtual network's broadcast address.
  static const virtualBroadcast = virtualNetwork | (~virtualMask & 0xFFFFFFFF);

  /// The largest game datagram online play carries: the largest UDP payload over IPv4 less the
  /// 12-byte header of the receiving engine's loopback hop (engine `MaxGameDatagram`). The engine
  /// refuses bigger ones with EMSGSIZE; a transport drops (and counts) any that still come.
  static const maxGameDatagram = 65507 - 12;

  static const flagReply = 0x0001;
  static const flagUnsupported = 0x0002;

  static bool isVirtual(int address) => address & virtualMask == virtualNetwork;

  /// A game datagram to the limited broadcast, the virtual network's broadcast or a multicast
  /// group goes to every other player in the session (LAN-style discovery).
  static bool isGroup(int address) =>
      address == 0xFFFFFFFF || address == virtualBroadcast || address & 0xF0000000 == 0xE0000000;

  static Uint8List frame(WireKind kind, Uint8List payload, {int flags = 0, int call = 0}) {
    final header = WireHeader(length: payload.length, kind: kind.value, flags: flags, call: call).bytes;
    return Uint8List(headerSize + payload.length)
      ..setAll(0, header)
      ..setAll(headerSize, payload);
  }

  static Uint8List welcome(Uint8List nonce, Uint8List proof) =>
      (WireWriter()
            ..u16(protocolVersion)
            ..raw(nonce)
            ..raw(proof))
          .data;

  static Uint8List refuse(RefuseReason reason, String text) =>
      (WireWriter()
            ..u16(reason.value)
            ..str(text))
          .data;

  /// HMAC-SHA-256(secret, "anyps5-online/1 launcher|engine" ‖ engine nonce ‖ launcher nonce).
  static Uint8List proof(List<int> secret, Side side, List<int> engineNonce, List<int> launcherNonce) {
    final label = side == Side.launcher ? 'anyps5-online/1 launcher' : 'anyps5-online/1 engine';
    final message = [...utf8.encode(label), ...engineNonce, ...launcherNonce];
    return Uint8List.fromList(Hmac(sha256, secret).convert(message).bytes);
  }

  /// Compares two proofs in constant time.
  static bool sameProof(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  static final Random _random = Random.secure();

  static Uint8List randomBytes(int count) => Uint8List.fromList(List.generate(count, (_) => _random.nextInt(256)));

  static String hex(List<int> data) => data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? fromHex(String text) {
    if (text.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(text)) return null;
    return Uint8List.fromList([
      for (var index = 0; index < text.length; index += 2) int.parse(text.substring(index, index + 2), radix: 16),
    ]);
  }

  /// A u64 as the platform writes account numbers in JSON: unsigned decimal (Dart's int is
  /// signed, so numbers above 2^63 come out negative otherwise).
  static String unsigned(int value) => BigInt.from(value).toUnsigned(64).toString();

  /// The u64 a decimal account number stands for (the bits of one above 2^63), or null.
  static int? parseUnsigned(String text) {
    if (!RegExp(r'^\d{1,20}$').hasMatch(text)) return null;
    final value = BigInt.parse(text);
    if (value >= BigInt.one << 64) return null;
    return value.toSigned(64).toInt();
  }
}

enum WireKind {
  hello(0x0001),
  welcome(0x0002),
  proof(0x0003),
  refuse(0x0004),
  account(0x0101),
  observation(0x0102),
  webRequest(0x0201),
  pushEvent(0x0204),
  datagram(0x0310);

  const WireKind(this.value);
  final int value;

  static WireKind? of(int value) => WireKind.values.where((kind) => kind.value == value).firstOrNull;
}

enum RefuseReason {
  badProof(1),
  protocolVersion(2),
  noGame(3),
  busy(4);

  const RefuseReason(this.value);
  final int value;
}

enum Side { launcher, engine }

enum DatagramKind {
  udp(1),
  p2p(2);

  const DatagramKind(this.value);
  final int value;

  static DatagramKind? of(int value) => DatagramKind.values.where((kind) => kind.value == value).firstOrNull;
}

class WireHeader {
  const WireHeader({required this.length, required this.kind, required this.flags, required this.call});

  final int length;
  final int kind;
  final int flags;
  final int call;

  bool get isReply => flags & OnlineWire.flagReply != 0;

  Uint8List get bytes =>
      (WireWriter()
            ..u32(length)
            ..u16(kind)
            ..u16(flags)
            ..u32(call))
          .data;

  /// The header at the start of [bytes]; null when there are fewer than 12 bytes or the length is
  /// over 16 MiB (which drops the connection).
  static WireHeader? parse(List<int> bytes) {
    if (bytes.length < OnlineWire.headerSize) return null;
    final reader = WireReader(bytes);
    final header = WireHeader(length: reader.u32(), kind: reader.u16(), flags: reader.u16(), call: reader.u32());
    return header.length > OnlineWire.maxPayload ? null : header;
  }

  @override
  bool operator ==(Object other) =>
      other is WireHeader && other.length == length && other.kind == kind && other.flags == flags && other.call == call;

  @override
  int get hashCode => Object.hash(length, kind, flags, call);

  @override
  String toString() => 'WireHeader($length, 0x${kind.toRadixString(16)}, $flags, $call)';
}

/// Packs fields in order: integers little-endian, str = u16 length + UTF-8, bytes = u32 length +
/// data, pairs = u16 count + (str, str).
class WireWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  Uint8List get data => _out.toBytes();

  void u8(int value) => _out.addByte(value & 0xFF);

  void u16(int value) => _out.add([value & 0xFF, (value >> 8) & 0xFF]);

  void u32(int value) => _out.add([for (var shift = 0; shift < 32; shift += 8) (value >> shift) & 0xFF]);

  void u64(int value) => _out.add([for (var shift = 0; shift < 64; shift += 8) (value >> shift) & 0xFF]);

  void i32(int value) => u32(value);

  void raw(List<int> bytes) => _out.add(bytes);

  void str(String text) {
    var bytes = utf8.encode(text);
    if (bytes.length > 0xFFFF) bytes = bytes.sublist(0, 0xFFFF);
    u16(bytes.length);
    _out.add(bytes);
  }

  void bytes(List<int> data) {
    u32(data.length);
    _out.add(data);
  }

  void pairs(List<WirePair> pairs) {
    final count = min(pairs.length, 0xFFFF);
    u16(count);
    for (final pair in pairs.take(count)) {
      str(pair.name);
      str(pair.value);
    }
  }
}

/// Reads fields in order; reading past the end turns [ok] false and gives zeros and empties.
class WireReader {
  WireReader(List<int> bytes) : _bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  final Uint8List _bytes;
  int _offset = 0;
  bool ok = true;

  int get remaining => ok ? _bytes.length - _offset : 0;

  Uint8List? _take(int count) {
    if (!ok || count < 0 || _bytes.length - _offset < count) {
      ok = false;
      return null;
    }
    final slice = Uint8List.sublistView(_bytes, _offset, _offset + count);
    _offset += count;
    return slice;
  }

  int _little(int size) {
    final slice = _take(size);
    if (slice == null) return 0;
    var value = 0;
    for (var index = 0; index < size; index++) {
      value |= slice[index] << (8 * index);
    }
    return value;
  }

  int u8() => _little(1);
  int u16() => _little(2);
  int u32() => _little(4);
  int u64() => _little(8);
  int i32() => u32().toSigned(32);

  Uint8List raw(int count) => Uint8List.fromList(_take(count) ?? const []);

  String str() {
    final slice = _take(u16());
    return slice == null ? '' : utf8.decode(slice, allowMalformed: true);
  }

  Uint8List bytes() => Uint8List.fromList(_take(u32()) ?? const []);

  List<WirePair> pairs() {
    final count = u16();
    final out = <WirePair>[];
    for (var index = 0; index < count && ok; index++) {
      final name = str();
      final value = str();
      if (ok) out.add(WirePair(name, value));
    }
    return out;
  }
}

class WirePair {
  const WirePair(this.name, this.value);

  final String name;
  final String value;

  @override
  bool operator ==(Object other) => other is WirePair && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);

  @override
  String toString() => '$name: $value';
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _samePairs(List<WirePair> left, List<WirePair> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// engine → launcher: u16 protocol, 16 nonce, str build, u32 pid.
class WireHello {
  const WireHello({
    this.protocolVersion = OnlineWire.protocolVersion,
    required this.nonce,
    required this.build,
    required this.pid,
  });

  final int protocolVersion;
  final Uint8List nonce;
  final String build;
  final int pid;

  Uint8List get payload =>
      (WireWriter()
            ..u16(protocolVersion)
            ..raw(nonce)
            ..str(build)
            ..u32(pid))
          .data;

  static WireHello? parse(List<int> payload) {
    final reader = WireReader(payload);
    final hello = WireHello(
      protocolVersion: reader.u16(),
      nonce: reader.raw(16),
      build: reader.str(),
      pid: reader.u32(),
    );
    return reader.ok ? hello : null;
  }

  @override
  bool operator ==(Object other) =>
      other is WireHello &&
      other.protocolVersion == protocolVersion &&
      _sameBytes(other.nonce, nonce) &&
      other.build == build &&
      other.pid == pid;

  @override
  int get hashCode => Object.hash(protocolVersion, build, pid);
}

/// launcher → engine, event: who is signed in, the virtual address and NAT type.
class WireAccount {
  const WireAccount({
    required this.signedIn,
    this.accountId = 0,
    this.onlineId = '',
    this.country = '',
    this.language = '',
    this.age = 0,
    this.address = 0,
    this.nat = 0,
  });

  static const signedOut = WireAccount(signedIn: false);

  final bool signedIn;
  final int accountId;
  final String onlineId;
  final String country;
  final String language;
  final int age;
  final int address;
  final int nat;

  WireAccount copyWith({int? address}) => WireAccount(
    signedIn: signedIn,
    accountId: accountId,
    onlineId: onlineId,
    country: country,
    language: language,
    age: age,
    address: address ?? this.address,
    nat: nat,
  );

  Uint8List get payload =>
      (WireWriter()
            ..u8(signedIn ? 1 : 0)
            ..u64(accountId)
            ..str(onlineId)
            ..str(country)
            ..str(language)
            ..u8(age)
            ..u32(address)
            ..u8(nat))
          .data;

  static WireAccount? parse(List<int> payload) {
    final reader = WireReader(payload);
    final account = WireAccount(
      signedIn: reader.u8() != 0,
      accountId: reader.u64(),
      onlineId: reader.str(),
      country: reader.str(),
      language: reader.str(),
      age: reader.u8(),
      address: reader.u32(),
      nat: reader.u8(),
    );
    return reader.ok ? account : null;
  }

  @override
  bool operator ==(Object other) =>
      other is WireAccount &&
      other.signedIn == signedIn &&
      other.accountId == accountId &&
      other.onlineId == onlineId &&
      other.country == country &&
      other.language == language &&
      other.age == age &&
      other.address == address &&
      other.nat == nat;

  @override
  int get hashCode => Object.hash(signedIn, accountId, onlineId, country, language, age, address, nat);

  @override
  String toString() => 'WireAccount($signedIn, ${OnlineWire.unsigned(accountId)}, $onlineId, address $address)';
}

/// engine → launcher, call: a web API request as the game built it, the body opaque.
class WireWebRequest {
  WireWebRequest({
    required this.userId,
    required this.apiGroup,
    required this.path,
    required this.method,
    this.headers = const [],
    List<int>? body,
  }) : body = body == null ? Uint8List(0) : Uint8List.fromList(body);

  final int userId;
  final String apiGroup;
  final String path;
  final String method;
  final List<WirePair> headers;
  final Uint8List body;

  Uint8List get payload =>
      (WireWriter()
            ..i32(userId)
            ..str(apiGroup)
            ..str(path)
            ..str(method)
            ..pairs(headers)
            ..bytes(body))
          .data;

  static WireWebRequest? parse(List<int> payload) {
    final reader = WireReader(payload);
    final request = WireWebRequest(
      userId: reader.i32(),
      apiGroup: reader.str(),
      path: reader.str(),
      method: reader.str(),
      headers: reader.pairs(),
      body: reader.bytes(),
    );
    return reader.ok ? request : null;
  }

  @override
  bool operator ==(Object other) =>
      other is WireWebRequest &&
      other.userId == userId &&
      other.apiGroup == apiGroup &&
      other.path == path &&
      other.method == method &&
      _samePairs(other.headers, headers) &&
      _sameBytes(other.body, body);

  @override
  int get hashCode => Object.hash(userId, apiGroup, path, method);
}

/// The reply to a web request: u16 status (0 = not offered), pairs headers, bytes body.
class WireWebReply {
  WireWebReply({required this.status, this.headers = const [], List<int>? body})
    : body = body == null ? Uint8List(0) : Uint8List.fromList(body);

  /// "Not offered": the engine answers the game exactly as it does offline.
  static final notOffered = WireWebReply(status: 0);

  final int status;
  final List<WirePair> headers;
  final Uint8List body;

  /// The body as JSON, for tests and logs; null when it is not JSON.
  Object? get json {
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
  }

  Uint8List get payload =>
      (WireWriter()
            ..u16(status)
            ..pairs(headers)
            ..bytes(body))
          .data;

  static WireWebReply? parse(List<int> payload) {
    final reader = WireReader(payload);
    final reply = WireWebReply(status: reader.u16(), headers: reader.pairs(), body: reader.bytes());
    return reader.ok ? reply : null;
  }

  @override
  bool operator ==(Object other) =>
      other is WireWebReply &&
      other.status == status &&
      _samePairs(other.headers, headers) &&
      _sameBytes(other.body, body);

  @override
  int get hashCode => Object.hash(status, body.length);

  @override
  String toString() => 'WireWebReply($status, ${utf8.decode(body, allowMalformed: true)})';
}

/// A game packet. From the engine [peer] is where it goes; to the engine, where it came from.
class WireDatagram {
  WireDatagram({
    required this.peer,
    required this.peerPort,
    required this.peerVport,
    required this.localPort,
    required this.localVport,
    required this.kind,
    required List<int> data,
  }) : data = data is Uint8List ? data : Uint8List.fromList(data);

  final int peer;
  final int peerPort;
  final int peerVport;
  final int localPort;
  final int localVport;
  final DatagramKind kind;
  final Uint8List data;

  WireDatagram copyWith({int? peer, List<int>? data}) => WireDatagram(
    peer: peer ?? this.peer,
    peerPort: peerPort,
    peerVport: peerVport,
    localPort: localPort,
    localVport: localVport,
    kind: kind,
    data: data ?? this.data,
  );

  Uint8List get payload =>
      (WireWriter()
            ..u32(peer)
            ..u16(peerPort)
            ..u16(peerVport)
            ..u16(localPort)
            ..u16(localVport)
            ..u8(kind.value)
            ..bytes(data))
          .data;

  /// Null when it is malformed, for an address outside the virtual network (and not a group), or
  /// bigger than a datagram.
  static WireDatagram? parse(List<int> payload) {
    final reader = WireReader(payload);
    final peer = reader.u32();
    final peerPort = reader.u16();
    final peerVport = reader.u16();
    final localPort = reader.u16();
    final localVport = reader.u16();
    final kind = DatagramKind.of(reader.u8());
    final data = reader.bytes();
    if (!reader.ok || kind == null) return null;
    if (!OnlineWire.isVirtual(peer) && !OnlineWire.isGroup(peer)) return null;
    if (data.length > OnlineWire.maxDatagram) return null;
    return WireDatagram(
      peer: peer,
      peerPort: peerPort,
      peerVport: peerVport,
      localPort: localPort,
      localVport: localVport,
      kind: kind,
      data: data,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WireDatagram &&
      other.peer == peer &&
      other.peerPort == peerPort &&
      other.peerVport == peerVport &&
      other.localPort == localPort &&
      other.localVport == localVport &&
      other.kind == kind &&
      _sameBytes(other.data, data);

  @override
  int get hashCode => Object.hash(peer, peerPort, peerVport, localPort, localVport, kind, data.length);

  @override
  String toString() =>
      'WireDatagram(${peer.toRadixString(16)}:$peerPort/$peerVport ↔ $localPort/$localVport ${kind.name} ${data.length} B)';
}

/// Session and invitation news for the game (launcher → engine, event), what the platform's web
/// API push events carry. An empty push context goes to the game's plain push callbacks and to
/// every push context; otherwise only to that context's callbacks.
class WirePushEvent {
  WirePushEvent({
    required this.service,
    this.label = 0,
    this.pushContextId = '',
    required this.dataType,
    List<int>? data,
    this.extended = const [],
    this.to = 0,
    this.from = 0,
    this.fromOnlineId = '',
  }) : data = data == null ? Uint8List(0) : Uint8List.fromList(data);

  static const maxDataType = 64;
  static const maxExtendedKey = 32;
  static const maxPushContextId = 36;

  final String service;
  final int label;
  final String pushContextId;
  final String dataType;
  final Uint8List data;
  final List<WirePair> extended;
  final int to;
  final int from;
  final String fromOnlineId;

  WirePushEvent copyWith({String? dataType, List<WirePair>? extended, String? fromOnlineId, String? pushContextId}) =>
      WirePushEvent(
        service: service,
        label: label,
        pushContextId: pushContextId ?? this.pushContextId,
        dataType: dataType ?? this.dataType,
        data: data,
        extended: extended ?? this.extended,
        to: to,
        from: from,
        fromOnlineId: fromOnlineId ?? this.fromOnlineId,
      );

  /// What the engine accepts: the platform's structures hold a 64-letter data type and 32-letter
  /// extended data keys.
  bool get isValid =>
      dataType.isNotEmpty &&
      utf8.encode(dataType).length <= maxDataType &&
      utf8.encode(pushContextId).length <= maxPushContextId &&
      utf8.encode(fromOnlineId).length <= 16 &&
      extended.every((pair) => pair.name.isNotEmpty && utf8.encode(pair.name).length <= maxExtendedKey);

  Uint8List get payload =>
      (WireWriter()
            ..str(service)
            ..u32(label)
            ..str(pushContextId)
            ..str(dataType)
            ..bytes(data)
            ..pairs(extended)
            ..u64(to)
            ..u64(from)
            ..str(fromOnlineId))
          .data;

  static WirePushEvent? parse(List<int> payload) {
    final reader = WireReader(payload);
    final event = WirePushEvent(
      service: reader.str(),
      label: reader.u32(),
      pushContextId: reader.str(),
      dataType: reader.str(),
      data: reader.bytes(),
      extended: reader.pairs(),
      to: reader.u64(),
      from: reader.u64(),
      fromOnlineId: reader.str(),
    );
    return reader.ok && event.isValid ? event : null;
  }

  @override
  bool operator ==(Object other) =>
      other is WirePushEvent &&
      other.service == service &&
      other.label == label &&
      other.pushContextId == pushContextId &&
      other.dataType == dataType &&
      _sameBytes(other.data, data) &&
      _samePairs(other.extended, extended) &&
      other.to == to &&
      other.from == from &&
      other.fromOnlineId == fromOnlineId;

  @override
  int get hashCode => Object.hash(service, label, pushContextId, dataType, to, from, fromOnlineId);

  @override
  String toString() => 'WirePushEvent($service, $pushContextId, $dataType)';
}
