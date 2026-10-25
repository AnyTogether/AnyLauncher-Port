import 'package:anyps5_desktop/core/trophies.dart';
import 'package:anyps5_desktop/ui/trophy_card.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

void main() {
  testWidgets('the trophy card is drawn at the screen\'s scale, a card on a clear background', (tester) async {
    await tester.runAsync(() async {
      await loadFonts();
      final trophy = Trophy(
        serviceLabel: 0,
        number: 3,
        grade: TrophyGrade.gold,
        hidden: false,
        name: 'Into the Citadel',
        detail: 'Reach the heart of Pharloom',
        icon: iconArt(0xF2C14E, 0x5C3B0B, size: 64),
      );
      final card = await TrophyCard.render(trophy);
      expect((card.width, card.height), (560, 140));
      int alpha(int x, int y) => card.pixels[(y * card.width + x) * 4 + 3];
      expect(alpha(0, 0), 0, reason: 'clear around the card');
      expect(alpha(280, 70), greaterThan(230), reason: 'the card itself');
      final double = await TrophyCard.render(trophy, scale: 2);
      expect((double.width, double.height), (1120, 280));
    });
  });
}
