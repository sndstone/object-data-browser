import 'package:flutter/material.dart';

import '../models/domain_models.dart';
import '../theme/app_motion.dart';
import 'app_select_field.dart';
import 'app_switch.dart';

/// Edits provider configuration only. Credentials are owned by the profile
/// editor and persisted through the consolidated secure credential store.
class ConnectionOptionsEditor extends StatelessWidget {
  const ConnectionOptionsEditor({
    super.key,
    required this.value,
    required this.endpointType,
    required this.onChanged,
    this.enableAnimations = true,
  });

  final bool enableAnimations;
  final ConnectionOptions value;
  final EndpointProfileType endpointType;
  final ValueChanged<ConnectionOptions> onChanged;

  Widget _text(String field, String label, String initial, {String? helper}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextFormField(
          key: ValueKey(field),
          initialValue: initial,
          decoration: InputDecoration(labelText: label, helperText: helper),
          onChanged: (text) => onChanged(value.update(
              field,
              field == 'storageClasses'
                  ? text
                      .split(',')
                      .map((item) => item.trim())
                      .where((item) => item.isNotEmpty)
                      .toList()
                  : text)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final gcs = endpointType.isGoogleCloudStorage;
    final azure = endpointType == EndpointProfileType.azureBlob;
    final modes = azure
        ? const [
            AppSelectItem(value: 'static', label: 'Storage account key'),
            AppSelectItem(
                value: 'azureSas', label: 'Shared access signature (SAS)'),
            AppSelectItem(value: 'azureDefault', label: 'Microsoft Entra ID'),
          ]
        : const [
            AppSelectItem(value: 'static', label: 'Access key and secret key'),
            AppSelectItem(
                value: 'awsProfile', label: 'Named AWS profile / SSO'),
            AppSelectItem(
                value: 'awsDefault', label: 'Default AWS credentials'),
            AppSelectItem(value: 'assumeRole', label: 'Assume AWS role'),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!gcs)
          AppSelectField<String>(
            value: modes.any((mode) => mode.value == value.authMode)
                ? value.authMode
                : 'static',
            items: modes,
            decoration: const InputDecoration(labelText: 'Authentication'),
            onChanged: (mode) {
              if (mode != null) onChanged(value.update('authMode', mode));
            },
          ),
        if (!gcs &&
            (value.authMode == 'awsProfile' || value.authMode == 'assumeRole'))
          _text(
              'awsProfileName',
              value.authMode == 'assumeRole'
                  ? 'Source AWS profile'
                  : 'AWS profile name',
              value.awsProfileName,
              helper:
                  'Optional for a source profile. Use a profile configured on this computer. Complete any SSO sign-in before connecting.'),
        if (!gcs && (value.authMode == 'assumeRole')) ...[
          _text('roleArn', 'Role ARN', value.roleArn),
          _text('externalId', 'External ID', value.externalId,
              helper: 'Optional external ID for the role.'),
          _text('roleSessionName', 'Role session name', value.roleSessionName),
        ],
        if (!gcs && (value.authMode == 'awsDefault'))
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
                'Resolve credentials from this computer’s AWS configuration, environment or assigned role.'),
          ),
        if (!gcs && (value.authMode == 'azureDefault'))
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
                'Use your local Azure sign-in, environment credentials or managed identity. Requires the Python engine with Azure Identity installed.'),
          ),
        const SizedBox(height: 18),
        ExpansionTile(
          title: const Text('Bucket access and endpoint capabilities'),
          tilePadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          expansionAnimationStyle: AnimationStyle(
            curve: Curves.easeOutCubic,
            duration: AppMotion.duration(context,
                enabled: enableAnimations, milliseconds: 240),
          ),
          children: [
            _text('knownBucket', azure ? 'Known container' : 'Known bucket',
                value.knownBucket,
                helper:
                    'Optional. Connect directly when your permissions do not allow listing the entire account.'),
            if (endpointType.isS3) ...[
              AppSwitchTile(
                value: value.requesterPays,
                onChanged: (enabled) =>
                    onChanged(value.update('requesterPays', enabled)),
                title: const Text('Requester Pays'),
                subtitle: const Text(
                    'Authorize request and transfer charges to the requesting account.'),
              ),
              _text('expectedBucketOwner', 'Expected owner',
                  value.expectedBucketOwner,
                  helper:
                      'Optional AWS account ID. Reject requests if the bucket is owned by another AWS account.'),
              _text('storageClasses', 'Storage classes',
                  value.storageClasses.join(', '),
                  helper:
                      'Optional. For compatible endpoints, list verified tier names separated by commas, such as STANDARD_IA, GLACIER.'),
            ],
            _text('caBundlePath', 'Trusted CA bundle', value.caBundlePath,
                helper:
                    'Optional local PEM certificate bundle for a private endpoint.'),
            const SizedBox(height: 18),
          ],
        ),
      ],
    );
  }
}
