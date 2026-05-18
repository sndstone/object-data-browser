import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/version_details.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import 'profile_import_picker.dart';
import 'version_details_catalog.dart';

class SettingsWorkspace extends StatelessWidget {
  const SettingsWorkspace({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final phone = MediaQuery.sizeOf(context).width < 700;
    final isAndroid = Platform.isAndroid;
    final dependencyVersions = visibleDependencyVersions(isAndroid: isAndroid);
    final bundledComponentVersions = visibleBundledComponentVersions(
      isAndroid: isAndroid,
      engines: controller.engines,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionIntro(
          context,
          title: 'Settings',
          description:
              'Tune the storage shell, connection behavior, and transfer defaults without losing the desktop workflow.',
        ),
        const SizedBox(height: 16),
        _section(
          context,
          title: 'General',
          children: [
            SwitchListTile(
              value: settings.enableAnimations,
              onChanged: (value) => controller.updateSettings(
                settings.copyWith(enableAnimations: value),
              ),
              title: const Text('Enable animations'),
            ),
            DropdownButtonFormField<String>(
              initialValue: settings.defaultEngineId,
              decoration: const InputDecoration(labelText: 'Default engine'),
              items: controller.engines
                  .map(
                    (engine) => DropdownMenuItem(
                      value: engine.id,
                      child: Text(engine.label),
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
          ],
        ),
        _section(
          context,
          title: 'Connections',
          children: [
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
                          final exportPath = Platform.isAndroid
                              ? defaultPath
                              : (await FilePicker.platform.saveFile(
                                    dialogTitle: 'Export profiles',
                                    fileName: defaultPath
                                        .split(Platform.pathSeparator)
                                        .last,
                                  ) ??
                                  defaultPath);
                          await controller.exportProfilesToPath(exportPath);
                        },
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Export profiles'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await FilePicker.platform.pickFiles(
                      type: profileImportPickerType(
                        isAndroid: Platform.isAndroid,
                      ),
                      allowedExtensions: profileImportAllowedExtensions(
                        isAndroid: Platform.isAndroid,
                      ),
                      dialogTitle: 'Import profiles',
                    );
                    final file = picked?.files.single;
                    final path = file?.path;
                    if (path == null) {
                      return;
                    }
                    if (file != null && !isJsonProfileImportSelection(file)) {
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
            const SizedBox(height: 12),
            if (controller.profiles.isEmpty)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('No endpoint profiles configured'),
                subtitle: Text(
                  'Create a profile, enter endpoint URL and credentials, save it, then test it by listing buckets.',
                ),
              )
            else
              ...controller.profiles.map(
                (profile) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ProfileEditorCard(
                    key: ValueKey(profile.id),
                    controller: controller,
                    profile: profile,
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await controller.addSampleProfile();
                },
                icon: const Icon(Icons.add),
                label: const Text('Create profile'),
              ),
            ),
          ],
        ),
        _section(
          context,
          title: 'Transfers',
          children: [
            _numberField(
              label: 'Concurrent transfers',
              initialValue: settings.transferConcurrency,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(transferConcurrency: value),
              ),
            ),
            const SizedBox(height: 12),
            _numberField(
              label: 'Multipart threshold (MiB)',
              initialValue: settings.multipartThresholdMiB,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(multipartThresholdMiB: value),
              ),
            ),
            const SizedBox(height: 12),
            _numberField(
              label: 'Multipart chunk size (MiB)',
              initialValue: settings.multipartChunkMiB,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(multipartChunkMiB: value),
              ),
            ),
          ],
        ),
        _section(
          context,
          title: 'Downloads & Temp Storage',
          children: [
            _textField(
              label: 'Default download path',
              initialValue: settings.downloadPath,
              onSubmitted: (value) => controller
                  .updateSettings(settings.copyWith(downloadPath: value)),
            ),
            const SizedBox(height: 12),
            _textField(
              label: 'Temp path override',
              initialValue: settings.tempPath,
              onSubmitted: (value) =>
                  controller.updateSettings(settings.copyWith(tempPath: value)),
            ),
          ],
        ),
        _section(
          context,
          title: 'Appearance',
          children: [
            SwitchListTile(
              value: settings.darkMode,
              onChanged: (value) =>
                  controller.updateSettings(settings.copyWith(darkMode: value)),
              title: const Text('Dark mode'),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Unified adaptive shell'),
              subtitle: Text(
                'Desktop uses a rail; mobile uses segmented navigation. The browser, benchmark, and settings screens keep the same structure across platforms.',
              ),
            ),
            DropdownButtonFormField<BrowserInspectorLayout>(
              initialValue: settings.browserInspectorLayout,
              decoration: const InputDecoration(
                labelText: 'Browser inspector placement',
              ),
              items: const [
                DropdownMenuItem(
                  value: BrowserInspectorLayout.bottom,
                  child: Text('Below object panel'),
                ),
                DropdownMenuItem(
                  value: BrowserInspectorLayout.right,
                  child: Text('Right of object panel'),
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
              value: settings.browserInspectorSize.toDouble().clamp(240, 560),
              label: '${settings.browserInspectorSize}px',
              onChanged: (value) {
                controller.updateSettings(
                  settings.copyWith(browserInspectorSize: value.round()),
                );
              },
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('UI scale: ${settings.uiScalePercent}%'),
              subtitle: const Text(
                'Smaller values fit more controls onscreen. Below 80% also reduces padding and element sizing. 70% is the default.',
              ),
            ),
            Slider(
              min: 60,
              max: 110,
              divisions: 10,
              value: settings.uiScalePercent.toDouble().clamp(60, 110),
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
              value: settings.logTextScalePercent.toDouble().clamp(80, 130),
              label: '${settings.logTextScalePercent}%',
              onChanged: (value) {
                controller.updateSettings(
                  settings.copyWith(logTextScalePercent: value.round()),
                );
              },
            ),
          ],
        ),
        _section(
          context,
          title: 'Safety & Recovery',
          children: [
            _numberField(
              label: 'Safe retries',
              initialValue: settings.safeRetries,
              onSubmitted: (value) => controller
                  .updateSettings(settings.copyWith(safeRetries: value)),
            ),
            const SizedBox(height: 12),
            _numberField(
              label: 'Retry base delay (ms)',
              initialValue: settings.retryBaseDelayMs,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(retryBaseDelayMs: value),
              ),
            ),
            const SizedBox(height: 12),
            _numberField(
              label: 'Retry max delay (ms)',
              initialValue: settings.retryMaxDelayMs,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(retryMaxDelayMs: value),
              ),
            ),
            const SizedBox(height: 12),
            _numberField(
              label: 'Request delay (ms)',
              initialValue: settings.requestDelayMs,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(requestDelayMs: value),
              ),
            ),
            const SizedBox(height: 12),
            phone
                ? Column(
                    children: [
                      _numberField(
                        label: 'Connect timeout (s)',
                        initialValue: settings.connectTimeoutSeconds,
                        onSubmitted: (value) => controller.updateSettings(
                          settings.copyWith(connectTimeoutSeconds: value),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _numberField(
                        label: 'Read timeout (s)',
                        initialValue: settings.readTimeoutSeconds,
                        onSubmitted: (value) => controller.updateSettings(
                          settings.copyWith(readTimeoutSeconds: value),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: _numberField(
                          label: 'Connect timeout (s)',
                          initialValue: settings.connectTimeoutSeconds,
                          onSubmitted: (value) => controller.updateSettings(
                            settings.copyWith(connectTimeoutSeconds: value),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _numberField(
                          label: 'Read timeout (s)',
                          initialValue: settings.readTimeoutSeconds,
                          onSubmitted: (value) => controller.updateSettings(
                            settings.copyWith(readTimeoutSeconds: value),
                          ),
                        ),
                      ),
                    ],
                  ),
            const SizedBox(height: 12),
            _numberField(
              label: 'Max pool connections',
              initialValue: settings.maxPoolConnections,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(maxPoolConnections: value),
              ),
            ),
            const SizedBox(height: 12),
            _numberField(
              label: 'Max requests per second (0 = unlimited)',
              initialValue: settings.maxRequestsPerSecond,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(maxRequestsPerSecond: value),
              ),
            ),
            SwitchListTile(
              value: settings.enableCrashRecovery,
              onChanged: (value) => controller.updateSettings(
                settings.copyWith(enableCrashRecovery: value),
              ),
              title: const Text('Crash isolation and engine restart recovery'),
            ),
          ],
        ),
        _section(
          context,
          title: 'Benchmark',
          children: [
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
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Engine and endpoint selection'),
              subtitle: Text(
                'Benchmark mode always uses the currently selected endpoint profile and backend engine from the app header.',
              ),
            ),
            _numberField(
              label: 'Benchmark data cache (MB)',
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
        ),
        _section(
          context,
          title: 'Diagnostics',
          children: [
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
              initialValue: settings.defaultPresignMinutes,
              onSubmitted: (value) => controller.updateSettings(
                settings.copyWith(defaultPresignMinutes: value),
              ),
            ),
          ],
        ),
        _section(
          context,
          title: 'Version Details',
          children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Application version'),
              subtitle: Text('$kApplicationVersion ($kApplicationBuild)'),
            ),
            const SizedBox(height: 8),
            Text(
              isAndroid ? 'Android app dependencies' : 'Flutter dependencies',
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
                isAndroid ? 'Android engines' : 'Bundled engines',
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
        ),
      ],
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    final phone = MediaQuery.sizeOf(context).width < 700;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        decoration: BoxDecoration(
          color: phone ? theme.colorScheme.surface : theme.cardTheme.color,
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
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionIntro(
    BuildContext context, {
    required String title,
    required String description,
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
        ],
      ),
    );
  }

  Widget _textField({
    required String label,
    required String initialValue,
    required ValueChanged<String> onSubmitted,
  }) {
    return TextFormField(
      initialValue: initialValue,
      decoration: InputDecoration(labelText: label),
      onFieldSubmitted: onSubmitted,
    );
  }

  Widget _numberField({
    required String label,
    required int initialValue,
    required ValueChanged<int> onSubmitted,
  }) {
    return TextFormField(
      initialValue: '$initialValue',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onFieldSubmitted: (value) {
        final parsed = int.tryParse(value);
        if (parsed != null) {
          onSubmitted(parsed);
        }
      },
    );
  }
}

class _ProfileEditorCard extends StatefulWidget {
  const _ProfileEditorCard({
    super.key,
    required this.controller,
    required this.profile,
  });

  final AppController controller;
  final EndpointProfile profile;

  @override
  State<_ProfileEditorCard> createState() => _ProfileEditorCardState();
}

class _ProfileEditorCardState extends State<_ProfileEditorCard> {
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
  late bool _pathStyle;
  late bool _useHttps;
  late bool _verifyTls;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _syncFromProfile();
    _expanded = !_looksConfigured(widget.profile);
  }

  @override
  void didUpdateWidget(covariant _ProfileEditorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) {
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
      _pathStyle = widget.profile.pathStyle;
      _useHttps = endpointUsesHttps(
        widget.profile.endpointUrl,
        fallback: widget.profile.verifyTls,
      );
      _verifyTls = widget.profile.verifyTls;
      _expanded = !_looksConfigured(widget.profile);
    }
  }

  void _syncFromProfile() {
    _nameController = TextEditingController(text: widget.profile.name);
    _endpointController =
        TextEditingController(text: widget.profile.endpointUrl);
    _regionController = TextEditingController(text: widget.profile.region);
    _accessKeyController =
        TextEditingController(text: widget.profile.accessKey);
    _secretKeyController =
        TextEditingController(text: widget.profile.secretKey);
    _sessionTokenController =
        TextEditingController(text: widget.profile.sessionToken ?? '');
    _connectTimeoutController = TextEditingController(
      text: '${widget.profile.connectTimeoutSeconds}',
    );
    _readTimeoutController = TextEditingController(
      text: '${widget.profile.readTimeoutSeconds}',
    );
    _notesController = TextEditingController(text: widget.profile.notes ?? '');
    _endpointType = widget.profile.endpointType;
    _pathStyle = widget.profile.pathStyle;
    _useHttps = endpointUsesHttps(
      widget.profile.endpointUrl,
      fallback: widget.profile.verifyTls,
    );
    _verifyTls = widget.profile.verifyTls;
    _endpointController.addListener(_handleEndpointInputChanged);
  }

  void _syncText(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.text = value;
    }
  }

  void _handleEndpointInputChanged() {
    if (_endpointType != EndpointProfileType.s3Compatible) {
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
        endpointUrl: _endpointType == EndpointProfileType.awsS3
            ? awsEndpointForRegion(_regionController.text)
            : normalizeEndpointUrl(
                _endpointController.text.trim(),
                preferHttps: _useHttps,
              ),
        region: _regionController.text.trim(),
        accessKey: _accessKeyController.text,
        secretKey: _secretKeyController.text,
        sessionToken: _sessionTokenController.text.trim().isEmpty
            ? null
            : _sessionTokenController.text.trim(),
        pathStyle:
            _endpointType == EndpointProfileType.awsS3 ? false : _pathStyle,
        verifyTls: _endpointType == EndpointProfileType.awsS3
            ? true
            : (_useHttps && _verifyTls),
        endpointType: _endpointType,
        connectTimeoutSeconds:
            int.tryParse(_connectTimeoutController.text.trim()) ?? 5,
        readTimeoutSeconds:
            int.tryParse(_readTimeoutController.text.trim()) ?? 60,
        notes: _notesController.text.trim(),
      ),
    );
  }

  bool _looksConfigured(EndpointProfile profile) {
    return profile.name.trim().isNotEmpty &&
        profile.accessKey.trim().isNotEmpty &&
        profile.secretKey.trim().isNotEmpty &&
        (profile.endpointType == EndpointProfileType.awsS3 ||
            profile.endpointUrl.trim().isNotEmpty);
  }

  @override
  void dispose() {
    _endpointController.removeListener(_handleEndpointInputChanged);
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
          initiallyExpanded: _expanded,
          onExpansionChanged: (value) => setState(() => _expanded = value),
          title: Text(
            widget.profile.name.isEmpty
                ? 'Unnamed profile'
                : widget.profile.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle: Text(
            _normalizedEndpointPreview.isEmpty
                ? 'Connection details not configured yet.'
                : _normalizedEndpointPreview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isSelected) const Chip(label: Text('Selected')),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Profile name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<EndpointProfileType>(
              initialValue: _endpointType,
              decoration: const InputDecoration(labelText: 'Endpoint type'),
              items: const [
                DropdownMenuItem(
                  value: EndpointProfileType.s3Compatible,
                  child: Text('S3-compatible'),
                ),
                DropdownMenuItem(
                  value: EndpointProfileType.awsS3,
                  child: Text('AWS S3'),
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
            ] else ...[
              DropdownButtonFormField<String>(
                initialValue:
                    _awsRegionOptions.contains(_regionController.text.trim())
                        ? (_regionController.text.trim().isEmpty
                            ? 'us-east-1'
                            : _regionController.text.trim())
                        : 'us-east-1',
                decoration: const InputDecoration(labelText: 'AWS region'),
                items: _awsRegionOptions
                    .map(
                      (region) => DropdownMenuItem(
                        value: region,
                        child: Text(region),
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
                title: Text(
                  _endpointType == EndpointProfileType.awsS3
                      ? 'AWS endpoint'
                      : 'Normalized endpoint',
                ),
                subtitle: Text(_normalizedEndpointPreview),
              ),
            if (_normalizedEndpointPreview.isNotEmpty)
              const SizedBox(height: 12),
            phone
                ? Column(
                    children: [
                      TextField(
                        controller: _accessKeyController,
                        decoration:
                            const InputDecoration(labelText: 'Access key'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _secretKeyController,
                        obscureText: true,
                        decoration:
                            const InputDecoration(labelText: 'Secret key'),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _accessKeyController,
                          decoration:
                              const InputDecoration(labelText: 'Access key'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _secretKeyController,
                          obscureText: true,
                          decoration:
                              const InputDecoration(labelText: 'Secret key'),
                        ),
                      ),
                    ],
                  ),
            const SizedBox(height: 12),
            TextField(
              controller: _sessionTokenController,
              decoration: const InputDecoration(
                labelText: 'Session token (optional)',
              ),
            ),
            SwitchListTile(
              value: _pathStyle,
              onChanged: _endpointType == EndpointProfileType.s3Compatible
                  ? (value) => setState(() => _pathStyle = value)
                  : null,
              title: const Text('Force path-style requests'),
              subtitle: Text(
                _endpointType == EndpointProfileType.awsS3
                    ? 'AWS S3 uses the standard virtual-hosted endpoint layout.'
                    : 'Useful for MinIO and other S3-compatible endpoints.',
              ),
            ),
            SwitchListTile(
              value: _verifyTls,
              onChanged: (_endpointType == EndpointProfileType.s3Compatible &&
                      _useHttps)
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
                        decoration: const InputDecoration(
                          labelText: 'Connect timeout (s)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _readTimeoutController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
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
                          decoration: const InputDecoration(
                            labelText: 'Connect timeout (s)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _readTimeoutController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Read timeout (s)',
                          ),
                        ),
                      ),
                    ],
                  ),
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
                  onPressed: () async {
                    final profile = _buildProfile();
                    await widget.controller.saveProfile(profile);
                  },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
                OutlinedButton.icon(
                  onPressed: isTesting
                      ? null
                      : () async {
                          final profile = _buildProfile();
                          await widget.controller.saveProfile(profile);
                          await widget.controller.testProfileById(profile.id);
                        },
                  icon: const Icon(Icons.playlist_add_check_circle_outlined),
                  label: Text(isTesting ? 'Testing...' : 'Test'),
                ),
                OutlinedButton.icon(
                  onPressed: isSelecting
                      ? null
                      : () async {
                          final profile = _buildProfile();
                          await widget.controller.saveProfile(profile);
                          await widget.controller
                              .setSelectedProfileById(profile.id);
                        },
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(isSelecting ? 'Loading...' : 'Use profile'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await widget.controller.deleteProfile(widget.profile.id);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
