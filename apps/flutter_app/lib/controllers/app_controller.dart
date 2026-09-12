import 'transfer_presentation.dart';
import 'action_scope.dart';
import 'persistence_state.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/domain_models.dart';
import '../services/app_state_repository.dart';
import '../services/app_platform.dart';
import '../services/engine_service.dart';
import '../services/multipart_sizing.dart';
import '../services/source_preview.dart';
import '../services/listing_cancellation.dart';
import 'object_selection.dart';
import 'object_query.dart';
import 'upload_batch.dart';
import '../services/diagnostic_safety.dart';

const List<String> kAwsRegions = <String>[
  'us-east-1',
  'us-east-2',
  'us-west-1',
  'us-west-2',
  'ca-central-1',
  'sa-east-1',
  'eu-west-1',
  'eu-west-2',
  'eu-west-3',
  'eu-central-1',
  'eu-central-2',
  'eu-north-1',
  'eu-south-1',
  'eu-south-2',
  'me-south-1',
  'me-central-1',
  'af-south-1',
  'ap-south-1',
  'ap-south-2',
  'ap-southeast-1',
  'ap-southeast-2',
  'ap-southeast-3',
  'ap-southeast-4',
  'ap-northeast-1',
  'ap-northeast-2',
  'ap-northeast-3',
];

String normalizeEndpointUrl(
  String rawValue, {
  required bool preferHttps,
}) {
  final trimmed = rawValue.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  final hasScheme =
      trimmed.startsWith('http://') || trimmed.startsWith('https://');
  final candidate =
      hasScheme ? trimmed : '${preferHttps ? 'https' : 'http'}://$trimmed';
  final uri = Uri.tryParse(candidate);
  if (uri == null) {
    return candidate;
  }

  final normalized = uri.toString();
  if ((uri.path.isEmpty || uri.path == '/') &&
      normalized.endsWith('/') &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty) {
    return normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

bool endpointUsesHttps(
  String rawValue, {
  required bool fallback,
}) {
  final trimmed = rawValue.trim();
  if (trimmed.startsWith('https://')) {
    return true;
  }
  if (trimmed.startsWith('http://')) {
    return false;
  }
  return fallback;
}

String awsEndpointForRegion(String region) {
  final normalizedRegion = region.trim().isEmpty ? 'us-east-1' : region.trim();
  if (normalizedRegion == 'us-east-1') {
    return 'https://s3.amazonaws.com';
  }
  return 'https://s3.$normalizedRegion.amazonaws.com';
}

String azureEndpointForAccount(String accountName) {
  final trimmed = accountName.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  return 'https://$trimmed.blob.core.windows.net';
}

EndpointProfile normalizeEndpointProfile(EndpointProfile profile) {
  if (profile.endpointType == EndpointProfileType.azureBlob) {
    // accessKey carries the storage account name; an empty endpoint URL means
    // the engine derives https://<account>.blob.core.windows.net. A custom
    // endpoint (Azurite, sovereign clouds) is normalized like any other URL.
    final customEndpoint = profile.endpointUrl.trim();
    final usesHttps = customEndpoint.isEmpty ||
        endpointUsesHttps(customEndpoint, fallback: true);
    return profile.copyWith(
      endpointUrl: customEndpoint.isEmpty
          ? ''
          : normalizeEndpointUrl(customEndpoint, preferHttps: true),
      region: profile.region.trim(),
      pathStyle: false,
      verifyTls: usesHttps ? profile.verifyTls : false,
    );
  }
  final normalizedRegion = profile.endpointType == EndpointProfileType.awsS3
      ? (profile.region.trim().isEmpty ? 'us-east-1' : profile.region.trim())
      : profile.region.trim();
  final usesHttps = profile.endpointType == EndpointProfileType.awsS3
      ? true
      : endpointUsesHttps(
          profile.endpointUrl,
          fallback: profile.verifyTls,
        );
  final normalizedEndpoint = profile.endpointType == EndpointProfileType.awsS3
      ? awsEndpointForRegion(normalizedRegion)
      : normalizeEndpointUrl(
          profile.endpointUrl,
          preferHttps: usesHttps,
        );

  return profile.copyWith(
    endpointUrl: normalizedEndpoint,
    region: normalizedRegion,
    endpointType: profile.endpointType,
    pathStyle: profile.endpointType == EndpointProfileType.awsS3
        ? false
        : profile.pathStyle,
    verifyTls: profile.endpointType == EndpointProfileType.awsS3
        ? true
        : (usesHttps ? profile.verifyTls : false),
  );
}

class _PendingObjectRelist {
  const _PendingObjectRelist({
    required this.profileId,
    required this.bucketName,
    required this.prefix,
    required this.listAll,
  });

  final String profileId;
  final String bucketName;
  final String prefix;
  final bool listAll;
}

class _TextPreviewResult {
  const _TextPreviewResult({
    required this.text,
    required this.truncated,
    required this.loadedBytes,
  });

  final String text;
  final bool truncated;
  final int loadedBytes;
}

class AppController extends ChangeNotifier {
  AppController({
    required EngineService engineService,
    required AppSettings initialSettings,
    required List<EndpointProfile> initialProfiles,
    String? initialSelectedProfileId,
    String? initialCredentialStoreError,
    AppStateRepository? appStateRepository,
  })  : _engineService = engineService,
        _initialSelectedProfileId = initialSelectedProfileId,
        _credentialStoreError = initialCredentialStoreError,
        _appStateRepository = appStateRepository,
        settings = initialSettings,
        profiles = initialProfiles.map(normalizeEndpointProfile).toList() {
    _persistedProfiles
        .addEntries(profiles.map((profile) => MapEntry(profile.id, profile)));
    final bootstrapProfileId = profiles.isEmpty ? '' : profiles.first.id;
    testDataConfig = TestDataToolConfig(
      bucketName: '',
      endpointUrl: profiles.isEmpty ? '' : profiles.first.endpointUrl,
      accessKey: '',
      secretKey: '',
      objectSizeBytes: 1024 * 1024,
      versions: 3,
      objectCount: 100,
      prefix: 'seed/',
      threads: 8,
      checksumAlgorithm: 'crc32c',
    );
    deleteAllConfig = DeleteAllToolConfig(
      bucketName: '',
      endpointUrl: profiles.isEmpty ? '' : profiles.first.endpointUrl,
      accessKey: '',
      secretKey: '',
      checksumAlgorithm: 'crc32c',
      batchSize: 1000,
      maxWorkers: 32,
      maxRetries: 5,
      retryMode: 'adaptive',
      maxRequestsPerSecond: 0,
      maxConnections: 200,
      pipelineSize: 16,
      listMaxKeys: 1000,
      deletionDelayMs: 0,
      immediateDeletion: true,
    );
    benchmarkDraft = BenchmarkConfig(
      profileId: bootstrapProfileId,
      engineId: initialSettings.defaultEngineId,
      bucketName: '',
      prefix: '',
      workloadType: 'mixed',
      deleteMode: 'multi-object-post',
      objectSizes: const [65536, 1048576, 8388608],
      concurrentThreads: initialSettings.transferConcurrency,
      testMode: 'duration',
      operationCount: 50000,
      durationSeconds: 60,
      validateChecksum: false,
      checksumAlgorithm: 'crc32c',
      randomData: true,
      inMemoryData: true,
      objectCount: 4096,
      connectTimeoutSeconds: initialSettings.connectTimeoutSeconds,
      readTimeoutSeconds: initialSettings.readTimeoutSeconds,
      maxAttempts: math.max(1, initialSettings.safeRetries - 1),
      maxPoolConnections: math.max(initialSettings.maxPoolConnections * 2, 512),
      dataCacheMb: initialSettings.benchmarkDataCacheMb,
      csvOutputPath: '${initialSettings.tempPath}/benchmark-results.csv',
      jsonOutputPath: '${initialSettings.tempPath}/benchmark-results.json',
      logFilePath: initialSettings.benchmarkLogPath,
      debugMode: initialSettings.benchmarkDebugMode,
      reducedLogging: true,
    );
    if (engineService is TransferJobSinkRegistrant) {
      (engineService as TransferJobSinkRegistrant)
          .setTransferSink(_handleTransferJobUpdate);
    }
    bannerMessage = _credentialStoreError;
    bannerSeverity = BannerSeverity.error;
    _syncDiagnosticsOptions();
  }

  final EngineService _engineService;
  final String? _initialSelectedProfileId;
  final AppStateRepository? _appStateRepository;
  String? _credentialStoreError;
  bool _lastProfileSaveSucceeded = true;
  final persistenceState = PersistenceState();
  final Map<String, EndpointProfile> _persistedProfiles = {};
  final Map<String, ActionScope> _actionScopes = {};
  final Map<String, String> _jobEngineOwners = {};
  String profilePersistenceStatusFor(String id) =>
      _credentialStoreError != null ||
              persistenceState.profileSaved(id) == false
          ? 'Session only'
          : 'Saved';
  Future<void> retrySaveSettings() async {
    await _persistState();
    notifyListeners();
  }

  String get profilePersistenceStatus =>
      _credentialStoreError == null && _lastProfileSaveSucceeded
          ? 'Saved'
          : 'Session only';
  int _taskSequence = 0;
  int _guardErrorSequence = 0;
  final Map<String, String> _busyTaskIds = <String, String>{};
  bool _benchmarkPollInFlight = false;
  bool _benchmarkLifecycleActionInFlight = false;
  bool _initializeStarted = false;
  bool _engineLogSinkAttached = false;
  // Monotonic token controlling listing-loop cancellation. Each listing loop
  // captures the current value at start; a mismatch means the loop was
  // superseded or cancelled and must stop. Using a generation (rather than a
  // shared bool) ensures a cancellation of run A can never be undone by run B.
  int _listingGeneration = 0;
  // Cosmetic flag reflecting whether the most recent listing run stopped due to
  // cancellation; drives the task summary only, not loop control.
  bool _listingCancelledState = false;
  bool get _listingCancelled =>
      ActionScope.current?.listingCancelled ?? _listingCancelledState;
  set _listingCancelled(bool value) {
    final scope = ActionScope.current;
    if (scope == null) {
      _listingCancelledState = value;
    } else {
      scope.listingCancelled = value;
    }
  }

  bool _benchmarkPollErrorReported = false;
  int _previewRequestSequence = 0;
  final Map<String, _PendingObjectRelist> _pendingUploadRelists =
      <String, _PendingObjectRelist>{};

  WorkspaceTab activeTab = WorkspaceTab.browser;
  BrowserInspectorTab inspectorTab = BrowserInspectorTab.bucketInfo;
  AppSettings settings;
  List<EndpointProfile> profiles;
  List<EngineDescriptor> engines = const [];
  List<BucketSummary> buckets = const [];
  List<ObjectEntry> objects = const [];
  List<ObjectVersionEntry> versions = const [];
  ListCursor objectCursor = const ListCursor(value: null, hasMore: false);
  ListCursor versionCursor = const ListCursor(value: null, hasMore: false);
  List<CapabilityDescriptor> capabilities = const [];
  List<TransferJob> transferJobs = const [];
  List<BrowserTaskRecord> browserTasks = const [];
  List<BenchmarkRun> benchmarkHistory = const [];
  List<EventLogEntry> eventLog = const [];
  final Set<String> _busyActions = <String>{};
  BucketAdminState? adminState;
  ObjectDetails? selectedObjectDetails;
  ObjectPreview? selectedObjectPreview;
  BenchmarkRun? benchmarkRun;
  EndpointProfile? selectedProfile;
  BucketSummary? selectedBucket;
  ObjectEntry? selectedObject;
  final ObjectSelection objectSelection = ObjectSelection();
  String? objectFilterError;
  static const int objectListingBudget = 100000;
  bool listingBudgetReached = false;
  void toggleObjectSelection(ObjectEntry object, {bool range = false}) {
    objectSelection.toggle(object, visibleObjects, range: range);
    notifyListeners();
  }

  void selectAllLoadedObjects() {
    objectSelection.selectAll(visibleObjects);
    notifyListeners();
  }

  void clearObjectSelection() {
    objectSelection.clear();
    notifyListeners();
  }

  String activeEngineId = 'rust';
  String currentPrefix = '';
  String objectFilterValue = '';
  BrowserFilterMode objectFilterMode = BrowserFilterMode.prefix;
  BrowserObjectSortField objectSortField = BrowserObjectSortField.lastModified;
  bool objectSortDescending = true;
  bool flatView = false;
  static const int objectPageSize = 1000;
  static const int eventLogLimit = 5000;
  static const int _taskOutputLineLimit = 500;
  static const int objectPreviewTextByteLimit = 64 * 1024;
  static const int objectPreviewImageMaxBytes = 20 * 1024 * 1024;

  Timer? _busyLineNotifyTimer;
  int objectPage = 1;
  bool showAllObjects = false;
  bool listAllKeys = false;
  bool loading = false;
  String? _bannerMessage;
  String? get bannerMessage => _bannerMessage;
  set bannerMessage(String? value) {
    _bannerMessage = value;
    bannerSeverity = BannerSeverity.info;
  }

  BannerSeverity bannerSeverity = BannerSeverity.info;
  String? pendingEventLogFilter;
  String settingsSectionName = 'Connections';
  void openConnectionSettings() {
    settingsSectionName = 'Connections';
    selectTab(WorkspaceTab.settings);
  }

  void setSettingsSection(String section) {
    settingsSectionName = section;
    notifyListeners();
  }

  final objectSearchFocus = ValueNotifier<int>(0);
  final inspectorToggleRequest = ValueNotifier<int>(0);
  final deleteSelectionRequest = ValueNotifier<int>(0);
  bool pendingInspectorToggle = false;
  void requestInspectorToggle() {
    pendingInspectorToggle = true;
    selectTab(WorkspaceTab.browser);
    inspectorToggleRequest.value++;
  }

  void requestDeleteSelection() {
    if (activeTab == WorkspaceTab.browser) deleteSelectionRequest.value++;
  }

  bool pendingObjectSearchFocus = false;
  void requestObjectSearchFocus() {
    pendingObjectSearchFocus = true;
    selectTab(WorkspaceTab.browser);
    objectSearchFocus.value++;
  }

  void openErrorDetails() {
    pendingEventLogFilter = 'ERROR';
    selectTab(WorkspaceTab.eventLog);
  }

  String? bannerTaskId;
  VersionBrowserOptions versionBrowserOptions = const VersionBrowserOptions();
  late TestDataToolConfig testDataConfig;
  late DeleteAllToolConfig deleteAllConfig;
  late BenchmarkConfig benchmarkDraft;
  ToolExecutionState putTestDataState = const ToolExecutionState(
    label: 'put-testdata',
    running: false,
    lastStatus: 'Idle',
  );
  ToolExecutionState deleteAllState = const ToolExecutionState(
    label: 'delete-all',
    running: false,
    lastStatus: 'Idle',
  );
  String? selectedBenchmarkRunId;
  String? selectedTaskId;
  BrowserTaskView taskView = BrowserTaskView.running;

  bool isBusy(String actionKey) => _busyActions.contains(actionKey);

  bool get hasBusyActions => _busyActions.isNotEmpty;

  final Set<ListingCancellation> _listingRequests = {};

  /// Stop waiting for stalled reads immediately; late responses cannot update
  /// the browser. Desktop additionally terminates only listing-owned workers.
  void cancelListing() {
    _listingGeneration++;
    _listingCancelled = true;
    for (final cancellation in _listingRequests.toList()) {
      cancellation.cancel();
    }
    if (_engineService is ListingCancellationRegistrant) {
      (_engineService as ListingCancellationRegistrant).cancelListings();
    }
    _markListingTasksCancelling();
    notifyListeners();
  }

  Future<T> _awaitListing<T>(Future<T> Function() request) async {
    final cancellation = ActionScope.current ?? ListingCancellation();
    _listingRequests.add(cancellation);
    try {
      return await cancellation.wait(request());
    } finally {
      _listingRequests.remove(cancellation);
    }
  }

  void _showListingCancelled() {
    bannerMessage = 'Listing cancelled. Keeping the results already loaded.';
    bannerSeverity = BannerSeverity.info;
  }

  Future<void> initialize() async {
    if (_initializeStarted) {
      return;
    }
    _initializeStarted = true;
    loading = true;
    notifyListeners();
    try {
      _attachEngineLogSink();
      _syncDiagnosticsOptions();
      _addEvent(
        level: 'INFO',
        category: 'App',
        message: 'Initializing application controller.',
        source: 'app',
      );
      engines = await _engineService.listEngines();
      selectedProfile = _selectBootstrapProfile();
      final preferredEngineId = settings.defaultEngineId;
      final preferredEngineAvailable = engines.any(
        (engine) => engine.id == preferredEngineId && engine.available,
      );
      final availableEngines = engines.where((engine) => engine.available);
      activeEngineId = preferredEngineAvailable
          ? preferredEngineId
          : availableEngines.isNotEmpty
              ? availableEngines.first.id
              : preferredEngineId;
      benchmarkDraft = benchmarkDraft.copyWith(engineId: activeEngineId);
      _addEvent(
        level: 'INFO',
        category: 'Engine',
        message:
            'Loaded ${engines.length} engine descriptor(s). Active engine is $activeEngineId.',
        source: 'engine',
      );
      if (_engineService.isMock) {
        _addEvent(
          level: 'WARN',
          category: 'Engine',
          message:
              'The app is currently using the mock engine service. Real S3 bucket and object operations are not wired yet, so button actions only trace local app behavior.',
          source: 'engine',
        );
      }
      if (_credentialStoreError != null) {
        bannerMessage = _credentialStoreError;
        bannerSeverity = BannerSeverity.error;
        _addEvent(
          level: 'ERROR',
          category: 'Persistence',
          message: _credentialStoreError!,
          source: 'keychain',
        );
      } else if (selectedProfile != null) {
        await refreshBuckets();
        await refreshCapabilities();
      } else {
        _addEvent(
          level: 'INFO',
          category: 'Profiles',
          message: 'No endpoint profiles configured at startup.',
          source: 'profiles',
        );
      }
    } catch (error) {
      bannerMessage = 'Initialization failed: $error';
      bannerSeverity = BannerSeverity.error;
      _addEvent(
        level: 'ERROR',
        category: 'App',
        message: 'Initialization failed: $error',
        source: 'app',
      );
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void _syncDiagnosticsOptions() {
    _engineService.configureDiagnostics(
      DiagnosticsOptions(
        enableApiLogging: settings.enableApiLogging,
        enableDebugLogging: settings.enableDebugLogging,
      ),
    );
  }

  void selectTab(WorkspaceTab tab) {
    activeTab = tab;
    _addEvent(
      level: 'INFO',
      category: 'Navigation',
      message: 'Switched workspace to ${tab.name}.',
      source: 'navigation',
    );
    notifyListeners();
  }

  final Map<InspectorGroup, BrowserInspectorTab> inspectorGroupTabs = {};
  void clearSelectedObject() {
    selectedObject = null;
    selectedObjectDetails = null;
    selectedObjectPreview = null;
    objectSelection.clear();
    setInspectorTab(BrowserInspectorTab.bucketInfo);
  }

  void setInspectorTab(BrowserInspectorTab tab) {
    inspectorGroupTabs[tab.group] = tab;
    inspectorTab = tab;
    notifyListeners();
  }

  Future<void> setEngine(String engineId) async {
    final shouldRefreshBrowserData = activeTab == WorkspaceTab.browser;
    await _runBusy(
      'set-engine',
      'Switching backend engine to ${_engineLabel(engineId)}...',
      () async {
        activeEngineId = engineId;
        benchmarkDraft = benchmarkDraft.copyWith(engineId: engineId);
        bannerMessage = 'Using ${_engineLabel(engineId)}.';
        _addEvent(
          level: 'INFO',
          category: 'Engine',
          message: 'Selected engine $engineId.',
          source: 'engine',
        );
        if (shouldRefreshBrowserData) {
          await refreshCapabilities();
        }
        if (shouldRefreshBrowserData && selectedProfile != null) {
          await refreshBuckets();
        }
        await _persistState();
        notifyListeners();
      },
    );
  }

  Future<void> setSelectedProfileById(String profileId) async {
    final profile = profiles.firstWhere((item) => item.id == profileId);
    await _runBusy(
      'select-profile',
      'Switching to endpoint profile ${profile.name}...',
      () async {
        selectedProfile = profile;
        currentPrefix = '';
        _syncObjectFilterWithPrefix();
        _addEvent(
          level: 'INFO',
          category: 'Profiles',
          message: 'Selected endpoint profile ${profile.name}.',
          source: 'profiles',
        );
        await refreshCapabilities();
        await refreshBuckets();
      },
    );
  }

  Future<void> testSelectedProfile() async {
    final profile = selectedProfile;
    if (profile == null) {
      _addEvent(
        level: 'WARN',
        category: 'Profiles',
        message: 'Profile test requested without a selected profile.',
        source: 'profiles',
      );
      return;
    }
    await testProfileById(profile.id);
  }

  Future<void> refreshCapabilities() async {
    final profile = selectedProfile;
    if (profile == null) {
      return;
    }
    capabilities = await _engineService.getCapabilities(
      engineId: activeEngineId,
      profile: profile,
    );
    _addEvent(
      level: 'INFO',
      category: 'Capabilities',
      message:
          'Loaded ${capabilities.length} capability descriptor(s) for ${profile.name} via $activeEngineId.',
      source: 'bucket-capabilities',
    );
    notifyListeners();
  }

  Future<void> refreshBuckets() async {
    final profile = selectedProfile;
    if (profile == null) {
      return;
    }
    await _runBusy('refresh-buckets', 'Listing buckets for ${profile.name}...',
        () async {
      await _guard('Buckets', () async {
        _listingCancelled = false;
        final listingGeneration = ++_listingGeneration;
        final previousBucketName = selectedBucket?.name;
        _addEvent(
          level: 'INFO',
          category: 'Buckets',
          message:
              'Listing buckets for profile ${profile.name} on ${profile.endpointUrl} with engine $activeEngineId.',
          profileId: profile.id,
          source: 'bucket-browser',
        );
        if (listingGeneration != _listingGeneration) {
          _listingCancelled = true;
          return;
        }
        final listedBuckets =
            await _awaitListing(() => _engineService.listBuckets(
                  engineId: activeEngineId,
                  profile: profile,
                ));
        if (listingGeneration != _listingGeneration) {
          _listingCancelled = true;
          _appendBusyTaskLine(
            'refresh-buckets',
            'Bucket listing cancelled. Late results were ignored.',
          );
          return;
        }
        buckets = listedBuckets;
        selectedBucket = previousBucketName == null
            ? (buckets.isEmpty ? null : buckets.first)
            : (_bucketByName(previousBucketName) ??
                (buckets.isEmpty ? null : buckets.first));
        adminState = null;
        benchmarkDraft = benchmarkDraft.copyWith(
          profileId: profile.id,
          engineId: activeEngineId,
          bucketName: selectedBucket?.name ?? '',
        );
        testDataConfig = testDataConfig.copyWith(
          endpointUrl: profile.endpointUrl,
          accessKey: profile.accessKey,
          secretKey: profile.secretKey,
          bucketName: selectedBucket?.name ?? '',
        );
        deleteAllConfig = deleteAllConfig.copyWith(
          endpointUrl: profile.endpointUrl,
          accessKey: profile.accessKey,
          secretKey: profile.secretKey,
          bucketName: selectedBucket?.name ?? '',
        );
        if (buckets.isEmpty) {
          _addEvent(
            level: 'WARN',
            category: 'Buckets',
            message:
                'Bucket list returned 0 entries. Verify the endpoint, credentials, and backend engine if you expected buckets.',
            profileId: profile.id,
            source: 'bucket-browser',
          );
        } else {
          _addEvent(
            level: 'INFO',
            category: 'Buckets',
            message: 'Bucket list returned ${buckets.length} bucket(s).',
            profileId: profile.id,
            source: 'bucket-browser',
          );
        }
        await refreshObjects(prefix: currentPrefix);
        if (!_listingCancelled) {
          await refreshBucketAdminState(cancellableListing: true);
        }
      });
    });
  }

  Future<void> refreshObjects({String? prefix, bool listAll = false}) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    if (profile == null || bucket == null) {
      objects = const [];
      versions = const [];
      versionCursor = const ListCursor(value: null, hasMore: false);
      objectCursor = const ListCursor(value: null, hasMore: false);
      listAllKeys = false;
      selectedObject = null;
      selectedObjectDetails = null;
      selectedObjectPreview = null;
      notifyListeners();
      return;
    }
    final previousPrefix = currentPrefix;
    final nextPrefix = prefix ?? currentPrefix;
    if (nextPrefix != currentPrefix) objectSelection.clear();
    final previousSelectionKey = selectedObject?.key;
    await _runBusy(
        'refresh-objects',
        listAll
            ? 'Listing all objects for ${bucket.name}${nextPrefix.isEmpty ? '' : ' at $nextPrefix'}...'
            : 'Listing up to $objectPageSize objects for ${bucket.name}${nextPrefix.isEmpty ? '' : ' at $nextPrefix'}...',
        () async {
      await _guard('Objects', () async {
        currentPrefix = nextPrefix;
        listAllKeys = listAll;
        _syncObjectFilterWithPrefix();
        _addEvent(
          level: 'INFO',
          category: 'Objects',
          message:
              '${listAll ? 'Listing all objects' : 'Listing the first $objectPageSize objects'} for bucket ${bucket.name} with prefix "$currentPrefix" using $activeEngineId.',
          includeSelectionContext: true,
          objectKey: previousSelectionKey,
          source: 'object-browser',
        );
        final page = await _pageThroughObjects(
          profile: profile,
          bucket: bucket,
          initialItems: <ObjectEntry>[],
          initialCursor: const ListCursor(value: null, hasMore: false),
          initialPageNumber: 0,
          listAll: listAll,
          fetchFirstPageWithoutCursor: true,
        );
        if (selectedProfile?.id != profile.id ||
            selectedBucket?.name != bucket.name ||
            currentPrefix != nextPrefix) {
          return;
        }
        if (_listingCancelled &&
            page.pageNumber == 0 &&
            previousPrefix == nextPrefix) {
          _showListingCancelled();
          return;
        }
        objects = page.items;
        objectSelection.retain(objects.map((o) => o.key));
        objectCursor = page.cursor;
        final pageNumber = page.pageNumber;
        _resetObjectPagination();
        selectedObject = previousSelectionKey == null
            ? null
            : _objectByKey(previousSelectionKey);
        if (_listingCancelled) {
          _showListingCancelled();
          return;
        }
        if (objects.isEmpty) {
          bannerMessage = 'No objects found in ${bucket.name}.';
          _addEvent(
            level: 'INFO',
            category: 'Objects',
            message: 'Object listing returned 0 entries for ${bucket.name}.',
            includeSelectionContext: true,
            source: 'object-browser',
          );
        } else {
          bannerMessage = objectCursor.hasMore
              ? 'Listed first ${objects.length} objects in ${bucket.name}.'
              : 'Listed ${objects.length} objects in ${bucket.name}.';
          _addEvent(
            level: 'INFO',
            category: 'Objects',
            message: objectCursor.hasMore
                ? 'Object listing returned the first ${objects.length} items across $pageNumber page(s); more pages are available.'
                : 'Object listing returned ${objects.length} items across $pageNumber page(s).',
            includeSelectionContext: true,
            source: 'object-browser',
          );
        }
        await _loadSelectionArtifacts(cancellableListing: true);
      });
    });
  }

  Future<void> listAllObjectsForCurrentBucket(
      {bool all = true, bool nextWindow = false}) async {
    final operationPrefix = currentPrefix;
    final profile = selectedProfile;
    final bucket = selectedBucket;
    if (profile == null || bucket == null) {
      return;
    }
    if (!objectCursor.hasMore) {
      listAllKeys = true;
      notifyListeners();
      return;
    }
    final previousSelectionKey = selectedObject?.key;
    await _runBusy(
      'refresh-objects',
      'Listing all objects for ${bucket.name}${currentPrefix.isEmpty ? '' : ' at $currentPrefix'}...',
      () async {
        await _guard('Objects', () async {
          listAllKeys = true;
          final page = await _pageThroughObjects(
            profile: profile,
            bucket: bucket,
            initialItems: nextWindow ? <ObjectEntry>[] : objects.toList(),
            initialCursor: objectCursor,
            initialPageNumber: (objects.length / objectPageSize).ceil(),
            listAll: all,
            fetchFirstPageWithoutCursor: false,
          );
          if (selectedProfile?.id != profile.id ||
              selectedBucket?.name != bucket.name ||
              currentPrefix != operationPrefix) {
            return;
          }
          objects = page.items;
          objectSelection.retain(objects.map((o) => o.key));
          objectCursor = page.cursor;
          final cursor = page.cursor;
          final pageNumber = page.pageNumber;
          _resetObjectPagination();
          selectedObject = previousSelectionKey == null
              ? null
              : _objectByKey(previousSelectionKey);
          if (_listingCancelled) {
            _showListingCancelled();
            return;
          }
          bannerMessage = cursor.hasMore
              ? 'Listed ${objects.length} objects in ${bucket.name}. More are available.'
              : 'Listed all ${objects.length} objects in ${bucket.name}.';
          _addEvent(
            level: 'INFO',
            category: 'Objects',
            message: cursor.hasMore
                ? 'Object listing stopped with ${objects.length} items loaded and more pages available.'
                : 'Object listing loaded all ${objects.length} items across $pageNumber page(s).',
            includeSelectionContext: true,
            source: 'object-browser',
          );
          await _loadSelectionArtifacts(cancellableListing: true);
        });
      },
    );
  }

  /// Shared object-listing page loop used by [refreshObjects] and
  /// [listAllObjectsForCurrentBucket]. Captures a cancellation generation at
  /// start so a cancel of this run cannot be undone by a later run, appends
  /// per-page progress lines to the active 'refresh-objects' task, and returns
  /// the accumulated items with the final cursor.
  Future<({List<ObjectEntry> items, ListCursor cursor, int pageNumber})>
      _pageThroughObjects({
    required EndpointProfile profile,
    required BucketSummary bucket,
    required List<ObjectEntry> initialItems,
    required ListCursor initialCursor,
    required int initialPageNumber,
    required bool listAll,
    required bool fetchFirstPageWithoutCursor,
  }) async {
    _listingCancelled = false;
    listingBudgetReached = false;
    final listingGeneration = ++_listingGeneration;
    final allItems = initialItems;
    final prefix = currentPrefix;
    final engineId = activeEngineId;
    final isFlat = flatView;
    var keyCharacters = allItems.fold<int>(0, (n, o) => n + o.key.length);
    var cursor = initialCursor;
    var pageNumber = initialPageNumber;
    var isFirstIteration = true;
    while (fetchFirstPageWithoutCursor || cursor.hasMore) {
      if (allItems.length >= objectListingBudget ||
          keyCharacters >= 16 * 1024 * 1024) {
        listingBudgetReached = true;
        _appendBusyTaskLine('refresh-objects',
            'Listing memory budget reached. Continue with the next window to release loaded rows.');
        break;
      }
      if (listingGeneration != _listingGeneration) {
        _listingCancelled = true;
        _appendBusyTaskLine(
          'refresh-objects',
          'Listing cancelled by user after $pageNumber page(s). Showing ${allItems.length} partial results.',
        );
        break;
      }
      final useCursor =
          fetchFirstPageWithoutCursor && isFirstIteration ? null : cursor;
      late final ObjectListResult objectResult;
      try {
        objectResult = await _awaitListing(() => _engineService.listObjects(
              engineId: engineId,
              profile: profile,
              bucketName: bucket.name,
              prefix: prefix,
              flat: isFlat,
              cursor: useCursor,
            ));
      } on ListingCancelled {
        _listingCancelled = true;
        _appendBusyTaskLine('refresh-objects',
            'Listing cancelled after $pageNumber page(s). Keeping ${allItems.length} loaded objects.');
        break;
      }
      if (listingGeneration != _listingGeneration) {
        _listingCancelled = true;
        break;
      }
      isFirstIteration = false;
      pageNumber += 1;
      allItems.addAll(objectResult.items);
      keyCharacters +=
          objectResult.items.fold<int>(0, (n, o) => n + o.key.length);
      cursor = objectResult.cursor;
      _appendBusyTaskLine(
        'refresh-objects',
        'Fetched page $pageNumber with ${objectResult.items.length} objects.',
      );
      if (!cursor.hasMore) {
        break;
      }
      if (!listAll) {
        _appendBusyTaskLine(
          'refresh-objects',
          'More objects are available. Use List all to continue listing this bucket.',
        );
        break;
      }
    }
    return (items: allItems, cursor: cursor, pageNumber: pageNumber);
  }

  Future<void> setSelectedBucket(BucketSummary bucket) async {
    objectSelection.clear();
    await _runBusy('select-bucket', 'Loading bucket ${bucket.name}...',
        () async {
      selectedBucket = bucket;
      currentPrefix = '';
      _syncObjectFilterWithPrefix();
      selectedObject = null;
      selectedObjectDetails = null;
      selectedObjectPreview = null;
      adminState = null;
      benchmarkDraft = benchmarkDraft.copyWith(bucketName: bucket.name);
      testDataConfig = testDataConfig.copyWith(bucketName: bucket.name);
      deleteAllConfig = deleteAllConfig.copyWith(bucketName: bucket.name);
      _addEvent(
        level: 'INFO',
        category: 'Buckets',
        message: 'Selected bucket ${bucket.name}.',
        includeSelectionContext: true,
        source: 'bucket-browser',
      );
      await refreshObjects();
      if (!_listingCancelled) {
        await refreshBucketAdminState(cancellableListing: true);
      }
    });
  }

  Future<void> createBucket({
    required String bucketName,
    required bool enableVersioning,
    required bool enableObjectLock,
  }) async {
    final profile = selectedProfile;
    if (profile == null) {
      return;
    }

    await _runBusy('create-bucket', 'Creating bucket $bucketName...', () async {
      await _guard('Buckets', () async {
        final created = await _engineService.createBucket(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucketName,
          enableVersioning: enableVersioning,
          enableObjectLock: enableObjectLock,
        );
        buckets = [
          created,
          ...buckets.where((bucket) => bucket.name != created.name),
        ]..sort((left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()));
        bannerMessage = 'Created bucket ${created.name}.';
        _addEvent(
          level: 'INFO',
          category: 'Buckets',
          message:
              'Created bucket ${created.name} with versioning=$enableVersioning and objectLock=$enableObjectLock.',
          profileId: profile.id,
          bucketName: created.name,
          source: 'bucket-admin',
        );
        await setSelectedBucket(created);
      });
    });
  }

  Future<void> setSelectedObject(
    ObjectEntry object, {
    bool openFolderOnSelect = true,
    bool loadArtifacts = true,
  }) async {
    if (openFolderOnSelect && object.isFolder && !flatView) {
      await openFolder(object);
      return;
    }
    final busyLabel = loadArtifacts && !object.isFolder
        ? 'Loading object details for ${object.name}...'
        : 'Selecting ${object.name}...';
    await _runBusy('select-object', busyLabel, () async {
      selectedObject = object;
      _addEvent(
        level: 'INFO',
        category: 'Objects',
        message: 'Selected object ${object.key}.',
        includeSelectionContext: true,
        objectKey: object.key,
        source: 'object-browser',
      );
      inspectorTab = BrowserInspectorTab.objectDetails;
      if (loadArtifacts && !object.isFolder) {
        await _loadSelectionArtifacts();
      } else {
        selectedObjectDetails = null;
        selectedObjectPreview = object.isFolder
            ? ObjectPreview.unsupported(
                key: object.key,
                message: 'Folder preview is not supported.',
              )
            : null;
      }
      notifyListeners();
    });
  }

  Future<void> toggleFlatView(bool value) async {
    flatView = value;
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message: 'Flat view set to $value.',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    await refreshObjects();
  }

  Future<void> openFolder(ObjectEntry folder) async {
    if (!folder.isFolder) {
      return;
    }
    currentPrefix = folder.key;
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message: 'Navigating into folder ${folder.key}.',
      includeSelectionContext: true,
      objectKey: folder.key,
      source: 'object-browser',
    );
    await refreshObjects(prefix: folder.key);
  }

  Future<void> navigateUp() async {
    if (currentPrefix.isEmpty) {
      return;
    }
    final trimmed = currentPrefix.endsWith('/')
        ? currentPrefix.substring(0, currentPrefix.length - 1)
        : currentPrefix;
    final lastSlash = trimmed.lastIndexOf('/');
    currentPrefix = lastSlash == -1 ? '' : trimmed.substring(0, lastSlash + 1);
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message: 'Navigated up to prefix "$currentPrefix".',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    await refreshObjects(prefix: currentPrefix);
  }

  Future<void> applyObjectFilter(String value, {bool log = true}) async {
    if (objectFilterMode == BrowserFilterMode.regex) {
      try {
        RegExp(value);
      } on FormatException catch (error) {
        objectFilterError = 'Invalid regular expression: ${error.message}';
        notifyListeners();
        return;
      }
      // Backtracking regexes run synchronously in Dart. Limit the accepted
      // expression size until the isolated filter worker validates execution.
      if (value.length > 256) {
        objectFilterError =
            'Use a regular expression of at most 256 characters.';
        notifyListeners();
        return;
      }
    }
    objectFilterError = null;
    objectSelection.clear();
    objectFilterValue = value;
    objectPage = 1;
    if (log) {
      _addEvent(
        level: 'INFO',
        category: 'Objects',
        message:
            'Updated object filter to "$value" in ${objectFilterMode.name} mode.',
        includeSelectionContext: true,
        source: 'object-browser',
      );
    }
    if (objectFilterMode == BrowserFilterMode.prefix) {
      await refreshObjects(prefix: value);
      return;
    }
    notifyListeners();
  }

  void setObjectFilterMode(BrowserFilterMode mode) {
    objectFilterError = null;
    objectSelection.clear();
    objectFilterMode = mode;
    objectPage = 1;
    if (mode == BrowserFilterMode.prefix) {
      _syncObjectFilterWithPrefix();
    }
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message: 'Switched object filter mode to ${mode.name}.',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    notifyListeners();
  }

  void setObjectSortField(BrowserObjectSortField field) {
    if (objectSortField == field) {
      return;
    }
    objectSortField = field;
    objectPage = 1;
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message: 'Sorted objects by ${field.name}.',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    notifyListeners();
  }

  void toggleObjectSortDirection() {
    objectSortDescending = !objectSortDescending;
    objectPage = 1;
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message:
          'Object sort order set to ${objectSortDescending ? 'descending' : 'ascending'}.',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    notifyListeners();
  }

  void setObjectPage(int value) {
    final clamped = value.clamp(1, objectPageCount).toInt();
    if (objectPage == clamped) {
      return;
    }
    objectPage = clamped;
    notifyListeners();
  }

  void nextObjectPage() {
    if (objectPage >= objectPageCount) {
      return;
    }
    objectPage += 1;
    notifyListeners();
  }

  void previousObjectPage() {
    if (objectPage <= 1) {
      return;
    }
    objectPage -= 1;
    notifyListeners();
  }

  void setShowAllObjects(bool value) {
    if (showAllObjects == value) {
      return;
    }
    showAllObjects = value;
    if (!showAllObjects) {
      objectPage = objectPage.clamp(1, objectPageCount).toInt();
    }
    notifyListeners();
  }

  void updateVersionBrowserOptions(VersionBrowserOptions value) {
    versionBrowserOptions = value;
    _addEvent(
      level: 'INFO',
      category: 'Versions',
      message: 'Updated version filter options.',
      includeSelectionContext: true,
      source: 'version-browser',
    );
    notifyListeners();
  }

  void showAllObjectsNow() {
    showAllObjects = true;
    bannerMessage = 'Showing all ${visibleObjects.length} loaded objects.';
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message: 'Switched object browser to show-all mode.',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    notifyListeners();
  }

  Future<void> createFolderMarker(String prefixName) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final trimmedName = prefixName.trim();
    if (profile == null || bucket == null || trimmedName.isEmpty) {
      return;
    }
    final normalizedName =
        trimmedName.endsWith('/') ? trimmedName : '$trimmedName/';
    final folderKey = currentPrefix.isEmpty
        ? normalizedName
        : '$currentPrefix$normalizedName';
    await _runBusy('create-folder', 'Creating folder marker...', () async {
      await _guard('Objects', () async {
        _appendBusyTaskLine(
          'create-folder',
          'Creating prefix $folderKey in bucket ${bucket.name}.',
        );
        await _engineService.createFolder(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          key: folderKey,
        );
        bannerMessage = 'Created folder marker $folderKey.';
        _addEvent(
          level: 'INFO',
          category: 'Objects',
          message: 'Created prefix $folderKey.',
          includeSelectionContext: true,
          objectKey: folderKey,
          source: 'object-browser',
        );
        if (settings.relistObjectsAfterMutation) {
          await refreshObjects(prefix: currentPrefix);
        }
      });
    });
  }

  Future<void> deleteSelectedObject() async {
    await deleteObjectKeys(objectSelection.isEmpty
        ? [if (selectedObject != null) selectedObject!.key]
        : objectSelection.keys.toList());
  }

  Future<void> deleteObjectKeys(List<String> keys) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final object = selectedObject;
    if (profile == null || bucket == null || keys.isEmpty) {
      return;
    }
    await _runBusy('delete-object', 'Deleting ${keys.length} object(s)...',
        () async {
      await _guard('Objects', () async {
        final result = await _engineService.deleteObjects(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          keys: keys,
        );
        final deleted = ObjectSelection.confirmedDeletes(keys, result);
        bannerMessage = result.failureCount > 0
            ? 'Deleted ${result.successCount}; ${result.failureCount} failed. ${result.failures.map((f) => '${f.target}: ${f.message}').join('; ')}'
            : deleted.length != keys.length
                ? 'Delete outcome could not be confirmed. Refresh before retrying.'
                : 'Deleted ${result.successCount} objects.';
        _addEvent(
          level: 'INFO',
          category: 'Objects',
          message:
              'Delete request completed with ${result.successCount} successes and ${result.failureCount} failures.',
          includeSelectionContext: true,
          objectKey: object?.key,
          source: 'object-browser',
        );
        if (selectedProfile?.id != profile.id ||
            selectedBucket?.name != bucket.name) {
          return;
        }
        objects =
            objects.where((entry) => !deleted.contains(entry.key)).toList();
        objectSelection.removeAll(deleted);
        if (deleted.contains(selectedObject?.key)) {
          selectedObject = null;
          selectedObjectPreview = null;
        }
        await _loadSelectionArtifacts();
      });
    });
  }

  Future<void> startSampleUpload(
    List<String> filePaths, {
    Map<String, String> objectKeyByPath = const <String, String>{},
  }) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    if (profile == null || bucket == null || filePaths.isEmpty) {
      return;
    }
    await _runBusy('upload', 'Starting upload...', () async {
      await _guard('Transfers', () async {
        if (filePaths.length > 1) {
          await _startUploadBatch(
              profile, bucket.name, filePaths, objectKeyByPath);
          return;
        }
        final uploadChunkMiB = await _uploadChunkSizeMiB(filePaths);
        final requestEngine = activeEngineId;
        final requestPrefix = currentPrefix;
        final job = await _engineService.startUpload(
          engineId: requestEngine,
          profile: profile,
          bucketName: bucket.name,
          prefix: requestPrefix,
          filePaths: filePaths,
          objectKeyByPath: objectKeyByPath,
          multipartThresholdMiB: settings.multipartThresholdMiB,
          multipartChunkMiB: uploadChunkMiB,
        );
        _pendingUploadRelists[job.id] = _PendingObjectRelist(
          profileId: profile.id,
          bucketName: bucket.name,
          prefix: requestPrefix,
          listAll: listAllKeys,
        );
        _registerUploadRetry(job.id, profile.id, bucket.name, requestEngine,
            requestPrefix, filePaths, objectKeyByPath);
        transferJobs = [job, ...transferJobs];
        _trackTransferJob(job);
        _maybeRelistAfterUpload(job);
        bannerTaskId = job.id;
        bannerMessage = _transferBannerMessage(job);
        bannerSeverity = job.status == 'failed'
            ? BannerSeverity.error
            : job.status == 'completed'
                ? BannerSeverity.success
                : BannerSeverity.info;
        _addEvent(
          level: 'INFO',
          category: 'Transfers',
          message:
              'Started upload job ${job.id} for ${filePaths.length} file(s) into ${bucket.name} with ${settings.dynamicMultipartSizing ? 'dynamic' : 'manual'} $uploadChunkMiB MiB parts.',
          includeSelectionContext: true,
          source: 'task-tray',
        );
      });
    }, trackTask: AppPlatform.isMobile);
  }

  void _registerUploadRetry(
      String id,
      String profileId,
      String bucket,
      String engine,
      String prefix,
      List<String> paths,
      Map<String, String> keys) {
    final files = List<String>.of(paths);
    final mapping = Map<String, String>.of(keys);
    _retryTransfers[id] = () async {
      if (selectedProfile?.id != profileId ||
          selectedBucket?.name != bucket ||
          activeEngineId != engine ||
          currentPrefix != prefix) {
        showBannerMessage(
            'Open the original upload connection, engine, bucket and prefix before retrying.',
            severity: BannerSeverity.warning);
        return;
      }
      await startSampleUpload(files, objectKeyByPath: mapping);
    };
  }

  Future<int> _uploadChunkSizeMiB(List<String> filePaths) async {
    if (!settings.dynamicMultipartSizing) {
      return MultipartSizing.compliantManualPartSizeMiB(
        settings.multipartChunkMiB,
      );
    }
    var largestFileBytes = 0;
    for (final path in filePaths) {
      final size = await File(path).length();
      largestFileBytes = math.max(largestFileBytes, size);
    }
    return MultipartSizing.recommendedPartSizeMiB(largestFileBytes);
  }

  UploadBatch? _uploadBatch;

  Future<void> _startUploadBatch(EndpointProfile profile, String bucket,
      List<String> paths, Map<String, String> keys) async {
    final id = 'upload-batch-${DateTime.now().microsecondsSinceEpoch}';
    final engineId = activeEngineId;
    final prefix = currentPrefix;
    _registerUploadRetry(id, profile.id, bucket, engineId, prefix, paths, keys);
    final batch = UploadBatch(
        id: id,
        engine: _engineService,
        engineId: engineId,
        profile: profile,
        bucket: bucket,
        prefix: prefix,
        paths: List.of(paths),
        objectKeys: Map.of(keys),
        settings: settings,
        onUpdate: (job) {
          bannerTaskId = id;
          _replaceTransfer(job);
          _trackTransferJob(job);
        },
        onFile: (index, path, status, message, job) {
          _addEvent(
              level: status == 'failed' || status == 'error' ? 'ERROR' : 'INFO',
              category: 'Transfers',
              message: message,
              source: 'upload-file',
              requestId: '$id/file-$index',
              parentRequestId: id,
              profileId: profile.id,
              bucketName: bucket,
              engineId: engineId,
              objectKey:
                  '$prefix${keys[path] ?? path.split(Platform.pathSeparator).last}',
              responseStatus: status,
              traceBody: {
                'file': path,
                'status': status,
                if (job != null) 'bytesTransferred': job.bytesTransferred,
                if (job != null) 'partsCompleted': job.partsCompleted,
                if (job != null) 'partsTotal': job.partsTotal
              });
          notifyListeners();
        });
    await batch.prepare();
    _uploadBatch = batch;
    _pendingUploadRelists[id] = _PendingObjectRelist(
        profileId: profile.id,
        bucketName: bucket,
        prefix: prefix,
        listAll: listAllKeys);
    _addEvent(
        level: 'INFO',
        category: 'Transfers',
        source: 'upload-batch',
        requestId: id,
        profileId: profile.id,
        bucketName: bucket,
        engineId: engineId,
        message: 'Upload ${paths.length} files to $bucket',
        responseStatus: 'running');
    try {
      final job = await batch.run();
      _addEvent(
          level: job.status == 'failed' ? 'ERROR' : 'INFO',
          category: 'Transfers',
          source: 'upload-batch',
          requestId: id,
          profileId: profile.id,
          bucketName: bucket,
          engineId: engineId,
          message:
              '${job.label}: ${job.status} · ${job.itemsCompleted}/${job.itemCount} files completed.',
          responseStatus: job.status);
      _maybeRelistAfterUpload(job);
    } finally {
      _uploadBatch = null;
      notifyListeners();
    }
  }

  Future<void> startSampleDownload() async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final object = selectedObject;
    final keys = objectSelection.isEmpty
        ? [if (object != null && !object.isFolder) object.key]
        : objectSelection.keys.toList();
    if (profile == null || bucket == null || keys.isEmpty) {
      return;
    }
    await _runBusy('download', 'Starting download...', () async {
      await _guard('Transfers', () async {
        final retryEngine = activeEngineId;
        final retryDestination = settings.downloadPath;
        final retryConflictPolicy =
            AppPlatform.isMobile ? 'keepBoth' : settings.downloadConflictPolicy;
        final retryThreshold = settings.multipartThresholdMiB;
        final retryChunk = settings.multipartChunkMiB;
        final retryKeys = List<String>.of(keys);
        final job = await _engineService.startDownload(
          engineId: retryEngine,
          profile: profile,
          bucketName: bucket.name,
          keys: retryKeys,
          destinationPath: retryDestination,
          conflictPolicy: retryConflictPolicy,
          multipartThresholdMiB: retryThreshold,
          multipartChunkMiB: retryChunk,
        );
        Future<void> replay() async {
          if (activeEngineId != retryEngine ||
              selectedProfile?.id != profile.id ||
              selectedBucket?.name != bucket.name) {
            showBannerMessage(
                'Select the original connection, engine and bucket before retrying.',
                severity: BannerSeverity.warning);
            return;
          }
          await _guard('Transfers', () async {
            final next = await _engineService.startDownload(
                engineId: retryEngine,
                profile: selectedProfile!,
                bucketName: bucket.name,
                keys: retryKeys,
                destinationPath: retryDestination,
                conflictPolicy: retryConflictPolicy,
                multipartThresholdMiB: retryThreshold,
                multipartChunkMiB: retryChunk);
            _retryTransfers[next.id] = replay;
            transferJobs = [next, ...transferJobs];
            bannerTaskId = next.id;
            _trackTransferJob(next);
          });
        }

        _retryTransfers[job.id] = replay;
        transferJobs = [job, ...transferJobs];
        _trackTransferJob(job);
        bannerTaskId = job.id;
        bannerMessage = _transferBannerMessage(job);
        bannerSeverity = job.status == 'failed'
            ? BannerSeverity.error
            : job.status == 'completed'
                ? BannerSeverity.success
                : BannerSeverity.info;
        final destinationLabel =
            AppPlatform.isMobile ? 'Downloads' : settings.downloadPath;
        _addEvent(
          level: 'INFO',
          category: 'Transfers',
          message:
              'Started download job ${job.id} for ${keys.length} object(s) into $destinationLabel.',
          includeSelectionContext: true,
          objectKey: object?.key,
          source: 'task-tray',
        );
      });
    }, trackTask: AppPlatform.isMobile);
  }

  Future<void> pauseTransfer(String jobId) async {
    await _runBusy('control-$jobId', 'Pause transfer', () async {
      if (_uploadBatch?.id == jobId) {
        await _uploadBatch!.control('pause');
        return;
      }
      final response = await _engineService.pauseTransfer(
        engineId: _jobEngineOwners[jobId] ?? activeEngineId,
        jobId: jobId,
      );
      final job = mergeTransferControl(
          transferJobs.where((job) => job.id == jobId).firstOrNull, response);
      _replaceTransfer(job);
      _trackTransferJob(job);
      _addEvent(
        level: 'INFO',
        category: 'Transfers',
        message: 'Paused transfer $jobId.',
        includeSelectionContext: true,
        source: 'task-tray',
      );
      notifyListeners();
    }, trackTask: false);
  }

  Future<void> resumeTransfer(String jobId) async {
    await _runBusy('control-$jobId', 'Resume transfer', () async {
      if (_uploadBatch?.id == jobId) {
        await _uploadBatch!.control('resume');
        return;
      }
      final response = await _engineService.resumeTransfer(
        engineId: _jobEngineOwners[jobId] ?? activeEngineId,
        jobId: jobId,
      );
      final job = mergeTransferControl(
          transferJobs.where((job) => job.id == jobId).firstOrNull, response);
      _replaceTransfer(job);
      _addEvent(
        level: 'INFO',
        category: 'Transfers',
        message: 'Resumed transfer $jobId.',
        includeSelectionContext: true,
        source: 'task-tray',
      );
      _trackTransferJob(job);
      notifyListeners();
    }, trackTask: false);
  }

  Future<void> cancelTransfer(String jobId) async {
    await _runBusy(
        'control-$jobId',
        'Cancel transfer',
        () => _guard('Transfers', () async {
              if (_uploadBatch?.id == jobId) {
                await _uploadBatch!.control('cancel');
                return;
              }
              final response = await _engineService.cancelTransfer(
                engineId: _jobEngineOwners[jobId] ?? activeEngineId,
                jobId: jobId,
              );
              final job = mergeTransferControl(
                  transferJobs.where((job) => job.id == jobId).firstOrNull,
                  response);
              _replaceTransfer(job);
              _addEvent(
                level: 'INFO',
                category: 'Transfers',
                message: 'Transfer $jobId: ${job.status}.',
                includeSelectionContext: true,
                source: 'task-tray',
              );
              _trackTransferJob(job);
              notifyListeners();
            }),
        trackTask: false);
  }

  Future<void> cancelToolTask(BrowserTaskRecord task) async {
    if (task.engineJobId == null) {
      return;
    }
    final state = await _engineService.cancelToolExecution(
      engineId: _jobEngineOwners[task.id] ?? activeEngineId,
      jobId: task.engineJobId!,
    );
    final taskLabel = _normalizeToolLabel(task.label);
    if (taskLabel == _normalizeToolLabel(putTestDataState.label)) {
      putTestDataState = state;
    } else if (taskLabel == _normalizeToolLabel(deleteAllState.label)) {
      deleteAllState = state;
    }
    final status = state.running
        ? 'cancelling'
        : state.exitCode == 130
            ? 'cancelled'
            : state.exitCode == 0
                ? 'completed'
                : 'failed';
    _upsertTask(task.copyWith(
        status: status,
        completedAt: state.running ? null : DateTime.now(),
        progress: task.progress,
        outputLines: state.outputLines,
        canCancel: state.cancellable));
    _addEvent(
      level: 'INFO',
      category: 'Tools',
      message: 'Tool ${task.label}: $status.',
      includeSelectionContext: true,
      source: 'task-tray',
    );
    notifyListeners();
  }

  Future<void> cancelAction(String actionKey) async {
    final id = _busyTaskIds[actionKey];
    final task = id == null ? null : _taskById(id);
    if (task != null) await cancelTask(task);
  }

  Future<void> cancelTask(BrowserTaskRecord task) async {
    if (task.kind == BrowserTaskKind.transfer) {
      await cancelTransfer(task.id);
      return;
    }
    if (task.kind == BrowserTaskKind.tool &&
        !_actionScopes.containsKey(task.id)) {
      await cancelToolTask(task);
      return;
    }
    if (task.kind == BrowserTaskKind.benchmark) {
      if (benchmarkRun?.id == task.id && task.isRunningLike) {
        await stopBenchmark();
      }
      return;
    }
    final scope = _actionScopes[task.id];
    if (scope != null && !scope.isCancelled) {
      scope.cancel();
      _upsertTask(
          task.copyWith(status: 'cancelling', canCancel: false, outputLines: [
        ...task.outputLines,
        'Cancellation requested. Stopping this action; completed work is retained.'
      ]));
      notifyListeners();
    } else if (scope == null &&
        task.actionKey != null &&
        _isListingActionKey(task.actionKey!)) {
      cancelListing();
    }
  }

  Future<void> generateSelectedPresignedUrl() async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final object = selectedObject;
    if (profile == null || bucket == null || object == null) {
      return;
    }
    await _runBusy('presign', 'Generating presigned URL...', () async {
      await _guard('Presign', () async {
        final expiration = Duration(minutes: settings.defaultPresignMinutes);
        final url = await _engineService.generatePresignedUrl(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          key: object.key,
          expiration: expiration,
        );
        final bundle = PresignedUrlBundle(
          url: url,
          expirationMinutes: settings.defaultPresignMinutes,
          curlCommand: 'curl -L "$url" -o "${object.name}"',
        );
        selectedObjectDetails = (selectedObjectDetails ??
                ObjectDetails(
                  key: object.key,
                  metadata: const {},
                  headers: const {},
                  tags: const {},
                  debugEvents: const [],
                  apiCalls: const [],
                ))
            .copyWith(presignedUrl: bundle);
        inspectorTab = BrowserInspectorTab.presign;
        _addEvent(
          level: 'INFO',
          category: 'Presign',
          message:
              'Generated presigned URL for ${object.key} with ${settings.defaultPresignMinutes} minute expiration.',
          includeSelectionContext: true,
          objectKey: object.key,
          source: 'presign',
        );
      });
    });
  }

  Future<void> refreshSelectedObjectPreview() async {
    final object = selectedObject;
    if (object == null) {
      selectedObjectPreview = null;
      notifyListeners();
      return;
    }
    _primeSelectedObjectPreview(object);
  }

  /// Older engine bridges (notably Android) report tool labels with a `.py`
  /// suffix ('put-testdata.py'); normalize so matching tolerates both forms.
  String _normalizeToolLabel(String label) =>
      label.endsWith('.py') ? label.substring(0, label.length - 3) : label;

  ToolExecutionState _failToolState(
    ToolExecutionState state,
    Object error,
  ) {
    final message = error is EngineException
        ? '${error.code.name}: ${error.message}'
        : error.toString();
    return state.copyWith(
      running: false,
      exitCode: 1,
      lastStatus: message,
      cancellable: false,
    );
  }

  void _failToolTask(String taskId, ToolExecutionState state) {
    final task = _taskById(taskId);
    if (task == null) {
      return;
    }
    _upsertTask(
      task.copyWith(
        status: 'failed',
        completedAt: DateTime.now(),
        progress: 1,
        outputLines: state.outputLines,
        canCancel: false,
      ),
    );
  }

  Future<void> runPutTestDataTool() async {
    final profile = selectedProfile;
    if (profile == null) {
      return;
    }
    final taskId = _nextTaskId('put-testdata');
    final scope = ActionScope(engineId: activeEngineId);
    _actionScopes[taskId] = scope;
    _jobEngineOwners[taskId] = activeEngineId;
    await scope.run(() => _guard('Tools', () async {
          putTestDataState = putTestDataState.copyWith(running: true);
          _upsertTask(
            BrowserTaskRecord(
              id: taskId,
              engineJobId: putTestDataState.jobId,
              kind: BrowserTaskKind.tool,
              label: 'put-testdata',
              status: 'running',
              startedAt: DateTime.now(),
              progress: 0,
              profileId: profile.id,
              bucketName: selectedBucket?.name ?? testDataConfig.bucketName,
              canCancel: true,
              outputLines: putTestDataState.outputLines,
            ),
          );
          notifyListeners();
          try {
            putTestDataState = await _engineService.runPutTestData(
              engineId: activeEngineId,
              profile: profile,
              config: testDataConfig,
            );
          } on ListingCancelled {
            final current = _taskById(taskId)!;
            putTestDataState = putTestDataState.copyWith(
                running: false,
                cancellable: false,
                lastStatus: scope.outcomeUnknown
                    ? 'Stopped; remote outcome unknown.'
                    : 'Cancelled.');
            _upsertTask(current.copyWith(
                status: scope.outcomeUnknown ? 'unknown' : 'cancelled',
                canCancel: false,
                completedAt: DateTime.now(),
                outputLines: [
                  ...current.outputLines,
                  putTestDataState.lastStatus
                ]));
            notifyListeners();
            rethrow;
          } catch (error) {
            putTestDataState = _failToolState(putTestDataState, error);
            _failToolTask(taskId, putTestDataState);
            notifyListeners();
            // Rethrow so _guard still surfaces the error banner and event.
            rethrow;
          }
          bannerMessage = putTestDataState.lastStatus;
          _upsertTask(
            _taskById(taskId)!.copyWith(
              status: (putTestDataState.exitCode == null ||
                      putTestDataState.exitCode == 0)
                  ? 'completed'
                  : 'failed',
              completedAt: DateTime.now(),
              progress: 1,
              outputLines: putTestDataState.outputLines,
              canCancel: putTestDataState.cancellable,
            ),
          );
          _addEvent(
            level: 'INFO',
            category: 'Tools',
            message: putTestDataState.lastStatus,
            includeSelectionContext: true,
            source: 'task-tray',
          );
          notifyListeners();
        }));
    _actionScopes.remove(taskId);
  }

  Future<void> runDeleteAllTool() async {
    final profile = selectedProfile;
    if (profile == null || deleteAllState.running) {
      return;
    }
    final taskId = _nextTaskId('delete-all');
    final scope = ActionScope(engineId: activeEngineId);
    _actionScopes[taskId] = scope;
    _jobEngineOwners[taskId] = activeEngineId;
    await scope.run(() => _guard('Tools', () async {
          deleteAllState = deleteAllState.copyWith(running: true);
          _upsertTask(
            BrowserTaskRecord(
              id: taskId,
              engineJobId: deleteAllState.jobId,
              kind: BrowserTaskKind.tool,
              label: 'delete-all',
              status: 'running',
              startedAt: DateTime.now(),
              progress: 0,
              profileId: profile.id,
              bucketName: selectedBucket?.name ?? deleteAllConfig.bucketName,
              canCancel: true,
              outputLines: deleteAllState.outputLines,
            ),
          );
          notifyListeners();
          try {
            deleteAllState = await _engineService.runDeleteAll(
              engineId: activeEngineId,
              profile: profile,
              config: deleteAllConfig,
            );
          } on ListingCancelled {
            final current = _taskById(taskId)!;
            deleteAllState = deleteAllState.copyWith(
                running: false,
                cancellable: false,
                lastStatus: scope.outcomeUnknown
                    ? 'Stopped; remote outcome unknown.'
                    : 'Cancelled.');
            _upsertTask(current.copyWith(
                status: scope.outcomeUnknown ? 'unknown' : 'cancelled',
                canCancel: false,
                completedAt: DateTime.now(),
                outputLines: [
                  ...current.outputLines,
                  deleteAllState.lastStatus
                ]));
            notifyListeners();
            rethrow;
          } catch (error) {
            deleteAllState = _failToolState(deleteAllState, error);
            _failToolTask(taskId, deleteAllState);
            notifyListeners();
            // Rethrow so _guard still surfaces the error banner and event.
            rethrow;
          }
          bannerMessage = deleteAllState.lastStatus;
          _upsertTask(
            _taskById(taskId)!.copyWith(
              status: (deleteAllState.exitCode == null ||
                      deleteAllState.exitCode == 0)
                  ? 'completed'
                  : 'failed',
              completedAt: DateTime.now(),
              progress: 1,
              outputLines: deleteAllState.outputLines,
              canCancel: deleteAllState.cancellable,
            ),
          );
          _addEvent(
            level: 'INFO',
            category: 'Tools',
            message: deleteAllState.lastStatus,
            includeSelectionContext: true,
            source: 'task-tray',
          );
          notifyListeners();
        }));
    _actionScopes.remove(taskId);
  }

  Future<void> startBenchmark() async {
    final profile = selectedProfile;
    if (profile == null) {
      _addEvent(
        level: 'WARN',
        category: 'Benchmark',
        message: 'Benchmark start requested without a selected profile.',
        source: 'benchmark',
      );
      return;
    }
    if (benchmarkDraft.bucketName.trim().isEmpty) {
      bannerMessage = 'Select a benchmark bucket before starting the run.';
      _addEvent(
        level: 'WARN',
        category: 'Benchmark',
        message: 'Benchmark start requested without a bucket selection.',
        profileId: profile.id,
        source: 'benchmark',
      );
      notifyListeners();
      return;
    }
    if (isBusy('benchmark-start')) {
      return;
    }

    final optimisticId = 'pending-${DateTime.now().millisecondsSinceEpoch}';
    final optimisticConfig = benchmarkDraft.copyWith(
      profileId: profile.id,
      engineId: activeEngineId,
    );
    final optimisticRun = BenchmarkRun(
      id: optimisticId,
      config: optimisticConfig,
      status: 'starting',
      processedCount: 0,
      startedAt: DateTime.now(),
      averageLatencyMs: 0,
      throughputOpsPerSecond: 0,
      liveLog: const <String>[],
    );
    benchmarkRun = optimisticRun;
    selectedBenchmarkRunId = optimisticId;
    _upsertBenchmarkHistory(optimisticRun);
    notifyListeners();

    await _runBusy(
      'benchmark-start',
      'Starting benchmark…',
      () async {
        await _guard('Benchmark', () async {
          final run = await _engineService.startBenchmark(
            config: optimisticConfig,
            profile: profile,
          );
          benchmarkRun = run;
          selectedBenchmarkRunId = run.id;
          benchmarkHistory = [
            run,
            ...benchmarkHistory.where(
              (item) => item.id != run.id && item.id != optimisticId,
            )
          ];
          _trackBenchmarkRun(run, profileId: profile.id);
          bannerMessage = 'Started benchmark ${run.id}.';
          _addEvent(
            level: 'INFO',
            category: 'Benchmark',
            message:
                'Started benchmark ${run.id} with engine $activeEngineId against profile ${profile.name}.',
            includeSelectionContext: true,
            source: 'task-tray',
          );
          notifyListeners();
        });
        if (benchmarkRun?.id == optimisticId) {
          benchmarkRun = null;
          benchmarkHistory = benchmarkHistory
              .where((item) => item.id != optimisticId)
              .toList();
          if (selectedBenchmarkRunId == optimisticId) {
            selectedBenchmarkRunId = null;
          }
          notifyListeners();
        }
      },
      trackTask: false,
    );
  }

  /// Inserts or replaces [run] at the head of [benchmarkHistory], keyed by id.
  void _upsertBenchmarkHistory(BenchmarkRun run) {
    benchmarkHistory = [
      run,
      ...benchmarkHistory.where((item) => item.id != run.id),
    ];
  }

  Future<void> pollBenchmark() async {
    final run = benchmarkRun;
    if (run == null ||
        _benchmarkPollInFlight ||
        _benchmarkLifecycleActionInFlight) {
      return;
    }
    _benchmarkPollInFlight = true;
    try {
      benchmarkRun = await _engineService.getBenchmarkStatus(run.id);
      _benchmarkPollErrorReported = false;
      _upsertBenchmarkHistory(benchmarkRun!);
      _trackBenchmarkRun(
        benchmarkRun!,
        profileId: benchmarkRun!.config.profileId,
      );
      _addEvent(
        level: 'INFO',
        category: 'Benchmark',
        message:
            'Polled benchmark ${run.id}: status=${benchmarkRun!.status}, processed=${benchmarkRun!.processedCount}.',
        includeSelectionContext: true,
        source: 'benchmark',
      );
      notifyListeners();
    } catch (error) {
      // Poll runs on a 1s timer; surface the failure once rather than spamming
      // a banner/event every tick. Reset on the next successful poll.
      if (!_benchmarkPollErrorReported) {
        _benchmarkPollErrorReported = true;
        bannerMessage = 'Benchmark status polling failed: $error';
        bannerSeverity = BannerSeverity.error;
        _addEvent(
          level: 'ERROR',
          category: 'Benchmark',
          message: 'Benchmark status polling failed for ${run.id}: $error',
          includeSelectionContext: true,
          source: 'benchmark',
        );
        notifyListeners();
      }
    } finally {
      _benchmarkPollInFlight = false;
    }
  }

  Future<void> pauseBenchmark() async {
    final run = benchmarkRun;
    if (run == null) {
      return;
    }
    benchmarkRun = run.copyWith(
      status: 'pausing',
      liveLog: [...run.liveLog, 'Pause requested...'],
    );
    _upsertBenchmarkHistory(benchmarkRun!);
    bannerMessage = 'Pausing benchmark ${run.id}...';
    notifyListeners();
    _benchmarkLifecycleActionInFlight = true;
    try {
      await _guard('Benchmark', () async {
        await _engineService.pauseBenchmark(run.id);
        // Rebuild from the current run rather than the pre-await snapshot so a
        // concurrent poll update is not clobbered.
        benchmarkRun = (benchmarkRun ?? run).copyWith(status: 'paused');
        _upsertBenchmarkHistory(benchmarkRun!);
        _addEvent(
          level: 'INFO',
          category: 'Benchmark',
          message: 'Paused benchmark ${run.id}.',
          includeSelectionContext: true,
          source: 'benchmark',
        );
        notifyListeners();
      });
    } finally {
      _benchmarkLifecycleActionInFlight = false;
    }
    await pollBenchmark();
  }

  Future<void> resumeBenchmark() async {
    final run = benchmarkRun;
    if (run == null) {
      return;
    }
    benchmarkRun = run.copyWith(
      status: 'resuming',
      liveLog: [...run.liveLog, 'Resume requested...'],
    );
    _upsertBenchmarkHistory(benchmarkRun!);
    bannerMessage = 'Resuming benchmark ${run.id}...';
    notifyListeners();
    _benchmarkLifecycleActionInFlight = true;
    try {
      await _guard('Benchmark', () async {
        await _engineService.resumeBenchmark(run.id);
        benchmarkRun = (benchmarkRun ?? run).copyWith(status: 'running');
        _upsertBenchmarkHistory(benchmarkRun!);
        _addEvent(
          level: 'INFO',
          category: 'Benchmark',
          message: 'Resumed benchmark ${run.id}.',
          includeSelectionContext: true,
          source: 'benchmark',
        );
        notifyListeners();
      });
    } finally {
      _benchmarkLifecycleActionInFlight = false;
    }
    await pollBenchmark();
  }

  Future<void> stopBenchmark() async {
    final run = benchmarkRun;
    if (run == null) {
      return;
    }
    benchmarkRun = run.copyWith(
      status: 'stopping',
      liveLog: [...run.liveLog, 'Stop requested...'],
    );
    _upsertBenchmarkHistory(benchmarkRun!);
    bannerMessage = 'Stopping benchmark ${run.id}...';
    notifyListeners();
    _benchmarkLifecycleActionInFlight = true;
    try {
      await _guard('Benchmark', () async {
        await _engineService.stopBenchmark(run.id);
        benchmarkRun = (benchmarkRun ?? run).copyWith(
          status: 'stopped',
          completedAt: DateTime.now(),
        );
        _upsertBenchmarkHistory(benchmarkRun!);
        _addEvent(
          level: 'INFO',
          category: 'Benchmark',
          message: 'Stopped benchmark ${run.id}.',
          includeSelectionContext: true,
          source: 'benchmark',
        );
        notifyListeners();
      });
    } finally {
      _benchmarkLifecycleActionInFlight = false;
    }
    await pollBenchmark();
  }

  Future<void> updateSettings(AppSettings value) async {
    settings = value;
    _syncDiagnosticsOptions();
    benchmarkDraft = benchmarkDraft.copyWith(
      concurrentThreads: value.transferConcurrency,
      connectTimeoutSeconds: value.connectTimeoutSeconds,
      readTimeoutSeconds: value.readTimeoutSeconds,
      maxAttempts: value.safeRetries,
      maxPoolConnections: value.maxPoolConnections,
      dataCacheMb: value.benchmarkDataCacheMb,
      csvOutputPath:
          '${value.tempPath}${Platform.pathSeparator}benchmark-results.csv',
      jsonOutputPath:
          '${value.tempPath}${Platform.pathSeparator}benchmark-results.json',
      debugMode: value.benchmarkDebugMode,
      logFilePath: value.benchmarkLogPath,
    );
    _addEvent(
      level: 'INFO',
      category: 'Settings',
      message: 'Updated application settings.',
      source: 'settings',
    );
    await _persistState();
    notifyListeners();
  }

  void updateProfile(EndpointProfile profile) {
    profile = normalizeEndpointProfile(profile);
    if (!profiles.contains(profile)) {
      persistenceState.recordProfile(profile.id, false);
    }
    final updatedExisting = profiles.any((item) => item.id == profile.id);
    profiles = updatedExisting
        ? profiles
            .map((item) => item.id == profile.id ? profile : item)
            .toList()
        : [...profiles, profile];
    if (selectedProfile?.id == profile.id) {
      selectedProfile = profile;
      testDataConfig = testDataConfig.copyWith(
        endpointUrl: profile.endpointUrl,
        accessKey: profile.accessKey,
        secretKey: profile.secretKey,
      );
      deleteAllConfig = deleteAllConfig.copyWith(
        endpointUrl: profile.endpointUrl,
        accessKey: profile.accessKey,
        secretKey: profile.secretKey,
      );
      benchmarkDraft = benchmarkDraft.copyWith(profileId: profile.id);
    }
    notifyListeners();
  }

  Future<void> testProfileById(String profileId) =>
      testProfileDraft(profiles.firstWhere((item) => item.id == profileId));

  bool supportsProfile(EndpointProfile profile) =>
      profile.endpointType != EndpointProfileType.azureBlob ||
      (!AppPlatform.isMobile && const {'python', 'go'}.contains(activeEngineId));

  Future<void> testProfileDraft(EndpointProfile draft) async {
    final profile = normalizeEndpointProfile(draft);
    final engine = activeEngineId;
    await _runBusy('test-profile-${profile.id}', 'Testing ${profile.name}...',
        () async {
      await _guard('Profiles', () async {
        final scope = ActionScope.current;
        Future<T> read<T>(Future<T> request) =>
            scope == null ? request : scope.wait(request);
        await read(
            _engineService.testProfile(engineId: engine, profile: profile));
        final found = await read(
            _engineService.listBuckets(engineId: engine, profile: profile));
        scope?.check();
        bannerMessage =
            'Connection test succeeded: ${found.length} bucket(s). Draft was not saved or activated.';
        bannerSeverity = BannerSeverity.success;
      });
    });
  }

  Future<bool> saveProfile(EndpointProfile profile) async {
    profile = normalizeEndpointProfile(profile);
    updateProfile(profile);
    if (selectedProfile == null) {
      selectedProfile = profile;
      benchmarkDraft = benchmarkDraft.copyWith(profileId: profile.id);
      testDataConfig = testDataConfig.copyWith(
        endpointUrl: profile.endpointUrl,
        accessKey: profile.accessKey,
        secretKey: profile.secretKey,
      );
      deleteAllConfig = deleteAllConfig.copyWith(
        endpointUrl: profile.endpointUrl,
        accessKey: profile.accessKey,
        secretKey: profile.secretKey,
      );
    }
    final persisted = await _persistState(
      allowCredentialStoreRecovery: true,
      explicitProfileIds: {profile.id},
    );
    if (persisted) _credentialStoreError = null;
    _lastProfileSaveSucceeded = persisted;
    persistenceState.recordProfile(profile.id, persisted);
    _addEvent(
        level: persisted ? 'INFO' : 'ERROR',
        category: 'Profiles',
        message: persisted
            ? 'Saved endpoint profile ${profile.name}.'
            : 'Profile ${profile.name} is session-only: secure persistence failed.',
        profileId: profile.id,
        source: 'profiles');
    bannerMessage = persisted
        ? 'Saved endpoint profile ${profile.name}.'
        : _credentialStoreError ??
            'Profile is available for this session, but its credentials could not be saved securely.';
    bannerSeverity =
        persisted ? BannerSeverity.success : BannerSeverity.warning;
    notifyListeners();
    return persisted;
  }

  Future<void> deleteProfile(String profileId) async {
    profiles = profiles.where((item) => item.id != profileId).toList();
    if (selectedProfile?.id == profileId) {
      selectedProfile = profiles.isEmpty ? null : profiles.first;
      buckets = const [];
      objects = const [];
      versions = const [];
      capabilities = const [];
      selectedBucket = null;
      selectedObject = null;
      selectedObjectDetails = null;
      selectedObjectPreview = null;
      currentPrefix = '';
      _syncObjectFilterWithPrefix();
      if (selectedProfile != null) {
        await refreshCapabilities();
        await refreshBuckets();
      }
    }
    if (settings.defaultProfileId == profileId) {
      settings = settings.copyWith(
        defaultProfileId: profiles.isEmpty ? '' : profiles.first.id,
      );
    }
    bannerMessage = 'Removed endpoint profile from this session.';
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Deleted endpoint profile $profileId.',
      profileId: profileId,
      source: 'profiles',
    );
    final saved = await _persistState();
    bannerMessage = saved
        ? 'Deleted endpoint profile.'
        : 'Profile removed for this session; deletion could not be saved.';
    bannerSeverity = saved ? BannerSeverity.success : BannerSeverity.warning;
    notifyListeners();
  }

  Future<void> setDefaultEngine(String engineId) async {
    settings = settings.copyWith(defaultEngineId: engineId);
    _addEvent(
      level: 'INFO',
      category: 'Engine',
      message: 'Updated default engine to $engineId.',
      source: 'engine',
    );
    await _persistState();
    notifyListeners();
  }

  Future<void> setDefaultProfile(String profileId) async {
    final profile = profiles.firstWhere((item) => item.id == profileId);
    settings = settings.copyWith(defaultProfileId: profile.id);
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Updated default endpoint to ${profile.name}.',
      profileId: profile.id,
      source: 'profiles',
    );
    await _persistState();
    notifyListeners();
  }

  Future<void> addSampleProfile() async {
    final profile = EndpointProfile(
      id: 'profile-${profiles.length + 1}',
      name: 'New Profile ${profiles.length + 1}',
      endpointUrl: '',
      region: '',
      accessKey: '',
      secretKey: '',
      pathStyle: true,
      verifyTls: true,
      endpointType: EndpointProfileType.s3Compatible,
      notes: '',
    );
    profiles = [...profiles, profile];
    if (selectedProfile == null) {
      selectedProfile = profile;
      benchmarkDraft = benchmarkDraft.copyWith(profileId: profile.id);
    }
    bannerMessage =
        'Created a new endpoint profile. Fill in the connection details and save it.';
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Created new endpoint profile ${profile.name}.',
      profileId: profile.id,
      source: 'profiles',
    );
    await _persistState();
    notifyListeners();
  }

  void updateTestDataConfig(TestDataToolConfig value) {
    testDataConfig = value;
    notifyListeners();
  }

  void updateDeleteAllConfig(DeleteAllToolConfig value) {
    deleteAllConfig = value;
    notifyListeners();
  }

  void updateBenchmarkDraft(BenchmarkConfig value) {
    benchmarkDraft = value;
    notifyListeners();
  }

  void clearDiagnostics() {
    selectedObjectDetails = selectedObjectDetails?.copyWith(
      debugEvents: const [],
      apiCalls: const [],
    );
    bannerMessage = 'Events & debug details cleared for the current selection.';
    _addEvent(
      level: 'INFO',
      category: 'EventsAndDebug',
      message: 'Cleared selection diagnostics.',
      includeSelectionContext: true,
      source: 'events-and-debug',
    );
    notifyListeners();
  }

  Future<void> exportDiagnostics() async {
    await _runBusy('export-diagnostics', 'Exporting inspector diagnostics...',
        () async {
      final details = selectedObjectDetails;
      if (details == null) {
        bannerMessage = 'No diagnostics available for export.';
        notifyListeners();
        return;
      }

      final file = await _writeJsonExport(
        prefix: 'diagnostics',
        payload: {
          'profileId': selectedProfile?.id,
          'bucketName': selectedBucket?.name,
          'objectKey': details.key,
          'bucketEvents':
              bucketScopedEvents.map((entry) => entry.toJson()).toList(),
          'metadata': details.metadata,
          'headers': details.headers,
          'tags': details.tags,
          'debugEvents': details.debugEvents
              .map(
                (event) => {
                  'timestamp': event.timestamp.toIso8601String(),
                  'level': event.level,
                  'message': event.message,
                },
              )
              .toList(),
          'apiCalls': details.apiCalls
              .map(
                (call) => {
                  'timestamp': call.timestamp.toIso8601String(),
                  'operation': call.operation,
                  'status': call.status,
                  'latencyMs': call.latencyMs,
                },
              )
              .toList(),
        },
      );

      bannerMessage = 'Events & debug exported to ${file.path}.';
      _addEvent(
        level: 'INFO',
        category: 'EventsAndDebug',
        message: 'Exported diagnostics to ${file.path}.',
        includeSelectionContext: true,
        source: 'events-and-debug',
      );
      notifyListeners();
    });
  }

  Future<void> exportEventLog() async {
    await _runBusy('export-event-log', 'Exporting event log...', () async {
      await Directory(settings.downloadPath).create(recursive: true);
      final file = File(
        '${settings.downloadPath}${Platform.pathSeparator}event-log-${DateTime.now().millisecondsSinceEpoch}.log',
      );
      final lines = eventLog
          .map(
            (entry) =>
                '[${entry.level}] ${entry.timestamp.toIso8601String()} ${entry.category}: ${entry.message}'
                '${entry.profileId == null ? '' : ' [profile=${entry.profileId}]'}'
                '${entry.bucketName == null ? '' : ' [bucket=${entry.bucketName}]'}'
                '${entry.objectKey == null ? '' : ' [object=${entry.objectKey}]'}',
          )
          .join('\n');
      await file.writeAsString(lines);
      bannerMessage = 'Event log exported to ${file.path}.';
      _addEvent(
        level: 'INFO',
        category: 'EventLog',
        message: 'Exported event log to ${file.path}.',
        source: 'event-log',
      );
      notifyListeners();
    });
  }

  Future<void> exportBenchmarkResults(
    String format, {
    BenchmarkRun? run,
  }) async {
    final targetRun = run ?? selectedBenchmarkRun;
    if (targetRun == null) {
      return;
    }
    final export = await _engineService.exportBenchmarkResults(
      runId: targetRun.id,
      format: format,
    );
    bannerMessage =
        'Benchmark ${targetRun.id} export prepared for ${export.path}.';
    _addEvent(
      level: 'INFO',
      category: 'Benchmark',
      message:
          'Prepared $format export for benchmark ${targetRun.id} to ${export.path}.',
      source: 'benchmark',
    );
    notifyListeners();
  }

  Future<File?> exportProfilesToPath(String path) async {
    final repository = _appStateRepository;
    if (repository == null) {
      return null;
    }
    final file =
        await repository.exportProfiles(profiles: profiles, path: path);
    bannerMessage = 'Profiles exported to ${file.path}.';
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Exported ${profiles.length} profiles to ${file.path}.',
      source: 'profiles',
    );
    notifyListeners();
    return file;
  }

  Future<void> importProfilesFromPath(String path) async {
    final repository = _appStateRepository;
    if (repository == null) {
      return;
    }
    final existingById = <String, EndpointProfile>{
      for (final profile in profiles) profile.id: profile,
    };
    final importedFromFile = await repository.importProfiles(path);
    final importedCredentialCount = importedFromFile
        .where(
          (profile) =>
              profile.accessKey.isNotEmpty ||
              profile.secretKey.isNotEmpty ||
              (profile.sessionToken ?? '').isNotEmpty,
        )
        .length;
    final containsImportedCredentials = importedCredentialCount > 0;
    final importedProfiles =
        importedFromFile.map(normalizeEndpointProfile).map((profile) {
      final existing = existingById[profile.id];
      if (existing == null) return profile;
      return profile.copyWith(
        accessKey:
            profile.accessKey.isEmpty ? existing.accessKey : profile.accessKey,
        secretKey:
            profile.secretKey.isEmpty ? existing.secretKey : profile.secretKey,
        sessionToken: (profile.sessionToken ?? '').isEmpty
            ? existing.sessionToken
            : profile.sessionToken,
      );
    }).toList();
    final mergedById = <String, EndpointProfile>{
      for (final profile in profiles) profile.id: profile,
      for (final profile in importedProfiles) profile.id: profile,
    };
    profiles = mergedById.values.toList()
      ..sort((left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()));
    final currentSelectionId = selectedProfile?.id;
    final nextSelectedId = currentSelectionId != null &&
            profiles.any((profile) => profile.id == currentSelectionId)
        ? currentSelectionId
        : (importedProfiles.isNotEmpty
            ? importedProfiles.first.id
            : (profiles.isEmpty ? null : profiles.first.id));
    selectedProfile = nextSelectedId == null
        ? null
        : profiles.firstWhere((profile) => profile.id == nextSelectedId);
    final persisted = await _persistState(
      explicitProfileIds: importedProfiles.map((profile) => profile.id).toSet(),
      allowCredentialStoreRecovery: containsImportedCredentials,
    );
    if (persisted && containsImportedCredentials) {
      _credentialStoreError = null;
    }
    final String importBannerMessage;
    if (persisted) {
      importBannerMessage = containsImportedCredentials
          ? 'Imported ${importedProfiles.length} profiles and securely stored credentials for $importedCredentialCount ${importedCredentialCount == 1 ? 'profile' : 'profiles'}.'
          : 'Imported ${importedProfiles.length} profile definitions. The file contained no credentials.';
    } else if (!containsImportedCredentials && _credentialStoreError != null) {
      importBannerMessage =
          'Imported ${importedProfiles.length} profile definitions for this session, but the file contained no credentials. Import a credential-bearing file or re-enter the keys and save.';
    } else {
      importBannerMessage =
          'Imported ${importedProfiles.length} profiles for this session, but credentials could not be saved securely.';
    }
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Imported ${importedProfiles.length} profiles from $path.',
      source: 'profiles',
    );
    if (selectedProfile != null && _credentialStoreError == null) {
      await refreshCapabilities();
      await refreshBuckets();
    }
    bannerMessage = importBannerMessage;
    notifyListeners();
  }

  void showBannerMessage(
    String message, {
    String category = 'App',
    String source = 'app',
    BannerSeverity severity = BannerSeverity.info,
  }) {
    bannerMessage = message;
    bannerSeverity = severity;
    bannerTaskId = null;
    _addEvent(
      level: severity == BannerSeverity.error
          ? 'ERROR'
          : severity == BannerSeverity.warning
              ? 'WARN'
              : 'INFO',
      category: category,
      message: message,
      source: source,
    );
    notifyListeners();
  }

  Future<void> openPath(
    String path, {
    bool revealInFolder = false,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final file = File(trimmed);
    final directory = Directory(trimmed);
    final exists = file.existsSync() || directory.existsSync();
    if (!exists) {
      showBannerMessage(
        'Path not found: $trimmed',
        category: 'Files',
        source: 'files',
      );
      return;
    }

    try {
      if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        showBannerMessage(
          'Opening exported files is not available on this platform yet.',
          category: 'Files',
          source: 'files',
        );
        return;
      }

      if (Platform.isWindows) {
        if (revealInFolder && file.existsSync()) {
          await Process.start('explorer.exe', <String>['/select,$trimmed']);
        } else {
          if (directory.existsSync()) {
            await Process.start('explorer.exe', <String>[trimmed]);
          } else {
            await Process.start('cmd.exe', <String>[
              '/c',
              'start',
              '',
              trimmed,
            ]);
          }
        }
      } else if (Platform.isMacOS) {
        if (revealInFolder && file.existsSync()) {
          await Process.start('open', <String>['-R', trimmed]);
        } else {
          await Process.start('open', <String>[trimmed]);
        }
      } else {
        final target = directory.existsSync()
            ? trimmed
            : (revealInFolder ? file.parent.path : trimmed);
        await Process.start('xdg-open', <String>[target]);
      }

      bannerMessage = revealInFolder
          ? 'Opened file location for $trimmed.'
          : 'Opened $trimmed.';
      _addEvent(
        level: 'INFO',
        category: 'Files',
        message: bannerMessage!,
        source: 'files',
      );
      notifyListeners();
    } catch (error) {
      showBannerMessage(
        'Unable to open $trimmed: $error',
        category: 'Files',
        source: 'files',
      );
    }
  }

  void clearBanner() {
    bannerMessage = null;
    bannerTaskId = null;
    notifyListeners();
  }

  void clearEventLog() {
    eventLog = const [];
    notifyListeners();
  }

  late final ObjectQuery _objectQuery = ObjectQuery((error) {
    objectFilterError = error;
    notifyListeners();
  });
  bool get filteringObjects => _objectQuery.loading;
  List<ObjectEntry> get visibleObjects => _objectQuery.resolve(
      objects,
      objectFilterMode,
      objectFilterValue,
      objectSortField,
      objectSortDescending);

  List<ObjectEntry> get pagedVisibleObjects {
    final results = visibleObjects;
    if (showAllObjects || results.length <= objectPageSize) {
      return results;
    }
    final safePage = objectPage.clamp(1, objectPageCount).toInt();
    final start = (safePage - 1) * objectPageSize;
    final end = (start + objectPageSize).clamp(0, results.length).toInt();
    return results.sublist(start, end);
  }

  int get objectPageCount {
    final count = visibleObjects.length;
    if (count <= objectPageSize) {
      return 1;
    }
    return (count / objectPageSize).ceil();
  }

  int get currentObjectPageStart {
    final count = visibleObjects.length;
    if (count == 0) {
      return 0;
    }
    if (showAllObjects || count <= objectPageSize) {
      return 1;
    }
    final safePage = objectPage.clamp(1, objectPageCount).toInt();
    return ((safePage - 1) * objectPageSize) + 1;
  }

  int get currentObjectPageEnd {
    final count = visibleObjects.length;
    if (count == 0) {
      return 0;
    }
    if (showAllObjects || count <= objectPageSize) {
      return count;
    }
    return (currentObjectPageStart + objectPageSize - 1)
        .clamp(0, count)
        .toInt();
  }

  List<ObjectVersionEntry> get visibleVersions {
    var results = versions;
    final filterValue = versionBrowserOptions.filterValue.trim();
    if (filterValue.isNotEmpty) {
      if (versionBrowserOptions.filterMode == BrowserFilterMode.regex) {
        try {
          final regex = RegExp(filterValue, caseSensitive: false);
          results = results
              .where(
                (item) =>
                    regex.hasMatch(item.key) || regex.hasMatch(item.versionId),
              )
              .toList();
        } catch (_) {
          results = versions;
        }
      } else if (versionBrowserOptions.filterMode == BrowserFilterMode.prefix) {
        results =
            results.where((item) => item.key.startsWith(filterValue)).toList();
      } else {
        final query = filterValue.toLowerCase();
        results = results.where((item) {
          return item.key.toLowerCase().contains(query) ||
              item.versionId.toLowerCase().contains(query);
        }).toList();
      }
    }
    results = results.where((item) {
      if (!versionBrowserOptions.showDeleteMarkers && item.deleteMarker) {
        return false;
      }
      if (!versionBrowserOptions.showVersions && !item.deleteMarker) {
        return false;
      }
      return true;
    }).toList();
    return results;
  }

  int get displayedVersionCount => visibleVersions.length;
  int get visibleDeleteMarkerCount =>
      visibleVersions.where((item) => item.deleteMarker).length;

  List<EventLogEntry>? _bucketScopedEventsCache;
  List<EventLogEntry>? _bucketScopedEventsInputLog;
  int _bucketScopedEventsInputLogLength = -1;
  String? _bucketScopedEventsInputProfileId;
  String? _bucketScopedEventsInputBucketName;

  List<EventLogEntry> get bucketScopedEvents {
    final profileId = selectedProfile?.id;
    final bucketName = selectedBucket?.name;
    if (_bucketScopedEventsCache != null &&
        identical(_bucketScopedEventsInputLog, eventLog) &&
        _bucketScopedEventsInputLogLength == eventLog.length &&
        _bucketScopedEventsInputProfileId == profileId &&
        _bucketScopedEventsInputBucketName == bucketName) {
      return _bucketScopedEventsCache!;
    }
    final results = eventLog.where((entry) {
      if (profileId != null && entry.profileId != profileId) {
        return false;
      }
      if (bucketName != null && entry.bucketName != bucketName) {
        return false;
      }
      return entry.bucketName != null;
    }).toList();
    _bucketScopedEventsCache = results;
    _bucketScopedEventsInputLog = eventLog;
    _bucketScopedEventsInputLogLength = eventLog.length;
    _bucketScopedEventsInputProfileId = profileId;
    _bucketScopedEventsInputBucketName = bucketName;
    return results;
  }

  final Map<String, Future<void> Function()> _retryTransfers = {};
  bool canRetryTask(BrowserTaskRecord task) =>
      task.isFailedLike &&
      _retryTransfers.containsKey(task.id) &&
      task.profileId == selectedProfile?.id &&
      task.bucketName == selectedBucket?.name;
  Future<void> retryTask(BrowserTaskRecord task) async {
    if (!canRetryTask(task) || isBusy('retry-${task.id}')) return;
    await _runBusy('retry-${task.id}', 'Retrying ${task.label}...', () async {
      final before = browserTasks.map((t) => t.id).toSet();
      await _retryTransfers[task.id]!();
      final next = browserTasks
          .where((t) =>
              t.kind == BrowserTaskKind.transfer && !before.contains(t.id))
          .firstOrNull;
      if (next != null) {
        _upsertTask(task.copyWith(
            outputLines: [...task.outputLines, 'Retried as ${next.id}']));
      }
    }, trackTask: false);
  }

  void clearFinishedTasks() {
    final removed = browserTasks
        .where((t) => [
              'completed',
              'failed',
              'cancelled',
              'canceled',
              'error',
              'stopped'
            ].contains(t.status))
        .map((t) => t.id)
        .toSet();
    browserTasks = browserTasks.where((t) => !removed.contains(t.id)).toList();
    transferJobs = transferJobs.where((t) => !removed.contains(t.id)).toList();
    for (final id in removed) {
      _retryTransfers.remove(id);
    }
    if (removed.contains(selectedTaskId)) selectedTaskId = null;
    notifyListeners();
  }

  List<BrowserTaskRecord> tasksForView(BrowserTaskView view) {
    switch (view) {
      case BrowserTaskView.running:
        return browserTasks.where((task) => task.isRunningLike).toList();
      case BrowserTaskView.failed:
        return browserTasks.where((task) => task.isFailedLike).toList();
      case BrowserTaskView.all:
        return browserTasks;
    }
  }

  void setTaskView(BrowserTaskView view) {
    if (taskView == view) {
      return;
    }
    taskView = view;
    notifyListeners();
  }

  void selectTask(String taskId) {
    selectedTaskId = taskId;
    notifyListeners();
  }

  void openBannerTask() {
    final taskId = bannerTaskId;
    if (taskId == null) {
      return;
    }
    final task = _taskById(taskId);
    if (task == null) {
      return;
    }
    selectedTaskId = task.id;
    taskView = task.isRunningLike
        ? BrowserTaskView.running
        : task.isFailedLike
            ? BrowserTaskView.failed
            : BrowserTaskView.all;
    activeTab = WorkspaceTab.tasks;
    _addEvent(
      level: 'INFO',
      category: 'Navigation',
      message: 'Opened task ${task.label}.',
      source: 'task-tray',
    );
    notifyListeners();
  }

  BrowserTaskRecord? get bannerTask {
    final taskId = bannerTaskId;
    return taskId == null ? null : _taskById(taskId);
  }

  String get benchmarkExportSummary {
    final run = selectedBenchmarkRun;
    if (run == null) {
      return 'No benchmark export available.';
    }
    return '${run.config.csvOutputPath}, ${run.config.jsonOutputPath}, ${run.config.logFilePath}';
  }

  double get benchmarkProgress {
    final run = benchmarkRun;
    if (run == null) {
      return 0;
    }
    return _benchmarkProgressForRun(run);
  }

  BenchmarkRun? get selectedBenchmarkRun {
    final selectedId = selectedBenchmarkRunId;
    if (selectedId != null) {
      for (final run in benchmarkHistory) {
        if (run.id == selectedId) {
          return run;
        }
      }
      if (benchmarkRun?.id == selectedId) {
        return benchmarkRun;
      }
    }
    return benchmarkRun ??
        (benchmarkHistory.isEmpty ? null : benchmarkHistory.first);
  }

  BenchmarkResultSummary? benchmarkSummaryForRun(BenchmarkRun? run) {
    if (run == null) {
      return null;
    }
    return run.resultSummary;
  }

  Map<String, int> benchmarkOperationsForRun(BenchmarkRun? run) {
    return benchmarkSummaryForRun(run)?.operationsByType ??
        const <String, int>{};
  }

  String benchmarkActivityForRun(BenchmarkRun? run) {
    if (run == null) {
      return 'No benchmark is running.';
    }
    final operations = benchmarkOperationsForRun(run);
    if (operations.isEmpty) {
      return 'Preparing benchmark workload...';
    }
    final breakdown = ['PUT', 'GET', 'DELETE']
        .where((operation) => operations.containsKey(operation))
        .map((operation) => '$operation ${operations[operation]}')
        .join(' - ');
    return switch (run.status) {
      'completed' => 'Completed workload: $breakdown',
      'stopped' => 'Stopped after: $breakdown',
      'paused' => 'Paused with: $breakdown',
      _ => 'Current workload: $breakdown',
    };
  }

  /// Wall-clock throughput cross-check: processedCount ÷ elapsed seconds.
  /// This is a conservative measurement that may be lower than the engine-
  /// reported value because it includes connection warm-up and queuing time.
  double wallClockThroughputForRun(BenchmarkRun run) {
    final elapsedMs = run.activeElapsedSeconds != null
        ? run.activeElapsedSeconds! * 1000.0
        : DateTime.now().difference(run.startedAt).inMilliseconds.toDouble();
    if (elapsedMs <= 0) return 0;
    return run.processedCount / (elapsedMs / 1000.0);
  }

  /// Estimated data throughput in MiB/s based on engine ops/s and average
  /// configured object size.
  double estimatedMibsForRun(BenchmarkRun run) {
    if (run.config.objectSizes.isEmpty) return 0;
    final avgBytes = run.config.objectSizes.reduce((a, b) => a + b) /
        run.config.objectSizes.length;
    return (run.throughputOpsPerSecond * avgBytes) / (1024 * 1024);
  }

  void selectBenchmarkRun(String runId) {
    selectedBenchmarkRunId = runId;
    notifyListeners();
  }

  String _engineLabel(String engineId) {
    return engines.firstWhere((engine) => engine.id == engineId).label;
  }

  Future<void> _loadSelectionArtifacts(
      {bool cancellableListing = false}) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final object = selectedObject;
    if (profile == null || bucket == null) {
      versions = const [];
      versionCursor = const ListCursor(value: null, hasMore: false);
      selectedObjectDetails = null;
      selectedObjectPreview = null;
      notifyListeners();
      return;
    }
    Future<T> read<T>(Future<T> Function() request) =>
        cancellableListing ? _awaitListing(request) : request();
    final versionResult = await read(() => _engineService.listObjectVersions(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          key: object?.key,
          options: versionBrowserOptions,
        ));
    versions = versionResult.items;
    versionCursor = versionResult.cursor;
    if (object == null) {
      selectedObjectDetails = null;
      selectedObjectPreview = null;
      _addEvent(
        level: 'INFO',
        category: 'Versions',
        message:
            'Loaded ${versions.length} version entries for bucket ${bucket.name}.',
        includeSelectionContext: true,
        source: 'version-browser',
      );
      notifyListeners();
      return;
    }
    selectedObjectDetails = await read(() => _engineService.getObjectDetails(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          key: object.key,
        ));
    _primeSelectedObjectPreview(object, notify: false);
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message:
          'Loaded ${versions.length} version entries and object details for ${object.key}.',
      includeSelectionContext: true,
      objectKey: object.key,
      source: 'events-and-debug',
    );
    notifyListeners();
  }

  void _primeSelectedObjectPreview(
    ObjectEntry object, {
    bool notify = true,
  }) {
    final contentType = _objectContentType(object);
    final kind = _previewKindFor(object, contentType);
    _previewRequestSequence += 1;
    final requestId = _previewRequestSequence;
    if (object.isFolder) {
      selectedObjectPreview = ObjectPreview.unsupported(
        key: object.key,
        contentType: contentType,
      );
    } else if (kind == ObjectPreviewKind.unsupported) {
      selectedObjectPreview = ObjectPreview.unsupported(
        key: object.key,
        contentType: contentType,
      );
    } else if (kind == ObjectPreviewKind.image &&
        object.size > objectPreviewImageMaxBytes) {
      selectedObjectPreview = ObjectPreview.unsupported(
        key: object.key,
        contentType: contentType,
        message: 'Not supported. Image is too large for inline preview.',
      );
    } else {
      selectedObjectPreview = ObjectPreview.loading(
        key: object.key,
        kind: kind,
        contentType: contentType,
      );
      unawaited(_loadObjectPreview(object, kind, contentType, requestId));
    }
    if (notify) {
      notifyListeners();
    }
  }

  ObjectPreviewKind _previewKindFor(ObjectEntry object, String contentType) {
    final normalizedType = contentType.toLowerCase();
    final key = object.key.toLowerCase();
    if (normalizedType.startsWith('image/')) {
      return ObjectPreviewKind.image;
    }
    if (normalizedType.startsWith('video/') ||
        key.endsWith('.avi') ||
        key.endsWith('.mkv')) {
      return ObjectPreviewKind.video;
    }
    if (normalizedType.startsWith('text/') ||
        normalizedType == 'application/json' ||
        normalizedType == 'application/xml' ||
        normalizedType == 'application/x-yaml' ||
        key.endsWith('.jsonl') ||
        isCodePreview(key, contentType)) {
      return ObjectPreviewKind.text;
    }
    return ObjectPreviewKind.unsupported;
  }

  Future<void> _loadObjectPreview(
    ObjectEntry object,
    ObjectPreviewKind kind,
    String contentType,
    int requestId,
  ) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    if (profile == null || bucket == null) {
      return;
    }
    try {
      final expirationMinutes =
          settings.defaultPresignMinutes.clamp(1, 15).toInt();
      final url = await _engineService.generatePresignedUrl(
        engineId: activeEngineId,
        profile: profile,
        bucketName: bucket.name,
        key: object.key,
        expiration: Duration(minutes: expirationMinutes),
      );
      if (!_isCurrentPreviewRequest(object.key, requestId)) {
        return;
      }
      if (kind == ObjectPreviewKind.text) {
        final preview = await _fetchPreviewText(url);
        if (!_isCurrentPreviewRequest(object.key, requestId)) {
          return;
        }
        selectedObjectPreview = ObjectPreview.ready(
          key: object.key,
          kind: kind,
          contentType: contentType,
          url: url,
          text: preview.text,
          truncated: preview.truncated,
          loadedBytes: preview.loadedBytes,
          message: preview.truncated
              ? 'Showing the first ${preview.loadedBytes} bytes.'
              : 'Preview loaded.',
        );
      } else {
        selectedObjectPreview = ObjectPreview.ready(
          key: object.key,
          kind: kind,
          contentType: contentType,
          url: url,
          message: kind == ObjectPreviewKind.video
              ? 'Video preview link generated.'
              : 'Preview loaded.',
        );
      }
    } catch (error) {
      if (!_isCurrentPreviewRequest(object.key, requestId)) {
        return;
      }
      selectedObjectPreview = ObjectPreview.unsupported(
        key: object.key,
        contentType: contentType,
      );
      _addEvent(
        level: 'WARN',
        category: 'Objects',
        message: 'Object preview is not supported for ${object.key}: $error',
        includeSelectionContext: true,
        objectKey: object.key,
        source: 'object-preview',
      );
    }
    notifyListeners();
  }

  bool _isCurrentPreviewRequest(String key, int requestId) {
    return _previewRequestSequence == requestId && selectedObject?.key == key;
  }

  Future<_TextPreviewResult> _fetchPreviewText(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw const FormatException('Invalid preview URL.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-${objectPreviewTextByteLimit - 1}',
      );
      final response = await request.close().timeout(
            const Duration(seconds: 15),
          );
      final bytes = <int>[];
      await for (final chunk in response) {
        final remaining = objectPreviewTextByteLimit - bytes.length;
        if (remaining <= 0) {
          break;
        }
        bytes.addAll(chunk.take(remaining));
        if (bytes.length >= objectPreviewTextByteLimit) {
          break;
        }
      }
      final contentLength = response.contentLength;
      final truncated = bytes.length >= objectPreviewTextByteLimit ||
          response.statusCode == HttpStatus.partialContent ||
          (contentLength > bytes.length && contentLength != -1);
      return _TextPreviewResult(
        text: const Utf8Decoder(allowMalformed: true).convert(bytes),
        truncated: truncated,
        loadedBytes: bytes.length,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _guard(
    String category,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } on ListingCancelled {
      if (ActionScope.current != null) {
        ActionScope.current!.cancel();
        bannerMessage = _isListingActionKey(_busyTaskIds.entries
                    .where((e) => _actionScopes[e.value] == ActionScope.current)
                    .firstOrNull
                    ?.key ??
                '')
            ? 'Listing cancelled. Keeping the results already loaded.'
            : 'Action stopped. Completed work is retained.';
      } else {
        _listingCancelled = true;
        _showListingCancelled();
      }
      notifyListeners();
    } on EngineException catch (error) {
      _guardErrorSequence += 1;
      bannerMessage = '${error.code.displayLabel}: ${error.message}';
      bannerSeverity = BannerSeverity.error;
      _addEvent(
        level: 'ERROR',
        category: category,
        message: '${error.code.name}: ${error.message}',
        includeSelectionContext: true,
        source: 'error',
      );
      notifyListeners();
    } catch (error) {
      _guardErrorSequence += 1;
      bannerMessage = error.toString();
      bannerSeverity = BannerSeverity.error;
      _addEvent(
        level: 'ERROR',
        category: category,
        message: error.toString(),
        includeSelectionContext: true,
        source: 'error',
      );
      notifyListeners();
    }
  }

  Future<void> _runBusy(
      String actionKey, String busyMessage, Future<void> Function() operation,
      {bool trackTask = true}) async {
    // Guard against the same action running twice concurrently. There is no
    // handle to await the in-flight run, so short-circuiting is the safe UX:
    // it avoids double execution and never clobbers the shared busy
    // bookkeeping (_busyActions / _busyTaskIds) for this key mid-flight.
    // Cancellation of an in-flight listing remains robust via the listing
    // generation token, so a superseding run can never undo a cancel.
    if (_busyActions.contains(actionKey)) {
      _debug(
        category: 'Action',
        message: 'Skipped duplicate action $actionKey; already in progress.',
      );
      return;
    }
    final taskId = _nextTaskId(actionKey);
    final parentScope = ActionScope.current;
    final scope = ActionScope(engineId: activeEngineId);
    _actionScopes[taskId] = scope;
    final startedAt = DateTime.now();
    final guardMarker = _guardErrorSequence;
    _busyActions.add(actionKey);
    _busyTaskIds[actionKey] = taskId;
    bannerMessage = busyMessage;
    bannerTaskId = trackTask ? taskId : null;
    if (trackTask) {
      _upsertTask(
        BrowserTaskRecord(
          id: taskId,
          kind: BrowserTaskKind.action,
          label: busyMessage,
          status: 'running',
          startedAt: startedAt,
          progress: 0,
          profileId: selectedProfile?.id,
          bucketName: selectedBucket?.name,
          outputLines: <String>[busyMessage],
          workspaceTab: activeTab,
          actionKey: actionKey,
          canCancel: true,
        ),
      );
    }
    _debug(
      category: 'Action',
      message: 'Started action $actionKey: $busyMessage',
    );
    notifyListeners();
    Object? uncaughtError;
    try {
      await scope.run(operation);
    } on ListingCancelled {
      scope.cancel();
    } catch (error) {
      uncaughtError = error;
      rethrow;
    } finally {
      final failed =
          uncaughtError != null || _guardErrorSequence != guardMarker;
      final currentTask = trackTask ? _taskById(taskId) : null;
      if (currentTask != null) {
        final cancelled = scope.isCancelled || scope.listingCancelled;
        if (cancelled &&
            _isListingActionKey(actionKey) &&
            parentScope != null) {
          parentScope.listingCancelled = true;
        }
        final summary = scope.outcomeUnknown
            ? 'Action stopped. A remote change may already have completed; inspect the destination before retrying.'
            : cancelled
                ? 'Cancelled.'
                : failed
                    ? (bannerMessage ?? 'Action failed.')
                    : 'Completed.';
        _upsertTask(
          currentTask.copyWith(
            status: scope.outcomeUnknown
                ? 'unknown'
                : cancelled
                    ? 'cancelled'
                    : failed
                        ? 'failed'
                        : 'completed',
            completedAt: DateTime.now(),
            progress: 1,
            outputLines: <String>[
              ...currentTask.outputLines,
              summary,
            ],
            canCancel: false,
          ),
        );
      }
      _actionScopes.remove(taskId);
      _busyActions.remove(actionKey);
      _busyTaskIds.remove(actionKey);
      if (!failed &&
          bannerSeverity == BannerSeverity.info &&
          !(bannerTask?.isRunningLike ?? false)) {
        if (bannerMessage == busyMessage) {
          bannerMessage = 'Operation completed.';
        }
        bannerSeverity = BannerSeverity.success;
      }
      // Any pending coalesced progress notification is superseded by the
      // notify below; cancelling keeps tests free of stray timers.
      if (_busyActions.isEmpty) {
        _busyLineNotifyTimer?.cancel();
        _busyLineNotifyTimer = null;
      }
      notifyListeners();
    }
  }

  void _appendBusyTaskLine(String actionKey, String line) {
    final taskId = _busyTaskIds[actionKey];
    if (taskId == null) {
      return;
    }
    final task = _taskById(taskId);
    if (task == null) {
      return;
    }
    // Keep only the most recent lines; a long-running listing can otherwise
    // grow a task's output unbounded (mirrors how eventLog is capped).
    final nextLines = <String>[...task.outputLines, line];
    if (nextLines.length > _taskOutputLineLimit) {
      nextLines.removeRange(0, nextLines.length - _taskOutputLineLimit);
    }
    _upsertTask(
      task.copyWith(outputLines: nextLines),
    );
    _notifyBusyLineAppended();
  }

  @override
  void dispose() {
    objectSearchFocus.dispose();
    inspectorToggleRequest.dispose();
    deleteSelectionRequest.dispose();
    _objectQuery.dispose();
    _busyLineNotifyTimer?.cancel();
    shutdownEngines();
    super.dispose();
  }

  /// Releases long-lived engine resources (desktop sidecar processes). Safe to
  /// call multiple times; also invoked on desktop app-exit requests.
  void shutdownEngines() {
    _engineService.shutdown();
  }

  // Progress lines can arrive per listing page; coalesce the resulting
  // listener notifications so large listings don't rebuild the UI per page.
  void _notifyBusyLineAppended() {
    if (_busyLineNotifyTimer?.isActive ?? false) {
      return;
    }
    _busyLineNotifyTimer = Timer(const Duration(milliseconds: 80), () {
      _busyLineNotifyTimer = null;
      notifyListeners();
    });
  }

  bool _isListingActionKey(String actionKey) {
    return actionKey == 'refresh-buckets' || actionKey == 'refresh-objects';
  }

  void _markListingTasksCancelling() {
    final updated = <BrowserTaskRecord>[];
    var changed = false;
    for (final task in browserTasks) {
      if (task.isRunningLike &&
          task.actionKey != null &&
          _isListingActionKey(task.actionKey!)) {
        updated.add(
          task.copyWith(
            status: 'cancelling',
            canCancel: false,
            outputLines: <String>[
              ...task.outputLines,
              'Cancellation requested. Stopping the listing and ignoring late results.',
            ],
          ),
        );
        changed = true;
      } else {
        updated.add(task);
      }
    }
    if (changed) {
      browserTasks = updated;
    }
  }

  Future<File> _writeJsonExport({
    required String prefix,
    required Map<String, Object?> payload,
  }) async {
    await Directory(settings.downloadPath).create(recursive: true);
    final file = File(
      '${settings.downloadPath}${Platform.pathSeparator}$prefix-${DateTime.now().millisecondsSinceEpoch}.json',
    );
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    return file;
  }

  void _addEvent({
    required String level,
    required String category,
    required String message,
    bool includeSelectionContext = false,
    String? profileId,
    String? bucketName,
    String? objectKey,
    String? source,
    String? requestId,
    String? parentRequestId,
    String? tracePhase,
    String? engineId,
    String? method,
    String? responseStatus,
    int? latencyMs,
    Object? traceHead,
    Object? traceBody,
  }) {
    if ((level == 'API' || source == 'api') && !settings.enableApiLogging) {
      return;
    }
    if (level == 'DEBUG' && !settings.enableDebugLogging) {
      return;
    }
    eventLog = [
      EventLogEntry(
        timestamp: DateTime.now(),
        level: level,
        category: category,
        message: DiagnosticSafety.text(message),
        profileId:
            profileId ?? (includeSelectionContext ? selectedProfile?.id : null),
        bucketName: bucketName ??
            (includeSelectionContext ? selectedBucket?.name : null),
        objectKey:
            objectKey ?? (includeSelectionContext ? selectedObject?.key : null),
        source: source,
        requestId: requestId,
        parentRequestId: parentRequestId,
        tracePhase: tracePhase,
        engineId: engineId,
        method: method,
        responseStatus: responseStatus,
        latencyMs: latencyMs,
        traceHead: DiagnosticSafety.sanitize(traceHead),
        traceBody: DiagnosticSafety.sanitize(traceBody),
      ),
      ...eventLog,
    ];
    // Keep the in-memory event log bounded; long sessions with API tracing
    // enabled would otherwise grow without limit.
    if (eventLog.length > eventLogLimit) {
      eventLog = eventLog.sublist(0, eventLogLimit);
    }
  }

  void _debug({
    required String category,
    required String message,
  }) {
    _addEvent(
      level: 'DEBUG',
      category: category,
      message: message,
      source: 'debug',
    );
  }

  void _attachEngineLogSink() {
    if (_engineLogSinkAttached || _engineService is! EngineLogSinkRegistrant) {
      return;
    }
    final registrant = _engineService as EngineLogSinkRegistrant;
    registrant.setLogSink((entry) {
      _addEvent(
        level: entry.level,
        category: entry.category,
        message: entry.message,
        profileId: entry.profileId,
        bucketName: entry.bucketName,
        objectKey: entry.objectKey,
        source: entry.source,
        requestId: entry.requestId,
        tracePhase: entry.tracePhase,
        engineId: entry.engineId,
        method: entry.method,
        responseStatus: entry.responseStatus,
        latencyMs: entry.latencyMs,
        traceHead: entry.traceHead,
        traceBody: entry.traceBody,
      );
      notifyListeners();
    });
    _engineLogSinkAttached = true;
  }

  Future<void> deleteSelectedBucket() async {
    final bucket = selectedBucket;
    if (bucket == null) {
      return;
    }
    await deleteBucketByName(bucket.name);
  }

  Future<void> deleteBucketByName(
    String bucketName, {
    bool force = false,
  }) async {
    final profile = selectedProfile;
    final bucket = _bucketByName(bucketName);
    if (profile == null || bucket == null) {
      return;
    }
    await _runBusy(
      force ? 'force-delete-bucket' : 'delete-bucket',
      force
          ? 'Force deleting bucket ${bucket.name}...'
          : 'Deleting bucket ${bucket.name}...',
      () async {
        await _guard('Buckets', () async {
          try {
            if (force) {
              await _forceDeleteBucketContents(bucket.name);
            }
            await _engineService.deleteBucket(
              engineId: activeEngineId,
              profile: profile,
              bucketName: bucket.name,
            );
          } on EngineException catch (error) {
            if (!force && _isBucketNotEmpty(error)) {
              bannerMessage =
                  'Bucket ${bucket.name} is not empty. Use Force delete to clear objects first.';
              _addEvent(
                level: 'WARN',
                category: 'Buckets',
                message:
                    'Delete bucket ${bucket.name} was blocked because the bucket is not empty.',
                profileId: profile.id,
                bucketName: bucket.name,
                source: 'bucket-admin',
              );
              notifyListeners();
              return;
            }
            rethrow;
          }
          buckets = buckets.where((item) => item.name != bucket.name).toList();
          selectedBucket = buckets.isEmpty ? null : buckets.first;
          adminState = null;
          bannerMessage = 'Deleted bucket ${bucket.name}.';
          _addEvent(
            level: 'INFO',
            category: 'Buckets',
            message: 'Deleted bucket ${bucket.name}.',
            includeSelectionContext: true,
            bucketName: bucket.name,
            source: 'bucket-admin',
          );
          if (selectedBucket != null) {
            await refreshObjects();
            await refreshBucketAdminState();
          } else {
            objects = const [];
            versions = const [];
            selectedObject = null;
            selectedObjectDetails = null;
            selectedObjectPreview = null;
            currentPrefix = '';
            _syncObjectFilterWithPrefix();
            notifyListeners();
          }
        });
      },
    );
  }

  Future<void> refreshBucketAdminState(
      {bool cancellableListing = false}) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    if (profile == null || bucket == null) {
      adminState = null;
      notifyListeners();
      return;
    }
    await _runBusy('refresh-bucket-admin', 'Loading bucket admin state...',
        () async {
      await _guard('Buckets', () async {
        Future<BucketAdminState> request() =>
            _engineService.getBucketAdminState(
              engineId: activeEngineId,
              profile: profile,
              bucketName: bucket.name,
            );
        adminState =
            cancellableListing ? await _awaitListing(request) : await request();
        notifyListeners();
      });
    });
  }

  Future<void> setBucketVersioning(bool enabled) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    if (profile == null || bucket == null) {
      return;
    }
    await _runBusy('bucket-versioning', 'Updating bucket versioning...',
        () async {
      await _guard('Buckets', () async {
        adminState = await _engineService.setBucketVersioning(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          enabled: enabled,
        );
        _addEvent(
          level: 'INFO',
          category: 'Buckets',
          message:
              'Set bucket versioning for ${bucket.name} to ${enabled ? 'enabled' : 'suspended'}.',
          includeSelectionContext: true,
          source: 'bucket-admin',
        );
        notifyListeners();
      });
    });
  }

  Future<void> saveBucketPolicy(String policyJson) async {
    await _mutateBucketAdmin(
      actionKey: 'bucket-policy',
      busyMessage: 'Saving bucket policy...',
      operation: (profile, bucket) => _engineService.putBucketPolicy(
        engineId: activeEngineId,
        profile: profile,
        bucketName: bucket.name,
        policyJson: policyJson,
      ),
    );
  }

  Future<void> saveBucketLifecycle(String lifecycleJson) async {
    await _mutateBucketAdmin(
      actionKey: 'bucket-lifecycle',
      busyMessage: 'Saving lifecycle configuration...',
      operation: (profile, bucket) => _engineService.putBucketLifecycle(
        engineId: activeEngineId,
        profile: profile,
        bucketName: bucket.name,
        lifecycleJson: lifecycleJson,
      ),
    );
  }

  Future<void> saveBucketCors(String corsJson) async {
    await _mutateBucketAdmin(
      actionKey: 'bucket-cors',
      busyMessage: 'Saving CORS configuration...',
      operation: (profile, bucket) => _engineService.putBucketCors(
        engineId: activeEngineId,
        profile: profile,
        bucketName: bucket.name,
        corsJson: corsJson,
      ),
    );
  }

  Future<void> saveBucketEncryption(String encryptionJson) async {
    await _mutateBucketAdmin(
      actionKey: 'bucket-encryption',
      busyMessage: 'Saving encryption configuration...',
      operation: (profile, bucket) => _engineService.putBucketEncryption(
        engineId: activeEngineId,
        profile: profile,
        bucketName: bucket.name,
        encryptionJson: encryptionJson,
      ),
    );
  }

  Future<void> saveBucketTags(Map<String, String> tags) async {
    await _mutateBucketAdmin(
      actionKey: 'bucket-tags',
      busyMessage: 'Saving bucket tags...',
      operation: (profile, bucket) => _engineService.putBucketTagging(
        engineId: activeEngineId,
        profile: profile,
        bucketName: bucket.name,
        tags: tags,
      ),
    );
  }

  Future<void> copyBucketContents({
    required String sourceBucketName,
    required String destinationBucketName,
    bool createDestinationIfMissing = false,
  }) async {
    final profile = selectedProfile;
    if (profile == null) {
      return;
    }
    final trimmedDestination = destinationBucketName.trim();
    if (trimmedDestination.isEmpty || trimmedDestination == sourceBucketName) {
      bannerMessage = 'Choose a different destination bucket.';
      notifyListeners();
      return;
    }
    await _runBusy(
      'copy-bucket',
      'Copying bucket $sourceBucketName to $trimmedDestination...',
      () async {
        await _guard('Buckets', () async {
          var destinationBucket = _bucketByName(trimmedDestination);
          if (destinationBucket == null && createDestinationIfMissing) {
            destinationBucket = await _engineService.createBucket(
              engineId: activeEngineId,
              profile: profile,
              bucketName: trimmedDestination,
              enableVersioning: false,
              enableObjectLock: false,
            );
            buckets = [
              destinationBucket,
              ...buckets
                  .where((bucket) => bucket.name != destinationBucket!.name),
            ]..sort(
                (left, right) =>
                    left.name.toLowerCase().compareTo(right.name.toLowerCase()),
              );
          }
          if (destinationBucket == null) {
            throw const EngineException(
              code: ErrorCode.invalidConfig,
              message:
                  'Destination bucket does not exist. Create it first or choose Create destination in the dialog.',
            );
          }

          var cursor = const ListCursor(value: null, hasMore: false);
          var copiedCount = 0;
          final failures = <String>[];
          var hasMore = true;
          while (hasMore) {
            final page = await _engineService.listObjects(
              engineId: activeEngineId,
              profile: profile,
              bucketName: sourceBucketName,
              prefix: '',
              flat: true,
              cursor: cursor.value == null && !cursor.hasMore ? null : cursor,
            );
            for (final object in page.items.where((entry) => !entry.isFolder)) {
              try {
                await _engineService.copyObject(
                  engineId: activeEngineId,
                  profile: profile,
                  sourceBucketName: sourceBucketName,
                  sourceKey: object.key,
                  destinationBucketName: trimmedDestination,
                  destinationKey: object.key,
                );
                copiedCount += 1;
              } on EngineException catch (error) {
                failures.add('${object.key}: ${error.message}');
              }
            }
            cursor = page.cursor;
            hasMore = page.cursor.hasMore;
          }
          bannerMessage = failures.isEmpty
              ? 'Copied $copiedCount objects to $trimmedDestination.'
              : 'Copied $copiedCount objects to $trimmedDestination with ${failures.length} failures.';
          _addEvent(
            level: failures.isEmpty ? 'INFO' : 'WARN',
            category: 'Buckets',
            message: failures.isEmpty
                ? 'Copied $copiedCount objects from $sourceBucketName to $trimmedDestination.'
                : 'Copied $copiedCount objects from $sourceBucketName to $trimmedDestination with failures: ${failures.join(' | ')}',
            profileId: profile.id,
            bucketName: sourceBucketName,
            source: 'bucket-admin',
          );
          if (selectedBucket?.name == sourceBucketName) {
            await refreshObjects(prefix: currentPrefix);
          }
        });
      },
    );
  }

  void _replaceTransfer(TransferJob updated) {
    transferJobs = [
      updated,
      ...transferJobs.where((job) => job.id != updated.id),
    ];
  }

  EndpointProfile? _selectBootstrapProfile() {
    if (profiles.isEmpty) {
      return null;
    }
    if (settings.defaultProfileId.isNotEmpty) {
      for (final profile in profiles) {
        if (profile.id == settings.defaultProfileId) return profile;
      }
    }
    if (_initialSelectedProfileId == null) {
      return profiles.first;
    }
    return profiles.firstWhere(
      (profile) => profile.id == _initialSelectedProfileId,
      orElse: () => profiles.first,
    );
  }

  void _syncObjectFilterWithPrefix() {
    if (objectFilterMode == BrowserFilterMode.prefix) {
      objectFilterValue = currentPrefix;
    }
  }

  void _resetObjectPagination() {
    objectPage = 1;
    if (!showAllObjects && visibleObjects.length <= objectPageSize) {
      objectPage = 1;
    }
  }

  Future<bool> _persistState({
    Set<String> explicitProfileIds = const {},
    bool allowCredentialStoreRecovery = false,
  }) async {
    final repository = _appStateRepository;
    if (repository == null) {
      persistenceState.record(false);
      return false;
    }
    final durableProfiles = <EndpointProfile>[
      for (final profile in profiles)
        if (explicitProfileIds.contains(profile.id) ||
            persistenceState.profileSaved(profile.id) != false)
          profile
        else if (_persistedProfiles.containsKey(profile.id))
          _persistedProfiles[profile.id]!,
    ];
    try {
      await repository.saveState(
        settings: settings,
        profiles: durableProfiles,
        selectedProfileId: selectedProfile?.id,
        allowCredentialStoreRecovery: allowCredentialStoreRecovery,
      );
      _persistedProfiles
        ..clear()
        ..addEntries(
            durableProfiles.map((profile) => MapEntry(profile.id, profile)));
      for (final id in explicitProfileIds) {
        persistenceState.recordProfile(id, true);
      }
      persistenceState.record(true);
      return true;
    } on CredentialStoreException catch (error) {
      persistenceState.record(false);
      _credentialStoreError = error.message;
      _addEvent(
        level: 'ERROR',
        category: 'Persistence',
        message: 'Failed to persist application state: $error',
        source: 'persistence',
      );
      return false;
    } catch (error) {
      persistenceState.record(false);
      _addEvent(
        level: 'ERROR',
        category: 'Persistence',
        message: 'Failed to persist application state: $error',
        source: 'persistence',
      );
      return false;
    }
  }

  String _nextTaskId(String prefix) {
    _taskSequence += 1;
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$_taskSequence';
  }

  BrowserTaskRecord? _taskById(String id) {
    for (final task in browserTasks) {
      if (task.id == id) {
        return task;
      }
    }
    return null;
  }

  BucketSummary? _bucketByName(String name) {
    for (final bucket in buckets) {
      if (bucket.name == name) {
        return bucket;
      }
    }
    return null;
  }

  ObjectEntry? _objectByKey(String key) {
    for (final entry in objects) {
      if (entry.key == key) {
        return entry;
      }
    }
    return null;
  }

  void _upsertTask(BrowserTaskRecord task) {
    browserTasks = [
      task,
      ...browserTasks.where((existing) => existing.id != task.id),
    ];
  }

  void _trackTransferJob(TransferJob job) {
    _jobEngineOwners.putIfAbsent(
        job.id, () => ActionScope.current?.engineId ?? activeEngineId);
    final currentTask = _taskById(job.id);
    final now = DateTime.now();
    var rate = currentTask?.bytesPerSecond ?? 0.0;
    final previousTime = currentTask?.sampledAt;
    if (previousTime != null && currentTask?.bytesTransferred != null) {
      final seconds = now.difference(previousTime).inMicroseconds / 1000000;
      final bytes = job.bytesTransferred - currentTask!.bytesTransferred!;
      if (seconds > 0 && bytes >= 0) {
        final sample = bytes / seconds;
        rate = rate == 0 ? sample : rate + (2 / 11) * (sample - rate);
      }
    }
    _upsertTask(
      BrowserTaskRecord(
        id: job.id,
        kind: BrowserTaskKind.transfer,
        label: job.label,
        status: job.status,
        startedAt: currentTask?.startedAt ?? DateTime.now(),
        completedAt:
            ['running', 'queued', 'paused', 'cancelling'].contains(job.status)
                ? null
                : DateTime.now(),
        progress: job.progress,
        bytesPerSecond: rate,
        sampledAt: now,
        profileId: _pendingUploadRelists[job.id]?.profileId ??
            currentTask?.profileId ??
            selectedProfile?.id,
        bucketName: _pendingUploadRelists[job.id]?.bucketName ??
            currentTask?.bucketName ??
            selectedBucket?.name,
        outputLines: job.outputLines,
        bytesTransferred: job.bytesTransferred,
        totalBytes: job.totalBytes,
        strategyLabel: job.strategyLabel,
        currentItemLabel: job.currentItemLabel,
        itemCount: job.itemCount,
        itemsCompleted: job.itemsCompleted,
        partSizeBytes: job.partSizeBytes,
        partsCompleted: job.partsCompleted,
        partsTotal: job.partsTotal,
        canPause: job.canPause,
        canResume: job.canResume,
        canCancel: job.canCancel,
      ),
    );
    if (bannerTaskId == job.id) {
      bannerMessage = _transferBannerMessage(job);
      bannerSeverity = job.status == 'failed'
          ? BannerSeverity.error
          : job.status == 'completed'
              ? BannerSeverity.success
              : BannerSeverity.info;
    }
    notifyListeners();
  }

  String _transferBannerMessage(TransferJob job) {
    final percent = (job.progress.clamp(0, 1) * 100).round();
    final direction = job.direction == 'download' ? 'Download' : 'Upload';
    if (job.status == 'cancelled' || job.status == 'canceled') {
      return '$direction cancelled - $percent%';
    }
    if (job.status == 'cancelling') {
      return 'Stopping $direction after in-flight work - $percent%';
    }
    if (job.status == 'completed') {
      return '$direction complete - 100%';
    }
    if (job.status == 'failed') {
      return '$direction failed - $percent%';
    }
    if (job.status == 'paused') {
      return '$direction paused - $percent%';
    }
    return '$direction in progress - $percent%';
  }

  void _handleTransferJobUpdate(TransferJob job) {
    job = preserveTransferCancellation(
        transferJobs.where((existing) => existing.id == job.id).firstOrNull,
        job);
    if (_uploadBatch?.consume(job) ?? false) return;
    if (_busyActions.contains(job.direction)) {
      bannerTaskId = job.id;
    }
    _replaceTransfer(job);
    _trackTransferJob(job);
    _maybeRelistAfterUpload(job);
  }

  void _maybeRelistAfterUpload(TransferJob job) {
    if (job.direction != 'upload') {
      return;
    }
    final status = job.status.toLowerCase();
    if (status == 'failed' ||
        status == 'error' ||
        status == 'cancelled' ||
        status == 'canceled') {
      _pendingUploadRelists.remove(job.id);
      return;
    }
    if (status != 'completed') {
      return;
    }
    final pending = _pendingUploadRelists.remove(job.id);
    if (pending == null || !settings.relistObjectsAfterMutation) {
      return;
    }
    unawaited(_relistObjectsAfterCompletedUpload(job, pending));
  }

  Future<void> _relistObjectsAfterCompletedUpload(
    TransferJob job,
    _PendingObjectRelist pending,
  ) async {
    if (selectedProfile?.id != pending.profileId ||
        selectedBucket?.name != pending.bucketName) {
      return;
    }
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message:
          'Upload job ${job.id} completed; refreshing object list for prefix "${pending.prefix}".',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    await refreshObjects(prefix: pending.prefix, listAll: pending.listAll);
    bannerMessage = 'Upload complete. Object list refreshed.';
    notifyListeners();
  }

  void _trackBenchmarkRun(BenchmarkRun run, {required String profileId}) {
    selectedBenchmarkRunId ??= run.id;
    final currentTask = _taskById(run.id);
    _upsertTask(
      BrowserTaskRecord(
        id: run.id,
        kind: BrowserTaskKind.benchmark,
        label: 'Benchmark ${run.id}',
        status: run.status,
        startedAt: currentTask?.startedAt ?? run.startedAt,
        completedAt: run.completedAt,
        progress: _benchmarkProgressForRun(run),
        profileId: profileId,
        bucketName: run.config.bucketName,
        outputLines: run.liveLog,
        workspaceTab: WorkspaceTab.benchmark,
        canCancel: run.status == 'running' ||
            run.status == 'paused' ||
            run.status == 'starting',
      ),
    );
  }

  Future<void> _mutateBucketAdmin({
    required String actionKey,
    required String busyMessage,
    required Future<BucketAdminState> Function(
      EndpointProfile profile,
      BucketSummary bucket,
    ) operation,
  }) async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    if (profile == null || bucket == null) {
      return;
    }
    await _runBusy(actionKey, busyMessage, () async {
      await _guard('Buckets', () async {
        adminState = await operation(profile, bucket);
        _addEvent(
          level: 'INFO',
          category: 'Buckets',
          message:
              'Updated ${actionKey.replaceFirst('bucket-', '')} for ${bucket.name}.',
          includeSelectionContext: true,
          source: 'bucket-admin',
        );
        notifyListeners();
      });
    });
  }

  bool _isBucketNotEmpty(EngineException error) {
    final awsCode = error.details?['awsCode']?.toString().toLowerCase();
    final message = error.message.toLowerCase();
    return error.code == ErrorCode.objectConflict ||
        awsCode == 'bucketnotempty' ||
        message.contains('bucketnotempty') ||
        message.contains('not empty');
  }

  Future<void> _forceDeleteBucketContents(String bucketName) async {
    final profile = selectedProfile;
    if (profile == null) {
      return;
    }
    deleteAllConfig = deleteAllConfig.copyWith(bucketName: bucketName);
    deleteAllState = deleteAllState.copyWith(running: true);
    notifyListeners();
    deleteAllState = await _engineService.runDeleteAll(
      engineId: activeEngineId,
      profile: profile,
      config: deleteAllConfig,
    );
    _addEvent(
      level: (deleteAllState.exitCode == null || deleteAllState.exitCode == 0)
          ? 'INFO'
          : 'WARN',
      category: 'Buckets',
      message: deleteAllState.lastStatus,
      profileId: profile.id,
      bucketName: bucketName,
      source: 'bucket-admin',
    );
  }

  String objectContentType(ObjectEntry object) => _objectContentType(object);

  String _objectContentType(ObjectEntry object) {
    if (object.isFolder) {
      return 'inode/directory';
    }
    final key = object.name.toLowerCase();
    if (key.endsWith('.json')) {
      return 'application/json';
    }
    if (key.endsWith('.csv')) {
      return 'text/csv';
    }
    if (key.endsWith('.txt') ||
        key.endsWith('.log') ||
        key.endsWith('.md') ||
        key.endsWith('.yaml') ||
        key.endsWith('.yml')) {
      return 'text/plain';
    }
    if (key.endsWith('.html') || key.endsWith('.htm')) {
      return 'text/html';
    }
    if (key.endsWith('.xml')) {
      return 'application/xml';
    }
    if (key.endsWith('.css')) {
      return 'text/css';
    }
    if (key.endsWith('.js') || key.endsWith('.mjs') || key.endsWith('.jsx')) {
      return 'text/javascript';
    }
    if (key.endsWith('.ts') || key.endsWith('.tsx')) {
      return 'text/typescript';
    }
    if (sourcePreviewLanguage(key, null) != null) {
      return 'text/plain';
    }
    if (key.endsWith('.png')) {
      return 'image/png';
    }
    if (key.endsWith('.jpg') || key.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (key.endsWith('.gif')) {
      return 'image/gif';
    }
    if (key.endsWith('.webp')) {
      return 'image/webp';
    }
    if (key.endsWith('.mp4') || key.endsWith('.m4v')) {
      return 'video/mp4';
    }
    if (key.endsWith('.webm')) {
      return 'video/webm';
    }
    if (key.endsWith('.mov')) {
      return 'video/quicktime';
    }
    if (key.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (key.endsWith('.zip')) {
      return 'application/zip';
    }
    if (key.endsWith('.parquet')) {
      return 'application/parquet';
    }
    return 'application/octet-stream';
  }

  double _benchmarkProgressForRun(BenchmarkRun run) {
    if (run.status == 'completed' || run.status == 'stopped') {
      return 1;
    }
    if (run.status == 'paused' || run.status == 'running') {
      if (run.config.testMode == 'operation-count') {
        return (run.processedCount /
                run.config.operationCount.clamp(1, 1 << 30))
            .clamp(0, 1)
            .toDouble();
      }
      final elapsedSeconds = run.activeElapsedSeconds?.round() ??
          DateTime.now().difference(run.startedAt).inSeconds;
      return (elapsedSeconds / run.config.durationSeconds.clamp(1, 1 << 30))
          .clamp(0, 1)
          .toDouble();
    }
    return 0;
  }
}
