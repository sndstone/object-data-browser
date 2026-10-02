import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/app_platform.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';

class BucketCopyDialog extends StatefulWidget {
  const BucketCopyDialog(
      {super.key, required this.controller, required this.sourceBucket});
  final AppController controller;
  final BucketSummary sourceBucket;
  @override
  State<BucketCopyDialog> createState() => _BucketCopyDialogState();
}

class _BucketCopyDialogState extends State<BucketCopyDialog> {
  late final EndpointProfile source = widget.controller.selectedProfile!;
  late EndpointProfile destination = source;
  final bucket = TextEditingController();
  final prefix = TextEditingController();
  String conflict = 'skip';
  bool create = false,
      confirmed = false,
      resume = false,
      history = false,
      copying = false;
  final sections = <String>{};
  bool get advanced =>
      !AppPlatform.isMobile &&
      source.endpointType != EndpointProfileType.azureBlob &&
      destination.endpointType != EndpointProfileType.azureBlob;

  Future<bool> review(Map<String, Object?> plan) async {
    if (!mounted) return false;
    final blocked = (plan['blocked'] as List? ?? []).isNotEmpty;
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: Text(plan['planId'] != null
                      ? 'Review bucket configuration'
                      : 'Review version history'),
                  content: SizedBox(
                      width: 650,
                      height: 420,
                      child: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            if (plan['versionCount'] != null)
                              Text(
                                  '${plan['versionCount']} versions and ${plan['deleteMarkerCount']} delete markers will be copied in order. New version IDs will be recorded in the recovery journal.'),
                            for (final warning
                                in plan['warnings'] as List? ?? [])
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text('$warning')),
                            for (final block in plan['blocked'] as List? ?? [])
                              Text('Blocked: $block'),
                            for (final raw
                                in plan['changes'] as List? ?? []) ...[
                              const Divider(),
                              Text('${(raw as Map)['section']}',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const Text('Current destination'),
                              SelectableText(const JsonEncoder.withIndent('  ')
                                  .convert(raw['before'])),
                              const Text('Proposed destination'),
                              SelectableText(const JsonEncoder.withIndent('  ')
                                  .convert(raw['after'])),
                            ],
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed:
                            blocked ? null : () => Navigator.pop(context, true),
                        child: const Text('Approve copy'))
                  ],
                )) ??
        false;
  }

  Future<String?> resolve(Map<String, Object?> outcome) async {
    if (!mounted) return null;
    final value = TextEditingController();
    try {
      return await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Inspect uncertain version copy'),
                content: SizedBox(
                    width: 560,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          'A write may have completed. Inspect the destination, then enter the exact new version ID or delete-marker version ID. The app verifies it before continuing.'),
                      SelectableText(const JsonEncoder.withIndent('  ').convert(
                          outcome['pending'] ??
                              outcome['inFlight'] ??
                              {'recoveryId': outcome['recoveryId']})),
                      TextField(
                          controller: value,
                          decoration: const InputDecoration(
                              labelText: 'Verified destination version ID')),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Keep paused')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, value.text.trim()),
                      child: const Text('Verify and resume'))
                ],
              ));
    } finally {
      value.dispose();
    }
  }

  @override
  void dispose() {
    bucket.dispose();
    prefix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Copy ${widget.sourceBucket.name}'),
        content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  DropdownButtonFormField<String>(
                      initialValue: destination.id,
                      decoration: const InputDecoration(
                          labelText: 'Destination endpoint'),
                      items: widget.controller.profiles
                          .map((p) => DropdownMenuItem(
                              value: p.id, child: Text(p.name)))
                          .toList(),
                      onChanged: (id) => setState(() {
                            destination = widget.controller.profiles
                                .firstWhere((p) => p.id == id);
                            confirmed = false;
                            if (!advanced) {
                              history = false;
                              sections.clear();
                            }
                          })),
                  const SizedBox(height: 12),
                  TextField(
                      controller: bucket,
                      decoration: const InputDecoration(
                          labelText: 'Destination bucket / container'),
                      onChanged: (_) => setState(() => confirmed = false)),
                  if (destination.id == widget.controller.selectedProfile?.id)
                    Wrap(spacing: 6, children: [
                      for (final b in widget.controller.buckets
                          .where((b) => b.name != widget.sourceBucket.name)
                          .take(8))
                        ActionChip(
                            label: Text(b.name),
                            onPressed: () => setState(() {
                                  bucket.text = b.name;
                                  confirmed = false;
                                }))
                    ]),
                  TextField(
                      controller: prefix,
                      decoration: const InputDecoration(
                          labelText: 'Source prefix (empty = full bucket)')),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                      initialValue: conflict,
                      decoration: const InputDecoration(
                          labelText: 'Existing destination objects'),
                      items: const [
                        DropdownMenuItem(
                            value: 'skip', child: Text('Skip existing keys')),
                        DropdownMenuItem(
                            value: 'replace',
                            child: Text('Replace existing keys')),
                        DropdownMenuItem(
                            value: 'fail',
                            child: Text('Report conflicts as failures'))
                      ],
                      onChanged: (v) => setState(() {
                            conflict = v!;
                            confirmed = false;
                          })),
                  CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Create destination if missing'),
                      value: create,
                      onChanged: (v) => setState(() => create = v!)),
                  CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                          'Resume the saved copy with these settings'),
                      value: resume,
                      onChanged: (v) => setState(() => resume = v!)),
                  if (advanced) ...[
                    CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title:
                            const Text('Copy every version and delete marker'),
                        subtitle: const Text(
                            'Requires destination versioning and an empty destination prefix, including history. Version IDs are remapped; retention and ACLs remain destination-controlled.'),
                        value: history,
                        onChanged: copying
                            ? null
                            : (v) => setState(() {
                                  history = v!;
                                  confirmed = false;
                                })),
                    const Text(
                        'Bucket configuration to review and apply after copying:'),
                    Wrap(spacing: 6, children: [
                      for (final section in [
                        'lifecycle',
                        'cors',
                        'tags',
                        'policy',
                        'publicAccessBlock'
                      ])
                        FilterChip(
                            label: Text({
                              'lifecycle': 'Lifecycle',
                              'cors': 'CORS',
                              'tags': 'Tags',
                              'policy': 'Bucket policy',
                              'publicAccessBlock': 'Public access block'
                            }[section]!),
                            selected: sections.contains(section),
                            onSelected: copying
                                ? null
                                : (value) => setState(() {
                                      value
                                          ? sections.add(section)
                                          : sections.remove(section);
                                    }))
                    ]),
                  ],
                  const Text(
                      'Copies exact object keys, metadata, tags and content headers. Configuration changes are reviewed before the copy and applied after the content completes. The source remains unchanged.'),
                  const SizedBox(height: 8),
                  const Text(
                      'Changes to the source during a copy can cause conflicts. Cross-endpoint copies stream through this computer and may incur transfer charges. Failed objects are reported in the event log.'),
                  if (conflict == 'replace' || history)
                    CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(history
                            ? 'I approve adding versions and delete markers to the destination.'
                            : 'I approve replacing existing destination objects.'),
                        value: confirmed,
                        onChanged: (v) => setState(() => confirmed = v!)),
                ]))),
        actions: [
          TextButton(
              onPressed: () {
                if (copying) {
                  widget.controller.cancelAction('copy-bucket');
                } else {
                  Navigator.pop(context);
                }
              },
              child: Text(copying ? 'Stop copy' : 'Cancel')),
          FilledButton(
              onPressed: copying ||
                      bucket.text.trim().isEmpty ||
                      ((conflict == 'replace' || history) && !confirmed)
                  ? null
                  : () async {
                      final name = bucket.text.trim(),
                          selected = destination,
                          policy = conflict,
                          sourcePrefix = prefix.text,
                          createBucket = create;
                      setState(() => copying = true);
                      await widget.controller.copyBucketContents(
                          sourceBucketName: widget.sourceBucket.name,
                          sourceProfile: source,
                          destinationBucketName: name,
                          destinationProfile: selected,
                          conflictPolicy: policy,
                          prefix: sourcePrefix,
                          createDestinationIfMissing: createBucket,
                          resume: resume,
                          includeHistory: history,
                          configurationSections: sections.toList()..sort(),
                          reviewPlan: review,
                          resolveHistoryOutcome: resolve);
                      if (context.mounted) Navigator.pop(context);
                    },
              child: Text(copying ? 'Copying…' : 'Copy bucket'))
        ],
      );
}
