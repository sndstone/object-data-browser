import 'package:s3_browser_crossplat/controllers/transfer_presentation.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/controllers/action_scope.dart';
import 'package:s3_browser_crossplat/benchmark/benchmark_metrics.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/listing_cancellation.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/settings_sections.dart';

class Repository implements AppStateRepository {
  bool fail = false;
  int writes = 0;
  List<EndpointProfile> profiles = [];
  @override
  Future<void> saveState(
      {required AppSettings settings,
      required List<EndpointProfile> profiles,
      required String? selectedProfileId,
      bool allowCredentialStoreRecovery = false}) async {
    writes++;
    if (fail) throw const FileSystemException('Fixture write failure');
    this.profiles = List.of(profiles);
  }

  @override
  Future<StoredAppState?> loadState() async => null;
  @override
  Future<List<EndpointProfile>> importProfiles(String path) async => [];
  @override
  Future<File> exportProfiles(
          {required List<EndpointProfile> profiles,
          required String path}) async =>
      File(path);
}

class TestingEngine extends MockEngineService {
  EndpointProfile? tested;
  Completer<void>? holdTest;
  @override
  Future<void> testProfile(
      {required String engineId, required EndpointProfile profile}) async {
    tested = profile;
    if (holdTest != null) await holdTest!.future;
  }
}

const profile = EndpointProfile(
    id: 'a',
    name: 'A',
    endpointUrl: 'http://localhost:9000',
    region: 'us-east-1',
    accessKey: 'fixture',
    secretKey: 'original',
    pathStyle: true,
    verifyTls: false);
AppController controller(TestingEngine engine, Repository repository) =>
    AppController(
        engineService: engine,
        appStateRepository: repository,
        initialSettings: AppSettings.fromJson({'defaultEngineId': 'python'}),
        initialProfiles: const [profile]);

void main() {
  test('testing a draft never saves or changes browsing selection', () async {
    final repo = Repository();
    final engine = TestingEngine();
    final c = controller(engine, repo);
    addTearDown(c.dispose);
    await c.initialize();
    final selected = c.selectedProfile;
    final bucket = c.selectedBucket;
    final writes = repo.writes;
    await c
        .testProfileDraft(profile.copyWith(secretKey: 'draft', name: 'Draft'));
    expect(engine.tested?.secretKey, 'draft');
    expect(repo.writes, writes);
    expect(c.selectedProfile, selected);
    expect(c.selectedBucket, bucket);
    expect(c.profiles.single.secretKey, 'original');
  });
  test('unsaved activation is never persisted by a later settings write',
      () async {
    final repo = Repository();
    final c = controller(TestingEngine(), repo);
    addTearDown(c.dispose);
    c.updateProfile(profile.copyWith(secretKey: 'draft'));
    await c.setSelectedProfileById(profile.id);
    await c.updateSettings(c.settings.copyWith(darkMode: true));
    expect(repo.profiles.single.secretKey, 'original');
    expect(c.profilePersistenceStatusFor(profile.id), 'Session only');
    expect(await c.saveProfile(c.profiles.single), isTrue);
    expect(repo.profiles.single.secretKey, 'draft');
    expect(c.profilePersistenceStatusFor(profile.id), 'Saved');
  });
  test('failed settings save is visible and retry clears the warning',
      () async {
    final repo = Repository()..fail = true;
    final c = controller(TestingEngine(), repo);
    addTearDown(c.dispose);
    await c.updateSettings(c.settings.copyWith(darkMode: true));
    expect(c.persistenceState.warning, contains('session'));
    repo.fail = false;
    await c.retrySaveSettings();
    expect(c.persistenceState.warning, isNull);
  });
  test('successful draft test cannot turn a failed save into saved credentials',
      () async {
    final repo = Repository()..fail = true;
    final c = controller(TestingEngine(), repo);
    addTearDown(c.dispose);
    expect(await c.saveProfile(profile.copyWith(secretKey: 'draft')), isFalse);
    await c.testProfileDraft(c.profiles.single);
    expect(c.profilePersistenceStatusFor(profile.id), 'Session only');
    expect(c.persistenceState.warning, isNotNull);
  });
  test('cancel stops a hung connection test and late completion has no effect',
      () async {
    final engine = TestingEngine()..holdTest = Completer<void>();
    final c = controller(engine, Repository());
    addTearDown(c.dispose);
    final pending = c.testProfileDraft(profile);
    await Future<void>.delayed(Duration.zero);
    final task =
        c.browserTasks.firstWhere((task) => task.actionKey == 'test-profile-a');
    await c.cancelTask(task);
    await pending.timeout(const Duration(seconds: 1));
    expect(
        c.browserTasks.firstWhere((t) => t.id == task.id).status, 'cancelled');
    final message = c.bannerMessage;
    engine.holdTest!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(c.bannerMessage, message);
  });
  test('action scopes do not cancel unrelated requests', () async {
    final a = ActionScope();
    final b = ActionScope();
    final first = a.run(() => a.wait(Completer<int>().future));
    final secondReply = Completer<int>();
    final second = b.run(() => b.wait(secondReply.future));
    final assertion = expectLater(first, throwsA(isA<ListingCancelled>()));
    a.cancel();
    await assertion;
    secondReply.complete(42);
    expect(await second, 42);
  });
  test('missing measurements stay unavailable while measured zero remains zero',
      () {
    expect(formatMeasuredMetric(null), 'Unavailable');
    expect(formatMeasuredMetric(0), '0.0');
    expect(formatMeasuredCount(null), 'Unavailable');
    expect(formatMeasuredCount(0), '0');
    expect(sizeLatencyField('p99'), 'p99LatencyMs');
  });
  test('production run without summary never invents benchmark measurements',
      () {
    final c = controller(TestingEngine(), Repository());
    addTearDown(c.dispose);
    final run = BenchmarkRun(
        id: 'real',
        config: c.benchmarkDraft,
        status: 'completed',
        processedCount: 100,
        startedAt: DateTime(2026),
        averageLatencyMs: 10,
        throughputOpsPerSecond: 25,
        liveLog: const []);
    expect(c.benchmarkSummaryForRun(run), isNull);
    expect(c.benchmarkOperationsForRun(run), isEmpty);
  });
  test(
      'control acknowledgement preserves counters and late progress cannot undo cancellation',
      () {
    const current = TransferJob(
        id: 'job',
        label: 'Download',
        direction: 'download',
        progress: .5,
        status: 'running',
        bytesTransferred: 50,
        totalBytes: 100);
    final ack = mergeTransferControl(
        current, current.copyWith(status: 'cancelling', bytesTransferred: 0));
    expect(ack.bytesTransferred, 50);
    expect(preserveTransferCancellation(ack, current).status, 'cancelling');
    final stopped = ack.copyWith(status: 'cancelled');
    expect(
        preserveTransferCancellation(
                stopped, current.copyWith(status: 'completed'))
            .status,
        'cancelled');
  });
  test('settings have six groups and preserve old deep links', () {
    expect(settingsSections.length, 6);
    expect(canonicalSettingsSection('General'), 'Connections');
    expect(canonicalSettingsSection('Downloads & Temp Storage'),
        'Transfers & Storage');
    expect(canonicalSettingsSection('Version Details'), 'About & Diagnostics');
  });
}
