import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide GameState;
import 'package:anyps5_desktop/ui/share_speaker.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../core/share_play_test.dart' show FakeEngine;
import '../core/share_viewer_test.dart' show FakeWatchEngine;
import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// A desktop that knows the game's window and its title.
class TitledDesktop extends FakeDesktop implements GameAreas {
  @override
  ScreenArea? gameArea(int pid) => const ScreenArea(0, 0, 1280, 720);
  @override
  String? gameTitle(int pid) => 'Orbit Runner';
}

class FakeSpeaker implements ShareSoundOut {
  final packets = <Uint8List>[];
  bool stopped = false;
  @override
  void push(Uint8List packet) => packets.add(packet);
  @override
  void stop() => stopped = true;
}

/// Hosting share play from the quick menu: start, a friend comes in, Let Them Play, stop. And
/// watching a friend's: from their invite in the Friends panel, full screen, the controller once
/// they hand it over, PS to leave.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakeEngine engine;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Map<String, Object?> sharePlay(List<Map<String, Object?>> viewers) => {
    'id': 'sp-1',
    'hostDevice': 'me-device',
    'titleId': 'PPSA01001',
    'title': 'Orbit Runner',
    'open': true,
    'maxViewers': 2,
    'viewers': viewers,
  };

  final ana = {
    'user': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
    'device': 'ana-browser',
  };

  setUp(() async {
    server = await FakeTogether.start();
    server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    fixture = makeFixture(together: server.base, desktop: TitledDesktop());
    model = fixture.model;
    engine = FakeEngine();
    model.sharePlay.engineOverride = () => engine;
    model.sharePlay.soundOverride = (_) => SilentGameSound();
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.friends.loaded);
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');

  Future<({Future<void> done})> play() async {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
    Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    File(p.join(installed, Installer.recordName)).writeAsStringSync(
      '{"date":"2026-10-24T12:00:00Z","source":${jsonEncode(orbit().folder)},"system":"linux",'
      '"titleID":"PPSA01001","toolkit":"arm-5ca076a87"}',
    );
    model.rescan();
    final playing = model.play(orbit());
    await until(() => model.running != null);
    return (done: playing);
  }

  List<String> quickRows() {
    model.open(Layer.quickMenu);
    return model.panelCategories().single.rows.map((row) => row.id).toList();
  }

  void choose(String id) {
    final row = model.panelCategories().expand((category) => category.rows).firstWhere((row) => row.id == id);
    switch (row.kind) {
      case ActionRow(:final run):
        run();
      default:
        fail('$id is no action');
    }
  }

  test('share the game, a friend comes in, plays as player 2, then it stops', () async {
    final playing = (await play()).done;
    expect(quickRows(), contains('share-start'));
    server.answers['POST share-plays'] = (201, {'sharePlay': sharePlay([]), 'iceServers': <Object>[], 'expiresAt': null});
    choose('share-start');
    await until(() => model.sharePlay.active);
    expect(model.toast, T.format('sharePlayStarted', ['Orbit Runner']));
    expect(server.calls.where((call) => call.path == 'share-plays').single.body['titleId'], 'PPSA01001');
    expect(quickRows(), containsAllInOrder(['share-on', 'share-open', 'share-max', 'share-invite-u-ana', 'share-stop']));

    // Ana comes in: she is offered a connection through the gateway.
    server.push('share_play.updated', sharePlay([ana]));
    await until(() => engine.links.isNotEmpty);
    await until(() => server.frames.any((frame) => frame['op'] == 'signal' && frame['kind'] == 'offer'));
    final offer = server.frames.firstWhere((frame) => frame['op'] == 'signal');
    expect(offer['to'], 'u-ana');
    expect(offer['device'], 'ana-browser');
    expect(offer['share'], 'sp-1');
    expect(quickRows(), containsAllInOrder(['share-on', 'share-play-u-ana', 'share-remove-u-ana']));

    server.answers['PUT share-plays/sp-1/viewers/u-ana/slot'] = (200, sharePlay([{...ana, 'slot': 2}]));
    choose('share-play-u-ana');
    await until(() => quickRows().contains('share-stop-u-ana'));
    expect(model.toast, T.format('sharePlayNowPlays', ['Ana', 2]));

    server.answers['DELETE share-plays/sp-1'] = (204, null);
    choose('share-stop');
    await until(() => engine.stopped);
    expect(model.sharePlay.active, isFalse);
    expect(engine.links.single.closed, isTrue);
    expect(server.frames.where((frame) => frame['op'] == 'signal').last['kind'], 'bye');
    expect(quickRows(), contains('share-start'));
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  group('watching', () {
    late FakeWatchEngine watcher;
    late FakeSpeaker speaker;
    var pad = const PadState();

    Map<String, Object?> anas(List<Map<String, Object?>> viewers) => {
      'id': 'sp-9',
      'host': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
      'hostDevice': 'ana-mac',
      'titleId': 'PPSA02002',
      'title': 'Neon Alley',
      'open': false,
      'maxViewers': 2,
      'viewers': viewers,
    };
    final me = {
      'user': {'userId': 'u-me', 'handle': 'utku', 'displayName': 'Utku'},
      'device': 'my-device',
    };

    setUp(() {
      watcher = FakeWatchEngine();
      speaker = FakeSpeaker();
      model.sharePlay.watchEngineOverride = () => watcher;
      model.sharePlay.speakerOverride = () => speaker;
      model.sharePlay.padOverride = () => pad;
    });

    List<String> friendRows() {
      model.open(Layer.friends);
      return model.panelCategories().expand((category) => category.rows).map((row) => row.id).toList();
    }

    Future<void> watchFromInvite() async {
      server.push('share_play.invite', {
        'sharePlayId': 'sp-9',
        'from': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
        'titleId': 'PPSA02002',
        'title': 'Neon Alley',
      });
      await until(() => model.sharePlay.invites.isNotEmpty);
      expect(model.toast, T.format('sharePlayInvitedYou', ['Ana', 'Neon Alley']));
      expect(friendRows(), containsAllInOrder(['share-watch-sp-9', 'share-decline-sp-9']));
      server.answers['POST share-plays/sp-9/join'] = (201, {'sharePlay': anas([me]), 'iceServers': <Object>[], 'expiresAt': null});
      choose('share-watch-sp-9');
      await until(() => model.overlay == Layer.shareWatch);
      await until(() => server.frames.any((frame) => frame['op'] == 'signal' && frame['kind'] == 'renegotiate'));
    }

    test('an invite in the Friends panel, the host\'s offer answered, the pad once handed over, PS leaves', () async {
      await watchFromInvite();
      final ask = server.frames.firstWhere((frame) => frame['op'] == 'signal');
      expect(ask['to'], 'u-ana');
      expect(ask['device'], 'ana-mac');
      expect(ask['share'], 'sp-9');
      expect(model.sharePlay.invites, isEmpty);

      server.push('share_play.signal', {
        'sharePlayId': 'sp-9',
        'from': 'u-ana',
        'device': 'ana-mac',
        'kind': 'offer',
        'data': {'type': 'offer', 'sdp': 'o1'},
      });
      await until(() => server.frames.any((frame) => frame['kind'] == 'answer'));
      final link = watcher.links.single;
      link.opened!('audio');
      expect(link.texts.single.$2, contains('audio-hello'));
      link.binary!('audio', Uint8List(976));
      expect(speaker.packets, hasLength(1));

      // While only watching, ○ leaves too; with the pad, only PS does.
      server.push('share_play.updated', anas([{...me, 'slot': 2}]));
      await until(() => model.sharePlay.watchSlot == 2);
      expect(model.toast, T.format('sharePlayYouPlay', [2]));
      pad = const PadState(pressed: {PadButton.south});
      await until(() => link.binaries.any((sent) => sent.$1 == 'pad'));
      model.handle(Command.back);
      expect(model.overlay, Layer.shareWatch);

      server.answers['POST share-plays/sp-9/leave'] = (204, null);
      model.handle(Command.home);
      await until(() => model.overlay != Layer.shareWatch);
      expect(model.sharePlay.isWatching, isFalse);
      expect(link.closed, isTrue);
      expect(speaker.stopped, isTrue);
      await until(() => server.callsTo('share-plays/sp-9/leave').isNotEmpty);
      expect(server.frames.where((frame) => frame['op'] == 'signal').last['kind'], 'bye');
    });

    test('the host stopping ends the watch with a word; a full share play says so', () async {
      await watchFromInvite();
      server.push('share_play.ended', {'sharePlayId': 'sp-9', 'reason': 'ended'});
      await until(() => !model.sharePlay.isWatching);
      expect(model.toast, T.format('sharePlayHostStopped', ['Ana']));
      expect(model.overlay, isNot(Layer.shareWatch));

      server.answers['POST share-plays/sp-9/join'] = (409, {'status': 409, 'code': 'full', 'title': 'Full'});
      await model.sharePlay.watch('sp-9');
      expect(model.toast, T.text('sharePlayFull'));
      expect(model.sharePlay.isWatching, isFalse);
    });

    test('a friend sharing who lets friends in is in the Friends panel', () async {
      server.push('presence.updated', {
        'userId': 'u-ana',
        'state': 'in_game',
        'titleId': 'PPSA02002',
        'share': {'sharePlayId': 'sp-9', 'titleId': 'PPSA02002', 'title': 'Neon Alley', 'open': true, 'viewers': 1, 'maxViewers': 3},
      });
      await until(() => model.together.hub.friends.friends.any((friend) => friend.presence.share != null));
      expect(friendRows(), contains('share-friend-sp-9'));
    });
  });

  test('signed out, the quick menu offers no share play', () async {
    final playing = (await play()).done;
    await model.together.signOut();
    await until(() => !model.together.signedIn);
    expect(quickRows(), isNot(contains('share-start')));
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);
}
