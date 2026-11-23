// Headless S3 API conformance runner (desktop engines only).
//
//   dart run tool/s3_conformance.dart \
//     --profile /path/to/profile.json \
//     --engine 'python=/path/python3 ../../engines/python/src/main.py' \
//     --engine 'go=/path/to/s3-browser-go-engine' \
//     --base odb-conf --out /tmp/conformance
//
// The profile file holds an endpoint profile as sent to engines
// (endpointType, endpointUrl, region, accessKey, secretKey, pathStyle, ...).
// Credentials go to the engine process only; they are never printed and never
// written to the report.
import 'dart:convert';
import 'dart:io';

import 'package:s3_browser_crossplat/conformance/conformance_export.dart';
import 'package:s3_browser_crossplat/conformance/conformance_models.dart';
import 'package:s3_browser_crossplat/conformance/conformance_suite.dart';
import 'package:s3_browser_crossplat/conformance/process_s3_op_executor.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final profilePath = options['profile']?.single;
  final engines = options['engine'] ?? const [];
  if (profilePath == null || engines.isEmpty) {
    stderr.writeln('Usage: --profile <file> --engine <id=command> [--engine ...] '
        '[--base name] [--out dir] [--no-lock] [--no-compliance] [--no-ssec] [--retain]');
    exitCode = 64;
    return;
  }
  final profile = Map<String, Object?>.from(
      jsonDecode(await File(profilePath).readAsString()) as Map);
  final config = ConformanceConfig(
    baseBucketName: options['base']?.single ?? 'odb-conformance',
    engineIds: [for (final e in engines) e.split('=').first],
    includeObjectLock: !options.containsKey('no-lock'),
    includeShortCompliance: !options.containsKey('no-compliance'),
    includeSseC: !options.containsKey('no-ssec'),
    retainBucketsOnFailure: options.containsKey('retain'),
  );
  final invalid = ConformanceConfig.validateBaseName(config.baseBucketName);
  if (invalid != null) {
    stderr.writeln(invalid);
    exitCode = 64;
    return;
  }
  final endpoint = ConformanceEndpoint(
    endpointUrl: '${profile['endpointUrl'] ?? ''}',
    region: '${profile['region'] ?? 'us-east-1'}',
    pathStyle: profile['pathStyle'] == true,
    endpointType: '${profile['endpointType'] ?? 's3Compatible'}',
  );
  final report = ConformanceReport(
    id: DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36),
    config: config,
    profileName: '${profile['name'] ?? endpoint.displayHost}',
    startedAt: DateTime.now(),
  );
  for (final spec in engines) {
    final split = spec.indexOf('=');
    final id = spec.substring(0, split);
    final command = spec.substring(split + 1).split(' ').where((p) => p.isNotEmpty).toList();
    stdout.writeln('== $id');
    final executor = await ProcessS3OpExecutor.start(
      engineId: id,
      executable: command.first,
      arguments: command.skip(1).toList(),
      profile: profile,
    );
    try {
      final run = await S3ConformanceSuite(
        executor: executor,
        config: config,
        endpoint: endpoint,
        onProgress: (progress) {
          final result = progress.lastResult;
          if (result != null && result.status != ConformanceStatus.pass) {
            stdout.writeln('  ${result.status.label.padRight(11)} ${result.id}  ${result.headline}');
          }
        },
      ).run();
      report.engines.add(run);
      final counts = run.counts;
      stdout.writeln('  -> ${counts.entries.map((e) => '${e.key.name}=${e.value}').join(' ')} '
          'calls=${run.callCount} teardown=${run.teardown?.clean == true ? 'clean' : 'see report'}');
    } finally {
      await executor.close();
    }
  }
  report.finishedAt = DateTime.now();
  final out = Directory(options['out']?.single ?? '.');
  await out.create(recursive: true);
  await File('${out.path}/s3-conformance-report.json').writeAsString(ConformanceExport.json(report));
  await File('${out.path}/s3-conformance-report.md').writeAsString(ConformanceExport.markdown(report));
  stdout.writeln('Reports written to ${out.path}');
}

Map<String, List<String>> _parse(List<String> args) {
  final result = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final name = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      result.putIfAbsent(name, () => []).add(args[++i]);
    } else {
      result.putIfAbsent(name, () => []);
    }
  }
  return result;
}
