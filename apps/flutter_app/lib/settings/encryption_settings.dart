import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/crypto/age.dart';
import '../services/crypto/age_primitives.dart' show ageRandomBytes, ageWipe;
import '../controllers/app_controller.dart';
import 'key_file_sync_settings.dart';
import 'encryption_connection_editor.dart';
import 'encryption_setup_guide.dart';
import '../services/encryption_key_store.dart';
import '../widgets/app_form_dialog.dart';
import '../widgets/copyable_value.dart';
import '../theme/app_motion.dart';
import '../utils/format.dart';

const _lossWarning =
    'Losing the passphrase or the key file loses access to data encrypted with these keys. Keep a backup in a safe place. The passphrase is never saved by the app.';

Future<void> showEncryptionKeyFileDialog(
  BuildContext context,
  AppController controller, {
  String action = 'Unlock key file',
}) async {
  final current = TextEditingController();
  final passphrase = TextEditingController();
  final confirmation = TextEditingController();
  final creating = action == 'Create key file';
  final changing = action == 'Change passphrase';
  var revealPassphrase = false;
  await showDialog<void>(
    context: context,
    builder: (_) => _SecretDialogControllers(
      controllers: [current, passphrase, confirmation],
      child: StatefulBuilder(
        builder: (context, update) => AppFormDialog<void>(
          title: action,
          dirty: current.text.isNotEmpty ||
              passphrase.text.isNotEmpty ||
              confirmation.text.isNotEmpty,
          submitLabel: creating
              ? 'Create'
              : changing
                  ? 'Change passphrase'
                  : 'Unlock',
          value: () {},
          onSave: (_) async {
            if ((creating || changing) &&
                passphrase.text != confirmation.text) {
              throw const EncryptionKeyInvalidException(
                'The passphrases do not match.',
              );
            }
            await controller.updateEncryptionKeys((store) async {
              if (creating) {
                await store.create(passphrase.text);
              } else if (changing) {
                await store.changePassphrase(current.text, passphrase.text);
              } else {
                await store.unlock(passphrase.text);
              }
            });
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (creating || changing)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(_lossWarning),
                ),
              if (changing)
                _secretField(current, 'Current passphrase',
                    onChanged: (_) => update(() {})),
              _secretField(
                passphrase,
                creating || changing
                    ? 'New passphrase (at least 12 characters)'
                    : 'Passphrase',
                visible: revealPassphrase,
                onToggle: () =>
                    update(() => revealPassphrase = !revealPassphrase),
                onChanged: (_) => update(() {}),
              ),
              if (creating || changing)
                _secretField(confirmation, 'Confirm passphrase',
                    visible: revealPassphrase, onChanged: (_) => update(() {})),
              if (creating || changing) ...[
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(
                    onPressed: () => update(() {
                      const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
                      final bytes = ageRandomBytes(25);
                      try {
                        // The 32-character alphabet uses exactly five bits per character.
                        final chars = [
                          for (final byte in bytes) alphabet[byte & 31]
                        ];
                        passphrase.text = [
                          for (var i = 0; i < 25; i += 5)
                            chars.sublist(i, i + 5).join(),
                        ].join('-');
                        confirmation.text = passphrase.text;
                        revealPassphrase = true;
                      } finally {
                        ageWipe(bytes);
                      }
                    }),
                    child: const Text('Generate passphrase'),
                  ),
                  TextButton(
                    onPressed: passphrase.text.isEmpty
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(text: passphrase.text)),
                    child: const Text('Copy'),
                  ),
                ]),
                const Text(
                    'Write this down or store it in a password manager. It cannot be recovered.'),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> showEncryptionKeyDialog(
  BuildContext context,
  AppController controller, {
  EncryptionKeyRecord? record,
  bool importing = false,
  bool deleting = false,
  bool vault = false,
}) async {
  final label = TextEditingController(
    text: deleting ? '' : record?.label ?? '',
  );
  final secret = TextEditingController();
  var revealSecret = false;
  final generating = record == null && !importing && !deleting;
  final title = deleting
      ? 'Delete key'
      : record != null
          ? 'Rename key'
          : importing
              ? (vault ? 'Import vault key' : 'Import customer key')
              : (vault ? 'Generate vault key' : 'Generate customer key');
  await showDialog<void>(
    context: context,
    builder: (_) => _SecretDialogControllers(
      controllers: [label, secret],
      child: StatefulBuilder(
        builder: (context, update) => AppFormDialog<void>(
          title: title,
          destructive: deleting,
          dirty: label.text != (deleting ? '' : record?.label ?? '') ||
              secret.text.isNotEmpty,
          submitLabel: deleting
              ? 'Delete key'
              : record != null
                  ? 'Rename'
                  : importing
                      ? 'Import key'
                      : 'Generate key',
          value: () {},
          onSave: (_) async {
            Uint8List? bytes;
            final secretValue = secret.text.trim();
            if (record == null && !deleting && secretValue.isEmpty) {
              throw const EncryptionKeyInvalidException(
                  'Wait for a key to be generated or enter a key.');
            }
            if (record == null && !deleting && !vault) {
              final value = secretValue;
              try {
                bytes = RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value)
                    ? Uint8List.fromList([
                        for (var i = 0; i < value.length; i += 2)
                          int.parse(value.substring(i, i + 2), radix: 16),
                      ])
                    : base64Decode(value);
                if (bytes.length != 32) throw const FormatException();
              } catch (_) {
                ageWipe(bytes);
                throw const EncryptionKeyInvalidException(
                  'Enter a base64 or hex encoded 32-byte key.',
                );
              }
            }
            try {
              await controller.updateEncryptionKeys((store) async {
                if (deleting) {
                  if (label.text != record!.label) {
                    throw const EncryptionKeyInvalidException(
                      'Type the key name exactly to confirm deletion.',
                    );
                  }
                  await store.delete(record.id);
                } else if (record != null) {
                  await store.rename(record.id, label.text);
                } else if (vault) {
                  await store.importAgeIdentity(label.text, secretValue);
                } else {
                  await store.importCustomerKey(label.text, bytes!);
                }
              });
            } finally {
              bytes?.fillRange(0, bytes.length, 0);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (vault && record == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Client-side encryption protects file contents before upload. Name encryption is optional. Sizes, counts, timestamps and deletion remain visible. Losing the key file or its passphrase means the data cannot be recovered. Objects can also be decrypted outside this app with the standard age tool and the vault key.',
                  ),
                ),
              if (deleting)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Objects encrypted with this key become unreadable if you have no backup. Type "${record!.label}" to delete it.',
                  ),
                ),
              TextField(
                controller: label,
                onChanged: (_) => update(() {}),
                decoration: InputDecoration(
                  labelText: deleting ? 'Type the key name' : 'Key label',
                ),
              ),
              if (generating)
                _GeneratedKeyField(controller: secret, vault: vault),
              if (importing)
                _secretField(
                  secret,
                  vault
                      ? 'Vault identity (AGE-SECRET-KEY-1…)'
                      : 'Customer key (base64 or hex)',
                  visible: revealSecret,
                  onToggle: () => update(() => revealSecret = !revealSecret),
                  onChanged: (_) => update(() {}),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _secretField(TextEditingController controller, String label,
        {ValueChanged<String>? onChanged,
        bool visible = false,
        VoidCallback? onToggle}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        obscureText: !visible,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        decoration: InputDecoration(
          label: Text(label),
          suffixIcon: onToggle == null
              ? null
              : IconButton(
                  tooltip: visible ? 'Hide secret' : 'Show secret',
                  onPressed: onToggle,
                  icon: Icon(visible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                ),
        ),
      ),
    );

// Secrets are cleared with the route after the closing transition, while
// controllers are still valid for the fields that are being unmounted.
class _SecretDialogControllers extends StatefulWidget {
  const _SecretDialogControllers(
      {required this.controllers, required this.child});
  final List<TextEditingController> controllers;
  final Widget child;
  @override
  State<_SecretDialogControllers> createState() =>
      _SecretDialogControllersState();
}

class _SecretDialogControllersState extends State<_SecretDialogControllers> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _GeneratedKeyField extends StatefulWidget {
  const _GeneratedKeyField({required this.controller, required this.vault});
  final TextEditingController controller;
  final bool vault;
  @override
  State<_GeneratedKeyField> createState() => _GeneratedKeyFieldState();
}

class _GeneratedKeyFieldState extends State<_GeneratedKeyField> {
  bool _busy = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    widget.controller.clear();
    try {
      String value;
      if (widget.vault) {
        value = (await AgeIdentity.generate()).secretKey;
      } else {
        final bytes = ageRandomBytes(EncryptionKeyStore.customerKeyLength);
        try {
          value = base64Encode(bytes);
        } finally {
          ageWipe(bytes);
        }
      }
      if (mounted) widget.controller.text = value;
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('generated-encryption-key'),
            controller: widget.controller,
            readOnly: true,
            maxLines: null,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontFamily: 'monospace'),
            decoration: const InputDecoration(labelText: 'Key'),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            TextButton(
              onPressed: _busy || _failed
                  ? null
                  : () => Clipboard.setData(
                      ClipboardData(text: widget.controller.text)),
              child: const Text('Copy'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _generate,
              child: const Text('Generate another'),
            ),
          ]),
          const SizedBox(height: 8),
          const Text(
              'Shown once. It is stored only in your encrypted key file.'),
          if (_busy) const Text('Generating key…'),
          if (_failed) const Text('Key generation failed. Please try again.'),
        ],
      );
}

/// Key file operations are deliberate user actions; mounting this widget only
/// checks whether the encrypted file exists and never creates or unlocks it.
class EncryptionSettings extends StatefulWidget {
  const EncryptionSettings({super.key, required this.controller});
  final AppController controller;
  @override
  State<EncryptionSettings> createState() => _EncryptionSettingsState();
}

class _EncryptionSettingsState extends State<EncryptionSettings> {
  String? _error;
  bool _busy = false;
  AppController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _perform(() async {
      await controller.ensureEncryptionKeyStore();
    });
  }

  Future<void> _perform(Future<void> Function() run) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await run();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is EncryptionKeyStoreException
              ? error.message
              : 'The key file operation failed. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _keyDialog({
    EncryptionKeyRecord? record,
    bool importing = false,
    bool deleting = false,
    bool vault = false,
  }) =>
      showEncryptionKeyDialog(context, controller,
          record: record,
          importing: importing,
          deleting: deleting,
          vault: vault);

  Future<void> _backup() async {
    final store = await controller.ensureEncryptionKeyStore();
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Back up key file',
      fileName: 'encryption-keys.age',
      bytes: await store.file.readAsBytes(),
    );
    if (path != null && File(path).absolute.path != store.file.absolute.path) {
      await store.exportTo(File(path));
    }
  }

  Future<void> _importFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import keys from file',
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    final passphrase = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (_) => _SecretDialogControllers(
        controllers: [passphrase],
        child: StatefulBuilder(
          builder: (context, update) => AppFormDialog<void>(
            title: 'Import keys from file',
            dirty: passphrase.text.isNotEmpty,
            submitLabel: 'Merge keys',
            value: () {},
            onSave: (_) => controller.updateEncryptionKeys((store) async {
              await store.importFrom(File(path), passphrase.text);
            }),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Keys are merged into your unlocked key file. Existing keys are kept.',
                ),
                _secretField(passphrase, 'Import file passphrase',
                    onChanged: (_) => update(() {})),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final store = controller.encryptionKeyStore;
          final unlocked = store?.isUnlocked == true;
          final exists = controller.encryptionKeyFileExists;
          Widget button(
            String label,
            Future<void> Function() run, {
            bool enabled = true,
            bool primary = false,
          }) {
            final action = _busy || !enabled ? null : () => _perform(run);
            return primary
                ? FilledButton(onPressed: action, child: Text(label))
                : OutlinedButton(onPressed: action, child: Text(label));
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Keys for optional encryption live in one passphrase-protected key file. Each profile chooses how its uploads are encrypted; until you choose, nothing changes.',
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    unlocked ? Icons.lock_open_outlined : Icons.lock_outline,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                title: Text(
                  'Key file: ${unlocked ? 'unlocked' : exists ? 'locked' : 'none'}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!exists)
                    button(
                      'Create key file…',
                      () => showEncryptionKeyFileDialog(
                        context,
                        controller,
                        action: 'Create key file',
                      ),
                      primary: true,
                    ),
                  if (exists && !unlocked)
                    button(
                      'Unlock key file…',
                      () => showEncryptionKeyFileDialog(context, controller),
                      primary: true,
                    ),
                  if (unlocked)
                    button(
                      'Lock key file',
                      () async => controller.lockEncryptionKeyFile(),
                    ),
                  if (unlocked)
                    button(
                      'Change passphrase…',
                      () => showEncryptionKeyFileDialog(
                        context,
                        controller,
                        action: 'Change passphrase',
                      ),
                    ),
                  button('Back up key file…', _backup, enabled: exists),
                  button('Import keys from file…', _importFile,
                      enabled: unlocked),
                ],
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
                    if (unlocked) ...[
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      Text('Keys',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        'Vault keys encrypt files before upload. Customer keys are sent to the provider with each request (SSE-C and Azure customer-provided keys).',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          button('Generate vault key…',
                              () => _keyDialog(vault: true),
                              primary: true),
                          button(
                            'Import vault key…',
                            () => _keyDialog(vault: true, importing: true),
                          ),
                          button('Generate customer key…', () => _keyDialog()),
                          button(
                            'Import customer key…',
                            () => _keyDialog(importing: true),
                          ),
                        ],
                      ),
                      for (final key in controller.encryptionKeys)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                key.label,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                '${key.type == EncryptionKeyType.customerKey ? 'Customer key' : 'Vault key'} · Created ${formatDateTime(key.createdAt.toLocal())}',
                              ),
                              CopyableValue(
                                label: key.type == EncryptionKeyType.ageIdentity
                                    ? 'Recipient'
                                    : 'Fingerprint',
                                value: key.fingerprint,
                                controller: controller,
                                monospace: true,
                                shorten: true,
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  Tooltip(
                                    message: 'Rename ${key.label}',
                                    child: button(
                                      'Rename',
                                      () => _keyDialog(record: key),
                                    ),
                                  ),
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                        foregroundColor: Theme.of(context)
                                            .colorScheme
                                            .error),
                                    onPressed: _busy
                                        ? null
                                        : () => _perform(() => _keyDialog(
                                            record: key, deleting: true)),
                                    icon: const Icon(Icons.delete_outline),
                                    label: Tooltip(
                                        message: 'Delete ${key.label}',
                                        child: const Text('Delete')),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              EncryptionByConnection(controller: controller),
              KeyFileSyncSettings(
                  controller: controller,
                  onChangePassphrase: () => showEncryptionKeyFileDialog(
                      context, controller,
                      action: 'Change passphrase')),
              EncryptionSetupGuide(controller: controller),
              if (_error != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.error_outline,
                      color: Theme.of(context).colorScheme.error),
                  title: Text(_error!),
                ),
            ],
          );
        },
      );
}
