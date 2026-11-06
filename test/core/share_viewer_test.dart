import 'dart:typed_data';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart';
import 'package:anyps5_desktop/core/together/share_audio.dart';
import 'package:anyps5_desktop/core/together/share_play.dart';
import 'package:anyps5_desktop/core/together/share_viewer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

class FakeWatchLink implements WatchLink {
  final remotes = <Map<String, dynamic>>[];
  final locals = <Map<String, dynamic>>[];
  final candidates = <Map<String, dynamic>>[];
  final texts = <(String, String)>[];
  final binaries = <(String, Uint8List)>[];
  bool remote = false;
  bool closed = false;
  bool open = true;
  bool refuseStereo = false;
  String state = 'new';
  void Function()? stateChanged;
  void Function(String)? opened;
  void Function(String, Uint8List)? binary;
  void Function(Map<String, dynamic>)? candidate;

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    remotes.add(description);
    remote = true;
  }

  @override
  Future<Map<String, dynamic>> createAnswer() async => {
    'type': 'answer',
    'sdp': 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10',
  };

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    if (refuseStereo && (description['sdp'] as String).contains('stereo')) throw StateError('no');
    locals.add(description);
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async => candidates.add(candidate);
  @override
  bool get hasRemote => remote;
  @override
  String get connectionState => closed ? 'closed' : state;
  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) => candidate = handler;
  @override
  set onState(void Function() handler) => stateChanged = handler;
  @override
  set onOpen(void Function(String) handler) => opened = handler;
  @override
  set onBinary(void Function(String, Uint8List) handler) => binary = handler;

  @override
  bool sendBinary(String label, Uint8List bytes, {int most = 65536}) {
    if (!open) return false;
    binaries.add((label, bytes));
    return true;
  }

  @override
  bool sendText(String label, String text) {
    if (!open) return false;
    texts.add((label, text));
    return true;
  }

  @override
  Future<WatchStats> stats() async => const WatchStats(roundTripMs: 31, framesPerSecond: 60, height: 720);
  @override
  Future<void> close() async => closed = true;
}

class FakeWatchEngine implements WatchEngine {
  final links = <FakeWatchLink>[];
  @override
  List<ShareAudioCodec> codecs = const [ShareAudioCodec.opus, ShareAudioCodec.pcm];
  @override
  Future<WatchLink> link(List<Map<String, dynamic>> iceServers) async {
    final link = FakeWatchLink();
    links.add(link);
    return link;
  }
}

ShareSignal fromHost(String kind, [Object? data, String device = 'host-dev']) =>
    ShareSignal(sharePlayId: 's1', from: 'h', device: device, kind: kind, data: data);

void main() {
  group('audio', () {
    test('the hello reads and writes as the Mac and the website send it', () {
      const hello = ShareAudioHello([ShareAudioCodec.opus, ShareAudioCodec.pcm]);
      expect(hello.text, '{"type":"audio-hello","v":1,"codecs":["opus","pcm"]}');
      expect(ShareAudioHello.parse('{"type":"audio-hello","v":1,"codecs":["flac","pcm"]}')!.codecs, [ShareAudioCodec.pcm]);
      expect(ShareAudioHello.parse('{"type":"audio-hello","v":1,"codecs":["pcm"]}')!.chosen, ShareAudioCodec.pcm);
      expect(ShareAudioHello.parse('nope'), isNull);
      expect(ShareAudioHello.parse('{"type":"other","codecs":[]}'), isNull);
    });

    test('stereo Opus is asked for on every Opus format, with the rate and 10 ms frames', () {
      const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 63\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;stereo=0\r\n'
          'a=rtpmap:63 opus/48000/2\r\na=ptime:20\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 H264/90000';
      final viewer = ShareAudioSdp.stereoOpus(sdp);
      expect(viewer, contains('a=fmtp:111 minptime=10;stereo=1;sprop-stereo=1\r\n'));
      expect(viewer, contains('a=rtpmap:63 opus/48000/2\r\na=fmtp:63 stereo=1;sprop-stereo=1'));
      expect(viewer, contains('a=ptime:20'));
      final host = ShareAudioSdp.stereoOpus(sdp, kbps: 128, frameMs: 10);
      expect(host, contains('maxaveragebitrate=128000;useinbandfec=1;usedtx=0'));
      expect(host, contains('a=ptime:10\r\nm=video'));
      expect(ShareAudioSdp.stereoOpus('v=0\r\nm=video 9 X 96'), 'v=0\r\nm=video 9 X 96');
    });

    test('an answer takes Opus only with an audio section that is not turned down', () {
      const opus = 'm=audio 9 X 111\r\na=rtpmap:111 opus/48000/2\r\na=recvonly';
      expect(ShareAudioSdp.takesOpus(opus), isTrue);
      expect(ShareAudioSdp.takesOpus('m=audio 0 X 111\r\na=rtpmap:111 opus/48000/2'), isFalse);
      expect(ShareAudioSdp.takesOpus('m=audio 9 X 111\r\na=rtpmap:111 opus/48000/2\r\na=inactive'), isFalse);
      expect(ShareAudioSdp.takesOpus('m=video 9 X 96\r\na=rtpmap:96 H264/90000'), isFalse);
    });
  });

  group('the pad packet', () {
    test('a controller as the engine\'s 80-byte input, as the Mac sends it', () {
      const state = PadState(
        pressed: {PadButton.south, PadButton.dpadUp, PadButton.start, PadButton.select},
        leftX: -1,
        leftY: 1,
        rightX: 0,
        rightY: -0.5,
        l2: 0.05,
        r2: 1,
      );
      final packet = SharePadPacket.packet(state, sequence: 7, sentMicros: 1234, session: 99);
      final data = ByteData.sublistView(packet);
      expect(packet, hasLength(RemotePacket.inputSize));
      expect(RemotePacket.inputSession(packet), 99);
      expect(data.getUint32(8, Endian.little), 7);
      expect(data.getUint64(16, Endian.little), 1234);
      expect(
        data.getUint32(32, Endian.little),
        SharePadPacket.cross | SharePadPacket.up | SharePadPacket.options | SharePadPacket.touchPad | SharePadPacket.r2,
      );
      expect(packet.sublist(36, 42), [0, 255, 128, 64, 13, 255]);
      expect(data.getFloat32(60, Endian.little), closeTo(9.80665, 0.0001));
    });

    test('the pump sends on a change and at least every 8 ms, and waits for the channel', () {
      var state = const PadState();
      var now = DateTime(2026, 11, 6, 12);
      var open = false;
      final sent = <Uint8List>[];
      final pump = SharePadPump(
        read: () => state,
        send: (packet) {
          if (!open) return false;
          sent.add(packet);
          return true;
        },
        session: 5,
        now: () => now,
      );
      pump.tick();
      expect(sent, isEmpty);
      open = true;
      pump.tick();
      pump.tick();
      expect(sent, hasLength(1), reason: 'nothing changed within 8 ms');
      now = now.add(const Duration(milliseconds: 9));
      pump.tick();
      expect(sent, hasLength(2), reason: 'kept alive');
      state = const PadState(pressed: {PadButton.east});
      pump.tick();
      expect(sent, hasLength(3));
      expect(ByteData.sublistView(sent.last).getUint32(32, Endian.little), SharePadPacket.circle);
      expect(ByteData.sublistView(sent.last).getUint32(8, Endian.little), 3);
    });
  });

  group('the viewer', () {
    late FakeWatchEngine engine;
    late List<(String, String, String, Object?)> signals;
    late List<Uint8List> sound;
    late ShareWatchSession session;

    ShareWatchSession make() => ShareWatchSession(
      id: 's1',
      hostId: 'h',
      hostDevice: 'host-dev',
      engine: engine,
      iceServers: const [],
      signal: (to, device, kind, data) => signals.add((to, device, kind, data)),
      onSound: sound.add,
      changed: () {},
    );

    setUp(() {
      engine = FakeWatchEngine();
      signals = [];
      sound = [];
      session = make();
    });

    test('asks for an offer, then again a moment later and every few seconds until connected', () {
      fakeAsync((async) {
        // Made in the fake zone, so its futures run on the fake clock.
        session = make()..start();
        expect(signals.single.$3, 'renegotiate');
        async.elapse(const Duration(milliseconds: 1600));
        expect(signals, hasLength(2));
        async.elapse(const Duration(seconds: 5));
        expect(signals, hasLength(3));
        session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o1'}));
        async.flushMicrotasks();
        engine.links.single
          ..state = 'connected'
          ..stateChanged!();
        final asked = signals.where((signal) => signal.$3 == 'renegotiate').length;
        async.elapse(const Duration(seconds: 20));
        expect(signals.where((signal) => signal.$3 == 'renegotiate').length, asked);
        expect(session.connected, isTrue);
      });
    });

    test('answers the offer with stereo Opus, after the candidates that came early', () async {
      await session.receive(fromHost('candidate', {'candidate': 'c0', 'sdpMid': '0', 'sdpMLineIndex': 0}));
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o1'}, 'host-dev-2'));
      final link = engine.links.single;
      expect(link.remotes.single, {'type': 'offer', 'sdp': 'o1'});
      expect(link.candidates.single['candidate'], 'c0');
      expect(link.locals.single['sdp'], contains('stereo=1;sprop-stereo=1'));
      final answer = signals.last;
      expect(answer.$3, 'answer');
      expect(answer.$2, 'host-dev-2', reason: 'the host\'s device follows its signals');
      expect((answer.$4! as Map)['sdp'], contains('stereo=1'));
      await session.receive(fromHost('candidate', {'candidate': 'c1'}));
      expect(link.candidates, hasLength(2));
      // A second offer on the same connection (the Opus track added) goes on the same link.
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o2'}));
      expect(engine.links, hasLength(1));
      expect(link.remotes, hasLength(2));
    });

    test('an answer WebRTC refuses with stereo goes as it was made', () async {
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o1'}));
      final link = engine.links.single..refuseStereo = true;
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o2'}));
      expect(link.locals.last['sdp'], isNot(contains('stereo')));
    });

    test('says hello on the sound channel once, plays PCM and hands pad answers on', () async {
      final padOut = <Uint8List>[];
      session = ShareWatchSession(
        id: 's1',
        hostId: 'h',
        hostDevice: 'host-dev',
        engine: engine,
        iceServers: const [],
        signal: (to, device, kind, data) => signals.add((to, device, kind, data)),
        onSound: sound.add,
        onPadOutput: padOut.add,
        changed: () {},
      );
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o1'}));
      final link = engine.links.single;
      link.opened!('pad');
      link.opened!('audio');
      link.opened!('audio');
      expect(link.texts, [('audio', '{"type":"audio-hello","v":1,"codecs":["opus","pcm"]}')]);
      link.binary!('audio', Uint8List(976));
      link.binary!('pad', Uint8List(32));
      expect(sound, hasLength(1));
      expect(padOut, hasLength(1));
      expect(session.sendPad(Uint8List(80)), isTrue);
      expect(link.binaries.single.$1, 'pad');
    });

    test('a launcher that plays no Opus track sends no hello and takes PCM', () async {
      engine.codecs = const [];
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o1'}));
      engine.links.single.opened!('audio');
      expect(engine.links.single.texts, isEmpty);
    });

    test('a broken link asks again; bye drops the connection; signals from others are not taken', () async {
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o1'}));
      final link = engine.links.single;
      signals.clear();
      link
        ..state = 'failed'
        ..stateChanged!();
      expect(signals.single.$3, 'renegotiate');
      expect(session.state, 'reconnecting');
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o2'}));
      expect(engine.links, hasLength(2), reason: 'a failed connection is made again');
      expect(link.closed, isTrue);
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'stranger', device: 'x', kind: 'bye'));
      expect(engine.links.last.closed, isFalse);
      await session.receive(fromHost('bye'));
      expect(engine.links.last.closed, isTrue);
      expect(session.state, 'waiting');
      await session.close();
      expect(signals.where((signal) => signal.$3 == 'bye'), isEmpty, reason: 'no connection left to say bye on');
    });

    test('leaving says bye to the host', () async {
      await session.receive(fromHost('offer', {'type': 'offer', 'sdp': 'o1'}));
      await session.close();
      expect(signals.last.$3, 'bye');
      expect(engine.links.single.closed, isTrue);
      expect(session.state, 'closed');
    });
  });
}
