import 'dart:convert';
import 'package:flutter/material.dart';
import '../controllers/action_scope.dart';
import '../controllers/app_controller.dart';
import '../models/azure_admin_presets.dart';
import '../models/domain_models.dart';
import '../services/diagnostic_safety.dart';
import '../services/listing_cancellation.dart';

class AzureAdminDialog extends StatefulWidget {
  const AzureAdminDialog(
      {super.key,
      required this.controller,
      required this.profile,
      required this.bucket,
      this.initialPath = ''});
  final AppController controller;
  final EndpointProfile profile;
  final String bucket, initialPath;
  @override
  State<AzureAdminDialog> createState() => _AzureAdminDialogState();
}

class _AzureAdminDialogState extends State<AzureAdminDialog> {
  final resource = TextEditingController();
  final prefix = TextEditingController();
  final cool = TextEditingController(text: '30');
  final cold = TextEditingController(text: '90');
  final archive = TextEditingController(text: '180');
  final retention = TextEditingController(text: '30');
  final holdTags = TextEditingController();
  late final path = TextEditingController(text: widget.initialPath);
  final destination = TextEditingController();
  final owner = TextEditingController();
  final group = TextEditingController();
  String preset = 'cool';
  bool busy = false,
      lifecycleLoaded = false,
      containerLoaded = false,
      hns = false,
      recursive = false;
  String? error, notice;
  Map<String, Object?>? policy;
  Map<String, Object?> protection = {}, access = {};
  List<Map<String, Object?>> directories = [];
  Map<String, Object?>? cursor;
  List<AdlsAclEntry> entries = [];
  int aclGeneration = 0;
  ActionScope? scope;
  bool get management => widget.profile.connection.authMode == 'azureDefault';

  @override
  void dispose() {
    scope?.cancel();
    for (final controller in [
      resource,
      prefix,
      cool,
      cold,
      archive,
      retention,
      holdTags,
      path,
      destination,
      owner,
      group
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<Map<String, Object?>> call(String action,
      [Map<String, Object?> args = const {}]) {
    if (!mounted) throw const ListingCancelled();
    ActionScope.current?.check();
    return widget.controller
        .storageAction(action, profile: widget.profile, arguments: {
      'bucketName': widget.bucket,
      if (resource.text.trim().isNotEmpty)
        'accountResourceId': resource.text.trim(),
      ...args,
    });
  }

  Future<void> run(Future<void> Function() operation) async {
    if (!mounted || busy) return;
    final active = ActionScope();
    scope = active;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await active.run(operation);
    } on ListingCancelled {
      if (mounted) {
        notice = active.outcomeUnknown
            ? 'Stopped. A dispatched change has an uncertain outcome; inspect the resource before trying again.'
            : 'Stopped.';
      }
    } catch (e) {
      if (mounted) error = DiagnosticSafety.text('$e');
    } finally {
      if (identical(scope, active)) scope = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String message,
      {String action = 'Apply'}) async {
    if (!mounted) return false;
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: Text(title),
                  content: Text(message),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(action)),
                  ],
                )) ??
        false;
  }

  Widget button(String label, Future<void> Function() work,
          {bool enabled = true}) =>
      OutlinedButton(
          onPressed: busy || !enabled ? null : () => run(work),
          child: Text(label));
  Widget field(TextEditingController controller, String label,
          {bool number = false, ValueChanged<String>? changed}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: controller,
            enabled: !busy,
            keyboardType: number ? TextInputType.number : null,
            decoration: InputDecoration(
                labelText: label, border: const OutlineInputBorder()),
            onChanged: changed,
          ));
  int days(TextEditingController value) {
    final result = int.tryParse(value.text.trim());
    if (result == null || result < 1) {
      throw const FormatException('Enter a positive whole number of days.');
    }
    return result;
  }

  Future<void> loadLifecycle() async {
    final value = await call('getAccountLifecycle');
    policy = value['policy'] == null
        ? null
        : Map<String, Object?>.from(value['policy'] as Map);
    lifecycleLoaded = true;
    notice =
        '${(policy?['rules'] as List? ?? const []).length} account lifecycle rules loaded.';
  }

  Future<void> applyLifecycle() async {
    final desired = AzureLifecyclePresets.build(
        currentPolicy: policy,
        preset: preset,
        bucket: widget.bucket,
        prefix: prefix.text,
        coolDays: preset == 'disabled' ? 30 : days(cool),
        coldDays: preset == 'coldArchive' ? days(cold) : 90,
        archiveDays:
            {'archive', 'coldArchive'}.contains(preset) ? days(archive) : 180);
    if (!await confirm(
        'Review Azure lifecycle preset',
        '${AzureLifecyclePresets.choices[preset]} for ${widget.bucket}/${prefix.text}.\n\n'
            'Only this app’s rule for that exact prefix changes. Other account rules are preserved. '
            'Tiering applies to current block blobs and may incur retrieval and minimum-storage charges. '
            'Archive retrieval is asynchronous. Disabling the rule does not reverse earlier tier changes.')) {
      return;
    }
    await call(
        'putAccountLifecycle', {'policy': desired, 'expectedPolicy': policy});
    await loadLifecycle();
    notice = 'Lifecycle preset applied and read back.';
  }

  Future<void> loadContainer() async {
    protection = await call('getContainerProtection');
    containerLoaded = true;
    final configuration = protection['configuration'];
    if (configuration is Map &&
        configuration['immutabilityPeriodSinceCreationInDays'] != null) {
      retention.text =
          '${configuration['immutabilityPeriodSinceCreationInDays']}';
    }
  }

  Future<void> changeContainer(String operation) async {
    final args = <String, Object?>{
      'operation': operation,
      'expectedETag': protection['etag']
    };
    if (operation == 'set' || operation == 'extend') {
      args['days'] = days(retention);
    }
    if (operation == 'setLegalHold' || operation == 'clearLegalHold') {
      final tags = holdTags.text
          .split(',')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toSet()
          .toList();
      if (tags.isEmpty ||
          tags.any((v) => !RegExp(r'^[a-zA-Z0-9]{3,23}$').hasMatch(v))) {
        throw const FormatException(
            'Legal hold tags must be 3–23 letters or digits, separated by commas.');
      }
      args['tags'] = tags;
    }
    final warning = operation == 'lock'
        ? 'Lock this container’s retention policy? Locking is irreversible. Protected objects cannot be deleted until retention expires.'
        : operation == 'extend'
            ? 'Extend the retention period to ${args['days']} days? Locked retention cannot later be shortened.'
            : operation == 'clearLegalHold'
                ? 'Remove the selected legal hold tags? This may allow protected objects to be deleted.'
                : operation == 'delete'
                    ? 'Delete the unlocked retention policy? Azure will reject deletion of a locked policy.'
                    : operation == 'setLegalHold'
                        ? 'Add the selected legal hold tags? Protected objects remain protected until the holds are cleared.'
                        : 'Set container retention to ${args['days']} days? This affects all objects covered by the container policy.';
    if (!await confirm('Review container protection', warning,
        action: operation == 'lock' ? 'Lock retention' : 'Apply')) {
      return;
    }
    protection = await call('setContainerProtection', args);
    notice = 'Container protection updated and read back.';
  }

  Future<void> discoverHns() async {
    final value = await call('getFilesystemInfo');
    hns = value['hnsEnabled'] == true;
    notice = hns
        ? 'Hierarchical namespace is enabled.'
        : '${value['reason'] ?? 'Hierarchical namespace is not enabled.'}';
  }

  Future<void> listPaths({bool more = false}) async {
    final value = await call(
        'listDirectories', {'key': path.text, if (more) 'cursor': cursor});
    final items = (value['items'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList();
    final next = value['cursor'] is Map
        ? Map<String, Object?>.from(value['cursor'] as Map)
        : null;
    if (more &&
        next?['hasMore'] == true &&
        next?['value'] == cursor?['value']) {
      throw StateError('Directory listing did not advance.');
    }
    directories = more ? [...directories, ...items] : items;
    cursor = next;
  }

  Future<void> readAccess() async {
    access = await call('getDirectoryAccess', {'key': path.text});
    entries = AdlsAclEntry.parse('${access['acl'] ?? ''}');
    owner.text = '${access['owner'] ?? ''}';
    group.text = '${access['group'] ?? ''}';
    aclGeneration++;
  }

  Future<void> saveAccess() async {
    final acl = AdlsAclEntry.encodeAll(entries);
    if (!await confirm('Review directory access',
        'Apply these ACL entries and owner/group to ${widget.bucket}/${path.text}? This changes access only for this directory; children are not edited recursively.')) {
      return;
    }
    access = await call('setDirectoryAccess', {
      'key': path.text,
      'acl': acl,
      'expectedETag': access['etag'],
      if (owner.text.trim().isNotEmpty) 'owner': owner.text.trim(),
      if (group.text.trim().isNotEmpty) 'group': group.text.trim(),
    });
    notice = 'Directory access updated.';
  }

  Future<void> changeDirectory(bool rename) async {
    final source = path.text;
    final target = destination.text;
    if (source.isEmpty || (rename && target.isEmpty)) {
      throw const FormatException('Enter the required directory paths.');
    }
    if (!await confirm(
        rename ? 'Rename directory' : 'Delete directory',
        rename
            ? 'Rename $source to $target? The destination must not already exist.'
            : recursive
                ? 'Permanently delete $source and all files and directories beneath it?'
                : 'Delete the empty directory $source?',
        action: rename ? 'Rename' : 'Delete')) {
      return;
    }
    Map<String, Object?>? continuation;
    final seen = <String>{};
    do {
      ActionScope.current?.check();
      final result =
          await call(rename ? 'renameDirectory' : 'deleteDirectory', {
        'key': source,
        'expectedETag': access['etag'],
        if (rename) 'destinationKey': target,
        if (!rename) 'recursive': recursive,
        if (continuation != null) 'cursor': continuation,
      });
      continuation = result['cursor'] is Map
          ? Map<String, Object?>.from(result['cursor'] as Map)
          : null;
      if (continuation?['hasMore'] == true &&
          !seen.add('${continuation?['value']}')) {
        throw StateError('Directory operation did not advance.');
      }
      if (!mounted) return;
    } while (continuation?['hasMore'] == true);
    access = {};
    if (rename) path.text = target;
    notice = rename ? 'Directory renamed.' : 'Directory deleted.';
  }

  Widget aclEntry(int index) {
    final entry = entries[index];
    void update(AdlsAclEntry value) => setState(() => entries[index] = value);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              Row(children: [
                Expanded(
                    child: DropdownButtonFormField<String>(
                        initialValue: entry.type,
                        decoration:
                            const InputDecoration(labelText: 'Entry type'),
                        items: ['user', 'group', 'mask', 'other']
                            .map((v) =>
                                DropdownMenuItem(value: v, child: Text(v)))
                            .toList(),
                        onChanged: busy
                            ? null
                            : (value) => update(entry.copyWith(
                                type: value!,
                                identity: {'mask', 'other'}.contains(value)
                                    ? ''
                                    : entry.identity)))),
                const SizedBox(width: 12),
                Expanded(
                    child: TextFormField(
                        key: ValueKey('$aclGeneration/$index/${entry.type}'),
                        initialValue: entry.identity,
                        enabled:
                            !busy && {'user', 'group'}.contains(entry.type),
                        decoration: const InputDecoration(
                            labelText: 'Object ID (blank = owner/group)'),
                        onChanged: (value) =>
                            update(entry.copyWith(identity: value)))),
                IconButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                              entries.removeAt(index);
                              aclGeneration++;
                            }),
                    tooltip: 'Remove ACL entry',
                    icon: const Icon(Icons.remove_circle_outline)),
              ]),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (var offset = 0; offset < 3; offset++)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Checkbox(
                        value: entry.permissions[offset] != '-',
                        onChanged: busy
                            ? null
                            : (value) {
                                final chars = entry.permissions.split('');
                                chars[offset] = value! ? 'rwx'[offset] : '-';
                                update(
                                    entry.copyWith(permissions: chars.join()));
                              }),
                    Text(['Read', 'Write', 'Execute'][offset]),
                  ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Checkbox(
                      value: entry.isDefault,
                      onChanged: busy
                          ? null
                          : (value) =>
                              update(entry.copyWith(isDefault: value))),
                  const Text('Default for new children')
                ]),
              ]),
            ])));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Azure account and directory administration'),
        content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${widget.profile.name} / ${widget.bucket}'),
                if (busy) const LinearProgressIndicator(),
                if (error != null)
                  SelectableText(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                if (notice != null) SelectableText(notice!),
                if (!management)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          'Account lifecycle and container protection require Azure Default authentication with management permissions. Select that authentication mode in the endpoint profile. Directory operations use the current data credentials.')),
                field(resource, 'Storage account resource ID',
                    changed: (_) => setState(() {
                          lifecycleLoaded = false;
                          containerLoaded = false;
                        })),
                const Text(
                    'Example: /subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Storage/storageAccounts/<account>'),
                ExpansionTile(
                    title: const Text('Lifecycle tiering presets'),
                    children: [
                      button('Load account lifecycle', loadLifecycle,
                          enabled:
                              management && resource.text.trim().isNotEmpty),
                      if (lifecycleLoaded) ...[
                        field(prefix,
                            'Object prefix inside this container (blank = all)'),
                        DropdownButtonFormField<String>(
                            initialValue: preset,
                            decoration: const InputDecoration(
                                labelText: 'Tiering preset'),
                            items: AzureLifecyclePresets.choices.entries
                                .map((entry) => DropdownMenuItem(
                                    value: entry.key, child: Text(entry.value)))
                                .toList(),
                            onChanged: busy
                                ? null
                                : (value) => setState(() => preset = value!)),
                        if (preset != 'disabled')
                          field(cool,
                              'Move to Cool after days since modification',
                              number: true),
                        if (preset == 'coldArchive')
                          field(cold,
                              'Move to Cold after days since modification',
                              number: true),
                        if ({'archive', 'coldArchive'}.contains(preset))
                          field(archive,
                              'Move to Archive after days since modification',
                              number: true),
                        button('Review and apply preset', applyLifecycle),
                        ExpansionTile(
                            title: const Text('Current account rules'),
                            children: [
                              SelectableText(const JsonEncoder.withIndent('  ')
                                  .convert(policy))
                            ]),
                      ],
                    ]),
                ExpansionTile(
                    title: const Text('Container immutability and legal holds'),
                    children: [
                      button('Read container protection', loadContainer,
                          enabled:
                              management && resource.text.trim().isNotEmpty),
                      if (containerLoaded) ...[
                        SelectableText(const JsonEncoder.withIndent('  ')
                            .convert(protection)),
                        field(retention, 'Retention period in days',
                            number: true),
                        Wrap(spacing: 8, children: [
                          button('Set unlocked retention',
                              () => changeContainer('set')),
                          button('Extend locked retention',
                              () => changeContainer('extend'),
                              enabled: protection['configuration'] != null),
                          button('Lock retention permanently',
                              () => changeContainer('lock'),
                              enabled: protection['configuration'] != null),
                          button('Delete unlocked retention',
                              () => changeContainer('delete'),
                              enabled: protection['configuration'] != null),
                        ]),
                        field(holdTags, 'Legal hold tags, separated by commas'),
                        Wrap(spacing: 8, children: [
                          button('Add legal hold tags',
                              () => changeContainer('setLegalHold')),
                          button('Clear legal hold tags',
                              () => changeContainer('clearLegalHold'))
                        ]),
                      ],
                    ]),
                ExpansionTile(
                    title: const Text(
                        'Hierarchical namespace directories and ACLs'),
                    children: [
                      button('Check hierarchical namespace', discoverHns),
                      if (hns) ...[
                        field(path,
                            'Directory path (blank = filesystem root for listing)',
                            changed: (_) => setState(() {
                                  access = {};
                                  cursor = null;
                                  directories = [];
                                })),
                        Wrap(spacing: 8, children: [
                          button('List directory', () => listPaths()),
                          button('Create directory', () async {
                            await call('createDirectory', {'key': path.text});
                            notice = 'Directory created.';
                          }, enabled: path.text.isNotEmpty),
                          button('Read directory access', readAccess,
                              enabled: path.text.isNotEmpty),
                        ]),
                        for (final item in directories)
                          ListTile(
                              dense: true,
                              leading: Icon('${item['isDirectory']}' == 'true'
                                  ? Icons.folder_outlined
                                  : Icons.insert_drive_file_outlined),
                              title: Text('${item['name']}'),
                              subtitle: Text('${item['permissions'] ?? ''}'),
                              onTap: busy || '${item['isDirectory']}' != 'true'
                                  ? null
                                  : () => setState(() {
                                        path.text = '${item['name']}';
                                        access = {};
                                        directories = [];
                                        cursor = null;
                                      })),
                        if (cursor?['hasMore'] == true)
                          button(
                              'Load more paths', () => listPaths(more: true)),
                        if (access.isNotEmpty) ...[
                          field(owner, 'Directory owner object ID'),
                          field(group, 'Directory group object ID'),
                          for (var i = 0; i < entries.length; i++) aclEntry(i),
                          button('Add ACL entry', () async {
                            entries.add(const AdlsAclEntry(type: 'user'));
                            aclGeneration++;
                          }),
                          button('Review and save directory ACL', saveAccess),
                          field(destination, 'Rename destination path'),
                          button(
                              'Rename directory', () => changeDirectory(true)),
                          CheckboxListTile(
                              value: recursive,
                              onChanged: busy
                                  ? null
                                  : (value) =>
                                      setState(() => recursive = value!),
                              title: const Text(
                                  'Include all children when deleting')),
                          button(
                              'Delete directory', () => changeDirectory(false)),
                        ],
                      ],
                    ]),
              ],
            ))),
        actions: [
          if (busy)
            TextButton(
                onPressed: () {
                  scope?.cancel();
                },
                child: const Text('Stop')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(busy ? 'Stop and close' : 'Close')),
        ],
      );
}
