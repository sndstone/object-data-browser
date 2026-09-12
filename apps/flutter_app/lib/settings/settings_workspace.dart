import 'settings_sections.dart';
import 'dart:async';
import '../widgets/setting_fields.dart';
import '../widgets/danger_button.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app/version_details.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/app_platform.dart';
import '../widgets/app_select_field.dart';
import 'profile_import_picker.dart';
import 'version_details_catalog.dart';

class SettingsWorkspace extends StatefulWidget {
  const SettingsWorkspace({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends State<SettingsWorkspace> {
  AppController get controller => widget.controller;
  String get _sectionName =>
      canonicalSettingsSection(controller.settingsSectionName);
  String? _editingProfileId;
  final Map<String, EndpointProfile> _profileDrafts = {};
  static const _sectionDescriptions = {
    'Connections':
        'Endpoint profiles and credentials. Exports never include secrets.',
    'General': 'Startup preferences and application behavior.',
    'Transfers': 'Upload sizing, concurrency and retry behavior.',
    'Appearance': 'Theme, text size and row density.',
    'Diagnostics': 'Choose which engine activity is recorded.',
  };
  static const _sections = settingsSections;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final phone = MediaQuery.sizeOf(context).width < 700;
    final isMobile = AppPlatform.isMobile;
    final dependencyVersions = visibleDependencyVersions(isMobile: isMobile);
    final bundledComponentVersions = visibleBundledComponentVersions(
      isMobile: isMobile,
      engines: controller.engines,
    );

    return LayoutBuilder(builder: (context, constraints) {
      final navigationWidth =
          220 * MediaQuery.textScalerOf(context).scale(14) / 14;
      final wide = constraints.maxWidth >= navigationWidth + 650;
      final rawSections = <_SettingsSection>[
        _SettingsSection(
            'General',
            Icons.settings_outlined,
            _sectionDescriptions['General'] ?? 'Configure General preferences.',
            () => _section(
                  context,
                  title: 'General',
                  children: () => [
                    AppSelectField<String>(
                      value: settings.defaultEngineId,
                      decoration:
                          const InputDecoration(labelText: 'Default engine'),
                      items: controller.engines
                          .map(
                            (engine) => AppSelectItem(
                              value: engine.id,
                              label: engine.label,
                            ),
                          )
                          .toList(),
                      onChanged: controller.engines.isEmpty
                          ? null
                          : (value) async {
                              if (value != null) {
                                await controller.setDefaultEngine(value);
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    AppSelectField<String>(
                      value: controller.profiles.any(
                        (profile) => profile.id == settings.defaultProfileId,
                      )
                          ? settings.defaultProfileId
                          : null,
                      decoration:
                          const InputDecoration(labelText: 'Default endpoint'),
                      items: controller.profiles
                          .map(
                            (profile) => AppSelectItem(
                              value: profile.id,
                              label: profile.name,
                            ),
                          )
                          .toList(),
                      onChanged: controller.profiles.isEmpty
                          ? null
                          : (value) async {
                              if (value != null) {
                                await controller.setDefaultProfile(value);
                              }
                            },
                    ),
                  ],
                )),
        _SettingsSection(
            'Connections',
            Icons.cable,
            _sectionDescriptions['Connections'] ??
                'Configure Connections preferences.',
            () => _section(
                  context,
                  title: 'Connections',
                  children: () => [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: controller.profiles.isEmpty
                              ? null
                              : () async {
                                  final defaultPath =
                                      '${controller.settings.downloadPath}${Platform.pathSeparator}s3-browser-profiles.json';
                                  final exportPath = isMobile
                                      ? defaultPath
                                      : (await FilePicker.platform.saveFile(
                                            dialogTitle: 'Export profiles',
                                            fileName: defaultPath
                                                .split(Platform.pathSeparator)
                                                .last,
                                          ) ??
                                          defaultPath);
                                  await controller
                                      .exportProfilesToPath(exportPath);
                                  if (Platform.isIOS && context.mounted) {
                                    final box = context.findRenderObject()
                                        as RenderBox?;
                                    await SharePlus.instance.share(
                                      ShareParams(
                                        files: [XFile(exportPath)],
                                        subject: 'Object Data Browser profiles',
                                        sharePositionOrigin: box == null
                                            ? null
                                            : box.localToGlobal(Offset.zero) &
                                                box.size,
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.upload_file_outlined),
                          label: const Text('Export profiles'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await FilePicker.platform.pickFiles(
                              type: profileImportPickerType(
                                isMobile: AppPlatform.isMobile,
                              ),
                              allowedExtensions: profileImportAllowedExtensions(
                                isMobile: AppPlatform.isMobile,
                              ),
                              dialogTitle: 'Import profiles',
                            );
                            final file = picked?.files.single;
                            final path = file?.path;
                            if (path == null) {
                              return;
                            }
                            if (file != null &&
                                !isJsonProfileImportSelection(file)) {
                              controller.showBannerMessage(
                                'Select a JSON profile export file.',
                                category: 'Profiles',
                                source: 'profiles',
                              );
                              return;
                            }
                            await controller.importProfilesFromPath(path);
                          },
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('Import profiles'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'App-generated profile exports contain endpoint settings only, never credentials. When an imported JSON file contains access and secret keys, they are moved into secure storage.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    if (controller.profiles.isEmpty)
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('No endpoint profiles configured'),
                        subtitle: Text(
                          'Create a profile, enter endpoint URL and credentials, save it, then test it by listing buckets.',
                        ),
                      )
                    else ...[
                      if (!phone || _editingProfileId == null)
                        for (final profile in controller.profiles)
                          ListTile(
                              selected: _editingProfileId == profile.id,
                              title: Text(profile.name),
                              subtitle: Text(profile.endpointUrl),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => setState(
                                  () => _editingProfileId = profile.id)),
                      if (phone && _editingProfileId != null)
                        TextButton.icon(
                            onPressed: () =>
                                setState(() => _editingProfileId = null),
                            icon: const Icon(Icons.arrow_back),
                            label: const Text('All connections')),
                      ...controller.profiles
                          .where((profile) =>
                              profile.id ==
                              (_editingProfileId ??
                                  (phone
                                      ? null
                                      : controller.profiles.first.id)))
                          .map(
                            (profile) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _ProfileEditorCard(
                                key: ValueKey(profile.id),
                                controller: controller,
                                profile: profile,
                                openEditor:
                                    phone || _editingProfileId == profile.id,
                                initialDraft: _profileDrafts[profile.id],
                                onDraftChanged: (draft) {
                                  if (draft == null) {
                                    _profileDrafts.remove(profile.id);
                                  } else {
                                    _profileDrafts[profile.id] = draft;
                                  }
                                },
                              ),
                            ),
                          ),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await controller.addSampleProfile();
                          if (mounted) {
                            setState(() => _editingProfileId =
                                controller.profiles.last.id);
                          }
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Create profile'),
                      ),
                    ),
                  ],
                )),
        _SettingsSection(
            'Transfers',
            Icons.swap_vert,
            _sectionDescriptions['Transfers'] ??
                'Configure Transfers preferences.',
            () => _section(
                  context,
                  title: 'Transfers',
                  children: () => [
                    Text(!isMobile &&
                            controller.selectedProfile?.endpointType !=
                                EndpointProfileType.azureBlob
                        ? 'Files: one at a time. Parallel S3 parts: up to ${(controller.selectedProfile?.maxConcurrentRequests ?? 8).clamp(1, 8)}. Change the limit in connection settings.'
                        : 'Files: one at a time. Parallel parts are managed by this engine.'),
                    const SizedBox(height: 12),
                    if (!isMobile)
                      AppSelectField<String>(
                        value: settings.downloadConflictPolicy,
                        decoration:
                            const InputDecoration(labelText: 'Existing files'),
                        items: const [
                          AppSelectItem(value: 'keepBoth', label: 'Keep both'),
                          AppSelectItem(
                              value: 'replace', label: 'Replace on success')
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            controller.updateSettings(settings.copyWith(
                                downloadConflictPolicy: value));
                          }
                        },
                      ),
                    const Text(
                        'Downloads are validated before publishing. Failed downloads preserve existing files.'),
                    const SizedBox(height: 12),
                    _numberField(
                      label: 'Multipart threshold (MiB)',
                      initialValue: settings.multipartThresholdMiB,
                      onSubmitted: (value) => controller.updateSettings(
                        settings.copyWith(multipartThresholdMiB: value),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.dynamicMultipartSizing,
                      onChanged: (value) => controller.updateSettings(
                        settings.copyWith(dynamicMultipartSizing: value),
                      ),
                      title: const Text('Automatically size upload parts'),
                      subtitle: const Text(
                        'Choose an S3-compliant part size independently for each file. Files share one upload job, while each file has its own multipart schedule. Disable this to use manual part sizes.',
                      ),
                    ),
                    const SizedBox(height: 4),
                    _numberField(
                      label: settings.dynamicMultipartSizing
                          ? 'Manual chunk size (MiB, downloads and fallback)'
                          : 'Manual multipart chunk size (MiB)',
                      min: 5,
                      max: 5120,
                      initialValue: settings.multipartChunkMiB,
                      onSubmitted: (value) => controller.updateSettings(
                        settings.copyWith(multipartChunkMiB: value),
                      ),
                    ),
                    SwitchListTile(
                      value: settings.relistObjectsAfterMutation,
                      onChanged: (value) => controller.updateSettings(
                        settings.copyWith(relistObjectsAfterMutation: value),
                      ),
                      title: const Text('Refresh object list after uploads'),
                      subtitle: const Text(
                        'Relist the current object view after prefix creation or a completed upload.',
                      ),
                    ),
                  ],
                )),
        _SettingsSection(
            'Downloads & Temp Storage',
            Icons.download_outlined,
            _sectionDescriptions['Downloads & Temp Storage'] ??
                'Configure Downloads & Temp Storage preferences.',
            () => _section(
                  context,
                  title: 'Downloads & Temp Storage',
                  children: () => [
                    _textField(
                      label: 'Default download path',
                      initialValue: settings.downloadPath,
                      onSubmitted: (value) => controller.updateSettings(
                          settings.copyWith(downloadPath: value)),
                    ),
                    const SizedBox(height: 12),
                    _textField(
                      label: 'Temp path override',
                      initialValue: settings.tempPath,
                      onSubmitted: (value) => controller
                          .updateSettings(settings.copyWith(tempPath: value)),
                    ),
                  ],
                )),
        _SettingsSection(
            'Appearance',
            Icons.palette_outlined,
            _sectionDescriptions['Appearance'] ??
                'Configure Appearance preferences.',
            () => _section(
                  context,
                  title: 'Appearance',
                  children: () => [
                    SwitchListTile(
                      value: settings.enableAnimations,
                      onChanged: (value) => controller.updateSettings(
                        settings.copyWith(enableAnimations: value),
                      ),
                      title: const Text('Enable animations'),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Compact desktop rows'),
                      subtitle: const Text(
                          'Keep text readable while reducing row padding. Touch targets remain comfortable.'),
                      value: controller.settings.compactRows,
                      onChanged: (value) => controller.updateSettings(
                          controller.settings.copyWith(compactRows: value)),
                    ),
                    SwitchListTile(
                      value: settings.darkMode,
                      onChanged: (value) => controller
                          .updateSettings(settings.copyWith(darkMode: value)),
                      title: const Text('Dark mode'),
                    ),
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                            'Desktop uses a rail; mobile uses segmented navigation. The browser, benchmark, and settings screens keep the same structure across platforms.')),
                    AppSelectField<BrowserInspectorLayout>(
                      value: settings.browserInspectorLayout,
                      decoration: const InputDecoration(
                        labelText: 'Browser inspector placement',
                      ),
                      items: const [
                        AppSelectItem(
                          value: BrowserInspectorLayout.bottom,
                          label: 'Below object panel',
                        ),
                        AppSelectItem(
                          value: BrowserInspectorLayout.right,
                          label: 'Right of object panel',
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        controller.updateSettings(
                          settings.copyWith(browserInspectorLayout: value),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Inspector panel size: ${settings.browserInspectorSize}px',
                      ),
                      subtitle: const Text(
                        'Applies to the inspector height in stacked mode and width in right-side mode.',
                      ),
                    ),
                    Slider(
                      min: 240,
                      max: 560,
                      divisions: 16,
                      value: settings.browserInspectorSize
                          .toDouble()
                          .clamp(240, 560),
                      label: '${settings.browserInspectorSize}px',
                      onChanged: (value) {
                        controller.updateSettings(
                          settings.copyWith(
                              browserInspectorSize: value.round()),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('UI scale: ${settings.uiScalePercent}%'),
                      subtitle: const Text(
                        'Text size is independent of row density. Default: 100%. OS accessibility enlargement is always respected.',
                      ),
                    ),
                    Slider(
                      min: 60,
                      max: 150,
                      divisions: 18,
                      value: settings.uiScalePercent.toDouble().clamp(60, 150),
                      label: '${settings.uiScalePercent}%',
                      onChanged: (value) {
                        controller.updateSettings(
                          settings.copyWith(uiScalePercent: value.round()),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Log text scale: ${settings.logTextScalePercent}%',
                      ),
                      subtitle: const Text(
                        'Applies only to Event Log and Events & Debug so trace text stays readable at smaller UI scales.',
                      ),
                    ),
                    Slider(
                      min: 80,
                      max: 130,
                      divisions: 10,
                      value: settings.logTextScalePercent
                          .toDouble()
                          .clamp(80, 130),
                      label: '${settings.logTextScalePercent}%',
                      onChanged: (value) {
                        controller.updateSettings(
                          settings.copyWith(logTextScalePercent: value.round()),
                        );
                      },
                    ),
                  ],
                )),
        _SettingsSection(
            'Safety & Recovery',
            Icons.health_and_safety_outlined,
            _sectionDescriptions['Safety & Recovery'] ??
                'Configure Safety & Recovery preferences.',
            () => _section(
                  context,
                  title: 'Safety & Recovery',
                  children: () => [
                    const Text(
                        'Credentials are stored securely and excluded from profile exports. A failed save remains session-only until retried successfully.'),
                    const SizedBox(height: 12),
                    const Text(
                        'Cancellation preserves completed work. Unconfirmed remote changes must be inspected before retrying. Engine restarts do not resume interrupted transfers.'),
                    const SizedBox(height: 12),
                    const Text(
                        'Transport timeouts and maximum attempts belong to each connection. Benchmark overrides are configured in Benchmark.'),
                  ],
                )),
        if (!isMobile)
          _SettingsSection(
              'Benchmark',
              Icons.speed,
              _sectionDescriptions['Benchmark'] ??
                  'Configure Benchmark preferences.',
              () => _section(
                    context,
                    title: 'Benchmark',
                    children: () => [
                      _numberField(
                        label: 'Benchmark workers',
                        min: 1,
                        max: 256,
                        initialValue: settings.transferConcurrency,
                        onSubmitted: (value) => controller.updateSettings(
                          settings.copyWith(transferConcurrency: value),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _numberField(
                        label: 'Benchmark maximum attempts',
                        min: 1,
                        max: 100,
                        initialValue: settings.safeRetries,
                        onSubmitted: (value) => controller.updateSettings(
                            settings.copyWith(safeRetries: value)),
                      ),
                      const SizedBox(height: 12),
                      phone
                          ? Column(
                              children: [
                                _numberField(
                                  label: 'Benchmark connect timeout (s)',
                                  initialValue: settings.connectTimeoutSeconds,
                                  onSubmitted: (value) =>
                                      controller.updateSettings(
                                    settings.copyWith(
                                        connectTimeoutSeconds: value),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _numberField(
                                  label: 'Benchmark read timeout (s)',
                                  initialValue: settings.readTimeoutSeconds,
                                  onSubmitted: (value) =>
                                      controller.updateSettings(
                                    settings.copyWith(
                                        readTimeoutSeconds: value),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: _numberField(
                                    label: 'Benchmark connect timeout (s)',
                                    initialValue:
                                        settings.connectTimeoutSeconds,
                                    onSubmitted: (value) =>
                                        controller.updateSettings(
                                      settings.copyWith(
                                          connectTimeoutSeconds: value),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _numberField(
                                    label: 'Benchmark read timeout (s)',
                                    initialValue: settings.readTimeoutSeconds,
                                    onSubmitted: (value) =>
                                        controller.updateSettings(
                                      settings.copyWith(
                                          readTimeoutSeconds: value),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                      const SizedBox(height: 12),
                      _numberField(
                        label: 'Benchmark connection pool',
                        initialValue: settings.maxPoolConnections,
                        onSubmitted: (value) => controller.updateSettings(
                          settings.copyWith(maxPoolConnections: value),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        value: settings.benchmarkChartSmoothing,
                        onChanged: (value) => controller.updateSettings(
                          settings.copyWith(benchmarkChartSmoothing: value),
                        ),
                        title: const Text('Smooth result charts'),
                      ),
                      SwitchListTile(
                        value: settings.benchmarkDebugMode,
                        onChanged: (value) => controller.updateSettings(
                          settings.copyWith(benchmarkDebugMode: value),
                        ),
                        title: const Text('Benchmark debug mode'),
                      ),
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                              'Benchmark mode always uses the currently selected endpoint profile and backend engine from the app header.')),
                      _numberField(
                        label: 'Benchmark data cache (MB)',
                        min: 0,
                        max: 2147483647,
                        initialValue: settings.benchmarkDataCacheMb,
                        onSubmitted: (value) => controller.updateSettings(
                          settings.copyWith(benchmarkDataCacheMb: value),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _textField(
                        label: 'Benchmark log path',
                        initialValue: settings.benchmarkLogPath,
                        onSubmitted: (value) => controller.updateSettings(
                          settings.copyWith(benchmarkLogPath: value),
                        ),
                      ),
                    ],
                  )),
        _SettingsSection(
            'Diagnostics',
            Icons.bug_report_outlined,
            _sectionDescriptions['Diagnostics'] ??
                'Configure Diagnostics preferences.',
            () => _section(
                  context,
                  title: 'Diagnostics',
                  children: () => [
                    SwitchListTile(
                      value: settings.enableDiagnostics,
                      onChanged: (value) => controller.updateSettings(
                        settings.copyWith(enableDiagnostics: value),
                      ),
                      title: const Text('Diagnostics workspace'),
                    ),
                    SwitchListTile(
                      value: settings.enableApiLogging,
                      onChanged: (value) => controller.updateSettings(
                        settings.copyWith(enableApiLogging: value),
                      ),
                      title: const Text('API logging'),
                    ),
                    SwitchListTile(
                      value: settings.enableDebugLogging,
                      onChanged: (value) => controller.updateSettings(
                        settings.copyWith(enableDebugLogging: value),
                      ),
                      title: const Text('Debug logging in Event Log'),
                    ),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Diagnostic logging'),
                      subtitle: Text(
                        'API logging records redacted request and response envelopes. Debug logging adds broader trace details in Event Log.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _numberField(
                      label: 'Default presign expiration (minutes)',
                      min: 1,
                      max: 10080,
                      initialValue: settings.defaultPresignMinutes,
                      onSubmitted: (value) => controller.updateSettings(
                        settings.copyWith(defaultPresignMinutes: value),
                      ),
                    ),
                  ],
                )),
        _SettingsSection(
            'Version Details',
            Icons.info_outline,
            _sectionDescriptions['Version Details'] ??
                'Configure Version Details preferences.',
            () => _section(
                  context,
                  title: 'Version Details',
                  children: () => [
                    TextButton.icon(
                        onPressed: () => showLicensePage(
                            context: context,
                            applicationName: 'Object Data Browser',
                            applicationVersion: kApplicationVersion),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Open source and font licenses')),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Application version'),
                      subtitle:
                          Text('$kApplicationVersion ($kApplicationBuild)'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isMobile
                          ? 'Mobile app dependencies'
                          : 'Flutter dependencies',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ...dependencyVersions.entries.map(
                      (entry) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry.key),
                        trailing: Text(entry.value),
                      ),
                    ),
                    if (bundledComponentVersions.isNotEmpty) ...[
                      const Divider(height: 24),
                      Text(
                        isMobile ? 'Mobile engines' : 'Bundled engines',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      ...bundledComponentVersions.entries.map(
                        (entry) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry.key),
                          trailing: Text(entry.value),
                        ),
                      ),
                    ],
                  ],
                )),
      ];
      rawSections.sort((a, b) => a.title == 'General'
          ? 1
          : b.title == 'General'
              ? -1
              : 0);
      final sections = <_SettingsSection>[
        for (final name in settingsSections)
          if (rawSections.any(
              (section) => canonicalSettingsSection(section.title) == name))
            _SettingsSection(
                name,
                rawSections
                    .firstWhere((section) =>
                        canonicalSettingsSection(section.title) == name)
                    .icon,
                name == 'Connections'
                    ? 'Test drafts, save credentials, and activate connections independently.'
                    : 'Configure $name.',
                () => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final section in rawSections)
                            if (canonicalSettingsSection(section.title) == name)
                              section.builder(),
                        ])),
      ];
      final active = sections.firstWhere((s) => s.title == _sectionName,
          orElse: () => sections.first);
      final content = ListView(padding: const EdgeInsets.all(16), children: [
        _sectionIntro(context,
            title: active.title, description: active.description, wide: wide),
        const SizedBox(height: 16),
        if (controller.persistenceState.warning != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(controller.persistenceState.warning!),
                        TextButton(
                            onPressed: controller.retrySaveSettings,
                            child: const Text('Retry saving')),
                      ]))),
        active.builder(),
      ]);
      if (!wide) return content;
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
            width: navigationWidth,
            child: ListView(padding: const EdgeInsets.all(12), children: [
              for (final section in sections)
                Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Material(
                        color: Colors.transparent,
                        child: ListTile(
                            selected: _sectionName == section.title,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            selectedTileColor:
                                Theme.of(context).colorScheme.primaryContainer,
                            leading: Icon(section.icon, size: 18),
                            title: Text(section.title),
                            onTap: () =>
                                controller.setSettingsSection(section.title)))),
            ])),
        const VerticalDivider(width: 1),
        Expanded(child: content),
      ]);
    });
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required List<Widget> Function() children,
  }) {
    final theme = Theme.of(context);
    final phone = MediaQuery.sizeOf(context).width < 700;
    if (canonicalSettingsSection(title) != _sectionName) {
      return const SizedBox.shrink();
    }
    return Offstage(
        offstage: false,
        child: TickerMode(
            enabled: canonicalSettingsSection(title) == _sectionName,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                decoration: BoxDecoration(
                  color:
                      phone ? theme.colorScheme.surface : theme.cardTheme.color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.all(16),
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      ...children(),
                    ],
                  ),
                ),
              ),
            )));
  }

  Widget _sectionIntro(
    BuildContext context, {
    required String title,
    required String description,
    required bool wide,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 10),
          Text(description, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 16),
          if (!wide)
            AppSelectField<String>(
                value: _sectionName,
                decoration:
                    const InputDecoration(labelText: 'Settings section'),
                items: _sections
                    .where((s) => s != 'Benchmark' || !AppPlatform.isMobile)
                    .map((s) => AppSelectItem(value: s, label: s))
                    .toList(),
                onChanged: (value) {
                  if (value != null) controller.setSettingsSection(value);
                }),
        ],
      ),
    );
  }

  Widget _textField({
    required String label,
    required String initialValue,
    required ValueChanged<String> onSubmitted,
  }) {
    return SettingTextField(
        key: ValueKey(label),
        label: label,
        value: initialValue,
        onCommit: onSubmitted);
  }

  Widget _numberField(
      {required String label,
      required int initialValue,
      required ValueChanged<int> onSubmitted,
      int min = 1,
      int max = 2147483647}) {
    return SettingNumberField(
        key: ValueKey(label),
        label: label,
        value: initialValue,
        min: min,
        max: max,
        onCommit: onSubmitted);
  }
}

class _ProfileEditorCard extends StatefulWidget {
  const _ProfileEditorCard({
    super.key,
    required this.controller,
    required this.profile,
    this.initialDraft,
    this.openEditor = false,
    required this.onDraftChanged,
  });

  final AppController controller;
  final EndpointProfile profile;
  final EndpointProfile? initialDraft;
  final bool openEditor;
  final ValueChanged<EndpointProfile?> onDraftChanged;

  @override
  State<_ProfileEditorCard> createState() => _ProfileEditorCardState();
}

class _ProfileEditorCardState extends State<_ProfileEditorCard> {
  final _editorExpansion = ExpansibleController();
  late final TextEditingController _nameController;
  late final TextEditingController _endpointController;
  late final TextEditingController _regionController;
  late final TextEditingController _accessKeyController;
  late final TextEditingController _secretKeyController;
  late final TextEditingController _sessionTokenController;
  late final TextEditingController _connectTimeoutController;
  late final TextEditingController _readTimeoutController;
  late final TextEditingController _notesController;
  late EndpointProfileType _endpointType;
  late int _connectionLimit;
  late int _maxAttempts;
  late bool _pathStyle;
  late bool _useHttps;
  late bool _verifyTls;
  late bool _expanded;
  bool _revealSecret = false, _revealToken = false;
  Timer? _revealTimer;
  void _reveal(bool token) {
    setState(() {
      if (token) {
        _revealToken = !_revealToken;
      } else {
        _revealSecret = !_revealSecret;
      }
    });
    _revealTimer?.cancel();
    _revealTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() {
          _revealSecret = false;
          _revealToken = false;
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _syncFromProfile();
    _connectionLimit =
        (widget.initialDraft ?? widget.profile).maxConcurrentRequests;
    _maxAttempts = (widget.initialDraft ?? widget.profile).maxAttempts;
    _expanded = widget.openEditor || !_looksConfigured(widget.profile);
    for (final field in [
      _nameController,
      _endpointController,
      _regionController,
      _accessKeyController,
      _secretKeyController,
      _sessionTokenController,
      _connectTimeoutController,
      _readTimeoutController,
      _notesController
    ]) {
      field.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant _ProfileEditorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openEditor && !oldWidget.openEditor) {
      _editorExpansion.expand();
    }
    if (oldWidget.profile != widget.profile) {
      widget.onDraftChanged(null);
      _revealSecret = false;
      _revealToken = false;
      _syncText(_nameController, widget.profile.name);
      _syncText(_endpointController, widget.profile.endpointUrl);
      _syncText(_regionController, widget.profile.region);
      _syncText(_accessKeyController, widget.profile.accessKey);
      _syncText(_secretKeyController, widget.profile.secretKey);
      _syncText(_sessionTokenController, widget.profile.sessionToken ?? '');
      _syncText(
        _connectTimeoutController,
        '${widget.profile.connectTimeoutSeconds}',
      );
      _syncText(_readTimeoutController, '${widget.profile.readTimeoutSeconds}');
      _syncText(_notesController, widget.profile.notes ?? '');
      _endpointType = widget.profile.endpointType;
      _connectionLimit = widget.profile.maxConcurrentRequests;
      _maxAttempts = widget.profile.maxAttempts;
      _pathStyle = widget.profile.pathStyle;
      _useHttps = endpointUsesHttps(
        widget.profile.endpointUrl,
        fallback: widget.profile.verifyTls,
      );
      _verifyTls = widget.profile.verifyTls;
      _expanded = widget.openEditor || !_looksConfigured(widget.profile);
    }
  }

  void _syncFromProfile() {
    final profile = widget.initialDraft ?? widget.profile;
    _nameController = TextEditingController(text: profile.name);
    _endpointController = TextEditingController(text: profile.endpointUrl);
    _regionController = TextEditingController(text: profile.region);
    _accessKeyController = TextEditingController(text: profile.accessKey);
    _secretKeyController = TextEditingController(text: profile.secretKey);
    _sessionTokenController =
        TextEditingController(text: profile.sessionToken ?? '');
    _connectTimeoutController = TextEditingController(
      text: '${profile.connectTimeoutSeconds}',
    );
    _readTimeoutController = TextEditingController(
      text: '${profile.readTimeoutSeconds}',
    );
    _notesController = TextEditingController(text: profile.notes ?? '');
    _endpointType = profile.endpointType;
    _pathStyle = profile.pathStyle;
    _useHttps = endpointUsesHttps(
      profile.endpointUrl,
      fallback: profile.verifyTls,
    );
    _verifyTls = profile.verifyTls;
    _endpointController.addListener(_handleEndpointInputChanged);
    _accessKeyController.addListener(_handleAccessKeyChanged);
  }

  void _handleAccessKeyChanged() {
    // For Azure profiles the access key field holds the storage account name,
    // which drives the derived endpoint preview.
    if (_endpointType == EndpointProfileType.azureBlob && mounted) {
      setState(() {});
    }
  }

  void _syncText(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.text = value;
    }
  }

  void _handleEndpointInputChanged() {
    if (_endpointType == EndpointProfileType.awsS3) {
      return;
    }
    final detected = _detectedUseHttps(_endpointController.text);
    if (detected == null || detected == _useHttps) {
      return;
    }
    setState(() {
      _useHttps = detected;
      if (!_useHttps) {
        _verifyTls = false;
      }
    });
  }

  bool? _detectedUseHttps(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('https://')) {
      return true;
    }
    if (trimmed.startsWith('http://')) {
      return false;
    }
    return null;
  }

  void _setEndpointType(EndpointProfileType value) {
    setState(() {
      _endpointType = value;
      if (_endpointType == EndpointProfileType.awsS3) {
        _useHttps = true;
        _verifyTls = true;
        _pathStyle = false;
        if (_regionController.text.trim().isEmpty) {
          _regionController.text = 'us-east-1';
        }
      } else if (_endpointType == EndpointProfileType.azureBlob) {
        _useHttps = true;
        _verifyTls = true;
        _pathStyle = false;
      }
    });
  }

  void _setUseHttps(bool value) {
    setState(() {
      _useHttps = value;
      if (!value) {
        _verifyTls = false;
      }
    });
  }

  String get _normalizedEndpointPreview {
    if (_endpointType == EndpointProfileType.awsS3) {
      return awsEndpointForRegion(_regionController.text);
    }
    if (_endpointType == EndpointProfileType.azureBlob &&
        _endpointController.text.trim().isEmpty) {
      return azureEndpointForAccount(_accessKeyController.text);
    }
    return normalizeEndpointUrl(
      _endpointController.text,
      preferHttps: _useHttps,
    );
  }

  List<String> get _awsRegionOptions {
    final current = _regionController.text.trim();
    return <String>[
      ...kAwsRegions,
      if (current.isNotEmpty && !kAwsRegions.contains(current)) current,
    ];
  }

  EndpointProfile _buildProfile() {
    return normalizeEndpointProfile(
      EndpointProfile(
        id: widget.profile.id,
        name: _nameController.text.trim(),
        endpointUrl: switch (_endpointType) {
          EndpointProfileType.awsS3 =>
            awsEndpointForRegion(_regionController.text),
          EndpointProfileType.azureBlob =>
            _endpointController.text.trim().isEmpty
                ? ''
                : normalizeEndpointUrl(
                    _endpointController.text.trim(),
                    preferHttps: _useHttps,
                  ),
          EndpointProfileType.s3Compatible => normalizeEndpointUrl(
              _endpointController.text.trim(),
              preferHttps: _useHttps,
            ),
        },
        region: _regionController.text.trim(),
        accessKey: _accessKeyController.text.trim(),
        secretKey: _secretKeyController.text.trim(),
        sessionToken: (_endpointType == EndpointProfileType.azureBlob ||
                _sessionTokenController.text.trim().isEmpty)
            ? null
            : _sessionTokenController.text.trim(),
        pathStyle: _endpointType == EndpointProfileType.s3Compatible
            ? _pathStyle
            : false,
        verifyTls: _endpointType == EndpointProfileType.awsS3
            ? true
            : (_useHttps && _verifyTls),
        endpointType: _endpointType,
        connectTimeoutSeconds:
            int.tryParse(_connectTimeoutController.text.trim()) ?? 5,
        readTimeoutSeconds:
            int.tryParse(_readTimeoutController.text.trim()) ?? 60,
        signerOverride: widget.profile.signerOverride,
        maxConcurrentRequests: _connectionLimit,
        maxAttempts: _maxAttempts,
        maxRequestsPerSecond: widget.profile.maxRequestsPerSecond,
        notes: _notesController.text.trim(),
      ),
    );
  }

  bool _looksConfigured(EndpointProfile profile) {
    return profile.name.trim().isNotEmpty &&
        profile.accessKey.trim().isNotEmpty &&
        profile.secretKey.trim().isNotEmpty &&
        (profile.endpointType == EndpointProfileType.awsS3 ||
            profile.endpointType == EndpointProfileType.azureBlob ||
            profile.endpointUrl.trim().isNotEmpty);
  }

  @override
  void dispose() {
    final draft = _buildProfile();
    widget.onDraftChanged(draft == widget.profile ? null : draft);
    _revealTimer?.cancel();
    _endpointController.removeListener(_handleEndpointInputChanged);
    _accessKeyController.removeListener(_handleAccessKeyChanged);
    _editorExpansion.dispose();
    _nameController.dispose();
    _endpointController.dispose();
    _regionController.dispose();
    _accessKeyController.dispose();
    _secretKeyController.dispose();
    _sessionTokenController.dispose();
    _connectTimeoutController.dispose();
    _readTimeoutController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? timeoutError(String value) {
      final n = int.tryParse(value.trim());
      return n == null || n < 1 || n > 2147483647
          ? 'Enter a positive timeout in seconds.'
          : null;
    }

    final connectError = timeoutError(_connectTimeoutController.text);
    final readError = timeoutError(_readTimeoutController.text);
    final valid = connectError == null && readError == null;
    final isDirty = _buildProfile() != widget.profile;
    final isSelected =
        widget.controller.selectedProfile?.id == widget.profile.id;
    final isTesting =
        widget.controller.isBusy('test-profile-${widget.profile.id}');
    final isSelecting = widget.controller.isBusy('select-profile');
    final phone = MediaQuery.sizeOf(context).width < 700;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ExpansionTile(
          controller: _editorExpansion,
          initiallyExpanded: _expanded,
          onExpansionChanged: (value) => setState(() {
            _expanded = value;
            if (!value) {
              _revealSecret = false;
              _revealToken = false;
            }
          }),
          title: Text(
            widget.profile.name.isEmpty
                ? 'Unnamed profile'
                : widget.profile.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                _normalizedEndpointPreview.isEmpty
                    ? 'Connection details not configured yet.'
                    : _normalizedEndpointPreview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (isSelected) const Chip(label: Text('Active')),
                Chip(
                    backgroundColor: isDirty
                        ? Theme.of(context).colorScheme.tertiaryContainer
                        : null,
                    label: Text(isDirty
                        ? 'Unsaved edits'
                        : widget.controller
                            .profilePersistenceStatusFor(widget.profile.id))),
                if (widget.controller.settings.defaultProfileId ==
                    widget.profile.id)
                  const Chip(label: Text('Startup default')),
              ],
            ),
          ]),
          trailing: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            if (!widget.controller.supportsProfile(_buildProfile()))
              const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('This engine does not support Azure.'),
                  subtitle: Text(
                      'Select Python or Go on desktop before testing or activating this connection.')),
            if (!AppPlatform.isMobile &&
                !widget.controller.supportsProfile(_buildProfile()))
              Wrap(spacing: 8, children: [
                for (final engine in widget.controller.engines)
                  if (engine.available &&
                      const {'python', 'go'}.contains(engine.id))
                    TextButton(
                        onPressed: () => widget.controller.setEngine(engine.id),
                        child: Text('Switch to ${engine.label}')),
              ]),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Profile name'),
            ),
            const SizedBox(height: 12),
            AppSelectField<EndpointProfileType>(
              value: _endpointType,
              decoration: const InputDecoration(labelText: 'Endpoint type'),
              items: const [
                AppSelectItem(
                  value: EndpointProfileType.s3Compatible,
                  label: 'S3-compatible',
                ),
                AppSelectItem(
                  value: EndpointProfileType.awsS3,
                  label: 'AWS S3',
                ),
                AppSelectItem(
                  value: EndpointProfileType.azureBlob,
                  label: 'Azure Blob Storage',
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  _setEndpointType(value);
                }
              },
            ),
            const SizedBox(height: 12),
            if (_endpointType == EndpointProfileType.s3Compatible) ...[
              TextField(
                controller: _endpointController,
                decoration: const InputDecoration(
                  labelText: 'Endpoint host or URL',
                  helperText:
                      'Paste a full URL or just a host:port. The scheme is added automatically when missing.',
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _useHttps,
                onChanged: _setUseHttps,
                title: const Text('Use HTTPS'),
                subtitle: Text(
                  _useHttps
                      ? 'Use HTTPS for this endpoint.'
                      : 'Use HTTP for this endpoint. TLS verification is disabled automatically.',
                ),
              ),
              TextField(
                controller: _regionController,
                decoration: const InputDecoration(labelText: 'Region'),
              ),
            ] else if (_endpointType == EndpointProfileType.azureBlob) ...[
              TextField(
                controller: _endpointController,
                decoration: const InputDecoration(
                  labelText: 'Custom blob endpoint (optional)',
                  helperText:
                      'Leave blank to use https://<account>.blob.core.windows.net. '
                      'Set this for Azurite or sovereign clouds.',
                ),
              ),
              if (_endpointController.text.trim().isNotEmpty)
                SwitchListTile(
                  value: _useHttps,
                  onChanged: _setUseHttps,
                  title: const Text('Use HTTPS'),
                  subtitle: Text(
                    _useHttps
                        ? 'Use HTTPS for this endpoint.'
                        : 'Use HTTP for this endpoint. TLS verification is disabled automatically.',
                  ),
                ),
            ] else ...[
              AppSelectField<String>(
                value: _awsRegionOptions.contains(_regionController.text.trim())
                    ? (_regionController.text.trim().isEmpty
                        ? 'us-east-1'
                        : _regionController.text.trim())
                    : 'us-east-1',
                decoration: const InputDecoration(labelText: 'AWS region'),
                items: _awsRegionOptions
                    .map(
                      (region) => AppSelectItem(
                        value: region,
                        label: region,
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _regionController.text = value;
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 12),
            if (_normalizedEndpointPreview.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _useHttps ? Icons.lock_outline : Icons.lock_open_outlined,
                ),
                title: Text(switch (_endpointType) {
                  EndpointProfileType.awsS3 => 'AWS endpoint',
                  EndpointProfileType.azureBlob => 'Blob service endpoint',
                  EndpointProfileType.s3Compatible => 'Normalized endpoint',
                }),
                subtitle: Text(_normalizedEndpointPreview),
              ),
            if (_normalizedEndpointPreview.isNotEmpty)
              const SizedBox(height: 12),
            phone
                ? Column(
                    children: [
                      TextField(
                        controller: _accessKeyController,
                        decoration: InputDecoration(
                          labelText: _endpointType.accessKeyLabel,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _secretKeyController,
                        obscureText: !_revealSecret,
                        style: _revealSecret
                            ? const TextStyle(fontFamily: 'monospace')
                            : null,
                        decoration: InputDecoration(
                          labelText: _endpointType.secretKeyLabel,
                          suffixIcon: IconButton(
                              tooltip: _revealSecret
                                  ? 'Hide secret'
                                  : 'Reveal secret',
                              onPressed: () => _reveal(false),
                              icon: Icon(_revealSecret
                                  ? Icons.visibility_off
                                  : Icons.visibility)),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _accessKeyController,
                          decoration: InputDecoration(
                            labelText: _endpointType.accessKeyLabel,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _secretKeyController,
                          obscureText: !_revealSecret,
                          style: _revealSecret
                              ? const TextStyle(fontFamily: 'monospace')
                              : null,
                          decoration: InputDecoration(
                            labelText: _endpointType.secretKeyLabel,
                            suffixIcon: IconButton(
                                tooltip: _revealSecret
                                    ? 'Hide secret'
                                    : 'Reveal secret',
                                onPressed: () => _reveal(false),
                                icon: Icon(_revealSecret
                                    ? Icons.visibility_off
                                    : Icons.visibility)),
                          ),
                        ),
                      ),
                    ],
                  ),
            const SizedBox(height: 12),
            if (_endpointType != EndpointProfileType.azureBlob)
              TextField(
                controller: _sessionTokenController,
                obscureText: !_revealToken,
                style: _revealToken
                    ? const TextStyle(fontFamily: 'monospace')
                    : null,
                decoration: InputDecoration(
                  suffixIcon: IconButton(
                      tooltip: _revealToken ? 'Hide token' : 'Reveal token',
                      onPressed: () => _reveal(true),
                      icon: Icon(_revealToken
                          ? Icons.visibility_off
                          : Icons.visibility)),
                  labelText: 'Session token (optional)',
                ),
              ),
            ExpansionTile(title: const Text('Advanced transport'), children: [
              if (!AppPlatform.isMobile &&
                  _endpointType != EndpointProfileType.azureBlob) ...[
                SettingNumberField(
                    label:
                        'Connection pool limit (S3 part workers capped at 8)',
                    value: _connectionLimit,
                    min: 1,
                    max: 256,
                    onCommit: (value) =>
                        setState(() => _connectionLimit = value)),
                const SizedBox(height: 12),
                SettingNumberField(
                    label: 'Maximum attempts',
                    value: _maxAttempts,
                    min: 1,
                    max: 100,
                    onCommit: (value) => setState(() => _maxAttempts = value)),
                const SizedBox(height: 12),
              ] else
                const Text(
                    'This engine manages connection pools and retry limits.'),
              SwitchListTile(
                value: _pathStyle,
                onChanged: _endpointType == EndpointProfileType.s3Compatible
                    ? (value) => setState(() => _pathStyle = value)
                    : null,
                title: const Text('Force path-style requests'),
                subtitle: Text(switch (_endpointType) {
                  EndpointProfileType.awsS3 =>
                    'AWS S3 uses the standard virtual-hosted endpoint layout.',
                  EndpointProfileType.azureBlob =>
                    'Not applicable to Azure Blob Storage.',
                  EndpointProfileType.s3Compatible =>
                    'Useful for MinIO and other S3-compatible endpoints.',
                }),
              ),
              SwitchListTile(
                value: _verifyTls,
                onChanged:
                    (_endpointType != EndpointProfileType.awsS3 && _useHttps)
                        ? (value) => setState(() => _verifyTls = value)
                        : null,
                title: const Text('Verify TLS certificates'),
                subtitle: Text(
                  _endpointType == EndpointProfileType.awsS3
                      ? 'AWS S3 always uses HTTPS with certificate verification enabled.'
                      : (_useHttps
                          ? 'Disable this only for self-signed or lab endpoints.'
                          : 'TLS verification is off because this endpoint uses HTTP.'),
                ),
              ),
              phone
                  ? Column(
                      children: [
                        TextField(
                          controller: _connectTimeoutController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            errorText: connectError,
                            labelText: 'Connect timeout (s)',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _readTimeoutController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            errorText: readError,
                            labelText: 'Read timeout (s)',
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _connectTimeoutController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              errorText: connectError,
                              labelText: 'Connect timeout (s)',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _readTimeoutController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              errorText: readError,
                              labelText: 'Read timeout (s)',
                            ),
                          ),
                        ),
                      ],
                    ),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: !valid ||
                          !isDirty &&
                              widget.controller.profilePersistenceStatusFor(
                                      widget.profile.id) ==
                                  'Saved'
                      ? null
                      : () async {
                          final profile = _buildProfile();
                          await widget.controller.saveProfile(profile);
                        },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
                OutlinedButton.icon(
                  onPressed: !valid ||
                          !widget.controller.supportsProfile(_buildProfile()) ||
                          isTesting
                      ? null
                      : () async {
                          final profile = _buildProfile();
                          await widget.controller.testProfileDraft(profile);
                        },
                  icon: const Icon(Icons.playlist_add_check_circle_outlined),
                  label: Text(isTesting ? 'Testing...' : 'Test'),
                ),
                OutlinedButton.icon(
                  onPressed: !valid ||
                          !widget.controller.supportsProfile(_buildProfile()) ||
                          isSelecting
                      ? null
                      : () async {
                          final profile = _buildProfile();
                          widget.controller.updateProfile(profile);
                          await widget.controller
                              .setSelectedProfileById(profile.id);
                        },
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(isSelecting ? 'Loading...' : 'Use profile'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () async {
                    final profile = widget.profile;
                    final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                                title:
                                    Text('Delete profile "${profile.name}"?'),
                                content: Text(
                                    'This removes the endpoint profile and its saved credentials.${isSelected ? '\nThe app will switch to the next available profile.' : ''}'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel')),
                                  DangerButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Delete profile'))
                                ]));
                    if (confirmed == true) {
                      await widget.controller.deleteProfile(profile.id);
                    }
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete…'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSection {
  const _SettingsSection(this.title, this.icon, this.description, this.builder);
  final String title, description;
  final IconData icon;
  final Widget Function() builder;
}
