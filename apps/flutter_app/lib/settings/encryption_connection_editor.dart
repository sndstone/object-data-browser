import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/object_encryption.dart';
import '../widgets/app_form_dialog.dart';
import 'client_encryption_editor.dart';
import 'upload_encryption_editor.dart';

/// Edits only encryption metadata. Saving is an explicit profile Save, including
/// the controller's secure-persistence recovery boundary; opening does no I/O.
Future<void> showConnectionEncryptionDialog(BuildContext context,
    AppController controller, EndpointProfile profile) async {
  var upload = profile.uploadEncryption;
  var rules = List<ClientEncryptionRule>.of(profile.clientEncryptionRules);
  await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
            builder: (context, update) => AppFormDialog<void>(
              title: 'Encryption by connection',
              width: 680,
              dirty: upload != profile.uploadEncryption ||
                  !listEquals(rules, profile.clientEncryptionRules),
              value: () {},
              onSave: (_) async {
                final current = controller.profiles
                    .where((p) => p.id == profile.id)
                    .firstOrNull;
                if (current == null ||
                    (current.uploadEncryption != profile.uploadEncryption &&
                        current.uploadEncryption != upload) ||
                    (!listEquals(current.clientEncryptionRules,
                            profile.clientEncryptionRules) &&
                        !listEquals(current.clientEncryptionRules, rules))) {
                  throw StateError(
                      'This connection changed elsewhere. Reopen its encryption editor.');
                }
                final value = upload;
                if (value != null) {
                  if (value.mode.isCustomerKey &&
                      (!customerKeyEndpointAllowed(current) ||
                          value.customerKeyId == null)) {
                    throw StateError(
                        'Choose a customer key and use an HTTPS endpoint.');
                  }
                  if (value.mode == ObjectEncryptionMode.azureScope &&
                      (value.encryptionScope?.trim().isEmpty ?? true)) {
                    throw StateError('Enter an encryption scope.');
                  }
                }
                if (upload == current.uploadEncryption &&
                    listEquals(rules, current.clientEncryptionRules) &&
                    controller.persistenceState.profileSaved(current.id) !=
                        false) {
                  return;
                }
                if (!await controller.saveProfile(current.copyWith(
                    uploadEncryption: upload, clientEncryptionRules: rules))) {
                  throw StateError(
                      'Changes are available for this session only: secure profile persistence failed. Save the profile again to recover.');
                }
              },
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(profile.name,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 18),
                    if (!profile.endpointType.isGoogleCloudStorage)
                      UploadEncryptionEditor(
                          controller: controller,
                          profile: profile,
                          initiallyExpanded: true,
                          value: upload,
                          onChanged: (value) => update(() => upload = value)),
                    const SizedBox(height: 18),
                    ClientEncryptionEditor(
                        controller: controller,
                        profileId: profile.id,
                        initiallyExpanded: true,
                        rules: rules,
                        onChanged: (value) => update(() => rules = value)),
                    const SizedBox(height: 18),
                    const SelectableText(
                        'Back up the key file; encrypted objects cannot be recovered without the key.'),
                  ]),
            ),
          ));
}

class EncryptionByConnection extends StatelessWidget {
  const EncryptionByConnection({super.key, required this.controller});
  final AppController controller;

  static String _summary(EndpointProfile profile) {
    final rules = profile.clientEncryptionRules.length;
    final uploads = profile.endpointType.isGoogleCloudStorage
        ? 'Uploads: provider default'
        : 'Uploads: ${profile.uploadEncryption?.mode.label ?? 'Bucket default'}';
    final vault = rules == 0
        ? 'Vault: off'
        : 'Vault: $rules ${rules == 1 ? 'rule' : 'rules'}';
    final modes = profile.clientEncryptionRules
        .map(vaultProtectionSummary)
        .where((mode) => mode.isNotEmpty)
        .toSet()
        .join();
    return '$uploads · $vault$modes';
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 18),
          Text('Encryption by connection',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 18),
          if (controller.profiles.isEmpty)
            const SelectableText(
                'Add a connection in Settings → Connections to configure upload encryption and vault rules.'),
          for (final profile in controller.profiles)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(profile.name,
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(_summary(profile),
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                      onPressed: () => showConnectionEncryptionDialog(
                          context, controller, profile),
                      child: const Text('Edit…')),
                ],
              ),
            ),
        ],
      );
}
