import '../utils/format.dart';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/domain_models.dart';
import '../widgets/empty_state.dart';

class StructuredLogList extends StatefulWidget {
  const StructuredLogList({
    super.key,
    required this.entries,
    required this.textScalePercent,
    required this.emptyMessage,
    this.embedded = false,
    this.profileNames = const {},
  });

  final List<EventLogEntry> entries;
  final int textScalePercent;
  final String emptyMessage;
  final bool embedded;

  /// Profile display names by ID, so context lines name the connection the
  /// user recognizes instead of its internal identifier.
  final Map<String, String> profileNames;

  @override
  State<StructuredLogList> createState() => _StructuredLogListState();
}

class _StructuredLogListState extends State<StructuredLogList> {
  List<EventLogEntry>? _cachedEntries;
  List<_StructuredLogItem>? _cachedItems;

  List<_StructuredLogItem> _itemsFor(List<EventLogEntry> entries) {
    final cached = _cachedItems;
    if (cached != null &&
        identical(_cachedEntries, entries) &&
        _cachedEntries!.length == entries.length) {
      return cached;
    }
    final items = _buildItems(entries);
    _cachedEntries = entries;
    _cachedItems = items;
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _itemsFor(widget.entries);
    final scaledChild = MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(widget.textScalePercent / 100),
      ),
      child: items.isEmpty
          ? widget.embedded
              // Embedded lists sit inside another scroll view; keep the
              // empty notice compact and left-aligned with surrounding text.
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    Icon(Icons.receipt_long_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(widget.emptyMessage,
                            style: Theme.of(context).textTheme.bodySmall)),
                  ]),
                )
              : EmptyState(
                  icon: Icons.manage_search_outlined,
                  title: widget.emptyMessage)
          : ListView.separated(
              shrinkWrap: widget.embedded,
              physics: widget.embedded
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return _ProfileNames(
                  names: widget.profileNames,
                  child: item.upload != null
                      ? _UploadBatchCard(entries: item.upload!)
                      : item.group != null
                          ? _ApiTraceCard(group: item.group!)
                          : _EventEntryCard(entry: item.entry!),
                );
              },
            ),
    );
    return scaledChild;
  }

  List<_StructuredLogItem> _buildItems(List<EventLogEntry> entries) {
    final items = <_StructuredLogItem>[];
    final groupsByRequestId = <String, _ApiTraceGroup>{};
    final uploads = <String, List<EventLogEntry>>{};
    for (final entry in entries) {
      final uploadId = entry.parentRequestId ??
          (entry.source == 'upload-batch' ? entry.requestId : null);
      if (uploadId != null) {
        if (!uploads.containsKey(uploadId)) {
          uploads[uploadId] = [];
          items.add(_StructuredLogItem.upload(uploads[uploadId]!));
        }
        uploads[uploadId]!.add(entry);
        continue;
      }
      if (_isStructuredApiEntry(entry)) {
        final requestId = entry.requestId!;
        final existing = groupsByRequestId[requestId];
        if (existing != null) {
          existing.add(entry);
          continue;
        }
        final group = _ApiTraceGroup(requestId: requestId)..add(entry);
        groupsByRequestId[requestId] = group;
        items.add(_StructuredLogItem.group(group));
        continue;
      }
      items.add(_StructuredLogItem.entry(entry));
    }
    return items;
  }

  bool _isStructuredApiEntry(EventLogEntry entry) {
    return (entry.level == 'API' || entry.source == 'api') &&
        (entry.requestId?.isNotEmpty ?? false);
  }
}

class _StructuredLogItem {
  const _StructuredLogItem.group(this.group)
      : entry = null,
        upload = null;
  const _StructuredLogItem.entry(this.entry)
      : group = null,
        upload = null;
  const _StructuredLogItem.upload(this.upload)
      : group = null,
        entry = null;

  final _ApiTraceGroup? group;
  final EventLogEntry? entry;
  final List<EventLogEntry>? upload;
}

class _UploadBatchCard extends StatelessWidget {
  const _UploadBatchCard({required this.entries});
  final List<EventLogEntry> entries;
  @override
  Widget build(BuildContext context) {
    final parents = entries.where((e) => e.source == 'upload-batch');
    final parent = parents.isEmpty ? entries.first : parents.first;
    final files = <String, List<EventLogEntry>>{};
    for (final entry in entries.where((e) => e.source == 'upload-file')) {
      files.putIfAbsent(entry.requestId!, () => []).add(entry);
    }
    return Card(
        child: ExpansionTile(
      key: PageStorageKey(
          'upload-log-${parent.parentRequestId ?? parent.requestId}'),
      leading: const Icon(Icons.upload_file),
      title: Text(parents.isEmpty ? 'Upload batch' : parent.message),
      subtitle: Text([
        if ((parent.bucketName ?? '').isNotEmpty) parent.bucketName!,
        parent.responseStatus ?? 'running',
        files.length == 1 ? '1 file' : '${files.length} files',
      ].join(' · ')),
      children: [
        for (final group in files.values)
          ExpansionTile(
            key: PageStorageKey('upload-file-${group.first.requestId}'),
            leading: group.first.responseStatus == 'failed'
                ? Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error)
                : Icon(group.first.responseStatus == 'completed'
                    ? Icons.check_circle_outline
                    : Icons.insert_drive_file_outlined),
            title: Text(group.first.objectKey ?? 'File'),
            subtitle: Text(group.first.responseStatus ?? ''),
            children: [
              for (final entry in group.reversed)
                Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: _EventEntryCard(entry: entry))
            ],
          ),
      ],
    ));
  }
}

class _ApiTraceGroup {
  _ApiTraceGroup({required this.requestId});

  final String requestId;
  final List<EventLogEntry> rawEntries = <EventLogEntry>[];
  EventLogEntry? send;
  EventLogEntry? response;

  void add(EventLogEntry entry) {
    rawEntries.add(entry);
    switch (entry.tracePhase) {
      case 'send':
        send ??= entry;
        break;
      case 'response':
        response ??= entry;
        break;
      default:
        break;
    }
  }

  EventLogEntry get displayEntry => response ?? send ?? rawEntries.first;

  Iterable<EventLogEntry> get orderedRawEntries sync* {
    if (send != null) {
      yield send!;
    }
    if (response != null) {
      yield response!;
    }
    for (final entry in rawEntries) {
      if (entry == send || entry == response) {
        continue;
      }
      yield entry;
    }
  }
}

class _ApiTraceCard extends StatelessWidget {
  const _ApiTraceCard({required this.group});

  final _ApiTraceGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = group.displayEntry;
    final detail = <String>[
      if ((entry.responseStatus ?? '').isNotEmpty) entry.responseStatus!,
      if (entry.latencyMs != null) '${entry.latencyMs} ms',
      if ((entry.engineId ?? '').isNotEmpty) entry.engineId!,
      if ((entry.tracePhase ?? '').isNotEmpty &&
          group.response == null &&
          group.send == null)
        entry.tracePhase!,
    ];

    return _ExpandableLogRow(
      entry: entry,
      category: entry.category,
      title: entry.method ?? entry.category,
      detail: detail.join(' · '),
      children: [
        _TracePayloadSection(
          title: 'Send',
          entry: group.send,
          emptyLabel: 'No request payload recorded.',
        ),
        const SizedBox(height: 12),
        _TracePayloadSection(
          title: 'Response',
          entry: group.response,
          emptyLabel: 'No response payload recorded.',
        ),
        const SizedBox(height: 12),
        Text('Raw event text', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _CodeBlock(
          value: group.orderedRawEntries
              .map((entry) => '[${entry.level}] ${entry.message}')
              .join('\n\n'),
        ),
      ],
    );
  }
}

class _TracePayloadSection extends StatelessWidget {
  const _TracePayloadSection({
    required this.title,
    required this.entry,
    required this.emptyLabel,
  });

  final String title;
  final EventLogEntry? entry;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedEntry = entry;
    if (resolvedEntry == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(emptyLabel, style: theme.textTheme.bodySmall),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (resolvedEntry.traceHead != null) ...[
          Text('Head', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _CodeBlock(value: _prettyJson(resolvedEntry.traceHead)),
          const SizedBox(height: 10),
        ],
        Text('Body', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        _CodeBlock(value: _prettyJson(resolvedEntry.traceBody)),
      ],
    );
  }
}

class _EventEntryCard extends StatelessWidget {
  const _EventEntryCard({required this.entry});

  final EventLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final parsedApi = _parseRawApiMessage(entry);
    if (parsedApi != null) {
      return _ParsedApiEntryCard(
        entry: entry,
        parsed: parsedApi,
      );
    }
    return _LogRow(
      entry: entry,
      category: entry.category,
      message: SelectableText(entry.message,
          key: PageStorageKey(
              'event-text-${entry.requestId}-${entry.timestamp.microsecondsSinceEpoch}-${entry.message.hashCode}')),
    );
  }
}

class _ParsedApiEntryCard extends StatelessWidget {
  const _ParsedApiEntryCard({
    required this.entry,
    required this.parsed,
  });

  final EventLogEntry entry;
  final _ParsedApiMessage parsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = <String>[
      parsed.phaseLabel,
      if (parsed.status != null && parsed.status!.isNotEmpty) parsed.status!,
      if (parsed.method != null &&
          parsed.method!.isNotEmpty &&
          parsed.method != parsed.title)
        parsed.method!,
      if (entry.latencyMs != null) '${entry.latencyMs} ms',
    ];

    return _ExpandableLogRow(
      entry: entry,
      category: entry.category,
      title: parsed.title,
      detail: detail.join(' · '),
      extraContext: parsed.url,
      children: [
        if (parsed.headers != null) ...[
          Text('Headers', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _CodeBlock(value: _prettyJson(parsed.headers)),
          const SizedBox(height: 12),
        ],
        Text('Body', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _CodeBlock(value: _prettyJson(parsed.body)),
        const SizedBox(height: 12),
        Text('Raw event text', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _CodeBlock(value: entry.message),
      ],
    );
  }
}

/// Supplies profile display names to log rows below it.
class _ProfileNames extends InheritedWidget {
  const _ProfileNames({required this.names, required super.child});
  final Map<String, String> names;

  static Map<String, String> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ProfileNames>()?.names ??
      const {};

  @override
  bool updateShouldNotify(_ProfileNames oldWidget) => oldWidget.names != names;
}

String _contextLine(BuildContext context, EventLogEntry entry) {
  final profileId = entry.profileId ?? '';
  return [
    if (profileId.isNotEmpty) _ProfileNames.of(context)[profileId] ?? profileId,
    if ((entry.bucketName ?? '').isNotEmpty) entry.bucketName!,
    if ((entry.objectKey ?? '').isNotEmpty) entry.objectKey!,
  ].join(' · ');
}

String _clockTime(DateTime value) => [value.hour, value.minute, value.second]
    .map((part) => part.toString().padLeft(2, '0'))
    .join(':');

/// Severity colors separate from the accent so errors read at a glance.
(Color, Color) _levelColors(ColorScheme scheme, String level) =>
    switch (level.toUpperCase()) {
      'ERROR' => (scheme.errorContainer, scheme.onErrorContainer),
      'WARN' || 'WARNING' => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer
        ),
      'API' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'DEBUG' => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      _ => (scheme.secondaryContainer, scheme.onSecondaryContainer),
    };

class _LevelPill extends StatelessWidget {
  const _LevelPill({required this.level});
  final String level;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = _levelColors(theme.colorScheme, level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: background, borderRadius: BorderRadius.circular(4)),
      child: Text(level.toUpperCase(),
          maxLines: 1,
          style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
              letterSpacing: .3)),
    );
  }
}

/// One dense log line: time, level, category, then the message with its
/// profile/bucket/object context underneath.
class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.entry,
    required this.category,
    required this.message,
    this.extraContext,
  });

  final EventLogEntry entry;
  final String category;
  final Widget message;
  final String? extraContext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final contextLine = _contextLine(context, entry);
    final isError = entry.level.toUpperCase() == 'ERROR';
    return Container(
      color: isError
          ? theme.colorScheme.errorContainer.withValues(alpha: .28)
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final meta = [
          Tooltip(
            message: formatDateTime(entry.timestamp),
            child: SizedBox(
              width: 68,
              child: Text(_clockTime(entry.timestamp),
                  style: muted?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ),
          SizedBox(
              width: 64,
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: _LevelPill(level: entry.level))),
          SizedBox(
            width: narrow ? null : 110,
            child: Text(category,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
          ),
        ];
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DefaultTextStyle.merge(
                style: theme.textTheme.bodyMedium, child: message),
            if (contextLine.isNotEmpty)
              Text(contextLine,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
            if ((extraContext ?? '').isNotEmpty)
              Text(extraContext!,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
          ],
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: meta),
              const SizedBox(height: 4),
              body,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...meta.map((m) => Padding(
                padding: const EdgeInsets.only(right: 8, top: 1), child: m)),
            Expanded(child: body),
          ],
        );
      }),
    );
  }
}

/// A [_LogRow] that expands to show trace payloads.
class _ExpandableLogRow extends StatefulWidget {
  const _ExpandableLogRow({
    required this.entry,
    required this.category,
    required this.title,
    required this.children,
    this.detail = '',
    this.extraContext,
  });

  final EventLogEntry entry;
  final String category;
  final String title;
  final String detail;
  final String? extraContext;
  final List<Widget> children;

  @override
  State<_ExpandableLogRow> createState() => _ExpandableLogRowState();
}

class _ExpandableLogRowState extends State<_ExpandableLogRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Expose the disclosure state so screen readers announce whether
        // the trace payload is showing; InkWell already handles focus and
        // Enter/Space activation.
        Semantics(
            button: true,
            expanded: _expanded,
            onTapHint: _expanded ? 'Hide details' : 'Show details',
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(children: [
                Expanded(
                  child: _LogRow(
                    entry: widget.entry,
                    category: widget.category,
                    extraContext: widget.extraContext,
                    message: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(widget.title,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        if (widget.detail.isNotEmpty)
                          Text(widget.detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ]),
            )),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}

class _ParsedApiMessage {
  const _ParsedApiMessage({
    required this.title,
    required this.phaseLabel,
    this.method,
    this.url,
    this.status,
    this.headers,
    this.body,
  });

  final String title;
  final String phaseLabel;
  final String? method;
  final String? url;
  final String? status;
  final Object? headers;
  final Object? body;
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: SelectableText(value,
          key: PageStorageKey('code-text-${value.hashCode}')),
    );
  }
}

String _prettyJson(Object? value) {
  const encoder = JsonEncoder.withIndent('  ');
  if (value == null) {
    return 'null';
  }
  try {
    return encoder.convert(value);
  } catch (_) {
    return value.toString();
  }
}

_ParsedApiMessage? _parseRawApiMessage(EventLogEntry entry) {
  final message = entry.message.trim();
  final headersIndex = message.indexOf(' HEADERS=');
  final bodyIndex = message.indexOf(' BODY=');
  if (headersIndex == -1 || bodyIndex == -1 || bodyIndex < headersIndex) {
    return null;
  }

  final prefix = message.substring(0, headersIndex).trim();
  final headersRaw = message.substring(headersIndex + 9, bodyIndex).trim();
  final bodyRaw = message.substring(bodyIndex + 6).trim();

  if (prefix.startsWith('SEND ')) {
    final sendParts = prefix.substring(5).trim();
    final splitIndex = sendParts.indexOf(' ');
    final method =
        splitIndex == -1 ? sendParts : sendParts.substring(0, splitIndex);
    final url =
        splitIndex == -1 ? null : sendParts.substring(splitIndex + 1).trim();
    return _ParsedApiMessage(
      title: method.isEmpty ? entry.category : method,
      phaseLabel: 'Send',
      method: method.isEmpty ? null : method,
      url: url,
      headers: _decodeTraceValue(headersRaw),
      body: _decodeTraceValue(bodyRaw),
    );
  }

  if (prefix.startsWith('RECV ')) {
    final receiveParts = prefix.substring(5).trim();
    final statusMatch = RegExp(r'STATUS=([^ ]+)').firstMatch(receiveParts);
    final status = statusMatch?.group(1);
    final operation = statusMatch == null
        ? receiveParts
        : receiveParts.substring(0, statusMatch.start).trim();
    return _ParsedApiMessage(
      title: operation.isEmpty ? entry.category : operation,
      phaseLabel: 'Response',
      status: status,
      headers: _decodeTraceValue(headersRaw),
      body: _decodeTraceValue(bodyRaw),
    );
  }

  return null;
}

Object? _decodeTraceValue(String raw) {
  if (raw.isEmpty) {
    return '';
  }
  final trimmed = raw.trim();
  if (trimmed == 'null') {
    return null;
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return trimmed;
    }
  }
  return trimmed;
}
