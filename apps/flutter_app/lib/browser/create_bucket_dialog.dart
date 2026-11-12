import 'package:flutter/material.dart';

import '../models/domain_models.dart';
import '../widgets/app_form_dialog.dart';
import '../widgets/app_switch.dart';

class CreateBucketDialog extends StatefulWidget {
  const CreateBucketDialog(
      {super.key, required this.provider, required this.onSave});
  final EndpointProfileType provider;
  final Future<void> Function(String name, bool versioning, bool objectLock)
      onSave;

  @override
  State<CreateBucketDialog> createState() => _CreateBucketDialogState();
}

class _CreateBucketDialogState extends State<CreateBucketDialog> {
  final _name = TextEditingController();
  bool _versioning = false, _lock = false;

  String? get _error {
    final name = _name.text.trim();
    if (name.isEmpty) return 'Enter a bucket name.';
    if (widget.provider == EndpointProfileType.awsS3 &&
        (name.length < 3 ||
            name.length > 63 ||
            !RegExp(r'^[a-z0-9][a-z0-9.-]*[a-z0-9]$').hasMatch(name) ||
            name.contains('..') ||
            RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(name) ||
            ['xn--', 'sthree-', 'amzn-s3-demo-'].any(name.startsWith) ||
            ['-s3alias', '--ol-s3', '.mrap', '--x-s3', '--table-s3']
                .any(name.endsWith))) {
      return 'Use 3–63 lowercase letters, digits, dots or hyphens with a letter or digit at each end. Reserved S3 names and IP addresses are not allowed.';
    }
    return null;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppFormDialog<String>(
        title: 'New bucket',
        width: 560,
        submitLabel: 'Create',
        dirty: _name.text.isNotEmpty || _versioning || _lock,
        valid: _error == null,
        value: () => _name.text.trim(),
        onSave: (name) => widget.onSave(name, _versioning || _lock, _lock),
        child: Builder(
            builder: (context) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: _name,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                          labelText: 'Bucket name',
                          errorText: _name.text.isEmpty ? null : _error,
                          errorMaxLines: 4),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => submitAppForm(context)),
                  if (widget.provider != EndpointProfileType.azureBlob) ...[
                    const SizedBox(height: 16),
                    AppSwitchTile(
                        value: _versioning || _lock,
                        onChanged: _lock
                            ? null
                            : (value) => setState(() => _versioning = value),
                        title: const Text('Enable versioning')),
                    AppSwitchTile(
                        value: _lock,
                        onChanged: (value) => setState(() => _lock = value),
                        title: const Text('Enable object lock')),
                    const SizedBox(height: 8),
                    const Text(
                        'Object Lock enables versioning. Availability depends on the storage provider.'),
                  ],
                ])),
      );
}
