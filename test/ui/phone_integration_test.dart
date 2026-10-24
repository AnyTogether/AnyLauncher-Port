import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/remote/remote_protocol.dart' as server;
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// The launcher and a phone together: pairing through the launcher's card, the library the phone
/// gets, and the phone driving the launcher.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() async {
    fixture = makeFixture();
    model = fixture.model;
    await model.startPhoneServer();
  });

  tearDown(() async {
    await model.stopPhoneServer();
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Future<FakePhone> pairedPhone() async {
    final phone = await FakePhone.connect(model.remote!.port!);
    phone.hello('phone-1', 'Pixel');
    final code = (await phone.next<Pairing>()).code;
    await until(() => model.pairing != null);
    expect(model.pairing!.code, code);
    expect(model.phoneConnecting, 'Pixel');
    model.handle(launcher.Command.select);
    await phone.next<Welcome>();
    return phone;
  }

  test('a phone pairs through the launcher and gets the library, the look and the art', () async {
    final phone = await pairedPhone();
    final library = await phone.next<Library>();
    expect(library.games.map((game) => game.name), ['Neon Alley', 'Orbit Runner', 'Quiet Forest', 'Sealed Archive']);
    final orbit = library.games[1];
    expect(orbit.state, GameState.installed);
    expect(orbit.trophies, '2/5');
    expect(library.games[0].state, GameState.locked);
    expect(library.games[3].state, GameState.unavailable);
    expect(library.selected, model.selectedGame!.id);
    expect(library.language, 'en');
    final look = await phone.next<LookUpdate>();
    expect(look.deep, startsWith('#'));
    phone.send(WantArt(orbit.id));
    final art = await phone.next<Art>();
    expect(base64.decode(art.icon!).sublist(1, 4), 'PNG'.codeUnits);
    expect(model.remote!.connectedDevices, ['Pixel']);
    await phone.close();
  });

  test('the phone moves the launcher, selects a game and keeps its pad layout per game', () async {
    final phone = await pairedPhone();
    await phone.next<Library>();
    phone.send(const Command('right'));
    await until(() => model.selected == 1);
    final selected = await phone.nextWhere<Library>((library) => library.selected == model.games[1].id);
    expect(selected.selected, model.games[1].id);
    phone.send(SelectGame(model.games[2].id));
    await until(() => model.selected == 2);
    phone.send(const Command('options'));
    await until(() => model.overlay == Layer.gameSettings);
    phone.send(const Command('back'));
    await until(() => model.overlay == null);
    phone.send(SaveLayout(model.games[2].id, '{"scale":1.2}'));
    await until(() => model.currentSettings(model.games[2]).phoneLayout == '{"scale":1.2}');
    final updated = await phone.nextWhere<Library>((library) => library.games[2].layout != null);
    expect(updated.games[2].layout, '{"scale":1.2}');
    await phone.close();
  });

  test('a launch on a locked game without a toolkit says so on the launcher', () async {
    model.preferences.toolkitFolder = null;
    final phone = await pairedPhone();
    await phone.next<Library>();
    phone.send(Launch(model.games[0].id));
    await until(() => model.toast == T.text('noToolkit'));
    await phone.close();
  });

  test('an installing game is told to the phone as an activity', () async {
    final phone = await pairedPhone();
    await phone.next<Library>();
    final locked = model.games[0];
    // A container the unwrapper takes, for the fake relinker to turn into a game.
    File(p.join(locked.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    model.unlock(locked);
    final activity = await phone.nextWhere<ActivityUpdate>((update) => update.activity != null);
    expect(activity.activity!.id, locked.id);
    await until(() => model.progress.isEmpty && model.queue.isEmpty);
    // The fake relinker installed it: the phone hears the activity end and sees it installed.
    final done = await phone.nextWhere<Library>((library) => library.games[0].state == GameState.installed);
    expect(done.games[0].state, GameState.installed);
    expect(server.RemoteGameState.installed.name, 'installed');
    await phone.close();
  });
}
