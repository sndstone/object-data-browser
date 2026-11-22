part of 'conformance_suite.dart';

extension _Versioning on S3ConformanceSuite {
  Future<void> _versioningPhase() async {
    final phaseOne = _run.checks.where((check) =>
        check.phase == ConformancePhase.standard || check.phase == ConformancePhase.setup);
    // The gate needs affirmative coverage: a required check that was
    // unsupported, skipped or errored did not show the behaviour either.
    final requiredFailures = phaseOne.where((check) =>
        check.severity == ConformanceSeverity.required &&
        check.status != ConformanceStatus.pass &&
        check.status != ConformanceStatus.warn);
    _run.gatePassed = requiredFailures.isEmpty;
    await _check('versioning.gate',
        category: 'Versioning',
        title: 'Phase 1 gate recorded before versioning is enabled',
        spec: 'Every required phase-1 check passes before PutBucketVersioning(Enabled). Phase 2 runs either way so versioning stays diagnosable.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.isTrue('required phase-1 checks without a pass', requiredFailures.isEmpty,
          expected: '0',
          actual: requiredFailures.isEmpty
              ? '0'
              : '${requiredFailures.length}: ${requiredFailures.take(6).map((check) => '${check.id} (${check.status.label})').join(', ')}${requiredFailures.length > 6 ? ', …' : ''}',
          explanation: 'Failed, errored, unsupported or skipped required checks leave phase-1 coverage incomplete.');
    });
    final enable = await _check('versioning.enable',
        category: 'Versioning',
        title: 'PutBucketVersioning(Enabled) then GetBucketVersioning',
        spec: 'PutBucketVersioning Status=Enabled: 200; GetBucketVersioning: Status Enabled.',
        body: (c) async {
      c.status(await c.call('PutBucketVersioning', {'Bucket': _stdBucket, 'VersioningConfiguration': {'Status': 'Enabled'}}), 200);
      final got = await c.call('GetBucketVersioning', {'Bucket': _stdBucket});
      c.status(got, 200);
      c.equals('Status', 'Enabled', got.field('Status'));
    });
    _versioningEnabled = enable.status == ConformanceStatus.pass || enable.status == ConformanceStatus.warn;
    if (!_versioningEnabled) {
      _run.note = 'Versioning could not be enabled; remaining phase-2 checks were skipped.';
      return;
    }
    // AWS documents a propagation delay after versioning is first enabled
    // (writes may briefly behave as unversioned). Wait until a probe write
    // gets a real version ID that reads back, within a bounded budget.
    await _check('versioning.ready',
        category: 'Versioning',
        title: 'Versioning takes effect for new writes',
        spec: 'After PutBucketVersioning(Enabled), PutObject returns a non-"null" x-amz-version-id that GetObject accepts. AWS allows a propagation delay; the suite waits up to 60 s.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final deadline = _clock().add(const Duration(seconds: 60));
      var attempts = 0;
      while (true) {
        attempts++;
        final put = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p2/ready-probe.txt'}, body: S3OpBody.text('probe $attempts'));
        final id = put.header('x-amz-version-id');
        if (put.isSuccess && id != null && id.isNotEmpty && id != 'null') {
          final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p2/ready-probe.txt', 'VersionId': id});
          if (get.isSuccess) {
            if (attempts > 1) c.note('Versioning took effect after $attempts probe writes.');
            return;
          }
        }
        if (_clock().isAfter(deadline)) {
          c.isTrue('versioned probe write', false,
              expected: 'version ID that reads back', actual: '${_CheckContext.describe(put)}, version ${id ?? 'absent'}',
              explanation: 'Versioning did not take effect within 60 s; later phase-2 results may reflect propagation.');
          return;
        }
        await _sleep(const Duration(seconds: 2));
      }
    });
    const key = 'p2/versioned.txt';
    final v1 = utf8.encode('version one');
    final v2 = utf8.encode('version two, longer');
    final ids = <String, String>{};
    await _check('versioning.put.distinct-ids',
        category: 'Versioning',
        title: 'Each PutObject creates a new version',
        spec: 'PutObject in an Enabled bucket: 200 with a distinct, non-"null" x-amz-version-id per write.',
        body: (c) async {
      final first = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('version one'));
      c.status(first, 200);
      final second = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('version two, longer'));
      c.status(second, 200);
      final a = first.header('x-amz-version-id');
      final b = second.header('x-amz-version-id');
      c.isTrue('x-amz-version-id (first)', a != null && a.isNotEmpty && a != 'null', expected: 'non-null version ID', actual: a);
      c.isTrue('x-amz-version-id (second)', b != null && b.isNotEmpty && b != 'null', expected: 'non-null version ID', actual: b);
      c.isTrue('distinct version IDs', a != b, expected: 'different', actual: '$a / $b');
      if (a != null) ids['v1'] = a;
      if (b != null) ids['v2'] = b;
    });
    await _check('versioning.get.by-id',
        category: 'Versioning',
        title: 'GetObject and HeadObject by VersionId',
        spec: 'GetObject/HeadObject versionId=<id>: 200 with that version and x-amz-version-id; without versionId the latest version.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      final old = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']});
      c.status(old, 200);
      c.body(old, v1, field: 'version 1');
      c.header(old, 'x-amz-version-id', ids['v1']);
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']});
      c.status(head, 200);
      c.header(head, 'x-amz-version-id', ids['v1']);
      c.header(head, 'content-length', '${v1.length}');
      final latest = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.body(latest, v2, field: 'latest');
      c.header(latest, 'x-amz-version-id', ids['v2']);
    });
    await _check('versioning.list',
        category: 'Versioning',
        title: 'ListObjectVersions reports versions newest first with IsLatest',
        spec: 'ListObjectVersions: 200; versions of a key newest first; only the newest has IsLatest=true.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      final o = await c.call('ListObjectVersions', {'Bucket': _stdBucket, 'Prefix': key});
      c.status(o, 200);
      final versions = o.list('Versions');
      c.equals('Versions[].VersionId', [ids['v2'], ids['v1']], [for (final v in versions) v['VersionId']]);
      c.equals('Versions[].IsLatest', [true, false], [for (final v in versions) v['IsLatest']]);
      c.equals('Versions[].Size', [v2.length, v1.length], [for (final v in versions) v['Size']]);
    });
    await _check('versioning.list.pagination',
        category: 'Versioning',
        title: 'ListObjectVersions paginates with KeyMarker and VersionIdMarker',
        spec: 'ListObjectVersions MaxKeys=1: IsTruncated with NextKeyMarker and NextVersionIdMarker; pages cover all versions exactly once.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      final third = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p2/paged.txt'}, body: S3OpBody.text('1'));
      c.fixture(third);
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p2/paged.txt'}, body: S3OpBody.text('2')));
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p2/paged.txt'}, body: S3OpBody.text('3')));
      final seen = <String>[];
      Object? keyMarker;
      Object? versionMarker;
      var pages = 0;
      while (pages < 10) {
        final o = await c.call('ListObjectVersions', {
          'Bucket': _stdBucket,
          'Prefix': 'p2/paged.txt',
          'MaxKeys': 1,
          if (keyMarker != null) 'KeyMarker': keyMarker,
          if (versionMarker != null) 'VersionIdMarker': versionMarker,
        });
        pages++;
        if (!c.status(o, 200)) return;
        seen.addAll([for (final v in o.list('Versions')) '${v['VersionId']}']);
        if (o.field('IsTruncated') != true) break;
        keyMarker = o.field('NextKeyMarker');
        versionMarker = o.field('NextVersionIdMarker');
        if (!c.isTrue('next markers', keyMarker != null && versionMarker != null,
            expected: 'NextKeyMarker and NextVersionIdMarker', actual: '$keyMarker / $versionMarker')) {
          return;
        }
      }
      c.equals('versions across pages', 3, seen.length);
      c.equals('distinct versions', 3, seen.toSet().length);
      c.equals('pages', 3, pages);
    });
    String? marker;
    await _check('versioning.delete-marker.create',
        category: 'Versioning',
        title: 'DeleteObject without VersionId creates a delete marker',
        spec: 'DeleteObject: 204 with x-amz-delete-marker: true and the marker\'s x-amz-version-id.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      final o = await c.call('DeleteObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(o, 204);
      c.header(o, 'x-amz-delete-marker', 'true');
      marker = o.header('x-amz-version-id');
      c.isTrue('x-amz-version-id', marker != null && marker!.isNotEmpty, expected: 'delete marker version ID', actual: marker);
    });
    await _check('versioning.delete-marker.current',
        category: 'Versioning',
        title: 'Reading a key whose current version is a delete marker',
        spec: 'GetObject/HeadObject without versionId: 404 with x-amz-delete-marker: true (GetObject code NoSuchKey).',
        body: (c) async {
      c.requirePassed('versioning.delete-marker.create');
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(get, 404, code: 'NoSuchKey');
      c.header(get, 'x-amz-delete-marker', 'true');
      c.header(get, 'x-amz-version-id', marker, informational: true);
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(head, 404);
      c.header(head, 'x-amz-delete-marker', 'true');
    });
    await _check('versioning.delete-marker.by-id',
        category: 'Versioning',
        title: 'Reading the delete marker version itself',
        spec: 'GetObject/HeadObject with the delete marker\'s versionId: 405 MethodNotAllowed with x-amz-delete-marker: true.',
        body: (c) async {
      c.requirePassed('versioning.delete-marker.create');
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': marker});
      c.status(get, 405, code: 'MethodNotAllowed');
      c.header(get, 'x-amz-delete-marker', 'true');
      c.headerPresent(get, 'last-modified', informational: true,
          explanation: 'AWS returns the delete marker\'s Last-Modified with the 405.');
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': marker});
      c.status(head, 405);
      c.header(head, 'x-amz-delete-marker', 'true', informational: true);
    });
    await _check('versioning.delete-marker.list',
        category: 'Versioning',
        title: 'ListObjectVersions lists the delete marker as latest',
        spec: 'ListObjectVersions: DeleteMarkers contains the marker with IsLatest=true; no version of the key is latest.',
        body: (c) async {
      c.requirePassed('versioning.delete-marker.create');
      final o = await c.call('ListObjectVersions', {'Bucket': _stdBucket, 'Prefix': key});
      c.status(o, 200);
      final markers = o.list('DeleteMarkers');
      c.equals('DeleteMarkers[].VersionId', [marker], [for (final m in markers) m['VersionId']]);
      c.equals('DeleteMarkers[].IsLatest', [true], [for (final m in markers) m['IsLatest']]);
      c.equals('Versions[].IsLatest', [false, false], [for (final v in o.list('Versions')) v['IsLatest']]);
    });
    await _check('versioning.delete-marker.remove',
        category: 'Versioning',
        title: 'Deleting the delete marker restores the previous version',
        spec: 'DeleteObject versionId=<marker>: 204 with x-amz-delete-marker: true; GetObject then returns the newest version.',
        body: (c) async {
      c.requirePassed('versioning.delete-marker.create');
      final o = await c.call('DeleteObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': marker});
      c.status(o, 204);
      c.header(o, 'x-amz-delete-marker', 'true');
      c.header(o, 'x-amz-version-id', marker);
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(get, 200);
      c.body(get, v2);
    });
    await _check('versioning.copy.source-version',
        category: 'Versioning',
        title: 'CopyObject from a specific source version',
        spec: 'CopyObject with x-amz-copy-source versionId: 200; x-amz-copy-source-version-id echoes it; the destination holds that version.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      final o = await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': 'p2/copied-v1.txt',
        'CopySource': {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']},
      });
      c.status(o, 200);
      c.header(o, 'x-amz-copy-source-version-id', ids['v1']);
      c.headerPresent(o, 'x-amz-version-id');
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p2/copied-v1.txt'}), v1);
    });
    await _check('versioning.tagging.by-version',
        category: 'Versioning',
        title: 'Tags apply to one version only',
        spec: 'PutObjectTagging/GetObjectTagging/DeleteObjectTagging with versionId act on that version; other versions keep their tags.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      final tags = [{'Key': 'version', 'Value': 'one'}];
      final put = await c.call('PutObjectTagging', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1'], 'Tagging': {'TagSet': tags}});
      c.status(put, 200);
      c.header(put, 'x-amz-version-id', ids['v1'], informational: true);
      c.equals('TagSet of version 1', tags, _tags(await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']})));
      c.equals('TagSet of version 2', const [], _tags(await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v2']})));
      c.status(await c.call('DeleteObjectTagging', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']}), 204);
      c.equals('TagSet of version 1 after delete', const [],
          _tags(await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']})));
    });
    await _check('versioning.delete.permanent',
        category: 'Versioning',
        title: 'DeleteObject with VersionId removes that version permanently',
        spec: 'DeleteObject versionId=<id>: 204 with x-amz-version-id; GetObject of that version: 404 NoSuchVersion; other versions remain.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      final o = await c.call('DeleteObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']});
      c.status(o, 204);
      c.header(o, 'x-amz-version-id', ids['v1']);
      c.headerAbsent(o, 'x-amz-delete-marker', informational: true);
      c.status(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': ids['v1']}), 404, code: 'NoSuchVersion');
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key}), v2, field: 'remaining version');
    });
    await _check('versioning.get.invalid-version',
        category: 'Versioning',
        title: 'GetObject with a malformed version ID',
        spec: 'GetObject versionId=<malformed>: 400 InvalidArgument.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.status(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': 'not-a-real-version'}), 400,
          code: 'InvalidArgument', alternativeCodes: const ['NoSuchVersion'], informationalCode: true);
    });
    await _check('versioning.delete-objects.versions',
        category: 'Versioning',
        title: 'DeleteObjects with VersionIds and without',
        spec: 'DeleteObjects: entries with VersionId delete that version (Deleted echoes VersionId); entries without VersionId create delete markers (DeleteMarker=true, DeleteMarkerVersionId).',
        body: (c) async {
      final a = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p2/batch-a.txt'}, body: S3OpBody.text('a'));
      c.fixture(a);
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p2/batch-b.txt'}, body: S3OpBody.text('b')));
      final versionA = a.header('x-amz-version-id');
      final o = await c.call('DeleteObjects', {
        'Bucket': _stdBucket,
        'Delete': {
          'Objects': [
            {'Key': 'p2/batch-a.txt', 'VersionId': versionA},
            {'Key': 'p2/batch-b.txt'},
          ],
          'Quiet': false,
        },
      });
      c.status(o, 200);
      final deleted = {for (final d in o.list('Deleted')) '${d['Key']}': d};
      c.equals('Deleted[a].VersionId', versionA, deleted['p2/batch-a.txt']?['VersionId']);
      c.equals('Deleted[b].DeleteMarker', true, deleted['p2/batch-b.txt']?['DeleteMarker']);
      c.isTrue('Deleted[b].DeleteMarkerVersionId', '${deleted['p2/batch-b.txt']?['DeleteMarkerVersionId'] ?? ''}'.isNotEmpty,
          expected: 'present', actual: deleted['p2/batch-b.txt']?['DeleteMarkerVersionId']);
      c.equals('Errors', 0, o.list('Errors').length);
      c.status(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p2/batch-a.txt', 'VersionId': versionA}), 404,
          code: 'NoSuchVersion');
      final listed = await c.call('ListObjectVersions', {'Bucket': _stdBucket, 'Prefix': 'p2/batch-b.txt'});
      c.equals('batch-b versions kept', 1, listed.list('Versions').length);
      c.equals('batch-b delete markers', 1, listed.list('DeleteMarkers').length);
    });
    await _suspendedChecks();
  }

  Future<void> _suspendedChecks() async {
    final suspend = await _check('versioning.suspend',
        category: 'Versioning',
        title: 'PutBucketVersioning(Suspended)',
        spec: 'PutBucketVersioning Status=Suspended: 200; GetBucketVersioning: Status Suspended.',
        body: (c) async {
      c.status(await c.call('PutBucketVersioning', {'Bucket': _stdBucket, 'VersioningConfiguration': {'Status': 'Suspended'}}), 200);
      final got = await c.call('GetBucketVersioning', {'Bucket': _stdBucket});
      c.equals('Status', 'Suspended', got.field('Status'));
    });
    if (suspend.status != ConformanceStatus.pass && suspend.status != ConformanceStatus.warn) return;
    await _sleep(const Duration(seconds: 1));
    const key = 'p2/suspended.txt';
    String? numbered;
    await _check('versioning.suspended.null-version',
        category: 'Versioning',
        title: 'Writes in a suspended bucket replace the "null" version',
        spec: 'After suspension, PutObject stores version "null"; a second write replaces it; earlier numbered versions remain.',
        body: (c) async {
      // A fresh key gets only "null" versions; the phase-2 key keeps its
      // numbered versions for the next check.
      final first = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('null one'));
      c.status(first, 200);
      final header = first.header('x-amz-version-id');
      c.isTrue('PutObject x-amz-version-id', header == null || header == 'null',
          expected: 'null or absent', actual: header, informational: true);
      c.status(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('null two')), 200);
      final listed = await c.call('ListObjectVersions', {'Bucket': _stdBucket, 'Prefix': key});
      c.status(listed, 200);
      final versions = listed.list('Versions');
      c.equals('Versions[].VersionId', ['null'], [for (final v in versions) v['VersionId']],
          explanation: 'A suspended bucket keeps exactly one "null" version per key.');
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'VersionId': 'null'});
      c.status(get, 200);
      c.body(get, utf8.encode('null two'));
      final older = await c.call('ListObjectVersions', {'Bucket': _stdBucket, 'Prefix': 'p2/versioned.txt'});
      numbered = older.list('Versions').where((v) => v['VersionId'] != 'null').firstOrNull?['VersionId']?.toString();
      c.isTrue('earlier numbered versions kept', numbered != null, expected: 'present', actual: numbered);
    });
    await _check('versioning.suspended.overwrite-numbered',
        category: 'Versioning',
        title: 'A write to a key with numbered versions adds a "null" version',
        spec: 'In a suspended bucket PutObject on a key with numbered versions adds a "null" version and keeps the numbered ones.',
        body: (c) async {
      c.requirePassed('versioning.put.distinct-ids');
      c.status(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p2/versioned.txt'}, body: S3OpBody.text('suspended write')), 200);
      final listed = await c.call('ListObjectVersions', {'Bucket': _stdBucket, 'Prefix': 'p2/versioned.txt'});
      final ids = [for (final v in listed.list('Versions')) '${v['VersionId']}'];
      c.isTrue('null version added', ids.contains('null'), expected: 'contains "null"', actual: ids.join(', '));
      c.isTrue('numbered version kept', numbered == null || ids.contains(numbered),
          expected: 'contains $numbered', actual: ids.join(', '));
      final latest = listed.list('Versions').where((v) => v['IsLatest'] == true).firstOrNull;
      c.equals('latest VersionId', 'null', latest?['VersionId']);
    });
    await _check('versioning.suspended.delete',
        category: 'Versioning',
        title: 'Deleting in a suspended bucket creates a "null" delete marker',
        spec: 'DeleteObject without versionId: 204, x-amz-delete-marker: true, version "null"; deleting that marker restores the latest numbered version.',
        body: (c) async {
      final o = await c.call('DeleteObject', {'Bucket': _stdBucket, 'Key': 'p2/versioned.txt'});
      c.status(o, 204);
      c.header(o, 'x-amz-delete-marker', 'true');
      c.header(o, 'x-amz-version-id', 'null', informational: true);
      final listed = await c.call('ListObjectVersions', {'Bucket': _stdBucket, 'Prefix': 'p2/versioned.txt'});
      final markers = listed.list('DeleteMarkers');
      c.equals('DeleteMarkers[].VersionId', ['null'], [for (final m in markers) m['VersionId']]);
      c.isTrue('null data version replaced', !listed.list('Versions').any((v) => v['VersionId'] == 'null'),
          expected: 'no "null" data version', actual: [for (final v in listed.list('Versions')) v['VersionId']].join(', '));
      c.status(await c.call('DeleteObject', {'Bucket': _stdBucket, 'Key': 'p2/versioned.txt', 'VersionId': 'null'}), 204);
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p2/versioned.txt'});
      c.status(get, 200);
      c.header(get, 'x-amz-version-id', numbered);
      c.body(get, utf8.encode('version two, longer'), field: 'restored numbered version');
    });
  }
}
