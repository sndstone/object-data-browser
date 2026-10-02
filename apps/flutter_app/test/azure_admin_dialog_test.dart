import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/browser/azure_admin_dialog.dart';
import 'package:s3_browser_crossplat/browser/storage_admin_dialog.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

class AzureAdminEngine extends MockEngineService {
  final requests = <Map<String, Object?>>[];
  final policy = <String, Object?>{
    'rules': [
      {'name': 'existing-custom', 'enabled': false}
    ]
  };
  @override
  Future<Map<String, Object?>> storageAction(
      {required EndpointProfile profile,
      required String action,
      Map<String, Object?> arguments = const {},
      EndpointProfile? destinationProfile}) async {
    requests.add({'action': action, ...arguments});
    if (action == 'providerInfo') {
      return {
        'actions': ['listTransferRecovery', 'resumeDownload', 'abortDownload']
      };
    }
    if (action == 'getAccountLifecycle') {
      return {'policy': policy, 'state': 'supported'};
    }
    if (action == 'putAccountLifecycle') return {'policy': arguments['policy']};
    if (action == 'listTransferRecovery') {
      return {
        'items': [
          {
            'id': 'download-fixture',
            'recoveryId': 'download-fixture',
            'kind': 'download',
            'key': 'file',
            'status': 'paused',
            'completedBytes': 1024,
            'fileSize': 2048
          },
        ]
      };
    }
    if (action == 'resumeDownload') {
      return {
        'id': 'download-fixture',
        'kind': 'download',
        'status': 'completed',
        'completedBytes': 2048,
        'fileSize': 2048
      };
    }
    return {};
  }
}

const azureFixtureProfile = EndpointProfile(
    id: 'fixture',
    name: 'Fixture Azure',
    endpointUrl: 'https://fixture.blob.core.windows.net',
    region: '',
    accessKey: '',
    secretKey: '',
    pathStyle: true,
    verifyTls: true,
    endpointType: EndpointProfileType.azureBlob,
    connection: ConnectionOptions(authMode: 'azureDefault'));

void main() {
  testWidgets(
      'Azure lifecycle preset requires review and preserves account rules',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = AzureAdminEngine();
    final controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [azureFixtureProfile]);
    await controller.initialize();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AzureAdminDialog(
                controller: controller,
                profile: azureFixtureProfile,
                bucket: 'container'))));
    await tester.enterText(find.byType(TextField).first,
        '/subscriptions/fixture/resourceGroups/fixture/providers/Microsoft.Storage/storageAccounts/fixture');
    await tester.tap(find.text('Lifecycle tiering presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load account lifecycle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review and apply preset'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.requests.where((r) => r['action'] == 'putAccountLifecycle'),
        isEmpty);
    await tester.tap(find.text('Review and apply preset'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    final request = engine.requests
        .singleWhere((r) => r['action'] == 'putAccountLifecycle');
    expect(request['expectedPolicy'], engine.policy);
    final rules = (request['policy'] as Map)['rules'] as List;
    expect(rules.first, (engine.policy['rules'] as List).first);
    expect((rules.last as Map)['definition']['filters']['prefixMatch'],
        ['container/']);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('download recovery record dispatches resumeDownload',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = AzureAdminEngine();
    final controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [azureFixtureProfile]);
    await controller.initialize();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StorageAdminDialog(controller: controller))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recoverable file transfers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh recovery records'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Resume transfer'));
    await tester.pumpAndSettle();
    final request =
        engine.requests.singleWhere((r) => r['action'] == 'resumeDownload');
    expect(request['recoveryId'], 'download-fixture');
    expect(
        engine.requests.where((r) => r['action'] == 'resumeUpload'), isEmpty);
    expect(find.text('Transfer completed.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
