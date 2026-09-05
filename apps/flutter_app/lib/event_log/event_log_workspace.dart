import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../logs/structured_log_list.dart';
import '../models/domain_models.dart';
import '../widgets/app_select_field.dart';
import '../widgets/compact_selector.dart';
import '../widgets/danger_button.dart';
import '../widgets/empty_state.dart';

class EventLogWorkspace extends StatefulWidget {
  const EventLogWorkspace({super.key, required this.controller});
  final AppController controller;
  @override
  State<EventLogWorkspace> createState() => _EventLogWorkspaceState();
}

class _EventLogWorkspaceState extends State<EventLogWorkspace> {
  String _level = 'All', _category = 'All', _query = '';
  Object? _signature;
  List<EventLogEntry> _filtered = [];
  AppController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _pending();
  }

  @override
  void didUpdateWidget(covariant EventLogWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pending();
  }

  void _pending() {
    if (controller.pendingEventLogFilter != null) {
      _level = controller.pendingEventLogFilter!;
      controller.pendingEventLogFilter = null;
    }
  }

  Future<void> _clear() async {
    if (controller.eventLog.length > 100) {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text('Clear ${controller.eventLog.length} events?'),
                  content: const Text(
                      'Export the log first if you want to keep it.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    DangerButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Clear events'))
                  ]));
      if (accepted != true) return;
    }
    controller.clearEventLog();
  }

  @override
  Widget build(BuildContext context) {
    final entries = controller.eventLog;
    final categories = [
      'All',
      ...entries.map((e) => e.category).toSet().toList()..sort()
    ];
    if (!categories.contains(_category)) _category = 'All';
    final signature = (entries, _level, _category, _query);
    if (_signature != signature) {
      _signature = signature;
      _filtered = entries
          .where((e) =>
              (_level == 'All' ||
                  e.level.toUpperCase() == _level ||
                  e.source?.toUpperCase() == _level) &&
              (_category == 'All' || e.category == _category) &&
              '${e.message} ${e.category} ${e.bucketName ?? ''} ${e.objectKey ?? ''}'
                  .toLowerCase()
                  .contains(_query.toLowerCase()))
          .toList();
    }
    return Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text('Event Log',
                                style: Theme.of(context).textTheme.titleLarge),
                            const Tooltip(
                                message:
                                    'Profile, listing, transfer and benchmark activity. Enable API and debug logging in Settings for engine traces.',
                                child: Icon(Icons.info_outline)),
                            FilledButton.icon(
                                onPressed: controller.isBusy('export-event-log')
                                    ? null
                                    : controller.exportEventLog,
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('Export')),
                            OutlinedButton(
                                onPressed: _clear, child: const Text('Clear')),
                          ]),
                      const SizedBox(height: 12),
                      CompactSelector<String>(
                          selected: _level,
                          onChanged: (v) => setState(() => _level = v),
                          options: [
                            for (final level in [
                              'All',
                              'ERROR',
                              'WARN',
                              'INFO',
                              'API',
                              'DEBUG'
                            ])
                              CompactSelectorOption(value: level, label: level)
                          ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        SizedBox(
                            width: 140,
                            child: AppSelectField<String>(
                                value: _category,
                                decoration: const InputDecoration(
                                    labelText: 'Category'),
                                items: [
                                  for (final c in categories)
                                    AppSelectItem(value: c, label: c)
                                ],
                                onChanged: (v) {
                                  if (v != null) setState(() => _category = v);
                                })),
                        const SizedBox(width: 8),
                        Expanded(
                            child: TextField(
                                decoration: const InputDecoration(
                                    labelText: 'Search events',
                                    prefixIcon: Icon(Icons.search)),
                                onChanged: (v) => setState(() => _query = v))),
                      ]),
                      const SizedBox(height: 8),
                      Text(
                          'Showing ${_filtered.length} of ${entries.length} · newest first'),
                      const SizedBox(height: 8),
                      Expanded(
                          child: entries.isEmpty
                              ? EmptyState(
                                  icon: Icons.receipt_long_outlined,
                                  title: 'No events recorded yet.',
                                  message:
                                      'Open a bucket to start browsing and record activity.',
                                  action: TextButton(
                                      onPressed: () => controller
                                          .selectTab(WorkspaceTab.browser),
                                      child: const Text('Open browser')))
                              : StructuredLogList(
                                  entries: _filtered,
                                  textScalePercent:
                                      controller.settings.logTextScalePercent,
                                  emptyMessage:
                                      'No events match these filters.')),
                    ]))));
  }
}
