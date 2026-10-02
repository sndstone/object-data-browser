import 'dart:convert';
import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../models/storage_presets.dart';
import '../services/diagnostic_safety.dart';

class StoragePresetDialog extends StatefulWidget {
  const StoragePresetDialog(
      {super.key, required this.controller, required this.lifecycle});
  final AppController controller;
  final bool lifecycle;
  @override
  State<StoragePresetDialog> createState() => _StoragePresetDialogState();
}

class _StoragePresetDialogState extends State<StoragePresetDialog> {
  late final profile = widget.controller.selectedProfile!;
  late final bucket = widget.controller.selectedBucket!;
  late String preset = widget.lifecycle ? 'multipart' : 'read';
  final principal = TextEditingController();
  final prefix = TextEditingController();
  final days = TextEditingController(text: '30');
  final filterTags = TextEditingController();
  final minimumBytes = TextEditingController(),
      maximumBytes = TextEditingController();
  final expiration = TextEditingController();
  final transitionAge = TextEditingController(text: '30'),
      archiveAge = TextEditingController(text: '90');
  final historyAge = TextEditingController(text: '90'),
      retained = TextEditingController(text: '5'),
      abortAge = TextEditingController(text: '7');
  bool enabled = true;
  String storageClass = '', existing = '{}';
  String? minimumSize, error;
  Map<String, Object?> access = {};
  bool loading = true, saving = false, confirmed = false;
  bool versioned = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.controller.storageAction(
          widget.lifecycle ? 'getBucketAdminState' : 'getAccess',
          profile: profile,
          arguments: {'bucketName': bucket.name});
      if (!mounted) return;
      setState(() {
        access = result;
        existing = result[widget.lifecycle ? 'lifecycleJson' : 'policyJson']
                as String? ??
            (widget.lifecycle ? '{"Rules":[]}' : '{}');
        minimumSize = result['transitionDefaultMinimumObjectSize'] as String?;
        versioned =
            {'Enabled', 'Suspended'}.contains(result['versioningStatus']);
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = DiagnosticSafety.text('$e');
          loading = false;
        });
      }
    }
  }

  String? _readError(String operation) {
    final sections = access['sections'];
    final section = sections is Map
        ? sections[operation]
        : sections is List
            ? sections
                .cast<Map>()
                .where((s) => s['operation'] == operation)
                .firstOrNull
            : null;
    return section is Map &&
            {'denied', 'accessDenied', 'unsupported', 'error', 'unknown'}
                .contains(section['state'])
        ? 'Cannot read existing configuration: ${section['message'] ?? section['state']}'
        : null;
  }

  List<String> _overlappingRules() {
    if (!widget.lifecycle) return const [];
    try {
      final rules = (jsonDecode(existing) as Map)['Rules'] as List? ?? [];
      return [
        for (final raw in rules)
          if (raw is Map &&
              raw['Status'] == 'Enabled' &&
              raw['ID'] != 'ObjectBrowser-$preset')
            if (_prefixOverlaps(raw)) '${raw['ID'] ?? 'Unnamed rule'}'
      ];
    } catch (_) {
      return const [];
    }
  }

  bool _prefixOverlaps(Map rule) {
    final filter = rule['Filter'];
    final previous = (filter is Map
            ? filter['Prefix'] ??
                (filter['And'] is Map ? filter['And']['Prefix'] : null)
            : null) ??
        rule['Prefix'] ??
        '';
    return prefix.text.startsWith('$previous') ||
        '$previous'.startsWith(prefix.text);
  }

  Map<String, String> _tags() {
    final result = <String, String>{};
    for (final line in filterTags.text.split('\n').where((v) => v.isNotEmpty)) {
      final split = line.indexOf('=');
      if (split < 1) {
        throw const FormatException('Enter one tag as key=value on each line.');
      }
      final key = line.substring(0, split);
      if (result.containsKey(key)) {
        throw const FormatException('Duplicate tag key.');
      }
      result[key] = line.substring(split + 1);
    }
    return result;
  }

  int? _optionalNumber(TextEditingController value) =>
      value.text.trim().isEmpty ? null : int.parse(value.text.trim());
  Widget _number(String label, TextEditingController value) => TextField(
      controller: value,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => setState(() => confirmed = false));

  String _generate() => preset.startsWith('acl')
      ? jsonEncode({'ACL': preset == 'aclPrivate' ? 'private' : 'public-read'})
      : widget.lifecycle
          ? StoragePresets.lifecycle(
              profile: profile,
              preset: preset,
              prefix: prefix.text,
              existing: existing,
              storageClass: storageClass,
              days: int.tryParse(days.text) ?? -1,
              versioned: versioned,
              enabled: enabled,
              tags: _tags(),
              minimumBytes: _optionalNumber(minimumBytes),
              maximumBytes: _optionalNumber(maximumBytes),
              expirationDays: _optionalNumber(expiration),
              transitionDays: int.parse(transitionAge.text),
              archiveDays: int.parse(archiveAge.text),
              noncurrentDays: int.parse(historyAge.text),
              retainVersions: int.parse(retained.text),
              abortDays: int.parse(abortAge.text))
          : StoragePresets.access(
              profile: profile,
              bucket: bucket.name,
              preset: preset,
              principal: principal.text,
              prefix: prefix.text,
              existing: existing);
  @override
  void dispose() {
    principal.dispose();
    prefix.dispose();
    days.dispose();
    for (final c in [
      filterTags,
      minimumBytes,
      maximumBytes,
      expiration,
      transitionAge,
      archiveAge,
      historyAge,
      retained,
      abortAge
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.lifecycle
        ? StoragePresets.lifecycleLabels
        : {
            ...StoragePresets.accessLabels,
            'aclPrivate': 'Legacy ACL: private',
            'aclPublicRead': 'Legacy ACL: public read'
          };
    String? generated, validation;
    try {
      generated = _generate();
    } catch (e) {
      validation = '$e';
    }
    final overlaps = _overlappingRules();
    final public = preset == 'publicRead' || preset == 'aclPublicRead';
    final aclPreset = preset.startsWith('acl');
    final readError = _readError(aclPreset
        ? 'GetBucketAcl'
        : widget.lifecycle
            ? 'GetBucketLifecycleConfiguration'
            : 'GetBucketPolicy');
    final ownership = jsonEncode(access['ownershipControls']);
    final destructive = public ||
        (enabled && (preset == 'history' || expiration.text.isNotEmpty));
    final block = access['publicAccessBlock'];
    final blocked = (aclPreset && ownership.contains('BucketOwnerEnforced')) ||
        (public &&
            block is Map &&
            (aclPreset
                ? (block['BlockPublicAcls'] == true ||
                    block['IgnorePublicAcls'] == true)
                : (block['BlockPublicPolicy'] == true ||
                    block['RestrictPublicBuckets'] == true)));
    return AlertDialog(
      title: Text(
          widget.lifecycle ? 'Lifecycle presets' : 'Access policy presets'),
      content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('${profile.name} / ${bucket.name}'),
                const SizedBox(height: 12),
                if (loading)
                  const LinearProgressIndicator()
                else ...[
                  DropdownButtonFormField<String>(
                      initialValue: preset,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Preset'),
                      items: labels.entries
                          .where((e) =>
                              !widget.lifecycle ||
                              profile.endpointType ==
                                  EndpointProfileType.awsS3 ||
                              !{
                                'tier',
                                'intelligent',
                                'archive',
                                'infrequent',
                                'deepArchive'
                              }.contains(e.key))
                          .map((e) => DropdownMenuItem(
                              value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: saving
                          ? null
                          : (v) => setState(() {
                                preset = v!;
                                confirmed = false;
                                transitionAge.text =
                                    preset == 'intelligent' ? '0' : '30';
                                archiveAge.text =
                                    preset == 'deepArchive' ? '180' : '90';
                              })),
                  const SizedBox(height: 12),
                  if (!widget.lifecycle &&
                      {'read', 'readWrite', 'readWriteDelete'}.contains(preset))
                    TextField(
                        controller: principal,
                        decoration: const InputDecoration(
                            labelText: 'Principal ARN',
                            hintText: 'arn:aws:iam::123456789012:role/Reader'),
                        onChanged: (_) => setState(() {})),
                  if (!aclPreset && !{'tls', 'private'}.contains(preset))
                    TextField(
                        controller: prefix,
                        decoration: const InputDecoration(
                            labelText: 'Key prefix (empty = whole bucket)'),
                        onChanged: (_) => setState(() {})),
                  if (preset == 'custom') ...[
                    DropdownButtonFormField<String>(
                        initialValue:
                            storageClass.isEmpty ? null : storageClass,
                        decoration: const InputDecoration(
                            labelText: 'Endpoint storage class'),
                        items: profile.connection.storageClasses
                            .map((s) =>
                                DropdownMenuItem(value: s, child: Text(s)))
                            .toList(),
                        onChanged: (v) => setState(() => storageClass = v!)),
                    TextField(
                        controller: days,
                        decoration: const InputDecoration(
                            labelText: 'Transition after days'),
                        onChanged: (_) => setState(() {})),
                    if (profile.connection.storageClasses.isEmpty)
                      const Text(
                          'Configure supported storage classes in endpoint settings first.'),
                  ],
                  if (widget.lifecycle) ...[
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Enable this preset rule'),
                        value: enabled,
                        onChanged: (v) => setState(() => enabled = v)),
                    if ({'tier', 'infrequent', 'intelligent'}.contains(preset))
                      _number('First transition after days', transitionAge),
                    if ({'tier', 'archive', 'deepArchive'}.contains(preset))
                      _number('Archive after days', archiveAge),
                    if (preset == 'multipart')
                      _number('Abort incomplete uploads after days', abortAge),
                    if (preset == 'history') ...[
                      _number(
                          'Expire noncurrent versions after days', historyAge),
                      _number('Retain newest noncurrent versions', retained)
                    ],
                    if (preset != 'multipart')
                      ExpansionTile(
                          title: const Text('Filter and optional expiration'),
                          children: [
                            TextField(
                                controller: filterTags,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                    labelText: 'Tags (one key=value per line)'),
                                onChanged: (_) =>
                                    setState(() => confirmed = false)),
                            _number('Object size greater than bytes (optional)',
                                minimumBytes),
                            _number('Object size less than bytes (optional)',
                                maximumBytes),
                            _number(
                                'Expire current objects after days (optional)',
                                expiration),
                          ]),
                    Text(
                        'Scope: ${prefix.text.isEmpty ? 'whole bucket' : prefix.text}; ${enabled ? 'enabled' : 'disabled'}. Rules run on the server. Disabling does not reverse previous transitions or deletions.'),
                  ],
                  const SizedBox(height: 12),
                  Text(widget.lifecycle
                      ? 'Adds or updates this preset rule. Other rules and their filters are preserved. Transition charges, minimum storage durations and small-object eligibility are determined by your provider.'
                      : 'Updates only Object Browser preset statements. Existing custom policy statements, IAM permissions and ACL grants remain in effect.'),
                  if (overlaps.isNotEmpty)
                    Text(
                        'Potential overlapping rules: ${overlaps.take(5).join(', ')}. Review their scopes; tag and size predicates may narrow the overlap.'),
                  if (preset == 'readWrite')
                    const Text(
                        'Write access can overwrite existing keys. This preset does not grant DeleteObject.'),
                  if (!widget.lifecycle) ...[
                    const SizedBox(height: 8),
                    const Text(
                        'Bucket policies are preferred when Object Ownership disables ACLs. Endpoint URLs are not S3 resource ARNs; this preset uses the bucket and AWS partition.'),
                    ExpansionTile(
                        title: const Text(
                            'ACL, ownership and public-access settings'),
                        children: [
                          SelectableText(
                              const JsonEncoder.withIndent('  ').convert({
                            'acl': access['acl'],
                            'ownershipControls': access['ownershipControls'],
                            'publicAccessBlock': access['publicAccessBlock']
                          }))
                        ]),
                  ],
                  if (readError != null) Text(readError),
                  if (blocked)
                    const Text(
                        'Object Ownership or bucket public-access settings block this preset.'),
                  if (aclPreset)
                    const Text(
                        'Applying a canned ACL replaces all existing ACL grants. Private ACL grants access only to the owner; bucket policy and IAM grants still apply.'),
                  if (destructive)
                    CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(public
                            ? 'I understand these objects become publicly readable.'
                            : 'I understand this rule schedules object or version expiration.'),
                        value: confirmed,
                        onChanged: (v) => setState(() => confirmed = v!)),
                  if (generated != null)
                    ExpansionTile(
                        title: const Text('Review generated configuration'),
                        children: [
                          SelectableText(generated,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12))
                        ]),
                  if (validation != null) Text(validation),
                ],
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
              ]))),
      actions: [
        TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: loading ||
                    saving ||
                    generated == null ||
                    readError != null ||
                    blocked ||
                    (destructive && !confirmed) ||
                    (access.isEmpty && error != null)
                ? null
                : () async {
                    setState(() {
                      saving = true;
                      error = null;
                    });
                    try {
                      if (widget.lifecycle) {
                        await widget.controller.storageAction('putLifecycle',
                            profile: profile,
                            arguments: {
                              'bucketName': bucket.name,
                              'lifecycleJson': generated,
                              'expectedLifecycleJson': existing,
                              if (minimumSize != null)
                                'transitionDefaultMinimumObjectSize':
                                    minimumSize,
                            });
                      } else {
                        await widget.controller.storageAction('putAccess',
                            profile: profile,
                            arguments: {
                              'bucketName': bucket.name,
                              if (aclPreset)
                                'acl': preset == 'aclPrivate'
                                    ? 'private'
                                    : 'public-read'
                              else ...{
                                'policyJson': generated,
                                'expectedPolicyJson': existing
                              }
                            });
                      }
                      await widget.controller.refreshBucketAdminState();
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      if (mounted) {
                        setState(() {
                          error = DiagnosticSafety.text('$e');
                          saving = false;
                        });
                      }
                    }
                  },
            child: Text(saving ? 'Applying…' : 'Apply preset'))
      ],
    );
  }
}
