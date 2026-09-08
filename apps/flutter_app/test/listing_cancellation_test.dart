import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:s3_browser_crossplat/browser/object_panel.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

const profile = EndpointProfile(
    id: 'test',
    name: 'Test',
    endpointUrl: 'http://localhost:9000',
    region: 'us-east-1',
    accessKey: 'fixture',
    secretKey: 'fixture',
    pathStyle: true,
    verifyTls: false);
const bucket = BucketSummary(
    name: 'test',
    region: 'us-east-1',
    objectCountHint: 0,
    versioningEnabled: false);
ObjectEntry object(String key) => ObjectEntry(
    key: key,
    name: key,
    size: 1,
    storageClass: 'STANDARD',
    modifiedAt: DateTime(2026),
    isFolder: false);
ObjectListResult page(String key, {bool more = false}) => ObjectListResult(
    items: [object(key)],
    cursor: ListCursor(value: more ? key : null, hasMore: more));

class StalledListingEngine extends MockEngineService {
  final requests = <Completer<ObjectListResult>>[];
  final bucketRequest = Completer<List<BucketSummary>>();
  ObjectListResult? firstPage;
  int adminCalls = 0;
  Completer<ObjectVersionListResult>? versionsRequest;
  @override
  Future<ObjectVersionListResult> listObjectVersions(
          {required String engineId,
          required EndpointProfile profile,
          required String bucketName,
          String? key,
          VersionBrowserOptions? options,
          ListCursor? cursor}) =>
      versionsRequest?.future ??
      super.listObjectVersions(
          engineId: engineId,
          profile: profile,
          bucketName: bucketName,
          key: key,
          options: options,
          cursor: cursor);

  @override
  Future<ObjectListResult> listObjects(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String prefix,
      required bool flat,
      ListCursor? cursor}) {
    final request = Completer<ObjectListResult>();
    requests.add(request);
    if (requests.length == 1 && firstPage != null) request.complete(firstPage);
    return request.future;
  }

  @override
  Future<List<BucketSummary>> listBuckets(
          {required String engineId, required EndpointProfile profile}) =>
      bucketRequest.future;
  @override
  Future<BucketAdminState> getBucketAdminState(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName}) {
    adminCalls++;
    throw StateError('Cancellation must not dispatch bucket admin reads.');
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);
void main() {
  late StalledListingEngine engine;
  late AppController controller;
  setUp(() {
    engine = StalledListingEngine();
    controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [profile]);
    controller.selectedProfile = profile;
    controller.selectedBucket = bucket;
    controller.buckets = const [bucket];
  });
  tearDown(() => controller.dispose());

  test(
      'cancel returns while the object request is still hung; retry ignores late data',
      () async {
    controller.objects = [object('existing')];
    final listing = controller.refreshObjects();
    expect(engine.requests, hasLength(1));
    await controller.cancelTask(controller.browserTasks.single);
    await listing.timeout(const Duration(seconds: 1));
    expect(engine.requests.first.isCompleted, false);
    expect(controller.hasBusyActions, false);
    expect(controller.browserTasks.single.status, 'cancelled');
    expect(controller.objects.single.key, 'existing');
    expect(controller.bannerMessage, contains('Listing cancelled'));
    final retry = controller.refreshObjects();
    engine.requests[1].complete(page('new'));
    await retry;
    engine.requests[0].complete(page('stale'));
    await settle();
    expect(controller.objects.single.key, 'new');
    expect(controller.browserTasks.where((t) => t.status == 'failed'), isEmpty);
  });

  test(
      'late timeout after cancellation does not report an error or fail a new listing',
      () async {
    final listing = controller.refreshObjects();
    controller.cancelListing();
    controller.cancelListing();
    await listing.timeout(const Duration(seconds: 1));
    final retry = controller.refreshObjects();
    engine.requests.first
        .completeError(TimeoutException('late provider timeout'));
    await settle();
    engine.requests.last.complete(page('new'));
    await retry;
    expect(controller.objects.single.key, 'new');
    expect(controller.browserTasks.where((t) => t.status == 'failed'), isEmpty);
    expect(controller.bannerMessage, isNot(contains('timeout')));
  });

  test(
      'cancel preserves completed pages and cursor but ignores the in-flight page',
      () async {
    engine.firstPage = page('first', more: true);
    final listing = controller.refreshObjects(listAll: true);
    await settle();
    expect(engine.requests, hasLength(2));
    controller.cancelListing();
    await listing.timeout(const Duration(seconds: 1));
    expect(controller.objects.map((o) => o.key), ['first']);
    expect(controller.objectCursor.value, 'first');
    expect(controller.objectCursor.hasMore, true);
    engine.requests.last.complete(page('late'));
    await settle();
    expect(controller.objects.map((o) => o.key), ['first']);
    expect(controller.browserTasks.single.status, 'cancelled');
  });

  test(
      'cancel bucket enumeration keeps the previous bucket list and skips follow-up reads',
      () async {
    final listing = controller.refreshBuckets();
    controller.cancelListing();
    await listing.timeout(const Duration(seconds: 1));
    expect(controller.hasBusyActions, false);
    expect(controller.browserTasks.single.status, 'cancelled');
    expect(engine.requests, isEmpty);
    expect(engine.adminCalls, 0);
    engine.bucketRequest.complete([]);
    await settle();
    expect(controller.buckets, [bucket]);
    expect(controller.selectedBucket, bucket);
  });

  test('cancelling the initial bucket object listing skips admin loading',
      () async {
    final selection = controller.setSelectedBucket(bucket);
    controller.cancelListing();
    await selection.timeout(const Duration(seconds: 1));
    expect(engine.adminCalls, 0);
    expect(controller.hasBusyActions, false);
    expect(
        controller.browserTasks
            .firstWhere((t) => t.actionKey == 'refresh-objects')
            .status,
        'cancelled');
  });
  test('cancel also interrupts the version read performed after object listing',
      () async {
    engine.firstPage = page('loaded');
    engine.versionsRequest = Completer<ObjectVersionListResult>();
    final listing = controller.refreshObjects();
    await settle();
    expect(controller.objects.single.key, 'loaded');
    expect(controller.isBusy('refresh-objects'), true);
    controller.cancelListing();
    await listing.timeout(const Duration(seconds: 1));
    expect(controller.hasBusyActions, false);
    expect(controller.browserTasks.single.status, 'cancelled');
    engine.versionsRequest!
        .completeError(TimeoutException('late version timeout'));
    await settle();
    expect(controller.bannerMessage, contains('Listing cancelled'));
  });

  testWidgets(
      'Cancel listing button releases a stalled listing and becomes Refresh',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
      listenable: controller,
      builder: (_, __) => ObjectPanel(
          controller: controller,
          onUpload: () {},
          onDelete: () {},
          onCreatePrefix: () {},
          onInspector: () {},
          onContextMenu: (_, __) async {}),
    ))));
    final listing = controller.refreshObjects();
    await tester.pump();
    expect(find.byTooltip('Cancel listing'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel listing'));
    await tester.pump();
    await listing;
    await tester.pump();
    expect(find.byTooltip('Refresh object list'), findsOneWidget);
    expect(find.byTooltip('Cancel listing'), findsNothing);
    expect(engine.requests.single.isCompleted, false);
    await tester.pumpWidget(const SizedBox());
  });
  for (final fails in [false, true]) {
    test('cancel wins over an already queued ${fails ? "error" : "response"}',
        () async {
      controller.objects = [object('existing')];
      final listing = controller.refreshObjects();
      if (fails) {
        engine.requests.single
            .completeError(TimeoutException('queued timeout'));
      } else {
        engine.requests.single.complete(page('stale'));
      }
      controller.cancelListing();
      await listing.timeout(const Duration(seconds: 1));
      expect(controller.objects.single.key, 'existing');
      expect(controller.browserTasks.single.status, 'cancelled');
      expect(controller.bannerMessage, contains('Listing cancelled'));
    });
  }
}
