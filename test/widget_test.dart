// UI smoke tests for Bakushi widgets that do not require the native engine.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/ui/widgets/section_card.dart';

void main() {
  testWidgets('SectionCard renders title and child', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SectionCard(title: 'Test section', child: const Text('inner')),
        ),
      ),
    );

    expect(find.text('Test section'), findsOneWidget);
    expect(find.text('inner'), findsOneWidget);
  });
}
