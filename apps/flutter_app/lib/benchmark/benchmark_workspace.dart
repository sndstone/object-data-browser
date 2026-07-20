import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../theme/app_theme.dart';
import '../widgets/app_select_field.dart';
import '../widgets/compact_selector.dart';

enum _BenchmarkPreviewSection {
  latency,
  operations,
  throughput,
  latencyOverTime,
  normalizedLatency,
  sizes,
  checksums,
}

enum _BenchmarkLineStyle {
  line,
  area,
}

enum _LatencyMetric {
  average,
  p50,
  p95,
  p99,
}

enum _NormalizationTarget {
  mib1,
  mb100,
  gb1,
}

enum _SizeChartStyle {
  bars,
  line,
}

class _ChartPoint {
  const _ChartPoint({
    required this.label,
    required this.value,
    this.x,
  });

  final String label;
  final double value;
  final double? x;
}

class _ChartSeries {
  const _ChartSeries({
    required this.id,
    required this.color,
    required this.points,
  });

  final String id;
  final Color color;
  final List<_ChartPoint> points;
}

class _BenchmarkPreset {
  const _BenchmarkPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.workloadType,
    required this.objectSizes,
    required this.concurrentThreads,
    required this.objectCount,
    required this.durationSeconds,
    required this.maxPoolConnections,
    this.validateChecksum,
    this.reducedLogging,
  });

  final String id;
  final String label;
  final String description;
  final String workloadType;
  final List<int> objectSizes;
  final int concurrentThreads;
  final int objectCount;
  final int durationSeconds;
  final int maxPoolConnections;

  /// Only applied (and matched) when non-null; presets that do not care about
  /// these switches leave the user's current setting untouched.
  final bool? validateChecksum;
  final bool? reducedLogging;
}

const List<_BenchmarkPreset> _benchmarkPresets = <_BenchmarkPreset>[
  _BenchmarkPreset(
    id: 'quick-check',
    label: 'Quick check',
    description:
        '1 MiB objects · 16 threads · 512 object pool · 30 s · read-heavy · 128 pool connections',
    workloadType: 'read-heavy',
    objectSizes: <int>[1048576],
    concurrentThreads: 16,
    objectCount: 512,
    durationSeconds: 30,
    maxPoolConnections: 128,
  ),
  _BenchmarkPreset(
    id: 'standard',
    label: 'Standard',
    description:
        '64 KiB + 1 MiB + 8 MiB objects · 64 threads · 4096 object pool · 60 s · mixed · 512 pool connections',
    workloadType: 'mixed',
    objectSizes: <int>[65536, 1048576, 8388608],
    concurrentThreads: 64,
    objectCount: 4096,
    durationSeconds: 60,
    maxPoolConnections: 512,
  ),
  _BenchmarkPreset(
    id: 'throughput-stress',
    label: 'Throughput stress',
    description:
        '16 MiB + 64 MiB objects · 128 threads · 2048 object pool · 300 s · write-heavy · 1024 pool connections · checksums off · reduced logging',
    workloadType: 'write-heavy',
    objectSizes: <int>[16777216, 67108864],
    concurrentThreads: 128,
    objectCount: 2048,
    durationSeconds: 300,
    maxPoolConnections: 1024,
    validateChecksum: false,
    reducedLogging: true,
  ),
  _BenchmarkPreset(
    id: 'iops-stress',
    label: 'IOPS stress (small objects)',
    description:
        '4 KiB + 16 KiB objects · 256 threads · 8192 object pool · 300 s · mixed · 1024 pool connections · checksums off · reduced logging',
    workloadType: 'mixed',
    objectSizes: <int>[4096, 16384],
    concurrentThreads: 256,
    objectCount: 8192,
    durationSeconds: 300,
    maxPoolConnections: 1024,
    validateChecksum: false,
    reducedLogging: true,
  ),
];

class BenchmarkWorkspace extends StatefulWidget {
  const BenchmarkWorkspace({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<BenchmarkWorkspace> createState() => _BenchmarkWorkspaceState();
}

class _BenchmarkWorkspaceState extends State<BenchmarkWorkspace> {
  final GlobalKey _resultsDialogChartExportKey = GlobalKey();
  final Map<String, TextEditingController> _fieldControllers =
      <String, TextEditingController>{};
  final Map<String, FocusNode> _fieldFocusNodes = <String, FocusNode>{};
  _BenchmarkPreviewSection _previewSection = _BenchmarkPreviewSection.latency;
  _BenchmarkLineStyle _throughputStyle = _BenchmarkLineStyle.line;
  _BenchmarkLineStyle _latencyTimeStyle = _BenchmarkLineStyle.line;
  _BenchmarkLineStyle _normalizedLatencyStyle = _BenchmarkLineStyle.line;
  _SizeChartStyle _sizeChartStyle = _SizeChartStyle.bars;
  _LatencyMetric _latencyMetric = _LatencyMetric.average;
  _NormalizationTarget _normalizationTarget = _NormalizationTarget.mib1;
  bool _overlapOperationMix = true;
  final Set<String> _enabledOperations = <String>{};

  AppController get controller => widget.controller;

  @override
  void dispose() {
    for (final controller in _fieldControllers.values) {
      controller.dispose();
    }
    for (final focusNode in _fieldFocusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final run = controller.benchmarkRun;
    final history = controller.benchmarkHistory;
    final config = controller.benchmarkDraft;
    final previewRun = controller.selectedBenchmarkRun;

    final isDesktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);
    final outerPad = isDesktopCompact ? 10.0 : 14.0;
    final gap = isDesktopCompact ? 10.0 : 14.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final useStackedLayout =
            constraints.maxWidth < 1180 || constraints.maxHeight < 920;
        if (useStackedLayout) {
          final configHeight =
              (constraints.maxHeight * 0.62).clamp(420.0, 800.0).toDouble();
          final panelHeight =
              (constraints.maxHeight * 0.5).clamp(340.0, 680.0).toDouble();
          return ListView(
            padding: EdgeInsets.all(outerPad),
            children: [
              SizedBox(
                  height: configHeight, child: _configPanel(context, config)),
              SizedBox(height: gap),
              SizedBox(height: panelHeight, child: _runPanel(context, run)),
              SizedBox(height: gap),
              SizedBox(
                  height: panelHeight, child: _historyPanel(context, history)),
              SizedBox(height: gap),
              SizedBox(
                height: math.max(panelHeight + 80, 520),
                child: _resultsPanel(context, previewRun),
              ),
            ],
          );
        }

        return Padding(
          padding: EdgeInsets.all(outerPad),
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: _configPanel(context, config),
                    ),
                    SizedBox(width: gap),
                    Expanded(
                      flex: 4,
                      child: _runPanel(context, run),
                    ),
                  ],
                ),
              ),
              SizedBox(height: gap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: _historyPanel(context, history)),
                    SizedBox(width: gap),
                    Expanded(
                        flex: 7, child: _resultsPanel(context, previewRun)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _adaptiveFieldPair({
    required BuildContext context,
    required Widget leading,
    required Widget trailing,
  }) {
    final phone = MediaQuery.sizeOf(context).width < 700;
    if (phone) {
      return Column(
        children: [
          leading,
          const SizedBox(height: 12),
          trailing,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: leading),
        const SizedBox(width: 12),
        Expanded(child: trailing),
      ],
    );
  }

  Widget _configPanel(BuildContext context, BenchmarkConfig config) {
    final selectedProfile = controller.selectedProfile;
    final bucketOptions =
        controller.buckets.map((bucket) => bucket.name).toList();
    final isDurationMode = config.testMode == 'duration';
    final isDesktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);
    final panelPadding = isDesktopCompact ? 10.0 : 14.0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListView(
        padding: EdgeInsets.all(panelPadding),
        children: [
          _sectionHeader(context, Icons.tune, 'Benchmark control'),
          const SizedBox(height: 10),
          Builder(builder: (context) {
            final starting = controller.isBusy('benchmark-start');
            final activeRun = controller.benchmarkRun;
            final runReady =
                activeRun != null && activeRun.status != 'starting';
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: selectedProfile == null || starting
                      ? null
                      : () {
                          _flushBenchmarkEditors();
                          controller.startBenchmark();
                        },
                  icon: starting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(starting ? 'Starting…' : 'Start benchmark'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      !runReady || starting ? null : controller.pauseBenchmark,
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      !runReady || starting ? null : controller.resumeBenchmark,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Resume'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      !runReady || starting ? null : controller.stopBenchmark,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                OutlinedButton.icon(
                  onPressed: starting ? null : controller.pollBenchmark,
                  icon: const Icon(Icons.sync),
                  label: const Text('Refresh status'),
                ),
              ],
            );
          }),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active endpoint profile'),
            subtitle: Text(selectedProfile?.name ?? 'No profile selected'),
            trailing: Text(controller.activeEngineId),
          ),
          const SizedBox(height: 14),
          _presetSelector(context, config),
          const SizedBox(height: 14),
          Text('Workload', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          AppSelectField<String>(
            key: ValueKey('benchmark-workload-${config.workloadType}'),
            value: config.workloadType,
            decoration: _fieldDecoration(label: 'Workload'),
            items: const [
              AppSelectItem(value: 'mixed', label: 'Mixed (PUT/GET/DELETE)'),
              AppSelectItem(value: 'write-heavy', label: 'Write-heavy'),
              AppSelectItem(value: 'read-heavy', label: 'Read-heavy'),
              AppSelectItem(value: 'delete', label: 'Delete'),
              AppSelectItem(
                  value: 'write-only', label: 'Write-only (PUT only)'),
              AppSelectItem(value: 'read-only', label: 'Read-only (GET only)'),
              AppSelectItem(value: 'custom', label: 'Custom mix (%)'),
            ],
            onChanged: (value) {
              if (value != null) {
                controller
                    .updateBenchmarkDraft(config.copyWith(workloadType: value));
              }
            },
          ),
          if (config.workloadType == 'custom') ...[
            const SizedBox(height: 8),
            _customMixCard(context, config),
          ],
          const SizedBox(height: 8),
          AppSelectField<String>(
            value: config.deleteMode,
            decoration: _fieldDecoration(label: 'Delete mode'),
            items: const [
              AppSelectItem(
                value: 'single',
                label: 'Single-object DELETE',
              ),
              AppSelectItem(
                value: 'multi-object-post',
                label: 'Multi-object delete (POST)',
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                controller.updateBenchmarkDraft(
                  config.copyWith(deleteMode: value),
                );
              }
            },
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Text(
              config.deleteMode == 'multi-object-post'
                  ? 'Delete phases issue S3 multi-object delete POST requests so each benchmark step can remove several keys at once.'
                  : 'Delete phases issue one S3 DELETE request per object for direct per-key behavior.',
            ),
          ),
          const SizedBox(height: 8),
          AppSelectField<String>(
            key: ValueKey('benchmark-test-mode-${config.testMode}'),
            value: config.testMode,
            decoration: _fieldDecoration(label: 'Run mode'),
            items: const [
              AppSelectItem(value: 'duration', label: 'Duration'),
              AppSelectItem(
                value: 'operation-count',
                label: 'Operation count',
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                controller
                    .updateBenchmarkDraft(config.copyWith(testMode: value));
              }
            },
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Text(
              isDurationMode
                  ? 'Active stop condition: duration. This run keeps processing operations until the duration expires.'
                  : 'Active stop condition: operation count. This run stops when the configured number of operations has completed.',
            ),
          ),
          const SizedBox(height: 8),
          AppSelectField<String>(
            value: bucketOptions.contains(config.bucketName)
                ? config.bucketName
                : null,
            decoration: _fieldDecoration(label: 'Bucket'),
            items: bucketOptions
                .map(
                  (bucketName) => AppSelectItem(
                    value: bucketName,
                    label: bucketName,
                  ),
                )
                .toList(),
            onChanged: bucketOptions.isEmpty
                ? null
                : (value) {
                    if (value != null) {
                      controller.updateBenchmarkDraft(
                        config.copyWith(bucketName: value),
                      );
                    }
                  },
          ),
          if (bucketOptions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Refresh buckets in Browser first if you need a target bucket here.',
              ),
            ),
          const SizedBox(height: 8),
          _textField(
            fieldKey: 'prefix',
            label: 'Prefix',
            initialValue: config.prefix,
            onChanged: (value) {
              controller.updateBenchmarkDraft(config.copyWith(prefix: value));
            },
          ),
          const SizedBox(height: 8),
          _textField(
            fieldKey: 'objectSizes',
            label: 'Sizes (bytes, comma-separated)',
            initialValue: config.objectSizes.join(','),
            onChanged: (value) {
              final sizes = value
                  .split(',')
                  .map((item) => int.tryParse(item.trim()))
                  .whereType<int>()
                  .toList();
              if (sizes.isNotEmpty) {
                controller
                    .updateBenchmarkDraft(config.copyWith(objectSizes: sizes));
              }
            },
          ),
          const SizedBox(height: 8),
          _adaptiveFieldPair(
            context: context,
            leading: _numberField(
              fieldKey: 'threads',
              label: 'Threads',
              initialValue: config.concurrentThreads,
              onChanged: (value) {
                controller.updateBenchmarkDraft(
                  config.copyWith(concurrentThreads: value),
                );
              },
            ),
            trailing: _numberField(
              fieldKey: 'datasetObjectCount',
              label: 'Object pool',
              helperText: 'Working set size.',
              initialValue: config.objectCount,
              onChanged: (value) {
                controller.updateBenchmarkDraft(
                  config.copyWith(objectCount: value),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _adaptiveFieldPair(
            context: context,
            leading: _numberField(
              fieldKey: 'durationSeconds',
              label: 'Duration (s)',
              helperText: isDurationMode
                  ? 'Active stop condition.'
                  : 'Disabled in operation-count mode.',
              enabled: isDurationMode,
              initialValue: config.durationSeconds,
              onChanged: (value) {
                controller.updateBenchmarkDraft(
                  config.copyWith(durationSeconds: value),
                );
              },
            ),
            trailing: _numberField(
              fieldKey: 'operationCount',
              label: 'Operation count',
              helperText: isDurationMode
                  ? 'Disabled in duration mode.'
                  : 'Active stop condition.',
              enabled: !isDurationMode,
              initialValue: config.operationCount,
              onChanged: (value) {
                controller.updateBenchmarkDraft(
                  config.copyWith(operationCount: value),
                );
              },
            ),
          ),
          const Divider(height: 14),
          Text(
            'Debug and transport',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          _adaptiveFieldPair(
            context: context,
            leading: _numberField(
              fieldKey: 'connectTimeoutSeconds',
              label: 'Connect timeout (s)',
              initialValue: config.connectTimeoutSeconds,
              onChanged: (value) {
                controller.updateBenchmarkDraft(
                  config.copyWith(connectTimeoutSeconds: value),
                );
              },
            ),
            trailing: _numberField(
              fieldKey: 'readTimeoutSeconds',
              label: 'Read timeout (s)',
              initialValue: config.readTimeoutSeconds,
              onChanged: (value) {
                controller.updateBenchmarkDraft(
                  config.copyWith(readTimeoutSeconds: value),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _adaptiveFieldPair(
            context: context,
            leading: _numberField(
              fieldKey: 'maxAttempts',
              label: 'Max attempts',
              initialValue: config.maxAttempts,
              onChanged: (value) {
                controller
                    .updateBenchmarkDraft(config.copyWith(maxAttempts: value));
              },
            ),
            trailing: _numberField(
              fieldKey: 'maxPoolConnections',
              label: 'Pool',
              initialValue: config.maxPoolConnections,
              onChanged: (value) {
                controller.updateBenchmarkDraft(
                  config.copyWith(maxPoolConnections: value),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _numberField(
            fieldKey: 'dataCacheMb',
            label: 'Data cache (MB)',
            initialValue: config.dataCacheMb,
            onChanged: (value) {
              controller
                  .updateBenchmarkDraft(config.copyWith(dataCacheMb: value));
            },
          ),
          _compactSwitchTile(
            value: config.validateChecksum,
            onChanged: (value) {
              controller.updateBenchmarkDraft(
                config.copyWith(validateChecksum: value),
              );
            },
            title: const Text('Validate checksums'),
          ),
          _compactSwitchTile(
            value: config.randomData,
            onChanged: (value) {
              controller
                  .updateBenchmarkDraft(config.copyWith(randomData: value));
            },
            title: const Text('Use random data'),
          ),
          _compactSwitchTile(
            value: config.inMemoryData,
            onChanged: (value) {
              controller
                  .updateBenchmarkDraft(config.copyWith(inMemoryData: value));
            },
            title: const Text('Generate in-memory test data'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Benchmark debug mode'),
            subtitle: Text(
              controller.settings.benchmarkDebugMode
                  ? 'Enabled in Settings. Benchmark tracing will be written to the Event Log.'
                  : 'Disabled in Settings. Enable it there when you need benchmark tracing.',
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 2),
            child: Text(
              'Tip: start from a preset — Throughput stress and IOPS stress are the ones that truly saturate a target. To push further, raise Threads and Pool first, turn off checksum validation, and keep reduced logging on.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ),
          _compactSwitchTile(
            value: config.reducedLogging,
            onChanged: (value) {
              controller.updateBenchmarkDraft(
                config.copyWith(reducedLogging: value),
              );
            },
            title: const Text('Less accurate logging (reduces overhead)'),
            subtitle: const Text(
              'Skips per-object success log lines. Timings and summaries still come from completed requests.',
            ),
          ),
          const Divider(height: 14),
          Text('Outputs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          _textField(
            fieldKey: 'csvOutputPath',
            label: 'CSV output',
            initialValue: config.csvOutputPath,
            onChanged: (value) {
              controller
                  .updateBenchmarkDraft(config.copyWith(csvOutputPath: value));
            },
          ),
          const SizedBox(height: 8),
          _textField(
            fieldKey: 'jsonOutputPath',
            label: 'JSON output',
            initialValue: config.jsonOutputPath,
            onChanged: (value) {
              controller
                  .updateBenchmarkDraft(config.copyWith(jsonOutputPath: value));
            },
          ),
          const SizedBox(height: 8),
          _textField(
            fieldKey: 'logFilePath',
            label: 'Log output',
            initialValue: config.logFilePath,
            onChanged: (value) {
              controller
                  .updateBenchmarkDraft(config.copyWith(logFilePath: value));
            },
          ),
        ],
      ),
    );
  }

  Widget _runPanel(BuildContext context, BenchmarkRun? run) {
    final operations = controller.benchmarkOperationsForRun(run);
    final isDesktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final logHeight =
              (constraints.maxHeight * 0.30).clamp(140.0, 220.0).toDouble();
          return Padding(
            padding: EdgeInsets.all(isDesktopCompact ? 12.0 : 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _sectionHeader(
                        context,
                        Icons.monitor_heart_outlined,
                        'Active run',
                      ),
                    ),
                    if (run != null) _statusChip(context, run.status),
                  ],
                ),
                const SizedBox(height: 12),
                if (run == null)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.speed_outlined,
                            size: 40,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6),
                          ),
                          const SizedBox(height: 12),
                          const Text('No benchmark is running.'),
                          const SizedBox(height: 4),
                          Text(
                            'Configure a workload and press Start benchmark.',
                            style: theme.textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                else if (run.status == 'starting')
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Starting benchmark…',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Contacting ${controller.activeEngineId} engine',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _runIdentityCard(context, run),
                                const SizedBox(height: 12),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: controller.benchmarkProgress,
                                    minHeight: 8,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  run.config.testMode == 'operation-count'
                                      ? '${(controller.benchmarkProgress * 100).toStringAsFixed(0)}% of ${run.config.operationCount} operations'
                                      : '${_activeBenchmarkSeconds(run).toStringAsFixed(0)}s of ${run.config.durationSeconds}s',
                                  style: theme.textTheme.labelMedium,
                                ),
                                const SizedBox(height: 12),
                                _runStatGrid(context, run),
                                const SizedBox(height: 14),
                                Text('Current activity',
                                    style: theme.textTheme.titleMedium),
                                const SizedBox(height: 6),
                                Text(controller.benchmarkActivityForRun(run)),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: operations.entries
                                      .map(
                                        (entry) => Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                              '${entry.key} ${entry.value}'),
                                        ),
                                      )
                                      .toList(),
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text('Output files',
                                          style: theme.textTheme.titleMedium),
                                    ),
                                    Tooltip(
                                      message: 'Open this run’s results folder',
                                      child: IconButton(
                                        onPressed: () => controller.openPath(
                                          _parentDirectory(
                                              run.config.csvOutputPath),
                                        ),
                                        icon: const Icon(
                                            Icons.folder_open_outlined),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Each run writes into its own folder named after the run ID.',
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(height: 8),
                                ..._outputFileEntries(run).map(
                                  (entry) => _outputFileTile(
                                      context, entry.key, entry.value),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () =>
                                          controller.exportBenchmarkResults(
                                        'csv',
                                        run: run,
                                      ),
                                      icon: const Icon(
                                          Icons.table_chart_outlined),
                                      label: const Text('Export CSV'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () =>
                                          controller.exportBenchmarkResults(
                                        'json',
                                        run: run,
                                      ),
                                      icon: const Icon(Icons.data_object),
                                      label: const Text('Export JSON'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text('Live log', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: logHeight,
                          child: _liveLogView(context, run),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Compact identity strip for the active run: ID, bucket, and engine.
  Widget _runIdentityCard(BuildContext context, BenchmarkRun run) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.tag,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  run.id,
                  style: theme.textTheme.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${run.config.bucketName.isEmpty ? 'No bucket set' : run.config.bucketName} · ${run.config.engineId.isEmpty ? controller.activeEngineId : run.config.engineId} engine',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Two-column grid of live counters for the active run.
  Widget _runStatGrid(BuildContext context, BenchmarkRun run) {
    final tiles = <Widget>[
      _runStatTile(
        context,
        icon: Icons.stacked_line_chart,
        label: 'Processed',
        value: '${run.processedCount}',
        caption: 'operations',
      ),
      _runStatTile(
        context,
        icon: Icons.timer_outlined,
        label: 'Latency',
        value: run.averageLatencyMs.toStringAsFixed(1),
        caption: 'ms average',
      ),
      _runStatTile(
        context,
        icon: Icons.speed_outlined,
        label: 'Throughput',
        value: run.throughputOpsPerSecond.toStringAsFixed(0),
        caption: 'ops/s',
        tooltip:
            'Measured from completed operations over active elapsed time. This is the benchmark’s truth source for live throughput.',
      ),
      _runStatTile(
        context,
        icon: Icons.sync_alt,
        label: 'Data rate',
        value: controller.estimatedMibsForRun(run).toStringAsFixed(2),
        caption: 'MiB/s',
        tooltip:
            'Current ops/s × average configured object size. Approximate because the workload mix can vary by size.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 320 ? 2 : 1;
        final tileWidth =
            (constraints.maxWidth - ((columns - 1) * 8)) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: tiles
              .map((tile) => SizedBox(width: tileWidth, child: tile))
              .toList(),
        );
      },
    );
  }

  Widget _runStatTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required String caption,
    String? tooltip,
  }) {
    final theme = Theme.of(context);
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
            ),
            child: Icon(
              icon,
              size: 16,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelMedium),
                const SizedBox(height: 1),
                Text.rich(
                  TextSpan(
                    text: value,
                    style: theme.textTheme.titleMedium,
                    children: [
                      TextSpan(
                        text: ' $caption',
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (tooltip != null)
            Tooltip(
              message: tooltip,
              preferBelow: false,
              constraints: const BoxConstraints(maxWidth: 280),
              child: Icon(
                Icons.info_outline,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
    return tile;
  }

  /// Terminal-styled live log that sticks to the newest entries.
  Widget _liveLogView(BuildContext context, BenchmarkRun run) {
    const background = Color(0xFF0A1410);
    const foreground = Color(0xFFC9DACF);
    final logStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: foreground,
          fontFamily: 'Menlo',
          fontFamilyFallback: const <String>[
            'Consolas',
            'Roboto Mono',
            'monospace',
          ],
          fontWeight: FontWeight.w500,
          fontSize: 12,
          height: 1.5,
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: background,
      ),
      child: run.liveLog.isEmpty
          ? Center(
              child: Text(
                'Waiting for benchmark log output...',
                style: logStyle?.copyWith(
                  color: foreground.withValues(alpha: 0.6),
                ),
              ),
            )
          : ListView(
              reverse: true,
              children: run.liveLog.reversed
                  .map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(entry, style: logStyle),
                    ),
                  )
                  .toList(),
            ),
    );
  }

  /// Parent directory of [path] using whichever separator the path uses.
  String _parentDirectory(String path) {
    final splitIndex = path.lastIndexOf(RegExp(r'[/\\]'));
    if (splitIndex <= 0) {
      return path;
    }
    return path.substring(0, splitIndex);
  }

  Widget _sectionHeader(BuildContext context, IconData icon, String title) {
    final theme = Theme.of(context);
    return Row(
      children: [
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
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _historyPanel(BuildContext context, List<BenchmarkRun> history) {
    final selectedRun = controller.selectedBenchmarkRun;
    final activeRun = controller.benchmarkRun;
    final isDesktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(isDesktopCompact ? 12.0 : 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, Icons.history, 'Benchmark history'),
            const SizedBox(height: 8),
            Expanded(
              child: history.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.hourglass_empty,
                            size: 32,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.6),
                          ),
                          const SizedBox(height: 10),
                          const Text('No benchmark runs recorded yet.'),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: history.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = history[index];
                        final isActive = activeRun?.id == item.id;
                        final subtitleParts = [
                          item.config.workloadType,
                          item.config.engineId,
                          item.config.bucketName,
                        ];
                        String subtitleText = subtitleParts
                            .where((s) => s.isNotEmpty)
                            .join(' - ');
                        if (isActive && item.status == 'running') {
                          final elapsed =
                              DateTime.now().difference(item.startedAt);
                          final minutes = elapsed.inMinutes;
                          final seconds = elapsed.inSeconds % 60;
                          subtitleText += ' - ${minutes}m ${seconds}s elapsed';
                        }
                        final textTheme = Theme.of(context).textTheme;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          selected: selectedRun?.id == item.id,
                          title: Text(
                            item.id,
                            style: textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            subtitleText,
                            style: textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _statusChip(context, item.status),
                          onTap: () => controller.selectBenchmarkRun(item.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(BuildContext context, String status) {
    final (color, icon) = switch (status) {
      'starting' => (
          Theme.of(context).colorScheme.primary,
          Icons.hourglass_top,
        ),
      'running' => (Colors.green.shade600, Icons.play_circle_filled),
      'paused' => (Colors.orange.shade600, Icons.pause_circle_filled),
      'stopped' => (Colors.red.shade600, Icons.stop_circle),
      'completed' => (Colors.blue.shade600, Icons.check_circle),
      _ => (Colors.grey.shade500, Icons.circle_outlined),
    };
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        );
    return Chip(
      avatar: Icon(icon, color: color, size: 14),
      label: Text(status, style: labelStyle),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide.none,
      backgroundColor: color.withValues(alpha: 0.1),
    );
  }

  Widget _resultsPanel(BuildContext context, BenchmarkRun? run) {
    final summary = controller.benchmarkSummaryForRun(run);
    final operations =
        summary == null ? const <String>[] : _availableOperations(summary);
    _syncOperationFilter(operations);
    final isDesktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(isDesktopCompact ? 12.0 : 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionHeader(
                          context, Icons.query_stats, 'Results preview'),
                      const SizedBox(height: 8),
                      if (run != null) ...[
                        Text(
                          'Viewing ${run.id}',
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        if (run.resultSummary == null)
                          Text(
                            'Live estimate while the benchmark is still running.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed:
                      summary == null ? null : () => _openResultsWorkspace(run),
                  icon: const Icon(Icons.open_in_full, size: 16),
                  label: const Text('Open detailed view'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              summary == null
                  ? 'Charts, deep metrics, and output artifacts will appear in the detailed workspace once summary data is available.'
                  : 'This preview stays focused on final summary numbers. Open detailed view for charts, deep metrics, and output files.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (run != null)
                  OutlinedButton.icon(
                    onPressed: () => controller.exportBenchmarkResults(
                      'csv',
                      run: run,
                    ),
                    icon: const Icon(Icons.table_chart_outlined),
                    label: const Text('Export selected CSV'),
                  ),
                if (run != null)
                  OutlinedButton.icon(
                    onPressed: () => controller.exportBenchmarkResults(
                      'json',
                      run: run,
                    ),
                    icon: const Icon(Icons.data_object),
                    label: const Text('Export selected JSON'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (summary == null)
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  ),
                  child: const Center(
                    child: Text(
                      'Results will populate here as the benchmark writes summary data.',
                    ),
                  ),
                ),
              )
            else ...[
              _metricCards(context, summary),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  ),
                  child: ListView(
                    children: [
                      _summaryListTile(
                        context,
                        'Run status',
                        run?.status ?? 'completed',
                      ),
                      _summaryListTile(
                        context,
                        'Operation mix',
                        summary.operationsByType.entries
                            .map((entry) => '${entry.key} ${entry.value}')
                            .join(' - '),
                      ),
                      _summaryListTile(
                        context,
                        'Latency percentiles',
                        _sortedPercentiles(summary)
                            .map(
                              (entry) =>
                                  '${entry.key.toUpperCase()} ${entry.value.toStringAsFixed(1)} ms',
                            )
                            .join(' - '),
                      ),
                      _summaryListTile(
                        context,
                        'Average bandwidth',
                        _formatBytesPerSecond(
                          summary.detailMetrics['averageBytesPerSecond'],
                        ),
                      ),
                      _summaryListTile(
                        context,
                        'Peak bandwidth',
                        _formatBytesPerSecond(
                          summary.detailMetrics['peakBytesPerSecond'],
                        ),
                      ),
                      _summaryListTile(
                        context,
                        'Sample windows',
                        '${summary.throughputSeries.length} recorded',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryListTile(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            value.isEmpty ? '-' : value,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _metricCards(BuildContext context, BenchmarkResultSummary summary) {
    final totalOps = summary.totalOperations;
    final avgLatency = summary.latencyPercentilesMs.isEmpty
        ? 0.0
        : summary.latencyPercentilesMs.values
                .reduce((left, right) => left + right) /
            summary.latencyPercentilesMs.length;
    final peakThroughput = summary.throughputSeries.fold<double>(
      0,
      (current, point) {
        final value = (point['opsPerSecond'] as num?)?.toDouble() ?? 0;
        return value > current ? value : current;
      },
    );

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _metricCard(
          context,
          'Operations',
          '$totalOps total',
          icon: Icons.stacked_line_chart,
        ),
        _metricCard(
          context,
          'Latency',
          '${avgLatency.toStringAsFixed(1)} ms avg',
          icon: Icons.timer_outlined,
        ),
        _metricCard(
          context,
          'Peak throughput',
          '${peakThroughput.toStringAsFixed(0)} ops/s',
          icon: Icons.speed_outlined,
        ),
        _metricCard(
          context,
          'Operation types',
          '${_availableOperations(summary).length} tracked',
          icon: Icons.category_outlined,
        ),
      ],
    );
  }

  Widget _metricCard(
    BuildContext context,
    String title,
    String value, {
    IconData icon = Icons.insights_outlined,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: 196,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surface,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
            ),
            child: Icon(icon, size: 16, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelMedium),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewSectionContent(
    BuildContext context,
    BenchmarkResultSummary summary,
    BoxConstraints constraints,
  ) {
    return switch (_previewSection) {
      _BenchmarkPreviewSection.latency =>
        _latencyPreview(context, summary, constraints.maxWidth),
      _BenchmarkPreviewSection.operations =>
        _operationsPreview(context, summary, constraints.maxWidth),
      _BenchmarkPreviewSection.throughput =>
        _throughputPreview(context, summary, constraints),
      _BenchmarkPreviewSection.latencyOverTime =>
        _latencyOverTimePreview(context, summary, constraints),
      _BenchmarkPreviewSection.normalizedLatency =>
        _normalizedLatencyPreview(context, summary, constraints),
      _BenchmarkPreviewSection.sizes =>
        _sizePreview(context, summary, constraints.maxWidth),
      _BenchmarkPreviewSection.checksums =>
        _checksumPreview(context, summary, constraints),
    };
  }

  Future<void> _openResultsWorkspace(BenchmarkRun? run) async {
    final selectedRun = _liveBenchmarkRun(run);
    final summary = controller.benchmarkSummaryForRun(selectedRun);
    if (!mounted || summary == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, dialogSetState) => Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          child: FractionallySizedBox(
            widthFactor: 0.94,
            heightFactor: 0.94,
            child: DefaultTabController(
              length: 3,
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  final liveRun = _liveBenchmarkRun(run);
                  final liveSummary =
                      controller.benchmarkSummaryForRun(liveRun);
                  if (liveSummary != null) {
                    _syncOperationFilter(_availableOperations(liveSummary));
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: Theme.of(dialogContext)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: 0.55),
                              ),
                              child: Icon(
                                Icons.query_stats,
                                size: 20,
                                color:
                                    Theme.of(dialogContext).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Benchmark results workspace',
                                    style: Theme.of(dialogContext)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    liveRun == null
                                        ? 'No run selected'
                                        : 'Viewing ${liveRun.id}',
                                    style: Theme.of(dialogContext)
                                        .textTheme
                                        .bodySmall,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            if (liveRun != null)
                              _statusChip(dialogContext, liveRun.status),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Close',
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                      const TabBar(
                        isScrollable: true,
                        tabs: [
                          Tab(text: 'Charts'),
                          Tab(text: 'Metrics'),
                          Tab(text: 'Files'),
                        ],
                      ),
                      Expanded(
                        child: liveSummary == null
                            ? const Center(
                                child: Text(
                                  'Summary data is still arriving. This view will refresh automatically.',
                                ),
                              )
                            : TabBarView(
                                children: [
                                  _resultsChartsTab(
                                    dialogContext,
                                    liveRun,
                                    liveSummary,
                                    updateUi: dialogSetState,
                                  ),
                                  _resultsMetricsTab(
                                    dialogContext,
                                    liveRun,
                                    liveSummary,
                                  ),
                                  _resultsFilesTab(
                                    dialogContext,
                                    liveRun,
                                    liveSummary,
                                  ),
                                ],
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  BenchmarkRun? _liveBenchmarkRun(BenchmarkRun? run) {
    if (run == null) {
      return controller.selectedBenchmarkRun;
    }
    if (controller.benchmarkRun?.id == run.id) {
      return controller.benchmarkRun;
    }
    for (final entry in controller.benchmarkHistory) {
      if (entry.id == run.id) {
        return entry;
      }
    }
    return run;
  }

  Widget _resultsChartsTab(
      BuildContext context, BenchmarkRun? run, BenchmarkResultSummary summary,
      {required StateSetter updateUi}) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (run != null)
                OutlinedButton.icon(
                  onPressed: () => controller.exportBenchmarkResults(
                    'csv',
                    run: run,
                  ),
                  icon: const Icon(Icons.table_chart_outlined),
                  label: const Text('Export selected CSV'),
                ),
              if (run != null)
                OutlinedButton.icon(
                  onPressed: () => controller.exportBenchmarkResults(
                    'json',
                    run: run,
                  ),
                  icon: const Icon(Icons.data_object),
                  label: const Text('Export selected JSON'),
                ),
              OutlinedButton.icon(
                onPressed: () => _exportPreviewImage(
                  run,
                  exportKey: _resultsDialogChartExportKey,
                ),
                icon: const Icon(Icons.image_outlined),
                label: const Text('Export current chart PNG'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CompactSelector<_BenchmarkPreviewSection>(
                  selected: _previewSection,
                  wrap: true,
                  dense: true,
                  onChanged: (section) {
                    updateUi(() {
                      _previewSection = section;
                    });
                  },
                  options: _BenchmarkPreviewSection.values
                      .map(
                        (section) => CompactSelectorOption(
                          value: section,
                          icon: _previewIcon(section),
                          label: _previewLabel(section),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                _metricCards(context, summary),
                const SizedBox(height: 12),
                _previewControls(context, summary, updateUi: updateUi),
                const SizedBox(height: 12),
                Expanded(
                  child: RepaintBoundary(
                    key: _resultsDialogChartExportKey,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLowest,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            SingleChildScrollView(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: constraints.maxHeight,
                            ),
                            child: _previewSectionContent(
                              context,
                              summary,
                              constraints,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsMetricsTab(
    BuildContext context,
    BenchmarkRun? run,
    BenchmarkResultSummary summary,
  ) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _detailedMetricsSection(context, run, summary),
        const SizedBox(height: 16),
        _operationDetailSection(context, summary),
        const SizedBox(height: 16),
        _sizeDetailSection(context, summary),
        const SizedBox(height: 16),
        _sampleWindowSection(context, summary),
      ],
    );
  }

  Widget _resultsFilesTab(
    BuildContext context,
    BenchmarkRun? run,
    BenchmarkResultSummary summary,
  ) {
    if (run == null) {
      return const Center(child: Text('No output files available yet.'));
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Output files',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            OutlinedButton.icon(
              onPressed: () => controller.openPath(
                _parentDirectory(run.config.csvOutputPath),
              ),
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: const Text('Open results folder'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Each run writes its artifacts into a folder named after the run ID.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ..._outputFileEntries(run)
            .map((entry) => _outputFileTile(context, entry.key, entry.value)),
        const SizedBox(height: 12),
        Text(
          'Use this view when you want the result artifacts without the chart preview taking space.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _detailedMetricsSection(
    BuildContext context,
    BenchmarkRun? run,
    BenchmarkResultSummary summary,
  ) {
    final detailMetrics = summary.detailMetrics;
    final cards = <MapEntry<String, String>>[
      MapEntry(
        'Sample windows',
        '${_intMetric(detailMetrics['sampleCount'])} x ${_intMetric(detailMetrics['sampleWindowSeconds'])}s',
      ),
      MapEntry(
        'Average bandwidth',
        _formatBytesPerSecond(detailMetrics['averageBytesPerSecond']),
      ),
      MapEntry(
        'Peak bandwidth',
        _formatBytesPerSecond(detailMetrics['peakBytesPerSecond']),
      ),
      MapEntry(
        'Retries',
        '${_intMetric(detailMetrics['retryCount'])}',
      ),
      MapEntry(
        'Checksum validated',
        '${_intMetric(detailMetrics['checksumValidated'])}',
      ),
      MapEntry(
        'Object sizes',
        run == null
            ? '${summary.sizeLatencyBuckets.length} tracked'
            : run.config.objectSizes.map(_formatSizeLabel).join(', '),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Detailed metrics',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Final benchmark metrics with timeline density, bandwidth, and workload context.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: cards
              .map(
                (entry) => _metricCard(
                  context,
                  entry.key,
                  entry.value,
                  icon: switch (entry.key) {
                    'Sample windows' => Icons.grid_view_outlined,
                    'Average bandwidth' => Icons.swap_vert,
                    'Peak bandwidth' => Icons.trending_up,
                    'Retries' => Icons.refresh,
                    'Checksum validated' => Icons.verified_outlined,
                    'Object sizes' => Icons.straighten_outlined,
                    _ => Icons.insights_outlined,
                  },
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Widget _operationDetailSection(
    BuildContext context,
    BenchmarkResultSummary summary,
  ) {
    final operationDetails = summary.operationDetails;
    if (operationDetails.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Operation detail',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Per-operation counts, throughput, and latency percentiles.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Op')),
              DataColumn(label: Text('Count')),
              DataColumn(label: Text('Share')),
              DataColumn(label: Text('Avg ops/s')),
              DataColumn(label: Text('Peak ops/s')),
              DataColumn(label: Text('P50')),
              DataColumn(label: Text('P95')),
              DataColumn(label: Text('P99')),
            ],
            rows: operationDetails
                .map(
                  (detail) => DataRow(
                    cells: [
                      DataCell(Text('${detail['operation'] ?? '-'}')),
                      DataCell(Text('${_intMetric(detail['count'])}')),
                      DataCell(
                        Text(
                            '${_doubleMetric(detail['sharePct']).toStringAsFixed(1)}%'),
                      ),
                      DataCell(
                        Text(_doubleMetric(detail['avgOpsPerSecond'])
                            .toStringAsFixed(1)),
                      ),
                      DataCell(
                        Text(_doubleMetric(detail['peakOpsPerSecond'])
                            .toStringAsFixed(1)),
                      ),
                      DataCell(Text(
                          '${_doubleMetric(detail['p50LatencyMs']).toStringAsFixed(1)} ms')),
                      DataCell(Text(
                          '${_doubleMetric(detail['p95LatencyMs']).toStringAsFixed(1)} ms')),
                      DataCell(Text(
                          '${_doubleMetric(detail['p99LatencyMs']).toStringAsFixed(1)} ms')),
                    ],
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _sizeDetailSection(
    BuildContext context,
    BenchmarkResultSummary summary,
  ) {
    if (summary.sizeLatencyBuckets.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Size bucket detail',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Latency spread by object size with counts and percentile bands.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Size')),
              DataColumn(label: Text('Count')),
              DataColumn(label: Text('Avg')),
              DataColumn(label: Text('P50')),
              DataColumn(label: Text('P95')),
              DataColumn(label: Text('P99')),
            ],
            rows: summary.sizeLatencyBuckets
                .map(
                  (bucket) => DataRow(
                    cells: [
                      DataCell(Text(_formatSizeLabel(
                          (bucket['sizeBytes'] as num?)?.toInt() ?? 0))),
                      DataCell(Text('${_intMetric(bucket['count'])}')),
                      DataCell(Text(
                          '${_doubleMetric(bucket['avgLatencyMs']).toStringAsFixed(1)} ms')),
                      DataCell(Text(
                          '${_doubleMetric(bucket['p50LatencyMs']).toStringAsFixed(1)} ms')),
                      DataCell(Text(
                          '${_doubleMetric(bucket['p95LatencyMs']).toStringAsFixed(1)} ms')),
                      DataCell(Text(
                          '${_doubleMetric(bucket['p99LatencyMs']).toStringAsFixed(1)} ms')),
                    ],
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _sampleWindowSection(
    BuildContext context,
    BenchmarkResultSummary summary,
  ) {
    if (summary.throughputSeries.isEmpty) {
      return const SizedBox.shrink();
    }
    final windows = summary.throughputSeries.length > 10
        ? summary.throughputSeries.sublist(summary.throughputSeries.length - 10)
        : summary.throughputSeries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent sample windows',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Latest benchmark windows with throughput, bandwidth, and latency.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Window')),
              DataColumn(label: Text('Ops/s')),
              DataColumn(label: Text('Bandwidth')),
              DataColumn(label: Text('Avg latency')),
              DataColumn(label: Text('P95 latency')),
              DataColumn(label: Text('Ops mix')),
            ],
            rows: windows
                .map(
                  (window) => DataRow(
                    cells: [
                      DataCell(Text(_pointLabel(window))),
                      DataCell(Text('${_intMetric(window['opsPerSecond'])}')),
                      DataCell(
                        Text(_formatBytesPerSecond(window['bytesPerSecond'])),
                      ),
                      DataCell(Text(
                          '${_doubleMetric(window['averageLatencyMs']).toStringAsFixed(1)} ms')),
                      DataCell(Text(
                          '${_doubleMetric(window['p95LatencyMs']).toStringAsFixed(1)} ms')),
                      DataCell(Text(_formatOperationMix(window['operations']))),
                    ],
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _previewControls(
    BuildContext context,
    BenchmarkResultSummary summary, {
    required StateSetter updateUi,
  }) {
    final operations = _availableOperations(summary);
    final enabledOperations = _enabledOperationsFor(summary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_previewSection != _BenchmarkPreviewSection.checksums)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                selected: enabledOperations.length == operations.length,
                label: const Text('All ops'),
                onSelected: (_) {
                  updateUi(() {
                    _enabledOperations.clear();
                  });
                },
              ),
              ...operations.map(
                (operation) => FilterChip(
                  selected: enabledOperations.contains(operation),
                  label: Text(operation),
                  onSelected: (selected) {
                    updateUi(() {
                      if (_enabledOperations.isEmpty) {
                        _enabledOperations.addAll(operations);
                      }
                      if (selected) {
                        _enabledOperations.add(operation);
                      } else {
                        _enabledOperations.remove(operation);
                      }
                      if (_enabledOperations.length == operations.length) {
                        _enabledOperations.clear();
                      }
                    });
                  },
                ),
              ),
            ],
          ),
        if (_previewSection != _BenchmarkPreviewSection.checksums)
          const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            switch (_previewSection) {
              _BenchmarkPreviewSection.operations => _choiceMenu<String>(
                  context,
                  label: 'Display',
                  currentLabel: _overlapOperationMix ? 'Overlap' : 'Split',
                  values: const <String>['Overlap', 'Split'],
                  onSelected: (value) {
                    updateUi(() {
                      _overlapOperationMix = value == 'Overlap';
                    });
                  },
                ),
              _BenchmarkPreviewSection.throughput =>
                _choiceMenu<_BenchmarkLineStyle>(
                  context,
                  label: 'Style',
                  currentLabel: _lineStyleLabel(_throughputStyle),
                  values: _BenchmarkLineStyle.values,
                  itemLabel: _lineStyleLabel,
                  onSelected: (value) {
                    updateUi(() {
                      _throughputStyle = value;
                    });
                  },
                ),
              _BenchmarkPreviewSection.latencyOverTime =>
                _choiceMenu<_BenchmarkLineStyle>(
                  context,
                  label: 'Style',
                  currentLabel: _lineStyleLabel(_latencyTimeStyle),
                  values: _BenchmarkLineStyle.values,
                  itemLabel: _lineStyleLabel,
                  onSelected: (value) {
                    updateUi(() {
                      _latencyTimeStyle = value;
                    });
                  },
                ),
              _BenchmarkPreviewSection.normalizedLatency =>
                _choiceMenu<_NormalizationTarget>(
                  context,
                  label: 'Normalize',
                  currentLabel: _normalizationLabel(_normalizationTarget),
                  values: _NormalizationTarget.values,
                  itemLabel: _normalizationLabel,
                  onSelected: (value) {
                    updateUi(() {
                      _normalizationTarget = value;
                    });
                  },
                ),
              _BenchmarkPreviewSection.sizes => _choiceMenu<_LatencyMetric>(
                  context,
                  label: 'Metric',
                  currentLabel: _latencyMetricLabel(_latencyMetric),
                  values: _LatencyMetric.values,
                  itemLabel: _latencyMetricLabel,
                  onSelected: (value) {
                    updateUi(() {
                      _latencyMetric = value;
                    });
                  },
                ),
              _ => const SizedBox.shrink(),
            },
            if (_previewSection == _BenchmarkPreviewSection.normalizedLatency)
              _choiceMenu<_BenchmarkLineStyle>(
                context,
                label: 'Style',
                currentLabel: _lineStyleLabel(_normalizedLatencyStyle),
                values: _BenchmarkLineStyle.values,
                itemLabel: _lineStyleLabel,
                onSelected: (value) {
                  updateUi(() {
                    _normalizedLatencyStyle = value;
                  });
                },
              ),
            if (_previewSection == _BenchmarkPreviewSection.sizes)
              _choiceMenu<_SizeChartStyle>(
                context,
                label: 'Chart',
                currentLabel: _sizeChartStyleLabel(_sizeChartStyle),
                values: _SizeChartStyle.values,
                itemLabel: _sizeChartStyleLabel,
                onSelected: (value) {
                  updateUi(() {
                    _sizeChartStyle = value;
                  });
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _latencyPreview(
    BuildContext context,
    BenchmarkResultSummary summary,
    double maxWidth,
  ) {
    final percentiles = _sortedPercentiles(summary);
    final operations = _enabledOperationsFor(summary);
    final width = math
        .max(maxWidth, operations.length * percentiles.length * 110)
        .toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Latency percentiles by operation',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Compare the available percentile bands across the selected operations.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 320,
          child: Scrollbar(
            thumbVisibility: width > maxWidth,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: operations
                      .map(
                        (operation) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: _groupedBars(
                              context,
                              title: operation,
                              entries: percentiles
                                  .map(
                                    (entry) => MapEntry(
                                      entry.key.toUpperCase(),
                                      summary.latencyPercentilesByOperationMs[
                                              operation]?[entry.key] ??
                                          (entry.value *
                                              _operationLatencyFactor(
                                                  operation)),
                                    ),
                                  )
                                  .toList(),
                              suffix: ' ms',
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _operationsPreview(
    BuildContext context,
    BenchmarkResultSummary summary,
    double maxWidth,
  ) {
    final series = _operationSeries(summary);
    if (_overlapOperationMix) {
      return _timeSeriesSection(
        context,
        title: 'Operation mix over time',
        subtitle:
            'Line chart view of the operation blend for each sample window.',
        series: series,
        chartHeight: 300,
        style: _BenchmarkLineStyle.line,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Operation mix over time',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Split view keeps each operation in its own chart for easier comparisons.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        ...series.map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _timeSeriesSection(
              context,
              title: entry.id,
              subtitle: 'Operations per second',
              series: <_ChartSeries>[entry],
              chartHeight: 180,
              style: _BenchmarkLineStyle.line,
            ),
          ),
        ),
      ],
    );
  }

  Widget _throughputPreview(
    BuildContext context,
    BenchmarkResultSummary summary,
    BoxConstraints constraints,
  ) {
    return _timeSeriesSection(
      context,
      title: 'Throughput over time',
      subtitle: 'Filter by operation or view the combined series.',
      series: _throughputSeries(summary),
      chartHeight: math.max(260, constraints.maxHeight - 80),
      style: _throughputStyle,
    );
  }

  Widget _latencyOverTimePreview(
    BuildContext context,
    BenchmarkResultSummary summary,
    BoxConstraints constraints,
  ) {
    return _timeSeriesSection(
      context,
      title: 'Latency over time',
      subtitle: 'Latency of every recorded request over benchmark time.',
      series: _latencyTimeSeries(summary),
      chartHeight: math.max(260, constraints.maxHeight - 80),
      style: _latencyTimeStyle,
      suffix: ' ms',
      pointSpacing: 14,
    );
  }

  Widget _normalizedLatencyPreview(
    BuildContext context,
    BenchmarkResultSummary summary,
    BoxConstraints constraints,
  ) {
    return _timeSeriesSection(
      context,
      title: 'Normalized latency over time',
      subtitle:
          'Latency scaled to ${_normalizationLabel(_normalizationTarget)} for easier comparison across object sizes.',
      series: _normalizedLatencySeries(summary),
      chartHeight: math.max(260, constraints.maxHeight - 80),
      style: _normalizedLatencyStyle,
      suffix: ' ms',
      pointSpacing: 14,
    );
  }

  Widget _sizePreview(
    BuildContext context,
    BenchmarkResultSummary summary,
    double maxWidth,
  ) {
    final entries = summary.sizeLatencyBuckets.map((item) {
      final sizeBytes = (item['sizeBytes'] as num?)?.toInt() ?? 0;
      return MapEntry(
        _formatSizeLabel(sizeBytes),
        switch (_latencyMetric) {
          _LatencyMetric.average =>
            (item['avgLatencyMs'] as num?)?.toDouble() ?? 0,
          _LatencyMetric.p50 => (item['p50LatencyMs'] as num?)?.toDouble() ??
              _sizeMetricValue(
                (item['avgLatencyMs'] as num?)?.toDouble() ?? 0,
                _latencyMetric,
              ),
          _LatencyMetric.p95 => (item['p95LatencyMs'] as num?)?.toDouble() ??
              _sizeMetricValue(
                (item['avgLatencyMs'] as num?)?.toDouble() ?? 0,
                _latencyMetric,
              ),
          _LatencyMetric.p99 => (item['p99LatencyMs'] as num?)?.toDouble() ??
              _sizeMetricValue(
                (item['avgLatencyMs'] as num?)?.toDouble() ?? 0,
                _latencyMetric,
              ),
        },
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Latency by object size',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Switch between average, p50, p95, and p99 and choose bars or a line chart.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (_sizeChartStyle == _SizeChartStyle.bars)
          SizedBox(
            height: 320,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: math.max(maxWidth, entries.length * 120),
                child: _barsForEntries(
                  context,
                  title: _latencyMetricLabel(_latencyMetric),
                  entries: entries,
                  suffix: ' ms',
                ),
              ),
            ),
          )
        else
          _timeSeriesSection(
            context,
            title: 'Latency by size',
            subtitle: _latencyMetricLabel(_latencyMetric),
            series: <_ChartSeries>[
              _ChartSeries(
                id: _latencyMetricLabel(_latencyMetric),
                color: Theme.of(context).colorScheme.primary,
                points: entries
                    .map((entry) =>
                        _ChartPoint(label: entry.key, value: entry.value))
                    .toList(),
              ),
            ],
            chartHeight: 300,
            style: _BenchmarkLineStyle.line,
            suffix: ' ms',
          ),
      ],
    );
  }

  Widget _checksumPreview(
    BuildContext context,
    BenchmarkResultSummary summary,
    BoxConstraints constraints,
  ) {
    final stats = summary.checksumStats.entries
        .where((entry) => entry.value > 0)
        .toList();
    if (stats.isEmpty) {
      return const Center(child: Text('No checksum statistics available.'));
    }
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final colors = <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.error,
    ];
    final total = stats.fold<int>(0, (current, entry) => current + entry.value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Checksum outcomes',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Share of checksum validation results across the run.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 28,
          runSpacing: 24,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: math.min(constraints.maxWidth * 0.45, 240),
              height: 240,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _PieChartPainter(
                      sections: List<_PieSection>.generate(
                        stats.length,
                        (index) => _PieSection(
                          value: stats[index].value.toDouble(),
                          color: colors[index % colors.length],
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$total',
                          style: textTheme.headlineSmall,
                        ),
                        Text(
                          'checks',
                          style: textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 240, maxWidth: 380),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List<Widget>.generate(
                  stats.length,
                  (index) {
                    final share =
                        total == 0 ? 0.0 : stats[index].value / total * 100;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: colors[index % colors.length]
                              .withValues(alpha: 0.08),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: colors[index % colors.length],
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                stats[index].key.replaceAll('_', ' '),
                                style: textTheme.bodyMedium,
                              ),
                            ),
                            Text(
                              '${stats[index].value}',
                              style: textTheme.labelLarge,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${share.toStringAsFixed(1)}%',
                              style: textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _timeSeriesSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required List<_ChartSeries> series,
    required double chartHeight,
    required _BenchmarkLineStyle style,
    String suffix = ' ops/s',
    double pointSpacing = 64,
  }) {
    if (series.isEmpty || series.every((entry) => entry.points.isEmpty)) {
      return Center(child: Text('No data available for $title.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: series
              .map(
                (entry) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: entry.color.withValues(alpha: 0.10),
                    border: Border.all(
                      color: entry.color.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: entry.color,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entry.id,
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        Text(
          _timeAxisSummary(series),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxPoints = series.fold<int>(
              0,
              (current, entry) =>
                  entry.points.length > current ? entry.points.length : current,
            );
            final chartWidth = math
                .max(constraints.maxWidth, maxPoints * pointSpacing)
                .toDouble();
            return SizedBox(
              height: chartHeight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: chartWidth,
                  height: chartHeight,
                  child: CustomPaint(
                    painter: _LineChartPainter(
                      series: series,
                      textColor: Theme.of(context).colorScheme.onSurface,
                      gridColor: Theme.of(context).colorScheme.outlineVariant,
                      area: style == _BenchmarkLineStyle.area,
                      suffix: suffix,
                      smooth: controller.settings.benchmarkChartSmoothing,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _groupedBars(
    BuildContext context, {
    required String title,
    required List<MapEntry<String, double>> entries,
    required String suffix,
  }) {
    return Column(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        Expanded(
          child: _barsForEntries(
            context,
            title: title,
            entries: entries,
            suffix: suffix,
          ),
        ),
      ],
    );
  }

  Widget _barsForEntries(
    BuildContext context, {
    required String title,
    required List<MapEntry<String, double>> entries,
    required String suffix,
  }) {
    final maxValue = entries.fold<double>(
      1,
      (current, entry) => entry.value > current ? entry.value : current,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: entries
          .map(
            (entry) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _bar(
                  context,
                  entry.key,
                  entry.value,
                  maxValue,
                  suffix: suffix,
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _bar(
    BuildContext context,
    String label,
    double value,
    double maxValue, {
    required String suffix,
  }) {
    const trackHeight = 190.0;
    final barHeight = maxValue <= 0
        ? 3.0
        : ((value / maxValue) * trackHeight).clamp(3.0, trackHeight);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '${value.toStringAsFixed(1)}$suffix',
          style: textTheme.labelMedium?.copyWith(color: scheme.onSurface),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: trackHeight,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 64),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(8)),
                      color: scheme.onSurface.withValues(alpha: 0.045),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    height: barHeight,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(8)),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          scheme.primary,
                          scheme.primary.withValues(alpha: 0.72),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: textTheme.labelMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _outputFileTile(BuildContext context, String label, String path) {
    if (path.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => controller.openPath(path),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              const Icon(Icons.link_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.labelLarge),
                    const SizedBox(height: 2),
                    Text(
                      path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Open file location',
                onPressed: () =>
                    controller.openPath(path, revealInFolder: true),
                icon: const Icon(Icons.folder_open_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _presetSelector(BuildContext context, BenchmarkConfig config) {
    final activePresetId = _activePresetId(config);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Presets', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in _benchmarkPresets)
              ChoiceChip(
                key: ValueKey('benchmark-preset-${preset.id}'),
                label: Text(preset.label),
                tooltip: preset.description,
                selected: activePresetId == preset.id,
                onSelected: (_) => _applyBenchmarkPreset(preset),
              ),
            ChoiceChip(
              key: const ValueKey('benchmark-preset-custom'),
              label: const Text('Custom'),
              tooltip:
                  'Active when the fields below differ from every preset. Edit any field to get here.',
              selected: activePresetId == null,
              onSelected: (_) {},
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: const Text(
            'Presets fill the fields below; edit anything afterwards and the selection becomes Custom. '
            'Quick check sanity-tests a target, Standard gives a balanced profile, and Throughput stress '
            'or IOPS stress are the ones that truly saturate a target.',
          ),
        ),
      ],
    );
  }

  String? _activePresetId(BenchmarkConfig config) {
    for (final preset in _benchmarkPresets) {
      if (_presetMatchesConfig(preset, config)) {
        return preset.id;
      }
    }
    return null;
  }

  bool _presetMatchesConfig(_BenchmarkPreset preset, BenchmarkConfig config) {
    if (config.workloadType != preset.workloadType ||
        config.testMode != 'duration' ||
        config.concurrentThreads != preset.concurrentThreads ||
        config.objectCount != preset.objectCount ||
        config.durationSeconds != preset.durationSeconds ||
        config.maxPoolConnections != preset.maxPoolConnections) {
      return false;
    }
    if (preset.validateChecksum != null &&
        config.validateChecksum != preset.validateChecksum) {
      return false;
    }
    if (preset.reducedLogging != null &&
        config.reducedLogging != preset.reducedLogging) {
      return false;
    }
    return _intListsEqual(config.objectSizes, preset.objectSizes);
  }

  bool _intListsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  void _applyBenchmarkPreset(_BenchmarkPreset preset) {
    FocusScope.of(context).unfocus();
    final config = controller.benchmarkDraft;
    controller.updateBenchmarkDraft(
      config.copyWith(
        workloadType: preset.workloadType,
        testMode: 'duration',
        objectSizes: preset.objectSizes,
        concurrentThreads: preset.concurrentThreads,
        objectCount: preset.objectCount,
        durationSeconds: preset.durationSeconds,
        maxPoolConnections: preset.maxPoolConnections,
        validateChecksum: preset.validateChecksum ?? config.validateChecksum,
        reducedLogging: preset.reducedLogging ?? config.reducedLogging,
      ),
    );
    _setFieldText('objectSizes', preset.objectSizes.join(','));
    _setFieldText('threads', '${preset.concurrentThreads}');
    _setFieldText('datasetObjectCount', '${preset.objectCount}');
    _setFieldText('durationSeconds', '${preset.durationSeconds}');
    _setFieldText('maxPoolConnections', '${preset.maxPoolConnections}');
  }

  void _setFieldText(String fieldKey, String value) {
    final fieldController = _fieldControllers[fieldKey];
    if (fieldController == null || fieldController.text == value) {
      return;
    }
    fieldController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Widget _textField({
    required String fieldKey,
    required String label,
    required String initialValue,
    required ValueChanged<String> onChanged,
  }) {
    final controller = _controllerFor(fieldKey, initialValue);
    final focusNode = _focusNodeFor(fieldKey);
    return TextFormField(
      key: ValueKey('benchmark-field-$fieldKey'),
      controller: controller,
      focusNode: focusNode,
      decoration: _fieldDecoration(label: label),
      onChanged: onChanged,
      onTapOutside: (_) => onChanged(controller.text),
      onFieldSubmitted: (_) => onChanged(controller.text),
    );
  }

  Widget _numberField({
    required String fieldKey,
    required String label,
    required int initialValue,
    required ValueChanged<int> onChanged,
    bool enabled = true,
    String? helperText,
  }) {
    final controller = _controllerFor(fieldKey, '$initialValue');
    final focusNode = _focusNodeFor(fieldKey);
    return TextFormField(
      key: ValueKey('benchmark-field-$fieldKey'),
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      keyboardType: TextInputType.number,
      decoration: _fieldDecoration(label: label, helperText: helperText),
      onChanged: (value) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) {
          onChanged(parsed);
        }
      },
      onTapOutside: (_) => _commitNumberController(controller, onChanged),
      onFieldSubmitted: (_) => _commitNumberController(controller, onChanged),
    );
  }

  InputDecoration _fieldDecoration({
    required String label,
    String? helperText,
  }) {
    return InputDecoration(
      labelText: label,
      helperText: helperText,
      helperMaxLines: 3,
    );
  }

  Widget _compactSwitchTile({
    required bool value,
    required ValueChanged<bool> onChanged,
    required Widget title,
    Widget? subtitle,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: title,
      subtitle: subtitle,
      dense: true,
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }

  TextEditingController _controllerFor(String fieldKey, String value) {
    final controller = _fieldControllers.putIfAbsent(
      fieldKey,
      () => TextEditingController(text: value),
    );
    final focusNode = _focusNodeFor(fieldKey);
    if (!focusNode.hasFocus && controller.text != value) {
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
    return controller;
  }

  FocusNode _focusNodeFor(String fieldKey) {
    return _fieldFocusNodes.putIfAbsent(fieldKey, FocusNode.new);
  }

  void _commitNumberController(
    TextEditingController controller,
    ValueChanged<int> onChanged,
  ) {
    final parsed = int.tryParse(controller.text.trim());
    if (parsed != null) {
      onChanged(parsed);
    }
  }

  void _flushBenchmarkEditors() {
    final draft = controller.benchmarkDraft;
    controller.updateBenchmarkDraft(
      draft.copyWith(
        prefix: _fieldControllers['prefix']?.text ?? draft.prefix,
        objectSizes:
            _parseObjectSizes(_fieldControllers['objectSizes']?.text) ??
                draft.objectSizes,
        concurrentThreads: _parseIntField('threads') ?? draft.concurrentThreads,
        objectCount: _parseIntField('datasetObjectCount') ?? draft.objectCount,
        durationSeconds:
            _parseIntField('durationSeconds') ?? draft.durationSeconds,
        operationCount:
            _parseIntField('operationCount') ?? draft.operationCount,
        connectTimeoutSeconds: _parseIntField('connectTimeoutSeconds') ??
            draft.connectTimeoutSeconds,
        readTimeoutSeconds:
            _parseIntField('readTimeoutSeconds') ?? draft.readTimeoutSeconds,
        maxAttempts: _parseIntField('maxAttempts') ?? draft.maxAttempts,
        maxPoolConnections:
            _parseIntField('maxPoolConnections') ?? draft.maxPoolConnections,
        dataCacheMb: _parseIntField('dataCacheMb') ?? draft.dataCacheMb,
        csvOutputPath:
            _fieldControllers['csvOutputPath']?.text ?? draft.csvOutputPath,
        jsonOutputPath:
            _fieldControllers['jsonOutputPath']?.text ?? draft.jsonOutputPath,
        logFilePath:
            _fieldControllers['logFilePath']?.text ?? draft.logFilePath,
      ),
    );
  }

  int? _parseIntField(String fieldKey) {
    return int.tryParse(_fieldControllers[fieldKey]?.text.trim() ?? '');
  }

  List<int>? _parseObjectSizes(String? rawValue) {
    if (rawValue == null) {
      return null;
    }
    final sizes = rawValue
        .split(',')
        .map((item) => int.tryParse(item.trim()))
        .whereType<int>()
        .toList();
    return sizes.isEmpty ? null : sizes;
  }

  double _activeBenchmarkSeconds(BenchmarkRun run) {
    final activeElapsedSeconds = run.activeElapsedSeconds;
    if (activeElapsedSeconds != null && activeElapsedSeconds >= 0) {
      return activeElapsedSeconds.clamp(
        0,
        run.config.durationSeconds.toDouble(),
      );
    }
    return DateTime.now()
        .difference(run.startedAt)
        .inSeconds
        .toDouble()
        .clamp(0, run.config.durationSeconds.toDouble());
  }

  /// Card shown when the workload type is 'custom', with sliders for
  /// read / write / delete percentages that always sum to 100.
  Widget _customMixCard(BuildContext context, BenchmarkConfig config) {
    final total =
        config.readPercent + config.writePercent + config.deletePercent;
    final balanced = total == 100;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: balanced
            ? null
            : Border.all(
                color:
                    Theme.of(context).colorScheme.error.withValues(alpha: 0.6),
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Custom operation mix',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Chip(
                label: Text(
                  'Total: $total%',
                  style: TextStyle(
                    color: balanced
                        ? Colors.green.shade700
                        : Theme.of(context).colorScheme.error,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide.none,
                backgroundColor: balanced
                    ? Colors.green.shade50
                    : Theme.of(context)
                        .colorScheme
                        .errorContainer
                        .withValues(alpha: 0.4),
              ),
            ],
          ),
          if (!balanced)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                'Percentages must sum to 100. Adjust the sliders below.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 8),
          _mixSlider(
            context,
            label: 'Write (PUT)',
            percent: config.writePercent,
            color: Colors.teal.shade600,
            onChanged: (value) {
              // Clamp so write + read ≤ 100, give remainder to delete.
              final clamped = value.clamp(0, 100 - config.readPercent);
              controller.updateBenchmarkDraft(config.copyWith(
                writePercent: clamped,
                deletePercent: 100 - clamped - config.readPercent,
              ));
            },
          ),
          _mixSlider(
            context,
            label: 'Read (GET)',
            percent: config.readPercent,
            color: Colors.blue.shade600,
            onChanged: (value) {
              final clamped = value.clamp(0, 100 - config.writePercent);
              controller.updateBenchmarkDraft(config.copyWith(
                readPercent: clamped,
                deletePercent: 100 - config.writePercent - clamped,
              ));
            },
          ),
          _mixSlider(
            context,
            label: 'Delete',
            percent: config.deletePercent,
            color: Colors.red.shade600,
            onChanged: (value) {
              final clamped = value.clamp(0, 100 - config.writePercent);
              controller.updateBenchmarkDraft(config.copyWith(
                deletePercent: clamped,
                readPercent: 100 - config.writePercent - clamped,
              ));
            },
          ),
        ],
      ),
    );
  }

  Widget _mixSlider(
    BuildContext context, {
    required String label,
    required int percent,
    required Color color,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: color,
              thumbColor: color,
              overlayColor: color.withValues(alpha: 0.2),
            ),
            child: Slider(
              min: 0,
              max: 100,
              divisions: 100,
              value: percent.toDouble(),
              label: '$percent%',
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '$percent%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: color,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _choiceMenu<T>(
    BuildContext context, {
    required String label,
    required String currentLabel,
    required List<T> values,
    required ValueChanged<T> onSelected,
    String Function(T value)? itemLabel,
  }) {
    T? selectedValue;
    for (final value in values) {
      final optionLabel = itemLabel?.call(value) ?? value.toString();
      if (optionLabel == currentLabel) {
        selectedValue = value;
        break;
      }
    }
    return SizedBox(
      width: 184,
      child: AppSelectField<T>(
        value: selectedValue,
        decoration: _fieldDecoration(label: label),
        menuMaxHeight: 240,
        items: values
            .map(
              (value) => AppSelectItem<T>(
                value: value,
                label: itemLabel?.call(value) ?? value.toString(),
                icon: Icons.tune,
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value != null) {
            onSelected(value);
          }
        },
      ),
    );
  }

  List<MapEntry<String, String>> _outputFileEntries(BenchmarkRun run) {
    return <MapEntry<String, String>>[
      MapEntry('CSV', run.config.csvOutputPath),
      MapEntry('JSON', run.config.jsonOutputPath),
      MapEntry('Log', run.config.logFilePath),
    ];
  }

  List<MapEntry<String, double>> _sortedPercentiles(
      BenchmarkResultSummary summary) {
    final entries = summary.latencyPercentilesMs.entries.toList();
    const order = <String>['p50', 'p75', 'p90', 'p95', 'p99', 'p999'];
    entries.sort((left, right) {
      final leftIndex = order.indexOf(left.key.toLowerCase());
      final rightIndex = order.indexOf(right.key.toLowerCase());
      if (leftIndex == -1 || rightIndex == -1) {
        return left.key.compareTo(right.key);
      }
      return leftIndex.compareTo(rightIndex);
    });
    return entries;
  }

  List<String> _availableOperations(BenchmarkResultSummary summary) {
    final operations = summary.operationsByType.keys.toList()..sort();
    return operations;
  }

  List<String> _enabledOperationsFor(BenchmarkResultSummary summary) {
    final operations = _availableOperations(summary);
    if (_enabledOperations.isEmpty) {
      return operations;
    }
    return operations.where(_enabledOperations.contains).toList();
  }

  void _syncOperationFilter(List<String> availableOperations) {
    if (_enabledOperations.isEmpty) {
      return;
    }
    _enabledOperations.removeWhere(
      (entry) => !availableOperations.contains(entry),
    );
  }

  List<_ChartSeries> _operationSeries(BenchmarkResultSummary summary) {
    final selected = _enabledOperationsFor(summary);
    final weights = _operationWeights(summary);
    return selected
        .map(
          (operation) => _ChartSeries(
            id: operation,
            color: _seriesColor(operation),
            points: summary.throughputSeries
                .map(
                  (point) => _ChartPoint(
                    label: _pointLabel(point),
                    x: _pointX(point),
                    value: _operationValueForPoint(
                      point,
                      operation,
                      fallback:
                          ((point['opsPerSecond'] as num?)?.toDouble() ?? 0) *
                              (weights[operation] ?? 0),
                    ),
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  List<_ChartSeries> _throughputSeries(BenchmarkResultSummary summary) {
    final selected = _enabledOperationsFor(summary);
    final allOperations = _availableOperations(summary);
    final weights = _operationWeights(summary);
    if (_throughputStyle != _BenchmarkLineStyle.area &&
        selected.length == allOperations.length) {
      return <_ChartSeries>[
        _ChartSeries(
          id: 'All operations',
          color: Theme.of(context).colorScheme.primary,
          points: summary.throughputSeries
              .map(
                (point) => _ChartPoint(
                  label: _pointLabel(point),
                  x: _pointX(point),
                  value: (point['opsPerSecond'] as num?)?.toDouble() ?? 0,
                ),
              )
              .toList(),
        ),
      ];
    }
    return selected
        .map(
          (operation) => _ChartSeries(
            id: operation,
            color: _seriesColor(operation),
            points: summary.throughputSeries
                .map(
                  (point) => _ChartPoint(
                    label: _pointLabel(point),
                    x: _pointX(point),
                    value: _operationValueForPoint(
                      point,
                      operation,
                      fallback:
                          ((point['opsPerSecond'] as num?)?.toDouble() ?? 0) *
                              (weights[operation] ?? 0),
                    ),
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  List<_ChartSeries> _latencyTimeSeries(BenchmarkResultSummary summary) {
    final requestTimeline = _latencyTimeline(summary);
    if (requestTimeline.isNotEmpty) {
      return _latencyTimelineSeries(summary, requestTimeline);
    }
    final selected = _enabledOperationsFor(summary);
    final throughputEntries = summary.throughputSeries
        .map(
          (point) => MapEntry<int, double>(
            (point['second'] as num?)?.toInt() ?? 0,
            (point['opsPerSecond'] as num?)?.toDouble() ?? 0,
          ),
        )
        .where((entry) => entry.key > 0)
        .toList();
    if (throughputEntries.isEmpty) {
      return const <_ChartSeries>[];
    }
    final minOps = throughputEntries
        .map((entry) => entry.value)
        .reduce((left, right) => left < right ? left : right);
    final maxOps = throughputEntries
        .map((entry) => entry.value)
        .reduce((left, right) => left > right ? left : right);
    final spread = math.max((maxOps - minOps).abs(), 1);
    final averageLatency = summary.latencyPercentilesMs.isEmpty
        ? 0.0
        : summary.latencyPercentilesMs.values
                .reduce((left, right) => left + right) /
            summary.latencyPercentilesMs.length;

    return selected
        .map(
          (operation) => _ChartSeries(
            id: operation,
            color: _seriesColor(operation),
            points: throughputEntries.map((entry) {
              final rawPoint = summary.throughputSeries.firstWhere(
                (point) =>
                    ((point['second'] as num?)?.toInt() ?? 0) == entry.key,
                orElse: () => const <String, Object?>{},
              );
              final latencyByOperation = rawPoint['latencyByOperationMs'];
              final load = (entry.value - minOps) / spread;
              final latencyValue = latencyByOperation is Map
                  ? latencyByOperation[operation]
                  : null;
              final latency = latencyValue is! num
                  ? averageLatency *
                      (0.8 + (load * 0.4)) *
                      _operationLatencyFactor(operation)
                  : latencyValue.toDouble();
              return _ChartPoint(
                label: _pointLabel(rawPoint, fallbackSecond: entry.key),
                x: _pointX(rawPoint, fallbackSecond: entry.key),
                value: double.parse(latency.toStringAsFixed(1)),
              );
            }).toList(),
          ),
        )
        .toList();
  }

  List<_ChartSeries> _normalizedLatencySeries(BenchmarkResultSummary summary) {
    final requestTimeline = _latencyTimeline(summary);
    if (requestTimeline.isNotEmpty) {
      return _latencyTimelineSeries(
        summary,
        requestTimeline,
        normalized: true,
      );
    }
    final selected = _enabledOperationsFor(summary);
    final sizeMiB =
        _averageObjectSizeMiB(summary).clamp(0.001, 1 << 20).toDouble();
    final targetMiB = switch (_normalizationTarget) {
      _NormalizationTarget.mib1 => 1.0,
      _NormalizationTarget.mb100 => 100.0,
      _NormalizationTarget.gb1 => 1024.0,
    };

    return _latencyTimeSeries(summary)
        .where((entry) => selected.contains(entry.id))
        .map(
          (entry) => _ChartSeries(
            id: entry.id,
            color: entry.color,
            points: entry.points
                .map(
                  (point) => _ChartPoint(
                    label: point.label,
                    value: double.parse(
                      ((point.value / sizeMiB) * targetMiB).toStringAsFixed(1),
                    ),
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  List<Map<String, Object?>> _latencyTimeline(BenchmarkResultSummary summary) {
    final timeline = summary.latencyTimeline
        .map((entry) => Map<String, Object?>.from(entry))
        .toList();
    timeline.sort((left, right) {
      final leftSequence = _intMetric(left['sequence']);
      final rightSequence = _intMetric(right['sequence']);
      if (leftSequence != rightSequence) {
        return leftSequence.compareTo(rightSequence);
      }
      final leftElapsed = _doubleMetric(left['elapsedMs']);
      final rightElapsed = _doubleMetric(right['elapsedMs']);
      if (leftElapsed != rightElapsed) {
        return leftElapsed.compareTo(rightElapsed);
      }
      return _intMetric(left['second']).compareTo(_intMetric(right['second']));
    });
    return timeline;
  }

  List<_ChartSeries> _latencyTimelineSeries(
    BenchmarkResultSummary summary,
    List<Map<String, Object?>> timeline, {
    bool normalized = false,
  }) {
    final selected = _enabledOperationsFor(summary);
    final targetMiB = switch (_normalizationTarget) {
      _NormalizationTarget.mib1 => 1.0,
      _NormalizationTarget.mb100 => 100.0,
      _NormalizationTarget.gb1 => 1024.0,
    };
    return selected
        .map(
          (operation) => _ChartSeries(
            id: operation,
            color: _seriesColor(operation),
            points: timeline
                .where(
              (entry) =>
                  entry['operation']?.toString().toUpperCase() == operation,
            )
                .map((entry) {
              final latency = _doubleMetric(entry['latencyMs']);
              final sizeBytes = _intMetric(entry['sizeBytes']);
              final scaledLatency = sizeBytes <= 0
                  ? latency
                  : (latency / (sizeBytes / (1024 * 1024))) * targetMiB;
              return _ChartPoint(
                label: _pointLabel(entry),
                value: double.parse(
                  (normalized ? scaledLatency : latency).toStringAsFixed(1),
                ),
                x: _doubleMetric(entry['elapsedMs']) / 1000,
              );
            }).toList(),
          ),
        )
        .where((entry) => entry.points.isNotEmpty)
        .toList();
  }

  Map<String, double> _operationWeights(BenchmarkResultSummary summary) {
    final total = summary.operationsByType.values
        .fold<int>(0, (left, right) => left + right);
    if (total == 0) {
      return <String, double>{
        for (final operation in summary.operationsByType.keys) operation: 0,
      };
    }
    return <String, double>{
      for (final entry in summary.operationsByType.entries)
        entry.key: entry.value / total,
    };
  }

  Color _seriesColor(String operation) {
    return switch (operation.toUpperCase()) {
      'PUT' => const Color(0xFF0F766E),
      'GET' => const Color(0xFF2563EB),
      'DELETE' => const Color(0xFFDC2626),
      'POST' => const Color(0xFFF59E0B),
      'HEAD' => const Color(0xFF7C3AED),
      _ => const Color(0xFF475569),
    };
  }

  double _operationLatencyFactor(String operation) {
    return switch (operation.toUpperCase()) {
      'PUT' => 1.18,
      'GET' => 0.92,
      'DELETE' => 0.86,
      'POST' => 1.06,
      'HEAD' => 0.74,
      _ => 1.0,
    };
  }

  double _averageObjectSizeMiB(BenchmarkResultSummary summary) {
    if (summary.sizeLatencyBuckets.isEmpty) {
      return 1.0;
    }
    final total = summary.sizeLatencyBuckets.fold<double>(
      0,
      (current, item) =>
          current +
          (((item['sizeBytes'] as num?)?.toDouble() ?? 0) / (1024 * 1024)),
    );
    return total / summary.sizeLatencyBuckets.length;
  }

  double _sizeMetricValue(double averageLatency, _LatencyMetric metric) {
    return switch (metric) {
      _LatencyMetric.average => averageLatency,
      _LatencyMetric.p50 => averageLatency * 0.82,
      _LatencyMetric.p95 => averageLatency * 1.18,
      _LatencyMetric.p99 => averageLatency * 1.42,
    };
  }

  String _previewLabel(_BenchmarkPreviewSection section) {
    return switch (section) {
      _BenchmarkPreviewSection.latency => 'Percentiles',
      _BenchmarkPreviewSection.operations => 'Op mix',
      _BenchmarkPreviewSection.throughput => 'Throughput/time',
      _BenchmarkPreviewSection.latencyOverTime => 'Latency/time',
      _BenchmarkPreviewSection.normalizedLatency => 'Latency normalized',
      _BenchmarkPreviewSection.sizes => 'By size',
      _BenchmarkPreviewSection.checksums => 'Checksums',
    };
  }

  IconData _previewIcon(_BenchmarkPreviewSection section) {
    return switch (section) {
      _BenchmarkPreviewSection.latency => Icons.timer_outlined,
      _BenchmarkPreviewSection.operations => Icons.account_tree_outlined,
      _BenchmarkPreviewSection.throughput => Icons.speed_outlined,
      _BenchmarkPreviewSection.latencyOverTime => Icons.show_chart,
      _BenchmarkPreviewSection.normalizedLatency => Icons.scale_outlined,
      _BenchmarkPreviewSection.sizes => Icons.stacked_bar_chart_outlined,
      _BenchmarkPreviewSection.checksums => Icons.verified_outlined,
    };
  }

  String _lineStyleLabel(_BenchmarkLineStyle style) {
    return switch (style) {
      _BenchmarkLineStyle.line => 'Line',
      _BenchmarkLineStyle.area => 'Area',
    };
  }

  String _latencyMetricLabel(_LatencyMetric metric) {
    return switch (metric) {
      _LatencyMetric.average => 'Average',
      _LatencyMetric.p50 => 'P50',
      _LatencyMetric.p95 => 'P95',
      _LatencyMetric.p99 => 'P99',
    };
  }

  String _normalizationLabel(_NormalizationTarget target) {
    return switch (target) {
      _NormalizationTarget.mib1 => '1 MiB',
      _NormalizationTarget.mb100 => '100 MiB',
      _NormalizationTarget.gb1 => '1 GiB',
    };
  }

  String _sizeChartStyleLabel(_SizeChartStyle style) {
    return switch (style) {
      _SizeChartStyle.bars => 'Bars',
      _SizeChartStyle.line => 'Line',
    };
  }

  String _formatSizeLabel(int sizeBytes) {
    if (sizeBytes >= 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(0)} GiB';
    }
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MiB';
    }
    if (sizeBytes >= 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(0)} KiB';
    }
    return '$sizeBytes B';
  }

  String _pointLabel(
    Map<String, Object?> point, {
    int? fallbackSecond,
  }) {
    final label = point['label']?.toString().trim() ?? '';
    if (label.isNotEmpty) {
      return label;
    }
    final elapsedMs = (point['elapsedMs'] as num?)?.toDouble();
    if (elapsedMs != null && elapsedMs >= 0) {
      final elapsedSeconds = elapsedMs / 1000;
      final fractionDigits = elapsedSeconds >= 100
          ? 0
          : elapsedSeconds >= 10
              ? 1
              : 2;
      return '${elapsedSeconds.toStringAsFixed(fractionDigits)}s';
    }
    final second = (point['second'] as num?)?.toInt() ?? fallbackSecond ?? 0;
    return second > 0 ? '${second}s' : '-';
  }

  double? _pointX(
    Map<String, Object?> point, {
    int? fallbackSecond,
  }) {
    final elapsedMs = (point['elapsedMs'] as num?)?.toDouble();
    if (elapsedMs != null && elapsedMs >= 0) {
      return elapsedMs / 1000;
    }
    final second =
        (point['second'] as num?)?.toDouble() ?? fallbackSecond?.toDouble();
    if (second != null && second > 0) {
      return second;
    }
    final label = point['label']?.toString();
    if (label == null || label.trim().isEmpty) {
      return null;
    }
    return _labelSeconds(label);
  }

  String _timeAxisSummary(List<_ChartSeries> series) {
    final explicitPoints = series
        .expand((entry) => entry.points)
        .where((point) => point.x != null)
        .toList()
      ..sort((left, right) => (left.x ?? 0).compareTo(right.x ?? 0));
    final points = explicitPoints.isNotEmpty
        ? explicitPoints
        : (series.isEmpty ? const <_ChartPoint>[] : series.first.points);
    if (points.isEmpty) {
      return 'Time axis: no samples recorded.';
    }
    final summaryPoints = explicitPoints.isEmpty
        ? points
        : () {
            final unique = <_ChartPoint>[];
            String? lastLabel;
            for (final point in points) {
              if (point.label == lastLabel) {
                continue;
              }
              unique.add(point);
              lastLabel = point.label;
            }
            return unique;
          }();
    final first = summaryPoints.first.label;
    final last = summaryPoints.last.label;
    final count =
        explicitPoints.isNotEmpty ? explicitPoints.length : points.length;
    final firstSeconds = _labelSeconds(first);
    final secondSeconds =
        summaryPoints.length > 1 ? _labelSeconds(summaryPoints[1].label) : null;
    final cadence = firstSeconds == null || secondSeconds == null
        ? (count < 2
            ? 'single sample'
            : 'sample spacing follows benchmark windows')
        : _formatSampleCadence((secondSeconds - firstSeconds).abs());
    return 'Time axis: $first to $last - $count samples - $cadence';
  }

  double? _labelSeconds(String label) {
    final match = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(label.trim());
    if (match == null) {
      return null;
    }
    return double.tryParse(match.group(1)!);
  }

  String _formatSampleCadence(double seconds) {
    if (seconds <= 0) {
      return 'variable intervals';
    }
    if (seconds < 1) {
      return '${(seconds * 1000).round()} ms intervals';
    }
    final fractionDigits =
        seconds >= 10 || seconds == seconds.roundToDouble() ? 0 : 1;
    return '${seconds.toStringAsFixed(fractionDigits)}s intervals';
  }

  double _operationValueForPoint(
    Map<String, Object?> point,
    String operation, {
    required double fallback,
  }) {
    final operations = point['operations'];
    if (operations is Map) {
      final value = operations[operation];
      if (value is num) {
        return value.toDouble();
      }
    }
    return fallback;
  }

  String _formatOperationMix(Object? operations) {
    if (operations is! Map) {
      return '-';
    }
    return operations.entries
        .map((entry) => '${entry.key} ${entry.value}')
        .join(' - ');
  }

  int _intMetric(Object? value) {
    return (value as num?)?.toInt() ?? 0;
  }

  double _doubleMetric(Object? value) {
    return (value as num?)?.toDouble() ?? 0;
  }

  String _formatBytesPerSecond(Object? value) {
    final bytesPerSecond = (value as num?)?.toDouble() ?? 0;
    if (bytesPerSecond >= 1024 * 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB/s';
    }
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MiB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(2)} KiB/s';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }

  Future<void> _exportPreviewImage(
    BenchmarkRun? run, {
    GlobalKey? exportKey,
  }) async {
    final boundary =
        exportKey?.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      controller.showBannerMessage(
        'Preview image export is not ready yet. Try again in a moment.',
        category: 'Benchmark',
        source: 'benchmark',
      );
      return;
    }

    final image = await boundary.toImage(
      pixelRatio: math.max(2, MediaQuery.of(context).devicePixelRatio),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      controller.showBannerMessage(
        'Preview image export failed because no image data was returned.',
        category: 'Benchmark',
        source: 'benchmark',
      );
      return;
    }

    final safeRunId = (run?.id ?? 'benchmark-preview').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final file = File(
      '${controller.settings.downloadPath}${Platform.pathSeparator}$safeRunId-preview-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    final buffer = bytes.buffer;
    await file.writeAsBytes(
      Uint8List.view(buffer, bytes.offsetInBytes, bytes.lengthInBytes),
    );
    controller.showBannerMessage(
      'Benchmark preview exported to ${file.path}.',
      category: 'Benchmark',
      source: 'benchmark',
    );
  }
}

class _PieSection {
  const _PieSection({
    required this.value,
    required this.color,
  });

  final double value;
  final Color color;
}

class _PieChartPainter extends CustomPainter {
  const _PieChartPainter({
    required this.sections,
  });

  final List<_PieSection> sections;

  @override
  void paint(Canvas canvas, Size size) {
    final total = sections.fold<double>(0, (left, right) => left + right.value);
    if (total <= 0) {
      return;
    }
    final stroke = size.shortestSide * 0.15;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.shortestSide - stroke) / 2,
    );
    // A small angular gap between segments keeps adjacent colors readable;
    // with a single segment there is nothing to separate.
    final gap = sections.length > 1 ? 0.035 : 0.0;
    var startAngle = -math.pi / 2;
    for (final section in sections) {
      final sweep = (section.value / total) * math.pi * 2;
      final visibleSweep = math.max(sweep - gap, 0.02);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.butt
        ..strokeWidth = stroke
        ..color = section.color;
      canvas.drawArc(
        rect,
        startAngle + (gap / 2),
        visibleSweep,
        false,
        paint,
      );
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter oldDelegate) {
    return oldDelegate.sections != sections;
  }
}

class _LineChartPainter extends CustomPainter {
  const _LineChartPainter({
    required this.series,
    required this.textColor,
    required this.gridColor,
    required this.area,
    required this.suffix,
    this.smooth = true,
  });

  final List<_ChartSeries> series;
  final Color textColor;
  final Color gridColor;
  final bool area;
  final String suffix;
  final bool smooth;

  static const double _leftPadding = 64.0;
  static const double _rightPadding = 14.0;
  static const double _topPadding = 26.0;
  static const double _bottomPadding = 34.0;

  /// Points above this count stop rendering per-point markers so dense series
  /// read as clean lines instead of dot clouds.
  static const int _markerPointLimit = 48;

  @override
  void paint(Canvas canvas, Size size) {
    final chartWidth = size.width - _leftPadding - _rightPadding;
    final chartHeight = size.height - _topPadding - _bottomPadding;
    if (chartWidth <= 0 || chartHeight <= 0) {
      return;
    }

    final maxPoints = series.fold<int>(
      0,
      (current, entry) =>
          entry.points.length > current ? entry.points.length : current,
    );
    if (maxPoints == 0) {
      return;
    }
    final hasExplicitX = _hasExplicitX();
    final minX = hasExplicitX ? _seriesMinX() : 0.0;
    final maxX =
        hasExplicitX ? _seriesMaxX() : math.max(maxPoints - 1, 1).toDouble();
    final maxValue = _niceCeil(
      _resolvedMaxValue(
        hasExplicitX: hasExplicitX,
        maxPoints: maxPoints,
      ),
    );

    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final verticalGridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = textColor.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final textStyle = TextStyle(
      color: textColor.withValues(alpha: 0.72),
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    final unitPainter = TextPainter(
      text: TextSpan(
        text: suffix.trim(),
        style: textStyle.copyWith(fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _leftPadding + 40);
    unitPainter.paint(canvas, const Offset(4, 2));

    for (var row = 0; row <= 4; row += 1) {
      final y = _topPadding + (chartHeight * row / 4);
      if (row < 4) {
        canvas.drawLine(
          Offset(_leftPadding, y),
          Offset(size.width - _rightPadding, y),
          gridPaint,
        );
      }
      final value = maxValue * (1 - (row / 4));
      final painter = TextPainter(
        text: TextSpan(
          text: _formatAxisValue(value),
          style: textStyle,
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
      )..layout(maxWidth: _leftPadding - 10);
      painter.paint(
        canvas,
        Offset(_leftPadding - 8 - painter.width, y - painter.height / 2),
      );
    }

    canvas.drawLine(
      Offset(_leftPadding, size.height - _bottomPadding),
      Offset(size.width - _rightPadding, size.height - _bottomPadding),
      axisPaint,
    );

    if (hasExplicitX) {
      final tickStep = _timeTickStep(
        minX: minX,
        maxX: maxX,
        chartWidth: chartWidth,
      );
      for (final tick in _timeTicks(
        minX: minX,
        maxX: maxX,
        step: tickStep,
      )) {
        final dx = _chartDx(
          chartWidth: chartWidth,
          leftPadding: _leftPadding,
          index: 0,
          count: 1,
          x: tick,
          hasExplicitX: true,
          minX: minX,
          maxX: maxX,
        );
        canvas.drawLine(
          Offset(dx, _topPadding),
          Offset(dx, size.height - _bottomPadding),
          verticalGridPaint,
        );
        canvas.drawLine(
          Offset(dx, size.height - _bottomPadding),
          Offset(dx, size.height - _bottomPadding + 4),
          axisPaint,
        );
        final labelPainter = TextPainter(
          text: TextSpan(
            text: _formatTimeTickLabel(tick, tickStep),
            style: textStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 64);
        labelPainter.paint(
          canvas,
          Offset(
            dx - (labelPainter.width / 2),
            size.height - _bottomPadding + 8,
          ),
        );
      }
    }

    final labelPoints =
        hasExplicitX ? const <_ChartPoint>[] : _axisLabelPoints();
    if (!hasExplicitX && labelPoints.isEmpty) {
      return;
    }
    if (!hasExplicitX) {
      final labelStep = math.max(1, (labelPoints.length / 8).ceil());
      for (var index = 0; index < labelPoints.length; index += 1) {
        if (index % labelStep != 0 && index != labelPoints.length - 1) {
          continue;
        }
        final dx = _chartDx(
          chartWidth: chartWidth,
          leftPadding: _leftPadding,
          index: index,
          count: labelPoints.length,
          x: labelPoints[index].x,
          hasExplicitX: hasExplicitX,
          minX: minX,
          maxX: maxX,
        );
        canvas.drawLine(
          Offset(dx, size.height - _bottomPadding),
          Offset(dx, size.height - _bottomPadding + 4),
          axisPaint,
        );
        final labelPainter = TextPainter(
          text: TextSpan(text: labelPoints[index].label, style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 56);
        labelPainter.paint(
          canvas,
          Offset(
            dx - (labelPainter.width / 2),
            size.height - _bottomPadding + 8,
          ),
        );
      }
    }

    if (area && !hasExplicitX) {
      _paintStackedAreas(
        canvas,
        chartWidth: chartWidth,
        chartHeight: chartHeight,
        leftPadding: _leftPadding,
        topPadding: _topPadding,
        bottomPadding: _bottomPadding,
        maxValue: maxValue,
      );
      return;
    }

    final baseline = _topPadding + chartHeight;
    for (final entry in series) {
      if (entry.points.isEmpty) {
        continue;
      }
      final offsets = <Offset>[];
      for (var index = 0; index < entry.points.length; index += 1) {
        final point = entry.points[index];
        final dx = _chartDx(
          chartWidth: chartWidth,
          leftPadding: _leftPadding,
          index: index,
          count: entry.points.length,
          x: point.x,
          hasExplicitX: hasExplicitX,
          minX: minX,
          maxX: maxX,
        );
        final dy = baseline - ((point.value / maxValue) * chartHeight);
        offsets.add(Offset(dx, dy));
      }

      final linePath = _seriesPath(offsets);
      final fillAlpha = area ? 0.20 : 0.08;
      final fillPath = Path.from(linePath)
        ..lineTo(offsets.last.dx, baseline)
        ..lineTo(offsets.first.dx, baseline)
        ..close();
      canvas.drawPath(
        fillPath,
        Paint()
          ..style = PaintingStyle.fill
          ..shader = ui.Gradient.linear(
            const Offset(0, _topPadding),
            Offset(0, baseline),
            <Color>[
              entry.color.withValues(alpha: fillAlpha),
              entry.color.withValues(alpha: 0.0),
            ],
          ),
      );
      canvas.drawPath(
        linePath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = entry.color,
      );
      if (offsets.length <= _markerPointLimit) {
        for (final offset in offsets) {
          canvas.drawCircle(
            offset,
            2.6,
            Paint()..color = entry.color,
          );
        }
      } else {
        canvas.drawCircle(
          offsets.last,
          3.2,
          Paint()..color = entry.color,
        );
      }
    }
  }

  /// Builds the series polyline, optionally smoothed with Catmull-Rom style
  /// cubic segments. Control-point y values are clamped to the chart band so
  /// the curve never dips below the baseline.
  Path _seriesPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    if (!smooth || points.length < 3) {
      for (var index = 1; index < points.length; index += 1) {
        path.lineTo(points[index].dx, points[index].dy);
      }
      return path;
    }
    final minY = points.fold<double>(
      double.infinity,
      (current, point) => point.dy < current ? point.dy : current,
    );
    final maxY = points.fold<double>(
      double.negativeInfinity,
      (current, point) => point.dy > current ? point.dy : current,
    );
    for (var index = 0; index < points.length - 1; index += 1) {
      final previous = index == 0 ? points[0] : points[index - 1];
      final current = points[index];
      final next = points[index + 1];
      final afterNext = index + 2 < points.length ? points[index + 2] : next;
      final control1 = Offset(
        current.dx + (next.dx - previous.dx) / 6,
        (current.dy + (next.dy - previous.dy) / 6).clamp(minY, maxY),
      );
      final control2 = Offset(
        next.dx - (afterNext.dx - current.dx) / 6,
        (next.dy - (afterNext.dy - current.dy) / 6).clamp(minY, maxY),
      );
      path.cubicTo(
        control1.dx,
        control1.dy,
        control2.dx,
        control2.dy,
        next.dx,
        next.dy,
      );
    }
    return path;
  }

  /// Rounds up to a value whose quarters land on clean axis labels.
  double _niceCeil(double value) {
    if (value <= 0 || !value.isFinite) {
      return 1;
    }
    final exponent = (math.log(value) / math.ln10).floor();
    final magnitude = math.pow(10.0, exponent).toDouble();
    final normalized = value / magnitude;
    const niceSteps = <double>[1, 2, 4, 5, 10];
    for (final step in niceSteps) {
      if (normalized <= step + 0.0001) {
        return step * magnitude;
      }
    }
    return 10 * magnitude;
  }

  bool _hasExplicitX() {
    return series.any((entry) => entry.points.any((point) => point.x != null));
  }

  double _seriesMinX() {
    return series
        .expand((entry) => entry.points)
        .map((point) => point.x)
        .whereType<double>()
        .fold<double>(double.infinity, (current, value) {
      return value < current ? value : current;
    });
  }

  double _seriesMaxX() {
    return series
        .expand((entry) => entry.points)
        .map((point) => point.x)
        .whereType<double>()
        .fold<double>(double.negativeInfinity, (current, value) {
      return value > current ? value : current;
    });
  }

  List<_ChartPoint> _axisLabelPoints() {
    if (!_hasExplicitX()) {
      final labelSeries = series.firstWhere(
        (entry) => entry.points.isNotEmpty,
        orElse: () => const _ChartSeries(
          id: '-',
          color: Colors.transparent,
          points: <_ChartPoint>[],
        ),
      );
      return labelSeries.points;
    }
    final flattened = series
        .expand((entry) => entry.points)
        .where((point) => point.x != null)
        .toList()
      ..sort((left, right) => (left.x ?? 0).compareTo(right.x ?? 0));
    if (flattened.isEmpty) {
      return const <_ChartPoint>[];
    }
    final labelPoints = <_ChartPoint>[];
    String? lastLabel;
    for (final point in flattened) {
      if (point.label == lastLabel) {
        continue;
      }
      labelPoints.add(point);
      lastLabel = point.label;
    }
    return labelPoints;
  }

  double _chartDx({
    required double chartWidth,
    required double leftPadding,
    required int index,
    required int count,
    required double? x,
    required bool hasExplicitX,
    required double minX,
    required double maxX,
  }) {
    if (hasExplicitX && x != null) {
      final xRange = math.max(maxX - minX, 0.001);
      return leftPadding + (chartWidth * ((x - minX) / xRange));
    }
    return leftPadding +
        (chartWidth * (count == 1 ? 0.5 : index / (count - 1)));
  }

  double _seriesMaxValue() {
    return series.fold<double>(
      1,
      (current, entry) {
        final localMax = entry.points.fold<double>(
          0,
          (best, point) {
            final value = point.value;
            if (!value.isFinite) {
              return best;
            }
            return value > best ? value : best;
          },
        );
        return localMax > current ? localMax : current;
      },
    );
  }

  double _resolvedMaxValue({
    required bool hasExplicitX,
    required int maxPoints,
  }) {
    if (area && !hasExplicitX) {
      return _stackedMaxValue(maxPoints);
    }
    return _seriesMaxValue();
  }

  double _timeTickStep({
    required double minX,
    required double maxX,
    required double chartWidth,
  }) {
    final range = math.max(maxX - minX, 0.001);
    final targetLabels = math.max(4, math.min(24, (chartWidth / 120).floor()));
    final rawStep = range / targetLabels;
    const baseSteps = <double>[0.1, 0.2, 0.5, 1, 1.5, 2, 2.5, 5];
    var scale = 1.0;
    while (scale < 100000) {
      for (final base in baseSteps) {
        final candidate = base * scale;
        if (candidate >= rawStep) {
          return candidate;
        }
      }
      scale *= 10;
    }
    return rawStep;
  }

  List<double> _timeTicks({
    required double minX,
    required double maxX,
    required double step,
  }) {
    if (step <= 0) {
      return const <double>[];
    }
    final start = (minX / step).floor() * step;
    final ticks = <double>[];
    for (var tick = start; tick <= maxX + 0.001; tick += step) {
      if (tick + 0.001 < minX) {
        continue;
      }
      ticks.add(double.parse(tick.toStringAsFixed(3)));
    }
    if (ticks.isEmpty || (ticks.first - minX).abs() > 0.001) {
      ticks.insert(0, double.parse(minX.toStringAsFixed(3)));
    }
    if ((ticks.last - maxX).abs() > 0.001) {
      ticks.add(double.parse(maxX.toStringAsFixed(3)));
    }
    return ticks;
  }

  String _formatTimeTickLabel(double seconds, double step) {
    if (step < 1) {
      return '${seconds.toStringAsFixed(2)}s';
    }
    if (step < 10 && seconds != seconds.roundToDouble()) {
      return '${seconds.toStringAsFixed(1)}s';
    }
    if (seconds == seconds.roundToDouble()) {
      return '${seconds.toStringAsFixed(0)}s';
    }
    return '${seconds.toStringAsFixed(1)}s';
  }

  double _stackedMaxValue(int maxPoints) {
    var maxValue = 1.0;
    for (var index = 0; index < maxPoints; index += 1) {
      var sum = 0.0;
      for (final entry in series) {
        if (index < entry.points.length) {
          sum += entry.points[index].value;
        }
      }
      if (sum > maxValue) {
        maxValue = sum;
      }
    }
    return maxValue;
  }

  void _paintStackedAreas(
    Canvas canvas, {
    required double chartWidth,
    required double chartHeight,
    required double leftPadding,
    required double topPadding,
    required double bottomPadding,
    required double maxValue,
  }) {
    final cumulative = List<double>.filled(
      series.fold<int>(
        0,
        (current, entry) =>
            entry.points.length > current ? entry.points.length : current,
      ),
      0,
    );
    for (final entry in series) {
      if (entry.points.isEmpty) {
        continue;
      }
      final topPoints = <Offset>[];
      final bottomPoints = <Offset>[];
      for (var index = 0; index < entry.points.length; index += 1) {
        final point = entry.points[index];
        final dx = leftPadding +
            (chartWidth *
                (entry.points.length == 1
                    ? 0.5
                    : index / (entry.points.length - 1)));
        final bottomValue = cumulative[index];
        final topValue = bottomValue + point.value;
        final topY =
            topPadding + chartHeight - ((topValue / maxValue) * chartHeight);
        final bottomY =
            topPadding + chartHeight - ((bottomValue / maxValue) * chartHeight);
        topPoints.add(Offset(dx, topY));
        bottomPoints.add(Offset(dx, bottomY));
        cumulative[index] = topValue;
      }

      final linePath = _seriesPath(topPoints);
      final fillPath = Path.from(linePath);
      for (var index = bottomPoints.length - 1; index >= 0; index -= 1) {
        fillPath.lineTo(bottomPoints[index].dx, bottomPoints[index].dy);
      }
      fillPath.close();

      canvas.drawPath(
        fillPath,
        Paint()
          ..style = PaintingStyle.fill
          ..shader = ui.Gradient.linear(
            Offset(0, topPadding),
            Offset(0, topPadding + chartHeight),
            <Color>[
              entry.color.withValues(alpha: 0.26),
              entry.color.withValues(alpha: 0.10),
            ],
          ),
      );
      canvas.drawPath(
        linePath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = entry.color,
      );
      if (topPoints.length <= _markerPointLimit) {
        for (final point in topPoints) {
          canvas.drawCircle(
            point,
            2.4,
            Paint()..color = entry.color,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.textColor != textColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.area != area ||
        oldDelegate.suffix != suffix ||
        oldDelegate.smooth != smooth;
  }

  String _formatAxisValue(double value) {
    if (value >= 1000000000) {
      return '${(value / 1000000000).toStringAsFixed(1)}G';
    }
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}k';
    }
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    final decimals = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    return value.toStringAsFixed(decimals);
  }
}
