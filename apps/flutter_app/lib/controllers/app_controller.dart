import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/domain_models.dart';
import '../services/app_state_repository.dart';
import '../services/engine_service.dart';

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

class AppController extends ChangeNotifier {
  AppController({
    required EngineService engineService,
    required AppSettings initialSettings,
    required List<EndpointProfile> initialProfiles,
    String? initialSelectedProfileId,
    AppStateRepository? appStateRepository,
  })  : _engineService = engineService,
        _initialSelectedProfileId = initialSelectedProfileId,
        _appStateRepository = appStateRepository,
        settings = initialSettings,
        profiles = initialProfiles.map(normalizeEndpointProfile).toList() {
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
      concurrentThreads: math.max(initialSettings.transferConcurrency * 8, 64),
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
    _syncDiagnosticsOptions();
  }

  final EngineService _engineService;
  final String? _initialSelectedProfileId;
  final AppStateRepository? _appStateRepository;
  int _taskSequence = 0;
  int _guardErrorSequence = 0;
  final Map<String, String> _busyTaskIds = <String, String>{};
  bool _benchmarkPollInFlight = false;
  bool _benchmarkLifecycleActionInFlight = false;
  bool _initializeStarted = false;
  bool _engineLogSinkAttached = false;
  bool _listingCancelled = false;

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
  BenchmarkRun? benchmarkRun;
  EndpointProfile? selectedProfile;
  BucketSummary? selectedBucket;
  ObjectEntry? selectedObject;
  String activeEngineId = 'rust';
  String currentPrefix = '';
  String objectFilterValue = '';
  BrowserFilterMode objectFilterMode = BrowserFilterMode.prefix;
  BrowserObjectSortField objectSortField = BrowserObjectSortField.lastModified;
  bool objectSortDescending = true;
  bool flatView = false;
  static const int objectPageSize = 1000;
  static const int eventLogLimit = 5000;

  Timer? _busyLineNotifyTimer;
  int objectPage = 1;
  bool showAllObjects = false;
  bool listAllKeys = false;
  bool loading = false;
  String? bannerMessage;
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

  /// Requests cancellation of any in-progress listing loop.
  /// The loop will stop after the current page completes and partial results
  /// will be displayed immediately.
  void cancelListing() {
    _listingCancelled = true;
    _markListingTasksCancelling();
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_initializeStarted) {
      return;
    }
    _initializeStarted = true;
    loading = true;
    notifyListeners();
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
    activeEngineId = settings.defaultEngineId;
    _addEvent(
      level: 'INFO',
      category: 'Engine',
      message:
          'Loaded ${engines.length} engine descriptor(s). Active engine is $activeEngineId.',
      source: 'engine',
    );
    if (_engineService.runtimeType.toString().contains('Mock')) {
      _addEvent(
        level: 'WARN',
        category: 'Engine',
        message:
            'The app is currently using the mock engine service. Real S3 bucket and object operations are not wired yet, so button actions only trace local app behavior.',
        source: 'engine',
      );
    }
    if (selectedProfile != null) {
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
    loading = false;
    notifyListeners();
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

  void setInspectorTab(BrowserInspectorTab tab) {
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
        await _persistState();
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
        final previousBucketName = selectedBucket?.name;
        _addEvent(
          level: 'INFO',
          category: 'Buckets',
          message:
              'Listing buckets for profile ${profile.name} on ${profile.endpointUrl} with engine $activeEngineId.',
          profileId: profile.id,
          source: 'bucket-browser',
        );
        if (_listingCancelled) return;
        buckets = await _engineService.listBuckets(
          engineId: activeEngineId,
          profile: profile,
        );
        if (_listingCancelled) {
          _appendBusyTaskLine(
            'refresh-buckets',
            'Bucket listing cancelled by user after the current request completed.',
          );
          return;
        }
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
        await refreshBucketAdminState();
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
      notifyListeners();
      return;
    }
    final nextPrefix = prefix ?? currentPrefix;
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
        _listingCancelled = false;
        final allItems = <ObjectEntry>[];
        var cursor = const ListCursor(value: null, hasMore: false);
        var pageNumber = 0;
        while (true) {
          if (_listingCancelled) {
            _appendBusyTaskLine(
              'refresh-objects',
              'Listing cancelled by user after $pageNumber page(s). Showing ${allItems.length} partial results.',
            );
            break;
          }
          final objectResult = await _engineService.listObjects(
            engineId: activeEngineId,
            profile: profile,
            bucketName: bucket.name,
            prefix: currentPrefix,
            flat: flatView,
            cursor: pageNumber == 0 ? null : cursor,
          );
          pageNumber += 1;
          allItems.addAll(objectResult.items);
          cursor = objectResult.cursor;
          _appendBusyTaskLine(
            'refresh-objects',
            'Fetched page $pageNumber with ${objectResult.items.length} objects.',
          );
          if (!objectResult.cursor.hasMore) {
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
        objects = allItems;
        objectCursor = cursor;
        _resetObjectPagination();
        selectedObject = previousSelectionKey == null
            ? null
            : _objectByKey(previousSelectionKey);
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
        await _loadSelectionArtifacts();
      });
    });
  }

  Future<void> listAllObjectsForCurrentBucket() async {
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
          _listingCancelled = false;
          listAllKeys = true;
          final allItems = objects.toList();
          var cursor = objectCursor;
          var pageNumber = (allItems.length / objectPageSize).ceil();
          while (cursor.hasMore) {
            if (_listingCancelled) {
              _appendBusyTaskLine(
                'refresh-objects',
                'Listing cancelled by user after $pageNumber page(s). Showing ${allItems.length} partial results.',
              );
              break;
            }
            final objectResult = await _engineService.listObjects(
              engineId: activeEngineId,
              profile: profile,
              bucketName: bucket.name,
              prefix: currentPrefix,
              flat: flatView,
              cursor: cursor,
            );
            pageNumber += 1;
            allItems.addAll(objectResult.items);
            cursor = objectResult.cursor;
            _appendBusyTaskLine(
              'refresh-objects',
              'Fetched page $pageNumber with ${objectResult.items.length} objects.',
            );
          }
          objects = allItems;
          objectCursor = cursor;
          _resetObjectPagination();
          selectedObject = previousSelectionKey == null
              ? null
              : _objectByKey(previousSelectionKey);
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
          await _loadSelectionArtifacts();
        });
      },
    );
  }

  Future<void> setSelectedBucket(BucketSummary bucket) async {
    await _runBusy('select-bucket', 'Loading bucket ${bucket.name}...',
        () async {
      selectedBucket = bucket;
      currentPrefix = '';
      _syncObjectFilterWithPrefix();
      selectedObject = null;
      selectedObjectDetails = null;
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
      await refreshBucketAdminState();
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

  Future<void> setSelectedObject(ObjectEntry object) async {
    if (object.isFolder && !flatView) {
      await openFolder(object);
      return;
    }
    await _runBusy(
        'select-object', 'Loading object details for ${object.name}...',
        () async {
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
      await _loadSelectionArtifacts();
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

  Future<void> applyObjectFilter(String value) async {
    objectFilterValue = value;
    objectPage = 1;
    _addEvent(
      level: 'INFO',
      category: 'Objects',
      message:
          'Updated object filter to "$value" in ${objectFilterMode.name} mode.',
      includeSelectionContext: true,
      source: 'object-browser',
    );
    if (objectFilterMode == BrowserFilterMode.prefix) {
      await refreshObjects(prefix: value);
      return;
    }
    notifyListeners();
  }

  void setObjectFilterMode(BrowserFilterMode mode) {
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
        await refreshObjects(prefix: currentPrefix);
      });
    });
  }

  Future<void> deleteSelectedObject() async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final object = selectedObject;
    if (profile == null || bucket == null || object == null) {
      return;
    }
    await _runBusy('delete-object', 'Deleting ${object.name}...', () async {
      await _guard('Objects', () async {
        final result = await _engineService.deleteObjects(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          keys: [object.key],
        );
        bannerMessage = 'Deleted ${result.successCount} objects.';
        _addEvent(
          level: 'INFO',
          category: 'Objects',
          message:
              'Delete request for ${object.key} completed with ${result.successCount} successes and ${result.failureCount} failures.',
          includeSelectionContext: true,
          objectKey: object.key,
          source: 'object-browser',
        );
        objects = objects.where((entry) => entry.key != object.key).toList();
        selectedObject = null;
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
        final job = await _engineService.startUpload(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          prefix: currentPrefix,
          filePaths: filePaths,
          objectKeyByPath: objectKeyByPath,
          multipartThresholdMiB: settings.multipartThresholdMiB,
          multipartChunkMiB: settings.multipartChunkMiB,
        );
        transferJobs = [job, ...transferJobs];
        _trackTransferJob(job);
        bannerTaskId = job.id;
        bannerMessage = _transferBannerMessage(job);
        _addEvent(
          level: 'INFO',
          category: 'Transfers',
          message:
              'Started upload job ${job.id} for ${filePaths.length} file(s) into ${bucket.name}.',
          includeSelectionContext: true,
          source: 'task-tray',
        );
      });
    }, trackTask: false);
  }

  Future<void> startSampleDownload() async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final object = selectedObject;
    if (profile == null || bucket == null || object == null) {
      return;
    }
    await _runBusy('download', 'Starting download...', () async {
      await _guard('Transfers', () async {
        final job = await _engineService.startDownload(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
          keys: [object.key],
          destinationPath: settings.downloadPath,
          multipartThresholdMiB: settings.multipartThresholdMiB,
          multipartChunkMiB: settings.multipartChunkMiB,
        );
        transferJobs = [job, ...transferJobs];
        _trackTransferJob(job);
        bannerTaskId = job.id;
        bannerMessage = _transferBannerMessage(job);
        final destinationLabel =
            Platform.isAndroid ? 'Downloads' : settings.downloadPath;
        _addEvent(
          level: 'INFO',
          category: 'Transfers',
          message:
              'Started download job ${job.id} for ${object.key} into $destinationLabel.',
          includeSelectionContext: true,
          objectKey: object.key,
          source: 'task-tray',
        );
      });
    }, trackTask: false);
  }

  Future<void> pauseTransfer(String jobId) async {
    final job = await _engineService.pauseTransfer(
      engineId: activeEngineId,
      jobId: jobId,
    );
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
  }

  Future<void> resumeTransfer(String jobId) async {
    final job = await _engineService.resumeTransfer(
      engineId: activeEngineId,
      jobId: jobId,
    );
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
  }

  Future<void> cancelTransfer(String jobId) async {
    final job = await _engineService.cancelTransfer(
      engineId: activeEngineId,
      jobId: jobId,
    );
    _replaceTransfer(job);
    _addEvent(
      level: 'INFO',
      category: 'Transfers',
      message: 'Cancelled transfer $jobId.',
      includeSelectionContext: true,
      source: 'task-tray',
    );
    _trackTransferJob(job);
    notifyListeners();
  }

  Future<void> cancelToolTask(BrowserTaskRecord task) async {
    if (task.engineJobId == null) {
      return;
    }
    final state = await _engineService.cancelToolExecution(
      engineId: activeEngineId,
      jobId: task.engineJobId!,
    );
    final taskLabel = _normalizeToolLabel(task.label);
    if (taskLabel == _normalizeToolLabel(putTestDataState.label)) {
      putTestDataState = state;
    } else if (taskLabel == _normalizeToolLabel(deleteAllState.label)) {
      deleteAllState = state;
    }
    _upsertTask(
      task.copyWith(
        status: 'cancelled',
        completedAt: DateTime.now(),
        progress: 1,
        outputLines: state.outputLines,
        canCancel: false,
      ),
    );
    _addEvent(
      level: 'INFO',
      category: 'Tools',
      message: 'Cancelled tool task ${task.label}.',
      includeSelectionContext: true,
      source: 'task-tray',
    );
    notifyListeners();
  }

  Future<void> cancelTask(BrowserTaskRecord task) async {
    if (task.kind == BrowserTaskKind.transfer) {
      await cancelTransfer(task.id);
      return;
    }
    if (task.kind == BrowserTaskKind.tool) {
      await cancelToolTask(task);
      return;
    }
    if (task.kind == BrowserTaskKind.benchmark) {
      if (benchmarkRun?.id == task.id && task.isRunningLike) {
        await stopBenchmark();
      }
      return;
    }
    if (task.actionKey != null && _isListingActionKey(task.actionKey!)) {
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
    await _guard('Tools', () async {
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
          canCancel: putTestDataState.cancellable,
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
    });
  }

  Future<void> runDeleteAllTool() async {
    final profile = selectedProfile;
    if (profile == null) {
      return;
    }
    final taskId = _nextTaskId('delete-all');
    await _guard('Tools', () async {
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
          canCancel: deleteAllState.cancellable,
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
          status:
              (deleteAllState.exitCode == null || deleteAllState.exitCode == 0)
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
    });
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
    benchmarkHistory = [
      optimisticRun,
      ...benchmarkHistory.where((item) => item.id != optimisticId),
    ];
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
      benchmarkHistory = [
        benchmarkRun!,
        ...benchmarkHistory.where((item) => item.id != benchmarkRun!.id),
      ];
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
    benchmarkHistory = [
      benchmarkRun!,
      ...benchmarkHistory.where((item) => item.id != benchmarkRun!.id),
    ];
    bannerMessage = 'Pausing benchmark ${run.id}...';
    notifyListeners();
    _benchmarkLifecycleActionInFlight = true;
    try {
      await _engineService.pauseBenchmark(run.id);
      benchmarkRun = run.copyWith(status: 'paused');
      benchmarkHistory = [
        benchmarkRun!,
        ...benchmarkHistory.where((item) => item.id != benchmarkRun!.id),
      ];
      _addEvent(
        level: 'INFO',
        category: 'Benchmark',
        message: 'Paused benchmark ${run.id}.',
        includeSelectionContext: true,
        source: 'benchmark',
      );
      notifyListeners();
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
    benchmarkHistory = [
      benchmarkRun!,
      ...benchmarkHistory.where((item) => item.id != benchmarkRun!.id),
    ];
    bannerMessage = 'Resuming benchmark ${run.id}...';
    notifyListeners();
    _benchmarkLifecycleActionInFlight = true;
    try {
      await _engineService.resumeBenchmark(run.id);
      benchmarkRun = run.copyWith(status: 'running');
      benchmarkHistory = [
        benchmarkRun!,
        ...benchmarkHistory.where((item) => item.id != benchmarkRun!.id),
      ];
      _addEvent(
        level: 'INFO',
        category: 'Benchmark',
        message: 'Resumed benchmark ${run.id}.',
        includeSelectionContext: true,
        source: 'benchmark',
      );
      notifyListeners();
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
    benchmarkHistory = [
      benchmarkRun!,
      ...benchmarkHistory.where((item) => item.id != benchmarkRun!.id),
    ];
    bannerMessage = 'Stopping benchmark ${run.id}...';
    notifyListeners();
    _benchmarkLifecycleActionInFlight = true;
    try {
      await _engineService.stopBenchmark(run.id);
      benchmarkRun = run.copyWith(
        status: 'stopped',
        completedAt: DateTime.now(),
      );
      benchmarkHistory = [
        benchmarkRun!,
        ...benchmarkHistory.where((item) => item.id != benchmarkRun!.id),
      ];
      _addEvent(
        level: 'INFO',
        category: 'Benchmark',
        message: 'Stopped benchmark ${run.id}.',
        includeSelectionContext: true,
        source: 'benchmark',
      );
      notifyListeners();
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

  Future<void> testProfileById(String profileId) async {
    final profile = normalizeEndpointProfile(
      profiles.firstWhere((item) => item.id == profileId),
    );
    updateProfile(profile);
    await _runBusy('test-profile-${profile.id}',
        'Testing ${profile.name}: validating credentials and listing buckets...',
        () async {
      await _guard('Profiles', () async {
        _addEvent(
          level: 'INFO',
          category: 'Profiles',
          message:
              'Testing endpoint profile ${profile.name} by validating the connection and then listing buckets.',
          profileId: profile.id,
          source: 'profiles',
        );
        await _engineService.testProfile(
            engineId: activeEngineId, profile: profile);
        final foundBuckets = await _engineService.listBuckets(
          engineId: activeEngineId,
          profile: profile,
        );
        if (selectedProfile?.id == profile.id) {
          buckets = foundBuckets;
          selectedBucket = foundBuckets.isEmpty ? null : foundBuckets.first;
          await refreshObjects(prefix: currentPrefix);
        }
        bannerMessage =
            'Endpoint ${profile.name} responded successfully. Bucket list returned ${foundBuckets.length} bucket(s).';
        _addEvent(
          level: foundBuckets.isEmpty ? 'WARN' : 'INFO',
          category: 'Profiles',
          message:
              'Profile ${profile.name} test completed. Bucket list returned ${foundBuckets.length} bucket(s).',
          profileId: profile.id,
          source: 'profiles',
        );
      });
    });
  }

  Future<void> saveProfile(EndpointProfile profile) async {
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
    bannerMessage = 'Saved endpoint profile ${profile.name}.';
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Saved endpoint profile ${profile.name}.',
      profileId: profile.id,
      source: 'profiles',
    );
    await _persistState();
    notifyListeners();
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
      currentPrefix = '';
      _syncObjectFilterWithPrefix();
      if (selectedProfile != null) {
        await refreshCapabilities();
        await refreshBuckets();
      }
    }
    bannerMessage = 'Deleted endpoint profile.';
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Deleted endpoint profile $profileId.',
      profileId: profileId,
      source: 'profiles',
    );
    await _persistState();
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
    await setEngine(engineId);
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
    final importedProfiles = (await repository.importProfiles(path))
        .map(normalizeEndpointProfile)
        .toList();
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
    await _persistState();
    bannerMessage = 'Imported ${importedProfiles.length} profiles.';
    _addEvent(
      level: 'INFO',
      category: 'Profiles',
      message: 'Imported ${importedProfiles.length} profiles from $path.',
      source: 'profiles',
    );
    if (selectedProfile != null) {
      await refreshCapabilities();
      await refreshBuckets();
    } else {
      notifyListeners();
    }
  }

  void showBannerMessage(
    String message, {
    String category = 'App',
    String source = 'app',
  }) {
    bannerMessage = message;
    bannerTaskId = null;
    _addEvent(
      level: 'INFO',
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

  List<ObjectEntry> get visibleObjects {
    List<ObjectEntry> results;
    if (objectFilterMode == BrowserFilterMode.prefix ||
        objectFilterValue.trim().isEmpty) {
      results = objects.toList();
    } else if (objectFilterMode == BrowserFilterMode.regex) {
      try {
        final regex = RegExp(objectFilterValue, caseSensitive: false);
        results = objects.where((entry) => regex.hasMatch(entry.key)).toList();
      } catch (_) {
        results = objects.toList();
      }
    } else {
      final query = objectFilterValue.toLowerCase();
      results = objects
          .where((entry) => entry.key.toLowerCase().contains(query))
          .toList();
    }
    results.sort(_compareObjectsForDisplay);
    return results;
  }

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

  List<EventLogEntry> get bucketScopedEvents {
    final profileId = selectedProfile?.id;
    final bucketName = selectedBucket?.name;
    return eventLog.where((entry) {
      if (profileId != null && entry.profileId != profileId) {
        return false;
      }
      if (bucketName != null && entry.bucketName != bucketName) {
        return false;
      }
      return entry.bucketName != null;
    }).toList();
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
    return run.resultSummary ?? _syntheticBenchmarkSummary(run);
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

  Future<void> _loadSelectionArtifacts() async {
    final profile = selectedProfile;
    final bucket = selectedBucket;
    final object = selectedObject;
    if (profile == null || bucket == null) {
      versions = const [];
      versionCursor = const ListCursor(value: null, hasMore: false);
      selectedObjectDetails = null;
      notifyListeners();
      return;
    }
    final versionResult = await _engineService.listObjectVersions(
      engineId: activeEngineId,
      profile: profile,
      bucketName: bucket.name,
      key: object?.key,
      options: versionBrowserOptions,
    );
    versions = versionResult.items;
    versionCursor = versionResult.cursor;
    if (object == null) {
      selectedObjectDetails = null;
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
    selectedObjectDetails = await _engineService.getObjectDetails(
      engineId: activeEngineId,
      profile: profile,
      bucketName: bucket.name,
      key: object.key,
    );
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

  Future<void> _guard(
    String category,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } on EngineException catch (error) {
      _guardErrorSequence += 1;
      bannerMessage = '${error.code.name}: ${error.message}';
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
    final taskId = _nextTaskId(actionKey);
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
          canCancel: _isListingActionKey(actionKey),
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
      await operation();
    } catch (error) {
      uncaughtError = error;
      rethrow;
    } finally {
      final failed =
          uncaughtError != null || _guardErrorSequence != guardMarker;
      final currentTask = trackTask ? _taskById(taskId) : null;
      if (currentTask != null) {
        final cancelled = _isListingActionKey(actionKey) && _listingCancelled;
        final summary = cancelled
            ? 'Cancelled.'
            : failed
                ? (bannerMessage ?? 'Action failed.')
                : 'Completed.';
        _upsertTask(
          currentTask.copyWith(
            status: cancelled
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
      _busyActions.remove(actionKey);
      _busyTaskIds.remove(actionKey);
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
    _upsertTask(
      task.copyWith(
        outputLines: <String>[
          ...task.outputLines,
          line,
        ],
      ),
    );
    _notifyBusyLineAppended();
  }

  @override
  void dispose() {
    _busyLineNotifyTimer?.cancel();
    super.dispose();
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
              'Cancellation requested. Waiting for the current listing request to finish.',
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
        message: message,
        profileId:
            profileId ?? (includeSelectionContext ? selectedProfile?.id : null),
        bucketName: bucketName ??
            (includeSelectionContext ? selectedBucket?.name : null),
        objectKey:
            objectKey ?? (includeSelectionContext ? selectedObject?.key : null),
        source: source,
        requestId: requestId,
        tracePhase: tracePhase,
        engineId: engineId,
        method: method,
        responseStatus: responseStatus,
        latencyMs: latencyMs,
        traceHead: traceHead,
        traceBody: traceBody,
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
            currentPrefix = '';
            _syncObjectFilterWithPrefix();
            notifyListeners();
          }
        });
      },
    );
  }

  Future<void> refreshBucketAdminState() async {
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
        adminState = await _engineService.getBucketAdminState(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket.name,
        );
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

  Future<void> _persistState() async {
    final repository = _appStateRepository;
    if (repository == null) {
      return;
    }
    try {
      await repository.saveState(
        settings: settings,
        profiles: profiles,
        selectedProfileId: selectedProfile?.id,
      );
    } catch (error) {
      _addEvent(
        level: 'ERROR',
        category: 'Persistence',
        message: 'Failed to persist application state: $error',
        source: 'persistence',
      );
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
    final currentTask = _taskById(job.id);
    _upsertTask(
      BrowserTaskRecord(
        id: job.id,
        kind: BrowserTaskKind.transfer,
        label: job.label,
        status: job.status,
        startedAt: currentTask?.startedAt ?? DateTime.now(),
        completedAt: job.status == 'running' || job.status == 'paused'
            ? null
            : DateTime.now(),
        progress: job.progress,
        profileId: selectedProfile?.id,
        bucketName: selectedBucket?.name,
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
    }
    notifyListeners();
  }

  String _transferBannerMessage(TransferJob job) {
    final percent = (job.progress.clamp(0, 1) * 100).round();
    final direction = job.direction == 'download' ? 'Download' : 'Upload';
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
    if (_busyActions.contains(job.direction)) {
      bannerTaskId = job.id;
    }
    _replaceTransfer(job);
    _trackTransferJob(job);
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

  int _compareObjectsForDisplay(ObjectEntry left, ObjectEntry right) {
    if (left.isFolder != right.isFolder) {
      return left.isFolder ? -1 : 1;
    }
    final multiplier = objectSortDescending ? -1 : 1;
    final comparison = switch (objectSortField) {
      BrowserObjectSortField.lastModified =>
        left.modifiedAt.compareTo(right.modifiedAt),
      BrowserObjectSortField.name =>
        left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      BrowserObjectSortField.size => left.size.compareTo(right.size),
      BrowserObjectSortField.contentType =>
        _objectContentType(left).compareTo(_objectContentType(right)),
    };
    if (comparison != 0) {
      return comparison * multiplier;
    }
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
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
    if (key.endsWith('.txt') || key.endsWith('.log') || key.endsWith('.md')) {
      return 'text/plain';
    }
    if (key.endsWith('.html') || key.endsWith('.htm')) {
      return 'text/html';
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

  BenchmarkResultSummary _syntheticBenchmarkSummary(BenchmarkRun run) {
    final operationsByType = _syntheticBenchmarkOperations(
      run.processedCount,
      run.config.workloadType,
      readPercent: run.config.readPercent,
      writePercent: run.config.writePercent,
      deletePercent: run.config.deletePercent,
    );
    final throughputBase = run.throughputOpsPerSecond == 0
        ? run.config.concurrentThreads * 120
        : run.throughputOpsPerSecond;
    final sampleCount = math.max(12, math.min(36, run.config.durationSeconds));
    final throughputSeries =
        List<Map<String, Object?>>.generate(sampleCount, (index) {
      final second = index + 1;
      final progress =
          sampleCount == 1 ? 1.0 : index / math.max(sampleCount - 1, 1);
      final swing = ((index % 6) - 2.5) * 0.022;
      final opsPerSecond =
          (throughputBase * (0.84 + (progress * 0.22) + swing)).round();
      final averageLatencyMs = run.averageLatencyMs <= 0
          ? 0.0
          : run.averageLatencyMs * (0.88 + (progress * 0.2) + (swing / 2));
      final operations = <String, int>{
        for (final entry in operationsByType.entries)
          entry.key: ((opsPerSecond *
                      (entry.value /
                          math.max(
                            run.processedCount,
                            1,
                          )))
                  .round())
              .clamp(0, opsPerSecond),
      };
      return <String, Object?>{
        'second': second,
        'label': _benchmarkSampleLabel(second),
        'opsPerSecond': opsPerSecond,
        'bytesPerSecond': opsPerSecond * _syntheticAverageObjectSize(run),
        'averageLatencyMs': double.parse(averageLatencyMs.toStringAsFixed(1)),
        'p95LatencyMs':
            double.parse((averageLatencyMs * 1.42).toStringAsFixed(1)),
        'operations': operations,
        'latencyByOperationMs': <String, double>{
          for (final entry in operations.keys)
            entry: double.parse(
              (averageLatencyMs * _syntheticOperationLatencyFactor(entry))
                  .toStringAsFixed(1),
            ),
        },
      };
    });
    final sizeLatencyBuckets = run.config.objectSizes.isEmpty
        ? const <Map<String, Object?>>[]
        : run.config.objectSizes.map((sizeBytes) {
            final latency = run.averageLatencyMs <= 0
                ? 0.0
                : (run.averageLatencyMs *
                    (0.5 + (sizeBytes / run.config.objectSizes.last) * 0.6));
            return <String, Object?>{
              'sizeBytes': sizeBytes,
              'avgLatencyMs': double.parse(latency.toStringAsFixed(1)),
              'p50LatencyMs': double.parse((latency * 0.82).toStringAsFixed(1)),
              'p95LatencyMs': double.parse((latency * 1.18).toStringAsFixed(1)),
              'p99LatencyMs': double.parse((latency * 1.42).toStringAsFixed(1)),
              'count': math.max(
                  1,
                  run.processedCount ~/
                      math.max(
                        run.config.objectSizes.length,
                        1,
                      )),
            };
          }).toList();
    final validated = run.config.validateChecksum ? run.processedCount : 0;
    final latencyPercentilesMs = <String, double>{
      'p50': double.parse((run.averageLatencyMs * 0.75).toStringAsFixed(1)),
      'p75': double.parse((run.averageLatencyMs * 0.9).toStringAsFixed(1)),
      'p90': double.parse((run.averageLatencyMs * 1.04).toStringAsFixed(1)),
      'p95': double.parse((run.averageLatencyMs * 1.15).toStringAsFixed(1)),
      'p99': double.parse((run.averageLatencyMs * 1.45).toStringAsFixed(1)),
      'p999': double.parse((run.averageLatencyMs * 1.7).toStringAsFixed(1)),
    };
    final latencyTimeline = _syntheticLatencyTimeline(
      throughputSeries: throughputSeries,
      operationsByType: operationsByType,
      objectSizes: run.config.objectSizes,
      averageLatencyMs: run.averageLatencyMs,
    );
    return BenchmarkResultSummary(
      totalOperations: run.processedCount,
      operationsByType: operationsByType,
      latencyPercentilesMs: latencyPercentilesMs,
      throughputSeries: throughputSeries,
      sizeLatencyBuckets: sizeLatencyBuckets,
      checksumStats: <String, int>{
        'validated_success': validated,
        'validated_failure': 0,
        'not_used': run.config.validateChecksum ? 0 : run.processedCount,
      },
      detailMetrics: <String, Object?>{
        'sampleCount': sampleCount,
        'sampleWindowSeconds': 1,
        'runMode': run.config.testMode,
        'workloadType': run.config.workloadType,
        'averageOpsPerSecond': double.parse(
            (run.processedCount / math.max(sampleCount, 1)).toStringAsFixed(1)),
        'peakOpsPerSecond': throughputSeries.fold<int>(
          0,
          (current, point) => math.max(
            current,
            (point['opsPerSecond'] as num?)?.toInt() ?? 0,
          ),
        ),
        'averageBytesPerSecond': throughputSeries.isEmpty
            ? 0
            : throughputSeries
                    .map((point) =>
                        (point['bytesPerSecond'] as num?)?.toDouble() ?? 0)
                    .reduce((left, right) => left + right) /
                throughputSeries.length,
        'peakBytesPerSecond': throughputSeries.fold<int>(
          0,
          (current, point) => math.max(
            current,
            (point['bytesPerSecond'] as num?)?.toInt() ?? 0,
          ),
        ),
        'averageObjectSizeBytes': _syntheticAverageObjectSize(run),
        'checksumValidated': validated,
        'errorCount': 0,
        'retryCount': math.max(1, run.processedCount ~/ 180),
        'bucket': run.config.bucketName,
        'prefix': run.config.prefix,
      },
      latencyPercentilesByOperationMs:
          _syntheticLatencyPercentilesByOperation(latencyPercentilesMs),
      operationDetails: _syntheticOperationDetails(
        operationsByType: operationsByType,
        throughputSeries: throughputSeries,
        latencyPercentilesMs: latencyPercentilesMs,
      ),
      latencyTimeline: latencyTimeline,
    );
  }

  List<Map<String, Object?>> _syntheticLatencyTimeline({
    required List<Map<String, Object?>> throughputSeries,
    required Map<String, int> operationsByType,
    required List<int> objectSizes,
    required double averageLatencyMs,
  }) {
    final sizes = objectSizes.isEmpty ? const <int>[1024 * 1024] : objectSizes;
    final operations = operationsByType.keys.toList(growable: false);
    var sequence = 0;
    return throughputSeries.expand((point) {
      final second = (point['second'] as num?)?.toInt() ?? 1;
      final latencyByOperation = Map<String, double>.from(
        ((point['latencyByOperationMs'] as Map?) ?? const <String, Object?>{})
            .map(
          (key, value) => MapEntry(key.toString(), (value as num).toDouble()),
        ),
      );
      final operationCount = operations.length;
      return operations.asMap().entries.map((entry) {
        sequence += 1;
        final operation = entry.value;
        final elapsedSeconds =
            math.max(second - 1, 0) + ((entry.key + 1) / (operationCount + 1));
        final latency = latencyByOperation[operation] ??
            (averageLatencyMs * _syntheticOperationLatencyFactor(operation));
        final sizeBytes = sizes[sequence % sizes.length];
        return <String, Object?>{
          'sequence': sequence,
          'operation': operation,
          'second': second,
          'elapsedMs': double.parse((elapsedSeconds * 1000).toStringAsFixed(1)),
          'label': _benchmarkTimelineLabel(elapsedSeconds),
          'latencyMs': double.parse(latency.toStringAsFixed(1)),
          'sizeBytes': sizeBytes,
        };
      });
    }).toList(growable: false);
  }

  String _benchmarkTimelineLabel(double elapsedSeconds) {
    final fractionDigits = elapsedSeconds >= 100
        ? 0
        : elapsedSeconds >= 10
            ? 1
            : 2;
    return '${elapsedSeconds.toStringAsFixed(fractionDigits)}s';
  }

  int _syntheticAverageObjectSize(BenchmarkRun run) {
    if (run.config.objectSizes.isEmpty) {
      return 1024 * 1024;
    }
    final total = run.config.objectSizes.fold<int>(
      0,
      (current, item) => current + item,
    );
    return (total / run.config.objectSizes.length).round();
  }

  String _benchmarkSampleLabel(int second) {
    if (second < 60) {
      return '${second}s';
    }
    final minutes = second ~/ 60;
    final remainingSeconds = second % 60;
    return '${minutes}m ${remainingSeconds}s';
  }

  Map<String, Map<String, double>> _syntheticLatencyPercentilesByOperation(
    Map<String, double> latencyPercentilesMs,
  ) {
    return <String, Map<String, double>>{
      'PUT': _scalePercentiles(latencyPercentilesMs, 1.18),
      'GET': _scalePercentiles(latencyPercentilesMs, 0.92),
      'DELETE': _scalePercentiles(latencyPercentilesMs, 0.86),
      'POST': _scalePercentiles(latencyPercentilesMs, 1.06),
      'HEAD': _scalePercentiles(latencyPercentilesMs, 0.74),
    };
  }

  Map<String, double> _scalePercentiles(
    Map<String, double> source,
    double factor,
  ) {
    return <String, double>{
      for (final entry in source.entries)
        entry.key: double.parse((entry.value * factor).toStringAsFixed(1)),
    };
  }

  double _syntheticOperationLatencyFactor(String operation) {
    return switch (operation.toUpperCase()) {
      'PUT' => 1.18,
      'GET' => 0.92,
      'DELETE' => 0.86,
      'POST' => 1.06,
      'HEAD' => 0.74,
      _ => 1.0,
    };
  }

  List<Map<String, Object?>> _syntheticOperationDetails({
    required Map<String, int> operationsByType,
    required List<Map<String, Object?>> throughputSeries,
    required Map<String, double> latencyPercentilesMs,
  }) {
    final totalOperations = math.max(
      operationsByType.values.fold<int>(0, (left, right) => left + right),
      1,
    );
    final latencyByOperation =
        _syntheticLatencyPercentilesByOperation(latencyPercentilesMs);
    return operationsByType.entries.map((entry) {
      final averageOpsPerSecond = throughputSeries.isEmpty
          ? 0.0
          : throughputSeries.map((point) {
                final operations =
                    (point['operations'] as Map<String, Object?>?) ??
                        const <String, Object?>{};
                return (operations[entry.key] as num?)?.toDouble() ?? 0;
              }).reduce((left, right) => left + right) /
              throughputSeries.length;
      final peakOpsPerSecond = throughputSeries.fold<double>(
        0,
        (current, point) {
          final operations = (point['operations'] as Map<String, Object?>?) ??
              const <String, Object?>{};
          final value = (operations[entry.key] as num?)?.toDouble() ?? 0;
          return value > current ? value : current;
        },
      );
      return <String, Object?>{
        'operation': entry.key,
        'count': entry.value,
        'sharePct': (entry.value / totalOperations) * 100,
        'avgOpsPerSecond': averageOpsPerSecond,
        'peakOpsPerSecond': peakOpsPerSecond,
        'avgLatencyMs': latencyByOperation[entry.key]?['p75'] ??
            latencyPercentilesMs['p75'],
        'p50LatencyMs': latencyByOperation[entry.key]?['p50'] ??
            latencyPercentilesMs['p50'],
        'p95LatencyMs': latencyByOperation[entry.key]?['p95'] ??
            latencyPercentilesMs['p95'],
        'p99LatencyMs': latencyByOperation[entry.key]?['p99'] ??
            latencyPercentilesMs['p99'],
      };
    }).toList();
  }

  Map<String, int> _syntheticBenchmarkOperations(
    int processedCount,
    String workloadType, {
    int readPercent = 34,
    int writePercent = 33,
    int deletePercent = 33,
  }) {
    if (processedCount <= 0) {
      return const <String, int>{'PUT': 0, 'GET': 0, 'DELETE': 0};
    }
    // Pure workload types.
    if (workloadType == 'write-only') {
      return <String, int>{'PUT': processedCount};
    }
    if (workloadType == 'read-only') {
      return <String, int>{'GET': processedCount};
    }
    // Custom percentage mix.
    if (workloadType == 'custom') {
      final operations = <String, int>{};
      var assigned = 0;
      if (writePercent > 0) {
        final puts = (processedCount * writePercent / 100).floor();
        operations['PUT'] = puts;
        assigned += puts;
      }
      if (readPercent > 0) {
        final gets = (processedCount * readPercent / 100).floor();
        operations['GET'] = gets;
        assigned += gets;
      }
      if (deletePercent > 0) {
        // Give the remainder to DELETE so total always equals processedCount.
        operations['DELETE'] = processedCount - assigned;
      }
      return operations;
    }
    final ratios = switch (workloadType) {
      'write-heavy' => const <String, int>{
          'PUT': 52,
          'GET': 24,
          'DELETE': 8,
          'POST': 16
        },
      'read-heavy' => const <String, int>{
          'PUT': 18,
          'GET': 62,
          'DELETE': 8,
          'POST': 12
        },
      'delete' => const <String, int>{
          'PUT': 0,
          'GET': 0,
          'DELETE': 92,
          'POST': 8
        },
      _ => const <String, int>{'PUT': 31, 'GET': 31, 'DELETE': 22, 'POST': 16},
    };
    final operations = <String, int>{};
    var assigned = 0;
    final keys = ratios.keys.toList();
    for (var index = 0; index < keys.length; index += 1) {
      final key = keys[index];
      final value = index == keys.length - 1
          ? processedCount - assigned
          : ((processedCount * ratios[key]!) / 100).floor();
      operations[key] = value;
      assigned += value;
    }
    return operations;
  }
}
