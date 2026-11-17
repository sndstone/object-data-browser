import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/browser/browser_workspace.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/settings_workspace.dart';

const _profile = EndpointProfile(
    id: 'test',
    name: 'Test',
    endpointUrl: 'http://localhost:9000',
    region: 'us-east-1',
    accessKey: 'fixture',
    secretKey: 'fixture',
    pathStyle: true,
    verifyTls: false);
const _bucket = BucketSummary(
    name: 'original',
    region: 'us-east-1',
    objectCountHint: 2,
    versioningEnabled: true);
ObjectEntry _object(String key) => ObjectEntry(
    key: key,
    name: key,
    size: 1,
    storageClass: 'STANDARD',
    modifiedAt: DateTime(2026),
    isFolder: false);

class _RecordingEngine extends MockEngineService {
  final uploads = <UploadTarget>[];
  final downloads = <List<String>>[];
  final deletes = <List<String>>[];

  TransferJob _job(String direction) => TransferJob(
      id: '$direction-${uploads.length + downloads.length}',
      label: direction,
      direction: direction,
      progress: 1,
      status: 'completed',
      bytesTransferred: 1,
      totalBytes: 1);

  @override
  Future<TransferJob> startUpload({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required List<String> filePaths,
    required Map<String, String> objectKeyByPath,
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
    Map<String, Object?>? clientEncryption,
    ObjectEncryption? encryption,
  }) async {
    uploads.add(UploadTarget(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        prefix: prefix,
        listAll: false));
    return _job('upload');
  }

  @override
  Future<TransferJob> startDownload({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
    required String destinationPath,
    String conflictPolicy = 'keepBoth',
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
    Map<String, Object?>? clientEncryption,
    ObjectEncryption? encryption,
  }) async {
    downloads.add(List.of(keys));
    return _job('download');
  }

  @override
  Future<BatchOperationResult> deleteObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
  }) async {
    deletes.add(List.of(keys));
    return BatchOperationResult(
        successCount: keys.length, failureCount: 0, failures: const []);
  }
}

class _ActionController extends AppController {
  _ActionController(_RecordingEngine engine)
      : super(
            engineService: engine,
            initialSettings: AppSettings.fromJson({
              'enableAnimations': false,
              'browserInspectorVisible': true,
              'browserInspectorSize': 550,
              'relistObjectsAfterMutation': false,
            }),
            initialProfiles: const [_profile]) {
    selectedProfile = _profile;
    selectedBucket = _bucket;
    buckets = const [_bucket];
    currentPrefix = 'original/';
    objects = [_object('inspected.bin'), _object('checked.bin')];
    selectedObject = objects.first;
  }

  final exports = <String>[];
  final preparedUploads = <UploadTarget?>[];
  final uploaded = Completer<void>();
  bool recordUploadOnly = false;

  @override
  Future<File?> exportProfilesToPath(String path) async {
    exports.add(path);
    return File(path);
  }

  @override
  Future<void> startSampleUpload(List<String> filePaths,
      {UploadTarget? target,
      Map<String, String> objectKeyByPath = const {}}) async {
    if (!recordUploadOnly) {
      return super.startSampleUpload(filePaths,
          target: target, objectKeyByPath: objectKeyByPath);
    }
    preparedUploads.add(target);
    if (!uploaded.isCompleted) uploaded.complete();
  }
}

class _Picker extends FilePicker {
  final files = Completer<FilePickerResult?>();
  final folder = Completer<String?>();
  String? savePath;
  int saves = 0;
  int picks = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) {
    picks++;
    return files.future;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) {
    picks++;
    return folder.future;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saves++;
    return savePath;
  }
}

void _navigate(_ActionController controller) {
  controller.selectedProfile =
      EndpointProfile.fromJson({..._profile.toJson(), 'id': 'other'});
  controller.selectedBucket = const BucketSummary(
      name: 'other',
      region: 'us-east-1',
      objectCountHint: 0,
      versioningEnabled: false);
  controller.currentPrefix = 'other/';
  controller.activeEngineId = 'go';
}

void _expectOriginal(UploadTarget? target) {
  expect(target, isNotNull);
  expect(target!.profile, same(_profile));
  expect(target.bucketName, 'original');
  expect(target.prefix, 'original/');
  expect(target.engineId, 'rust');
}

Future<void> _pumpWorkspace(WidgetTester tester, _ActionController controller,
    {bool settings = false}) async {
  tester.view.physicalSize = const Size(1800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => settings
                  ? SettingsWorkspace(controller: controller)
                  : BrowserWorkspace(
                      controller: controller, compact: false)))));
  await tester.pumpAndSettle();
}

void main() {
  late _RecordingEngine engine;
  late _ActionController controller;
  setUp(() {
    engine = _RecordingEngine();
    controller = _ActionController(engine);
  });
  tearDown(() => controller.dispose());

  for (final count in [1, 2]) {
    test('captured upload target survives preparation for $count files',
        () async {
      final dir = await Directory.systemTemp.createTemp('upload-target-');
      addTearDown(() => dir.delete(recursive: true));
      final paths = <String>[];
      for (var i = 0; i < count; i++) {
        final file = await File('${dir.path}/$i.bin').writeAsString('fixture');
        paths.add(file.path);
      }
      final target = controller.captureUploadTarget();
      _navigate(controller);
      await controller.startSampleUpload(paths, target: target);
      expect(engine.uploads, hasLength(count));
      for (final target in engine.uploads) {
        _expectOriginal(target);
      }
    });
  }

  test('default upload target is captured before single-file sizing', () async {
    final dir = await Directory.systemTemp.createTemp('upload-sizing-target-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/one.bin').writeAsString('fixture');
    final upload = controller.startSampleUpload([file.path]);
    _navigate(controller);
    await upload;
    _expectOriginal(engine.uploads.single);
  });

  for (final folder in [false, true]) {
    testWidgets('${folder ? 'folder' : 'file'} picker keeps initiation target',
        (tester) async {
      final picker = _Picker();
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      controller.recordUploadOnly = true;
      // With an object selected the toolbar shows selection actions instead.
      controller.selectedObject = null;
      await _pumpWorkspace(tester, controller);
      // Invoke the action directly: this narrow fixture layout places the
      // prefix field's shortcut hint over the button's centre.
      tester
          .widget<FilledButton>(find.ancestor(
              of: find.text('Upload'),
              // FilledButton.icon builds a private FilledButton subclass.
              matching: find.byWidgetPredicate((w) => w is FilledButton)))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
      await tester.tap(find.text(folder ? 'Upload folder' : 'Upload files'));
      await tester.pumpAndSettle();
      expect(picker.picks, 1);
      _navigate(controller);
      // The picker continuation lives in the test zone while directory
      // traversal needs real I/O, so alternate real time with frame pumps.
      final dir = await tester
          .runAsync(() => Directory.systemTemp.createTemp('picker-target-'));
      addTearDown(() => dir!.delete(recursive: true));
      if (folder) {
        await tester.runAsync(
            () => File('${dir!.path}/one.bin').writeAsString('fixture'));
        picker.folder.complete(dir!.path);
      } else {
        picker.files.complete(FilePickerResult([
          PlatformFile(name: 'one.bin', size: 1, path: '/fixture/one.bin')
        ]));
      }
      for (var i = 0; i < 100 && !controller.uploaded.isCompleted; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      expect(controller.uploaded.isCompleted, isTrue);
      _expectOriginal(controller.preparedUploads.single);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('dropped directory keeps target while traversal is pending',
      (tester) async {
    controller.recordUploadOnly = true;
    await _pumpWorkspace(tester, controller);
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('drop-target-');
      try {
        await File('${dir.path}/one.bin').writeAsString('fixture');
        tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
            DropDoneDetails(
                files: [DropItemDirectory(dir.path, [])],
                localPosition: Offset.zero,
                globalPosition: Offset.zero));
        _navigate(controller);
        await controller.uploaded.future;
      } finally {
        await dir.delete(recursive: true);
      }
    });
    _expectOriginal(controller.preparedUploads.single);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelled desktop profile export does not dispatch a write',
      (tester) async {
    final picker = _Picker();
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = FilePickerIO());
    await _pumpWorkspace(tester, controller, settings: true);
    await tester.tap(find.text('Export profiles'));
    await tester.pumpAndSettle();
    expect(picker.saves, 1);
    expect(controller.exports, isEmpty);
    picker.savePath = '/chosen/profiles.json';
    await tester.tap(find.text('Export profiles'));
    await tester.pumpAndSettle();
    expect(controller.exports, ['/chosen/profiles.json']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'inspector current actions ignore checked keys and confirm delete',
      (tester) async {
    controller.toggleObjectSelection(controller.objects.last);
    controller.inspectorTab = BrowserInspectorTab.versions;
    await _pumpWorkspace(tester, controller);
    final download = find.text('Download current object');
    await tester.ensureVisible(download);
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(engine.downloads, [
      ['inspected.bin']
    ]);

    final delete = find.text('Delete current object');
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 object(s)?'), findsOneWidget);
    expect(engine.deletes, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.deletes, isEmpty);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete 1 object(s)'));
    await tester.pumpAndSettle();
    expect(engine.deletes, [
      ['inspected.bin']
    ]);
    expect(controller.objectSelection.keys, contains('checked.bin'));
    await tester.pumpWidget(const SizedBox());
  });

  test('default download and delete actions retain batch selection behavior',
      () async {
    controller.toggleObjectSelection(controller.objects.last);
    await controller.startSampleDownload();
    await controller.deleteSelectedObject();
    expect(engine.downloads, [
      ['checked.bin']
    ]);
    expect(engine.deletes, [
      ['checked.bin']
    ]);
    expect(controller.objects.map((o) => o.key), contains('inspected.bin'));
  });
}
