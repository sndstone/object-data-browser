import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/logs/structured_log_list.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';

Widget host(List<EventLogEntry> entries) => MaterialApp(
    home: Scaffold(
        body: StructuredLogList(
            entries: entries, textScalePercent: 100, emptyMessage: 'Empty')));

void main() {
  testWidgets('trace rows announce their expanded state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host([
      EventLogEntry(
          timestamp: DateTime(2026),
          level: 'DEBUG',
          category: 'API',
          message: 'SEND GET https://example.test/bucket '
              'HEADERS={"host":"example.test"} BODY=',
          source: 'api'),
    ]));
    final row = find.text('GET').first;
    expect(
        tester.getSemantics(row),
        isSemantics(
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
            hasTapAction: true));
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('GET').first),
        isSemantics(isButton: true, isExpanded: true));
    handle.dispose();
  });

  testWidgets('upload batch summary omits a missing bucket separator',
      (tester) async {
    final time = DateTime(2026);
    await tester.pumpWidget(host([
      EventLogEntry(
          timestamp: time,
          level: 'INFO',
          category: 'Transfers',
          message: 'Upload one file',
          source: 'upload-batch',
          requestId: 'batch',
          responseStatus: 'failed'),
      EventLogEntry(
          timestamp: time,
          level: 'ERROR',
          category: 'Transfers',
          message: 'Upload failed',
          source: 'upload-file',
          requestId: 'a',
          parentRequestId: 'batch',
          objectKey: 'a.txt',
          responseStatus: 'failed'),
    ]));
    expect(find.text('failed · 1 file'), findsOneWidget);
    await tester.tap(find.text('Upload one file'));
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
    expect(icon.color,
        Theme.of(tester.element(find.text('a.txt'))).colorScheme.error);
  });
}
