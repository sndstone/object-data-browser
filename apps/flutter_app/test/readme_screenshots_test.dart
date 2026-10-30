// Opt-in documentation capture; never connects to a storage endpoint.
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

final _date = DateTime(2026, 10, 28, 14, 32);
const _source = '''{
  "release": "autumn-2026",
  "environment": "staging",
  "region": "eu-central-1",
  "assets": [
    {
      "key": "images/cover.webp",
      "contentType": "image/webp",
      "cacheControl": "public, max-age=86400"
    },
    {
      "key": "exports/catalog.parquet",
      "contentType": "application/octet-stream",
      "rows": 24800
    }
  ],
  "retention": {
    "archiveAfterDays": 90,
    "expireAfterDays": 365
  }
}
''';

ObjectEntry _object(String name, int size, {bool folder = false}) =>
    ObjectEntry(
      key: name,
      name: name,
      size: size,
      storageClass: folder ? 'FOLDER' : 'STANDARD',
      modifiedAt: _date,
      isFolder: folder,
      metadataCount: folder ? 0 : 2,
      etag: folder ? null : 'd41d8cd98f00b204e9800998ecf8427e',
    );

class _ScreenshotEngine extends MockEngineService {
  @override
  Future<List<BucketSummary>> listBuckets({
    required String engineId,
    required EndpointProfile profile,
  }) async =>
      [
        for (final name in [
          'studio-assets',
          'daily-backups',
          'build-artifacts'
        ])
          BucketSummary(
            name: name,
            region: 'eu-central-1',
            objectCountHint: name == 'studio-assets' ? 12 : 48,
            versioningEnabled: true,
            createdAt: DateTime(2026, 8, 12),
          ),
      ];

  @override
  Future<ObjectListResult> listObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required bool flat,
    ListCursor? cursor,
  }) async =>
      ObjectListResult(items: [
        _object('exports/', 0, folder: true),
        _object('images/', 0, folder: true),
        _object('releases/', 0, folder: true),
        _object('release-manifest.json', _source.length),
        _object('asset-index.csv', 98304),
        _object('brand-guidelines.pdf', 2457600),
        _object('catalog.parquet', 184549376),
        _object('cover.webp', 458752),
        _object('deployment.yaml', 1840),
        _object('product-feed.json', 327680),
        _object('readme.txt', 2148),
        _object('site-backup.tar.gz', 734003200),
      ], cursor: const ListCursor(value: null, hasMore: false));
}

void main() {
  testWidgets('capture README screenshots', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      await tester.binding.setSurfaceSize(null);
    });
    for (final (family, path) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ('Inter', 'assets/fonts/Inter.ttf'),
      ('Sora', 'assets/fonts/Sora.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(path))).load();
    }
    // Widget tests otherwise substitute Ahem's square glyphs for system fonts.
    final monoPath = Platform.environment['README_MONOSPACE_FONT'] ??
        (Platform.isWindows
            ? r'C:\Windows\Fonts\consola.ttf'
            : Platform.isMacOS
                ? '/System/Library/Fonts/Menlo.ttc'
                : '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf');
    final monoBytes = await tester.runAsync(() => File(monoPath).readAsBytes());
    await (FontLoader('monospace')
          ..addFont(Future.value(ByteData.sublistView(monoBytes!))))
        .load();
    final controller = AppController(
      engineService: _ScreenshotEngine(),
      initialSettings: AppSettings.fromJson({
        'defaultEngineId': 'python',
        'darkMode': true,
        'enableAnimations': false,
        'uiScalePercent': 100,
        'browserInspectorLayout': 'right',
        'downloadPath': r'C:\Downloads',
      }),
      initialProfiles: const [
        EndpointProfile(
          id: 'demo',
          name: 'Studio storage',
          endpointUrl: 'https://s3.example.com',
          region: 'eu-central-1',
          accessKey: 'DEMO-ACCESS-KEY',
          secretKey: 'fictional-demo-secret',
          pathStyle: true,
          verifyTls: true,
        ),
      ],
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.selectedObject = controller.objects
        .singleWhere((o) => o.name == 'release-manifest.json');
    controller.selectedObjectDetails = const ObjectDetails(
      key: 'release-manifest.json',
      metadata: {'owner': 'studio', 'build': 'autumn-2026'},
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'public, max-age=3600',
      },
      tags: {'environment': 'staging', 'project': 'catalog'},
      debugEvents: [],
      apiCalls: [],
    );
    controller.selectedObjectPreview = ObjectPreview.ready(
      key: 'release-manifest.json',
      kind: ObjectPreviewKind.text,
      contentType: 'application/json',
      text: _source,
      loadedBytes: _source.length,
      message: 'Preview loaded.',
    );
    controller.inspectorTab = BrowserInspectorTab.objectDetails;
    controller.clearBanner();
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: S3BrowserApp(controller: controller),
    ));
    await tester.pumpAndSettle();

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await (boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        try {
          final bytes = await image.toByteData(format: ImageByteFormat.png);
          final file = File('../../docs/screenshots/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }

    await capture('browser-dark');
    controller.settings = controller.settings.copyWith(darkMode: false);
    controller.clearBanner();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();
    await capture('source-preview-light');
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    controller.selectTab(WorkspaceTab.settings);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Studio storage').last);
    await tester.pumpAndSettle();
    await capture('settings-light');
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  }, skip: Platform.environment['README_SCREENSHOTS'] != '1');
}
