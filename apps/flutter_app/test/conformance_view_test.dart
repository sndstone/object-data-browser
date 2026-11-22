import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/benchmark/benchmark_workspace.dart';
import 'package:s3_browser_crossplat/conformance/conformance_models.dart';
import 'package:s3_browser_crossplat/conformance/conformance_suite.dart';
import 'package:s3_browser_crossplat/conformance/sidecar_s3_op_executor.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';

import 'conformance_fake.dart';

const _profile = EndpointProfile(
  id: 'conformance',
  name: 'Conformance endpoint',
  endpointUrl: 'https://s3.conformance.example',
  region: 'us-east-1',
  accessKey: 'fixture-access',
  secretKey: 'fixture-secret',
  pathStyle: true,
  verifyTls: true,
);

/// A desktop-like engine service: the mock plus the conformance transport.
class _DesktopLikeService extends MockEngineService implements S3ConformanceTransport {
  final FakeExecutor endpoint = FakeExecutor();
  int requests = 0;

  @override
  Future<Map<String, Object?>> conformanceRequest({
    required String engineId,
    required EndpointProfile profile,
    required String method,
    Map<String, Object?> params = const {},
  }) async {
    requests++;
    throw const EngineException(code: ErrorCode.unsupportedFeature, message: 'not used in layout tests');
  }
}

Future<ConformanceReport> _report() async {
  final runs = <ConformanceEngineRun>[];
  for (final engine in ['python', 'go']) {
    runs.add(await S3ConformanceSuite(
      executor: FakeExecutor(engineId: engine, ops: engine == 'go' ? ({...allConformanceOps}..remove('ListObjects')) : null),
      config: const ConformanceConfig(baseBucketName: 'odb-layout'),
      endpoint: const ConformanceEndpoint(endpointUrl: 'https://s3.conformance.example', region: 'us-east-1', pathStyle: true),
      sleep: (_) async {},
      multipartPartSize: 32 * 1024,
    ).run());
  }
  return ConformanceReport(
      id: 'layout', config: const ConformanceConfig(baseBucketName: 'odb-layout', engineIds: ['python', 'go']),
      profileName: _profile.name, startedAt: DateTime(2026, 11, 22))
    ..engines.addAll(runs);
}

void _checkText(WidgetTester tester, {required bool checkSize}) {
  var checked = 0;
  void walk(RenderObject object) {
    if (object is RenderParagraph && object.hasSize) {
      final matrix = object.getTransformTo(null).storage;
      final paintScale = math.sqrt(matrix[0] * matrix[0] + matrix[1] * matrix[1]);
      final style = object.text.style ?? const TextStyle();
      final text = object.text.toPlainText();
      if (text.trim().isNotEmpty && !(style.fontFamily ?? '').toLowerCase().contains('icons')) {
        checked++;
        expect(object.didExceedMaxLines, isFalse, reason: 'Clipped conformance text: "$text"');
        if (checkSize) {
          expect(object.textScaler.scale(style.fontSize ?? 14) * paintScale, greaterThanOrEqualTo(12 - 0.01),
              reason: 'Small conformance text: "$text"');
        }
      }
    }
    object.visitChildren(walk);
  }

  walk(tester.renderObject(find.byType(BenchmarkWorkspace)));
  expect(checked, greaterThan(0));
}

void main() {
  testWidgets('mobile-like engine services never show the conformance mode', (tester) async {
    final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson({'enableAnimations': false}),
        initialProfiles: const [_profile]);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.conformance.available, isFalse);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BenchmarkWorkspace(controller: controller))));
    await tester.pump();
    expect(find.byKey(const ValueKey('benchmark-mode-selector')), findsNothing);
    expect(find.text('S3 API conformance'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(1000, 760), const Size(1280, 860), const Size(390, 844)]) {
    for (final scale in [100, 150]) {
      testWidgets('conformance view ${size.width}x${size.height} at $scale%', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _DesktopLikeService();
        final controller = AppController(
            engineService: service,
            initialSettings: AppSettings.fromJson({'enableAnimations': false}),
            initialProfiles: const [_profile]);
        addTearDown(controller.dispose);
        await controller.initialize();
        expect(controller.conformance.available, isTrue);
        final report = (await tester.runAsync(_report))!;
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(scalePercent: scale, desktopCompact: size.width >= 700),
          home: Scaffold(body: BenchmarkWorkspace(controller: controller)),
        ));
        await tester.pump();
        await tester.tap(find.text('S3 API conformance'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('conformance-base-name')), findsOneWidget);
        await tester.scrollUntilVisible(find.byKey(const ValueKey('conformance-run')), 200,
            scrollable: find
                .descendant(of: find.byKey(const ValueKey('conformance-setup-list')), matching: find.byType(Scrollable))
                .first);
        expect(find.byKey(const ValueKey('conformance-run')), findsOneWidget);
        expect(tester.takeException(), isNull);
        _checkText(tester, checkSize: scale == 100);

        controller.conformance.history.insert(0, report);
        controller.conformance.select(report);
        await tester.pump();
        await tester.tap(find.text('Results (2)'));
        await tester.pumpAndSettle();
        expect(find.text('python · fake-sdk 1.0'), findsOneWidget);
        await tester.scrollUntilVisible(find.byKey(const ValueKey('conformance-check-bucket.create')), 300,
            scrollable: find
                .descendant(of: find.byKey(const ValueKey('conformance-results-list')), matching: find.byType(Scrollable))
                .first);
        await tester.ensureVisible(find.text('CreateBucket creates the standard test bucket'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('CreateBucket creates the standard test bucket'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _checkText(tester, checkSize: scale == 100);

        await tester.tap(find.text('Compare engines'));
        await tester.pumpAndSettle();
        expect(find.text('list.v1.delimiter'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(service.requests, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
