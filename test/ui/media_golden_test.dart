import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Settings › Broadcasting as it looks, in English and Turkish.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> broadcasting(WidgetTester tester, Language language, String golden) async {
    fixture = makeFixture(language: language);
    final model = fixture.model;
    model.media
      ..ffmpegOverride = 'ffmpeg'
      ..encodersOverride = EncoderChoice(ffmpeg: 'ffmpeg', system: HostSystem.linux, run: (_, _) async => throw StateError('none'))
      ..areaOverride = ((_) => const ScreenArea(0, 0, 1920, 1080));
    await tester.runAsync(() async => model.media.setKey('live_123456789_abcd'));
    model.openSettingsCategory('broadcast');
    await pumpLauncher(tester, model);
    await expectLater(shell, matchesGoldenFile(golden));
  }

  testWidgets('settings: broadcasting', (tester) => broadcasting(tester, Language.english, 'goldens/settings_broadcast.png'));

  testWidgets(
    'settings: broadcasting, in Turkish',
    (tester) => broadcasting(tester, Language.byCode('tr'), 'goldens/settings_broadcast_tr.png'),
  );
}
