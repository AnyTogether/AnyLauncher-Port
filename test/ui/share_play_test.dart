import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../core/share_play_test.dart' show FakeEngine;
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

/// Hosting share play from the quick menu: start, a friend comes in, Let Them Play, stop.
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
    final row = model.panelCategories().single.rows.firstWhere((row) => row.id == id);
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
    await until(() => !model.sharePlay.active);
    expect(engine.stopped, isTrue);
    expect(engine.links.single.closed, isTrue);
    expect(quickRows(), contains('share-start'));
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('signed out, the quick menu offers no share play', () async {
    final playing = (await play()).done;
    await model.together.signOut();
    await until(() => !model.together.signedIn);
    expect(quickRows(), isNot(contains('share-start')));
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);
}
