import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/share_play.dart';
import 'package:anyps5_desktop/core/together/share_viewer.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide GameState;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Watching a friend's share play, headless: the picture is flutter_webrtc's and is not drawn
/// here, so the screen shows what it has until the picture comes, with the chip and the seat.
void main() {
  late Fixture fixture;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  testWidgets('golden: watching Ana\'s share play as player 2, before the picture (en)', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    model.together.account.user = const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
    model.sharePlay
      ..watching = const SharePlay(
        id: 'sp-9',
        host: Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
        hostDevice: 'ana-mac',
        titleId: 'PPSA02002',
        title: 'Neon Alley',
        open: true,
        maxViewers: 2,
        viewers: [
          ShareViewer(user: Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis'), device: 'd', slot: 2),
        ],
      )
      ..watchStats = const WatchStats(roundTripMs: 31, framesPerSecond: 60, height: 720);
    model.open(Layer.shareWatch);
    await pumpLauncher(tester, model);
    expect(find.text(T.text('sharePlayConnecting')), findsOneWidget);
    expect(find.text('Ana · Neon Alley'), findsOneWidget);
    expect(find.text('${T.format('sharePlayPlayer', [2])} · 31 ms · 720p60'), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/share_watch_en.png'));
  });
}
