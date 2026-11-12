import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/controllers/object_query.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

const profile = EndpointProfile(
    id: 'test',
    name: 'Test',
    endpointUrl: 'http://localhost:9000',
    region: 'us-east-1',
    accessKey: 'test',
    secretKey: 'test',
    pathStyle: true,
    verifyTls: false);
const bucket = BucketSummary(
    name: 'bucket',
    region: 'us-east-1',
    objectCountHint: 1,
    versioningEnabled: true);
ObjectEntry object(String key) => ObjectEntry(
    key: key,
    name: key,
    size: 10,
    storageClass: 'STANDARD',
    modifiedAt: DateTime(2026),
    isFolder: false);
ObjectDetails details(String key, {String? type}) => ObjectDetails(
    key: key,
    metadata: const {},
    headers: type == null ? const {} : {'content-type': type},
    tags: const {},
    debugEvents: const [],
    apiCalls: const []);
ObjectVersionEntry version(String key, String id) => ObjectVersionEntry(
    key: key,
    versionId: id,
    modifiedAt: DateTime(2026),
    latest: false,
    deleteMarker: false,
    size: 1);

class ResourceEngine extends MockEngineService {
  Completer<ObjectDetails>? firstDetails;
  bool repeatedPages = false;
  int listingCalls = 0;
  String? previewUrl;
  Completer<ObjectListResult>? deferredListing;
  @override
  Future<ObjectDetails> getObjectDetails(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String key}) async {
    if (key == 'a.bin' && firstDetails != null) return firstDetails!.future;
    return details(key);
  }

  @override
  Future<ObjectVersionListResult> listObjectVersions(
          {required String engineId,
          required EndpointProfile profile,
          required String bucketName,
          String? key,
          VersionBrowserOptions? options,
          ListCursor? cursor}) async =>
      const ObjectVersionListResult(
          items: [],
          cursor: ListCursor(value: null, hasMore: false),
          totalCount: 0,
          versionCount: 0,
          deleteMarkerCount: 0);
  @override
  Future<ObjectListResult> listObjects(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String prefix,
      required bool flat,
      ListCursor? cursor}) async {
    listingCalls++;
    if (deferredListing != null) return deferredListing!.future;
    return ObjectListResult(
        items: const [],
        cursor: ListCursor(
            value: repeatedPages ? 'repeated' : null, hasMore: repeatedPages));
  }

  @override
  Future<String> generatePresignedUrl(
          {required String engineId,
          required EndpointProfile profile,
          required String bucketName,
          required String key,
          required Duration expiration}) async =>
      previewUrl!;
}

AppController controller(ResourceEngine engine) {
  final value = AppController(
      engineService: engine,
      initialSettings: AppSettings.fromJson({}),
      initialProfiles: const [profile]);
  value.selectedProfile = profile;
  value.selectedBucket = bucket;
  return value;
}

Future<void> settleUntil(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  test('new selection wins while a previous details request is pending',
      () async {
    final engine = ResourceEngine()..firstDetails = Completer<ObjectDetails>();
    final c = controller(engine);
    addTearDown(c.dispose);
    final first = c.setSelectedObject(object('a.bin'));
    await Future<void>.delayed(Duration.zero);
    final second = c.setSelectedObject(object('b.bin'));
    expect(c.selectedObject!.key, 'b.bin');
    await second;
    expect(c.selectedObjectDetails!.key, 'b.bin');
    engine.firstDetails!.complete(details('a.bin'));
    await first;
    expect(c.selectedObject!.key, 'b.bin');
    expect(c.selectedObjectDetails!.key, 'b.bin');
  });

  test('repeated empty listing pages terminate with partial results', () async {
    final engine = ResourceEngine()..repeatedPages = true;
    final c = controller(engine);
    addTearDown(c.dispose);
    await c.refreshObjects(listAll: true);
    expect(engine.listingCalls, 2);
    expect(c.objectCursor.hasMore, isFalse);
    expect(c.objectListingError, contains('continuation'));
  });

  test('version pages deduplicate incrementally and retain previous access',
      () {
    final pages = VersionPages();
    pages.append([version('a', '1'), version('a', '2')]);
    pages.append([version('a', '2'), version('a', '3')]);
    expect(pages.map((v) => v.versionId), ['1', '2', '3']);
    expect(() => pages[0] = version('a', '4'), throwsUnsupportedError);
  });

  test('folder navigation clears previous selection before a failed listing',
      () async {
    final engine = ResourceEngine()
      ..deferredListing = Completer<ObjectListResult>();
    final c = controller(engine);
    addTearDown(c.dispose);
    final old = object('old.bin');
    c.objects = [old];
    c.objectSelection.selectAll([old]);
    final operation = c.openFolder(ObjectEntry(
        key: 'next/',
        name: 'next/',
        size: 0,
        storageClass: 'STANDARD',
        modifiedAt: DateTime(2026),
        isFolder: true));
    expect(c.objectSelection.isEmpty, isTrue);
    engine.deferredListing!.completeError(const EngineException(
        code: ErrorCode.engineUnavailable, message: 'fixture listing failed'));
    await operation;
    expect(c.objectSelection.isEmpty, isTrue);
  });

  test('large object queries preserve original objects across repeated queries',
      () async {
    Completer<void>? changed;
    final query = ObjectQuery((error) {
      expect(error, isNull);
      changed?.complete();
    });
    addTearDown(query.dispose);
    final objects = List.generate(6000, (i) => object('entry-$i.bin'));
    changed = Completer<void>();
    query.resolve(objects, BrowserFilterMode.text, 'entry-5999',
        BrowserObjectSortField.name, false);
    await changed.future.timeout(const Duration(seconds: 5));
    expect(
        identical(
            query
                .resolve(objects, BrowserFilterMode.text, 'entry-5999',
                    BrowserObjectSortField.name, false)
                .single,
            objects.last),
        isTrue);
    changed = Completer<void>();
    query.resolve(objects, BrowserFilterMode.text, 'entry-0.',
        BrowserObjectSortField.name, false);
    await changed.future.timeout(const Duration(seconds: 5));
    expect(
        identical(
            query
                .resolve(objects, BrowserFilterMode.text, 'entry-0.',
                    BrowserObjectSortField.name, false)
                .single,
            objects.first),
        isTrue);
  });

  test('pathological version regex times out away from the UI isolate',
      () async {
    final completed = Completer<String?>();
    final query = VersionQuery(completed.complete);
    addTearDown(query.dispose);
    query.resolve(
        [version('${'a' * 100}!', '1')],
        const VersionBrowserOptions(
            filterMode: BrowserFilterMode.regex, filterValue: r'(a+)+$'));
    expect(await completed.future.timeout(const Duration(seconds: 5)),
        contains('execution budget'));
    expect(query.loading, isFalse);
  });

  test('HTTP errors never become ready text previews', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('Access denied');
      await request.response.close();
    });
    final engine = ResourceEngine()
      ..previewUrl = 'http://127.0.0.1:${server.port}/sample';
    final c = controller(engine);
    addTearDown(c.dispose);
    await c.setSelectedObject(object('sample.txt'));
    await settleUntil(() =>
        c.selectedObjectPreview != null && !c.selectedObjectPreview!.loading);
    expect(c.selectedObjectPreview!.supported, isFalse);
    expect(c.selectedObjectPreview!.text, isNull);
  });
}
