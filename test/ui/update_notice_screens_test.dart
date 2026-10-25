import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

/// The launcher's own update on screen: the notice beside the top bar, focused from the pad, and
/// waiting for a game, in both languages.
void main() {
  final shell = find.byType(LauncherShell);
  Fixture? fixture;

  tearDown(() {
    fixture?.model.dispose();
    fixture?.dispose();
    fixture = null;
    T.language = Language.english;
  });

  AppModel ready(Language language) {
    fixture = makeFixture(system: HostSystem.windows, language: language);
    final model = fixture!.model;
    final installer = p.join(fixture!.temp.path, 'AnyPS5-Desktop-Setup-0.1.6-x64.exe');
    File(installer).writeAsBytesSync([0x4D, 0x5A]);
    T.language = language;
    model.updates
      ..latest = sampleRelease('0.1.6')
      ..downloaded = installer
      ..downloadedVersion = '0.1.6';
    return model;
  }

  for (final language in Language.values) {
    testWidgets('the notice beside the top bar, Restart Now focused (${language.code})', (tester) async {
      final model = ready(language);
      expect(model.updates.showsNotice, isTrue);
      model.handle(Command.up);
      model.handle(Command.left);
      expect(model.focus, const HomeFocus.top(0));
      model.handle(Command.left);
      expect(model.focus, const HomeFocus.notice(1), reason: 'the pad reaches it left of the top bar');
      model.handle(Command.left);
      expect(model.focus, const HomeFocus.notice(0));
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/update_notice_${language.code}.png'));
    });
  }

  testWidgets('Later on the pad: the notice goes, the focus is back on the top bar', (tester) async {
    final model = ready(Language.english);
    model.handle(Command.up);
    model.handle(Command.left);
    model.handle(Command.left);
    model.handle(Command.select);
    expect(model.updates.showsNotice, isFalse);
    expect(model.focus, const HomeFocus.top(0));
    model.handle(Command.left);
    expect(model.focus, const HomeFocus.top(0), reason: 'nothing left of the top bar now');
    expect(
      File(p.join(model.updates.folder, 'pending.json')).existsSync(),
      isTrue,
      reason: 'the installer runs at the next launch',
    );
  });

  testWidgets('waiting for the game (tr)', (tester) async {
    final model = ready(Language.turkish);
    model.starting = model.games.first;
    await model.updates.restartNow();
    model.starting = null;
    expect(model.updates.restartAfterGame, isTrue);
    await pumpLauncher(tester, model);
    await expectLater(shell, matchesGoldenFile('goldens/update_notice_waiting_tr.png'));
  });
}
