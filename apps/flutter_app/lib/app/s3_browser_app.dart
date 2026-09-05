import '../widgets/navigation_item.dart';
import 'app_shortcuts.dart';
import 'dart:async';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../benchmark/benchmark_workspace.dart';
import '../browser/browser_workspace_frame.dart';
import '../controllers/app_controller.dart';
import '../event_log/event_log_workspace.dart';
import '../models/domain_models.dart';
import '../settings/settings_workspace.dart';
import '../tasks/tasks_workspace.dart';
import '../theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/breakpoints.dart';
import '../widgets/app_select_field.dart';
import '../widgets/compact_selector.dart';

class S3BrowserApp extends StatefulWidget {
  const S3BrowserApp({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<S3BrowserApp> createState() => _S3BrowserAppState();
}

class _S3BrowserAppState extends State<S3BrowserApp> {
  Timer? _benchmarkTimer;
  AppLifecycleListener? _lifecycleListener;
  static const List<WorkspaceTab> _allNavTabs = [
    WorkspaceTab.browser,
    WorkspaceTab.tasks,
    WorkspaceTab.benchmark,
    WorkspaceTab.eventLog,
    WorkspaceTab.settings,
  ];

  List<WorkspaceTab> _visibleNavTabs() {
    final hideBenchmark = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!hideBenchmark) {
      return _allNavTabs;
    }
    return _allNavTabs
        .where((tab) => tab != WorkspaceTab.benchmark)
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChange);
    // Shut down long-lived engine sidecar processes before the desktop app
    // exits so they do not outlive the UI process.
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        widget.controller.shutdownEngines();
        return AppExitResponse.exit;
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.initialize();
    });
  }

  @override
  void dispose() {
    _benchmarkTimer?.cancel();
    _lifecycleListener?.dispose();
    widget.controller.removeListener(_handleControllerChange);
    super.dispose();
  }

  void _handleControllerChange() {
    final run = widget.controller.benchmarkRun;
    if (run != null && run.status == 'running') {
      _benchmarkTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        widget.controller.pollBenchmark();
      });
    } else {
      _benchmarkTimer?.cancel();
      _benchmarkTimer = null;
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final desktopCompact = AppTheme.isDesktopPlatform(defaultTargetPlatform);
    final theme = controller.settings.darkMode
        ? AppTheme.dark(
            scalePercent: controller.settings.uiScalePercent,
            compactRows: controller.settings.compactRows,
            desktopCompact: desktopCompact,
          )
        : AppTheme.light(
            scalePercent: controller.settings.uiScalePercent,
            compactRows: controller.settings.compactRows,
            desktopCompact: desktopCompact,
          );

    return MaterialApp(
      title: 'Object Data Browser',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: PreferenceTextScaler(MediaQuery.textScalerOf(context),
                controller.settings.uiScalePercent / 100),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final sizeClass = Breakpoints.sizeClass(constraints.maxWidth);
              final phone = sizeClass == WindowSizeClass.phone;
              final tablet = sizeClass == WindowSizeClass.tablet;
              final compact = phone || tablet;
              final compactRail = sizeClass == WindowSizeClass.smallDesktop;
              final navTabs = _visibleNavTabs();
              final activeTab = navTabs.contains(controller.activeTab)
                  ? controller.activeTab
                  : WorkspaceTab.browser;
              if (activeTab != controller.activeTab) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    controller.selectTab(activeTab);
                  }
                });
              }
              final body = DirectionalSwitcher(
                position: navTabs.indexOf(activeTab),
                axis: compact ? Axis.horizontal : Axis.vertical,
                duration: AppMotion.duration(context,
                    enabled: controller.settings.enableAnimations,
                    milliseconds: 280),
                child: switch (activeTab) {
                  WorkspaceTab.browser => BrowserWorkspaceFrame(
                      key: const ValueKey('browser'),
                      controller: controller,
                      compact: compact,
                    ),
                  WorkspaceTab.benchmark => BenchmarkWorkspace(
                      key: const ValueKey('benchmark'),
                      controller: controller,
                    ),
                  WorkspaceTab.settings => SettingsWorkspace(
                      key: const ValueKey('settings'),
                      controller: controller,
                    ),
                  WorkspaceTab.tasks => TasksWorkspace(
                      key: const ValueKey('tasks'),
                      controller: controller,
                    ),
                  WorkspaceTab.eventLog => EventLogWorkspace(
                      key: const ValueKey('event-log'),
                      controller: controller,
                    ),
                },
              );

              return AppShortcuts(
                  controller: controller,
                  child: Scaffold(
                    bottomNavigationBar: AnimatedSwitcher(
                      duration: AppMotion.duration(context,
                          enabled: controller.settings.enableAnimations,
                          milliseconds: 220),
                      child: phone
                          ? KeyedSubtree(
                              key: const ValueKey('phone-navigation'),
                              child: _buildBottomNav(controller, navTabs),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('no-phone-navigation'),
                            ),
                    ),
                    body: ColoredBox(
                      color: controller.settings.darkMode
                          ? AppTheme.darkRail
                          : Theme.of(context).colorScheme.inverseSurface,
                      child: SafeArea(
                        child: Stack(
                          children: [
                            Row(
                              children: [
                                AnimatedContainer(
                                  key: const ValueKey(
                                      'workspace-navigation-rail'),
                                  duration: AppMotion.duration(context,
                                      enabled:
                                          controller.settings.enableAnimations,
                                      milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  width: compact ? 0 : (compactRail ? 72 : 126),
                                  child: ClipRect(
                                    child: compact
                                        ? const SizedBox.shrink()
                                        : _buildRail(
                                            context,
                                            controller,
                                            navTabs,
                                            collapsed: compactRail,
                                          ),
                                  ),
                                ),
                                Expanded(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .scaffoldBackgroundColor,
                                      borderRadius: !compact
                                          ? const BorderRadius.horizontal(
                                              left: Radius.circular(8),
                                            )
                                          : BorderRadius.zero,
                                    ),
                                    child: Column(
                                      children: [
                                        _AppHeader(
                                          controller: controller,
                                          compact: compact || compactRail,
                                          phone: phone,
                                        ),
                                        MotionSize(
                                          duration: AppMotion.duration(context,
                                              enabled: controller
                                                  .settings.enableAnimations,
                                              milliseconds: 220),
                                          curve: Curves.easeOutCubic,
                                          child: AnimatedSwitcher(
                                            duration: AppMotion.duration(
                                                context,
                                                enabled: controller
                                                    .settings.enableAnimations,
                                                milliseconds: 220),
                                            switchInCurve: Curves.easeOutCubic,
                                            switchOutCurve: Curves.easeInCubic,
                                            transitionBuilder: (child,
                                                    animation) =>
                                                FadeTransition(
                                                    opacity: animation,
                                                    child: child),
                                            child: tablet
                                                ? KeyedSubtree(
                                                    key: const ValueKey(
                                                      'tablet-navigation',
                                                    ),
                                                    child: _buildTopTabs(
                                                      controller,
                                                      navTabs,
                                                    ),
                                                  )
                                                : const SizedBox.shrink(
                                                    key: ValueKey(
                                                      'no-tablet-navigation',
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        Expanded(child: body),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Positioned(
                              top: phone ? null : 76,
                              bottom: phone ? 12 : null,
                              right: 12,
                              left: phone ? 12 : null,
                              child: _BannerOverlay(controller: controller),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ));
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRail(
    BuildContext context,
    AppController controller,
    List<WorkspaceTab> navTabs, {
    required bool collapsed,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding:
          EdgeInsets.fromLTRB(collapsed ? 8 : 10, 18, collapsed ? 8 : 10, 12),
      color: theme.extension<AppRailTheme>()!.background,
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.extension<AppRailTheme>()!.logoBackground,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Icon(
              Icons.inventory_2_rounded,
              color: theme.extension<AppRailTheme>()!.foreground,
              size: 28,
            ),
          ),
          const SizedBox(height: 42),
          ...navTabs.map(
            (tab) => _RailDestination(
              index: navTabs.indexOf(tab),
              count: navTabs.length,
              selected: controller.activeTab == tab,
              icon: _tabIcon(tab, selected: false),
              selectedIcon: _tabIcon(tab, selected: true),
              label: _tabLabel(tab),
              collapsed: collapsed,
              onTap: () => controller.selectTab(tab),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildTopTabs(
    AppController controller,
    List<WorkspaceTab> navTabs,
  ) {
    return Padding(
      key: const ValueKey('workspace-top-tabs'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: CompactSelector<WorkspaceTab>(
        selected: controller.activeTab,
        onChanged: controller.selectTab,
        expand: true,
        options: navTabs
            .map(
              (tab) => CompactSelectorOption(
                value: tab,
                icon: _tabIcon(tab, selected: false),
                label: _tabLabel(tab),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildBottomNav(
    AppController controller,
    List<WorkspaceTab> navTabs,
  ) {
    return NavigationBar(
      selectedIndex: navTabs.contains(controller.activeTab)
          ? navTabs.indexOf(controller.activeTab)
          : 0,
      onDestinationSelected: (index) => controller.selectTab(navTabs[index]),
      destinations: navTabs
          .map(
            (tab) => NavigationDestination(
              icon: Icon(_tabIcon(tab, selected: false)),
              selectedIcon: Icon(_tabIcon(tab, selected: true)),
              label: _tabLabel(tab),
            ),
          )
          .toList(),
    );
  }

  static IconData _tabIcon(WorkspaceTab tab, {required bool selected}) {
    return switch (tab) {
      WorkspaceTab.tasks =>
        selected ? Icons.dashboard_customize : Icons.dashboard_outlined,
      WorkspaceTab.browser =>
        selected ? Icons.inventory_2 : Icons.inventory_2_outlined,
      WorkspaceTab.benchmark => selected ? Icons.tune : Icons.tune_outlined,
      WorkspaceTab.eventLog =>
        selected ? Icons.receipt_long : Icons.receipt_long_outlined,
      WorkspaceTab.settings =>
        selected ? Icons.settings : Icons.settings_outlined,
    };
  }

  static String _tabLabel(WorkspaceTab tab) {
    return switch (tab) {
      WorkspaceTab.tasks => 'Jobs',
      WorkspaceTab.browser => 'Buckets',
      WorkspaceTab.benchmark => 'Benchmark',
      WorkspaceTab.eventLog => 'Event Log',
      WorkspaceTab.settings => 'Settings',
    };
  }
}

class _RailDestination extends StatelessWidget {
  const _RailDestination({
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    required this.collapsed,
    required this.index,
    required this.count,
  });

  final int index, count;
  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final rail = Theme.of(context).extension<AppRailTheme>()!;
    final textColor = rail.foreground;
    return NavigationItem(
        label: '$label, tab ${index + 1} of $count',
        selected: selected,
        onActivate: onTap,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Tooltip(
            message: label,
            child: Material(
                color: selected ? rail.selectedBackground : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: onTap,
                  child: SizedBox(
                    height: 48,
                    child: Row(
                      mainAxisAlignment: collapsed
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        SizedBox(width: collapsed ? 0 : 12),
                        Icon(
                          selected ? selectedIcon : icon,
                          color: textColor,
                          size: 20,
                        ),
                        if (!collapsed) ...[
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(
                                  color: textColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                          )),
                        ],
                      ],
                    ),
                  ),
                )),
          ),
        ));
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader({
    required this.controller,
    required this.compact,
    required this.phone,
  });

  final AppController controller;
  final bool compact;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktopCompact = AppTheme.isDesktopPlatform(theme.platform);
    final desktopWide = !phone && !compact;
    final margin = EdgeInsets.fromLTRB(
      phone ? 12 : (desktopCompact ? 10 : 12),
      phone ? 8 : (desktopCompact ? 10 : 12),
      phone ? 12 : (desktopCompact ? 10 : 12),
      phone ? 8 : (desktopCompact ? 8 : 10),
    );
    final padding = EdgeInsets.fromLTRB(
      desktopCompact && !phone ? 12 : (phone ? 18 : 12),
      phone ? 14 : (desktopCompact ? 8 : (compact ? 10 : 12)),
      desktopCompact && !phone ? 12 : (phone ? 18 : 12),
      desktopCompact && !phone ? 8 : (phone ? 14 : 10),
    );
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(
          phone ? 12 : (desktopCompact ? 8 : 10),
        ),
        color: theme.colorScheme.surface,
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: AppMotion.duration(context,
            enabled: controller.settings.enableAnimations, milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Transform.translate(
            offset: Offset(0, 8 * (1 - value)),
            child: Opacity(opacity: value, child: child),
          );
        },
        child: desktopWide
            ? Row(
                children: [
                  SizedBox(
                    width: desktopCompact ? 260 : 300,
                    child: _DesktopHeaderMark(
                        compact: desktopCompact, controller: controller),
                  ),
                  SizedBox(width: desktopCompact ? 12 : 16),
                  if (controller.activeTab == WorkspaceTab.browser)
                    Expanded(child: _HeaderSearchField(controller: controller))
                  else
                    const Spacer(),
                  SizedBox(width: desktopCompact ? 12 : 16),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: desktopCompact ? 430 : 500,
                    ),
                    child: _HeaderControlStrip(
                      controller: controller,
                      embedded: true,
                      desktopPinned: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _HeaderThemeToggle(controller: controller),
                ],
              )
            : _HeaderControlStrip(
                controller: controller,
                embedded: true,
                desktopPinned: !phone,
              ),
      ),
    );
  }
}

class _DesktopHeaderMark extends StatelessWidget {
  const _DesktopHeaderMark({required this.compact, required this.controller});
  final AppController controller;

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 40 : 48,
            height: compact ? 40 : 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.85),
              ),
            ),
            child: Icon(
              Icons.storage_rounded,
              size: compact ? 20 : 24,
              color: theme.colorScheme.primary,
            ),
          ),
          SizedBox(width: compact ? 10 : 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Object Data Browser',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 3),
                if (controller.activeTab == WorkspaceTab.browser)
                  SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        Text(
                            controller.selectedProfile?.name ?? 'No connection',
                            style: theme.textTheme.bodySmall),
                        if (controller.selectedBucket != null)
                          TextButton(
                              onPressed: () =>
                                  controller.refreshObjects(prefix: ''),
                              child: Text(
                                  ' › ${controller.selectedBucket!.name}')),
                        ..._prefixButtons(),
                      ]))
                else
                  Text(
                      controller.activeTab == WorkspaceTab.tasks
                          ? 'Jobs · ${controller.tasksForView(BrowserTaskView.running).length} running, ${controller.tasksForView(BrowserTaskView.failed).length} failed'
                          : controller.activeTab == WorkspaceTab.settings
                              ? 'Settings · ${controller.settingsSectionName}'
                              : controller.activeTab == WorkspaceTab.eventLog
                                  ? 'Event Log · ${controller.eventLog.length} events'
                                  : 'Benchmark',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _prefixButtons() {
    final parts =
        controller.currentPrefix.split('/').where((p) => p.isNotEmpty).toList();
    return [
      for (var i = 0; i < parts.length; i++)
        if (parts.length <= 4 || i == 0 || i >= parts.length - 2)
          TextButton(
              onPressed: () => controller.refreshObjects(
                  prefix: '${parts.take(i + 1).join('/')}/'),
              child: Text(' › ${parts[i]}'))
        else if (i == 1)
          const Text(' › …')
    ];
  }
}

class _HeaderSearchField extends StatelessWidget {
  const _HeaderSearchField({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
      onPressed: controller.requestObjectSearchFocus,
      icon: const Icon(Icons.search),
      label: Text(
          'Search  ${Theme.of(context).platform == TargetPlatform.macOS ? '⌘K' : 'Ctrl K'}'));
}

class _HeaderThemeToggle extends StatelessWidget {
  const _HeaderThemeToggle({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final darkMode = controller.settings.darkMode;
    return IconButton.filledTonal(
      tooltip: darkMode ? 'Switch to light mode' : 'Switch to dark mode',
      onPressed: () {
        unawaited(
          controller.updateSettings(
            controller.settings.copyWith(darkMode: !darkMode),
          ),
        );
      },
      icon: Icon(darkMode ? Icons.light_mode : Icons.dark_mode),
    );
  }
}

class _HeaderControlStrip extends StatelessWidget {
  const _HeaderControlStrip({
    required this.controller,
    this.embedded = false,
    this.desktopPinned = false,
  });

  final AppController controller;
  final bool embedded;
  final bool desktopPinned;

  @override
  Widget build(BuildContext context) {
    final profiles = controller.profiles;
    final engines = controller.engines;
    final phone = Breakpoints.isPhone(MediaQuery.sizeOf(context).width);
    final desktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);
    return Container(
      margin: embedded
          ? EdgeInsets.zero
          : phone
              ? const EdgeInsets.only(top: 2)
              : EdgeInsets.fromLTRB(
                  desktopCompact ? 14 : 18,
                  0,
                  desktopCompact ? 14 : 18,
                  desktopCompact ? 10 : 14,
                ),
      padding: embedded
          ? EdgeInsets.zero
          : phone
              ? const EdgeInsets.only(top: 4)
              : EdgeInsets.fromLTRB(
                  desktopCompact ? 14 : 18,
                  desktopCompact ? 8 : 10,
                  desktopCompact ? 14 : 18,
                  0,
                ),
      child: phone
          ? SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                  icon: const Icon(Icons.cloud_outlined),
                  label: Text(
                      '${controller.selectedProfile?.name ?? 'Choose connection'} · ${controller.activeEngineId}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (context) => SafeArea(
                          child: AnimatedBuilder(
                              animation: controller,
                              builder: (context, _) => Padding(
                                  padding: EdgeInsets.fromLTRB(
                                      20,
                                      20,
                                      20,
                                      20 +
                                          MediaQuery.viewInsetsOf(context)
                                              .bottom),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _labeledPhoneField(context,
                                            label: 'Endpoint profile',
                                            child: _profileDropdown(
                                                context, controller.profiles,
                                                phone: true)),
                                        const SizedBox(height: 16),
                                        _labeledPhoneField(context,
                                            label: 'Backend engine',
                                            child: _engineDropdown(
                                                context, controller.engines,
                                                phone: true)),
                                        const SizedBox(height: 12),
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('Done')),
                                      ])))))))
          : Align(
              alignment: desktopPinned ? Alignment.topRight : Alignment.topLeft,
              child: desktopPinned
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: compactWidth(context, embedded, true),
                          child:
                              _profileDropdown(context, profiles, phone: false),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: compactWidth(context, embedded, false),
                          child:
                              _engineDropdown(context, engines, phone: false),
                        ),
                      ],
                    )
                  : Wrap(
                      spacing: desktopCompact ? 10 : 12,
                      runSpacing: desktopCompact ? 10 : 12,
                      children: [
                        SizedBox(
                          width: compactWidth(context, embedded, true),
                          child: _profileDropdown(
                            context,
                            profiles,
                            phone: false,
                          ),
                        ),
                        SizedBox(
                          width: compactWidth(context, embedded, false),
                          child: _engineDropdown(
                            context,
                            engines,
                            phone: false,
                          ),
                        ),
                      ],
                    ),
            ),
    );
  }

  double compactWidth(BuildContext context, bool embedded, bool profile) {
    final desktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);
    if (desktopPinned) {
      return embedded
          ? (profile
              ? (desktopCompact ? 180 : 210)
              : (desktopCompact ? 160 : 190))
          : (profile
              ? (desktopCompact ? 180 : 210)
              : (desktopCompact ? 160 : 190));
    }
    return profile
        ? (embedded
            ? (desktopCompact ? 292 : 320)
            : (desktopCompact ? 252 : 280))
        : (embedded
            ? (desktopCompact ? 212 : 240)
            : (desktopCompact ? 196 : 220));
  }

  Widget _labeledPhoneField(
    BuildContext context, {
    required String label,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0,
            ),
          ),
        ),
        child,
      ],
    );
  }

  Widget _profileDropdown(
    BuildContext context,
    List<EndpointProfile> profiles, {
    required bool phone,
  }) {
    final onSurface = phone ? Theme.of(context).colorScheme.onSurface : null;
    final selectedId = controller.selectedProfile?.id;
    final validProfileValue =
        profiles.any((p) => p.id == selectedId) ? selectedId : null;
    return AppSelectField<String>(
      value: validProfileValue,
      isExpanded: true,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: onSurface,
          ),
      decoration: InputDecoration(
        labelText: phone ? null : 'Endpoint profile',
        hintText: profiles.isEmpty ? 'Create a profile in Settings' : null,
        isDense: phone,
        constraints: phone ? const BoxConstraints(minHeight: 48) : null,
        contentPadding:
            phone ? const EdgeInsets.fromLTRB(12, 12, 12, 10) : null,
      ),
      items: profiles
          .map(
            (profile) => AppSelectItem(
              value: profile.id,
              label: profile.name,
            ),
          )
          .toList(),
      onChanged: profiles.isEmpty
          ? null
          : (value) {
              if (value != null) {
                controller.setSelectedProfileById(value);
              }
            },
    );
  }

  Widget _engineDropdown(
    BuildContext context,
    List<EngineDescriptor> engines, {
    required bool phone,
  }) {
    final activeId = controller.activeEngineId;
    final validEngineValue =
        engines.any((e) => e.id == activeId) ? activeId : null;
    return AppSelectField<String>(
      value: validEngineValue,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: phone ? null : 'Backend engine',
        isDense: phone,
        constraints: phone ? const BoxConstraints(minHeight: 48) : null,
        contentPadding:
            phone ? const EdgeInsets.fromLTRB(12, 12, 12, 10) : null,
      ),
      items: engines
          .map(
            (engine) => AppSelectItem(
              value: engine.id,
              label: engine.label,
            ),
          )
          .toList(),
      onChanged: engines.isEmpty
          ? null
          : (value) {
              if (value != null) {
                controller.setEngine(value);
              }
            },
    );
  }
}

class _BannerOverlay extends StatefulWidget {
  const _BannerOverlay({required this.controller});

  final AppController controller;

  @override
  State<_BannerOverlay> createState() => _BannerOverlayState();
}

class _BannerOverlayState extends State<_BannerOverlay> {
  Timer? _timer;
  Object? _lastState;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final c = widget.controller;
    final state = (
      c.bannerMessage,
      c.bannerSeverity,
      c.hasBusyActions,
      c.bannerTask?.status
    );
    if (state == _lastState) return;
    _lastState = state;
    _timer?.cancel();
    if (c.bannerMessage == null ||
        c.hasBusyActions ||
        (c.bannerTask?.isRunningLike ?? false)) {
      return;
    }
    final duration = switch (c.bannerSeverity) {
      BannerSeverity.error => null,
      BannerSeverity.warning => const Duration(seconds: 8),
      BannerSeverity.success => const Duration(seconds: 2),
      BannerSeverity.info => const Duration(milliseconds: 3500),
    };
    if (duration != null) {
      _timer = Timer(duration, () {
        if (mounted) c.clearBanner();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final colors = Theme.of(context).colorScheme;
    final background = switch (c.bannerSeverity) {
      BannerSeverity.error => colors.errorContainer,
      BannerSeverity.warning => colors.tertiaryContainer,
      BannerSeverity.success => colors.primaryContainer,
      BannerSeverity.info => colors.inverseSurface,
    };
    final foreground = switch (c.bannerSeverity) {
      BannerSeverity.error => colors.onErrorContainer,
      BannerSeverity.warning => colors.onTertiaryContainer,
      BannerSeverity.success => colors.onPrimaryContainer,
      BannerSeverity.info => colors.onInverseSurface,
    };
    return AnimatedSwitcher(
      duration: AppMotion.duration(context,
          enabled: c.settings.enableAnimations, milliseconds: 180),
      child: c.bannerMessage == null
          ? const SizedBox.shrink(key: ValueKey('banner-empty'))
          : Align(
              key: ValueKey('banner-${c.bannerTaskId ?? 'message'}'),
              alignment: Alignment.topRight,
              child: Semantics(
                  liveRegion: true,
                  child: Material(
                    color: background,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                        constraints: const BoxConstraints(maxWidth: 480),
                        padding: const EdgeInsets.all(8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                              switch (c.bannerSeverity) {
                                BannerSeverity.error => Icons.error_outline,
                                BannerSeverity.warning => Icons.warning_amber,
                                BannerSeverity.success =>
                                  Icons.check_circle_outline,
                                BannerSeverity.info => Icons.info_outline
                              },
                              color: foreground),
                          if (c.bannerTask?.kind == BrowserTaskKind.transfer)
                            Text(
                                '${(c.bannerTask!.progress.clamp(0, 1) * 100).round()}%',
                                style: TextStyle(color: foreground)),
                          const SizedBox(width: 8),
                          Flexible(
                              child: InkWell(
                                  onTap: c.bannerTaskId != null
                                      ? c.openBannerTask
                                      : null,
                                  child: Text(c.bannerMessage!,
                                      style: TextStyle(color: foreground)))),
                          if (c.bannerSeverity == BannerSeverity.error)
                            TextButton(
                                onPressed: c.openErrorDetails,
                                style: TextButton.styleFrom(
                                    foregroundColor: foreground),
                                child: const Text('Details'))
                          else if (c.bannerTaskId != null)
                            TextButton(
                                onPressed: c.openBannerTask,
                                style: TextButton.styleFrom(
                                    foregroundColor: foreground),
                                child: const Text('Details')),
                          IconButton(
                              tooltip: 'Dismiss message',
                              onPressed: c.clearBanner,
                              icon: Icon(Icons.close, color: foreground)),
                        ])),
                  )),
            ),
    );
  }
}
