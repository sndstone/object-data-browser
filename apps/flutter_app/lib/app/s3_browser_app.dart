import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../benchmark/benchmark_workspace.dart';
import '../browser/browser_workspace.dart';
import '../controllers/app_controller.dart';
import '../event_log/event_log_workspace.dart';
import '../models/domain_models.dart';
import '../settings/settings_workspace.dart';
import '../tasks/tasks_workspace.dart';
import '../theme/app_theme.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.initialize();
    });
  }

  @override
  void dispose() {
    _benchmarkTimer?.cancel();
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
            desktopCompact: desktopCompact,
          )
        : AppTheme.light(
            scalePercent: controller.settings.uiScalePercent,
            desktopCompact: desktopCompact,
          );

    return MaterialApp(
      title: 'Object Data Browser',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler:
                TextScaler.linear(controller.settings.uiScalePercent / 100),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final phone = constraints.maxWidth < 700;
              final compact = constraints.maxWidth < 1200;
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
              final body = AnimatedSwitcher(
                duration: controller.settings.enableAnimations
                    ? const Duration(milliseconds: 280)
                    : Duration.zero,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: switch (activeTab) {
                  WorkspaceTab.browser => BrowserWorkspace(
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

              return Scaffold(
                bottomNavigationBar:
                    phone ? _buildBottomNav(controller, navTabs) : null,
                body: ColoredBox(
                  color: controller.settings.darkMode
                      ? AppTheme.darkRail
                      : Theme.of(context).colorScheme.inverseSurface,
                  child: SafeArea(
                    child: Stack(
                      children: [
                        Row(
                          children: [
                            if (!compact)
                              _buildRail(context, controller, navTabs),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color:
                                      Theme.of(context).scaffoldBackgroundColor,
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
                                      compact: compact,
                                      phone: phone,
                                    ),
                                    if (compact && !phone)
                                      _buildTopTabs(controller, navTabs),
                                    Expanded(child: body),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          top: phone ? 8 : 76,
                          right: 12,
                          left: phone ? 12 : null,
                          child: _BannerOverlay(controller: controller),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRail(
    BuildContext context,
    AppController controller,
    List<WorkspaceTab> navTabs,
  ) {
    final theme = Theme.of(context);
    return Container(
      width: 126,
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 12),
      color: controller.settings.darkMode
          ? AppTheme.darkRail
          : theme.colorScheme.inverseSurface,
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.lightAccent,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.inventory_2_rounded,
              color: Color(0xFF9FE870),
              size: 28,
            ),
          ),
          const SizedBox(height: 42),
          ...navTabs.map(
            (tab) => _RailDestination(
              selected: controller.activeTab == tab,
              icon: _tabIcon(tab, selected: false),
              selectedIcon: _tabIcon(tab, selected: true),
              label: _tabLabel(tab),
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
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: CompactSelector<WorkspaceTab>(
        selected: controller.activeTab,
        onChanged: controller.selectTab,
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
  });

  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textColor = selected ? Colors.white : const Color(0xFFD4DED7);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? const Color(0xFF075D31) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  selected ? selectedIcon : icon,
                  color: textColor,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: textColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
      phone ? 12 : (desktopCompact ? 10 : 14),
      phone ? 8 : (desktopCompact ? 10 : 14),
      phone ? 12 : (desktopCompact ? 10 : 14),
      phone ? 8 : (desktopCompact ? 8 : 10),
    );
    final padding = EdgeInsets.fromLTRB(
      desktopCompact && !phone ? 12 : (phone ? 18 : 14),
      phone ? 14 : (desktopCompact ? 8 : (compact ? 10 : 12)),
      desktopCompact && !phone ? 12 : (phone ? 18 : 14),
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
        duration: controller.settings.enableAnimations
            ? const Duration(milliseconds: 220)
            : Duration.zero,
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
                    child: _DesktopHeaderMark(compact: desktopCompact),
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
  const _DesktopHeaderMark({required this.compact});

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
                Text(
                  'Buckets  >  Objects  >  Inspect',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderSearchField extends StatelessWidget {
  const _HeaderSearchField({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasOpenBucket = controller.selectedBucket != null;
    final initialValue = controller.objectFilterMode == BrowserFilterMode.text
        ? controller.objectFilterValue
        : '';
    return SizedBox(
      height: 46,
      child: TextFormField(
        key: ValueKey(
          'header-object-search-${controller.selectedBucket?.name ?? 'none'}',
        ),
        initialValue: initialValue,
        enabled: hasOpenBucket,
        decoration: InputDecoration(
          hintText: hasOpenBucket
              ? 'Search current bucket...'
              : 'Open a bucket to search objects...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              width: 32,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Ctrl K',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontSize: 11,
                ),
              ),
            ),
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 42,
            minHeight: 32,
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        ),
        onChanged: hasOpenBucket
            ? (value) {
                if (controller.objectFilterMode != BrowserFilterMode.text) {
                  controller.setObjectFilterMode(BrowserFilterMode.text);
                }
                unawaited(controller.applyObjectFilter(value));
              }
            : null,
      ),
    );
  }
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
    final phone = MediaQuery.sizeOf(context).width < 700;
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
          ? Column(
              children: [
                _labeledPhoneField(
                  context,
                  label: 'Endpoint profile',
                  child: _profileDropdown(context, profiles, phone: true),
                ),
                const SizedBox(height: 8),
                _labeledPhoneField(
                  context,
                  label: 'Backend engine',
                  child: _engineDropdown(context, engines, phone: true),
                ),
              ],
            )
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
    return DropdownButtonFormField<String>(
      initialValue: validProfileValue,
      isExpanded: true,
      dropdownColor: Theme.of(context).colorScheme.surface,
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
            (profile) => DropdownMenuItem(
              value: profile.id,
              child: Text(profile.name),
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
    return DropdownButtonFormField<String>(
      initialValue: validEngineValue,
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
            (engine) => DropdownMenuItem(
              value: engine.id,
              child: Text(engine.label),
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
  Timer? _dismissTimer;
  String? _lastMessage;
  bool _lastBusy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChange);
    _lastMessage = widget.controller.bannerMessage;
    _lastBusy = widget.controller.hasBusyActions;
    _scheduleDismiss();
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    widget.controller.removeListener(_handleChange);
    super.dispose();
  }

  void _handleChange() {
    final next = widget.controller.bannerMessage;
    final busy = widget.controller.hasBusyActions;
    if (next != _lastMessage || busy != _lastBusy) {
      _lastMessage = next;
      _lastBusy = busy;
      _scheduleDismiss();
    }
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    final message = widget.controller.bannerMessage;
    if (message == null || message.isEmpty) {
      return;
    }
    if (widget.controller.hasBusyActions) {
      return;
    }
    if (widget.controller.bannerTask?.isRunningLike ?? false) {
      return;
    }
    _dismissTimer = Timer(_dismissDelayFor(message), () {
      if (!mounted) return;
      if (widget.controller.bannerMessage == message &&
          !widget.controller.hasBusyActions) {
        widget.controller.clearBanner();
      }
    });
  }

  Duration _dismissDelayFor(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('listed ') ||
        normalized.contains('list returned') ||
        normalized.contains('listing completed') ||
        normalized.contains('completed listing')) {
      return const Duration(seconds: 2);
    }
    if (normalized.contains('listing ')) {
      return const Duration(seconds: 5);
    }
    return const Duration(milliseconds: 3500);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.controller.bannerMessage;
    final busy = widget.controller.hasBusyActions;
    final visible = message != null && message.isNotEmpty;
    final canOpenTask = widget.controller.bannerTaskId != null;
    final bannerTask = widget.controller.bannerTask;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.25),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: !visible
            ? const SizedBox.shrink(key: ValueKey('banner-empty'))
            : Align(
                key: ValueKey('banner-${bannerTask?.id ?? 'message'}'),
                alignment: Alignment.topRight,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.inverseSurface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant
                            .withValues(alpha: 0.4),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: canOpenTask
                                ? widget.controller.openBannerTask
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(0, 2, 6, 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _BannerStatusIndicator(
                                    busy: busy,
                                    canOpenTask: canOpenTask,
                                    task: bannerTask,
                                  ),
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Text(
                                      message,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        color:
                                            theme.colorScheme.onInverseSurface,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => widget.controller.clearBanner(),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: theme.colorScheme.onInverseSurface
                                  .withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _BannerStatusIndicator extends StatelessWidget {
  const _BannerStatusIndicator({
    required this.busy,
    required this.canOpenTask,
    required this.task,
  });

  final bool busy;
  final bool canOpenTask;
  final BrowserTaskRecord? task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progressTask = task?.kind == BrowserTaskKind.transfer ? task : null;
    if (progressTask != null) {
      final progress = progressTask.progress.clamp(0, 1).toDouble();
      final percent = (progress * 100).round();
      return Container(
        width: 44,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.onInverseSurface.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: theme.colorScheme.onInverseSurface.withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          '$percent%',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onInverseSurface,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return SizedBox(
      width: 16,
      height: 16,
      child: busy
          ? CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.onInverseSurface,
              ),
            )
          : Icon(
              canOpenTask
                  ? Icons.task_alt_outlined
                  : Icons.check_circle_outline,
              size: 16,
              color: theme.colorScheme.onInverseSurface,
            ),
    );
  }
}
