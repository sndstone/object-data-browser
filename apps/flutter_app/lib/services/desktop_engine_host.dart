import '../controllers/action_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'diagnostic_safety.dart';
import 'listing_cancellation.dart';

class DesktopEngineHostResponse {
  const DesktopEngineHostResponse({
    required this.payload,
    required this.stdoutOutput,
    required this.stderrOutput,
  });

  final Map<String, Object?> payload;
  final String stdoutOutput;
  final String stderrOutput;
}

/// Hosts long-lived sidecar engine processes.
///
/// Engines serve many requests from a single `main()` loop over stdin, so the
/// host keeps processes alive between requests instead of paying process
/// startup on every call. Ordinary work is bounded and exclusive per process.
/// Python/Java control requests bypass the work queue on the job-owning
/// process. Sequential engines must not advertise interactive controls.
class DesktopEngineHost {
  DesktopEngineHost(
      {this.maxProcesses = 4,
      this.maxProcessesPerEngine = 2,
      this.maxQueuedRequests = 64,
      this.requestTimeout = const Duration(minutes: 2),
      this.queueTimeout = const Duration(minutes: 2)});
  final int maxProcesses;
  final int maxProcessesPerEngine;
  final int maxQueuedRequests;
  final Duration requestTimeout;
  final Duration queueTimeout;
  int _active = 0;
  int _starting = 0;
  final Map<String, int> _activeByKey = {};
  final List<_HostWaiter> _waiters = [];
  final Map<String, _EngineProcess> _jobOwners = {};
  final Map<ListingCancellation, _EngineProcess?> _listings = {};
  int get liveProcessCount => _liveProcesses.length;
  int get queuedRequestCount => _waiters.length;

  /// How many idle processes to keep alive per executable+arguments key.
  static const int _maxIdleProcessesPerKey = 2;

  final Map<String, List<_EngineProcess>> _idleProcesses =
      <String, List<_EngineProcess>>{};
  final Set<_EngineProcess> _liveProcesses = <_EngineProcess>{};
  bool _disposed = false;

  Future<DesktopEngineHostResponse> send({
    required String executablePath,
    List<String> arguments = const [],
    String? workingDirectory,
    required Map<String, Object?> request,
    void Function(Map<String, Object?> event)? onEvent,
    bool concurrentControls = false,
    Duration? timeout,
    ListingCancellation? listingCancellation,
  }) async {
    if (_disposed) {
      throw StateError('DesktopEngineHost has been disposed.');
    }
    final key = _processKey(executablePath, arguments, workingDirectory);
    final method = request['method']?.toString() ?? '';
    final jobId = (request['params'] as Map?)?['jobId']?.toString();
    if (jobId != null &&
        {
          'pauseTransfer',
          'resumeTransfer',
          'cancelTransfer',
          'cancelToolExecution'
        }.contains(method)) {
      final owner = _jobOwners['$key/$jobId'];
      if (!concurrentControls || owner == null || owner.isDefunct) {
        throw StateError(
            'No controllable active job $jobId in this engine session.');
      }
      final response = await owner.send(
          request: request, timeout: const Duration(seconds: 15));
      if (response.payload['ok'] == true) {
        owner.setPaused(method == 'pauseTransfer');
      }
      return response;
    }
    final cancellation = listingCancellation ??
        (isCancellableListingMethod(method) ? ListingCancellation() : null);
    final isListing = isCancellableListingMethod(method);
    if (cancellation != null && isListing) _listings[cancellation] = null;
    var entered = false;
    _EngineProcess? acquired;
    try {
      if (cancellation?.isCancelled ?? false) throw const ListingCancelled();
      await _enter(key, method, cancellation);
      entered = true;
      if (cancellation?.isCancelled ?? false) throw const ListingCancelled();
      final process = acquired = await _acquireProcess(
        key: key,
        executablePath: executablePath,
        arguments: arguments,
        workingDirectory: workingDirectory,
      );
      if (cancellation != null && isListing) _listings[cancellation] = process;
      if (cancellation?.isCancelled ?? false) throw const ListingCancelled();
      final pending = process.send(
          request: request,
          timeout: timeout ?? requestTimeout,
          progressDeadline: {
            'startUpload',
            'startDownload',
            'runPutTestData',
            'runDeleteAll'
          }.contains(method),
          onEvent: (event) {
            final job = event['job'];
            final id = job is Map ? job['id']?.toString() : null;
            if (id != null) _jobOwners['$key/$id'] = process;
            if (!concurrentControls && job is Map) {
              event = {
                ...event,
                'job': {
                  ...job,
                  'canPause': false,
                  'canResume': false,
                  'canCancel': false
                }
              };
            }
            onEvent?.call(event);
          });
      final response = cancellation == null
          ? await pending
          : await cancellation.wait(pending);
      if (cancellation?.isCancelled ?? false) throw const ListingCancelled();
      _jobOwners.removeWhere((_, owner) => identical(owner, process));
      _releaseProcess(key, process);
      return response;
    } catch (_) {
      if (cancellation is ActionScope &&
          cancellation.isCancelled &&
          acquired != null &&
          !isListing) {
        cancellation.outcomeUnknown = true;
      }
      // The process can no longer be trusted to pair responses with
      // requests; drop it so the next request respawns a fresh one.
      if (acquired != null) _discardProcess(key, acquired);
      if (cancellation?.isCancelled ?? false) throw const ListingCancelled();
      rethrow;
    } finally {
      if (cancellation != null) _listings.remove(cancellation);
      if (entered) {
        _active--;
        _activeByKey[key] = (_activeByKey[key] ?? 1) - 1;
      }
      _wakeWaiters();
    }
  }

  Future<void> _enter(
      String key, String method, ListingCancellation? cancellation) async {
    if (_waiters.length >= maxQueuedRequests) {
      throw StateError(
          'Engine request queue is full. Wait for active jobs to finish.');
    }
    final waiter = _HostWaiter(key, method);
    _waiters.add(waiter);
    cancellation?.whenCancelled.then((_) {
      if (_waiters.remove(waiter)) {
        waiter.ready.completeError(const ListingCancelled());
        _wakeWaiters();
      }
    });
    _wakeWaiters();
    try {
      await waiter.ready.future.timeout(queueTimeout);
    } catch (_) {
      _waiters.remove(waiter);
      rethrow;
    }
  }

  void cancelQueuedListings() {
    final cancelled = _waiters.where((w) => w.method == 'listObjects').toList();
    for (final waiter in cancelled) {
      _waiters.remove(waiter);
      waiter.ready.completeError(StateError('Queued listing cancelled.'));
    }
  }

  /// Each ordinary request exclusively owns its process, so terminating a
  /// listing cannot kill a transfer running on another process in the pool.
  void cancelListings() {
    for (final entry in _listings.entries.toList()) {
      entry.key.cancel();
      entry.value?.kill();
    }
    for (final waiter in _waiters.toList()) {
      if (!isCancellableListingMethod(waiter.method)) {
        continue;
      }
      _waiters.remove(waiter);
      waiter.ready.completeError(const ListingCancelled());
    }
    _wakeWaiters();
  }

  void _wakeWaiters() {
    if (_disposed) return;
    for (final waiter in List<_HostWaiter>.of(_waiters)) {
      if (_active >= maxProcesses) break;
      if ((_activeByKey[waiter.key] ?? 0) >= maxProcessesPerEngine) continue;
      _waiters.remove(waiter);
      _active++;
      _activeByKey[waiter.key] = (_activeByKey[waiter.key] ?? 0) + 1;
      waiter.ready.complete();
    }
  }

  /// Kills every hosted engine process and rejects future requests.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final waiter in _waiters) {
      waiter.ready
          .completeError(StateError('DesktopEngineHost has been disposed.'));
    }
    _waiters.clear();
    _jobOwners.clear();
    final processes = List<_EngineProcess>.of(_liveProcesses);
    _liveProcesses.clear();
    _idleProcesses.clear();
    for (final process in processes) {
      process.kill();
    }
  }

  static String _processKey(
    String executablePath,
    List<String> arguments,
    String? workingDirectory,
  ) {
    return <String>[
      executablePath,
      ...arguments,
      workingDirectory ?? '',
    ].join('\u0000');
  }

  Future<_EngineProcess> _acquireProcess({
    required String key,
    required String executablePath,
    required List<String> arguments,
    String? workingDirectory,
  }) async {
    final idle = _idleProcesses[key];
    while (idle != null && idle.isNotEmpty) {
      final process = idle.removeLast();
      if (!process.isDefunct) {
        return process;
      }
      _liveProcesses.remove(process);
    }

    // Evict idle processes from other engine keys before starting new work.
    // Active permits are reserved synchronously, including process startup.
    for (final entry in _idleProcesses.entries.toList()) {
      for (final idleProcess in entry.value.toList()) {
        if (_liveProcesses.length + _starting < maxProcesses) break;
        _discardProcess(entry.key, idleProcess);
      }
    }
    _starting++;
    late final _EngineProcess process;
    try {
      process = await _EngineProcess.start(
        executablePath: executablePath,
        arguments: arguments,
        workingDirectory: workingDirectory,
      );
    } finally {
      _starting--;
    }
    process.onDefunct = (defunct) {
      _jobOwners.removeWhere((_, owner) => identical(owner, defunct));
      _liveProcesses.remove(defunct);
      _idleProcesses[key]?.remove(defunct);
    };
    _liveProcesses.add(process);
    if (_disposed) {
      process.kill();
      _liveProcesses.remove(process);
      throw StateError('DesktopEngineHost has been disposed.');
    }
    return process;
  }

  void _releaseProcess(String key, _EngineProcess process) {
    if (_disposed || process.isDefunct) {
      _discardProcess(key, process);
      return;
    }
    final idle = _idleProcesses.putIfAbsent(key, () => <_EngineProcess>[]);
    if (idle.length >= _maxIdleProcessesPerKey) {
      _discardProcess(key, process);
      return;
    }
    idle.add(process);
  }

  void _discardProcess(String key, _EngineProcess process) {
    _jobOwners.removeWhere((_, owner) => identical(owner, process));
    _idleProcesses[key]?.remove(process);
    _liveProcesses.remove(process);
    process.kill();
  }
}

class _HostWaiter {
  _HostWaiter(this.key, this.method);
  final String key;
  final String method;
  final Completer<void> ready = Completer<void>();
}

class _PendingRequest {
  _PendingRequest({this.onEvent, this.progressDeadline = false});

  final bool progressDeadline;

  final void Function(Map<String, Object?> event)? onEvent;
  final Completer<Map<String, Object?>> completer =
      Completer<Map<String, Object?>>();
  final DiagnosticBuffer stdoutLines = DiagnosticBuffer();
  final DiagnosticBuffer stderrLines = DiagnosticBuffer();
  DateTime lastProgress = DateTime.now();
  bool paused = false;
}

class _EngineProcess {
  _EngineProcess._({
    required this.executablePath,
    required this.arguments,
    required Process process,
  }) : _process = process {
    // Swallow late stdin pipe errors (e.g. the engine dying mid-write);
    // failures are surfaced through the per-request flush instead.
    _process.stdin.done.then((_) {}, onError: (_) {});
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleStdoutLine,
          onDone: () =>
              _markDefunct('Engine closed stdout without responding.'),
          onError: (_) =>
              _markDefunct('Engine stdout stream failed unexpectedly.'),
        );
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStderrLine, onError: (_) {});
    _process.exitCode.then((code) {
      _exitCode = code;
      _markDefunct('Engine exited with code $code');
    });
  }

  static Future<_EngineProcess> start({
    required String executablePath,
    required List<String> arguments,
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      executablePath,
      arguments,
      workingDirectory: workingDirectory,
      runInShell:
          Platform.isWindows && executablePath.toLowerCase().endsWith('.bat'),
    );
    return _EngineProcess._(
      executablePath: executablePath,
      arguments: arguments,
      process: process,
    );
  }

  /// Keep only this many stderr lines emitted while no request is in flight.

  /// How long to wait after a response for trailing stderr diagnostics.
  static const Duration _stderrDrainDelay = Duration(milliseconds: 2);

  final String executablePath;
  final List<String> arguments;
  final Process _process;
  final Map<String, _PendingRequest> _pending = <String, _PendingRequest>{};
  final DiagnosticBuffer _idleStderrLines = DiagnosticBuffer();
  void Function(_EngineProcess process)? onDefunct;
  bool _defunct = false;
  int? _exitCode;
  late final StreamSubscription<String> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;

  bool get isDefunct => _defunct;
  void setPaused(bool paused) {
    for (final pending in _pending.values) {
      if (pending.onEvent != null) {
        pending.paused = paused;
        pending.lastProgress = DateTime.now();
      }
    }
  }

  Future<DesktopEngineHostResponse> send({
    required Map<String, Object?> request,
    void Function(Map<String, Object?> event)? onEvent,
    Duration timeout = const Duration(minutes: 2),
    bool progressDeadline = false,
  }) async {
    if (_defunct) {
      throw _defunctException('Engine process is no longer running.');
    }
    final requestId = request['requestId']?.toString() ??
        DateTime.now().microsecondsSinceEpoch.toString();
    final pending =
        _PendingRequest(onEvent: onEvent, progressDeadline: progressDeadline);
    // Attach an error observer before flushing stdin; a process may die or a
    // watchdog may fire before the response await below is reached.
    pending.completer.future.then((_) {}, onError: (Object _) {});
    if (_idleStderrLines.isNotEmpty) {
      pending.stderrLines.addAll(_idleStderrLines.lines);
      _idleStderrLines.clear();
    }
    _pending[requestId] = pending;
    final watchdog = Timer.periodic(
        Duration(milliseconds: (timeout.inMilliseconds ~/ 4).clamp(10, 1000)),
        (_) {
      if (pending.completer.isCompleted ||
          (progressDeadline && pending.paused)) {
        return;
      }
      if (DateTime.now().difference(pending.lastProgress) >= timeout) {
        pending.completer.completeError(TimeoutException(
            'Engine stopped responding. The operation outcome may be unknown; check before retrying.',
            timeout));
        kill();
      }
    });
    try {
      _process.stdin.writeln(jsonEncode(request));
      await _process.stdin.flush().timeout(timeout);
    } catch (error) {
      watchdog.cancel();
      _pending.remove(requestId);
      throw _defunctException('Failed to write request to engine: $error');
    }
    if (_defunct && !pending.completer.isCompleted) {
      // The process died between the liveness check and the write landing.
      _pending.remove(requestId);
      watchdog.cancel();
      throw _defunctException('Engine process exited before responding.');
    }

    try {
      final payload = await pending.completer.future;
      // Give stderr lines flushed alongside the response a chance to arrive
      // so structured engine logs stay attached to the request that caused
      // them. A zero-duration timer can fire before pending pipe reads are
      // delivered, so wait one real event-loop turn.
      await Future<void>.delayed(_stderrDrainDelay);
      return DesktopEngineHostResponse(
        payload: payload,
        stdoutOutput: pending.stdoutLines.join('\n').trim(),
        stderrOutput: pending.stderrLines.join('\n').trim(),
      );
    } finally {
      watchdog.cancel();
      _pending.remove(requestId);
    }
  }

  void kill() {
    _markDefunct('Engine process was shut down.');
    try {
      _process.stdin.close();
    } catch (_) {
      // Closing stdin lets engines exit their read loops gracefully.
    }
    _process.kill();
  }

  void _handleStdoutLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Preserve non-JSON stdout in stdoutOutput for debugging.
      for (final pending in _pending.values) {
        pending.stdoutLines.add(line);
      }
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final message = Map<String, Object?>.from(decoded);
    if (message.containsKey('event')) {
      for (final pending in List<_PendingRequest>.of(_pending.values)) {
        if (pending.onEvent == null) continue;
        if (pending.progressDeadline) pending.lastProgress = DateTime.now();
        final job = message['job'];
        if (job is Map) pending.paused = job['status'] == 'paused';
        pending.onEvent?.call(message);
      }
      return;
    }
    if (!message.containsKey('ok')) {
      return;
    }
    String? targetId;
    final requestId = message['requestId']?.toString();
    if (requestId != null && _pending.containsKey(requestId)) {
      targetId = requestId;
    } else if (requestId == null && _pending.length == 1) {
      // Engines echo the requestId; tolerate a missing one as long as it is
      // unambiguous which request the response belongs to.
      targetId = _pending.keys.first;
    }
    if (targetId == null) {
      return;
    }
    // Leave the entry in _pending so trailing stderr lines keep routing to
    // it; send() removes it once the response has been assembled.
    final pending = _pending[targetId];
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(message);
    }
  }

  void _handleStderrLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      return;
    }
    if (_pending.isEmpty) {
      _idleStderrLines.add(line);
      return;
    }
    for (final pending in _pending.values) {
      pending.stderrLines.add(line);
    }
  }

  void _markDefunct(String description) {
    if (_defunct) {
      return;
    }
    _defunct = true;
    final failed = List<_PendingRequest>.of(_pending.values);
    _pending.clear();
    for (final pending in failed) {
      if (pending.completer.isCompleted) {
        continue;
      }
      final stderrOutput = pending.stderrLines.join('\n').trim();
      pending.completer.completeError(
        ProcessException(
          executablePath,
          arguments,
          stderrOutput.isEmpty ? description : '$description\n$stderrOutput',
          _exitCode ?? -1,
        ),
      );
    }
    _stdoutSubscription.cancel();
    _stderrSubscription.cancel();
    onDefunct?.call(this);
  }

  ProcessException _defunctException(String description) {
    final stderrOutput = _idleStderrLines.join('\n').trim();
    return ProcessException(
      executablePath,
      arguments,
      stderrOutput.isEmpty ? description : '$description\n$stderrOutput',
      _exitCode ?? -1,
    );
  }
}
