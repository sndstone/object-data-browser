part of 'conformance_suite.dart';

/// One page of versions: (key, versionId, isDeleteMarker).
typedef _VersionEntry = (String, String?, bool);

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
    // A bucket whose CreateBucket outcome is unknown is never purged: the run
    // cannot prove it created it. It is reported for manual inspection.
    for (final bucket in _uncertainBuckets) {
      final head = await _quiet('HeadBucket', {'Bucket': bucket});
      if (head != null && head.isService && head.httpStatus == 404) continue;
      retained.add(bucket);
      errors.add('CreateBucket $bucket had no definite outcome; it was not deleted automatically. Check it manually.');
    }
    // Lock bucket first: its protections are the slowest to clear.
    final order = <String>{
      ..._ownedBuckets.where((b) => b == _lockBucket),
      ..._ownedBuckets.where((b) => b != _lockBucket),
    };
    for (final bucket in order) {
      if (cancellation.skipTeardown) {
        // "Stop without cleanup" pressed during teardown.
        retained.add(bucket);
        errors.add('Teardown stopped by the user before $bucket was cleaned up.');
        continue;
      }
      final head = await _quiet('HeadBucket', {'Bucket': bucket});
      if (head == null || !head.isService) {
        retained.add(bucket);
        errors.add('HeadBucket $bucket: ${head == null ? 'engine error' : _CheckContext.describe(head)}; bucket state unknown.');
        continue;
      }
      if (head.httpStatus == 404) continue; // already deleted by its check
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
      final gone = await _quiet('HeadBucket', {'Bucket': bucket});
      if (delete != null && delete.isSuccess && gone != null && gone.isService && gone.httpStatus == 404) {
        deleted.add(bucket);
      } else if (delete != null && delete.isSuccess) {
        retained.add(bucket);
        errors.add('DeleteBucket $bucket returned ${delete.httpStatus} but HeadBucket still reports '
            '${gone == null ? 'an engine error' : _CheckContext.describe(gone)}.');
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
        title: retain ? 'Buckets retained for inspection (failures and "keep buckets" on)' : 'Every test bucket was emptied and deleted',
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
      if (list == null || !list.isSuccess || list.output['truncated'] == true) {
        errors.add('ListMultipartUploads $bucket: ${list == null ? 'engine error' : _CheckContext.describe(list)}; uploads may remain.');
        break;
      }
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
    Object? keyMarker;
    Object? versionMarker;
    for (var page = 0; page < 50; page++) {
      final list = await _quiet('ListObjectVersions', {
        'Bucket': bucket,
        if (keyMarker != null) 'KeyMarker': keyMarker,
        if (versionMarker != null) 'VersionIdMarker': versionMarker,
      });
      if (list == null || !list.isSuccess || list.output['truncated'] == true) {
        errors.add('ListObjectVersions $bucket: ${list == null ? 'engine error' : _CheckContext.describe(list)}; legal holds may remain.');
        return released;
      }
      for (final v in list.list('Versions')) {
        final key = '${v['Key']}';
        final id = v['VersionId'];
        final hold = await _quiet('GetObjectLegalHold', {'Bucket': bucket, 'Key': key, 'VersionId': id});
        if (hold == null || hold.field('LegalHold.Status') != 'ON') continue;
        final off = await _quiet('PutObjectLegalHold',
            {'Bucket': bucket, 'Key': key, 'VersionId': id, 'LegalHold': {'Status': 'OFF'}});
        if (off != null && off.isSuccess) {
          released++;
        } else {
          errors.add('PutObjectLegalHold OFF $key: ${off == null ? 'engine error' : _CheckContext.describe(off)}');
        }
      }
      if (list.field('IsTruncated') != true) break;
      keyMarker = list.field('NextKeyMarker');
      versionMarker = list.field('NextVersionIdMarker');
    }
    return released;
  }

  /// The first page (at most 1000 entries) of what remains, or null when it
  /// cannot be listed. Plain keys are used only for a bucket that has never
  /// had versioning, where deleting a key cannot create a delete marker.
  Future<(List<_VersionEntry>, bool)?> _remainingPage(String bucket, List<String> errors) async {
    final list = await _quiet('ListObjectVersions', {'Bucket': bucket, 'MaxKeys': 1000});
    if (list != null && list.isSuccess && list.output['truncated'] == true) {
      errors.add('ListObjectVersions $bucket: the engine could not project the listing; versions cannot be enumerated.');
      return null;
    }
    if (list != null && list.isSuccess) {
      return (
        <_VersionEntry>[
          for (final v in list.list('Versions')) ('${v['Key']}', v['VersionId']?.toString(), false),
          for (final m in list.list('DeleteMarkers')) ('${m['Key']}', m['VersionId']?.toString(), true),
        ],
        list.field('IsTruncated') == true,
      );
    }
    final versioning = await _quiet('GetBucketVersioning', {'Bucket': bucket});
    if (versioning == null || !versioning.isSuccess || versioning.field('Status') != null) {
      errors.add('ListObjectVersions $bucket: ${list == null ? 'engine error' : _CheckContext.describe(list)}; versions cannot be enumerated.');
      return null;
    }
    final keys = await _quiet('ListObjectsV2', {'Bucket': bucket, 'MaxKeys': 1000});
    if (keys == null || !keys.isSuccess || keys.output['truncated'] == true) {
      errors.add('ListObjectsV2 $bucket: ${keys == null ? 'engine error' : _CheckContext.describe(keys)}');
      return null;
    }
    return (
      <_VersionEntry>[for (final item in keys.list('Contents')) ('${item['Key']}', null, false)],
      keys.field('IsTruncated') == true,
    );
  }

  /// Deletes page by page from the start of the listing; returns
  /// (deleted, left over). Memory stays bounded to one page.
  Future<(int, int)> _purge(String bucket,
      {required bool bypass, required List<String> errors}) async {
    var deleted = 0;
    for (var round = 0; round < 200; round++) {
      final page = await _remainingPage(bucket, errors);
      if (page == null) return (deleted, 1);
      final (entries, truncated) = page;
      if (entries.isEmpty) return (deleted, 0);
      final o = await _quiet('DeleteObjects', {
        'Bucket': bucket,
        if (bypass) 'BypassGovernanceRetention': true,
        'Delete': {
          'Objects': [
            for (final v in entries) {'Key': v.$1, if (v.$2 != null) 'VersionId': v.$2}
          ],
          'Quiet': true,
        },
      });
      final failed = <String>{};
      var progress = 0;
      if (o != null && o.isSuccess) {
        for (final error in o.list('Errors')) {
          failed.add('${error['Key']}\u0000${error['VersionId'] ?? ''}');
        }
        progress += entries.length - failed.length;
      }
      // Per-object fallback for an endpoint without DeleteObjects, without
      // batch governance bypass, or for entries the batch refused.
      for (final v in entries) {
        if (o != null && o.isSuccess && !failed.contains('${v.$1}\u0000${v.$2 ?? ''}')) continue;
        final single = await _quiet('DeleteObject', {
          'Bucket': bucket,
          'Key': v.$1,
          if (v.$2 != null) 'VersionId': v.$2,
          if (bypass) 'BypassGovernanceRetention': true,
        });
        if (single != null && single.isSuccess) {
          progress++;
        } else if (errors.length < 20) {
          errors.add('DeleteObject ${v.$1}: ${single == null ? 'engine error' : _CheckContext.describe(single)}');
        }
      }
      deleted += progress;
      if (progress == 0) {
        return (deleted, entries.length + (truncated ? 1 : 0));
      }
    }
    final last = await _remainingPage(bucket, errors);
    if (last != null && last.$1.isNotEmpty) {
      errors.add('$bucket still lists ${last.$1.length}${last.$2 ? '+' : ''} versions after 200 cleanup rounds.');
    }
    return (deleted, last == null ? 1 : last.$1.length);
  }
}
