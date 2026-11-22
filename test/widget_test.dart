import 'package:carnatic_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home shows Gamaka brand', (tester) async {
    await tester.pumpWidget(const GamakaApp());
    expect(find.text('GAMAKA'), findsOneWidget);
    expect(find.textContaining('Shankarabharanam'), findsWidgets);
  });
}
