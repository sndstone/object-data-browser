import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/bucket_encryption_config.dart';
import '../models/domain_models.dart';
import '../services/encryption_key_store.dart';
import '../settings/client_encryption_editor.dart';
import '../settings/encryption_settings.dart';
import '../theme/app_motion.dart';
import '../widgets/app_form_dialog.dart';
import '../widgets/banner_activity/banner_activity_spec.dart';
import '../widgets/banner_activity/bucket_activity_status.dart';
import '../widgets/app_select_field.dart';
import '../widgets/app_switch.dart';
import '../widgets/copyable_value.dart';
import '../widgets/dialog_controllers.dart';
import 'json_editor_dialog.dart';

Future<void> showBucketEncryptionDialog(
    BuildContext context, AppController controller) async {
  if (controller.selectedBucket == null || controller.selectedProfile == null) {
    return;
  }
  final kms = TextEditingController();
  await showDialog<void>(
      context: context,
      builder: (_) => DialogControllers(
            controllers: [kms],
            child: BucketEncryptionDialog(
                controller: controller, kmsController: kms),
          ));
}

class BucketEncryptionDialog extends StatefulWidget {
  const BucketEncryptionDialog(
      {super.key, required this.controller, required this.kmsController});
  final AppController controller;
  final TextEditingController kmsController;
  @override
  State<BucketEncryptionDialog> createState() => _BucketEncryptionDialogState();
}

class _BucketEncryptionDialogState extends State<BucketEncryptionDialog> {
  AppController get controller => widget.controller;
  late final String _profileId;
  late final String _bucket;
  late final String _engine;
  late String _json;
  late BucketEncryptionConfig _config;
  late String _mode;
  late bool? _bucketKey;
  late List<ClientEncryptionRule> _savedRules;
  late List<ClientEncryptionRule> _rules;
  String? _quickKeyId;
  var _quickPolicy = ClientEncryptionPolicy.standard;
  var _quickEncryptNames = false;

  @override
  void initState() {
    super.initState();
    _profileId = controller.selectedProfile!.id;
    _bucket = controller.selectedBucket!.name;
    _engine = controller.activeEngineId;
    _json = controller.adminState?.bucketName == _bucket
        ? controller.adminState!.encryptionJson
        : '{}';
    _config = BucketEncryptionConfig.parse(_json);
    _mode = _config.mode;
    _bucketKey = _config.bucketKeyEnabled;
    _savedRules = List.of(controller.selectedProfile!.clientEncryptionRules);
    _rules = List.of(_savedRules);
    widget.kmsController.text = _config.kmsKeyId;
  }

  bool get _serverChanged =>
      _config.canEdit &&
      (_mode.isEmpty
          ? _config.hasRule
          : (_mode != _config.mode ||
              widget.kmsController.text.trim() != _config.kmsKeyId ||
              _bucketKey != _config.bucketKeyEnabled));
  bool get _vaultChanged => !listEquals(_rules, _savedRules);
  void _checkTarget() {
    if (controller.selectedProfile?.id != _profileId ||
        controller.selectedBucket?.name != _bucket ||
        controller.activeEngineId != _engine) {
      throw StateError(
          'The target changed. Reopen Bucket encryption for the selected bucket.');
    }
  }

  bool _encryptionReadSucceeded(BucketAdminState? state) {
    final section = state?.sections['GetBucketEncryption'];
    return state?.bucketName == _bucket &&
        section is Map &&
        const {'supported', 'missing', 'available', 'absent'}
            .contains(section['state']);
  }

  Future<void> _checkCurrentConfiguration(String expectedJson) async {
    _checkTarget();
    final before = controller.bucketAdminReads;
    await controller.runFormAction(controller.refreshBucketAdminState);
    _checkTarget();
    final current = controller.adminState;
    if (controller.bucketAdminReads == before ||
        !_encryptionReadSucceeded(current)) {
      throw StateError(
          'The current server encryption configuration could not be read. Try again.');
    }
    // The S3 bucket encryption API has no conditional write. Check as late
    // as possible to reduce the time available for another writer.
    if (current!.encryptionJson != expectedJson) {
      throw StateError(
          'The server encryption configuration changed. Reopen this dialog before saving.');
    }
  }

  Future<void> _save() => controller.runFormAction(() async {
        _checkTarget();
        if (_serverChanged) {
          if (_mode.isEmpty) {
            final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                      scrollable: true,
                      title: const Text('Remove explicit encryption rule?'),
                      content: const SelectableText(
                          'Future uploads will use the provider default. Existing objects keep their encryption. This also removes any other settings in the explicit rule.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Remove rule')),
                      ],
                    ));
            if (confirmed != true) {
              throw StateError('The explicit rule was kept.');
            }
            await _checkCurrentConfiguration(_json);
            if (!mounted) return;
            await controller.runFormAction(controller.deleteBucketEncryption);
          } else {
            final json = _config.encode(
                mode: _mode,
                kmsKeyId: widget.kmsController.text.trim(),
                bucketKeyEnabled: _bucketKey);
            await _checkCurrentConfiguration(_json);
            if (!mounted) return;
            await controller
                .runFormAction(() => controller.saveBucketEncryption(json));
          }
          _json = controller.adminState!.encryptionJson;
          _config = BucketEncryptionConfig.parse(_json);
          _mode = _config.mode;
          _bucketKey = _config.bucketKeyEnabled;
          widget.kmsController.text = _config.kmsKeyId;
        }
        if (_vaultChanged) {
          _checkTarget();
          final current = controller.selectedProfile!;
          if (!listEquals(current.clientEncryptionRules, _savedRules) &&
              !listEquals(current.clientEncryptionRules, _rules)) {
            throw StateError(
                'Vault rules changed elsewhere. Reopen this dialog before saving.');
          }
          final persisted = await controller
              .saveVaultRules(current.copyWith(clientEncryptionRules: _rules));
          if (!persisted) {
            throw StateError(
                'Vault rules are available for this session only: secure profile persistence failed. Save the profile again to recover.');
          }
          _savedRules = List.of(_rules);
        }
      });

  Future<void> _loadServerState() async {
    if (controller.selectedProfile?.id != _profileId ||
        controller.selectedBucket?.name != _bucket) {
      return;
    }
    await controller.refreshBucketAdminState();
    if (!mounted) return;
    setState(() {
      if (!_encryptionReadSucceeded(controller.adminState)) return;
      _json = controller.adminState!.encryptionJson;
      _config = BucketEncryptionConfig.parse(_json);
      _mode = _config.mode;
      _bucketKey = _config.bucketKeyEnabled;
      widget.kmsController.text = _config.kmsKeyId;
    });
  }

  Future<void> _editJson() async {
    final original = _json;
    final result = await showDialog<String>(
        context: context,
        builder: (_) => JsonEditorDialog(
              title: 'Encryption JSON',
              initialValue: original,
              onSave: (value) => controller.runFormAction(() async {
                await _checkCurrentConfiguration(original);
                if (!mounted) return;
                await controller.saveBucketEncryption(value);
              }),
            ));
    if (result != null && mounted) {
      setState(() {
        _json = controller.adminState?.bucketName == _bucket
            ? controller.adminState!.encryptionJson
            : result;
        _config = BucketEncryptionConfig.parse(_json);
        _mode = _config.mode;
        _bucketKey = _config.bucketKeyEnabled;
        widget.kmsController.text = _config.kmsKeyId;
      });
    }
  }

  /// One-step setup for the common case: the whole bucket, one vault key.
  /// The rule is staged here and written by the dialog's Save.
  Widget _quickVaultSetup(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final unlocked = controller.encryptionKeyStore?.isUnlocked == true;
        final keys = controller.encryptionKeys
            .where((key) => key.type == EncryptionKeyType.ageIdentity)
            .toList();
        final selected =
            keys.where((key) => key.id == _quickKeyId).firstOrNull ??
                (keys.length == 1 ? keys.single : null);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (keys.isNotEmpty)
              AppSelectField<String>(
                key: const ValueKey('bucket-vault-key'),
                value: selected?.id,
                decoration: const InputDecoration(labelText: 'Vault key'),
                items: [
                  for (final key in keys)
                    AppSelectItem(value: key.id, label: key.label),
                ],
                onChanged: (value) => setState(() => _quickKeyId = value),
              )
            else
              SelectableText(unlocked
                  ? 'There is no vault key yet. Generate one to encrypt this bucket.'
                  : controller.encryptionKeyFileExists
                      ? 'Unlock the key file to choose a vault key.'
                      : 'Create the key file first; it holds the vault key.'),
            const SizedBox(height: 18),
            VaultProtectionControls(
              keyPrefix: 'bucket-vault',
              policy: _quickPolicy,
              encryptNames: _quickEncryptNames,
              onPolicyChanged: (value) => setState(() => _quickPolicy = value),
              onNamesChanged: (value) =>
                  setState(() => _quickEncryptNames = value),
            ),
            const SizedBox(height: 18),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (!unlocked)
                OutlinedButton(
                  onPressed: () async {
                    await controller.ensureEncryptionKeyStore();
                    if (!context.mounted) return;
                    await showEncryptionKeyFileDialog(context, controller,
                        action: controller.encryptionKeyFileExists
                            ? 'Unlock key file'
                            : 'Create key file');
                  },
                  child: Text(controller.encryptionKeyFileExists
                      ? 'Unlock key file…'
                      : 'Create key file…'),
                )
              else if (keys.isEmpty)
                OutlinedButton(
                  onPressed: () =>
                      showEncryptionKeyDialog(context, controller, vault: true),
                  child: const Text('Generate vault key…'),
                ),
              FilledButton.tonal(
                key: const ValueKey('bucket-vault-enable'),
                onPressed: selected == null
                    ? null
                    : () => setState(() => _rules = [
                          ..._rules,
                          ClientEncryptionRule(
                            bucket: _bucket,
                            prefix: '',
                            keyId: selected.id,
                            recipient: selected.fingerprint,
                            label: selected.label,
                            policy: _quickPolicy,
                            encryptNames: _quickEncryptNames,
                          ),
                        ]),
                child: const Text('Encrypt new uploads to this bucket'),
              ),
            ]),
          ],
        );
      });

  @override
  Widget build(BuildContext context) {
    final profile = controller.selectedProfile;
    final providerAvailable = profile?.endpointType.isAzure != true &&
        profile?.endpointType.isGoogleCloudStorage != true;
    final reportedServerCapability = controller.capabilities
        .where((c) => c.key == 'bucket.encryption')
        .firstOrNull;
    // Only an explicit "unsupported" hides the form. Engines report "unknown"
    // for S3-compatible endpoints until an operation has been tried, and the
    // save itself reports a provider that rejects the call.
    final serverSupported = providerAvailable &&
        controller.profileCapability('bucket.encryption') &&
        reportedServerCapability?.state != CapabilityState.unsupported;
    final serverLoaded = _encryptionReadSucceeded(controller.adminState);
    final vaultSupported = controller.capabilities.any((c) =>
        c.key == 'object.clientEncryption' &&
        c.state == CapabilityState.supported);
    final bucketRules = _rules.where((r) => r.bucket == _bucket).toList();
    final theme = Theme.of(context).textTheme;
    return AppFormDialog<void>(
      title: 'Bucket encryption',
      width: 680,
      value: () {},
      onSave: (_) => _save(),
      savingStatus: _vaultChanged
          ? BucketActivityStatus(
              controller: controller,
              animation: BucketActivityAnimation.boltThrow,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            )
          : null,
      dirty: _serverChanged || _vaultChanged,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CopyableValue(label: 'Bucket', value: _bucket, controller: controller),
        const SizedBox(height: 16),
        Text('Default encryption on the server', style: theme.titleMedium),
        const SizedBox(height: 18),
        if (!serverSupported)
          const SelectableText(
              'Default encryption controls are not available for this provider or engine.')
        else if (!serverLoaded) ...[
          const SelectableText(
              'The current encryption configuration of this bucket has not been loaded, so it cannot be edited safely yet.'),
          const SizedBox(height: 18),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              key: const ValueKey('bucket-encryption-load'),
              onPressed: _loadServerState,
              child: const Text('Load configuration'),
            ),
          ),
        ] else ...[
          if (!_config.canEdit)
            SelectableText(_config.notice!)
          else ...[
            AppSelectField<String>(
              key: const ValueKey('bucket-encryption-mode'),
              value: _mode,
              decoration:
                  const InputDecoration(labelText: 'Server encryption mode'),
              items: const [
                AppSelectItem(
                    value: '', label: 'Provider default (no explicit rule)'),
                AppSelectItem(
                    value: 'AES256',
                    label:
                        'SSE-S3 (AES-256, keys managed by the storage service)'),
                AppSelectItem(
                    value: 'aws:kms', label: 'SSE-KMS (your KMS key)'),
                AppSelectItem(
                    value: 'aws:kms:dsse',
                    label: 'DSSE-KMS (two layers, AWS only)'),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _mode = value;
                    _bucketKey = value == 'aws:kms' ? _bucketKey : null;
                  });
                }
              },
            ),
            MotionSize(
                duration: AppMotion.duration(context,
                    enabled: controller.settings.enableAnimations,
                    milliseconds: 240),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_mode == 'aws:kms' || _mode == 'aws:kms:dsse') ...[
                        const SizedBox(height: 18),
                        TextField(
                            controller: widget.kmsController,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                                labelText: 'KMS key ID or ARN',
                                helperText:
                                    'Optional. Leave empty for the provider-managed key.',
                                helperMaxLines: 4)),
                      ],
                      if (_mode == 'aws:kms') ...[
                        const SizedBox(height: 18),
                        AppSwitchTile(
                            key: const ValueKey('bucket-encryption-bucket-key'),
                            value: _bucketKey == true,
                            title: const Text('Use S3 Bucket Key'),
                            onChanged: (value) =>
                                setState(() => _bucketKey = value)),
                      ],
                    ])),
          ],
          const SizedBox(height: 18),
          TextButton(onPressed: _editJson, child: const Text('Edit as JSON…')),
        ],
        if (vaultSupported) ...[
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 18),
          Text('Vault encryption by this app (client-side)',
              style: theme.titleMedium),
          const SizedBox(height: 18),
          SelectableText(switch (bucketRules.length) {
            0 => 'Off for this bucket.',
            1 when bucketRules.single.prefix.isEmpty =>
              'New uploads to this bucket are encrypted with "${bucketRules.single.label}".',
            1 =>
              'New uploads under "${bucketRules.single.prefix}" are encrypted with "${bucketRules.single.label}".',
            _ =>
              '${bucketRules.length} vault rules cover parts of this bucket.',
          }),
          const SizedBox(height: 18),
          const SelectableText(
              'Back up the key file: nobody can recover the encrypted objects without the key.'),
          const SizedBox(height: 18),
          if (bucketRules.isEmpty) ...[
            _quickVaultSetup(context),
            const SizedBox(height: 18),
          ],
          for (final rule
              in bucketRules.where((rule) => rule.prefix.isEmpty)) ...[
            VaultProtectionControls(
              keyPrefix: 'bucket-vault',
              policy: rule.policy,
              encryptNames: rule.encryptNames,
              onPolicyChanged: (value) => setState(() => _rules = [
                    for (final current in _rules)
                      if (identical(current, rule))
                        current.copyWith(policy: value)
                      else
                        current,
                  ]),
              onNamesChanged: (value) => setState(() => _rules = [
                    for (final current in _rules)
                      if (identical(current, rule))
                        current.copyWith(encryptNames: value)
                      else
                        current,
                  ]),
            ),
            const SizedBox(height: 18),
          ],
          ClientEncryptionEditor(
              controller: controller,
              profileId: _profileId,
              bucketName: _bucket,
              initiallyExpanded: true,
              rules: bucketRules,
              onChanged: (rules) => setState(() => _rules = [
                    ..._rules.where((r) => r.bucket != _bucket),
                    ...rules,
                  ])),
        ],
      ]),
    );
  }
}
