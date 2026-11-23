import 'dart:convert';

import 'conformance_models.dart';

/// Report exports. Built only from bounded result records: no bodies,
/// credentials, presigned URLs or customer keys ever reach these models.
abstract final class ConformanceExport {
  static String json(ConformanceReport report) =>
      const JsonEncoder.withIndent('  ').convert(report.toJson());

  static String markdown(ConformanceReport report, {bool includePassing = false}) {
    final out = StringBuffer()
      ..writeln('# S3 API conformance report')
      ..writeln()
      ..writeln('- Profile: ${_cell(report.profileName)}')
      ..writeln('- Started: ${report.startedAt.toUtc().toIso8601String()}')
      ..writeln('- Base bucket name: `${report.config.baseBucketName}`')
      ..writeln('- Object Lock stage: ${report.config.includeObjectLock ? 'on' : 'off'}'
          '${report.config.includeObjectLock && report.config.includeShortCompliance ? ' (with a 5-second COMPLIANCE check)' : ''}')
      ..writeln();
    out
      ..writeln('## Summary')
      ..writeln()
      ..writeln('| Engine | SDK | Pass | Fail | Deviation | Unsupported | Skipped | Error | Calls | Mean call ms | Teardown |')
      ..writeln('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |');
    for (final engine in report.engines) {
      final counts = engine.counts;
      final mean = engine.callCount == 0 ? 0 : engine.totalCallLatencyMs / engine.callCount;
      final teardown = engine.teardown;
      out.writeln('| ${engine.engineId} | ${_cell(engine.sdk)} | ${counts[ConformanceStatus.pass]} | '
          '${counts[ConformanceStatus.fail]} | ${counts[ConformanceStatus.warn]} | '
          '${counts[ConformanceStatus.unsupported]} | ${counts[ConformanceStatus.skipped]} | '
          '${counts[ConformanceStatus.error]} | ${engine.callCount} | ${mean.toStringAsFixed(1)} | '
          '${teardown == null ? 'not run' : teardown.clean ? 'clean' : 'see notes'} |');
    }
    final discrepancies = report.discrepancies();
    if (report.engines.length > 1) {
      out
        ..writeln()
        ..writeln('## Engine discrepancies')
        ..writeln();
      if (discrepancies.isEmpty) {
        out.writeln('All engines produced the same status for every check.');
      } else {
        out
          ..writeln('| Check | ${report.engines.map((e) => e.engineId).join(' | ')} |')
          ..writeln('| --- |${' --- |' * report.engines.length}');
        for (final id in discrepancies) {
          final cells = [
            for (final engine in report.engines)
              () {
                final check = engine.check(id);
                return check == null ? '—' : '${check.status.label}: ${_cell(check.headline)}';
              }()
          ];
          out.writeln('| `$id` | ${cells.join(' | ')} |');
        }
      }
    }
    for (final engine in report.engines) {
      out
        ..writeln()
        ..writeln('## ${engine.engineId} (${_cell(engine.sdk)})')
        ..writeln()
        ..writeln('- Endpoint: ${_cell(engine.endpoint)}, region ${_cell(engine.region)}, '
            '${engine.pathStyle ? 'path-style' : 'virtual-hosted'} addressing')
        ..writeln('- Client: ${_cell(jsonEncode(engine.client))}')
        ..writeln('- Buckets: ${engine.buckets.values.map((b) => '`$b`').join(', ')}')
        ..writeln('- Status: ${engine.status.name}${engine.note == null ? '' : ' — ${_cell(engine.note!)}'}')
        ..writeln('- Phase 1 gate: ${engine.gatePassed == null ? 'not reached' : engine.gatePassed! ? 'required coverage met (every required check passed or deviated only informationally)' : 'incomplete (a required check failed, errored, was unsupported or was skipped)'}');
      final teardown = engine.teardown;
      if (teardown != null) {
        out.writeln('- Teardown: deleted ${teardown.bucketsDeleted.length} bucket(s), '
            '${teardown.objectsDeleted} object version(s), aborted ${teardown.uploadsAborted} upload(s), '
            'cleared ${teardown.legalHoldsCleared} legal hold(s)'
            '${teardown.bucketsRetained.isEmpty ? '' : '; retained ${teardown.bucketsRetained.join(', ')}'}'
            '${teardown.errors.isEmpty ? '' : '; errors: ${teardown.errors.map(_cell).join('; ')}'}');
      }
      out
        ..writeln()
        ..writeln('| Check | Phase | Severity | Status | Calls | ms | Detail |')
        ..writeln('| --- | --- | --- | --- | ---: | ---: | --- |');
      for (final check in engine.checks) {
        if (!includePassing && check.status == ConformanceStatus.pass) continue;
        out.writeln('| `${check.id}` | ${check.phase.label} | ${check.severity.name} | ${check.status.label} | '
            '${check.calls.length} | ${check.callLatencyMs.toStringAsFixed(1)} | ${_cell(_detail(check))} |');
      }
      if (!includePassing) {
        out
          ..writeln()
          ..writeln('${engine.count(ConformanceStatus.pass)} passing checks are omitted; the JSON export lists every check with per-call latency.');
      }
    }
    return out.toString();
  }

  /// Exports the Check × Engine compatibility matrix as RFC-4180 CSV.
  static String matrixCsv(
    ConformanceReport report, {
    bool onlyDifferences = false,
  }) {
    final out = StringBuffer();
    final header = <String>[
      'check_id',
      'phase',
      'category',
      'severity',
      'title',
      'discrepancy',
      for (final engine in report.engines) ...[
        '${engine.engineId}_status',
        '${engine.engineId}_calls',
        '${engine.engineId}_latency_ms',
        '${engine.engineId}_detail',
      ],
    ];
    out.writeln(header.map(_csvCell).join(','));
    final diffSet = report.discrepancies().toSet();
    final ids = onlyDifferences
        ? report.checkIds().where(diffSet.contains).toList()
        : report.checkIds();
    for (final id in ids) {
      final sample = report.sampleCheck(id)!;
      final row = <String>[
        id,
        sample.phase.label,
        sample.category,
        sample.severity.name,
        sample.title,
        diffSet.contains(id) ? 'true' : 'false',
        for (final engine in report.engines) ...() {
          final check = engine.check(id);
          if (check == null) return const ['not_run', '0', '', ''];
          return [
            check.status.label,
            '${check.calls.length}',
            check.callLatencyMs.toStringAsFixed(1),
            check.status == ConformanceStatus.pass
                ? check.headline
                : _detail(check),
          ];
        }(),
      ];
      out.writeln(row.map(_csvCell).join(','));
    }
    return out.toString();
  }

  /// Exports a standalone Compatibility Matrix Markdown report (summary table +
  /// full Check × Engine matrix, or differences only).
  static String matrixMarkdown(
    ConformanceReport report, {
    bool onlyDifferences = false,
  }) {
    final out = StringBuffer()
      ..writeln('# S3 API compatibility matrix')
      ..writeln()
      ..writeln('- Profile: ${_cell(report.profileName)}')
      ..writeln('- Started: ${report.startedAt.toUtc().toIso8601String()}')
      ..writeln(
          '- Engines: ${report.engines.map((e) => '${e.engineId} (${_cell(e.sdk)})').join(', ')}')
      ..writeln('- Base bucket name: `${report.config.baseBucketName}`')
      ..writeln(
          '- Object Lock stage: ${report.config.includeObjectLock ? 'on' : 'off'}'
          '${report.config.includeObjectLock && report.config.includeShortCompliance ? ' (with a 5-second COMPLIANCE check)' : ''}')
      ..writeln();
    out
      ..writeln('## Engine summary')
      ..writeln()
      ..writeln(
          '| Engine | SDK | Phase 1 gate | Pass | Fail | Deviation | Unsupported | Skipped | Error | Calls | Mean ms | p50 ms | p95 ms | Teardown |')
      ..writeln(
          '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |');
    for (final engine in report.engines) {
      final counts = engine.counts;
      final p50 = engine.percentileCallLatencyMs(50);
      final p95 = engine.percentileCallLatencyMs(95);
      final gate = engine.gatePassed == null
          ? 'not reached'
          : engine.gatePassed!
              ? 'met'
              : 'incomplete';
      final teardown = engine.teardown;
      out.writeln('| ${engine.engineId} | ${_cell(engine.sdk)} | $gate | '
          '${counts[ConformanceStatus.pass]} | ${counts[ConformanceStatus.fail]} | '
          '${counts[ConformanceStatus.warn]} | ${counts[ConformanceStatus.unsupported]} | '
          '${counts[ConformanceStatus.skipped]} | ${counts[ConformanceStatus.error]} | '
          '${engine.callCount} | ${engine.meanCallLatencyMs.toStringAsFixed(1)} | '
          '${p50 == null ? '—' : p50.toStringAsFixed(1)} | '
          '${p95 == null ? '—' : p95.toStringAsFixed(1)} | '
          '${teardown == null ? (engine.status == ConformanceRunStatus.running ? 'running' : 'not run') : teardown.clean ? 'clean' : 'see notes'} |');
    }

    final diffSet = report.discrepancies().toSet();
    final ids = onlyDifferences
        ? report.checkIds().where(diffSet.contains).toList()
        : report.checkIds();
    out
      ..writeln()
      ..writeln(onlyDifferences
          ? '## Engine discrepancies (${ids.length})'
          : '## Compatibility matrix (${ids.length} checks)')
      ..writeln();
    if (ids.isEmpty) {
      out.writeln(onlyDifferences
          ? 'All engines produced the same status for every check.'
          : 'No checks recorded.');
    } else {
      out
        ..writeln(
            '| Check | Phase | Severity | ${report.engines.map((e) => e.engineId).join(' | ')} |')
        ..writeln('| --- | --- | --- |${' --- |' * report.engines.length}');
      for (final id in ids) {
        final sample = report.sampleCheck(id)!;
        final cells = [
          for (final engine in report.engines)
            () {
              final check = engine.check(id);
              if (check == null) return '—';
              final latency = '${check.callLatencyMs.toStringAsFixed(1)} ms';
              if (check.status == ConformanceStatus.pass) {
                return '${check.status.label} ($latency)';
              }
              return '${check.status.label} ($latency): ${_cell(check.headline)}';
            }()
        ];
        out.writeln(
            '| `$id` | ${sample.phase.label} | ${sample.severity.name} | ${cells.join(' | ')} |');
      }
    }
    if (!onlyDifferences && report.engines.length > 1) {
      out
        ..writeln()
        ..writeln('## Cross-engine discrepancies')
        ..writeln();
      if (diffSet.isEmpty) {
        out.writeln('All engines produced the same status for every check.');
      } else {
        out.writeln(
            '${diffSet.length} check(s) differed across engines: ${diffSet.map((id) => '`$id`').join(', ')}.');
      }
    }
    return out.toString();
  }

  static String _detail(ConformanceCheckResult check) {
    final mismatches = check.mismatches.take(3).map((m) =>
        '${m.field}: expected ${m.expected}, got ${m.actual}${m.explanation == null ? '' : ' (${m.explanation})'}');
    final parts = [
      if (check.note != null) check.note!,
      ...mismatches,
    ];
    return parts.isEmpty ? check.title : parts.join('; ');
  }

  static String _cell(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', ' ').replaceAll('\r', ' ');

  static String _csvCell(String value) {
    final normalized = value.replaceAll('\r\n', ' ').replaceAll('\n', ' ').replaceAll('\r', ' ');
    if (normalized.contains(',') || normalized.contains('"')) {
      return '"${normalized.replaceAll('"', '""')}"';
    }
    return normalized;
  }
}
