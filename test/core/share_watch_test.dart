import 'package:anyps5_desktop/core/together/media.dart';
import 'package:anyps5_desktop/core/together/share_play.dart';
import 'package:anyps5_desktop/core/together/share_watch.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:test/test.dart';

import '../support/fake_sfu.dart';
import '../support/fake_together.dart';

Map<String, dynamic> share({String media = 'sfu', int? mySlot, bool watching = true, String id = 's-1'}) => {
  'id': id,
  'host': FakeTogether.card('u-host', 'host', 'Host'),
  'hostDevice': 'd-host',
  'titleId': 'PPSA01001',
  'open': true,
  'maxViewers': 12,
  'media': media,
  'viewers': [
    if (watching) {'user': FakeTogether.card('u-me', 'utku', 'Utku'), 'device': 'd-me', 'slot': mySlot},
    {'user': FakeTogether.card('u-ana', 'ana', 'Ana'), 'device': 'd-ana', 'slot': null},
  ],
};

SfuAccess room(String token, {DateTime? expires}) => SfuAccess(
  url: 'wss://media.example.org',
  token: token,
  room: 'share-s-1',
  identity: 'u-me',
  expiresAt: expires ?? DateTime.now().add(const Duration(minutes: 10)),
);

SharePlayStart joined(Map<String, dynamic> sharePlay, {SfuAccess? sfu}) =>
    SharePlayStart(SharePlay.fromJson(sharePlay), const [], null, sfu: sfu);

TogetherEvent updated(Map<String, dynamic> sharePlay) => TogetherEvent('e', 'share_play.updated', sharePlay);

void main() {
  late List<FakeSfuRoom> rooms;
  late List<String> fetched;
  late List<bool> mesh;
  late bool failNext;
  late ShareWatch watch;

  setUp(() {
    rooms = [];
    fetched = [];
    mesh = [];
    failNext = false;
    watch = ShareWatch(
      me: 'u-me',
      room: () {
        final made = FakeSfuRoom(fail: failNext);
        rooms.add(made);
        return made;
      },
      access: (id) async {
        fetched.add(id);
        return room('fresh-${fetched.length}');
      },
      onMesh: mesh.add,
    );
  });

  test('which way a viewer watches: the media server only in an "sfu" share play without a pad', () {
    expect(ShareWatch.pathFor(SharePlay.fromJson(share()), 'u-me'), ShareWatchPath.sfu);
    expect(ShareWatch.pathFor(SharePlay.fromJson(share(mySlot: 2)), 'u-me'), ShareWatchPath.mesh);
    expect(ShareWatch.pathFor(SharePlay.fromJson(share(media: 'mesh')), 'u-me'), ShareWatchPath.mesh);
    expect(ShareWatch.pathFor(SharePlay.fromJson(share()..remove('media')), 'u-me'), ShareWatchPath.mesh);
    expect(ShareWatch.pathFor(SharePlay.fromJson(share(watching: false)), 'u-me'), ShareWatchPath.none);
  });

  test('a mesh share play never touches the media server', () async {
    await watch.start(joined(share(media: 'mesh')));
    expect(watch.path, ShareWatchPath.mesh);
    expect(rooms, isEmpty);
    expect(mesh, [true]);
    await watch.handle(updated(share(media: 'mesh')));
    expect(mesh, [true], reason: 'told once');
    expect(fetched, isEmpty);
  });

  test("without a pad: the join answer's room, the host's picture, no mesh at all", () async {
    await watch.start(joined(share(), sfu: room('from-join')));
    expect(watch.path, ShareWatchPath.sfu);
    expect(rooms.single.access?.token, 'from-join');
    expect(fetched, isEmpty);
    expect(mesh, isEmpty, reason: 'no mesh signals while watching from the server');
    expect(watch.hasPicture, isFalse);
    rooms.single.tracks['u-ana'] = {'game'};
    expect(watch.hasPicture, isFalse, reason: "only the host's game track is the picture");
    rooms.single.tracks['u-host'] = {sfuTrackNames.video, sfuTrackNames.audio};
    expect(watch.hasPicture, isTrue);
  });

  test('a pad handed over moves to the mesh; taken back, to a fresh room', () async {
    await watch.start(joined(share(), sfu: room('from-join')));
    await watch.handle(updated(share(mySlot: 3)));
    expect(watch.path, ShareWatchPath.mesh);
    expect(rooms.single.left, isTrue);
    expect(mesh, [true]);
    await watch.handle(updated(share()));
    expect(watch.path, ShareWatchPath.sfu);
    expect(mesh, [true, false]);
    expect(fetched, ['s-1'], reason: 'the join token was used');
    expect(rooms.last.access?.token, 'fresh-1');
    expect(rooms.last.left, isFalse);
  });

  test('a share play that turns "sfu" mid-way leaves the mesh for the room', () async {
    await watch.start(joined(share(media: 'mesh')));
    await watch.handle(updated(share()));
    expect(mesh, [true, false]);
    expect(rooms.single.access?.token, 'fresh-1');
  });

  test('a join token past its time is not used: a fresh one is asked for', () async {
    await watch.start(joined(share(), sfu: room('old', expires: DateTime.now().subtract(const Duration(seconds: 1)))));
    expect(rooms.single.access?.token, 'fresh-1');
  });

  test('a media server that cannot be reached is tried again on the next update', () async {
    failNext = true;
    await watch.start(joined(share(), sfu: room('from-join')));
    expect(watch.path, ShareWatchPath.sfu);
    expect(watch.problem, isTrue);
    expect(watch.server, isNull);
    failNext = false;
    await watch.handle(updated(share()));
    expect(watch.problem, isFalse);
    expect(watch.server, same(rooms.last));
    expect(rooms.last.connected, isTrue);
  });

  test('taken out, or the share play ended: out of the room; other share plays are not ours', () async {
    await watch.start(joined(share(), sfu: room('from-join')));
    await watch.handle(updated(share(id: 's-2', mySlot: 2)));
    expect(watch.path, ShareWatchPath.sfu);
    await watch.handle(updated(share(watching: false)));
    expect(watch.path, ShareWatchPath.none);
    expect(rooms.single.left, isTrue);

    await watch.start(joined(share(), sfu: room('again')));
    await watch.handle(const TogetherEvent('e', 'share_play.ended', {'sharePlayId': 's-1'}));
    expect(watch.path, ShareWatchPath.none);
    expect(watch.sharePlay, isNull);
    expect(rooms.last.left, isTrue);
  });

  test('stopping leaves the room and the mesh', () async {
    await watch.start(joined(share(mySlot: 2)));
    await watch.stop();
    expect(mesh, [true, false]);
    await watch.start(joined(share(), sfu: room('from-join')));
    await watch.stop();
    expect(rooms.single.left, isTrue);
    expect(watch.path, ShareWatchPath.none);
  });
}
