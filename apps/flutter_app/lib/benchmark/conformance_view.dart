import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../conformance/conformance_controller.dart';
import '../conformance/conformance_export.dart';
import '../conformance/conformance_models.dart';
import '../conformance/conformance_suite.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../widgets/app_switch.dart';
import '../widgets/compact_selector.dart';

enum _ConformanceTab { setup, results, matrix }

enum _ResultFilter { all, problems, deviations, unsupported, skipped }

enum _MatrixFilter { all, differences, problems }

/// Desktop-only S3 API conformance view inside the Benchmark workspace.
class ConformanceView extends StatefulWidget {
  const ConformanceView({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConformanceView> createState() => _ConformanceViewState();
}

class _ConformanceViewState extends State<ConformanceView> {
  _ConformanceTab _tab = _ConformanceTab.setup;
  _ResultFilter _filter = _ResultFilter.all;
  _MatrixFilter _matrixFilter = _MatrixFilter.all;
  ConformancePhase? _matrixPhase;
  String? _engine;
  Timer? _elapsedTimer;
  late final TextEditingController _baseName;
  late final TextEditingController _kmsKey;

  ConformanceController get conformance => widget.controller.conformance;

  @override
  void initState() {
    super.initState();
    _baseName = TextEditingController(text: conformance.config.baseBucketName);
    _kmsKey = TextEditingController(text: conformance.config.kmsKeyId);
    final installed = widget.controller.engines
        .where((e) => e.available && ConformanceController.supportsEngine(e))
        .map((e) => e.id)
        .toList();
    final selected =
        conformance.config.engineIds.where(installed.contains).toList();
    if (selected.isEmpty && installed.isNotEmpty) {
      final active = installed.contains(widget.controller.activeEngineId)
          ? widget.controller.activeEngineId
          : installed.first;
      conformance.config = conformance.config.copyWith(engineIds: [active]);
    } else if (selected.length != conformance.config.engineIds.length) {
      conformance.config = conformance.config.copyWith(engineIds: selected);
    }
    conformance.addListener(_syncElapsedTimer);
    _syncElapsedTimer();
  }

  void _syncElapsedTimer() {
    if (conformance.running) {
      _elapsedTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && conformance.running) setState(() {});
      });
    } else {
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
    }
  }

  @override
  void dispose() {
    conformance.removeListener(_syncElapsedTimer);
    _elapsedTimer?.cancel();
    _baseName.dispose();
    _kmsKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: conformance,
      builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1180 &&
            MediaQuery.textScalerOf(context).scale(14) < 22;
        final displayEngines = conformance.displayEngines;
        final running = conformance.running;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CompactSelector<_ConformanceTab>(
            selected: _tab,
            onChanged: (value) => setState(() => _tab = value),
            wrap: true,
            options: [
              const CompactSelectorOption(
                value: _ConformanceTab.setup,
                label: 'Setup & run',
                icon: Icons.fact_check_outlined,
              ),
              CompactSelectorOption(
                value: _ConformanceTab.results,
                label: displayEngines.isEmpty
                    ? 'Results'
                    : running
                        ? 'Results (${displayEngines.length} · live)'
                        : 'Results (${displayEngines.length})',
                icon: Icons.rule,
              ),
              CompactSelectorOption(
                value: _ConformanceTab.matrix,
                label: running
                    ? 'Compatibility matrix (live)'
                    : 'Compatibility matrix',
                icon: Icons.grid_on,
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 8),
            _liveStatusBanner(context),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: switch (_tab) {
              _ConformanceTab.setup => wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(flex: 7, child: _setupCard(context)),
                      const SizedBox(width: 10),
                      Expanded(flex: 4, child: _progressCard(context)),
                    ])
                  : ListView(
                      key: const ValueKey('conformance-setup-list'),
                      children: [
                        _setupCard(context, scroll: false),
                        const SizedBox(height: 10),
                        _progressCard(context, scroll: false),
                      ],
                    ),
              _ConformanceTab.results => _resultsCard(context),
              _ConformanceTab.matrix => _matrixCard(context),
            },
          ),
        ]);
      }),
    );
  }

  // --------------------------------------------------------- live status bar

  Widget _liveStatusBanner(BuildContext context) {
    final theme = Theme.of(context);
    final report = conformance.current;
    final progress = conformance.progress;
    final live = conformance.liveChecks;
    final engineIds = report?.config.engineIds ?? const <String>[];
    final engineCount = engineIds.length;
    final engineIndex =
        ((report?.engines.length ?? 0) + 1).clamp(1, engineCount == 0 ? 1 : engineCount);
    final overall = conformance.overallProgress;
    final percent = overall == null ? null : (overall * 100).round();
    final elapsed = report == null ? '0s' : _elapsed(report.startedAt);
    return Card(
      key: const ValueKey('conformance-live-banner'),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.28),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    'Running ${conformance.liveEngine ?? ''} ($engineIndex of $engineCount)',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '${progress?.phase.label ?? 'Starting'}'
                    '${progress?.currentCheck == null ? '' : ' · ${progress!.currentCheck}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    '${live.length} checks'
                    '${percent == null ? '' : ' · $percent%'}'
                    ' · $elapsed',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              OutlinedButton.icon(
                key: const ValueKey('conformance-banner-stop'),
                onPressed: conformance.stopping ? null : conformance.stop,
                icon: const Icon(Icons.stop, size: 16),
                label: Text(conformance.stopping ? 'Stopping…' : 'Stop'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: overall),
          if (engineIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final id in engineIds) _engineQueueChip(context, id),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _engineQueueChip(BuildContext context, String engineId) {
    final theme = Theme.of(context);
    final state = conformance.engineQueueState(engineId);
    final finished = conformance.current?.engines
        .where((e) => e.engineId == engineId)
        .firstOrNull;
    final (icon, color, detail) = switch (state) {
      ConformanceEngineQueueState.completed => (
          Icons.check_circle,
          theme.colorScheme.primary,
          '$engineId: ${finished?.count(ConformanceStatus.pass) ?? 0} pass',
        ),
      ConformanceEngineQueueState.running => (
          Icons.play_circle_fill,
          theme.colorScheme.tertiary,
          '$engineId: running (${conformance.liveChecks.length})',
        ),
      ConformanceEngineQueueState.queued => (
          Icons.schedule,
          theme.colorScheme.onSurfaceVariant,
          '$engineId: queued',
        ),
      ConformanceEngineQueueState.cancelled => (
          Icons.stop_circle_outlined,
          theme.colorScheme.onSurfaceVariant,
          '$engineId: cancelled',
        ),
      ConformanceEngineQueueState.failed => (
          Icons.error,
          theme.colorScheme.error,
          '$engineId: failed',
        ),
    };
    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(detail),
      visualDensity: VisualDensity.compact,
    );
  }

  // ---------------------------------------------------------------- setup

  Widget _setupCard(BuildContext context, {bool scroll = true}) {
    final theme = Theme.of(context);
    final profile = widget.controller.selectedProfile;
    final engines =
        widget.controller.engines.where((e) => e.desktopSupported).toList();
    final config = conformance.config;
    final blocked =
        conformance.blockedReason(profile, widget.controller.engines);
    final running = conformance.running;
    final children = <Widget>[
      _header(context, Icons.fact_check_outlined, 'S3 API conformance'),
      const SizedBox(height: 8),
      Text(
        'Checks the endpoint against the AWS S3 API specification through each SDK engine and records the latency of every call. '
        'Temporary buckets are created, tested in stages and deleted afterwards.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Endpoint profile'),
        subtitle: Text(profile == null
            ? 'No profile selected'
            : '${profile.name} · ${_endpointLabel(profile)}'),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('conformance-base-name'),
        controller: _baseName,
        enabled: !running,
        decoration: InputDecoration(
          labelText: 'Base bucket name',
          helperText:
              'Creates <base>-std-<run>, <base>-lock-<run> and a short-lived <base>-xb-<run> for each engine.',
          errorText: ConformanceConfig.validateBaseName(_baseName.text.trim()),
        ),
        onChanged: (value) =>
            conformance.updateConfig(config.copyWith(baseBucketName: value.trim())),
      ),
      const SizedBox(height: 16),
      Text('Engines', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(
        'Select several SDK engines to build a cross-engine compatibility matrix against the same endpoint. They run one after another.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final engine in engines)
          () {
            final supported = ConformanceController.supportsEngine(engine);
            final tooltip = !supported
                ? '${engine.label} is a raw HTTP performance engine and does not run the SDK conformance harness'
                : engine.available
                    ? '${engine.label} ${engine.version}'
                    : '${engine.label} is not installed';
            return Tooltip(
              message: tooltip,
              child: FilterChip(
                key: ValueKey('conformance-engine-${engine.id}'),
                label: Text(engine.label),
                selected: supported && config.engineIds.contains(engine.id),
                onSelected: running || !engine.available || !supported
                    ? null
                    : (selected) {
                        final ids = [
                          ...config.engineIds.where((id) => id != engine.id),
                          if (selected) engine.id,
                        ];
                        ids.sort((a, b) => engines
                            .indexWhere((e) => e.id == a)
                            .compareTo(engines.indexWhere((e) => e.id == b)));
                        conformance.updateConfig(config.copyWith(engineIds: ids));
                      },
              ),
            );
          }(),
        TextButton(
          key: const ValueKey('conformance-select-all'),
          onPressed: running
              ? null
              : () => conformance.updateConfig(config.copyWith(engineIds: [
                    for (final e in engines)
                      if (e.available && ConformanceController.supportsEngine(e))
                        e.id
                  ])),
          child: const Text('Select all'),
        ),
      ]),
      const SizedBox(height: 16),
      Text('Stages and options', style: theme.textTheme.titleSmall),
      const SizedBox(height: 6),
      AppSwitchTile(
        key: const ValueKey('conformance-object-lock'),
        value: config.includeObjectLock,
        onChanged: running
            ? null
            : (v) => conformance.updateConfig(config.copyWith(includeObjectLock: v)),
        title: const Text('Object Lock bucket'),
        subtitle: const Text(
          'Creates a lock-enabled bucket for GOVERNANCE retention and legal-hold checks. Retention lasts at most a few minutes and teardown bypasses it.',
        ),
      ),
      AppSwitchTile(
        value: config.includeShortCompliance,
        onChanged: running || !config.includeObjectLock
            ? null
            : (v) =>
                conformance.updateConfig(config.copyWith(includeShortCompliance: v)),
        title: const Text('Short COMPLIANCE check'),
        subtitle: const Text(
          'Locks one object in COMPLIANCE mode for 5 seconds; teardown waits for it to expire.',
        ),
      ),
      AppSwitchTile(
        value: config.includeSseC,
        onChanged: running
            ? null
            : (v) => conformance.updateConfig(config.copyWith(includeSseC: v)),
        title: const Text('SSE-C checks'),
        subtitle: Text(profile != null && !_allowsCustomerKeys(profile)
            ? 'Skipped for this endpoint: customer keys are sent only over HTTPS or to a loopback address.'
            : 'Uses throwaway customer keys generated for the run. They are never stored or reported.'),
      ),
      AppSwitchTile(
        value: config.includeSseKms,
        onChanged: running
            ? null
            : (v) => conformance.updateConfig(config.copyWith(includeSseKms: v)),
        title: const Text('SSE-KMS check'),
        subtitle: const Text(
          'Informational: endpoints without a key service report an error, which is recorded as such.',
        ),
      ),
      if (config.includeSseKms)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextField(
            controller: _kmsKey,
            enabled: !running,
            decoration: const InputDecoration(
              labelText: 'KMS key ID (optional)',
              helperText:
                  'Key ID, ARN or alias. Leave empty to use the endpoint default.',
            ),
            onChanged: (value) =>
                conformance.updateConfig(config.copyWith(kmsKeyId: value.trim())),
          ),
        ),
      AppSwitchTile(
        key: const ValueKey('conformance-retain'),
        value: config.retainBucketsOnFailure,
        onChanged: running
            ? null
            : (v) => conformance
                .updateConfig(config.copyWith(retainBucketsOnFailure: v)),
        title: const Text('Keep buckets when checks fail'),
        subtitle: const Text(
          'Off: buckets are always emptied and deleted. On: locks and uploads are released but the buckets stay for inspection.',
        ),
      ),
      if (blocked != null && !running)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(blocked,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ),
      if (conformance.lastError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(conformance.lastError!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          key: const ValueKey('conformance-run'),
          onPressed: running || blocked != null || profile == null
              ? null
              : () async {
                  final report = await conformance.start(
                      profile: profile, engines: widget.controller.engines);
                  if (mounted && report != null && report.engines.isNotEmpty) {
                    setState(() {
                      _tab = _ConformanceTab.results;
                      _engine = report.engines.first.engineId;
                    });
                  }
                },
          icon: const Icon(Icons.play_arrow),
          label: const Text('Run conformance'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('conformance-stop'),
          onPressed: running && !conformance.stopping ? conformance.stop : null,
          icon: const Icon(Icons.stop),
          label: const Text('Stop and clean up'),
        ),
        TextButton(
          onPressed: running ? () => _confirmForceStop(context) : null,
          child: const Text('Stop without cleanup'),
        ),
      ]),
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: scroll
          ? ListView(
              key: const ValueKey('conformance-setup-list'),
              padding: const EdgeInsets.all(14),
              children: children)
          : Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children)),
    );
  }

  Future<void> _confirmForceStop(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop without cleanup?'),
        content: const Text(
          'The test buckets and their objects stay on the endpoint. Locked objects can only be deleted after their retention ends.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Stop')),
        ],
      ),
    );
    if (confirmed == true) conformance.forceStop();
  }

  Widget _progressCard(BuildContext context, {bool scroll = true}) {
    final theme = Theme.of(context);
    final progress = conformance.progress;
    final running = conformance.running;
    final report = conformance.current;
    final live = conformance.liveChecks;
    final counts = {
      for (final status in ConformanceStatus.values)
        status: live.where((c) => c.status == status).length,
    };
    final engineCount = report?.config.engineIds.length ?? 0;
    final engineIndex = ((report?.engines.length ?? 0) + 1)
        .clamp(1, engineCount == 0 ? 1 : engineCount);
    final engineFraction = progress == null
        ? null
        : (progress.completed / conformanceEstimatedChecks).clamp(0.0, 1.0);
    final enginePercent =
        engineFraction == null ? null : (engineFraction * 100).round();
    final children = <Widget>[
      _header(context, Icons.timeline, running ? 'Live progress' : 'Progress'),
      const SizedBox(height: 10),
      if (!running && report == null)
        Text('No run yet. Live status updates appear here while checks complete.',
            style: theme.textTheme.bodySmall)
      else if (!running && report != null) ...[
        Text(
          'Last run finished ${_time(report.finishedAt ?? report.startedAt)} '
          '(${_duration(report.startedAt, report.finishedAt)}).',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final engine in report.engines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              '${engine.engineId}: ${engine.count(ConformanceStatus.pass)} pass, '
              '${engine.count(ConformanceStatus.fail)} fail, '
              '${engine.count(ConformanceStatus.warn)} deviation, '
              '${engine.count(ConformanceStatus.unsupported)} unsupported',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (report.engines.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => setState(() => _tab = _ConformanceTab.matrix),
              icon: const Icon(Icons.grid_on, size: 18),
              label: const Text('Compatibility matrix'),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _tab = _ConformanceTab.results),
              icon: const Icon(Icons.rule, size: 18),
              label: const Text('Results'),
            ),
          ]),
        ],
      ] else ...[
        Text(
          'Engine ${conformance.liveEngine ?? ''} ($engineIndex of $engineCount)'
          '${conformance.liveEngineStartedAt == null ? '' : ' · ${_elapsed(conformance.liveEngineStartedAt!)}'}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          progress == null
              ? 'Starting…'
              : '${progress.phase.label}: ${progress.phase.description}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: engineFraction),
        const SizedBox(height: 6),
        Text(
          '${live.length} checks complete'
          '${enginePercent == null ? '' : ' ($enginePercent%)'}'
          '${progress?.currentCheck == null ? '' : ' · now ${progress!.currentCheck}'}',
          style: theme.textTheme.bodySmall,
        ),
        if (conformance.stopping)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Stopping after the current call, then cleaning up.',
                style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final status in ConformanceStatus.values)
            if (counts[status]! > 0) _statusChip(context, status, counts[status]!),
        ]),
        const SizedBox(height: 10),
        Text('Latest checks', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final check in live.reversed.take(12))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _statusIcon(context, check.status),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${check.id} · ${check.phase.label}',
                    style: theme.textTheme.bodySmall),
              ),
              const SizedBox(width: 6),
              Text('${check.callLatencyMs.toStringAsFixed(1)} ms',
                  style: theme.textTheme.bodySmall),
            ]),
          ),
      ],
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: scroll
          ? ListView(padding: const EdgeInsets.all(14), children: children)
          : Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children)),
    );
  }

  // -------------------------------------------------------------- results

  Widget _resultsCard(BuildContext context) {
    final theme = Theme.of(context);
    final report = conformance.displayReport;
    if (report == null || report.engines.isEmpty) {
      return Card(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              conformance.running
                  ? 'Waiting for the first check to finish…'
                  : 'Run conformance to see results.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final engineId = report.engines.any((e) => e.engineId == _engine)
        ? _engine!
        : report.engines.first.engineId;
    final run = report.engines.firstWhere((e) => e.engineId == engineId);
    final isLiveRun = run.status == ConformanceRunStatus.running;
    final checks = run.checks.where(_matchesFilter).toList();
    final byPhase = <ConformancePhase, List<ConformanceCheckResult>>{};
    for (final check in checks) {
      byPhase.putIfAbsent(check.phase, () => []).add(check);
    }
    final mean = run.meanCallLatencyMs;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListView(
          key: const ValueKey('conformance-results-list'),
          padding: const EdgeInsets.all(14),
          children: [
            Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final engine in report.engines)
                    ChoiceChip(
                      label: Text(engine.status == ConformanceRunStatus.running
                          ? '${engine.engineId} (live)'
                          : engine.engineId),
                      selected: engine.engineId == engineId,
                      onSelected: (_) =>
                          setState(() => _engine = engine.engineId),
                    ),
                  if (conformance.history.length > 1 && !conformance.running)
                    PopupMenuButton<ConformanceReport>(
                      tooltip: 'Earlier runs',
                      onSelected: conformance.select,
                      itemBuilder: (context) => [
                        for (final item in conformance.history)
                          PopupMenuItem(
                              value: item,
                              child: Text(
                                  '${item.profileName} · ${_time(item.startedAt)}')),
                      ],
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.history, size: 18),
                          SizedBox(width: 4),
                          Text('Earlier runs'),
                        ]),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => _exportReport(context, report, markdown: false),
                    icon: const Icon(Icons.data_object),
                    label: const Text('Save JSON'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _exportReport(context, report, markdown: true),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Save Markdown'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: ConformanceExport.markdown(report)));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Markdown report copied.')));
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy Markdown'),
                  ),
                ]),
            const SizedBox(height: 12),
            Text(
              isLiveRun
                  ? '${run.engineId} · ${run.sdk} · streaming live'
                  : '${run.engineId} · ${run.sdk}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${run.endpoint} · ${run.pathStyle ? 'path-style' : 'virtual-hosted'} · one attempt per call, checksums only when requested · '
              '${run.callCount} calls, mean ${mean.toStringAsFixed(1)} ms',
              style: theme.textTheme.bodySmall,
            ),
            if (run.note != null) ...[
              const SizedBox(height: 4),
              Text(run.note!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 4),
            Text(
              'Phase 1 gate: ${run.gatePassed == null ? (isLiveRun ? 'in progress' : 'not reached') : run.gatePassed! ? 'required coverage met before versioning was enabled' : 'incomplete: a required check failed, errored, was unsupported or was skipped before versioning was enabled'}',
              style: theme.textTheme.bodySmall,
            ),
            if (run.teardown != null) ...[
              const SizedBox(height: 4),
              Text(_teardownText(run.teardown!),
                  style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final status in ConformanceStatus.values)
                _statusChip(context, status, run.count(status)),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (filter, label) in const [
                (_ResultFilter.all, 'All checks'),
                (_ResultFilter.problems, 'Failures and errors'),
                (_ResultFilter.deviations, 'Deviations'),
                (_ResultFilter.unsupported, 'Unsupported'),
                (_ResultFilter.skipped, 'Skipped'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _filter == filter,
                  onSelected: (_) => setState(() => _filter = filter),
                ),
            ]),
            const SizedBox(height: 8),
            if (checks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  isLiveRun
                      ? 'Checks will appear here as they complete.'
                      : 'No checks match this filter.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            for (final entry in byPhase.entries) ...[
              const SizedBox(height: 8),
              Text('${entry.key.label} — ${entry.key.description}',
                  style: theme.textTheme.titleSmall),
              for (final check in entry.value) _checkTile(context, check),
            ],
          ]),
    );
  }

  bool _matchesFilter(ConformanceCheckResult check) => switch (_filter) {
        _ResultFilter.all => true,
        _ResultFilter.problems =>
          check.status == ConformanceStatus.fail ||
              check.status == ConformanceStatus.error,
        _ResultFilter.deviations => check.status == ConformanceStatus.warn,
        _ResultFilter.unsupported =>
          check.status == ConformanceStatus.unsupported,
        _ResultFilter.skipped => check.status == ConformanceStatus.skipped,
      };

  Widget _checkTile(BuildContext context, ConformanceCheckResult check) {
    final theme = Theme.of(context);
    return ExpansionTile(
      key: ValueKey('conformance-check-${check.id}'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.fromLTRB(32, 0, 8, 12),
      leading: _statusIcon(context, check.status),
      title: Text(check.title, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        '${check.id} · ${check.category} · ${check.severity == ConformanceSeverity.required ? 'required' : 'informational'} · '
        '${check.calls.length} call${check.calls.length == 1 ? '' : 's'}, ${check.callLatencyMs.toStringAsFixed(1)} ms',
        style: theme.textTheme.bodySmall,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('AWS specification: ${check.specRef}',
            style: theme.textTheme.bodySmall),
        if (check.note != null) ...[
          const SizedBox(height: 6),
          Text(check.note!, style: theme.textTheme.bodySmall),
        ],
        if (check.expectations.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Expected and actual', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final item in [
            ...check.mismatches,
            ...check.expectations.where((e) => e.ok),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                  item.ok
                      ? Icons.check
                      : (item.informational ? Icons.info_outline : Icons.close),
                  size: 16,
                  color: item.ok
                      ? theme.colorScheme.primary
                      : item.informational
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText(
                    '${item.field}\n  expected: ${item.expected}\n  actual:   ${item.actual}'
                    '${item.explanation == null ? '' : '\n  ${item.explanation}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ]),
            ),
        ],
        if (check.calls.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Calls', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final call in check.calls)
            Text(
              '${call.op}  ${call.outcome == 'service' ? call.httpStatus : call.outcome}'
              '${call.errorCode == null ? '' : ' ${call.errorCode}'}  ${call.latencyMs.toStringAsFixed(1)} ms'
              '${call.attempts == 1 ? '' : '  (${call.attempts} attempts)'}',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ],
    );
  }

  // --------------------------------------------------- compatibility matrix

  Widget _matrixCard(BuildContext context) {
    final theme = Theme.of(context);
    final report = conformance.displayReport;
    if (report == null || report.engines.isEmpty) {
      return Card(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              conformance.running
                  ? 'Waiting for the first check to populate the compatibility matrix…'
                  : 'Run conformance with one or more SDK engines to build an exportable compatibility matrix.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final allIds = report.checkIds();
    final discrepancies = report.discrepancies().toSet();
    final hasMultiEngine = report.engines.length > 1;
    final problemIds = {
      for (final id in allIds)
        if (report.engines.any((e) {
          final status = e.check(id)?.status;
          return status == ConformanceStatus.fail ||
              status == ConformanceStatus.error ||
              status == ConformanceStatus.warn;
        }))
          id,
    };
    final activeFilter =
        (!hasMultiEngine && _matrixFilter == _MatrixFilter.differences)
            ? _MatrixFilter.all
            : _matrixFilter;
    final onlyDiffs = activeFilter == _MatrixFilter.differences;
    final phasesPresent = <ConformancePhase>{
      for (final id in allIds)
        if (report.sampleCheck(id) != null) report.sampleCheck(id)!.phase,
    };
    final rows = allIds.where((id) {
      if (activeFilter == _MatrixFilter.differences &&
          !discrepancies.contains(id)) {
        return false;
      }
      if (activeFilter == _MatrixFilter.problems && !problemIds.contains(id)) {
        return false;
      }
      if (_matrixPhase != null &&
          report.sampleCheck(id)?.phase != _matrixPhase) {
        return false;
      }
      return true;
    }).toList();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListView(
          key: const ValueKey('conformance-matrix-list'),
          padding: const EdgeInsets.all(14),
          children: [
            _header(
              context,
              Icons.grid_on,
              conformance.running
                  ? 'Compatibility matrix (live)'
                  : 'Compatibility matrix',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('conformance-export-matrix-csv'),
                  onPressed: () =>
                      _exportMatrix(context, report, csv: true, onlyDifferences: onlyDiffs),
                  icon: const Icon(Icons.table_view_outlined, size: 18),
                  label: const Text('Export CSV'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('conformance-export-matrix-md'),
                  onPressed: () =>
                      _exportMatrix(context, report, csv: false, onlyDifferences: onlyDiffs),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('Export Markdown'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('conformance-export-matrix-json'),
                  onPressed: () => _exportReport(context, report, markdown: false),
                  icon: const Icon(Icons.data_object, size: 18),
                  label: const Text('Export JSON'),
                ),
                TextButton.icon(
                  key: const ValueKey('conformance-copy-matrix-md'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(
                      text: ConformanceExport.matrixMarkdown(report,
                          onlyDifferences: onlyDiffs),
                    ));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Compatibility matrix copied as Markdown.')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy Matrix'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Engine summary', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Scrollbar(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  columnWidths: const {
                    0: FixedColumnWidth(130),
                    1: FixedColumnWidth(160),
                    2: FixedColumnWidth(110),
                    3: FixedColumnWidth(72),
                    4: FixedColumnWidth(72),
                    5: FixedColumnWidth(96),
                    6: FixedColumnWidth(108),
                    7: FixedColumnWidth(82),
                    8: FixedColumnWidth(72),
                    9: FixedColumnWidth(140),
                    10: FixedColumnWidth(110),
                  },
                  border: TableBorder(
                      horizontalInside: BorderSide(color: theme.dividerColor)),
                  children: [
                    TableRow(children: [
                      _cell(Text('Engine', style: theme.textTheme.titleSmall)),
                      _cell(Text('SDK', style: theme.textTheme.titleSmall)),
                      _cell(Text('Phase 1 gate',
                          style: theme.textTheme.titleSmall)),
                      _cell(Text('Pass', style: theme.textTheme.titleSmall)),
                      _cell(Text('Fail', style: theme.textTheme.titleSmall)),
                      _cell(Text('Deviation',
                          style: theme.textTheme.titleSmall)),
                      _cell(Text('Unsupported',
                          style: theme.textTheme.titleSmall)),
                      _cell(Text('Skipped', style: theme.textTheme.titleSmall)),
                      _cell(Text('Error', style: theme.textTheme.titleSmall)),
                      _cell(Text('Mean / p95 ms',
                          style: theme.textTheme.titleSmall)),
                      _cell(Text('Teardown', style: theme.textTheme.titleSmall)),
                    ]),
                    for (final engine in report.engines)
                      TableRow(children: [
                        _cell(Text(
                          engine.status == ConformanceRunStatus.running
                              ? '${engine.engineId} (live)'
                              : engine.engineId,
                          style: theme.textTheme.bodySmall,
                        )),
                        _cell(Text(engine.sdk, style: theme.textTheme.bodySmall)),
                        _cell(Text(
                          engine.gatePassed == null
                              ? (engine.status == ConformanceRunStatus.running
                                  ? 'in progress'
                                  : 'not reached')
                              : engine.gatePassed!
                                  ? 'met'
                                  : 'incomplete',
                          style: theme.textTheme.bodySmall,
                        )),
                        _cell(Text('${engine.count(ConformanceStatus.pass)}',
                            style: theme.textTheme.bodySmall)),
                        _cell(Text('${engine.count(ConformanceStatus.fail)}',
                            style: theme.textTheme.bodySmall)),
                        _cell(Text('${engine.count(ConformanceStatus.warn)}',
                            style: theme.textTheme.bodySmall)),
                        _cell(Text(
                            '${engine.count(ConformanceStatus.unsupported)}',
                            style: theme.textTheme.bodySmall)),
                        _cell(Text('${engine.count(ConformanceStatus.skipped)}',
                            style: theme.textTheme.bodySmall)),
                        _cell(Text('${engine.count(ConformanceStatus.error)}',
                            style: theme.textTheme.bodySmall)),
                        _cell(Text(
                          () {
                            final p95 = engine.percentileCallLatencyMs(95);
                            return '${engine.meanCallLatencyMs.toStringAsFixed(1)} / '
                                '${p95 == null ? '—' : p95.toStringAsFixed(1)}';
                          }(),
                          style: theme.textTheme.bodySmall,
                        )),
                        _cell(Text(
                          engine.teardown == null
                              ? (engine.status == ConformanceRunStatus.running
                                  ? 'running'
                                  : 'not run')
                              : engine.teardown!.clean
                                  ? 'clean'
                                  : 'see notes',
                          style: theme.textTheme.bodySmall,
                        )),
                      ]),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(
                key: const ValueKey('conformance-matrix-filter-all'),
                label: Text('All checks (${allIds.length})'),
                selected: activeFilter == _MatrixFilter.all,
                onSelected: (_) =>
                    setState(() => _matrixFilter = _MatrixFilter.all),
              ),
              if (hasMultiEngine)
                ChoiceChip(
                  key: const ValueKey('conformance-matrix-filter-diff'),
                  label: Text('Differences only (${discrepancies.length})'),
                  selected: activeFilter == _MatrixFilter.differences,
                  onSelected: (_) =>
                      setState(() => _matrixFilter = _MatrixFilter.differences),
                ),
              ChoiceChip(
                key: const ValueKey('conformance-matrix-filter-problems'),
                label: Text('Problems & deviations (${problemIds.length})'),
                selected: activeFilter == _MatrixFilter.problems,
                onSelected: (_) =>
                    setState(() => _matrixFilter = _MatrixFilter.problems),
              ),
            ]),
            if (phasesPresent.length > 1) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                ChoiceChip(
                  label: const Text('All phases'),
                  selected: _matrixPhase == null,
                  onSelected: (_) => setState(() => _matrixPhase = null),
                ),
                for (final phase in ConformancePhase.values)
                  if (phasesPresent.contains(phase))
                    ChoiceChip(
                      label: Text(phase.label),
                      selected: _matrixPhase == phase,
                      onSelected: (_) => setState(() => _matrixPhase = phase),
                    ),
              ]),
            ],
            const SizedBox(height: 8),
            Text(
              hasMultiEngine
                  ? 'Each cell shows status and summed call latency for that engine. Highlighted rows indicate SDKs observed different behaviour.'
                  : 'Select two or more SDK engines on Setup & run to compare cross-engine behaviour side by side. Export CSV, Markdown or JSON at any time.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  activeFilter == _MatrixFilter.differences
                      ? 'Every engine produced the same status for every check.'
                      : 'No checks match the selected filters.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              Scrollbar(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Table(
                    defaultVerticalAlignment: TableCellVerticalAlignment.top,
                    columnWidths: {
                      0: const FixedColumnWidth(290),
                      for (var i = 0; i < report.engines.length; i++)
                        i + 1: const FixedColumnWidth(195),
                    },
                    border: TableBorder(
                        horizontalInside: BorderSide(color: theme.dividerColor)),
                    children: [
                      TableRow(children: [
                        _cell(Text('Check', style: theme.textTheme.titleSmall)),
                        for (final engine in report.engines)
                          _cell(Text(
                            '${engine.engineId}${engine.status == ConformanceRunStatus.running ? ' (live)' : ''}\n${engine.sdk}',
                            style: theme.textTheme.titleSmall,
                          )),
                      ]),
                      for (final id in rows)
                        () {
                          final sample = report.sampleCheck(id);
                          final isDiff =
                              hasMultiEngine && discrepancies.contains(id);
                          return TableRow(
                            decoration: isDiff
                                ? BoxDecoration(
                                    color: theme.colorScheme.tertiaryContainer
                                        .withValues(alpha: 0.22),
                                  )
                                : null,
                            children: [
                              _cell(Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(id, style: theme.textTheme.bodyMedium),
                                  if (sample != null)
                                    Text(
                                      '${sample.phase.label} · ${sample.category}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                ],
                              )),
                              for (final engine in report.engines)
                                _matrixCell(context, engine.check(id)),
                            ],
                          );
                        }(),
                    ],
                  ),
                ),
              ),
          ]),
    );
  }

  Widget _matrixCell(BuildContext context, ConformanceCheckResult? check) {
    final theme = Theme.of(context);
    if (check == null) {
      return _cell(Text('not run', style: theme.textTheme.bodySmall));
    }
    return _cell(Tooltip(
      message: check.headline,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _statusIcon(context, check.status),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${check.status.label}\n${check.callLatencyMs.toStringAsFixed(1)} ms',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ]),
    ));
  }

  Widget _cell(Widget child) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6), child: child);

  // -------------------------------------------------------------- helpers

  Future<void> _exportReport(
    BuildContext context,
    ConformanceReport report, {
    required bool markdown,
  }) async {
    final name = 's3-conformance-${report.id}.${markdown ? 'md' : 'json'}';
    final path = await FilePicker.platform
        .saveFile(dialogTitle: 'Save conformance report', fileName: name);
    if (path == null) return;
    String message;
    try {
      await File(path).writeAsString(markdown
          ? ConformanceExport.markdown(report)
          : ConformanceExport.json(report));
      message = 'Report saved to $path';
    } on FileSystemException catch (error) {
      message =
          'The report could not be saved: ${error.osError?.message ?? error.message}';
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _exportMatrix(
    BuildContext context,
    ConformanceReport report, {
    required bool csv,
    required bool onlyDifferences,
  }) async {
    final name = 's3-compatibility-matrix-${report.id}.${csv ? 'csv' : 'md'}';
    final path = await FilePicker.platform
        .saveFile(dialogTitle: 'Export compatibility matrix', fileName: name);
    if (path == null) return;
    String message;
    try {
      await File(path).writeAsString(csv
          ? ConformanceExport.matrixCsv(report, onlyDifferences: onlyDifferences)
          : ConformanceExport.matrixMarkdown(report,
              onlyDifferences: onlyDifferences));
      message = 'Compatibility matrix saved to $path';
    } on FileSystemException catch (error) {
      message =
          'The compatibility matrix could not be saved: ${error.osError?.message ?? error.message}';
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Widget _header(BuildContext context, IconData icon, String title) {
    final theme = Theme.of(context);
    return Row(children: [
      Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
        ),
        child: Icon(icon, size: 16, color: theme.colorScheme.primary),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
    ]);
  }

  Widget _statusIcon(BuildContext context, ConformanceStatus status) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (status) {
      ConformanceStatus.pass => (Icons.check_circle, scheme.primary),
      ConformanceStatus.fail => (Icons.cancel, scheme.error),
      ConformanceStatus.error => (Icons.error, scheme.error),
      ConformanceStatus.warn => (Icons.info, scheme.tertiary),
      ConformanceStatus.unsupported => (Icons.block, scheme.onSurfaceVariant),
      ConformanceStatus.skipped =>
        (Icons.remove_circle_outline, scheme.onSurfaceVariant),
    };
    return Semantics(
        label: status.label, child: Icon(icon, size: 18, color: color));
  }

  Widget _statusChip(BuildContext context, ConformanceStatus status, int count) =>
      Chip(
        avatar: _statusIcon(context, status),
        label: Text('${status.label}: $count'),
        visualDensity: VisualDensity.compact,
      );

  String _teardownText(ConformanceTeardownReport teardown) {
    final parts = [
      'Teardown: deleted ${teardown.bucketsDeleted.length} bucket(s) and ${teardown.objectsDeleted} object version(s)',
      if (teardown.uploadsAborted > 0)
        'aborted ${teardown.uploadsAborted} upload(s)',
      if (teardown.legalHoldsCleared > 0)
        'cleared ${teardown.legalHoldsCleared} legal hold(s)',
      if (teardown.bucketsRetained.isNotEmpty)
        'retained ${teardown.bucketsRetained.join(', ')}',
      if (teardown.errors.isNotEmpty)
        '${teardown.errors.length} cleanup error(s): ${teardown.errors.first}',
    ];
    return '${parts.join(', ')}.';
  }

  static String _endpointLabel(EndpointProfile profile) {
    final endpoint = ConformanceEndpoint(
      endpointUrl: profile.endpointUrl,
      region: profile.region,
      pathStyle: profile.pathStyle,
      endpointType: profile.endpointType == EndpointProfileType.awsS3
          ? 'awsS3'
          : 's3Compatible',
    );
    return endpoint.displayHost;
  }

  static bool _allowsCustomerKeys(EndpointProfile profile) => ConformanceEndpoint(
        endpointUrl: profile.endpointUrl,
        region: profile.region,
        pathStyle: profile.pathStyle,
        endpointType: profile.endpointType == EndpointProfileType.awsS3
            ? 'awsS3'
            : 's3Compatible',
      ).allowsCustomerKeys;

  static String _elapsed(DateTime start) => _duration(start, DateTime.now());

  static String _duration(DateTime start, DateTime? end) {
    final totalSeconds =
        (end ?? DateTime.now()).difference(start).inSeconds.clamp(0, 86400);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return minutes == 0 ? '${seconds}s' : '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  static String _time(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}
