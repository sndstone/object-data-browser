import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';

void main() {
  testWidgets('iOS select field opens and selects a route menu item',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, setState) => AppSelectField<String>(
                  value: selected,
                  items: const [
                    AppSelectItem(value: 'go', label: 'Go (iOS)'),
                    AppSelectItem(value: 'rust', label: 'Rust (iOS)'),
                  ],
                  onChanged: (value) => setState(() => selected = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Go (iOS)'), findsOneWidget);

    await tester.tap(find.text('Go (iOS)'));
    await tester.pumpAndSettle();
    expect(selected, 'go');
  });
}
