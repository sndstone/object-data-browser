import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import 'browser_workspace.dart';

/// The shell still refreshes its status banner for job/log events, but the
/// browser subtree only changes for data it actually displays. Inherited
/// theme, text scale and layout changes continue to flow through Flutter.
class BrowserWorkspaceFrame extends StatefulWidget {
  const BrowserWorkspaceFrame(
      {super.key, required this.controller, required this.compact});
  final AppController controller;
  final bool compact;
  @override
  State<BrowserWorkspaceFrame> createState() => _BrowserWorkspaceFrameState();
}

class _BrowserWorkspaceFrameState extends State<BrowserWorkspaceFrame> {
  Object? _signature;
  Widget? _child;
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final signature = (
      widget.compact,
      c.settings,
      c.profiles,
      c.engines,
      c.activeEngineId,
      c.selectedProfile,
      c.selectedBucket,
      c.buckets,
      c.objects,
      c.visibleObjects,
      c.filteringObjects,
      c.objectFilterError,
      c.selectedObject,
      c.selectedObjectDetails,
      c.selectedObjectPreview,
      c.objectSelection.keys.join('\u0000'),
      c.currentPrefix,
      c.flatView,
      c.objectPage,
      c.showAllObjects,
      c.listAllKeys,
      c.objectCursor,
      c.objectFilterMode,
      c.objectFilterValue,
      c.objectSortField,
      c.objectSortDescending,
      c.inspectorTab,
      Object.hashAll(c.inspectorGroupTabs.entries.map((e) => (e.key, e.value))),
      c.adminState,
      c.versions,
      c.versionCursor,
      c.versionBrowserOptions,
      c.capabilities,
      c.putTestDataState,
      c.deleteAllState,
      c.testDataConfig,
      c.deleteAllConfig,
      c.inspectorTab == BrowserInspectorTab.eventsAndDebug ? c.eventLog : null,
      c.isBusy('refresh-objects'),
      c.isBusy('select-object'),
      c.isBusy('upload'),
      c.isBusy('download'),
      c.isBusy('delete-object'),
      c.isBusy('select-bucket'),
    );
    if (_signature != signature || _child == null) {
      _signature = signature;
      _child = BrowserWorkspace(controller: c, compact: widget.compact);
    }
    return _child!;
  }
}
