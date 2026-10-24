import 'package:anyps5_desktop/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the app starts', (tester) async {
    await tester.pumpWidget(const AnyPS5App());
    expect(find.text('AnyPS5'), findsOneWidget);
  });
}
