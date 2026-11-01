import 'dart:typed_data';

import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/share_host.dart';
import 'package:anyps5_desktop/core/together/share_play.dart';
import 'package:test/test.dart';

class FakeBridges implements SharePadBridges {
  final free = <int>[3, 2];
  final sent = <(int, Uint8List)>[];
  final released = <int>[];
  @override
  int? reservePadBridge() => free.isEmpty ? null : free.removeAt(0);
  @override
  void releasePadBridge(int bridge) => released.add(bridge);
  @override
  void sendPad(Uint8List data, int bridge) => sent.add((bridge, data));
}

class FakeLink implements ShareLink {
  final offers = <bool>[];
  final remotes = <Map<String, dynamic>>[];
  final candidates = <Map<String, dynamic>>[];
  final padsOut = <Uint8List>[];
  final encodings = <int>[];
  String signaling = 'stable';
  bool remote = false;
  bool closed = false;
  Map<String, dynamic>? local;
  void Function(Uint8List)? pad;

  @override
  Future<Map<String, dynamic>> createOffer({bool restart = false}) async {
    offers.add(restart);
    return {'type': 'offer', 'sdp': 'offer-${offers.length}'};
  }

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    local = description;
    signaling = 'have-local-offer';
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    remotes.add(description);
    remote = true;
    signaling = 'stable';
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async => candidates.add(candidate);
  @override
  String get signalingState => signaling;
  @override
  String get connectionState => closed ? 'closed' : 'connecting';
  @override
  bool get hasRemote => remote;
  @override
  Map<String, dynamic>? get localDescription => local;
  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) {}
  @override
  set onState(void Function() handler) {}
  @override
  set onPad(void Function(Uint8List) handler) => pad = handler;
  @override
  void sendPad(Uint8List packet) => padsOut.add(packet);
  @override
  Future<void> setEncoding({required int maxBitrate, required int maxFramerate, required double scaleDown}) async =>
      encodings.add(maxBitrate);
  @override
  Future<void> close() async => closed = true;
}

class FakeEngine implements ShareEngine {
  final links = <FakeLink>[];
  bool stopped = false;
  @override
  bool get hasSound => true;
  @override
  Future<bool> start({required String windowTitle}) async => true;
  @override
  Future<ShareLink> link(List<Map<String, dynamic>> iceServers) async {
    final link = FakeLink();
    links.add(link);
    return link;
  }

  @override
  Future<void> stop() async => stopped = true;
}

Person person(String id) => Person(id: id, handle: id, displayName: id.toUpperCase());

ShareViewer viewer(String id, String device, {int? slot}) => ShareViewer(user: person(id), device: device, slot: slot);

SharePlay share(List<ShareViewer> viewers) =>
    SharePlay(id: 's1', hostDevice: 'host', titleId: 'PPSA01001', open: true, maxViewers: 4, viewers: viewers);

/// An 80-byte pad packet with a session, as a viewer's browser sends it.
Uint8List padPacket() {
  final packet = Uint8List(80);
  ByteData.sublistView(packet)
    ..setUint32(0, 0x49525041, Endian.little)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 80, Endian.little)
    ..setUint32(8, 5, Endian.little)
    ..setUint64(24, 99, Endian.little);
  packet[32] = 0xFF;
  return packet;
}

void main() {
  test('the server\'s share play reads as the Mac reads it', () {
    final start = SharePlayStart.fromJson({
      'sharePlay': {
        'id': 's1',
        'host': {'userId': 'h', 'handle': 'h', 'displayName': 'Host'},
        'hostDevice': 'dev',
        'titleId': 'PPSA01001',
        'title': 'Orbit',
        'open': true,
        'maxViewers': 3,
        'viewers': [
          {'user': {'userId': 'a', 'handle': 'a', 'displayName': 'A'}, 'device': 'd1', 'slot': 2},
        ],
      },
      'iceServers': [
        {'urls': ['stun:stun.example.org']},
      ],
      'expiresAt': '2026-11-01T12:00:00Z',
    });
    expect(start.sharePlay.viewers.single.slot, 2);
    expect(start.sharePlay.maxViewers, 3);
    expect(start.iceServers, hasLength(1));
    expect(start.expiresAt, DateTime.utc(2026, 11, 1, 12));
    expect(ShareSignal.frame(to: 'a', device: 'd1', share: 's1', kind: 'offer', data: {'sdp': 'x'}), {
      'op': 'signal', 'to': 'a', 'device': 'd1', 'share': 's1', 'kind': 'offer', 'data': {'sdp': 'x'},
    });
  });

  test('the roster calls newcomers, hangs up on leavers and on a device change', () {
    final plan = ShareRoster.plan([viewer('a', 'd1'), viewer('b', 'd2')], [viewer('a', 'd9'), viewer('c', 'd3')]);
    expect(plan.call.map((viewer) => viewer.user.id), ['a', 'c']);
    expect(plan.hangUp, ['a', 'b']);
    expect(ShareRoster.freePad([viewer('a', 'd', slot: 2), viewer('b', 'd', slot: 4)]), 3);
    expect(ShareRoster.freePad([for (final pad in [2, 3, 4]) viewer('$pad', 'd', slot: pad)]), isNull);
    expect(ShareRoster.encoding(3).maxFramerate, 30);
  });

  test('the answer gets WebRTC\'s bit rate hints on every H.264 format', () {
    const sdp = 'v=0\r\na=rtpmap:102 H264/90000\r\na=fmtp:102 profile-level-id=42e01f\r\na=rtpmap:104 H264/90000';
    final tuned = ShareRoster.tuneVideo(sdp, startKbps: 2500, maxKbps: 10000);
    expect(tuned, contains('a=fmtp:102 profile-level-id=42e01f;x-google-start-bitrate=2500;x-google-max-bitrate=10000'));
    expect(tuned, contains('a=rtpmap:104 H264/90000\r\na=fmtp:104 x-google-start-bitrate=2500'));
  });

  test('only a viewer with a pad reaches the game, seated as their player, let go when it is taken back', () {
    final bridges = FakeBridges();
    final router = SharePadRouter(bridges);
    expect(router.receive(padPacket(), 'a'), isFalse);
    router.update({'a': 3});
    expect(router.receive(padPacket(), 'a'), isTrue);
    final (bridge, sent) = bridges.sent.single;
    expect(bridge, 3);
    expect(sent[13], 3, reason: 'the pad the host gave');
    expect(router.receive(padPacket(), 'b'), isFalse);
    expect(router.receive(Uint8List(80), 'a'), isFalse, reason: 'not a pad packet');
    router.update({});
    final letGo = bridges.sent.last.$2;
    expect(letGo[32], 0);
    expect(letGo.sublist(36, 40), [128, 128, 128, 128]);
    expect(ByteData.sublistView(letGo).getUint32(8, Endian.little), 6);
    expect(bridges.released, [3]);
  });

  group('the host', () {
    late FakeEngine engine;
    late FakeBridges bridges;
    late List<(String, String, String, Object?)> signals;
    late ShareHostSession session;

    setUp(() {
      engine = FakeEngine();
      bridges = FakeBridges();
      signals = [];
      session = ShareHostSession(
        id: 's1',
        engine: engine,
        iceServers: const [],
        signal: (to, device, kind, data) => signals.add((to, device, kind, data)),
        router: SharePadRouter(bridges),
        changed: () {},
      );
    });

    test('offers each viewer, tunes their answer, queues early candidates', () async {
      await session.apply(share([viewer('a', 'd1')]));
      expect(signals.single.$3, 'offer');
      expect(signals.single.$2, 'd1');
      final link = engine.links.single;
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'candidate', data: {'candidate': 'c1'}));
      expect(link.candidates, isEmpty);
      await session.receive(const ShareSignal(
        sharePlayId: 's1', from: 'a', device: 'd1', kind: 'answer',
        data: {'type': 'answer', 'sdp': 'a=rtpmap:96 H264/90000'},
      ));
      expect(link.remotes.single['sdp'], contains('x-google-max-bitrate=10000'));
      expect(link.candidates, [{'candidate': 'c1'}]);
      expect(link.encodings, isNotEmpty);
    });

    test('a viewer waiting for the offer gets it again; a broken one gets a new connection', () async {
      await session.apply(share([viewer('a', 'd1')]));
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'renegotiate'));
      expect(signals.map((signal) => signal.$3), ['offer', 'offer']);
      expect(engine.links, hasLength(1));
      engine.links.single.signaling = 'stable';
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'renegotiate'));
      expect(engine.links, hasLength(2));
      expect(engine.links.first.closed, isTrue);
    });

    test('a pad handed over reaches the game, its answers go back, leavers are hung up on', () async {
      await session.apply(share([viewer('a', 'd1', slot: 2)]));
      engine.links.single.pad!(padPacket());
      expect(bridges.sent.single.$1, 3);
      session.padOutput(3, Uint8List(32));
      expect(engine.links.single.padsOut, hasLength(1));
      await session.apply(share(const []));
      expect(engine.links.single.closed, isTrue);
      expect(bridges.released, [3]);
      await session.close();
      expect(engine.stopped, isTrue);
    });

    test('signals of another share play are not taken', () async {
      await session.apply(share([viewer('a', 'd1')]));
      await session.receive(const ShareSignal(sharePlayId: 'other', from: 'a', device: 'd1', kind: 'bye'));
      expect(engine.links.single.closed, isFalse);
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'bye'));
      expect(engine.links.single.closed, isTrue);
    });
  });
}
