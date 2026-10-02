import 'content_headers_dialog.dart';
import 'azure_admin_dialog.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../controllers/action_scope.dart';
import '../models/domain_models.dart';
import '../services/diagnostic_safety.dart';
import '../services/multipart_sizing.dart';
import '../services/listing_cancellation.dart';
import 'tag_editor_dialog.dart';

class StorageAdminDialog extends StatefulWidget {
  const StorageAdminDialog(
      {super.key,
      required this.controller,
      this.objectKey,
      this.versionId,
      this.deleteMarker = false});
  final AppController controller;
  final String? objectKey, versionId;
  final bool deleteMarker;
  @override
  State<StorageAdminDialog> createState() => _StorageAdminDialogState();
}

class _StorageAdminDialogState extends State<StorageAdminDialog> {
  late final profile = widget.controller.selectedProfile!;
  late final bucket = widget.controller.selectedBucket!.name;
  final amount = TextEditingController(text: '30');
  final date = TextEditingController(
      text: DateTime.now()
          .toUtc()
          .add(const Duration(days: 30))
          .toIso8601String());
  final kms = TextEditingController();
  String mode = 'GOVERNANCE',
      unit = 'Days',
      tier = 'Standard',
      storageClass = '',
      encryption = '';
  bool busy = true;
  String? error, notice;
  Map<String, Object?> details = {}, provider = {}, protection = {};
  List<dynamic> uploads = [];
  List<Map<String, Object?>> recoveryUploads = [];
  Map<String, Object?>? cursor;
  ActionScope? actionScope;
  Map<String, Object?> get ref => {
        'bucketName': bucket,
        if (widget.objectKey != null) 'key': widget.objectKey,
        if (widget.versionId != null) 'versionId': widget.versionId
      };
  bool supports(String action) =>
      (provider['actions'] as List? ?? []).contains(action);
  @override
  void initState() {
    super.initState();
    if (profile.endpointType == EndpointProfileType.azureBlob) {
      mode = 'Unlocked';
    }
    _load();
  }

  @override
  void dispose() {
    actionScope?.cancel();
    amount.dispose();
    date.dispose();
    kms.dispose();
    super.dispose();
  }

  Future<Map<String, Object?>> call(String action,
      [Map<String, Object?> args = const {}]) {
    if (!mounted) throw const ListingCancelled();
    ActionScope.current?.check();
    return widget.controller
        .storageAction(action, profile: profile, arguments: {...ref, ...args});
  }

  Future<void> run(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    final scope = ActionScope();
    actionScope = scope;
    try {
      await scope.run(action);
    } on ListingCancelled {
      if (mounted) {
        notice = scope.outcomeUnknown
            ? 'Stopped. Inspect recovery state before retrying an uncertain change.'
            : 'Stopped. Completed recovery checkpoints remain available.';
      }
    } catch (e) {
      if (mounted) setState(() => error = DiagnosticSafety.text('$e'));
    } finally {
      if (identical(actionScope, scope)) actionScope = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _load() async {
    await run(() async {
      provider = await call('providerInfo');
      if (widget.objectKey != null && !widget.deleteMarker) {
        details = await call('objectDetails');
      }
    });
  }

  Future<bool> confirm(String text) async =>
      mounted &&
      (await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                      title: const Text('Confirm change'),
                      content: Text(text),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Confirm'))
                      ])) ??
          false);
  Map<String, String> stringMap(Object? value) =>
      (value as Map? ?? {}).map((k, v) => MapEntry('$k', '$v'));
  Future<void> editMap(String field) async {
    final current = field == 'tags' ? await call('objectTags') : details;
    if (!mounted) return;
    final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => TagEditorDialog(
            initialTags: stringMap(current[field]),
            title: field == 'tags' ? 'Object tags' : 'Object metadata'));
    if (result == null) return;
    await run(() async {
      final outcome = await call(
          field == 'tags' ? 'objectTags' : 'objectProperties', {
        field: result,
        if (details['etag'] != null) 'expectedETag': details['etag']
      });
      checkOutcome(outcome);
      details = await call('objectDetails');
      notice = 'Saved $field.';
    });
  }

  Future<void> editHeaders() async {
    final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) =>
            ContentHeadersDialog(headers: stringMap(details['headers'])));
    if (result == null) return;
    await run(() async {
      checkOutcome(await call('objectProperties', {
        'headers': result,
        if (details['etag'] != null) 'expectedETag': details['etag']
      }));
      details = await call('objectDetails');
      notice = 'Headers saved.';
    });
  }

  void checkOutcome(Map<String, Object?> result) {
    if ((result['failureCount'] as num? ?? 0) > 0 ||
        {'failed', 'cancelled', 'unknown', 'completionUnknown'}
            .contains(result['status']) ||
        result['requiresVerification'] == true) {
      throw StateError(
          '${result['failures'] ?? result['lastStatus'] ?? result['error'] ?? result['status']}');
    }
  }

  Widget button(String text, Future<void> Function() fn) => OutlinedButton(
      onPressed: busy
          ? null
          : () async {
              try {
                await fn();
              } catch (e) {
                if (mounted) {
                  setState(() => error = DiagnosticSafety.text('$e'));
                }
              }
            },
      child: Text(text));
  Future<void> refreshRecovery() async {
    final result = await call('listTransferRecovery');
    recoveryUploads = (result['items'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList();
  }

  String recoveryAction(Map<String, Object?> record, {bool abort = false}) =>
      record['kind'] == 'download'
          ? (abort ? 'abortDownload' : 'resumeDownload')
          : (abort ? 'abortUpload' : 'resumeUpload');

  Future<Map<String, Object?>> finishRecovery(
      Map<String, Object?> initial) async {
    var current = initial;
    while ({'paused', 'prepared', 'uploading', 'downloading'}
        .contains(current['status'])) {
      if (!mounted) throw const ListingCancelled();
      ActionScope.current?.check();
      final before = (current['completedBytes'] as num? ?? 0).toInt();
      setState(() => notice =
          '${current['kind'] == 'download' ? 'Downloaded' : 'Uploaded'} $before / ${current['fileSize']} bytes.');
      current = await call(recoveryAction(current), {
        'recoveryId': current['recoveryId'] ?? current['id'],
        'maxParts': 16,
        'maxRanges': 16,
      });
      ActionScope.current?.check();
      checkOutcome(current);
      if (current['status'] == 'paused' &&
          (current['completedBytes'] as num? ?? 0) <= before) {
        throw StateError(
            'Recovery made no progress. Inspect the stored record before resuming.');
      }
    }
    checkOutcome(current);
    return current;
  }

  Future<void> startRecoveryDownload() => run(() async {
        final directory = await FilePicker.platform
            .getDirectoryPath(dialogTitle: 'Recoverable download destination');
        if (directory == null || !mounted) return;
        final outcome = await call('startResumableDownload', {
          'destinationDirectory': directory,
          'conflictPolicy': 'keepBoth',
          'multipartChunkMiB': widget.controller.settings.multipartChunkMiB,
          'maxRanges': 16,
        });
        final result = await finishRecovery(outcome);
        notice = result['status'] == 'completed'
            ? 'Download verified and saved to ${result['filePath']}.'
            : 'Download status: ${result['status']}.';
      });

  Future<void> startRecoveryUpload() async {
    await run(() async {
      final selection = await FilePicker.platform.pickFiles(
          allowMultiple: false,
          dialogTitle: 'Choose a file for recoverable upload');
      if (selection == null ||
          selection.files.single.path == null ||
          !mounted) {
        return;
      }
      final selected = selection.files.single;
      final file = File(selected.path!);
      final size = await file.length();
      if (!mounted) return;
      final keyController = TextEditingController(text: selected.name);
      var conflict = 'skip', overwriteConfirmed = false;
      final chosen = await showDialog<Map<String, Object?>>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Recoverable upload'),
                  content: SizedBox(
                      width: 500,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('${selected.name} ($size bytes) → $bucket'),
                        TextField(
                            controller: keyController,
                            decoration: const InputDecoration(
                                labelText: 'Destination object key'),
                            onChanged: (_) => update(() {})),
                        DropdownButtonFormField<String>(
                            initialValue: conflict,
                            decoration: const InputDecoration(
                                labelText: 'Existing destination object'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'skip',
                                  child: Text('Skip existing key')),
                              DropdownMenuItem(
                                  value: 'fail',
                                  child: Text('Report a conflict')),
                              DropdownMenuItem(
                                  value: 'replace',
                                  child: Text('Replace existing object'))
                            ],
                            onChanged: (value) => update(() {
                                  conflict = value!;
                                  overwriteConfirmed = false;
                                })),
                        if (conflict == 'replace')
                          CheckboxListTile(
                              value: overwriteConfirmed,
                              onChanged: (value) =>
                                  update(() => overwriteConfirmed = value!),
                              title: const Text(
                                  'I approve replacing the existing destination object.')),
                        const SizedBox(height: 12),
                        const Text(
                            'Keep the source file at its current path to resume after interruption. Progress and cancellation are available in Jobs.'),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: keyController.text.isEmpty ||
                                (conflict == 'replace' && !overwriteConfirmed)
                            ? null
                            : () => Navigator.pop(context, {
                                  'key': keyController.text,
                                  'conflictPolicy': conflict
                                }),
                        child: const Text('Start upload'))
                  ],
                )),
      );
      keyController.dispose();
      if (chosen == null || !mounted) return;
      final settings = widget.controller.settings;
      final partSize = settings.dynamicMultipartSizing
          ? MultipartSizing.recommendedPartSizeMiB(size)
          : MultipartSizing.compliantManualPartSizeMiB(
              settings.multipartChunkMiB);
      final outcome = await finishRecovery(await call('startResumableUpload', {
        ...chosen,
        'filePath': file.path,
        'multipartChunkMiB': partSize,
        'maxParts': 16
      }));
      await refreshRecovery();
      notice = outcome['status'] == 'skipped'
          ? 'Existing object skipped.'
          : outcome['status'] == 'completed'
              ? 'Upload completed.'
              : 'Upload status: ${outcome['status']}.';
    });
  }

  Widget select(String label, String value, List<String> values,
          void Function(String) update) =>
      DropdownButtonFormField<String>(
          initialValue: value.isEmpty ? null : value,
          decoration: InputDecoration(labelText: label),
          items: values
              .map((v) => DropdownMenuItem(value: v, child: Text(v)))
              .toList(),
          onChanged: busy ? null : (v) => setState(() => update(v!)));
  @override
  Widget build(BuildContext context) {
    final object = widget.objectKey != null;
    final classes = profile.endpointType == EndpointProfileType.s3Compatible
        ? profile.connection.storageClasses
        : List<String>.from(provider['storageClasses'] as List? ?? []);
    return AlertDialog(
        title: Text(object ? 'Object administration' : 'Bucket administration'),
        content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  SelectableText(
                      '${profile.name} / $bucket${object ? '/${widget.objectKey}' : ''}${widget.versionId == null ? '' : '\nVersion: ${widget.versionId}'}'),
                  const SizedBox(height: 12),
                  if (busy) const LinearProgressIndicator(),
                  if (error != null)
                    SelectableText(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (notice != null) SelectableText(notice!),
                  if (profile.endpointType == EndpointProfileType.azureBlob &&
                      !object &&
                      (supports('getFilesystemInfo') ||
                          supports('getAccountLifecycle') ||
                          supports('getContainerProtection')))
                    button('Azure lifecycle, immutability and directories',
                        () async {
                      await showDialog<void>(
                          context: context,
                          builder: (_) => AzureAdminDialog(
                              controller: widget.controller,
                              profile: profile,
                              bucket: bucket));
                    }),
                  if (object && !widget.deleteMarker) ...[
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      if (supports('objectTags'))
                        button('Edit tags', () async {
                          try {
                            await editMap('tags');
                          } catch (e) {
                            if (mounted) {
                              setState(
                                  () => error = DiagnosticSafety.text('$e'));
                            }
                          }
                        }),
                      if (supports('objectProperties'))
                        button('Edit metadata', () => editMap('metadata')),
                      if (supports('objectProperties'))
                        button('Edit content headers', editHeaders),
                      if (supports('presignVersion'))
                        button(
                            'Share this version',
                            () => run(() async {
                                  final r = await call('presignVersion',
                                      {'expirationSeconds': 900});
                                  notice = r['url'] as String?;
                                })),
                      if (supports('downloadVersion'))
                        button('Download this version', () async {
                          final path = await FilePicker.platform
                              .getDirectoryPath(
                                  dialogTitle: 'Download destination');
                          if (path != null) {
                            await run(() async {
                              final r = await call('downloadVersion', {
                                'destinationPath': path,
                                'multipartChunkMiB':
                                    widget.controller.settings.multipartChunkMiB
                              });
                              checkOutcome(r);
                              notice = 'Download completed.';
                            });
                          }
                        }),
                      if (supports('startResumableDownload'))
                        button('Download with recovery', startRecoveryDownload),
                      if (widget.versionId != null && supports('copyObject'))
                        button('Restore as current version', () async {
                          if (!await confirm(
                              'Copy this version to the current key? The selected historical version remains unchanged.')) {
                            return;
                          }
                          await run(() async {
                            final r = await widget.controller.storageAction(
                                'copyObject',
                                profile: profile,
                                destinationProfile: profile,
                                arguments: {
                                  'sourceBucketName': bucket,
                                  'sourceKey': widget.objectKey,
                                  'sourceVersionId': widget.versionId,
                                  'destinationBucketName': bucket,
                                  'destinationKey': widget.objectKey,
                                  'conflictPolicy': 'replace'
                                });
                            checkOutcome(r);
                            notice = 'Copied to the current key.';
                          });
                        }),
                    ]),
                    ExpansionTile(
                        title: const Text('Metadata and headers'),
                        children: [
                          SelectableText(const JsonEncoder.withIndent('  ')
                              .convert(details))
                        ]),
                    if (supports('objectProperties'))
                      ExpansionTile(
                          title: const Text('Storage class and encryption'),
                          children: [
                            select('Destination storage class', storageClass,
                                classes, (v) => storageClass = v),
                            if (profile.endpointType !=
                                EndpointProfileType.azureBlob) ...[
                              select(
                                  'Encryption',
                                  encryption,
                                  ['Preserve', 'AES256', 'aws:kms'],
                                  (v) => encryption = v),
                              if (encryption == 'aws:kms')
                                TextField(
                                    controller: kms,
                                    decoration: const InputDecoration(
                                        labelText: 'KMS key ARN (optional)')),
                            ],
                            const Text(
                                'On S3, property edits copy the object to the same key and can create a new version. Existing content headers and metadata are preserved.'),
                            button('Apply properties', () async {
                              if (!await confirm(
                                  'Apply these properties to ${widget.objectKey}?')) {
                                return;
                              }
                              await run(() async {
                                final r = await call('objectProperties', {
                                  if (storageClass.isNotEmpty)
                                    'storageClass': storageClass,
                                  if (encryption.isNotEmpty &&
                                      encryption != 'Preserve')
                                    'encryption': {
                                      'ServerSideEncryption': encryption,
                                      if (kms.text.trim().isNotEmpty)
                                        'SSEKMSKeyId': kms.text.trim()
                                    },
                                  if (details['etag'] != null)
                                    'expectedETag': details['etag']
                                });
                                checkOutcome(r);
                                notice = 'Properties applied.';
                                details = await call('objectDetails');
                              });
                            }),
                          ]),
                    if (supports('restoreObject'))
                      ExpansionTile(
                          title: const Text('Restore an archived object'),
                          children: [
                            select(
                                'Retrieval tier',
                                tier,
                                ['Standard', 'Bulk', 'Expedited'],
                                (v) => tier = v),
                            TextField(
                                controller: amount,
                                decoration: const InputDecoration(
                                    labelText: 'Days to keep restored copy'),
                                keyboardType: TextInputType.number),
                            button(
                                'Request restore',
                                () => run(() async {
                                      final days = int.tryParse(amount.text);
                                      if (days == null || days < 1) {
                                        throw const FormatException(
                                            'Enter a positive day count.');
                                      }
                                      await call('restoreObject',
                                          {'days': days, 'tier': tier});
                                      notice =
                                          'Restore requested. Retrieval is asynchronous and may incur charges.';
                                    })),
                          ]),
                  ],
                  if (object &&
                      widget.versionId != null &&
                      supports('deleteVersion'))
                    button(
                        widget.deleteMarker
                            ? 'Remove this delete marker'
                            : 'Permanently delete this version', () async {
                      if (!await confirm(widget.deleteMarker
                          ? 'Remove this exact delete marker? An older object may become visible again.'
                          : 'Permanently delete this exact version? This cannot be undone.')) {
                        return;
                      }
                      await run(() async {
                        checkOutcome(await call('deleteVersion'));
                        notice = 'Version deleted.';
                      });
                    }),
                  if ((object && supports('getObjectProtection')) ||
                      (!object && supports('getBucketProtection')))
                    ExpansionTile(
                        title: Text(profile.endpointType ==
                                EndpointProfileType.azureBlob
                            ? 'Blob immutability and legal hold'
                            : 'Object Lock and retention'),
                        children: [
                          button(
                              'Read protection',
                              () => run(() async {
                                    protection = await call(object
                                        ? 'getObjectProtection'
                                        : 'getBucketProtection');
                                  })),
                          if (protection.isNotEmpty)
                            SelectableText(const JsonEncoder.withIndent('  ')
                                .convert(protection)),
                          select(
                              'Retention mode',
                              mode,
                              profile.endpointType ==
                                      EndpointProfileType.azureBlob
                                  ? ['Unlocked', 'Locked']
                                  : ['GOVERNANCE', 'COMPLIANCE'],
                              (v) => mode = v),
                          if (object)
                            TextField(
                                controller: date,
                                decoration: const InputDecoration(
                                    labelText: 'Retain until (UTC ISO date)'))
                          else ...[
                            TextField(
                                controller: amount,
                                decoration: const InputDecoration(
                                    labelText: 'Default retention amount'),
                                keyboardType: TextInputType.number),
                            select('Unit', unit, ['Days', 'Years'],
                                (v) => unit = v),
                          ],
                          Text(profile.endpointType ==
                                  EndpointProfileType.azureBlob
                              ? 'Locked Azure retention cannot be shortened or unlocked.'
                              : 'Compliance retention cannot be shortened or removed. This workflow never bypasses governance retention.'),
                          button('Apply retention', () async {
                            if (!await confirm(
                                'Apply $mode retention to ${object ? 'this exact object reference' : 'this bucket'}? Locked or compliance retention is irreversible until expiry.')) {
                              return;
                            }
                            await run(() async {
                              if (object) {
                                final until = DateTime.parse(date.text).toUtc();
                                if (!until.isAfter(DateTime.now())) {
                                  throw const FormatException(
                                      'Retention must end in the future.');
                                }
                                protection = await call('setObjectProtection', {
                                  'retention': {
                                    'Mode': mode,
                                    'RetainUntilDate': until.toIso8601String()
                                  }
                                });
                              } else {
                                final value = int.tryParse(amount.text);
                                if (value == null || value < 1) {
                                  throw const FormatException(
                                      'Enter a positive retention amount.');
                                }
                                protection = await call('setBucketProtection', {
                                  'configuration': {
                                    'ObjectLockEnabled': 'Enabled',
                                    'Rule': {
                                      'DefaultRetention': {
                                        'Mode': mode,
                                        unit: value
                                      }
                                    }
                                  }
                                });
                              }
                              notice = 'Retention applied.';
                            });
                          }),
                          if (object)
                            Wrap(spacing: 8, children: [
                              for (final hold in [true, false])
                                button(
                                    hold
                                        ? 'Enable legal hold'
                                        : 'Release legal hold', () async {
                                  if (!await confirm(
                                      '${hold ? 'Enable' : 'Release'} legal hold on this object reference?')) {
                                    return;
                                  }
                                  await run(() async {
                                    protection = await call(
                                        'setObjectProtection',
                                        {'legalHold': hold});
                                    notice = 'Legal hold updated.';
                                  });
                                })
                            ]),
                        ]),
                  if (!object && supports('listTransferRecovery'))
                    ExpansionTile(
                        title: const Text('Recoverable file transfers'),
                        children: [
                          const Text(
                              'Resume interrupted uploads and downloads from this computer. File identities and completed parts or ranges are verified before reuse.'),
                          Wrap(spacing: 8, children: [
                            if (supports('startResumableUpload'))
                              button('Upload a file with recovery',
                                  startRecoveryUpload),
                            button('Refresh recovery records',
                                () => run(refreshRecovery)),
                          ]),
                          for (final upload in recoveryUploads)
                            ListTile(
                              isThreeLine: true,
                              title: Text('${upload['key']}'),
                              subtitle: Text(
                                  '${upload['kind'] == 'download' ? 'Download' : 'Upload'} · ${upload['status']} · ${upload['completedBytes'] ?? 0} / ${upload['fileSize'] ?? 0} bytes\n${upload['filePath'] ?? ''}${upload['requiresVerification'] == true ? '\nCompletion is uncertain; verify the destination before further changes.' : ''}${upload['error'] == null ? '' : '\n${DiagnosticSafety.text('${upload['error']}')}'}'),
                              trailing: Wrap(children: [
                                if (supports(recoveryAction(upload)) &&
                                    !{
                                      'completed',
                                      'aborted',
                                      'cancelled',
                                      'failed',
                                      'skipped'
                                    }.contains(upload['status']))
                                  IconButton(
                                      tooltip: upload['requiresVerification'] ==
                                                  true ||
                                              upload['status'] ==
                                                  'completionUnknown'
                                          ? 'Verify completion'
                                          : 'Resume transfer',
                                      onPressed: busy
                                          ? null
                                          : () => run(() async {
                                                final outcome =
                                                    await finishRecovery(
                                                        await call(
                                                            recoveryAction(
                                                                upload),
                                                            {
                                                      'recoveryId': upload[
                                                              'recoveryId'] ??
                                                          upload['id']
                                                    }));
                                                await refreshRecovery();
                                                notice = outcome['status'] ==
                                                        'completed'
                                                    ? 'Transfer completed.'
                                                    : 'Transfer status: ${outcome['status']}.';
                                              }),
                                      icon: const Icon(Icons.play_arrow)),
                                if (supports(
                                        recoveryAction(upload, abort: true)) &&
                                    !{'completed', 'aborted', 'skipped'}
                                        .contains(upload['status']))
                                  IconButton(
                                      tooltip: 'Abort recoverable transfer',
                                      onPressed: busy
                                          ? null
                                          : () async {
                                              if (!await confirm(upload[
                                                          'kind'] ==
                                                      'download'
                                                  ? 'Remove the staged partial download for ${upload['key']}? Existing destination files remain unchanged.'
                                                  : upload['kind'] ==
                                                          'azureBlockUpload'
                                                      ? 'Stop this upload of ${upload['key']}? Azure will expire uncommitted blocks after seven days of inactivity. The committed blob remains unchanged.'
                                                      : 'Discard uploaded parts for ${upload['key']}? The local source file remains unchanged.')) {
                                                return;
                                              }
                                              await run(() async {
                                                checkOutcome(await call(
                                                    recoveryAction(upload,
                                                        abort: true),
                                                    {
                                                      'recoveryId': upload[
                                                              'recoveryId'] ??
                                                          upload['id']
                                                    }));
                                                await refreshRecovery();
                                                notice = 'Transfer aborted.';
                                              });
                                            },
                                      icon: const Icon(Icons.delete_outline)),
                              ]),
                            ),
                        ]),
                  if (!object && supports('getBucketConfiguration'))
                    button(
                        'Read extended bucket configuration',
                        () => run(() async {
                              final value =
                                  await call('getBucketConfiguration');
                              notice = const JsonEncoder.withIndent('  ')
                                  .convert(value);
                            })),
                  if (!object && supports('listMultipartUploads'))
                    ExpansionTile(
                        title: const Text('Incomplete multipart uploads'),
                        children: [
                          button(
                              uploads.isEmpty
                                  ? 'List uploads'
                                  : 'Refresh uploads',
                              () => run(() async {
                                    final r =
                                        await call('listMultipartUploads');
                                    uploads = r['items'] as List? ?? [];
                                    cursor = r['nextCursor'] is Map
                                        ? Map<String, Object?>.from(
                                            r['nextCursor'] as Map)
                                        : null;
                                  })),
                          for (final raw in uploads)
                            Builder(builder: (context) {
                              final upload = raw as Map;
                              return ListTile(
                                  title: Text('${upload['Key']}'),
                                  subtitle: Text(
                                      '${upload['UploadId']}\n${upload['Initiated']}'),
                                  trailing: Wrap(children: [
                                    IconButton(
                                        tooltip: 'Inspect parts',
                                        onPressed: busy
                                            ? null
                                            : () => run(() async {
                                                  Map<String, Object?>?
                                                      partCursor;
                                                  var count = 0, bytes = 0;
                                                  final seenCursors =
                                                      <String>{};
                                                  do {
                                                    final r = await call(
                                                        'listParts', {
                                                      'key': upload['Key'],
                                                      'uploadId':
                                                          upload['UploadId'],
                                                      if (partCursor != null)
                                                        'cursor': partCursor
                                                    });
                                                    for (final part
                                                        in r['items']
                                                                as List? ??
                                                            []) {
                                                      count++;
                                                      bytes += (part['Size']
                                                                  as num? ??
                                                              0)
                                                          .toInt();
                                                    }
                                                    partCursor = r['nextCursor']
                                                            is Map
                                                        ? Map<String,
                                                                Object?>.from(
                                                            r['nextCursor']
                                                                as Map)
                                                        : null;
                                                    if (partCursor?[
                                                                'hasMore'] ==
                                                            true &&
                                                        !seenCursors.add(
                                                            jsonEncode(
                                                                partCursor))) {
                                                      throw StateError(
                                                          'Multipart listing did not advance.');
                                                    }
                                                  } while (
                                                      partCursor?['hasMore'] ==
                                                          true);
                                                  notice =
                                                      '$count uploaded parts, $bytes bytes.';
                                                }),
                                        icon: const Icon(Icons.info_outline)),
                                    IconButton(
                                        tooltip: 'Abort upload',
                                        onPressed: busy
                                            ? null
                                            : () async {
                                                if (!await confirm(
                                                    'Abort this incomplete upload and discard its parts?')) {
                                                  return;
                                                }
                                                await run(() async {
                                                  await call(
                                                      'abortMultipartUpload', {
                                                    'key': upload['Key'],
                                                    'uploadId':
                                                        upload['UploadId']
                                                  });
                                                  uploads.remove(raw);
                                                  notice = 'Upload aborted.';
                                                });
                                              },
                                        icon: const Icon(Icons.delete_outline)),
                                  ]));
                            }),
                          if (cursor?['hasMore'] == true)
                            button(
                                'Load more uploads',
                                () => run(() async {
                                      final r = await call(
                                          'listMultipartUploads',
                                          {'cursor': cursor});
                                      uploads = [
                                        ...uploads,
                                        ...r['items'] as List
                                      ];
                                      cursor = Map<String, Object?>.from(
                                          r['nextCursor'] as Map);
                                    })),
                        ]),
                ]))),
        actions: [
          if (busy)
            TextButton(
                onPressed: () => actionScope?.cancel(),
                child: const Text('Stop')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(busy ? 'Stop and close' : 'Close'))
        ]);
  }
}
