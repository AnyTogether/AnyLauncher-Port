import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/media.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/share_play.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

const access = {
  'url': 'wss://media.example.org',
  'token': 'jwt',
  'room': 'share-s-1',
  'identity': 'u-me',
  'expiresAt': '2026-11-06T12:10:00.000Z',
};

void main() {
  test('a media route: "sfu" through the media server, anything else (or nothing) the mesh', () {
    expect(MediaRoute.parse('sfu'), MediaRoute.sfu);
    expect(MediaRoute.parse('mesh'), MediaRoute.mesh);
    expect(MediaRoute.parse(null), MediaRoute.mesh, reason: 'an older server says nothing');
    expect(MediaRoute.parse('carrier-pigeon'), MediaRoute.mesh);
  });

  test('a media server room as the server hands it out', () {
    final room = SfuAccess.fromJson(access)!;
    expect(room.url, 'wss://media.example.org');
    expect(room.token, 'jwt');
    expect(room.room, 'share-s-1');
    expect(room.identity, 'u-me');
    expect(room.expiresAt, DateTime.utc(2026, 11, 6, 12, 10));
    expect(room.fresh(DateTime.utc(2026, 11, 6, 12, 9)), isTrue);
    expect(room.fresh(DateTime.utc(2026, 11, 6, 12, 10)), isFalse);
    expect(SfuAccess.fromJson(null), isNull, reason: 'the mesh: null');
    expect(SfuAccess.fromJson({'url': 'wss://x'}), isNull, reason: 'no token, no room');
  });

  test('the media limits: without a media server (or an answer) the mesh limits', () {
    final on = MediaLimits.fromJson({'sfu': true, 'maxShareViewers': 16, 'maxPartySize': 24});
    expect((on.sfu, on.maxShareViewers, on.maxPartySize), (true, 16, 24));
    final off = MediaLimits.fromJson({'sfu': false, 'maxShareViewers': 4, 'maxPartySize': 8});
    expect((off.sfu, off.maxShareViewers, off.maxPartySize), (false, 4, 8));
    final old = MediaLimits.fromJson(const {});
    expect((old.sfu, old.maxShareViewers, old.maxPartySize), (false, 4, 8));
  });

  test('share plays and their join answers carry the route and the room', () {
    final sharePlay = {
      'id': 's-1',
      'hostDevice': 'd-host',
      'titleId': 'PPSA01001',
      'open': true,
      'maxViewers': 12,
      'media': 'sfu',
      'viewers': const [],
    };
    expect(SharePlay.fromJson(sharePlay).media, MediaRoute.sfu);
    expect(SharePlay.fromJson({...sharePlay}..remove('media')).media, MediaRoute.mesh);
    final joined = SharePlayStart.fromJson({'sharePlay': sharePlay, 'iceServers': const [], 'expiresAt': null, 'sfu': access});
    expect(joined.sfu?.room, 'share-s-1');
    expect(SharePlayStart.fromJson({'sharePlay': sharePlay, 'iceServers': const []}).sfu, isNull);
  });

  test("a party's call route and its size: an older server says neither, so the mesh and eight", () {
    final party = Party.fromJson({
      'id': 'p-1',
      'members': const [],
      'max': 24,
      'call': {'id': 'c-1', 'in': const [], 'muted': const [], 'deafened': const [], 'media': 'sfu'},
    });
    expect(party.callMedia, MediaRoute.sfu);
    expect(party.max, 24);
    final old = Party.fromJson({
      'id': 'p-2',
      'members': const [],
      'call': {'id': 'c-2', 'in': const [], 'muted': const []},
    });
    expect(old.callMedia, MediaRoute.mesh);
    expect(old.max, maxPartySize);
    expect(Party.fromJson({'id': 'p-3', 'max': 0}).max, maxPartySize, reason: 'nonsense is the mesh limit');
  });

  test('a party is full at its own size, not always at eight', () {
    Map<String, dynamic> member(int n) => FakeTogether.card('u-$n', 'h$n', 'P$n');
    final nine = [for (var n = 0; n < 9; n++) member(n)];
    expect(Party.fromJson({'id': 'p', 'members': nine.take(8).toList()}).full, isTrue);
    expect(Party.fromJson({'id': 'p', 'members': nine, 'max': 24}).full, isFalse);
    expect(Party.fromJson({'id': 'p', 'members': nine, 'max': 9}).full, isTrue);
    expect(Party.fromJson({'id': 'p', 'members': nine.take(8).toList(), 'max': 24}).copyWith(open: true).max, 24);
  });

  group('the server', () {
    late FakeTogether server;
    late TogetherAccount account;

    setUp(() async {
      server = await FakeTogether.start();
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('what it holds, and the mesh limits when it cannot say', () async {
      final media = MediaServerClient(account);
      server.answers['GET media-server'] = (200, {'sfu': true, 'maxShareViewers': 16, 'maxPartySize': 24});
      expect((await media.limits()).maxShareViewers, 16);
      server.answers['GET media-server'] = FakeTogether.problem(404, 'not_found');
      final old = await media.limits();
      expect((old.sfu, old.maxShareViewers, old.maxPartySize), (false, 4, 8));
    });

    test('fresh rooms for a share play and a call; 409 on the mesh', () async {
      final media = MediaServerClient(account);
      server.answers['GET share-plays/s-1/sfu'] = (200, access);
      server.answers['GET calls/c-1/sfu'] = (200, {...access, 'room': 'call-c-1'});
      expect((await media.sharePlay('s-1')).room, 'share-s-1');
      expect((await media.call('c-1')).room, 'call-c-1');
      server.answers['GET calls/c-2/sfu'] = FakeTogether.problem(409, 'conflict', 'This call is peer to peer');
      await expectLater(media.call('c-2'), throwsA(isA<TogetherProblem>()));
    });

    test('joining a share play to watch gives the room on the media server', () async {
      server.answers['POST share-plays/s-1/join'] = (
        201,
        {
          'sharePlay': {'id': 's-1', 'hostDevice': 'd', 'titleId': 'T', 'open': true, 'maxViewers': 12, 'media': 'sfu', 'viewers': const []},
          'iceServers': const [],
          'expiresAt': null,
          'sfu': access,
        },
      );
      final joined = await SharePlayClient(account).join('s-1');
      expect(joined.sharePlay.media, MediaRoute.sfu);
      expect(joined.sfu?.token, 'jwt');
      server.answers['POST share-plays/s-1/leave'] = (200, {'left': true});
      await SharePlayClient(account).leave('s-1');
      expect(server.callsTo('share-plays/s-1/leave'), hasLength(1));
    });
  });
}
