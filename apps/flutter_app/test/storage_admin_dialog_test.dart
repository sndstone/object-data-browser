import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/browser/storage_admin_dialog.dart';

class AdminEngine extends MockEngineService {
  final requests = <Map<String, Object?>>[];
  @override
  Future<Map<String, Object?>> storageAction(
      {required EndpointProfile profile,
      required String action,
      Map<String, Object?> arguments = const {},
      EndpointProfile? destinationProfile}) async {
    requests.add({'action': action, ...arguments});
    if (action == 'providerInfo') {
      return {
        'actions': ['deleteVersion']
      };
    }
    if (action == 'deleteVersion') {
      return {'successCount': 1, 'failureCount': 0};
    }
    return {};
  }
}

void main() {
  testWidgets(
      'exact delete-marker reference survives confirmation; cancel dispatches nothing',
      (tester) async {
    final engine = AdminEngine();
    final controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [
          EndpointProfile(
              id: 'p',
              name: 'Test',
              endpointUrl: 'https://example.test',
              region: 'us-east-1',
              accessKey: 'x',
              secretKey: 'y',
              pathStyle: true,
              verifyTls: true)
        ]);
    await controller.initialize();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => StorageAdminDialog(
                            controller: controller,
                            objectKey: ' spaced + key ',
                            versionId: 'null',
                            deleteMarker: true)),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove this delete marker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        engine.requests.where((r) => r['action'] == 'deleteVersion'), isEmpty);
    await tester.tap(find.text('Remove this delete marker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    final request =
        engine.requests.singleWhere((r) => r['action'] == 'deleteVersion');
    expect(request['key'], ' spaced + key ');
    expect(request['versionId'], 'null');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
