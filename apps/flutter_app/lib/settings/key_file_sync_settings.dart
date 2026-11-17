import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/key_file_sync.dart';
import '../services/key_file_sync_transport.dart';
import '../widgets/app_form_dialog.dart';
import '../widgets/dialog_controllers.dart';
import '../widgets/app_select_field.dart';
import '../widgets/empty_state.dart';
import '../theme/app_motion.dart';
import '../utils/format.dart';

class KeyFileSyncSettings extends StatefulWidget {
  const KeyFileSyncSettings(
      {super.key, required this.controller, required this.onChangePassphrase});
  final AppController controller;
  final Future<void> Function() onChangePassphrase;
  @override
  State<KeyFileSyncSettings> createState() => _KeyFileSyncSettingsState();
}

class _KeyFileSyncSettingsState extends State<KeyFileSyncSettings> {
  bool _busy = false;
  String? _error;
  AppController get controller => widget.controller;
  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) {
        setState(() => _error = failure is KeyFileSyncException
            ? failure.message
            : 'The sync operation failed. Check access and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _textDialog(String title, String label,
      {String initial = '',
      String submit = 'Continue',
      bool secret = false,
      Future<void> Function(String)? onSave}) async {
    final text = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => DialogControllers(
        controllers: [text],
        child: StatefulBuilder(
          builder: (context, update) => AppFormDialog<String>(
            title: title,
            submitLabel: submit,
            dirty: text.text != initial,
            value: () => secret ? text.text : text.text.trim(),
            onSave: onSave,
            child: TextField(
              controller: text,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => update(() {}),
              decoration: InputDecoration(labelText: label),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _setup() async {
    final store = await controller.ensureEncryptionKeyStore();
    if (!mounted) return;
    if (!store.isUnlocked) {
      throw const KeyFileSyncException('Unlock the key file to set up sync.');
    }
    final bucket = TextEditingController();
    final objectKey = TextEditingController(text: defaultKeyFileSyncObjectKey);
    await showDialog<void>(
      context: context,
      builder: (_) => DialogControllers(
        controllers: [bucket, objectKey],
        child: _SyncSetupDialog(
          controller: controller,
          bucketName: bucket,
          objectKey: objectKey,
          onChangePassphrase: widget.onChangePassphrase,
        ),
      ),
    );
  }

  Future<void> _mismatch() async {
    final sync = controller.keyFileSync;
    if (sync == null) return;
    await _textDialog(
        'Sync bucket passphrase', 'Passphrase (at least 16 characters)',
        secret: true,
        submit: 'Merge and adopt passphrase', onSave: (passphrase) async {
      await sync.syncNow(remotePassphrase: passphrase);
      if (sync.status == KeyFileSyncStatus.passphraseMismatch) {
        throw const KeyFileSyncException('The passphrase is incorrect.');
      }
      if (sync.status == KeyFileSyncStatus.error) {
        throw KeyFileSyncException(sync.statusText);
      }
    });
  }

  Future<void> _versions() async {
    final sync = controller.keyFileSync;
    if (sync == null) return;
    final passphrase = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (_) => DialogControllers(
        controllers: [passphrase],
        child: _SyncVersionsDialog(sync: sync, passphrase: passphrase),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final config = controller.settings.keyFileSync;
        final sync = controller.keyFileSync;
        final unlocked = controller.encryptionKeyStore?.isUnlocked == true;
        final state = sync?.state ?? controller.settings.keyFileSyncState;
        Widget button(String label, Future<void> Function() action,
                {bool enabled = true}) =>
            OutlinedButton(
                onPressed: _busy || !enabled ? null : () => _perform(action),
                child: Text(label));
        final theme = Theme.of(context);
        final failed = sync?.status == KeyFileSyncStatus.error ||
            sync?.status == KeyFileSyncStatus.passphraseMismatch;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            Text('Key file sync', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Optionally sync your encrypted key file through one bucket to merge changes across devices.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'The encrypted key file is stored in that bucket. Anyone who can read the bucket can copy it, so sync requires a passphrase of at least 16 characters.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            MotionSize(
              duration: AppMotion.duration(context,
                  enabled: controller.settings.enableAnimations,
                  milliseconds: 240),
              alignment: Alignment.topCenter,
              curve: Curves.easeOutCubic,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (config == null)
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.sync_disabled),
                      title: Text('Off'),
                    )
                  else ...[
                    Text(
                      '${controller.profiles.where((p) => p.id == config.profileId).firstOrNull?.name ?? 'Missing profile'} / ${config.bucket} / ${config.objectKey}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Semantics(
                      liveRegion: true,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          failed ? Icons.warning_amber_rounded : Icons.sync,
                          color: failed
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        title: Text(sync?.statusText ??
                            'Sync unavailable. Check the profile and its static credentials.'),
                      ),
                    ),
                    if (!unlocked)
                      const Text(
                          'Unlock the key file to sync pending changes.'),
                    Text(
                        'Last synced: ${state.lastSyncedAt == null ? 'never' : formatDateTime(state.lastSyncedAt!.toLocal())}',
                        style: theme.textTheme.bodySmall),
                    Text(
                        'Bucket versioning: ${switch (state.versioningEnabled) {
                          true => 'on',
                          false => 'off',
                          null => 'unknown'
                        }}',
                        style: theme.textTheme.bodySmall),
                    if (state.conditionalWrites == false)
                      Text(
                          'This store does not block simultaneous writes. Changes still merge at the next sync.',
                          style: theme.textTheme.bodySmall),
                  ],
                  if (_error != null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.info_outline,
                          color: theme.colorScheme.onSurfaceVariant),
                      title: Text(_error!),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(
                onPressed: _busy ||
                        !unlocked ||
                        (config != null && sync == null)
                    ? null
                    : () => _perform(
                        config == null ? _setup : () async => sync?.syncNow()),
                child: Text(config == null ? 'Set up sync…' : 'Sync now'),
              ),
              if (config != null) ...[
                if (state.versioningEnabled != true)
                  button('Turn on versioning',
                      () async => sync?.refreshVersioning(enable: true),
                      enabled: unlocked && sync != null),
                button('Earlier versions…', _versions,
                    enabled: unlocked && sync != null),
                if (sync?.status == KeyFileSyncStatus.passphraseMismatch)
                  button('Enter sync passphrase…', _mismatch,
                      enabled: unlocked),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(() async {
                            await controller.turnOffKeyFileSync();
                            if (mounted) {
                              setState(() => _error =
                                  'Sync is off. The encrypted copy remains in the bucket.');
                            }
                          }),
                  child: const Text('Turn off sync'),
                ),
              ],
            ]),
          ],
        );
      });
}

class _SyncSetupDialog extends StatefulWidget {
  const _SyncSetupDialog(
      {required this.controller,
      required this.bucketName,
      required this.objectKey,
      required this.onChangePassphrase});
  final AppController controller;
  final TextEditingController bucketName, objectKey;
  final Future<void> Function() onChangePassphrase;
  @override
  State<_SyncSetupDialog> createState() => _SyncSetupDialogState();
}

class _SyncSetupDialogState extends State<_SyncSetupDialog> {
  EndpointProfile? _profile;
  List<String> _buckets = [];
  String? _bucket, _error;
  bool _loading = false, _creating = false;
  int _generation = 0;
  final Set<KeyFileSyncSetupTransport> _transports = {};

  @override
  void dispose() {
    for (final transport in _transports) {
      transport.close();
    }
    _transports.clear();
    super.dispose();
  }

  Future<void> _load(EndpointProfile profile) async {
    final generation = ++_generation;
    setState(() {
      _profile = profile;
      _bucket = null;
      _buckets = [];
      _error = null;
      _loading = true;
      _creating = false;
    });
    KeyFileSyncSetupTransport? transport;
    try {
      transport = widget.controller.createKeyFileSyncSetupTransport(profile);
      _transports.add(transport);
      final buckets = await transport.buckets();
      if (mounted && generation == _generation) {
        setState(() => _buckets = buckets);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() =>
            _error = 'Could not load buckets. Check access and try again.');
      }
    } finally {
      if (transport != null && _transports.remove(transport)) transport.close();
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() async {
    final profile = _profile!;
    final bucket = _creating ? widget.bucketName.text.trim() : _bucket!;
    if (_creating) {
      final transport =
          widget.controller.createKeyFileSyncSetupTransport(profile);
      try {
        await transport.createBucket(bucket);
      } catch (_) {
        throw const KeyFileSyncException(
            'Could not create the bucket and enable versioning. Check access.');
      } finally {
        transport.close();
      }
      // Retrying a failed configuration must not try to create the bucket again.
      if (mounted) {
        setState(() {
          _buckets = {..._buckets, bucket}.toList();
          _bucket = bucket;
          _creating = false;
        });
      }
    }
    await widget.controller.configureKeyFileSync(KeyFileSyncConfig(
      profileId: profile.id,
      bucket: bucket,
      objectKey: widget.objectKey.text.trim().isEmpty
          ? defaultKeyFileSyncObjectKey
          : widget.objectKey.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final theme = Theme.of(context);
          final policyMet =
              widget.controller.encryptionKeyStore?.passphraseMeetsSyncPolicy ==
                  true;
          final reasons = [
            for (final profile in widget.controller.profiles)
              if (keyFileSyncProfileIneligibility(profile) case final reason?)
                '${profile.name}: $reason',
          ];
          return AppFormDialog<void>(
            title: 'Set up key file sync',
            submitLabel: 'Turn on sync',
            dirty: _profile != null ||
                widget.bucketName.text.isNotEmpty ||
                widget.objectKey.text != defaultKeyFileSyncObjectKey,
            valid: policyMet &&
                _profile != null &&
                !_loading &&
                (_creating
                    ? widget.bucketName.text.trim().isNotEmpty
                    : _bucket != null),
            value: () {},
            onSave: (_) => _save(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!policyMet) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.info_outline,
                        color: theme.colorScheme.onSurfaceVariant),
                    title: const Text('Longer passphrase required'),
                    subtitle: const Text(
                        'Change the key file passphrase to at least 16 characters to turn on sync.'),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                        onPressed: widget.onChangePassphrase,
                        child: const Text('Change passphrase…')),
                  ),
                  const SizedBox(height: 18),
                ],
                AppSelectField<String>(
                  value: _profile?.id,
                  decoration: InputDecoration(
                    labelText: 'Sync profile',
                    helperText: reasons.isEmpty ? null : reasons.join('\n'),
                    helperMaxLines: 100,
                  ),
                  items: [
                    for (final profile in widget.controller.profiles)
                      AppSelectItem(
                          value: profile.id,
                          label: profile.name,
                          enabled:
                              keyFileSyncProfileIneligibility(profile) == null),
                  ],
                  onChanged: policyMet
                      ? (id) {
                          final profile = widget.controller.profiles
                              .where((p) => p.id == id)
                              .firstOrNull;
                          if (profile != null &&
                              keyFileSyncProfileIneligibility(profile) ==
                                  null) {
                            _load(profile);
                          }
                        }
                      : null,
                ),
                const SizedBox(height: 18),
                AppSelectField<String>(
                  value: _bucket,
                  decoration: const InputDecoration(labelText: 'Sync bucket'),
                  items: [
                    for (final bucket in _buckets)
                      AppSelectItem(value: bucket, label: bucket)
                  ],
                  onChanged: _profile == null || _loading
                      ? null
                      : (value) => setState(() {
                            _bucket = value;
                            _creating = false;
                          }),
                ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(
                        semanticsLabel: 'Loading buckets'),
                  ),
                if (_error != null) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.error_outline,
                        color: theme.colorScheme.error),
                    title: Text(_error!),
                  ),
                  Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                          onPressed: () => _load(_profile!),
                          child: const Text('Retry'))),
                ],
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _profile == null || _loading
                        ? null
                        : () => setState(() => _creating = !_creating),
                    icon: Icon(_creating ? Icons.close : Icons.add),
                    label: Text(_creating
                        ? 'Choose existing bucket'
                        : 'Create bucket…'),
                  ),
                ),
                MotionSize(
                  duration: AppMotion.duration(context,
                      enabled: widget.controller.settings.enableAnimations,
                      milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _creating
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 12),
                          child: TextField(
                            controller: widget.bucketName,
                            autocorrect: false,
                            enableSuggestions: false,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                                labelText: 'Bucket name',
                                helperText:
                                    'The bucket is created with versioning on when you turn on sync.',
                                helperMaxLines: 100),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: widget.objectKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'Object key',
                      helperText:
                          'Optional. Leave empty to use the default object key.',
                      helperMaxLines: 100),
                ),
              ],
            ),
          );
        },
      );
}

class _SyncVersionsDialog extends StatefulWidget {
  const _SyncVersionsDialog({required this.sync, required this.passphrase});
  final KeyFileSync sync;
  final TextEditingController passphrase;
  @override
  State<_SyncVersionsDialog> createState() => _SyncVersionsDialogState();
}

class _SyncVersionsDialogState extends State<_SyncVersionsDialog> {
  List<KeyFileSyncVersion>? _versions;
  KeyFileSyncVersion? _selected;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final versions = await widget.sync.earlierVersions();
      if (mounted) setState(() => _versions = versions);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not load earlier versions. Check access and try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppFormDialog<void>(
        title: 'Earlier versions',
        submitLabel: 'Import keys',
        dirty: _selected != null || widget.passphrase.text.isNotEmpty,
        valid: _selected != null && widget.passphrase.text.isNotEmpty,
        value: () {},
        onSave: (_) async {
          try {
            await widget.sync
                .importVersion(_selected!.id, widget.passphrase.text);
          } catch (_) {
            throw const KeyFileSyncException(
                'Could not import this version. Check its passphrase and access.');
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              EmptyState(
                icon: Icons.error_outline,
                title: _error!,
                action:
                    TextButton(onPressed: _load, child: const Text('Retry')),
              )
            else if (_versions == null)
              const LinearProgressIndicator(
                  semanticsLabel: 'Loading earlier versions')
            else if (_versions!.isEmpty)
              const EmptyState(
                icon: Icons.history,
                title: 'No earlier versions are available.',
              )
            else ...[
              const Text(
                  'Keys are merged into your unlocked key file. Existing keys are kept.'),
              const SizedBox(height: 18),
              for (final version in _versions!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  selected: _selected == version,
                  leading: Icon(_selected == version
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
                  title: Text(version.modifiedAt == null
                      ? 'Unknown time'
                      : formatDateTime(version.modifiedAt!.toLocal())),
                  subtitle: Text(
                      '${formatBytes(version.size)} · ${version.id.length > 12 ? '${version.id.substring(0, 12)}…' : version.id}'),
                  onTap: () => setState(() => _selected = version),
                ),
            ],
            const SizedBox(height: 18),
            TextField(
              controller: widget.passphrase,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration:
                  const InputDecoration(labelText: 'Version passphrase'),
            ),
          ],
        ),
      );
}
