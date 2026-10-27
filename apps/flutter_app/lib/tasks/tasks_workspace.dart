import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/compact_selector.dart';
import '../widgets/empty_state.dart';

class TasksWorkspace extends StatelessWidget {
  const TasksWorkspace({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final view = controller.taskView;
    final tasks = controller.tasksForView(view);
    final selectedIndex =
        tasks.indexWhere((t) => t.id == controller.selectedTaskId);
    final selected =
        tasks.isEmpty ? null : tasks[selectedIndex < 0 ? 0 : selectedIndex];
    final duration = AppMotion.duration(context,
        enabled: controller.settings.enableAnimations, milliseconds: 180);
    return LayoutBuilder(builder: (context, constraints) {
      final split = constraints.maxWidth >= 1000 &&
          MediaQuery.textScalerOf(context).scale(14) < 22;
      return Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  CompactSelector<BrowserTaskView>(
                      selected: view,
                      onChanged: controller.setTaskView,
                      options: [
                        CompactSelectorOption(
                            value: BrowserTaskView.running,
                            icon: Icons.sync,
                            label:
                                'Running · ${controller.tasksForView(BrowserTaskView.running).length}'),
                        CompactSelectorOption(
                            value: BrowserTaskView.failed,
                            icon: Icons.error_outline,
                            label:
                                'Failed · ${controller.tasksForView(BrowserTaskView.failed).length}'),
                        CompactSelectorOption(
                            value: BrowserTaskView.all,
                            icon: Icons.list_alt,
                            label:
                                'All · ${controller.tasksForView(BrowserTaskView.all).length}'),
                      ]),
                  TextButton.icon(
                      onPressed: controller.clearFinishedTasks,
                      icon: const Icon(Icons.clear_all),
                      label: const Text('Clear finished')),
                ]),
            const SizedBox(height: 12),
            Expanded(
                child: tasks.isEmpty
                    ? EmptyState(
                        icon: Icons.task_alt,
                        title: switch (view) {
                          BrowserTaskView.running => 'No running tasks.',
                          BrowserTaskView.failed => 'No failed tasks.',
                          BrowserTaskView.all => 'No task history yet.'
                        },
                        message: 'Upload or download objects from the browser.',
                        action: TextButton(
                            onPressed: () =>
                                controller.selectTab(WorkspaceTab.browser),
                            child: const Text('Open browser')))
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            Expanded(
                                flex: split ? 4 : 1,
                                child: DirectionalSwitcher(
                                    position: view.index,
                                    duration: duration,
                                    layoutBuilder: (current, previous) =>
                                        current ?? const SizedBox.shrink(),
                                    child: ListView.separated(
                                        key: ValueKey('jobs-list-${view.name}'),
                                        itemCount: tasks.length,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(height: 8),
                                        itemBuilder: (context, index) =>
                                            _TaskCard(
                                                key: ValueKey(tasks[index].id),
                                                controller: controller,
                                                task: tasks[index],
                                                split: split,
                                                selected: split
                                                    ? tasks[index].id ==
                                                        selected?.id
                                                    : tasks[index].id ==
                                                        controller
                                                            .selectedTaskId)))),
                            if (split) ...[
                              const SizedBox(width: 10),
                              Expanded(
                                  flex: 7,
                                  child: Card(
                                      clipBehavior: Clip.antiAlias,
                                      child: DirectionalSwitcher(
                                          position: selectedIndex < 0
                                              ? 0
                                              : selectedIndex,
                                          duration: duration,
                                          layoutBuilder: (current, previous) =>
                                              current ??
                                              const SizedBox.shrink(),
                                          child: _TaskDetails(
                                              key: ValueKey(
                                                  'job-detail-${selected!.id}'),
                                              controller: controller,
                                              task: selected,
                                              showActions: true)))),
                            ],
                          ])),
          ]));
    });
  }
}

String _taskLabel(BrowserTaskRecord task) {
  if (task.status != 'completed') return task.label;
  var label = task.label;
  for (final entry in const {
    'Loading': 'Loaded',
    'Listing': 'Listed',
    'Deleting': 'Deleted',
    'Uploading': 'Uploaded',
    'Downloading': 'Downloaded',
    'Delete': 'Deleted',
    'Upload': 'Uploaded',
    'Download': 'Downloaded'
  }.entries) {
    if (label.startsWith('${entry.key} ')) {
      label = label.replaceFirst(entry.key, entry.value);
      break;
    }
  }
  if (label != task.label && label.endsWith('...')) {
    label = '${label.substring(0, label.length - 3)}.';
  }
  return label;
}

String _duration(Duration value) {
  final seconds = value.inSeconds.clamp(0, 1 << 40);
  if (seconds >= 3600) {
    return '${seconds ~/ 3600}h ${(seconds ~/ 60) % 60}m ${seconds % 60}s';
  }
  if (seconds >= 60) return '${seconds ~/ 60}m ${seconds % 60}s';
  return '${seconds}s';
}

String _eta(Duration value) => value.inSeconds < 60
    ? '< 1 min left'
    : value.inMinutes < 60
        ? '~${value.inMinutes} min left'
        : '~${value.inHours}h ${value.inMinutes % 60}m left';

class _TaskCard extends StatelessWidget {
  const _TaskCard(
      {super.key,
      required this.controller,
      required this.task,
      required this.split,
      required this.selected});
  final AppController controller;
  final BrowserTaskRecord task;
  final bool split, selected;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
        clipBehavior: Clip.antiAlias,
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: .35)
            : null,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
              onTap: () =>
                  controller.selectTask(!split && selected ? null : task.id),
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  child: Text(_taskLabel(task),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall)),
                              if (split) ...[
                                const SizedBox(width: 8),
                                TaskStatusPill(status: task.status),
                              ],
                              if (!split)
                                Icon(
                                    selected
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 20),
                            ]),
                        if (!split) ...[
                          const SizedBox(height: 6),
                          TaskStatusPill(status: task.status),
                        ],
                        if (task.isRunningLike || task.isFailedLike) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                              color: TaskStatusPill.color(context, task.status),
                              value: task.isRunningLike &&
                                      task.status != 'paused' &&
                                      task.progress == 0 &&
                                      (task.totalBytes == null ||
                                          task.totalBytes == 0)
                                  ? null
                                  : task.progress.clamp(0.0, 1.0)),
                        ],
                        const SizedBox(height: 7),
                        Text(
                            '${_duration(task.elapsed)} elapsed${task.bytesPerSecond >= 1024 ? ' · ${formatBytes(task.bytesPerSecond.round())}/s' : ''}${task.eta != null ? ' · ${_eta(task.eta!)}' : ''}',
                            style: theme.textTheme.bodySmall),
                        if (task.bytesTransferred != null &&
                            task.totalBytes != null)
                          Text(
                              '${formatBytes(task.bytesTransferred!)} / ${formatBytes(task.totalBytes!)}',
                              style: theme.textTheme.bodySmall),
                        if (task.isFailedLike)
                          Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                  task.outputLines.isEmpty
                                      ? 'This operation failed. Open details before retrying.'
                                      : task.outputLines.last,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: theme.colorScheme.error))),
                      ]))),
          if (!split)
            Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: _TaskActions(controller: controller, task: task)),
          if (!split)
            MotionSize(
                duration: AppMotion.duration(context,
                    enabled: controller.settings.enableAnimations,
                    milliseconds: 180),
                alignment: Alignment.topCenter,
                child: selected
                    ? _TaskDetails(
                        controller: controller,
                        task: task,
                        showActions: false,
                        embedded: true)
                    : const SizedBox.shrink()),
        ]));
  }
}

class _TaskActions extends StatelessWidget {
  const _TaskActions({required this.controller, required this.task});
  final AppController controller;
  final BrowserTaskRecord task;
  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (task.canPause)
          OutlinedButton.icon(
              onPressed: () => controller.pauseTransfer(task.id),
              icon: const Icon(Icons.pause, size: 18),
              label: const Text('Pause')),
        if (task.canResume)
          OutlinedButton.icon(
              onPressed: () => controller.resumeTransfer(task.id),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Resume')),
        if (task.canCancel)
          OutlinedButton.icon(
              onPressed: () => controller.cancelTask(task),
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: Text(
                  task.kind == BrowserTaskKind.benchmark ? 'Stop' : 'Cancel')),
        if (controller.canRetryTask(task))
          OutlinedButton.icon(
              onPressed: controller.isBusy('retry-${task.id}')
                  ? null
                  : () => controller.retryTask(task),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry')),
        if (task.isFailedLike)
          TextButton.icon(
              onPressed: controller.openErrorDetails,
              icon: const Icon(Icons.receipt_long_outlined, size: 18),
              label: const Text('Open Event Log')),
        if (task.kind == BrowserTaskKind.benchmark)
          TextButton.icon(
              onPressed: () => controller.selectTab(WorkspaceTab.benchmark),
              icon: const Icon(Icons.query_stats, size: 18),
              label: const Text('Open benchmark')),
        if (task.kind == BrowserTaskKind.action && task.workspaceTab != null)
          TextButton(
              onPressed: () => controller.selectTab(task.workspaceTab!),
              child: Text('Open ${switch (task.workspaceTab!) {
                WorkspaceTab.browser => 'browser',
                WorkspaceTab.benchmark => 'benchmark',
                WorkspaceTab.tasks => 'tasks',
                WorkspaceTab.settings => 'settings',
                WorkspaceTab.eventLog => 'event log'
              }}')),
      ]);
}

class _TaskDetails extends StatelessWidget {
  const _TaskDetails(
      {super.key,
      required this.controller,
      required this.task,
      required this.showActions,
      this.embedded = false});
  final AppController controller;
  final BrowserTaskRecord task;
  final bool showActions, embedded;
  @override
  Widget build(BuildContext context) {
    final profiles = controller.profiles.where((p) => p.id == task.profileId);
    final profileName = profiles.isEmpty ? task.profileId : profiles.first.name;
    final metrics = <String>[
      if (task.bytesTransferred != null && task.totalBytes != null)
        'Bytes: ${formatBytes(task.bytesTransferred!)}/${formatBytes(task.totalBytes!)}',
      if (task.itemCount != null)
        'Items: ${task.itemsCompleted ?? 0}/${task.itemCount}',
      if (task.partsTotal != null)
        'Parts: ${task.partsCompleted ?? 0}/${task.partsTotal}${task.partSizeBytes == null ? '' : ' · ${formatBytes(task.partSizeBytes!)} per part'}',
    ];
    final children = <Widget>[
      if (!embedded) ...[
        Row(children: [
          const Icon(Icons.info_outline, size: 20),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_taskLabel(task),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium))
        ]),
        const SizedBox(height: 12),
      ],
      if (showActions) ...[
        _TaskActions(controller: controller, task: task),
        const SizedBox(height: 16)
      ],
      if (metrics.isNotEmpty) ...[
        LayoutBuilder(
            builder: (context, constraints) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: metrics
                    .map((metric) => Container(
                        width: constraints.maxWidth < 360
                            ? constraints.maxWidth
                            : (constraints.maxWidth - 8) / 2,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant),
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(metric)))
                    .toList())),
        const SizedBox(height: 16),
      ],
      if (profileName != null) Text('Profile: $profileName'),
      if (task.bucketName != null) Text('Bucket: ${task.bucketName}'),
      Text('Started: ${formatDateTime(task.startedAt)}'),
      if (task.completedAt != null)
        Text('Completed: ${formatDateTime(task.completedAt!)}'),
      if (task.strategyLabel != null) Text('Strategy: ${task.strategyLabel}'),
      if (task.currentItemLabel != null)
        Text('Current item: ${task.currentItemLabel}'),
      if (task.kind == BrowserTaskKind.transfer &&
          task.isRunningLike &&
          !task.canCancel &&
          task.status != 'cancelling')
        const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
                'This engine cannot interrupt the active file. Cancelling a batch stops its remaining files.')),
      if (task.outputLines.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Output', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8)),
            child: SelectableText(task.outputLines.join('\n'),
                key: PageStorageKey('output-${task.id}'))),
      ],
    ];
    return embedded
        ? Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children))
        : ListView(
            key: PageStorageKey('job-scroll-${task.id}'),
            padding: const EdgeInsets.all(16),
            children: children);
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
