import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/media.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/core/together/voice.dart';
import 'package:test/test.dart';

import '../support/fake_sfu.dart';
import '../support/fake_together.dart';
import 'together_voice_test.dart' show FakeEngine, offerSdp, until;

/// Party voice through the media server: a call with more voices than the mesh holds.
void main() {
  late FakeTogether server;
  late TogetherAccount account;
  late TogetherSocket socket;
  late Parties parties;
  late FakeEngine engine;
  late List<FakeSfuRoom> rooms;
  late Voice voice;

  Map<String, dynamic> room(String callId, String token) => {
    'url': 'wss://media.example.org',
    'token': token,
    'room': 'call-$callId',
    'identity': 'u-me',
    'expiresAt': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
  };

  /// POST /calls answers with a call on [media], and its room when [withRoom].
  void callAnswer(String media, {bool withRoom = true}) {
    final partyId = server.party!['id'];
    server.party!['call'] = {'id': 'c-9', 'in': ['u-ana', 'u-me'], 'muted': <String>[], 'media': media};
    server.answers['POST calls'] = (
      201,
      {
        'call': {
          'id': 'c-9',
          'kind': 'party',
          'partyId': partyId,
          'media': media,
          'in': [
            {'userId': 'u-ana', 'device': 'device-ana', 'muted': false, 'deafened': false},
          ],
        },
        'iceServers': const [],
        'expiresAt': null,
        'sfu': media == 'sfu' && withRoom ? room('c-9', 'from-join') : null,
      },
    );
  }

  setUp(() async {
    server = await FakeTogether.start();
    server.inParty([server.person('u-ana', 'ana', 'Ana')]);
    server.answers['GET calls/c-9/sfu'] = (200, room('c-9', 'fresh'));
    server.answers['POST calls/c-9/mute'] = (200, {'muted': true});
    server.answers['POST calls/c-9/leave'] = (200, {'left': true});
    account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
    await account.startEmail('utku@example.com');
    await account.verifyEmail('123456');
    socket = TogetherSocket(account: account);
    parties = Parties(account: account, socket: socket);
    engine = FakeEngine();
    rooms = [];
    voice = Voice(
      account: account,
      socket: socket,
      parties: parties,
      engine: () => engine,
      sfuRoom: () {
        final made = FakeSfuRoom();
        rooms.add(made);
        return made;
      },
      measureEvery: const Duration(milliseconds: 20),
    );
    socket.start();
    await until(() => parties.party != null && socket.status == SocketStatus.ready);
  });

  tearDown(() async {
    voice.dispose();
    parties.dispose();
    socket.dispose();
    account.close();
    await server.close();
  });

  test('a call on the media server: its room, the microphone published, no mesh at all', () async {
    callAnswer('sfu');
    await voice.join();
    expect(voice.active, isTrue);
    expect(voice.viaServer, isTrue);
    expect(engine.links, isEmpty, reason: 'nobody is called on the mesh');
    expect(rooms.single.access?.token, 'from-join');
    expect(rooms.single.calls, ['connect call-c-9', 'publish mic on']);
    expect(server.callsTo('calls/c-9/sfu'), isEmpty);
    expect(server.frames.where((frame) => frame['op'] == 'signal'), isEmpty);
  });

  test('muted stays muted in the room, and the others are still told through the server', () async {
    voice.setMuted(true);
    callAnswer('sfu');
    await voice.join();
    expect(rooms.single.microphone, isFalse);
    voice.setMuted(false);
    expect(rooms.single.microphone, isTrue);
    voice.setMuted(true);
    expect(rooms.single.microphone, isFalse);
    await until(() => server.callsTo('calls/c-9/mute').length >= 3);
    final told = [for (final call in server.callsTo('calls/c-9/mute')) call.body['muted']];
    expect(told, containsAll([true, false]));
  });

  test('deafened in the media server\'s room: nobody is heard there, the microphone is off, the others are told', () async {
    callAnswer('sfu');
    await voice.join();
    voice.setDeafened(true);
    expect(rooms.single.hearing, isFalse);
    expect(rooms.single.microphone, isFalse);
    voice.setDeafened(false);
    expect(rooms.single.hearing, isTrue);
    expect(rooms.single.microphone, isTrue);
    await until(() => server.callsTo('calls/c-9/mute').length >= 2);
    final told = [for (final call in server.callsTo('calls/c-9/mute')) (call.body['muted'], call.body['deafened'])];
    expect(told, contains((true, true)));
  });

  test('an "sfu" answer without a room asks for one', () async {
    callAnswer('sfu', withRoom: false);
    await voice.join();
    expect(server.callsTo('calls/c-9/sfu'), hasLength(1));
    expect(rooms.single.access?.token, 'fresh');
  });

  test('call.media moves a mesh call to the room: the mesh closes and stops answering', () async {
    callAnswer('mesh');
    await voice.join();
    expect(voice.viaServer, isFalse);
    await server.nextFrame('signal');
    expect(engine.links, hasLength(1));
    server.push('call.joined', {'callId': 'c-9', 'partyId': server.party!['id'], 'userId': 'u-me', 'device': 'd-me'});
    await until(() => parties.party!.callId == 'c-9');

    server.push('call.media', {'callId': 'c-9', 'partyId': server.party!['id'], 'media': 'sfu'});
    await until(() => rooms.isNotEmpty && rooms.single.microphone != null);
    expect(voice.viaServer, isTrue);
    expect(voice.active, isTrue);
    expect(engine.links.single.closed, isTrue);
    expect(engine.stopped, isTrue);
    expect(rooms.single.access?.token, 'fresh');
    expect(parties.party!.callMedia, MediaRoute.sfu);

    // A late offer from someone still on the mesh is not answered.
    server.push('signal', {
      'call': 'c-9',
      'from': 'u-bo',
      'device': 'device-bo',
      'kind': 'offer',
      'data': {'type': 'offer', 'sdp': offerSdp},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.links, hasLength(1));
  });

  test("the party's view saying the call is on the media server moves it too", () async {
    callAnswer('mesh');
    await voice.join();
    final view = {
      ...server.party!,
      'call': {'id': 'c-9', 'in': ['u-ana', 'u-me'], 'muted': <String>[], 'deafened': <String>[], 'media': 'sfu'},
    };
    server.push('party.updated', view);
    await until(() => rooms.isNotEmpty && rooms.single.microphone == true);
    expect(engine.links.single.closed, isTrue);
  });

  test('call.media for another call changes nothing', () async {
    callAnswer('mesh');
    await voice.join();
    server.push('call.media', {'callId': 'c-other', 'partyId': server.party!['id'], 'media': 'sfu'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rooms, isEmpty);
    expect(voice.viaServer, isFalse);
  });

  test("who speaks comes from the room's active speakers", () async {
    callAnswer('sfu');
    await voice.join();
    rooms.single
      ..participants = {'u-ana', 'u-bo'}
      ..speaking = {'u-ana', 'u-me'};
    rooms.single.changed!();
    expect(voice.speakingOf('u-ana'), isTrue);
    expect(voice.speakingOf('u-bo'), isFalse);
    expect(voice.speaking, isTrue);
    expect(voice.peers.map((peer) => peer.userId), unorderedEquals(['u-ana', 'u-bo']));
    voice.setMuted(true);
    expect(voice.speaking, isFalse, reason: 'muted is never speaking');
  });

  test('leaving leaves the room and tells the server; the call ending leaves it too', () async {
    callAnswer('sfu');
    await voice.join();
    await voice.leave();
    expect(rooms.single.left, isTrue);
    expect(server.callsTo('calls/c-9/leave'), hasLength(1));
    expect(voice.active, isFalse);

    await voice.join();
    server.push('call.ended', {'callId': 'c-9', 'partyId': server.party!['id'], 'reason': 'ended'});
    await until(() => !voice.active);
    expect(rooms.last.left, isTrue);
  });

  test('a media server that cannot be reached is a failed join', () async {
    callAnswer('sfu');
    voice.dispose();
    voice = Voice(
      account: account,
      socket: socket,
      parties: parties,
      engine: () => engine,
      sfuRoom: () => FakeSfuRoom(fail: true),
    );
    await voice.join();
    expect(voice.active, isFalse);
    expect(voice.problem, VoiceProblem.failed);
    expect(server.callsTo('calls/c-9/leave'), hasLength(1), reason: 'not left counted in the call');
  });
}
