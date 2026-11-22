part of 'conformance_suite.dart';

extension _Teardown on S3ConformanceSuite {
  Future<void> _teardownPhase() async {
    final failures = _run.checks.any((check) =>
        check.status == ConformanceStatus.fail || check.status == ConformanceStatus.error);
    final retain = config.retainBucketsOnFailure && failures;
    final deleted = <String>[];
    final retained = <String>[];
    final errors = <String>[];
    var objects = 0;
    var uploads = 0;
    var holds = 0;
    var leftovers = 0;
    // Lock bucket first: its protections are the slowest to clear.
    final order = [
      ..._ownedBuckets.where((b) => b == _lockBucket),
      ..._ownedBuckets.where((b) => b != _lockBucket),
    ];
    for (final bucket in order.toSet()) {
      final exists = await _quiet('HeadBucket', {'Bucket': bucket});
      if (exists == null || exists.httpStatus == 404 || exists.httpStatus == 400) {
        // Never created (or an invalid name the endpoint refused).
        continue;
      }
      uploads += await _abortUploads(bucket, errors);
      if (bucket == _lockBucket) holds += await _releaseHolds(bucket, errors);
      if (retain) {
        retained.add(bucket);
        continue;
      }
      if (bucket == _lockBucket && _complianceUntil != null) {
        await _waitUntilServer(_complianceUntil!, max: const Duration(seconds: 20));
      }
      final purge = await _purge(bucket, bypass: bucket == _lockBucket, errors: errors);
      objects += purge.$1;
      leftovers += purge.$2;
      final delete = await _quiet('DeleteBucket', {'Bucket': bucket});
      if (delete != null && delete.isSuccess) {
        deleted.add(bucket);
      } else {
        retained.add(bucket);
        errors.add('DeleteBucket $bucket: ${delete == null ? 'engine error' : _CheckContext.describe(delete)}');
      }
    }
    _run.teardown = ConformanceTeardownReport(
      bucketsDeleted: deleted,
      bucketsRetained: retained,
      objectsDeleted: objects,
      uploadsAborted: uploads,
      legalHoldsCleared: holds,
      leftovers: leftovers,
      errors: [for (final error in errors.take(20)) conformanceClip(error, 200)],
    );
    await _check('teardown.complete',
        category: 'Teardown',
        title: retain ? 'Buckets retained for inspection (failures and "retain buckets" on)' : 'Every test bucket was emptied and deleted',
        spec: 'Abort uploads, clear legal holds, delete every version and delete marker (bypassing GOVERNANCE), then DeleteBucket: 204.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      if (retain) {
        c.note('Retained: ${retained.join(', ')}. Delete them when finished.');
        return;
      }
      c.equals('buckets retained', 0, retained.length,
          explanation: retained.isEmpty ? null : 'Not deleted: ${retained.join(', ')}');
      c.equals('teardown errors', 0, errors.length,
          explanation: errors.isEmpty ? null : conformanceClip(errors.first, 160));
    });
  }

  Future<int> _abortUploads(String bucket, List<String> errors) async {
    var aborted = 0;
    Object? keyMarker;
    Object? uploadMarker;
    for (var page = 0; page < 20; page++) {
      final list = await _quiet('ListMultipartUploads', {
        'Bucket': bucket,
        if (keyMarker != null) 'KeyMarker': keyMarker,
        if (uploadMarker != null) 'UploadIdMarker': uploadMarker,
      });
      if (list == null || !list.isSuccess) break;
      for (final upload in list.list('Uploads')) {
        final o = await _quiet('AbortMultipartUpload',
            {'Bucket': bucket, 'Key': upload['Key'], 'UploadId': upload['UploadId']});
        if (o != null && (o.isSuccess || o.httpStatus == 404)) {
          aborted++;
        } else {
          errors.add('AbortMultipartUpload ${upload['Key']}: ${o == null ? 'engine error' : _CheckContext.describe(o)}');
        }
      }
      if (list.field('IsTruncated') != true) break;
      keyMarker = list.field('NextKeyMarker');
      uploadMarker = list.field('NextUploadIdMarker');
    }
    return aborted;
  }

  Future<int> _releaseHolds(String bucket, List<String> errors) async {
    var released = 0;
    for (final version in await _allVersions(bucket)) {
      if (version.$3) continue; // delete markers carry no hold
      final hold = await _quiet('GetObjectLegalHold', {'Bucket': bucket, 'Key': version.$1, 'VersionId': version.$2});
      if (hold == null || hold.field('LegalHold.Status') != 'ON') continue;
      final off = await _quiet('PutObjectLegalHold',
          {'Bucket': bucket, 'Key': version.$1, 'VersionId': version.$2, 'LegalHold': {'Status': 'OFF'}});
      if (off != null && off.isSuccess) {
        released++;
      } else {
        errors.add('PutObjectLegalHold OFF ${version.$1}: ${off == null ? 'engine error' : _CheckContext.describe(off)}');
      }
    }
    return released;
  }

  /// (key, versionId, isDeleteMarker) for every version, or the keys of an
  /// endpoint without ListObjectVersions.
  Future<List<(String, String?, bool)>> _allVersions(String bucket) async {
    final result = <(String, String?, bool)>[];
    Object? keyMarker;
    Object? versionMarker;
    for (var page = 0; page < 200; page++) {
      final list = await _quiet('ListObjectVersions', {
        'Bucket': bucket,
        if (keyMarker != null) 'KeyMarker': keyMarker,
        if (versionMarker != null) 'VersionIdMarker': versionMarker,
      });
      if (list == null || !list.isSuccess) {
        return _allKeys(bucket);
      }
      for (final v in list.list('Versions')) {
        result.add(('${v['Key']}', v['VersionId']?.toString(), false));
      }
      for (final m in list.list('DeleteMarkers')) {
        result.add(('${m['Key']}', m['VersionId']?.toString(), true));
      }
      if (list.field('IsTruncated') != true) break;
      keyMarker = list.field('NextKeyMarker');
      versionMarker = list.field('NextVersionIdMarker');
    }
    return result;
  }

  Future<List<(String, String?, bool)>> _allKeys(String bucket) async {
    final result = <(String, String?, bool)>[];
    Object? token;
    for (var page = 0; page < 200; page++) {
      final list = await _quiet('ListObjectsV2', {
        'Bucket': bucket,
        if (token != null) 'ContinuationToken': token,
      });
      if (list == null || !list.isSuccess) break;
      for (final item in list.list('Contents')) {
        result.add(('${item['Key']}', null, false));
      }
      token = list.field('NextContinuationToken');
      if (list.field('IsTruncated') != true || token == null) break;
    }
    return result;
  }

  /// Deletes every version and marker; returns (deleted, left over).
  Future<(int, int)> _purge(String bucket,
      {required bool bypass, required List<String> errors}) async {
    var deleted = 0;
    var remaining = 0;
    for (var sweep = 0; sweep < 5; sweep++) {
      final versions = await _allVersions(bucket);
      remaining = versions.length;
      if (versions.isEmpty) break;
      for (var start = 0; start < versions.length; start += 500) {
        final batch = versions.skip(start).take(500).toList();
        final o = await _quiet('DeleteObjects', {
          'Bucket': bucket,
          if (bypass) 'BypassGovernanceRetention': true,
          'Delete': {
            'Objects': [
              for (final v in batch) {'Key': v.$1, if (v.$2 != null) 'VersionId': v.$2}
            ],
            'Quiet': true,
          },
        });
        final failed = <String>{};
        if (o != null && o.isSuccess) {
          for (final error in o.list('Errors')) {
            failed.add('${error['Key']}\u0000${error['VersionId'] ?? ''}');
          }
          deleted += batch.length - failed.length;
        }
        // Per-object fallback for an endpoint without DeleteObjects or
        // without batch governance bypass.
        for (final v in batch) {
          if (o != null && o.isSuccess && !failed.contains('${v.$1}\u0000${v.$2 ?? ''}')) continue;
          final single = await _quiet('DeleteObject', {
            'Bucket': bucket,
            'Key': v.$1,
            if (v.$2 != null) 'VersionId': v.$2,
            if (bypass) 'BypassGovernanceRetention': true,
          });
          if (single != null && single.isSuccess) {
            deleted++;
          } else if (sweep == 4) {
            errors.add('DeleteObject ${v.$1}: ${single == null ? 'engine error' : _CheckContext.describe(single)}');
          }
        }
      }
    }
    final left = await _allVersions(bucket);
    remaining = left.length;
    return (deleted, remaining);
  }
}
