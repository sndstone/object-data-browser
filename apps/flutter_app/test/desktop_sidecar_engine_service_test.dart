import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/desktop_sidecar_engine_service.dart';

void main() {
  late Directory emptyEngineRoot;
  late DesktopSidecarEngineService service;

  setUp(() async {
    emptyEngineRoot =
        await Directory.systemTemp.createTemp('empty_engine_root_test');
    service = DesktopSidecarEngineService(engineRoot: emptyEngineRoot.path);
  });

  tearDown(() async {
    service.shutdown();
    await emptyEngineRoot.delete(recursive: true);
  });

  test('reports engines unavailable when sidecars are not installed', () async {
    final engines = await service.listEngines();
    expect(engines, isNotEmpty);
    expect(engines, everyElement(hasUnavailableStatus));
  });

  test('does not silently substitute mock bucket data', () async {
    await expectLater(
      service.listBuckets(engineId: 'python', profile: profile),
      throwsA(
        isA<EngineException>()
            .having((error) => error.code, 'code', ErrorCode.engineUnavailable),
      ),
    );
  });
}

const profile = EndpointProfile(
  id: 'test',
  name: 'Test',
  endpointUrl: 'http://localhost:9000',
  region: 'us-east-1',
  accessKey: 'access',
  secretKey: 'secret',
  pathStyle: true,
  verifyTls: false,
);

Matcher get hasUnavailableStatus => isA<EngineDescriptor>()
    .having((engine) => engine.available, 'available', false);
