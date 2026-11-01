import 'package:anyps5_desktop/core/together/cloud_saves.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/save_sync_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// The question Save Sync asks over the launcher when both sides changed (in a file of its own:
/// a widget test's binding answers every HTTP request with a 400, which the cloud tests need).
void main() {
  testWidgets('golden: the question when saves changed here and in the cloud', (tester) async {
    final fixture = makeFixture();
    addTearDown(fixture.dispose);
    final model = fixture.model;
    final asked = CloudQuestion<ConflictChoice>(
      title: T.text('cloudConflictTitle'),
      detail: T.format('cloudConflictDetail', ['Orbit Runner', 'Laptop', '2026-11-01 21:04']),
      answers: [
        (T.text('cloudConflictTakeCloud'), ConflictChoice.takeCloud),
        (T.text('cloudConflictKeepMine'), ConflictChoice.keepThisComputer),
        (T.text('cloudNotNow'), ConflictChoice.notNow),
      ],
    );
    model.saveSync.question = asked;
    model.open(Layer.cloudQuestion);
    model.panelRow = 1;
    await pumpLauncher(tester, model);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/cloud_conflict.png'));
    model.command(Command.back);
    expect(await asked.answer, ConflictChoice.notNow);
    model.dispose();
  });
}
