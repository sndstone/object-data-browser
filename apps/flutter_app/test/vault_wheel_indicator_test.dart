import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/vault_wheel_indicator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the completed wheel paints just an even outline and centered check',
      () async {
    const ink = Color(0xff15211f);
    const accent = Color(0xff004d19);
    final painter = VaultWheelPainter(
      clock: const AlwaysStoppedAnimation(1.0),
      phase: VaultWheelPhase.unlocked,
      foreground: ink,
      accent: accent,
      background: const Color(0xffe8f2ee),
    );
    final actual = await _pixels((canvas) {
      painter.paint(canvas, const Size(28, 32));
    });
    final expected = await _pixels((canvas) {
      final pen = Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawRRect(
        const RRect.fromLTRBXY(4.6, 5.4, 23.4, 26.6, 3, 3),
        pen,
      );
      final check = Path()
        ..moveTo(9.6, 15.4)
        ..lineTo(12.7, 18.6)
        ..lineTo(18.6, 12.4);
      canvas.drawPath(
          check,
          pen
            ..color = accent
            ..strokeWidth = 1.85);
    });
    expect(actual, orderedEquals(expected));
  });

  testWidgets(
      'bucket menu unlock stays closed on failure and finishes on success',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 850);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('vault-wheel-indicator-')))!;
    final store = EncryptionKeyStore(File('${directory.path}/keys.age'),
        scryptWorkFactor: 1);
    await tester.runAsync(() => store.create('fixture passphrase'));
    store.lock();
    final controller = AppController(
      engineService: MockEngineService(),
      encryptionKeyStore: store,
      initialSettings: AppSettings.fromJson({
        'enableAnimations': true,
        'uiScalePercent': 80,
      }),
      initialProfiles: const [
        EndpointProfile(
          id: 'vault-menu-fixture',
          name: 'Fixture',
          endpointUrl: 'https://example.test',
          region: 'us-east-1',
          accessKey: 'fixture',
          secretKey: 'fixture',
          pathStyle: true,
          verifyTls: true,
          clientEncryptionRules: [
            ClientEncryptionRule(
              bucket: 'archive-vault',
              keyId: 'fixture-key',
              recipient: 'fixture-recipient',
              label: 'Archive',
            ),
          ],
        ),
      ],
    );
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    final openBucket = controller.selectedBucket;
    expect(openBucket?.name, 'benchmark-scratch');
    controller.selectedBucket = controller.buckets
        .singleWhere((bucket) => bucket.name == 'archive-vault');
    expect(controller.clientKeyUnlockRequired, isTrue);
    controller.selectedBucket = openBucket;
    await tester.tap(
      find.widgetWithText(ListTile, 'archive-vault'),
      buttons: kSecondaryMouseButton,
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock vault…'));
    await tester.pumpAndSettle();
    final wheel = find.byType(VaultWheelIndicator);

    await tester.enterText(find.byType(TextField).last, 'incorrect');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await _pumpUntil(tester,
        () => find.text('The passphrase is incorrect.').evaluate().isNotEmpty);
    expect(store.isUnlocked, isFalse);
    expect(find.text('Vault unlocked.'), findsNothing);
    expect(controller.selectedBucket, same(openBucket));

    await tester.enterText(find.byType(TextField).last, 'fixture passphrase');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await _pumpUntil(
        tester, () => find.text('Vault unlocked.').evaluate().isNotEmpty);
    expect(tester.widget<VaultWheelIndicator>(wheel).phase,
        VaultWheelPhase.unlocked);
    expect(controller.selectedBucket, same(openBucket));
    expect(controller.canUnlockBucketVault('archive-vault'), isFalse);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('Vault unlocked.'), findsOneWidget);
    final painter = tester
        .widget<CustomPaint>(find.descendant(
          of: wheel,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is CustomPaint && widget.painter is VaultWheelPainter,
          ),
        ))
        .painter! as VaultWheelPainter;
    expect(painter.clock.value, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(wheel, findsNothing);
  });
}

Future<List<int>> _pixels(void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(4);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(112, 128);
  try {
    return (await image.toByteData())!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 150 && !ready(); attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}
