import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/core/together/voice.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';
import 'together_voice_test.dart' show FakeEngine, until;

/// Calls with one friend, as the Mac's TogetherClient makes them: POST /calls with a user ID,
/// answer, decline; the party's voice is not touched by them.
void main() {
  late FakeTogether server;
  late TogetherAccount account;
  late TogetherSocket socket;
  late Parties parties;
  late FakeEngine engine;
  late Voice voice;
  const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');

  Map<String, dynamic> joined(String id, {bool muted = false}) => {
    'call': {
      'id': id,
      'kind': 'direct',
      'partyId': null,
      'in': [
        {'userId': 'u-ana', 'device': 'device-ana', 'muted': muted, 'deafened': muted},
      ],
    },
    'iceServers': const [],
    'expiresAt': null,
  };

  setUp(() async {
    server = await FakeTogether.start();
    server.person('u-ana', 'ana', 'Ana');
    account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
    await account.startEmail('utku@example.com');
    await account.verifyEmail('123456');
    socket = TogetherSocket(account: account);
    parties = Parties(account: account, socket: socket);
    engine = FakeEngine();
    voice = Voice(account: account, socket: socket, parties: parties, engine: () => engine);
    socket.start();
    await until(() => socket.status == SocketStatus.ready);
  });

  tearDown(() async {
    voice.dispose();
    parties.dispose();
    socket.dispose();
    account.close();
    await server.close();
  });

  test('calling a friend joins the call here and waits; their answer, their mute and the end are heard', () async {
    server.answers['POST calls'] = (201, joined('call-1'));
    Person? answered;
    (Person, String?)? ended;
    voice
      ..onAnswered = ((person) => answered = person)
      ..onCallEnded = ((person, reason) => ended = (person, reason));
    await voice.callFriend(ana);
    expect(server.callsTo('calls').single.body, {'userId': 'u-ana'});
    expect(voice.active, isTrue);
    expect(voice.friend?.id, 'u-ana');
    expect(voice.waiting, isTrue);
    // The newcomer offers to who is in already.
    final offer = await server.nextFrame('signal');
    expect(offer['to'], 'u-ana');

    server.push('call.answered', {'callId': 'call-1', 'userId': 'u-ana'});
    await until(() => !voice.waiting);
    expect(answered?.id, 'u-ana');
    server.push('call.updated', {'callId': 'call-1', 'userId': 'u-ana', 'muted': true, 'deafened': true});
    await until(() => voice.deafenedOthers.contains('u-ana'));
    expect(voice.mutedOthers, {'u-ana'});

    server.push('call.ended', {'callId': 'call-1', 'reason': 'declined'});
    await until(() => !voice.active);
    expect(ended?.$1.id, 'u-ana');
    expect(ended?.$2, 'declined');
    expect(voice.friend, isNull);
  });

  test('a ringing call answered here, or declined; a refused answer throws', () async {
    server.answers['POST calls/call-2/answer'] = (200, joined('call-2', muted: true));
    await voice.answer('call-2', ana);
    expect(voice.active, isTrue);
    expect(voice.waiting, isFalse);
    expect(voice.mutedOthers, {'u-ana'});
    await voice.leave();
    expect(server.callsTo('calls/call-2/leave'), hasLength(1));

    server.answers['POST calls/call-3/decline'] = (204, null);
    await voice.decline('call-3');
    expect(server.callsTo('calls/call-3/decline'), hasLength(1));

    server.answers['POST calls/call-4/answer'] = FakeTogether.problem(409, 'conflict');
    await expectLater(voice.answer('call-4', ana), throwsA(isA<TogetherProblem>()));
    expect(voice.active, isFalse);
    expect(engine.stopped, isTrue);
  });
}
