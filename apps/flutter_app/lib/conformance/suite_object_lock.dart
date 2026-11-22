part of 'conformance_suite.dart';

extension _ObjectLock on S3ConformanceSuite {
  Future<void> _objectLockPhase() async {
    if (_stdReady) await _lockNegativeChecks();
    final create = await _check('lock.bucket.create',
        category: 'Object Lock',
        title: 'CreateBucket with Object Lock enabled',
        spec: 'CreateBucket x-amz-bucket-object-lock-enabled: true: 200. Endpoints without Object Lock reject it (recorded as unsupported).',
        body: (c) async {
      final o = await _createBucket(c, _lockBucket, objectLock: true);
      if (!o.isSuccess && (o.errorCode == 'InvalidRequest' || o.errorCode == 'NotImplemented') &&
          (o.errorMessage ?? '').toLowerCase().contains('lock')) {
        c.unsupported('The endpoint does not support Object Lock: ${conformanceClip(o.errorMessage, 120)}');
      }
      c.status(o, 200);
    });
    if (create.status != ConformanceStatus.pass && create.status != ConformanceStatus.warn) {
      return;
    }
    final versioning = await _check('lock.versioning.auto',
        category: 'Object Lock',
        title: 'Object Lock enables versioning automatically',
        spec: 'GetBucketVersioning on an Object Lock bucket: Status Enabled without PutBucketVersioning.',
        body: (c) async {
      final o = await c.call('GetBucketVersioning', {'Bucket': _lockBucket});
      c.status(o, 200);
      c.equals('Status', 'Enabled', o.field('Status'));
    });
    final lockConfig = await _check('lock.config.get',
        category: 'Object Lock',
        title: 'GetObjectLockConfiguration on the lock bucket',
        spec: 'GetObjectLockConfiguration: 200, ObjectLockEnabled Enabled, no default rule.',
        body: (c) async {
      final o = await c.call('GetObjectLockConfiguration', {'Bucket': _lockBucket});
      c.status(o, 200);
      c.equals('ObjectLockConfiguration.ObjectLockEnabled', 'Enabled', o.field('ObjectLockConfiguration.ObjectLockEnabled'));
      c.equals('ObjectLockConfiguration.Rule', null, o.field('ObjectLockConfiguration.Rule'));
    });
    _lockReady = lockConfig.status == ConformanceStatus.pass || lockConfig.status == ConformanceStatus.warn;
    if (!_lockReady || versioning.status == ConformanceStatus.fail) {
      _run.note = 'Object Lock was not active on bucket 2; protected writes were skipped.';
      return;
    }
    await _check('lock.config.default-retention',
        category: 'Object Lock',
        title: 'Put, read and clear a default GOVERNANCE retention',
        spec: 'PutObjectLockConfiguration with Rule.DefaultRetention {GOVERNANCE, Days 1}: 200; Get returns it; putting ObjectLockEnabled alone clears the rule.',
        body: (c) async {
      c.status(await c.call('PutObjectLockConfiguration', {
        'Bucket': _lockBucket,
        'ObjectLockConfiguration': {
          'ObjectLockEnabled': 'Enabled',
          'Rule': {'DefaultRetention': {'Mode': 'GOVERNANCE', 'Days': 1}},
        },
      }), 200);
      final got = await c.call('GetObjectLockConfiguration', {'Bucket': _lockBucket});
      c.equals('Rule.DefaultRetention.Mode', 'GOVERNANCE', got.field('ObjectLockConfiguration.Rule.DefaultRetention.Mode'));
      c.equals('Rule.DefaultRetention.Days', 1, got.field('ObjectLockConfiguration.Rule.DefaultRetention.Days'));
      // No fixture is written while the default applies.
      c.status(await c.call('PutObjectLockConfiguration', {
        'Bucket': _lockBucket,
        'ObjectLockConfiguration': {'ObjectLockEnabled': 'Enabled'},
      }), 200);
      final cleared = await c.call('GetObjectLockConfiguration', {'Bucket': _lockBucket});
      c.equals('Rule after clearing', null, cleared.field('ObjectLockConfiguration.Rule'));
    });
    // A default that was not cleared would lock every fixture for a day. Only a
    // successful read that shows no default rule allows fixture writes.
    final verified = await _quiet('GetObjectLockConfiguration', {'Bucket': _lockBucket});
    if (verified == null ||
        !verified.isSuccess ||
        verified.field('ObjectLockConfiguration.ObjectLockEnabled') != 'Enabled' ||
        verified.field('ObjectLockConfiguration.Rule') != null) {
      _run.note = 'The lock bucket\'s default retention could not be confirmed absent; protected writes were skipped.';
      return;
    }
    await _check('lock.put.requires-integrity',
        category: 'Object Lock',
        title: 'Retention on PutObject requires Content-MD5 or a checksum',
        spec: 'PutObject with Object Lock headers and no Content-MD5/x-amz-checksum (engines send checksums only on request): 400 InvalidRequest; nothing is stored.',
        body: (c) async {
      final until = _isoSeconds(_serverNow().add(const Duration(seconds: 60)));
      final o = await c.call('PutObject', {
        'Bucket': _lockBucket,
        'Key': 'lock/no-integrity.txt',
        'ObjectLockMode': 'GOVERNANCE',
        'ObjectLockRetainUntilDate': until,
      }, body: S3OpBody.text('x'));
      c.status(o, 400, code: 'InvalidRequest', informationalCode: true,
          explanation: 'AWS requires Content-MD5 or an x-amz-checksum header when Object Lock headers are present.');
      c.status(await c.call('HeadObject', {'Bucket': _lockBucket, 'Key': 'lock/no-integrity.txt'}), 404,
          explanation: 'The rejected write must not create the object.');
    });
    const key = 'lock/governed.txt';
    final payload = utf8.encode('governed object');
    String? versionId;
    DateTime? retainUntil;
    await _check('lock.put.governance-and-hold',
        category: 'Object Lock',
        title: 'PutObject with GOVERNANCE retention and a legal hold',
        spec: 'PutObject with x-amz-object-lock-mode GOVERNANCE, retain-until date and legal hold ON (plus Content-MD5): 200 with a version ID; HeadObject reports all three.',
        body: (c) async {
      retainUntil = _serverNow().add(const Duration(seconds: 120));
      final o = await c.call('PutObject', {
        'Bucket': _lockBucket,
        'Key': key,
        'ContentMD5': ConformanceBytes.md5Base64(payload),
        'ObjectLockMode': 'GOVERNANCE',
        'ObjectLockRetainUntilDate': _isoSeconds(retainUntil!),
        'ObjectLockLegalHoldStatus': 'ON',
      }, body: S3OpBody.text('governed object'));
      c.status(o, 200);
      versionId = o.header('x-amz-version-id');
      c.isTrue('x-amz-version-id', versionId != null && versionId != 'null', expected: 'version ID', actual: versionId);
      final head = await c.call('HeadObject', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      c.header(head, 'x-amz-object-lock-mode', 'GOVERNANCE');
      c.header(head, 'x-amz-object-lock-legal-hold', 'ON');
      _sameSecond(c, 'x-amz-object-lock-retain-until-date', retainUntil, head.header('x-amz-object-lock-retain-until-date'));
    });
    final protected = _passed('lock.put.governance-and-hold');
    await _check('lock.retention.get',
        category: 'Object Lock',
        title: 'GetObjectRetention returns mode and date',
        spec: 'GetObjectRetention: 200 with Retention.Mode GOVERNANCE and RetainUntilDate.',
        body: (c) async {
      if (!protected) c.skip('Prerequisite lock.put.governance-and-hold did not pass.');
      final o = await c.call('GetObjectRetention', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      c.status(o, 200);
      c.equals('Retention.Mode', 'GOVERNANCE', o.field('Retention.Mode'));
      _sameSecond(c, 'Retention.RetainUntilDate', retainUntil, o.field('Retention.RetainUntilDate'));
    });
    await _check('lock.retention.extend',
        category: 'Object Lock',
        title: 'Extending GOVERNANCE retention needs no bypass',
        spec: 'PutObjectRetention with a later RetainUntilDate: 200; GetObjectRetention reports the new date.',
        body: (c) async {
      if (!protected) c.skip('Prerequisite lock.put.governance-and-hold did not pass.');
      final later = retainUntil!.add(const Duration(seconds: 60));
      c.status(await c.call('PutObjectRetention', {
        'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId,
        'Retention': {'Mode': 'GOVERNANCE', 'RetainUntilDate': _isoSeconds(later)},
      }), 200);
      final got = await c.call('GetObjectRetention', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      if (_sameSecond(c, 'Retention.RetainUntilDate', later, got.field('Retention.RetainUntilDate'))) {
        retainUntil = later;
      }
    });
    await _check('lock.retention.shorten-denied',
        category: 'Object Lock',
        title: 'Shortening GOVERNANCE retention without bypass is refused',
        spec: 'PutObjectRetention with an earlier date and no x-amz-bypass-governance-retention: 403 AccessDenied; the date is unchanged.',
        body: (c) async {
      if (!protected) c.skip('Prerequisite lock.put.governance-and-hold did not pass.');
      final earlier = _serverNow().add(const Duration(seconds: 90));
      c.status(await c.call('PutObjectRetention', {
        'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId,
        'Retention': {'Mode': 'GOVERNANCE', 'RetainUntilDate': _isoSeconds(earlier)},
      }), 403, code: 'AccessDenied');
      final got = await c.call('GetObjectRetention', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      _sameSecond(c, 'Retention.RetainUntilDate (unchanged)', retainUntil, got.field('Retention.RetainUntilDate'));
    });
    await _check('lock.retention.shorten-bypass',
        category: 'Object Lock',
        title: 'Shortening GOVERNANCE retention with bypass',
        spec: 'PutObjectRetention with x-amz-bypass-governance-retention: true: 200; the earlier date applies.',
        body: (c) async {
      if (!protected) c.skip('Prerequisite lock.put.governance-and-hold did not pass.');
      final earlier = _serverNow().add(const Duration(seconds: 90));
      c.status(await c.call('PutObjectRetention', {
        'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId,
        'BypassGovernanceRetention': true,
        'Retention': {'Mode': 'GOVERNANCE', 'RetainUntilDate': _isoSeconds(earlier)},
      }), 200);
      final got = await c.call('GetObjectRetention', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      if (_sameSecond(c, 'Retention.RetainUntilDate', earlier, got.field('Retention.RetainUntilDate'))) {
        retainUntil = earlier;
      }
    });
    await _check('lock.legal-hold.blocks-delete',
        category: 'Object Lock',
        title: 'A legal hold blocks deletion even with governance bypass',
        spec: 'GetObjectLegalHold: Status ON; DeleteObject versionId with x-amz-bypass-governance-retention: 403 AccessDenied.',
        body: (c) async {
      if (!protected) c.skip('Prerequisite lock.put.governance-and-hold did not pass.');
      final hold = await c.call('GetObjectLegalHold', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      c.status(hold, 200);
      c.equals('LegalHold.Status', 'ON', hold.field('LegalHold.Status'));
      c.status(await c.call('DeleteObject', {
        'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId, 'BypassGovernanceRetention': true,
      }), 403, code: 'AccessDenied');
      c.status(await c.call('HeadObject', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId}), 200,
          explanation: 'The protected version must still exist.');
    });
    await _check('lock.delete.marker-allowed',
        category: 'Object Lock',
        title: 'A simple DELETE on a locked key adds a delete marker',
        spec: 'DeleteObject without versionId: 204 with x-amz-delete-marker: true; the locked version remains readable by ID.',
        body: (c) async {
      if (!protected) c.skip('Prerequisite lock.put.governance-and-hold did not pass.');
      final o = await c.call('DeleteObject', {'Bucket': _lockBucket, 'Key': key});
      c.status(o, 204);
      c.header(o, 'x-amz-delete-marker', 'true');
      final get = await c.call('GetObject', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      c.status(get, 200);
      c.body(get, payload);
    });
    await _check('lock.legal-hold.off',
        category: 'Object Lock',
        title: 'PutObjectLegalHold OFF releases the hold',
        spec: 'PutObjectLegalHold Status OFF: 200; GetObjectLegalHold reports OFF.',
        body: (c) async {
      if (!protected) c.skip('Prerequisite lock.put.governance-and-hold did not pass.');
      c.status(await c.call('PutObjectLegalHold', {
        'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId, 'LegalHold': {'Status': 'OFF'},
      }), 200);
      final hold = await c.call('GetObjectLegalHold', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId});
      c.equals('LegalHold.Status', 'OFF', hold.field('LegalHold.Status'));
    });
    await _check('lock.governance.delete-denied',
        category: 'Object Lock',
        title: 'GOVERNANCE retention blocks deletion without bypass',
        spec: 'DeleteObject versionId without x-amz-bypass-governance-retention while retained: 403 AccessDenied.',
        body: (c) async {
      c.requirePassed('lock.legal-hold.off');
      c.status(await c.call('DeleteObject', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId}), 403,
          code: 'AccessDenied');
    });
    await _check('lock.governance.delete-bypass',
        category: 'Object Lock',
        title: 'GOVERNANCE retention can be bypassed for deletion',
        spec: 'DeleteObject versionId with x-amz-bypass-governance-retention: true: 204; the version is gone.',
        body: (c) async {
      c.requirePassed('lock.legal-hold.off');
      c.status(await c.call('DeleteObject', {
        'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId, 'BypassGovernanceRetention': true,
      }), 204);
      c.status(await c.call('HeadObject', {'Bucket': _lockBucket, 'Key': key, 'VersionId': versionId}), 404);
    });
    await _check('lock.legal-hold.only',
        category: 'Object Lock',
        title: 'Legal hold without retention',
        spec: 'PutObject then PutObjectLegalHold ON: 200; deletion by version: 403 AccessDenied; after OFF: 204.',
        body: (c) async {
      const holdKey = 'lock/hold-only.txt';
      final put = await c.call('PutObject', {
        'Bucket': _lockBucket, 'Key': holdKey, 'ContentMD5': ConformanceBytes.md5Base64(utf8.encode('hold')),
      }, body: S3OpBody.text('hold'));
      c.fixture(put);
      final id = put.header('x-amz-version-id');
      c.status(await c.call('PutObjectLegalHold', {'Bucket': _lockBucket, 'Key': holdKey, 'VersionId': id, 'LegalHold': {'Status': 'ON'}}), 200);
      c.status(await c.call('DeleteObject', {'Bucket': _lockBucket, 'Key': holdKey, 'VersionId': id}), 403, code: 'AccessDenied');
      c.status(await c.call('PutObjectLegalHold', {'Bucket': _lockBucket, 'Key': holdKey, 'VersionId': id, 'LegalHold': {'Status': 'OFF'}}), 200);
      c.status(await c.call('DeleteObject', {'Bucket': _lockBucket, 'Key': holdKey, 'VersionId': id}), 204);
    });
    await _check('lock.compliance.short',
        category: 'Object Lock',
        title: 'COMPLIANCE retention cannot be bypassed, shortened or relaxed (5-second lock)',
        spec: 'PutObject COMPLIANCE: 200 with a version ID; GetObjectRetention reports COMPLIANCE and the date; DeleteObject with governance bypass, '
            'PutObjectRetention with an earlier date and PutObjectRetention to GOVERNANCE: 403 AccessDenied; after the date passes the version can be deleted.',
        body: (c) async {
      if (!config.includeShortCompliance) c.skip('The short COMPLIANCE check is turned off.');
      const complianceKey = 'lock/compliance.txt';
      final until = _serverNow().add(const Duration(seconds: 5));
      // Recorded before the write: a timed-out PUT may still have locked a version.
      _complianceUntil = until.add(const Duration(seconds: 1));
      final put = await c.call('PutObject', {
        'Bucket': _lockBucket,
        'Key': complianceKey,
        'ContentMD5': ConformanceBytes.md5Base64(utf8.encode('compliance')),
        'ObjectLockMode': 'COMPLIANCE',
        'ObjectLockRetainUntilDate': _isoSeconds(until),
      }, body: S3OpBody.text('compliance'));
      c.status(put, 200);
      if (!put.isSuccess) return;
      final id = put.header('x-amz-version-id');
      if (!c.isTrue('x-amz-version-id', id != null && id.isNotEmpty && id != 'null', expected: 'version ID', actual: id)) {
        return;
      }
      final retention = await c.call('GetObjectRetention', {'Bucket': _lockBucket, 'Key': complianceKey, 'VersionId': id});
      c.status(retention, 200);
      c.equals('Retention.Mode', 'COMPLIANCE', retention.field('Retention.Mode'));
      _sameSecond(c, 'Retention.RetainUntilDate', until, retention.field('Retention.RetainUntilDate'));
      final deleteAttempt = await c.call('DeleteObject', {
        'Bucket': _lockBucket, 'Key': complianceKey, 'VersionId': id, 'BypassGovernanceRetention': true,
      });
      c.status(deleteAttempt, 403, code: 'AccessDenied');
      final shorten = await c.call('PutObjectRetention', {
        'Bucket': _lockBucket, 'Key': complianceKey, 'VersionId': id, 'BypassGovernanceRetention': true,
        'Retention': {'Mode': 'COMPLIANCE', 'RetainUntilDate': _isoSeconds(until.subtract(const Duration(seconds: 2)))},
      });
      c.status(shorten, 403, code: 'AccessDenied', explanation: 'COMPLIANCE retention cannot be shortened, even with bypass.');
      final relax = await c.call('PutObjectRetention', {
        'Bucket': _lockBucket, 'Key': complianceKey, 'VersionId': id, 'BypassGovernanceRetention': true,
        'Retention': {'Mode': 'GOVERNANCE', 'RetainUntilDate': _isoSeconds(until)},
      });
      c.status(relax, 403, code: 'AccessDenied', explanation: 'COMPLIANCE cannot be switched to GOVERNANCE.');
      final still = await c.call('HeadObject', {'Bucket': _lockBucket, 'Key': complianceKey, 'VersionId': id});
      c.status(still, 200, explanation: 'The protected version must still exist.');
      await _waitUntilServer(until.add(const Duration(seconds: 2)));
      c.status(await c.call('DeleteObject', {'Bucket': _lockBucket, 'Key': complianceKey, 'VersionId': id}), 204,
          explanation: 'After the retain-until date the version can be deleted.');
      c.status(await c.call('HeadObject', {'Bucket': _lockBucket, 'Key': complianceKey, 'VersionId': id}), 404,
          explanation: 'The expired version is gone after deletion.');
    });
  }

  Future<void> _lockNegativeChecks() async {
    await _check('lock.standard-bucket.config-absent',
        category: 'Object Lock',
        title: 'GetObjectLockConfiguration on a bucket without Object Lock',
        spec: 'GetObjectLockConfiguration: 404 ObjectLockConfigurationNotFoundError.',
        body: (c) async {
      c.status(await c.call('GetObjectLockConfiguration', {'Bucket': _stdBucket}), 404,
          code: 'ObjectLockConfigurationNotFoundError');
    });
    await _check('lock.standard-bucket.object-calls-rejected',
        category: 'Object Lock',
        title: 'Retention and legal hold calls on a bucket without Object Lock',
        spec: 'PutObjectRetention, PutObjectLegalHold, GetObjectRetention and PutObject with lock headers on a bucket without Object Lock: 400 InvalidRequest.',
        body: (c) async {
      const key = 'p3/no-lock.txt';
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('x')));
      final until = _isoSeconds(_serverNow().add(const Duration(seconds: 60)));
      c.status(await c.call('PutObjectRetention', {
        'Bucket': _stdBucket, 'Key': key, 'Retention': {'Mode': 'GOVERNANCE', 'RetainUntilDate': until},
      }), 400, code: 'InvalidRequest');
      c.status(await c.call('PutObjectLegalHold', {'Bucket': _stdBucket, 'Key': key, 'LegalHold': {'Status': 'ON'}}), 400,
          code: 'InvalidRequest');
      c.status(await c.call('GetObjectRetention', {'Bucket': _stdBucket, 'Key': key}), 400,
          code: 'InvalidRequest', informationalCode: true);
      final put = await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': 'p3/no-lock-put.txt',
        'ContentMD5': ConformanceBytes.md5Base64(utf8.encode('x')),
        'ObjectLockMode': 'GOVERNANCE',
        'ObjectLockRetainUntilDate': until,
      }, body: S3OpBody.text('x'));
      c.status(put, 400, code: 'InvalidRequest');
      c.status(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': 'p3/no-lock-put.txt'}), 404,
          explanation: 'The rejected write must not create the object.');
    });
  }

  bool _sameSecond(_CheckContext c, String field, DateTime? expected, Object? actual) {
    final parsed = actual == null
        ? null
        : (_parseIso(actual) ?? _parseHttpDate('$actual'));
    final ok = expected != null &&
        parsed != null &&
        (parsed.millisecondsSinceEpoch ~/ 1000) == (expected.toUtc().millisecondsSinceEpoch ~/ 1000);
    return c.isTrue(field, ok,
        expected: expected == null ? 'absent' : _isoSeconds(expected), actual: actual);
  }
}
