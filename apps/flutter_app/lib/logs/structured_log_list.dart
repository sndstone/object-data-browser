import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/domain_models.dart';

class StructuredLogList extends StatelessWidget {
  const StructuredLogList({
    super.key,
    required this.entries,
    required this.textScalePercent,
    required this.emptyMessage,
    this.embedded = false,
  });

  final List<EventLogEntry> entries;
  final int textScalePercent;
  final String emptyMessage;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final items = _buildItems(entries);
    final scaledChild = MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScalePercent / 100),
      ),
      child: items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(emptyMessage),
            )
          : ListView.separated(
              shrinkWrap: embedded,
              physics: embedded
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = items[index];
                if (item.group != null) {
                  return _ApiTraceCard(group: item.group!);
                }
                return _EventEntryCard(entry: item.entry!);
              },
            ),
    );
    return scaledChild;
  }

  List<_StructuredLogItem> _buildItems(List<EventLogEntry> entries) {
    final items = <_StructuredLogItem>[];
    final groupsByRequestId = <String, _ApiTraceGroup>{};
    for (final entry in entries) {
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
  const _StructuredLogItem.group(this.group) : entry = null;
  const _StructuredLogItem.entry(this.entry) : group = null;

  final _ApiTraceGroup? group;
  final EventLogEntry? entry;
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
    final summaryParts = <String>[
      _formatDateTime(entry.timestamp),
      if ((entry.engineId ?? '').isNotEmpty) entry.engineId!,
      if ((entry.responseStatus ?? '').isNotEmpty)
        'Status ${entry.responseStatus}',
      if (entry.latencyMs != null) '${entry.latencyMs} ms',
    ];
    final contextParts = <String>[
      if ((entry.profileId ?? '').isNotEmpty) 'Profile ${entry.profileId}',
      if ((entry.bucketName ?? '').isNotEmpty) 'Bucket ${entry.bucketName}',
      if ((entry.objectKey ?? '').isNotEmpty) 'Object ${entry.objectKey}',
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(
          entry.method ?? entry.category,
          style: theme.textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text(entry.category)),
                if ((entry.tracePhase ?? '').isNotEmpty &&
                    group.response == null &&
                    group.send == null)
                  Chip(label: Text(entry.tracePhase!)),
                ...summaryParts.map((part) => Chip(label: Text(part))),
              ],
            ),
            if (contextParts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                contextParts.join(' - '),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
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
      ),
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

    final theme = Theme.of(context);
    final contextParts = <String>[
      if ((entry.profileId ?? '').isNotEmpty) 'Profile ${entry.profileId}',
      if ((entry.bucketName ?? '').isNotEmpty) 'Bucket ${entry.bucketName}',
      if ((entry.objectKey ?? '').isNotEmpty) 'Object ${entry.objectKey}',
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '[${entry.level}] ${entry.category}',
                  style: theme.textTheme.titleSmall,
                ),
                Chip(label: Text(_formatDateTime(entry.timestamp))),
              ],
            ),
            if (contextParts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                contextParts.join(' - '),
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            SelectableText(entry.message),
          ],
        ),
      ),
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
    final contextParts = <String>[
      if ((entry.profileId ?? '').isNotEmpty) 'Profile ${entry.profileId}',
      if ((entry.bucketName ?? '').isNotEmpty) 'Bucket ${entry.bucketName}',
      if ((entry.objectKey ?? '').isNotEmpty) 'Object ${entry.objectKey}',
    ];
    final summaryParts = <String>[
      _formatDateTime(entry.timestamp),
      if (parsed.status != null && parsed.status!.isNotEmpty)
        'Status ${parsed.status}',
      if (parsed.method != null && parsed.method!.isNotEmpty) parsed.method!,
      if (entry.latencyMs != null) '${entry.latencyMs} ms',
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(
          parsed.title,
          style: theme.textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text(entry.category)),
                Chip(label: Text(parsed.phaseLabel)),
                ...summaryParts.map((part) => Chip(label: Text(part))),
              ],
            ),
            if (contextParts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                contextParts.join(' - '),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (parsed.url != null && parsed.url!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                parsed.url!,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
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
      ),
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
      child: SelectableText(value),
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

String _formatDateTime(DateTime value) {
  final twoDigitMonth = value.month.toString().padLeft(2, '0');
  final twoDigitDay = value.day.toString().padLeft(2, '0');
  final twoDigitHour = value.hour.toString().padLeft(2, '0');
  final twoDigitMinute = value.minute.toString().padLeft(2, '0');
  final twoDigitSecond = value.second.toString().padLeft(2, '0');
  return '${value.year}-$twoDigitMonth-$twoDigitDay $twoDigitHour:$twoDigitMinute:$twoDigitSecond';
}
