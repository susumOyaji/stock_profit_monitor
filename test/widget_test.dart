// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:stock_profit_monitor/main.dart';

void main() {
  testWidgets('Renders main page and initial stocks', (WidgetTester tester) async {
    // This is needed to mock SharedPreferences.
    SharedPreferences.setMockInitialValues({});

    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // Verify that the title is rendered.
    expect(find.text('Profit Monitor'), findsOneWidget);

    // Verify that the total P&L label is rendered.
    expect(find.text('Total P&L:'), findsOneWidget);

    // Verify that the initial dummy stocks are present.
    expect(find.text('AAPL'), findsOneWidget);
    expect(find.text('GOOGL'), findsOneWidget);
  });
}