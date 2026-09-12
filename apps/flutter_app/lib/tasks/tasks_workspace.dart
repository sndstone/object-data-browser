import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../utils/format.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../widgets/compact_selector.dart';

class TasksWorkspace extends StatelessWidget {
  const TasksWorkspace({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = controller.taskView;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: theme.colorScheme.surface,
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Jobs', style: theme.textTheme.headlineSmall),
                      OutlinedButton(
                          onPressed: controller.clearFinishedTasks,
                          child: const Text('Clear finished'))
                    ]),
                const SizedBox(height: 8),
                Text(
                  'Track running work, review failures, and open completed jobs.',
                  style: theme.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          CompactSelector<BrowserTaskView>(
            selected: view,
            onChanged: controller.setTaskView,
            options: [
              CompactSelectorOption(
                value: BrowserTaskView.running,
                icon: Icons.play_circle_outline,
                label:
                    'Running · ${controller.tasksForView(BrowserTaskView.running).length}',
              ),
              CompactSelectorOption(
                value: BrowserTaskView.failed,
                icon: Icons.error_outline,
                label:
                    'Failed · ${controller.tasksForView(BrowserTaskView.failed).length}',
              ),
              CompactSelectorOption(
                value: BrowserTaskView.all,
                icon: Icons.view_list_outlined,
                label:
                    'All · ${controller.tasksForView(BrowserTaskView.all).length}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _TaskList(
              controller: controller,
              view: view,
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.controller,
    required this.view,
  });

  final AppController controller;
  final BrowserTaskView view;

  @override
  Widget build(BuildContext context) {
    final tasks = controller.tasksForView(view);
    if (tasks.isEmpty) {
      return EmptyState(
          icon: Icons.task_alt,
          title: switch (view) {
            BrowserTaskView.running => 'No running tasks.',
            BrowserTaskView.failed => 'No failed tasks.',
            BrowserTaskView.all => 'No task history yet.'
          },
          message: 'Upload or download objects from the browser.',
          action: TextButton(
              onPressed: () => controller.selectTab(WorkspaceTab.browser),
              child: const Text('Open browser')));
    }

    return ListView.separated(
      itemCount: tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _TaskCard(
        key: ValueKey(tasks[index].id),
        controller: controller,
        task: tasks[index],
      ),
    );
  }
}

class _TaskCard extends StatefulWidget {
  const _TaskCard({
    super.key,
    required this.controller,
    required this.task,
  });

  final AppController controller;
  final BrowserTaskRecord task;

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  final ExpansibleController _expansion = ExpansibleController();
  AppController get controller => widget.controller;
  BrowserTaskRecord get task => widget.task;
  @override
  void didUpdateWidget(covariant _TaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (task.id == controller.selectedTaskId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_expansion.isExpanded) _expansion.expand();
      });
    }
  }

  @override
  void dispose() {
    _expansion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (task.profileId != null) 'Profile: ${task.profileId}',
      if (task.bucketName != null) 'Bucket: ${task.bucketName}',
      'Started: ${formatDateTime(task.startedAt)}',
      if (task.completedAt != null)
        'Completed: ${formatDateTime(task.completedAt!)}',
      if (task.strategyLabel != null) 'Strategy: ${task.strategyLabel}',
      if (task.currentItemLabel != null)
        'Current item: ${task.currentItemLabel}',
    ];
    final metricLines = <String>[
      if (task.bytesTransferred != null && task.totalBytes != null)
        'Bytes: ${formatBytes(task.bytesTransferred!)}/${formatBytes(task.totalBytes!)}',
      if (task.itemCount != null)
        'Items: ${(task.itemsCompleted ?? 0)}/${task.itemCount}',
      if (task.partsTotal != null)
        'Parts: ${(task.partsCompleted ?? 0)}/${task.partsTotal}'
            '${task.partSizeBytes == null ? '' : ' - ${formatBytes(task.partSizeBytes!)} per part'}',
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        key: PageStorageKey(task.id),
        controller: _expansion,
        initiallyExpanded: task.id == controller.selectedTaskId,
        onExpansionChanged: (expanded) {
          if (expanded) {
            controller.selectTask(task.id);
          }
        },
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(
          task.label,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TaskStatusPill(status: task.status),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              color: TaskStatusPill.color(context, task.status),
              value: task.isRunningLike &&
                      task.status != 'paused' &&
                      task.progress == 0 &&
                      (task.totalBytes == null || task.totalBytes == 0)
                  ? null
                  : task.progress.clamp(0.0, 1.0),
            ),
            const SizedBox(height: 8),
            Text(
                '${task.elapsed.inMinutes}m ${task.elapsed.inSeconds % 60}s elapsed${task.bytesPerSecond >= 1024 ? ' · ${formatBytes(task.bytesPerSecond.round())}/s' : ''}${task.eta != null ? ' · ~${task.eta!.inMinutes + 1} min left' : ''}',
                style: Theme.of(context).textTheme.bodySmall),
            if (controller.canRetryTask(task))
              TextButton(
                  onPressed: controller.isBusy('retry-${task.id}')
                      ? null
                      : () => controller.retryTask(task),
                  child: const Text('Retry')),
            if (task.isFailedLike)
              TextButton(
                  onPressed: controller.openErrorDetails,
                  child: const Text('Open Event Log')),
            if (task.isFailedLike)
              Text(
                  task.outputLines.isEmpty
                      ? 'This operation failed. Expand for details before retrying.'
                      : task.outputLines.last,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (metricLines.isNotEmpty && !task.isFailedLike)
              Text(
                metricLines.first,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        children: [
          if (metricLines.length > 1)
            Align(
                alignment: Alignment.centerLeft,
                child: Text(metricLines.skip(1).join('\n'))),
          if (details.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(details.join('\n')),
            ),
          if (details.isNotEmpty) const SizedBox(height: 12),
          if (task.outputLines.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(task.outputLines.join('\n'),
                  key: PageStorageKey('output-${task.id}')),
            ),
          if (task.outputLines.isNotEmpty) const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (task.kind == BrowserTaskKind.action && task.canCancel)
                OutlinedButton.icon(
                  onPressed: () => controller.cancelTask(task),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Cancel'),
                ),
              if (task.kind == BrowserTaskKind.transfer && task.isRunningLike && !task.canCancel && task.status != 'cancelling')
                const Text('This engine cannot interrupt the active file. Cancelling a batch stops its remaining files.'),
              if (task.kind == BrowserTaskKind.transfer)
                OutlinedButton(
                  onPressed: task.canPause
                      ? () => controller.pauseTransfer(task.id)
                      : null,
                  child: const Text('Pause'),
                ),
              if (task.kind == BrowserTaskKind.transfer)
                OutlinedButton(
                  onPressed: task.canResume
                      ? () => controller.resumeTransfer(task.id)
                      : null,
                  child: const Text('Resume'),
                ),
              if (task.kind == BrowserTaskKind.transfer)
                OutlinedButton(
                  onPressed:
                      task.canCancel ? () => controller.cancelTask(task) : null,
                  child: const Text('Cancel'),
                ),
              if (task.kind == BrowserTaskKind.benchmark)
                OutlinedButton(
                  onPressed: () => controller.selectTab(WorkspaceTab.benchmark),
                  child: const Text('Open benchmark'),
                ),
              if (task.kind == BrowserTaskKind.benchmark && task.canCancel)
                OutlinedButton.icon(
                  onPressed: () => controller.cancelTask(task),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop'),
                ),
              if (task.kind == BrowserTaskKind.action &&
                  task.workspaceTab != null)
                OutlinedButton(
                  onPressed: () => controller.selectTab(task.workspaceTab!),
                  child: Text(
                    'Open ${switch (task.workspaceTab!) {
                      WorkspaceTab.browser => 'browser',
                      WorkspaceTab.benchmark => 'benchmark',
                      WorkspaceTab.tasks => 'tasks',
                      WorkspaceTab.settings => 'settings',
                      WorkspaceTab.eventLog => 'event log',
                    }}',
                  ),
                ),
              if (task.kind == BrowserTaskKind.tool)
                OutlinedButton(
                  onPressed:
                      task.canCancel ? () => controller.cancelTask(task) : null,
                  child: const Text('Cancel'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class TaskStatusPill extends StatelessWidget {
  const TaskStatusPill({super.key, required this.status});
  final String status;
  static Color color(BuildContext context, String status) {
    final c = Theme.of(context).colorScheme;
    return switch (status) {
      'failed' || 'cancelled' => c.error,
      'paused' => c.tertiary,
      'running' ||
      'queued' ||
      'active' =>
        Theme.of(context).extension<AppStatusTheme>()?.running ?? c.secondary,
      _ => c.onSurfaceVariant
    };
  }

  @override
  Widget build(BuildContext context) => Chip(
      avatar: Icon(
          switch (status) {
            'failed' || 'cancelled' => Icons.error_outline,
            'paused' => Icons.pause_circle_outline,
            'completed' => Icons.check_circle_outline,
            _ => Icons.play_circle_outline
          },
          size: 16,
          color: color(context, status)),
      label: Text(status.isEmpty
          ? 'Unknown'
          : '${status[0].toUpperCase()}${status.substring(1)}'),
      labelStyle: TextStyle(color: color(context, status)),
      backgroundColor: color(context, status).withValues(alpha: .12));
}
