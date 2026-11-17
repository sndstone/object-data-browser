import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/settings/google_service_account_editor.dart';
import 'package:s3_browser_crossplat/widgets/connection_options_editor.dart';
import 'package:s3_browser_crossplat/widgets/app_form_dialog.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';

import 'google_cloud_storage_fixture.dart' show dummyServiceAccountJson;
import 'support/raw_dropdowns.dart';

void main() {
  testWidgets(
      'paste validates structure then masks the accepted key and replacement',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    String value = '';
    String? email;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, update) => GoogleServiceAccountEditor(
                      value: value,
                      onChanged: (json, identity) => update(() {
                        value = json;
                        email = identity.email;
                      }),
                    )))));
    await tester.tap(find.text('Paste JSON'));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((widget) => widget is AppFormDialog),
        findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SimpleDialog), findsNothing);
    expect(rawDropdowns(), findsNothing);
    expect(tester.takeException(), isNull);
    final input = find.byKey(const ValueKey('google-service-account-json'));
    await tester.enterText(input, '{"private_key":"never echo this"}');
    await tester.tap(find.text('Accept key'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The key must have type "service_account".'),
        findsWidgets);
    expect(value, isEmpty);
    final missing = jsonDecode(dummyServiceAccountJson()) as Map;
    missing.remove('project_id');
    await tester.enterText(input, jsonEncode(missing));
    await tester.tap(find.text('Accept key'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('The service-account key is missing project_id.'),
        findsWidgets);
    final json = dummyServiceAccountJson();
    await tester.enterText(input, json);
    await tester.tap(find.text('Accept key'));
    await tester.pumpAndSettle();
    expect(value, json);
    expect(email, 'throwaway@example.invalid');
    expect(find.text('throwaway@example.invalid'), findsOneWidget);
    expect(find.text('throwaway-project'), findsOneWidget);
    expect(find.text('•••••••• — key stored securely on Save'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('dummy'), findsNothing);
    await tester.ensureVisible(find.text('Replace by pasting JSON'));
    await tester.tap(find.text('Replace by pasting JSON'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(value, json);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Cloud Storage connection options omit AWS authentication and S3 options',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: SingleChildScrollView(
                child: ConnectionOptionsEditor(
          endpointType: EndpointProfileType.googleCloudStorage,
          value:
              const ConnectionOptions(authMode: 'assumeRole', roleArn: 'old'),
          onChanged: (_) {},
        )))));
    await tester.tap(find.text('Bucket access and endpoint capabilities'));
    await tester.pumpAndSettle();
    for (final label in [
      'Authentication',
      'Role ARN',
      'AWS profile name',
      'Requester Pays',
      'Expected owner',
      'Storage classes'
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(find.text('Known bucket'), findsOneWidget);
    expect(find.text('Trusted CA bundle'), findsOneWidget);
  });
}
