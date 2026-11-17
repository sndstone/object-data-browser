import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/encryption_key_store.dart';
import '../services/crypto/age.dart';
import '../widgets/app_form_dialog.dart';
import '../widgets/app_select_field.dart';
import '../widgets/app_switch.dart';
import '../widgets/copyable_value.dart';
import '../theme/app_motion.dart';
import '../widgets/dialog_controllers.dart';
import 'encryption_settings.dart';

class ClientEncryptionEditor extends StatelessWidget {
  const ClientEncryptionEditor({
    super.key,
    required this.controller,
    required this.rules,
    required this.onChanged,
    this.profileId,
    this.bucketName,
    this.initiallyExpanded = false,
  });
  final AppController controller;
  final String? profileId, bucketName;
  final bool initiallyExpanded;
  final List<ClientEncryptionRule> rules;
  final ValueChanged<List<ClientEncryptionRule>> onChanged;

  Future<void> _edit(BuildContext context, {int? index}) async {
    if (index != null &&
        rules[index].policy == ClientEncryptionPolicy.unsupported) {
      return;
    }
    if (controller.encryptionKeyStore?.isUnlocked != true) {
      await controller.ensureEncryptionKeyStore();
      if (!context.mounted) return;
    }
    final existing = index == null ? null : rules[index];
    final bucket =
        TextEditingController(text: existing?.bucket ?? bucketName ?? '');
    final prefix = TextEditingController(text: existing?.prefix ?? '');
    final keys = controller.encryptionKeys
        .where((k) => k.type == EncryptionKeyType.ageIdentity)
        .toList();
    String? keyId = existing?.keyId;
    var policy = existing?.policy ?? ClientEncryptionPolicy.standard;
    var encryptNames = existing?.encryptNames ?? false;
    final knownBuckets =
        profileId != null && profileId == controller.selectedProfile?.id
            ? controller.buckets.map((b) => b.name).toSet().toList()
            : <String>[];
    var typeBucket = knownBuckets.isEmpty ||
        (bucket.text.isNotEmpty && !knownBuckets.contains(bucket.text));
    void refreshKeys() {
      keys
        ..clear()
        ..addAll(controller.encryptionKeys
            .where((key) => key.type == EncryptionKeyType.ageIdentity));
    }

    final result = await showDialog<ClientEncryptionRule>(
      context: context,
      builder: (_) => DialogControllers(
        controllers: [bucket, prefix],
        child: StatefulBuilder(
          builder: (context, setState) => AppFormDialog<ClientEncryptionRule>(
            title: existing == null ? 'Add vault rule' : 'Edit vault rule',
            submitLabel: 'Save rule',
            dirty: bucket.text != (existing?.bucket ?? bucketName ?? '') ||
                prefix.text != (existing?.prefix ?? '') ||
                keyId != existing?.keyId ||
                policy !=
                    (existing?.policy ?? ClientEncryptionPolicy.standard) ||
                encryptNames != (existing?.encryptNames ?? false),
            value: () {
              final key = keys.where((k) => k.id == keyId).firstOrNull;
              final recipient = key?.fingerprint ?? existing?.recipient;
              if (bucket.text.trim().isEmpty ||
                  keyId == null ||
                  recipient == null ||
                  !isAgeRecipient(recipient)) {
                throw const EncryptionKeyInvalidException(
                  'Choose a bucket and vault key. Unlock the key file to choose a key.',
                );
              }
              // Encrypted names are stored one folder segment at a time, so
              // the location has to be a folder (or the whole bucket).
              if ((encryptNames || policy == ClientEncryptionPolicy.strict) &&
                  prefix.text.isNotEmpty &&
                  !prefix.text.endsWith('/')) {
                throw const EncryptionKeyInvalidException(
                  'Name encryption needs a folder. End the prefix with "/" or leave it empty for the whole bucket.',
                );
              }
              // Two rules for the same place would silently replace each
              // other; the existing one has to be edited instead.
              for (var i = 0; i < rules.length; i++) {
                if (i != index &&
                    rules[i].bucket == bucket.text.trim() &&
                    rules[i].prefix == prefix.text) {
                  throw const EncryptionKeyInvalidException(
                    'A vault rule for this bucket and prefix already exists. Edit that rule instead.',
                  );
                }
              }
              return ClientEncryptionRule(
                bucket: bucket.text.trim(),
                prefix: prefix.text,
                keyId: keyId!,
                recipient: recipient,
                label: key?.label ?? existing!.label,
                policy: policy,
                encryptNames: encryptNames,
              );
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Matching uploads encrypt contents and append .age. The longest matching prefix wins. With names visible, uploads work while the key file is locked.',
                ),
                const SizedBox(height: 18),
                if (bucketName != null)
                  SelectableText('Bucket: $bucketName')
                else ...[
                  if (!typeBucket)
                    AppSelectField<String>(
                      value: knownBuckets.contains(bucket.text)
                          ? bucket.text
                          : null,
                      decoration: const InputDecoration(labelText: 'Bucket'),
                      items: [
                        for (final name in knownBuckets)
                          AppSelectItem(value: name, label: name)
                      ],
                      onChanged: (value) =>
                          setState(() => bucket.text = value ?? ''),
                    )
                  else
                    TextField(
                      controller: bucket,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Bucket'),
                    ),
                  if (knownBuckets.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => typeBucket = !typeBucket),
                      child: Text(typeBucket
                          ? 'Choose a known bucket'
                          : 'Type a name instead'),
                    ),
                ],
                const SizedBox(height: 18),
                TextField(
                  controller: prefix,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Prefix (optional)',
                  ),
                ),
                const SizedBox(height: 18),
                AppSelectField<String>(
                  value: keys.any((k) => k.id == keyId) ? keyId : null,
                  decoration: const InputDecoration(labelText: 'Vault key'),
                  items: [
                    for (final key in keys)
                      AppSelectItem(value: key.id, label: key.label),
                  ],
                  onChanged: keys.isEmpty
                      ? null
                      : (value) => setState(() => keyId = value),
                ),
                const SizedBox(height: 18),
                VaultProtectionControls(
                  policy: policy,
                  encryptNames: encryptNames,
                  onPolicyChanged: (value) => setState(() => policy = value),
                  onNamesChanged: (value) =>
                      setState(() => encryptNames = value),
                ),
                MotionSize(
                  duration: AppMotion.duration(context,
                      enabled: controller.settings.enableAnimations,
                      milliseconds: 240),
                  alignment: Alignment.topCenter,
                  curve: Curves.easeOutCubic,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (keys.where((key) => key.id == keyId).firstOrNull
                          case final key?)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: CopyableValue(
                              label: 'Recipient',
                              value: key.fingerprint,
                              controller: controller,
                              monospace: true,
                              shorten: true),
                        ),
                    ],
                  ),
                ),
                if (controller.encryptionKeyStore?.isUnlocked != true)
                  TextButton(
                    onPressed: () async {
                      await showEncryptionKeyFileDialog(context, controller,
                          action: controller.encryptionKeyFileExists
                              ? 'Unlock key file'
                              : 'Create key file');
                      if (context.mounted) {
                        setState(() {
                          refreshKeys();
                        });
                      }
                    },
                    child: Text(controller.encryptionKeyFileExists
                        ? 'Unlock key file…'
                        : 'Create key file…'),
                  ),
                if (keys.isEmpty &&
                    controller.encryptionKeyStore?.isUnlocked == true)
                  TextButton(
                    onPressed: () async {
                      await showEncryptionKeyDialog(context, controller,
                          vault: true);
                      if (context.mounted) setState(refreshKeys);
                    },
                    child: const Text('Generate vault key…'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result != null) {
      final next = List<ClientEncryptionRule>.of(rules);
      if (index != null) next.removeAt(index);
      final duplicate = next.indexWhere((rule) =>
          rule.bucket == result.bucket && rule.prefix == result.prefix);
      if (duplicate < 0) {
        next.insert(index ?? next.length, result);
      } else {
        next[duplicate] = result;
      }
      onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
        title: const Text('Client-side encryption'),
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        expansionAnimationStyle: AnimationStyle(
          curve: Curves.easeOutCubic,
          duration: AppMotion.duration(context,
              enabled: controller.settings.enableAnimations, milliseconds: 240),
        ),
        subtitle: Text(
          rules.isEmpty
              ? 'Off · no vault rules'
              : '${rules.length} vault rule(s)',
        ),
        children: [
          Text(
              'Optional. Vault rules protect file contents before upload and can also hide names. Sizes, counts and dates remain visible.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 18),
          for (var i = 0; i < rules.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${rules[i].bucket}/${rules[i].prefix}'),
              subtitle: Text(
                  rules[i].policy == ClientEncryptionPolicy.unsupported
                      ? '${rules[i].label} · $unsupportedVaultPolicyNotice'
                      : '${rules[i].label}${vaultProtectionSummary(rules[i])}'),
              onTap: rules[i].policy == ClientEncryptionPolicy.unsupported
                  ? null
                  : () => _edit(context, index: i),
              trailing: IconButton(
                tooltip: 'Remove vault rule',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      scrollable: true,
                      title: const Text('Remove vault rule?'),
                      content: const SelectableText(
                          'Existing .age objects stay encrypted and still need the vault key. Keep your key file backup.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Remove rule')),
                      ],
                    ),
                  );
                  if (confirmed == true) onChanged(List.of(rules)..removeAt(i));
                },
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add),
              label: const Text('Add vault rule'),
            ),
          ),
        ],
      );
}

const unsupportedVaultPolicyNotice =
    'Written by a newer version of the app. Uploads to this location are refused until the app is updated.';

String vaultProtectionSummary(ClientEncryptionRule rule) =>
    rule.policy == ClientEncryptionPolicy.unsupported
        ? ' · unsupported protection'
        : rule.randomNames
            ? ' · strict'
            : rule.encryptsNames
                ? ' · names encrypted'
                : '';

/// Shared controls for rule editing and one-step bucket setup.
class VaultProtectionControls extends StatelessWidget {
  const VaultProtectionControls({
    super.key,
    this.keyPrefix = 'vault',
    required this.policy,
    required this.encryptNames,
    required this.onPolicyChanged,
    required this.onNamesChanged,
  });
  final String keyPrefix;
  final ClientEncryptionPolicy policy;
  final bool encryptNames;
  final ValueChanged<ClientEncryptionPolicy> onPolicyChanged;
  final ValueChanged<bool> onNamesChanged;

  @override
  Widget build(BuildContext context) {
    if (policy == ClientEncryptionPolicy.unsupported) {
      return const Text(unsupportedVaultPolicyNotice);
    }
    final strict = policy == ClientEncryptionPolicy.strict;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSelectField<ClientEncryptionPolicy>(
          key: ValueKey('$keyPrefix-policy'),
          value: policy,
          decoration: const InputDecoration(labelText: 'Protection'),
          items: const [
            AppSelectItem(
                value: ClientEncryptionPolicy.standard, label: 'Default'),
            AppSelectItem(
                value: ClientEncryptionPolicy.strict, label: 'Strict'),
          ],
          onChanged: (value) {
            if (value != null) onPolicyChanged(value);
          },
        ),
        const SizedBox(height: 12),
        Text(
            strict
                ? 'Every upload gets its own random name key. Names and folders are hidden completely, so the bucket shows one flat list of random names.'
                : 'One vault key. File contents are encrypted; folders keep working.',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (strict)
          const Text(
              'Names are always encrypted under Strict. Uploading the same name again keeps both objects.')
        else
          AppSwitchTile(
            key: ValueKey('$keyPrefix-encrypt-names'),
            value: encryptNames,
            title: const Text('Encrypt file and folder names'),
            subtitle: const Text(
                'Each folder and file name is replaced by an encrypted name. The same folder always gets the same encrypted name, so browsing and filtering by folder still work.'),
            onChanged: onNamesChanged,
          ),
        if (strict || encryptNames) ...[
          const SizedBox(height: 12),
          const Text(
              'Uploading and reading names needs the key file unlocked. Object sizes, counts and dates stay visible in the bucket.'),
        ],
        const SizedBox(height: 12),
        const Text(
            'Changes apply to new uploads. Existing objects keep their names.'),
      ],
    );
  }
}
