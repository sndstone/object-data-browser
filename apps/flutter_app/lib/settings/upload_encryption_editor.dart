import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/encryption_key_store.dart';
import '../services/object_encryption.dart';
import '../theme/app_motion.dart';
import '../widgets/dialog_controllers.dart';
import '../widgets/app_form_dialog.dart';
import '../widgets/copyable_value.dart';
import '../widgets/app_select_field.dart';
import '../widgets/app_switch.dart';
import 'encryption_settings.dart';

class UploadEncryptionEditor extends StatefulWidget {
  const UploadEncryptionEditor({
    super.key,
    required this.controller,
    required this.profile,
    required this.value,
    required this.onChanged,
    this.initiallyExpanded = false,
  });
  final AppController controller;
  final bool initiallyExpanded;
  final EndpointProfile profile;
  final ObjectEncryption? value;
  final ValueChanged<ObjectEncryption?> onChanged;
  @override
  State<UploadEncryptionEditor> createState() => _UploadEncryptionEditorState();
}

class _UploadEncryptionEditorState extends State<UploadEncryptionEditor> {
  late final TextEditingController _kms = TextEditingController(
    text: widget.value?.kmsKeyId ?? '',
  );
  late final TextEditingController _scope = TextEditingController(
    text: widget.value?.encryptionScope ?? '',
  );
  late final Map<String, String> _context = {
    ...?widget.value?.kmsEncryptionContext,
  };
  ObjectEncryptionMode get _mode {
    final mode = widget.value?.mode ?? ObjectEncryptionMode.bucketDefault;
    return mode != ObjectEncryptionMode.bucketDefault &&
            mode.isAzure != widget.profile.endpointType.isAzure
        ? ObjectEncryptionMode.bucketDefault
        : mode;
  }

  @override
  void didUpdateWidget(covariant UploadEncryptionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    final kms = widget.value?.kmsKeyId ?? '';
    final scope = widget.value?.encryptionScope ?? '';
    if (_kms.text.trim() != kms) _kms.text = kms;
    if (_scope.text.trim() != scope) _scope.text = scope;
    _context
      ..clear()
      ..addAll(widget.value?.kmsEncryptionContext ?? {});
  }

  @override
  void dispose() {
    _kms.dispose();
    _scope.dispose();
    super.dispose();
  }

  void _publish({
    ObjectEncryptionMode? mode,
    bool? bucketKey,
    EncryptionKeyRecord? key,
  }) {
    final chosen = mode ?? _mode;
    final kms = chosen == ObjectEncryptionMode.sseKms ||
        chosen == ObjectEncryptionMode.dsseKms;
    widget.onChanged(
      chosen == ObjectEncryptionMode.bucketDefault
          ? null
          : ObjectEncryption(
              mode: chosen,
              kmsKeyId:
                  kms && _kms.text.trim().isNotEmpty ? _kms.text.trim() : null,
              kmsEncryptionContext:
                  kms && _context.isNotEmpty ? Map.of(_context) : null,
              bucketKeyEnabled: chosen == ObjectEncryptionMode.sseKms
                  ? bucketKey ?? widget.value?.bucketKeyEnabled
                  : null,
              encryptionScope: chosen == ObjectEncryptionMode.azureScope
                  ? _scope.text.trim()
                  : null,
              customerKeyId: chosen.isCustomerKey
                  ? key?.id ?? widget.value?.customerKeyId
                  : null,
              customerKeyFingerprint: chosen.isCustomerKey
                  ? key?.fingerprint ?? widget.value?.customerKeyFingerprint
                  : null,
            ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final customerAllowed = customerKeyEndpointAllowed(widget.profile);
          final keys = widget.controller.encryptionKeys
              .where((key) => key.type == EncryptionKeyType.customerKey)
              .toList();
          final modes = ObjectEncryptionMode.values
              .where(
                (mode) =>
                    mode == ObjectEncryptionMode.bucketDefault ||
                    mode.isAzure == widget.profile.endpointType.isAzure,
              )
              .toList();
          return ExpansionTile(
            title: const Text('Upload encryption'),
            subtitle: Text(_mode.label),
            tilePadding: EdgeInsets.zero,
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            initiallyExpanded: widget.initiallyExpanded,
            expansionAnimationStyle: AnimationStyle(
              curve: Curves.easeOutCubic,
              duration: AppMotion.duration(
                context,
                enabled: widget.controller.settings.enableAnimations,
                milliseconds: 240,
              ),
            ),
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Optional. Bucket default sends no encryption headers. These settings apply only to new uploads and folder markers.',
                  ),
                  const SizedBox(height: 18),
                  AppSelectField<ObjectEncryptionMode>(
                    value: modes.contains(_mode)
                        ? _mode
                        : ObjectEncryptionMode.bucketDefault,
                    decoration: const InputDecoration(
                      labelText: 'Upload encryption mode',
                    ),
                    items: [
                      for (final mode in modes)
                        AppSelectItem(
                          value: mode,
                          label: mode.label,
                          enabled: !mode.isCustomerKey || customerAllowed,
                        ),
                    ],
                    onChanged: (mode) {
                      if (mode != null) _publish(mode: mode);
                    },
                  ),
                  if (!customerAllowed)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Customer keys require an HTTPS endpoint (loopback endpoints are allowed for local testing).',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  MotionSize(
                    duration: AppMotion.duration(context,
                        enabled: widget.controller.settings.enableAnimations,
                        milliseconds: 240),
                    alignment: Alignment.topCenter,
                    curve: Curves.easeOutCubic,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_mode == ObjectEncryptionMode.sseKms ||
                            _mode == ObjectEncryptionMode.dsseKms) ...[
                          const SizedBox(height: 18),
                          TextField(
                            controller: _kms,
                            decoration: const InputDecoration(
                              labelText: 'KMS key ID or ARN (optional)',
                            ),
                            onChanged: (_) => _publish(),
                          ),
                          for (final pair in _context.entries)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(pair.key),
                              subtitle: Text(pair.value),
                              trailing: IconButton(
                                tooltip: 'Remove context ${pair.key}',
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () {
                                  setState(() => _context.remove(pair.key));
                                  _publish();
                                },
                              ),
                            ),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: TextButton(
                              onPressed: _addContext,
                              child: const Text('Add encryption context pair'),
                            ),
                          ),
                          if (_mode == ObjectEncryptionMode.sseKms)
                            AppSwitchTile(
                              title: const Text('Use S3 bucket key'),
                              value: widget.value?.bucketKeyEnabled ?? false,
                              onChanged: (value) => _publish(bucketKey: value),
                            ),
                        ],
                        if (_mode == ObjectEncryptionMode.azureScope)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: TextField(
                              controller: _scope,
                              decoration: const InputDecoration(
                                labelText: 'Encryption scope name',
                              ),
                              onChanged: (_) => _publish(),
                            ),
                          ),
                        if (_mode.isCustomerKey) ...[
                          const SizedBox(height: 18),
                          if (widget
                                  .controller.encryptionKeyStore?.isUnlocked !=
                              true)
                            TextButton(
                              onPressed: () async {
                                await widget.controller
                                    .ensureEncryptionKeyStore();
                                if (context.mounted) {
                                  await showEncryptionKeyFileDialog(
                                    context,
                                    widget.controller,
                                    action: widget
                                            .controller.encryptionKeyFileExists
                                        ? 'Unlock key file'
                                        : 'Create key file',
                                  );
                                }
                              },
                              child: const Text('Unlock key file…'),
                            ),
                          AppSelectField<String>(
                            value: keys.any((key) =>
                                    key.id == widget.value?.customerKeyId)
                                ? widget.value?.customerKeyId
                                : null,
                            decoration: const InputDecoration(
                                labelText: 'Customer key'),
                            items: [
                              for (final key in keys)
                                AppSelectItem(value: key.id, label: key.label),
                            ],
                            onChanged: keys.isEmpty || !customerAllowed
                                ? null
                                : (id) => _publish(
                                      key: keys
                                          .firstWhere((key) => key.id == id),
                                    ),
                          ),
                          if (widget.value?.customerKeyFingerprint != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: CopyableValue(
                                label: 'Fingerprint',
                                value: widget.value!.customerKeyFingerprint!,
                                controller: widget.controller,
                                monospace: true,
                                shorten: true,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );

  Future<void> _addContext() async {
    final key = TextEditingController(), value = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => DialogControllers(
        controllers: [key, value],
        child: StatefulBuilder(
          builder: (context, update) => AppFormDialog<void>(
            title: 'Encryption context',
            submitLabel: 'Add',
            dirty: key.text.isNotEmpty || value.text.isNotEmpty,
            value: () {},
            onSave: (_) async {
              if (key.text.trim().isEmpty) {
                throw const EncryptionKeyInvalidException(
                    'Enter a context key.');
              }
              if (!mounted) return;
              setState(() => _context[key.text.trim()] = value.text);
              _publish();
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: key,
                  onChanged: (_) => update(() {}),
                  decoration: const InputDecoration(labelText: 'Context key'),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: value,
                  onChanged: (_) => update(() {}),
                  decoration: const InputDecoration(labelText: 'Context value'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
