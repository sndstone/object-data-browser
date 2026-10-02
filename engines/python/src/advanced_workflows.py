"""Credential-free, explicitly dispatched administrative and recovery workflows.

Cloud clients are supplied by the engine for each request. Checkpoints never
contain profiles, tokens, signed URLs, or provider credentials.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import importlib
import json
import os
import re
import ssl
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote, urlencode, urlparse

ACTIONS = {
    'planHistoryCopy', 'resumeHistoryCopy', 'inspectHistoryCopy', 'resolveHistoryCopy',
    'planBucketConfigurationCopy', 'applyBucketConfigurationCopy',
    'getAccountLifecycle', 'putAccountLifecycle',
    'getContainerProtection', 'setContainerProtection',
    'getFilesystemInfo', 'listDirectories', 'createDirectory', 'renameDirectory',
    'deleteDirectory', 'getDirectoryAccess', 'setDirectoryAccess',
    'startResumableDownload', 'resumeDownload', 'abortDownload',
}
AZURE_ACTIONS = ACTIONS - {
    'planHistoryCopy', 'resumeHistoryCopy', 'inspectHistoryCopy', 'resolveHistoryCopy',
    'planBucketConfigurationCopy', 'applyBucketConfigurationCopy',
}


def handle(params, engine):
    return Workflows(engine).dispatch(params)


class Workflows:
    def __init__(self, engine):
        self.e = engine

    def fail(self, code, message):
        raise self.e.SidecarError(code, message)

    def dispatch(self, p):
        action = p['action']
        if action in {'planHistoryCopy', 'resumeHistoryCopy', 'inspectHistoryCopy', 'resolveHistoryCopy'}:
            return self.history(p)
        if action in {'planBucketConfigurationCopy', 'applyBucketConfigurationCopy'}:
            return self.configuration(p)
        if action in {'startResumableDownload', 'resumeDownload', 'abortDownload'}:
            return self.download(p)
        if action in {'startResumableUpload', 'resumeUpload', 'abortUpload'}:
            return self.azure_upload(p)
        return self.azure(p)

    def path(self, ident):
        if not re.fullmatch(r'(?:history|configuration|download|azureupload)-[a-f0-9]{32}', str(ident)):
            self.fail('invalid_config', 'Invalid workflow identifier.')
        return self.e._recovery_dir() / (ident + '.json')

    def write(self, state):
        state['updatedAt'] = self.e._now_iso()
        path = self.path(state['id'])
        tmp = path.with_suffix('.' + uuid.uuid4().hex + '.tmp')
        try:
            with tmp.open('x', encoding='utf-8') as output:
                os.chmod(tmp, 0o600)
                json.dump(state, output, default=self.e._serialize_dt)
                output.flush()
                os.fsync(output.fileno())
            os.replace(tmp, path)
            if os.name != 'nt':
                directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        finally:
            tmp.unlink(missing_ok=True)

    def read(self, ident):
        try:
            return json.loads(self.path(ident).read_text())
        except FileNotFoundError:
            self.fail('invalid_config', 'Workflow checkpoint was not found.')

    @contextmanager
    def lock(self, ident):
        # Same cross-process lock implementation as ordinary upload recovery.
        with self.path(ident).with_suffix('.lock').open('a+b') as handle:
            try:
                if os.name == 'nt':
                    import msvcrt
                    if handle.tell() == 0:
                        handle.write(b'0')
                        handle.flush()
                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                self.fail('conflict', 'This workflow is already active in another request.')
            try:
                yield
            finally:
                if os.name == 'nt':
                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def reference(self, payload):
        return self.e._recovery_profile_ref(payload)

    def endpoint_identity(self, payload):
        profile = self.e._parse_profile(payload)
        url = urlparse(profile.endpoint_url)
        return (url.scheme.lower(), (url.hostname or '').lower(),
                url.port or (443 if url.scheme == 'https' else 80), url.path.rstrip('/'))

    def clients(self, p):
        source, destination = p.get('sourceProfile') or {}, p.get('destinationProfile') or {}
        src, dst = self.e._parse_profile(source), self.e._parse_profile(destination)
        if src.endpoint_type == 'azureBlob' or dst.endpoint_type == 'azureBlob':
            self.fail('unsupported_feature', 'This workflow requires S3 source and destination endpoints.')
        a, b = str(p.get('sourceBucketName') or ''), str(p.get('destinationBucketName') or '')
        if not a or not b:
            self.fail('invalid_config', 'Source and destination buckets are required.')
        if a == b and self.endpoint_identity(source) == self.endpoint_identity(destination):
            self.fail('conflict', 'Source and destination identify the same bucket.')
        if p['action'] in {'planHistoryCopy', 'resumeHistoryCopy', 'inspectHistoryCopy', 'resolveHistoryCopy'}:
            dst = replace(dst, max_attempts=1)
        return self.e._build_client(src), self.e._build_client(dst), a, b

    def verify_refs(self, state, p):
        for field in ('source', 'destination'):
            if state[field + 'Ref'] != self.reference(p.get(field + 'Profile') or {}):
                self.fail('conflict', 'The workflow endpoint or profile identity changed.')
            if state[field + 'BucketName'] != p.get(field + 'BucketName'):
                self.fail('conflict', 'The workflow bucket identity changed.')

    def versions(self, client, bucket, prefix='', exact=None, maximum=100000):
        """Capture XML order because SDK separates versions and delete markers."""
        result, seen, cursor = [], set(), {}
        while True:
            raw_order = []
            caller = threading.get_ident()
            def capture(http_response=None, **_):
                if threading.get_ident() != caller or http_response is None:
                    return
                try:
                    root = ET.fromstring(http_response.content)
                    for child in root:
                        kind = child.tag.rsplit('}', 1)[-1]
                        if kind not in {'Version', 'DeleteMarker'}:
                            continue
                        fields = {n.tag.rsplit('}', 1)[-1]: n.text for n in child}
                        raw_order.append((fields.get('Key'), fields.get('VersionId')))
                except (ET.ParseError, AttributeError, TypeError):
                    return
            events = getattr(getattr(client, 'meta', None), 'events', None)
            event_id = 'history-' + uuid.uuid4().hex
            if events is not None:
                events.register('after-call.s3.ListObjectVersions', capture, unique_id=event_id)
            try:
                response = client.list_object_versions(Bucket=bucket, Prefix=prefix, MaxKeys=1000, **cursor)
            finally:
                if events is not None:
                    events.unregister('after-call.s3.ListObjectVersions', unique_id=event_id)
            rows = []
            for field, marker in [('Versions', False), ('DeleteMarkers', True)]:
                for item in response.get(field, []):
                    if exact is not None and item['Key'] != exact:
                        continue
                    identity = (item['Key'], str(item['VersionId']))
                    if identity in seen:
                        self.fail('invalid_response', 'Version listing repeated a version.')
                    seen.add(identity)
                    rows.append({'key': item['Key'], 'sourceVersionId': str(item['VersionId']),
                                 'deleteMarker': marker, 'modifiedAt': self.e._serialize_dt(item['LastModified']),
                                 'latest': bool(item.get('IsLatest')), 'size': int(item.get('Size') or 0),
                                 'etag': item.get('ETag')})
            if raw_order:
                ranks = {identity: index for index, identity in enumerate(raw_order)}
                rows.sort(key=lambda row: ranks[(row['key'], row['sourceVersionId'])])
            else:
                # Fakes and unusual providers may omit the raw response. Never
                # invent ordering between equal-time historical delete/content.
                rows.sort(key=lambda row: (row['key'], row['modifiedAt'], row['latest']), reverse=True)
                for first, second in zip(rows, rows[1:]):
                    if first['key'] == second['key'] and first['modifiedAt'] == second['modifiedAt'] and first['deleteMarker'] != second['deleteMarker'] and not first['latest']:
                        self.fail('unsupported_feature', 'Provider omitted ordering for equal-time versions and delete markers.')
            result.extend(rows)
            if len(result) > maximum:
                self.fail('invalid_config', 'History plan exceeds 100,000 versions; narrow the prefix and copy in batches.')
            if not response.get('IsTruncated'):
                return result
            next_cursor = {key: response.get('Next' + key) for key in ('KeyMarker', 'VersionIdMarker')}
            if not next_cursor['KeyMarker'] or next_cursor == cursor:
                self.fail('invalid_response', 'Version listing did not advance its cursor.')
            cursor = next_cursor

    def history_public(self, state):
        return {k: v for k, v in state.items() if k not in {'entries'}}

    def history(self, p):
        src, dst, a, b = self.clients(p)
        action = p['action']
        if action == 'planHistoryCopy':
            if src.get_bucket_versioning(Bucket=a).get('Status') not in {'Enabled', 'Suspended'}:
                self.fail('unsupported_feature', 'Source bucket must have version history enabled or suspended.')
            missing_destination = False
            try:
                if dst.get_bucket_versioning(Bucket=b).get('Status') != 'Enabled':
                    self.fail('conflict', 'Destination versioning must be enabled before planning history copy.')
            except Exception as error:
                if not p.get('createDestinationIfMissing') or self.e._client_error_code(error) not in {'NoSuchBucket', '404', 'NotFound'}:
                    raise
                missing_destination = True
            prefix = str(p.get('prefix') or '')
            if not missing_destination and self.versions(dst, b, prefix):
                self.fail('conflict', 'History copy requires an empty destination prefix, including historical versions and delete markers.')
            listed = self.versions(src, a, prefix)
            # Listing order is newest-first per exact key. Reverse each group.
            grouped = {}
            for row in listed:
                grouped.setdefault(row['key'], []).append(row)
            entries = [entry for key in sorted(grouped) for entry in reversed(grouped[key])]
            ident = 'history-' + uuid.uuid4().hex
            state = {'id': ident, 'recoveryId': ident, 'kind': 'historyCopy', 'status': 'planned',
                     'sourceRef': self.reference(p['sourceProfile']), 'destinationRef': self.reference(p['destinationProfile']),
                     'sourceBucketName': a, 'destinationBucketName': b, 'prefix': prefix,
                     'entries': entries, 'destinationInitiallyMissing': missing_destination, 'objectCount': len(grouped), 'versionCount': sum(not row['deleteMarker'] for row in entries),
                     'deleteMarkerCount': sum(row['deleteMarker'] for row in entries), 'completedCount': 0,
                     'mappings': [], 'createdAt': self.e._now_iso(),
                     'warnings': ['Provider version IDs and timestamps are regenerated at the destination.',
                                  'Object ACLs, retention, legal holds and bucket configuration are not copied by history replay.',
                                  'Use an idle destination prefix; cross-endpoint replay cannot atomically exclude outside writers.']}
            self.write(state)
            return self.history_public(state)
        ident = p.get('recoveryId')
        with self.lock(ident):
            state = self.read(ident)
            self.verify_refs(state, p)
            if action == 'inspectHistoryCopy' or state['status'] == 'completed':
                return self.history_public(state)
            if state.get('inFlight'):
                if action != 'resolveHistoryCopy':
                    state['status'] = 'outcomeUnknown'
                    self.write(state)
                    return self.history_public(state)
                # Explicit operator-supplied destination version must exist and
                # match the expected kind/content size; never infer a delete.
                supplied = p.get('destinationVersionId')
                if supplied is None:
                    self.fail('invalid_config', 'An inspected destination version ID is required to resolve the uncertain write.')
                entry = state['inFlight']
                actual = self.versions(dst, b, entry['key'], exact=entry['key'])
                matched = [v for v in actual if v['sourceVersionId'] == str(supplied)]
                if any(m['key'] == entry['key'] and m['destinationVersionId'] == str(supplied) for m in state['mappings']):
                    self.fail('conflict', 'This destination version is already mapped to an earlier history operation.')
                if len(matched) != 1 or matched[0]['deleteMarker'] != entry['deleteMarker'] or matched[0]['size'] != entry['size']:
                    self.fail('conflict', 'Destination version does not match the uncertain history operation.')
                if not entry['deleteMarker']:
                    head = dst.head_object(Bucket=b, Key=entry['key'], VersionId=str(supplied))
                    if (head.get('Metadata') or {}).get('object-browser-history-operation') != entry['operationId']:
                        self.fail('conflict', 'Destination version lacks this operation identity; cannot resolve it safely.')
                self.history_finish(state, entry, str(supplied))
                return self.history_public(state)
            if action == 'resolveHistoryCopy':
                self.fail('invalid_config', 'No uncertain history operation requires resolution.')
            if dst.get_bucket_versioning(Bucket=b).get('Status') != 'Enabled':
                self.fail('conflict', 'Destination versioning changed; history replay stopped.')
            # Verify exact source manifest before every resumed batch.
            current = self.versions(src, a, state['prefix'])
            planned = {(x['key'], x['sourceVersionId'], x['deleteMarker'], x['etag']) for x in state['entries']}
            if {(x['key'], x['sourceVersionId'], x['deleteMarker'], x['etag']) for x in current} != planned:
                self.fail('conflict', 'Source version history changed since planning. Create a new plan for an unchanged prefix.')
            state['status'] = 'running'
            self.write(state)
            maximum = min(100, max(1, int(p.get('maxEntries') or 25)))
            for entry in state['entries'][state['completedCount']:state['completedCount'] + maximum]:
                known = {m['destinationVersionId'] for m in state['mappings'] if m['key'] == entry['key']}
                actual = self.versions(dst, b, entry['key'], exact=entry['key'])
                if {v['sourceVersionId'] for v in actual} != known:
                    self.fail('conflict', 'Destination history changed outside this workflow.')
                operation = {**entry, 'operationId': uuid.uuid4().hex}
                if not entry['deleteMarker']:
                    head = src.head_object(Bucket=a, Key=entry['key'], VersionId=entry['sourceVersionId'])
                    metadata = {**head.get('Metadata', {}), 'object-browser-history-operation': operation['operationId']}
                state['inFlight'] = operation
                state['status'] = 'outcomeUnknown'
                self.write(state)
                try:
                    if entry['deleteMarker']:
                        response = dst.delete_object(Bucket=b, Key=entry['key'])
                        self.e._check_mutation_result(response, 'VersionId')
                        if not response.get('DeleteMarker'):
                            self.fail('invalid_response', 'Destination did not report a newly created delete marker.')
                        version = response['VersionId']
                    else:
                        response = self.e._storage_copy({
                            'sourceProfile': p['sourceProfile'], 'destinationProfile': {**p['destinationProfile'], 'maxAttempts': 1},
                            'sourceBucketName': a, 'destinationBucketName': b,
                            'sourceKey': entry['key'], 'destinationKey': entry['key'],
                            'sourceVersionId': entry['sourceVersionId'], 'expectedSourceETag': entry['etag'],
                            'conflictPolicy': 'replace', 'options': {'metadata': metadata}})
                        if response.get('successCount') != 1 or response.get('versionId') is None:
                            self.fail('invalid_response', 'History copy did not return a verified destination version.')
                        version = response['versionId']
                    self.history_finish(state, operation, version)
                except BaseException:
                    state['status'] = 'outcomeUnknown'
                    self.write(state)
                    raise
            state['status'] = 'completed' if state['completedCount'] == len(state['entries']) else 'running'
            self.write(state)
            return self.history_public(state)

    def history_finish(self, state, entry, version):
        state['mappings'].append({'key': entry['key'], 'sourceVersionId': entry['sourceVersionId'],
                                  'destinationVersionId': str(version), 'deleteMarker': entry['deleteMarker']})
        state['completedCount'] += 1
        state.pop('inFlight', None)
        state['status'] = 'running'
        self.write(state)

    CONFIG = {
        'lifecycle': ('get_bucket_lifecycle_configuration', 'put_bucket_lifecycle_configuration', 'LifecycleConfiguration', {'NoSuchLifecycleConfiguration'}),
        'cors': ('get_bucket_cors', 'put_bucket_cors', 'CORSConfiguration', {'NoSuchCORSConfiguration'}),
        'tags': ('get_bucket_tagging', 'put_bucket_tagging', 'Tagging', {'NoSuchTagSet'}),
        'policy': ('get_bucket_policy', 'put_bucket_policy', 'Policy', {'NoSuchBucketPolicy'}),
        'publicAccessBlock': ('get_public_access_block', 'put_public_access_block', 'PublicAccessBlockConfiguration', {'NoSuchPublicAccessBlockConfiguration'}),
    }

    def config_read(self, client, bucket, section):
        method, _, _, missing = self.CONFIG[section]
        try:
            data = self.e._clean_sdk(getattr(client, method)(Bucket=bucket))
        except Exception as error:
            if self.e._client_error_code(error) in missing:
                return None
            raise
        if section == 'policy':
            return json.loads(data['Policy'])
        if section == 'publicAccessBlock':
            return data['PublicAccessBlockConfiguration']
        return data

    def map_policy(self, policy, source, destination):
        mapped = json.loads(json.dumps(policy))
        statements = mapped.get('Statement', [])
        if isinstance(statements, dict):
            statements = [statements]
        if not isinstance(statements, list):
            self.fail('invalid_config', 'Bucket policy statements must be a list or object.')
        for statement in statements:
            if statement.get('Effect') == 'Allow':
                principal = statement.get('Principal')
                if not isinstance(principal, dict) or set(principal) != {'AWS'}:
                    self.fail('unsupported_feature', 'Policy copy permits only explicit AWS principals; public and service grants need destination review.')
                principals = principal['AWS'] if isinstance(principal['AWS'], list) else [principal['AWS']]
                if not principals or any(not isinstance(v, str) or '*' in v or '?' in v or '${' in v for v in principals):
                    self.fail('unsupported_feature', 'Wildcard and dynamic principal grants cannot be copied.')
            if 'NotResource' in statement or 'NotPrincipal' in statement:
                self.fail('unsupported_feature', 'Negative policy resource/principal selectors require manual destination review.')
            resources = statement.get('Resource')
            values = resources if isinstance(resources, list) else [resources]
            rewritten = []
            for value in values:
                if not isinstance(value, str):
                    self.fail('invalid_config', 'Policy resource must be an S3 ARN.')
                match = re.fullmatch(r'arn:(aws(?:-cn|-us-gov)?):s3:::' + re.escape(source) + r'(/.*)?', value)
                if not match:
                    self.fail('unsupported_feature', 'Policy contains a resource outside the exact source bucket.')
                rewritten.append(f'arn:{match[1]}:s3:::{destination}{match[2] or ""}')
            statement['Resource'] = rewritten if isinstance(resources, list) else rewritten[0]
            # SourceArn/SourceAccount/KMS conditions are not automatically safe
            # across accounts/endpoints; refuse rather than broaden a grant.
            if statement.get('Condition'):
                self.fail('unsupported_feature', 'Conditional policy statements require explicit destination authoring.')
        mapped['Statement'] = statements
        return mapped

    def configuration(self, p):
        src, dst, a, b = self.clients(p)
        if p['action'] == 'planBucketConfigurationCopy':
            sections = p.get('sections') or ['lifecycle', 'cors', 'tags']
            if any(section not in self.CONFIG for section in sections):
                self.fail('unsupported_feature', 'Configuration copy supports lifecycle, cors, tags, policy and publicAccessBlock only.')
            changes, blocked = [], []
            for section in dict.fromkeys(sections):
                try:
                    desired = self.config_read(src, a, section)
                    current = self.config_read(dst, b, section)
                    if desired is None:
                        continue  # Absence never deletes destination settings.
                    if section == 'policy':
                        desired = self.map_policy(desired, a, b)
                        if current and current != desired:
                            self.fail('conflict', 'Destination has a different policy; policy copy does not replace existing grants or denies.')
                    if section == 'publicAccessBlock':
                        desired = {key: bool(desired.get(key)) or bool((current or {}).get(key)) for key in
                                   ['BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets']}
                    if current != desired:
                        changes.append({'section': section, 'before': current, 'after': desired})
                except Exception as error:
                    code = error.code if isinstance(error, self.e.SidecarError) else self.e._client_error_code(error)
                    blocked.append({'section': section, 'code': code or 'unknown',
                                    'message': error.message if isinstance(error, self.e.SidecarError) else 'Configuration could not be read safely; check permissions.'})
            ident = 'configuration-' + uuid.uuid4().hex
            state = {'id': ident, 'planId': ident, 'kind': 'configurationCopy', 'status': 'planned',
                     'sourceRef': self.reference(p['sourceProfile']), 'destinationRef': self.reference(p['destinationProfile']),
                     'sourceBucketName': a, 'destinationBucketName': b, 'changes': changes, 'blocked': blocked,
                     'warnings': ['Review lifecycle expiration and transition actions before applying.',
                                  'Public access protections are never weakened. ACLs, KMS, replication, notifications and retention are excluded.'],
                     'appliedSections': [], 'createdAt': self.e._now_iso()}
            self.write(state)
            return state
        with self.lock(p.get('planId')):
            state = self.read(p['planId'])
            self.verify_refs(state, p)
            if state['blocked']:
                self.fail('conflict', 'This configuration plan has blocked sections; create a plan containing only compatible sections.')
            if state['status'] == 'completed':
                return state
            # Read every destination section before any mutation. A resumed
            # ambiguous PUT may be accepted only if the exact value is present.
            pending = []
            for change in state['changes']:
                current = self.config_read(dst, b, change['section'])
                if current == change['after']:
                    if change['section'] not in state['appliedSections']:
                        state['appliedSections'].append(change['section'])
                    continue
                if current != change['before']:
                    self.fail('conflict', 'Destination configuration changed after review. Refresh the plan.')
                pending.append(change)
            for change in pending:
                section, desired = change['section'], change['after']
                _, method, field, _ = self.CONFIG[section]
                kwargs = {'Bucket': b}
                if section == 'policy':
                    kwargs[field] = json.dumps(desired)
                elif section == 'lifecycle':
                    kwargs[field] = {'Rules': desired['Rules']}
                    if desired.get('TransitionDefaultMinimumObjectSize'):
                        kwargs['TransitionDefaultMinimumObjectSize'] = desired['TransitionDefaultMinimumObjectSize']
                else:
                    kwargs[field] = desired
                state['status'] = 'applying'
                state['inFlightSection'] = section
                self.write(state)
                getattr(dst, method)(**kwargs)
                if self.config_read(dst, b, section) != desired:
                    self.fail('conflict', 'Destination did not read back the reviewed configuration.')
                state['appliedSections'].append(section)
                state.pop('inFlightSection', None)
                self.write(state)
            state['status'] = 'completed'
            self.write(state)
            return state

    def azure(self, p):
        profile = self.e._parse_profile(p.get('profile') or {})
        if profile.endpoint_type != 'azureBlob':
            self.fail('unsupported_feature', 'This operation requires an Azure Blob profile.')
        client = self.e._build_azure_client(profile)
        action = p['action']
        if action == 'presignVersion':
            return self.azure_presign(p, client)
        if action in {'getObjectProtection', 'setObjectProtection'}:
            return self.blob_protection(p, client)
        if action in {'getAccountLifecycle', 'putAccountLifecycle', 'getContainerProtection', 'setContainerProtection'}:
            return self.management(p, client)
        return self.adls(p, profile, client)

    def azure_presign(self, p, client):
        if client.profile.auth_mode == 'azureSas':
            self.fail('unsupported_feature', 'An existing SAS cannot mint a narrower version grant. Use an account key or Azure Default credentials.')
        ref = self.e._object_ref(p)
        seconds = min(7 * 86400, max(1, int(p.get('expirationSeconds') or p.get('expiresSeconds') or 900)))
        now = datetime.now(timezone.utc)
        fmt = lambda value: value.strftime('%Y-%m-%dT%H:%M:%SZ')
        query = {'sp': 'r', 'st': fmt(now - timedelta(minutes=5)), 'se': fmt(now + timedelta(seconds=seconds)),
                 'spr': 'https' if client.scheme == 'https' else 'https,http', 'sv': '2023-11-03',
                 'sr': 'bv' if 'VersionId' in ref else 'b'}
        canonical = f"/blob/{client.account}/{ref['Bucket']}/{ref['Key']}"
        fields = [query['sp'], query['st'], query['se'], canonical]
        signing_key = client.key
        if client.credential is not None:
            root = ET.Element('KeyInfo')
            ET.SubElement(root, 'Start').text = query['st']
            # Delegation interval, including backdate, cannot exceed seven days.
            ET.SubElement(root, 'Expiry').text = fmt(now + timedelta(seconds=min(seconds, 7 * 86400 - 300)))
            query['se'] = root.findtext('Expiry')
            fields[2] = query['se']
            _, _, body = client.request('POST', query={'restype': 'service', 'comp': 'userdelegationkey'},
                                        headers={'Content-Type': 'application/xml'}, body=ET.tostring(root))
            delegated = self.e._azure_parse_xml(body)
            mapping = [('skoid', 'SignedOid'), ('sktid', 'SignedTid'), ('skt', 'SignedStart'),
                       ('ske', 'SignedExpiry'), ('sks', 'SignedService'), ('skv', 'SignedVersion')]
            for key, name in mapping:
                value = delegated.findtext(name)
                if not value:
                    self.fail('invalid_response', 'Azure omitted a delegation key field.')
                query[key] = value
                fields.append(value)
            fields.extend(['', '', ''])  # authorized/unauthorized OID and correlation ID, API 2023.
            try:
                signing_key = base64.b64decode(delegated.findtext('Value'), validate=True)
            except (TypeError, ValueError):
                self.fail('invalid_response', 'Azure returned an invalid delegation signing key.')
        else:
            fields.append('')  # Signed identifier for a service SAS.
        fields.extend(['', query['spr'], query['sv'], query['sr'], ref.get('VersionId', ''), '', '', '', '', '', ''])
        query['sig'] = base64.b64encode(hmac.new(signing_key, '\n'.join(fields).encode(), hashlib.sha256).digest()).decode()
        if 'VersionId' in ref:
            query['versionid'] = ref['VersionId']
        return {'url': client.base_url + client.blob_path(ref['Bucket'], ref['Key']) + '?' + urlencode(query),
                'expiresAt': query['se'], 'expiresSeconds': seconds, 'versionId': ref.get('VersionId')}

    def blob_protection(self, p, client):
        ref = self.e._object_ref(p)
        path = client.blob_path(ref['Bucket'], ref['Key'])
        query = {'versionid': ref['VersionId']} if 'VersionId' in ref else {}
        if p['action'] == 'setObjectProtection':
            retention = p.get('retention')
            if retention is not None:
                date = retention.get('RetainUntilDate') or retention.get('untilDate')
                mode = retention.get('Mode') or retention.get('mode') or 'Unlocked'
                mode = {'GOVERNANCE': 'Unlocked', 'COMPLIANCE': 'Locked'}.get(mode, mode)
                if mode not in {'Unlocked', 'Locked'}:
                    self.fail('invalid_config', 'Azure immutability mode must be Unlocked or Locked.')
                try:
                    until = datetime.fromisoformat(str(date).replace('Z', '+00:00'))
                    if until.tzinfo is None or until <= datetime.now(timezone.utc):
                        raise ValueError()
                except (TypeError, ValueError):
                    self.fail('invalid_config', 'Retention must have a future timezone-qualified untilDate.')
                headers = {'x-ms-immutability-policy-until-date': self.e.formatdate(until.timestamp(), usegmt=True),
                           'x-ms-immutability-policy-mode': mode}
                if p.get('expectedETag'):
                    headers['If-Match'] = p['expectedETag']
                client.request('PUT', path, query={**query, 'comp': 'immutabilityPolicies'}, headers=headers, body=b'')
            if p.get('legalHold') is not None:
                value = p['legalHold']
                if isinstance(value, dict):
                    value = value.get('Status') == 'ON'
                if not isinstance(value, bool):
                    self.fail('invalid_config', 'Legal hold must be true or false.')
                client.request('PUT', path, query={**query, 'comp': 'legalhold'},
                               headers={'x-ms-legal-hold': str(value).lower()}, body=b'')
        _, headers, _ = client.request('HEAD', path, query=query)
        return {'retention': {'Mode': headers.get('x-ms-immutability-policy-mode'),
                              'RetainUntilDate': headers.get('x-ms-immutability-policy-until-date')},
                'legalHold': {'Status': 'ON' if str(headers.get('x-ms-legal-hold')).lower() == 'true' else 'OFF'},
                'versionId': headers.get('x-ms-version-id'), 'etag': headers.get('ETag')}

    def management_request(self, p, client, method, suffix='', body=None, headers=None, missing=False):
        if client.profile.auth_mode != 'azureDefault' or client.credential is None:
            self.fail('unsupported_feature', 'Azure account management requires Azure Default credentials and management-plane RBAC; account keys/SAS cannot authorize it.')
        if not client.profile.verify_tls:
            self.fail('invalid_config', 'Azure management requires TLS certificate verification.')
        resource = str(p.get('accountResourceId') or '')
        pattern = r'/subscriptions/([a-zA-Z0-9-]+)/resourceGroups/([\w.() -]+)/providers/Microsoft.Storage/storageAccounts/([a-z0-9]{3,24})'
        match = re.fullmatch(pattern, resource)
        if not match or match[3] != client.account:
            self.fail('invalid_config', 'accountResourceId must identify the configured Azure storage account.')
        hostname = urlparse(client.base_url).hostname or ''
        if not hostname.endswith('.core.windows.net'):
            self.fail('unsupported_feature', 'Account management currently supports the Azure public cloud; sovereign/custom endpoints require their management authority.')
        token = client.credential.get_token('https://management.azure.com/.default').token
        url = 'https://management.azure.com' + quote(resource, safe='/') + suffix + '?api-version=2024-01-01'
        request_headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', **(headers or {})}
        import urllib3
        response = client.pool.request(method, url, headers=request_headers,
                                       body=None if body is None else json.dumps(body).encode(),
                                       timeout=urllib3.Timeout(connect=client.profile.connect_timeout_seconds,
                                                               read=client.profile.read_timeout_seconds),
                                       pool_timeout=client.profile.read_timeout_seconds,
                                       retries=False, redirect=False)
        try:
            if response.status == 404 and missing:
                return None
            if response.status >= 300:
                self.fail('auth_failed' if response.status in {401, 403} else 'conflict' if response.status == 412 else 'provider_error',
                          f'Azure management request failed with HTTP {response.status}; check management permissions and the resource ID.')
            result = json.loads(response.data or b'{}')
            if response.headers.get('ETag'):
                result.setdefault('etag', response.headers['ETag'])
            return result
        finally:
            response.release_conn()

    def management(self, p, client):
        action = p['action']
        if action in {'getAccountLifecycle', 'putAccountLifecycle'}:
            suffix = '/managementPolicies/default'
            current = self.management_request(p, client, 'GET', suffix, missing=True)
            policy = (current or {}).get('properties', {}).get('policy')
            if action == 'putAccountLifecycle':
                if 'expectedPolicy' not in p or p['expectedPolicy'] != policy:
                    self.fail('conflict', 'Refresh account lifecycle policy before applying changes.')
                desired = p.get('policy')
                if not isinstance(desired, dict) or not isinstance(desired.get('rules'), list):
                    self.fail('invalid_config', 'Azure lifecycle policy must contain a rules list.')
                # Scope is account-level and replacement semantics are explicit.
                self.management_request(p, client, 'PUT', suffix, body={'properties': {'policy': desired}},
                                        headers={'If-Match': current['etag']} if current and current.get('etag') else {})
                current = self.management_request(p, client, 'GET', suffix)
                policy = current.get('properties', {}).get('policy')
                if policy != desired:
                    self.fail('conflict', 'Azure lifecycle readback differs from the requested policy.')
            return {'policy': policy, 'etag': (current or {}).get('etag'), 'scope': 'storageAccount',
                    'state': 'absent' if current is None else 'supported'}
        bucket = str(p.get('bucketName') or '')
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,61}[a-z0-9]', bucket):
            self.fail('invalid_config', 'A valid Azure container name is required.')
        base = '/blobServices/default/containers/' + quote(bucket, safe='')
        suffix = base + '/immutabilityPolicies/default'
        current = self.management_request(p, client, 'GET', suffix, missing=True)
        if action == 'setContainerProtection':
            operation = p.get('operation') or 'set'
            etag = (current or {}).get('etag')
            if p.get('expectedETag') != etag:
                self.fail('conflict', 'Container immutability policy changed; refresh before editing.')
            headers = {'If-Match': etag} if etag else {}
            if operation == 'set':
                days = p.get('days')
                if isinstance(days, bool) or not isinstance(days, int) or not 1 <= days <= 146000:
                    self.fail('invalid_config', 'Retention days must be an integer between 1 and 146000.')
                self.management_request(p, client, 'PUT', suffix,
                                        body={'properties': {'immutabilityPeriodSinceCreationInDays': days}}, headers=headers)
            elif operation in {'lock', 'extend', 'delete'}:
                if not current:
                    self.fail('conflict', 'No container immutability policy exists.')
                if operation == 'delete':
                    self.management_request(p, client, 'DELETE', suffix, headers=headers)
                else:
                    body = None
                    if operation == 'extend':
                        days = p.get('days')
                        if not isinstance(days, int) or isinstance(days, bool) or days <= int(current.get('properties', {}).get('immutabilityPeriodSinceCreationInDays', 0)):
                            self.fail('invalid_config', 'Extension days must exceed the current retention period.')
                        body = {'properties': {'immutabilityPeriodSinceCreationInDays': days}}
                    self.management_request(p, client, 'POST', suffix + ('/lock' if operation == 'lock' else '/extend'), body=body, headers=headers)
            elif operation in {'setLegalHold', 'clearLegalHold'}:
                tags = p.get('tags')
                if not isinstance(tags, list) or not tags or any(not isinstance(v, str) or not re.fullmatch(r'[a-zA-Z0-9]{3,23}', v) for v in tags):
                    self.fail('invalid_config', 'Container legal hold requires alphanumeric tags of 3–23 characters.')
                self.management_request(p, client, 'POST', base + '/' + operation, body={'tags': tags})
            else:
                self.fail('invalid_config', 'Unsupported container protection operation.')
            current = self.management_request(p, client, 'GET', suffix, missing=True)
        container = self.management_request(p, client, 'GET', base)
        return {'configuration': (current or {}).get('properties'), 'etag': (current or {}).get('etag'),
                'legalHold': container.get('properties', {}).get('legalHold'), 'scope': 'container'}

    def adls(self, p, profile, client):
        # HNS is observed through an account read, never presumed from a path.
        _, info, _ = client.request('HEAD', query={'restype': 'account', 'comp': 'properties'})
        hns = str(info.get('x-ms-is-hns-enabled') or '').lower() == 'true'
        if not hns and p.get('accountResourceId'):
            account = self.management_request(p, client, 'GET')
            hns = account.get('properties', {}).get('isHnsEnabled') is True
        if p['action'] == 'getFilesystemInfo':
            return {'hnsEnabled': hns, 'state': 'supported' if hns else 'unsupported',
                    'reason': None if hns else 'Hierarchical namespace was not confirmed by the account.'}
        if not hns:
            self.fail('unsupported_feature', 'Directory operations require a confirmed hierarchical namespace account.')
        endpoint = urlparse(profile.endpoint_url)
        host = endpoint.hostname or ''
        if not re.fullmatch(r'[a-z0-9]+\.(?:privatelink\.)?(?:blob|dfs)\.core\.windows\.net', host) or endpoint.scheme != 'https' or endpoint.path not in {'', '/'}:
            self.fail('unsupported_feature', 'ADLS requires an Azure public-cloud Blob/DFS endpoint with a paired HTTPS authority.')
        dfs_url = endpoint._replace(netloc=endpoint.netloc.replace('.blob.', '.dfs.')).geturl()
        dfs = self.e._build_azure_client(replace(profile, endpoint_url=dfs_url))
        bucket, key = str(p.get('bucketName') or ''), str(p.get('key') or '')
        if not bucket or key.startswith('/') or any(part in {'.', '..'} for part in key.split('/')):
            self.fail('invalid_config', 'Use a filesystem name and exact relative directory path.')
        action = p['action']
        path = dfs.blob_path(bucket, key) if key else dfs.blob_path(bucket)
        cursor = p.get('cursor') or {}
        if action == 'listDirectories':
            query = {'resource': 'filesystem', 'recursive': 'false', 'maxResults': '1000'}
            if key: query['directory'] = key
            if cursor.get('value'): query['continuation'] = cursor['value']
            _, headers, body = dfs.request('GET', dfs.blob_path(bucket), query=query)
            document = json.loads(body)
            marker = headers.get('x-ms-continuation')
            if marker and marker == cursor.get('value'):
                self.fail('invalid_response', 'Directory listing cursor did not advance.')
            return {'items': document.get('paths', []), 'cursor': {'value': marker, 'hasMore': bool(marker)}}
        if not key:
            self.fail('invalid_config', 'A non-root directory path is required for this operation.')
        if action == 'createDirectory':
            _, headers, _ = dfs.request('PUT', path, query={'resource': 'directory'}, headers={'If-None-Match': '*'}, body=b'')
            return {'created': True, 'etag': headers.get('ETag')}
        if action == 'getDirectoryAccess':
            _, headers, _ = dfs.request('HEAD', path, query={'action': 'getAccessControl', 'upn': 'false'})
            return {key: headers.get('x-ms-' + key) for key in ['acl', 'permissions', 'owner', 'group']} | {'etag': headers.get('ETag')}
        if not p.get('expectedETag'):
            self.fail('invalid_config', 'Refresh the directory ETag before changing or deleting it.')
        if action == 'setDirectoryAccess':
            values = {name: p[name] for name in ('acl', 'permissions', 'owner', 'group') if p.get(name) is not None}
            if not values or ('acl' in values and 'permissions' in values):
                self.fail('invalid_config', 'Specify ACL or permissions, optionally owner/group; ACL and permissions are mutually exclusive.')
            if any(not isinstance(value, str) or '\n' in value or '\r' in value for value in values.values()):
                self.fail('invalid_config', 'Directory access fields must be single-line strings.')
            headers = {'If-Match': p['expectedETag'], **{'x-ms-' + name: value for name, value in values.items()}}
            dfs.request('PATCH', path, query={'action': 'setAccessControl'}, headers=headers, body=b'')
            return self.adls({**p, 'action': 'getDirectoryAccess'}, profile, client)
        if action == 'renameDirectory':
            destination = str(p.get('destinationKey') or '')
            if not destination or destination.startswith('/') or any(v in {'.', '..'} for v in destination.split('/')) or destination == key or destination.startswith(key.rstrip('/') + '/'):
                self.fail('invalid_config', 'Destination must be a different relative path outside the source directory.')
            source = dfs.blob_path(bucket, key)
            if profile.auth_mode == 'azureSas':
                source += '?' + profile.azure_sas_token
            headers = {'x-ms-rename-source': source, 'x-ms-source-if-match': p['expectedETag'], 'If-None-Match': '*'}
            query = {'mode': 'legacy'}
            if cursor.get('value'):
                query['continuation'] = cursor['value']
                headers.pop('If-None-Match')
                headers.pop('x-ms-source-if-match')
            _, result_headers, _ = dfs.request('PUT', dfs.blob_path(bucket, destination), query=query, headers=headers, body=b'')
            marker = result_headers.get('x-ms-continuation')
            return {'renamed': not bool(marker), 'cursor': {'value': marker, 'hasMore': bool(marker)}, 'etag': result_headers.get('ETag')}
        if action == 'deleteDirectory':
            recursive = p.get('recursive') is True
            query = {'recursive': str(recursive).lower()}
            if cursor.get('value'): query['continuation'] = cursor['value']
            _, headers, _ = dfs.request('DELETE', path, query=query, headers={'If-Match': p['expectedETag']})
            marker = headers.get('x-ms-continuation')
            return {'deleted': not bool(marker), 'cursor': {'value': marker, 'hasMore': bool(marker)}}
        self.fail('unsupported_feature', 'Unknown Azure directory operation.')

    def transfer_public(self, state):
        return {k: v for k, v in state.items() if k not in {'ranges', 'blocks', 'options'}}

    def transfer_event(self, state, control, done, total, size, status='running'):
        self.e._transfer_checkpoint(control, bytes_transferred=state['completedBytes'], items_completed=int(status == 'completed'),
                                    parts_completed=done, current_item_label=state['key'])
        self.e._emit_transfer_event(self.e._build_transfer_job(
            job_id=state['id'], label=control.label, direction=control.direction,
            progress=(state['completedBytes'] / size if size else int(status == 'completed')),
            status=status, bytes_transferred=state['completedBytes'], total_bytes=size,
            output_lines=[], current_item_label=state['key'], item_count=1,
            items_completed=int(status == 'completed'), part_size_bytes=state['partSize'],
            parts_completed=done, parts_total=total, can_pause=status == 'running', can_cancel=status == 'running'))

    def remote_head(self, client, azure, bucket, key, version=None):
        if azure:
            _, headers, _ = client.request('HEAD', client.blob_path(bucket, key),
                                           query={'versionid': version} if version is not None else {})
            return {'size': int(headers.get('Content-Length') or 0), 'etag': headers.get('ETag'),
                    'versionId': headers.get('x-ms-version-id') or version,
                    'metadata': {k[10:].lower(): v for k, v in headers.items() if k.lower().startswith('x-ms-meta-')}}
        head = client.head_object(Bucket=bucket, Key=key, **({'VersionId': version} if version is not None else {}))
        return {'size': int(head.get('ContentLength') or 0), 'etag': head.get('ETag'),
                'versionId': head.get('VersionId') or version, 'metadata': head.get('Metadata') or {}}

    def download(self, p):
        profile_payload = p.get('profile') or {}
        profile = self.e._parse_profile(profile_payload)
        azure = profile.endpoint_type == 'azureBlob'
        client = self.e._build_azure_client(profile) if azure else self.e._build_client(profile)
        if p['action'] == 'startResumableDownload':
            ref = self.e._object_ref(p)
            identity = self.remote_head(client, azure, ref['Bucket'], ref['Key'], ref.get('VersionId'))
            if not identity['etag']:
                self.fail('unsupported_feature', 'Resumable downloads require a stable remote ETag.')
            destination = Path(str(p.get('destinationDirectory') or p.get('destinationPath') or '')).expanduser().resolve()
            if not destination.is_dir():
                self.fail('invalid_config', 'Choose an existing download directory.')
            policy = p.get('conflictPolicy') or 'keepBoth'
            if policy not in {'replace', 'keepBoth'}:
                self.fail('invalid_config', 'Download conflict policy must be replace or keepBoth.')
            ident = 'download-' + uuid.uuid4().hex
            stage = destination / ('.' + ident + '.part')
            fd = os.open(stage, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
            os.close(fd)
            chunk = min(128, max(1, int(p.get('multipartChunkMiB') or 8))) * 1024**2
            state = {'id': ident, 'recoveryId': ident, 'kind': 'download', 'profileRef': self.reference(profile_payload),
                     'bucketName': ref['Bucket'], 'key': ref['Key'], 'versionId': identity['versionId'],
                     'remoteIdentity': {k: identity[k] for k in ('size', 'etag', 'versionId')},
                     'fileSize': identity['size'], 'filePath': str(destination / self.e._download_name(ref['Key'])),
                     'stagedPath': str(stage), 'partSize': chunk, 'ranges': [], 'completedBytes': 0,
                     'status': 'prepared', 'conflictPolicy': policy, 'createdAt': self.e._now_iso()}
            self.write(state)
        else:
            ident = p.get('recoveryId')
        with self.lock(ident):
            state = self.read(ident)
            if state.get('kind') != 'download' or state['profileRef'] != self.reference(profile_payload):
                self.fail('conflict', 'The download endpoint or profile identity changed.')
            if state['status'] in {'completed', 'aborted'}:
                return self.transfer_public(state)
            stage = Path(state['stagedPath'])
            if stage.name != '.' + ident + '.part' or stage.parent != Path(state['filePath']).parent or stage.is_symlink():
                self.fail('conflict', 'The staged download path no longer matches its checkpoint.')
            if p['action'] == 'abortDownload':
                stage.unlink(missing_ok=True)
                state['status'] = 'aborted'
                self.write(state)
                return self.transfer_public(state)
            if state['status'] == 'publishing':
                target = Path(state['filePath'])
                if target.is_file() and not target.is_symlink() and self.e._file_identity(target)['sha256'] == state.get('sha256'):
                    state['status'] = 'completed'
                    stage.unlink(missing_ok=True)
                    self.write(state)
                    return self.transfer_public(state)
                if not stage.exists():
                    self.fail('conflict', 'Download publication outcome cannot be verified; inspect the destination file.')
            identity = self.remote_head(client, azure, state['bucketName'], state['key'], state['versionId'])
            if any(identity[k] != state['remoteIdentity'][k] for k in ('size', 'etag', 'versionId')):
                self.fail('conflict', 'Remote object identity changed; the old ranges cannot be resumed.')
            return self.e._run_transfer(lambda _: self.execute_download(p, state, profile, client, azure), p)

    def execute_download(self, p, state, profile, client, azure):
        size, chunk = state['fileSize'], state['partSize']
        total = (size + chunk - 1) // chunk
        control = self.e._register_transfer(self.e.TransferControl(job_id=state['id'], label='Recoverable download ' + state['key'],
                                                                  direction='download', total_bytes=size, item_count=1,
                                                                  strategy_label='Recoverable range download', part_size_bytes=chunk, parts_total=total))
        stage = Path(state['stagedPath'])
        if not stage.exists():
            self.fail('conflict', 'The staged download file is missing.')
        fd = os.open(stage, os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0))
        try:
            with os.fdopen(fd, 'r+b', closefd=True) as output:
                valid = []
                for item in state['ranges']:
                    output.seek(item['start'])
                    data = output.read(item['length'])
                    if len(data) == item['length'] and hashlib.sha256(data).hexdigest() == item['sha256']:
                        valid.append(item)
                state['ranges'] = valid
                state['completedBytes'] = sum(item['length'] for item in valid)
                state['status'] = 'downloading'
                self.write(state)
                self.transfer_event(state, control, len(valid), total, size)
                done = {item['start'] for item in valid}
                starts = (start for start in range(0, size, chunk) if start not in done)
                limit = min(128, max(1, int(p.get('maxRanges') or 32)))
                def receive(start):
                    self.e._transfer_gate(control)
                    end = min(size, start + chunk) - 1
                    version = state['versionId']
                    if azure:
                        response = client.open('GET', client.blob_path(state['bucketName'], state['key']),
                                               query={'versionid': version} if version is not None else {},
                                               headers={'Range': f'bytes={start}-{end}', 'If-Match': state['remoteIdentity']['etag']})
                        header = response.headers.get('Content-Range', '')
                        try: data = response.read(chunk + 1)
                        finally: response.close()
                    else:
                        response = client.get_object(Bucket=state['bucketName'], Key=state['key'],
                                                     **({'VersionId': version} if version is not None else {}),
                                                     Range=f'bytes={start}-{end}', IfMatch=state['remoteIdentity']['etag'])
                        header = response.get('ContentRange', '')
                        try: data = response['Body'].read(chunk + 1)
                        finally: response['Body'].close()
                    self.e._validate_download_range(header, start, end, size, len(data))
                    return start, data
                import itertools
                with self.e.ThreadPoolExecutor(max_workers=min(8, profile.max_pool_connections)) as pool:
                    for future in self.e._bounded_parallel(pool, receive, itertools.islice(starts, limit), min(8, profile.max_pool_connections)):
                        start, data = future.result()
                        self.e._transfer_gate(control)
                        output.seek(start)
                        output.write(data)
                        output.flush()
                        os.fsync(output.fileno())
                        state['ranges'].append({'start': start, 'length': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
                        state['completedBytes'] += len(data)
                        self.write(state)
                        self.transfer_event(state, control, len(state['ranges']), total, size)
                if state['completedBytes'] != size:
                    state['status'] = 'paused'
                    self.write(state)
                    return self.transfer_public(state)
                output.truncate(size)
                output.flush()
                os.fsync(output.fileno())
            self.e._transfer_gate(control)
            state['sha256'] = self.e._file_identity(stage)['sha256']
            target = Path(state['filePath'])
            if state['conflictPolicy'] == 'keepBoth':
                initial = target
                index = 1
                while target.exists():
                    target = initial.with_name(initial.stem + f' ({index})' + initial.suffix)
                    index += 1
                state['filePath'] = str(target)
            state['status'] = 'publishing'
            self.write(state)
            if state['conflictPolicy'] == 'replace':
                os.replace(stage, target)
            else:
                os.link(stage, target)  # Atomic, never overwrite a raced-in file.
                stage.unlink()
            state['status'] = 'completed'
            self.write(state)
            self.transfer_event(state, control, total, total, size, 'completed')
            return self.transfer_public(state)
        except BaseException as error:
            if state['status'] != 'publishing':
                state['status'] = 'paused'
            self.write(state)
            if isinstance(error, self.e._TransferCancelled):
                return self.transfer_public(state)
            raise

    def azure_upload(self, p):
        payload = p.get('profile') or {}
        profile = self.e._parse_profile(payload)
        if profile.endpoint_type != 'azureBlob':
            self.fail('unsupported_feature', 'This block recovery workflow requires Azure Blob.')
        client = self.e._build_azure_client(profile)
        if p['action'] == 'startResumableUpload':
            if (p.get('options') or {}).get('encryption'):
                self.fail('unsupported_feature', 'Azure recovery uses account/container encryption; per-upload S3 encryption options cannot be applied.')
            file = Path(str(p.get('filePath') or '')).expanduser().resolve()
            if not file.is_file():
                self.fail('invalid_config', 'Choose an existing source file.')
            identity = self.e._file_identity(file)
            size = identity['size']
            chunk = max(self.e._azure_block_size(size), min(128, max(1, int(p.get('multipartChunkMiB') or 8))) * 1024**2)
            ref = self.e._object_ref(p)
            policy = p.get('conflictPolicy') or 'replace'
            if policy not in {'replace', 'overwrite', 'skip', 'fail'}:
                self.fail('invalid_config', 'Upload conflict policy must be replace, skip or fail.')
            try:
                head = self.remote_head(client, True, ref['Bucket'], ref['Key'])
            except self.e.SidecarError as error:
                if error.details.get('httpStatus') != 404:
                    raise
                head = None
            if head and policy in {'skip', 'fail'}:
                if policy == 'fail':
                    self.fail('conflict', 'Destination blob already exists.')
                return {'status': 'skipped', 'completedBytes': 0, 'key': ref['Key'], 'bucketName': ref['Bucket']}
            ident = 'azureupload-' + uuid.uuid4().hex
            state = {'id': ident, 'recoveryId': ident, 'kind': 'azureBlockUpload', 'profileRef': self.reference(payload),
                     'bucketName': ref['Bucket'], 'key': ref['Key'], 'filePath': str(file), 'fileSize': size,
                     'sourceIdentity': identity, 'partSize': chunk, 'blocks': [], 'completedBytes': 0,
                     'destinationETag': (head or {}).get('etag'), 'status': 'prepared',
                     'options': self.e._copy_options({}, p.get('options') or {}), 'createdAt': self.e._now_iso()}
            self.write(state)
        else:
            ident = p.get('recoveryId')
        with self.lock(ident):
            state = self.read(ident)
            if state.get('kind') != 'azureBlockUpload' or state['profileRef'] != self.reference(payload):
                self.fail('conflict', 'Azure upload endpoint or profile identity changed.')
            if state['status'] in {'completed', 'aborted'}:
                return self.transfer_public(state)
            if state['status'] == 'completionUnknown':
                self.azure_verify_upload(state, client)
                return self.transfer_public(state)
            if p['action'] == 'abortUpload':
                # Azure has no delete-single-uncommitted-block API. Never clear
                # a blob or another uploader's blocks to fake an abort.
                state.update(status='aborted', cleanupRequired=False,
                             cleanupNote='Uncommitted blocks expire on Azure after seven days of inactivity; the committed blob was not changed.')
                self.write(state)
                return self.transfer_public(state)
            if self.e._file_identity(Path(state['filePath'])) != state['sourceIdentity']:
                self.fail('conflict', 'Source file identity changed; start a new upload.')
            return self.e._run_transfer(lambda _: self.execute_azure_upload(p, state, profile, client), p)

    def azure_verify_upload(self, state, client):
        try:
            head = self.remote_head(client, True, state['bucketName'], state['key'], state.get('versionId'))
        except Exception:
            state['requiresVerification'] = True
            self.write(state)
            return False
        if head['size'] == state['fileSize'] and head['metadata'].get('object_browser_recovery_id') == state['id'] and head['metadata'].get('object_browser_source_sha256') == state['sourceIdentity']['sha256']:
            state.update(status='completed', completedBytes=state['fileSize'], versionId=head['versionId'], requiresVerification=False)
            self.write(state)
            return True
        state['requiresVerification'] = True
        self.write(state)
        return False

    def execute_azure_upload(self, p, state, profile, client):
        size, chunk = state['fileSize'], state['partSize']
        total = (size + chunk - 1) // chunk
        control = self.e._register_transfer(self.e.TransferControl(job_id=state['id'], label='Recoverable Azure upload ' + state['key'],
                                                                  direction='upload', total_bytes=size, item_count=1,
                                                                  strategy_label='Recoverable Azure blocks', part_size_bytes=chunk, parts_total=total))
        path = client.blob_path(state['bucketName'], state['key'])
        try:
            try:
                _, _, body = client.request('GET', path, query={'comp': 'blocklist', 'blocklisttype': 'uncommitted'})
                root = self.e._azure_parse_xml(body)
                remote = {node.findtext('Name'): int(node.findtext('Size') or 0) for node in root.iterfind('UncommittedBlocks/Block')}
            except self.e.SidecarError as error:
                if error.details.get('httpStatus') != 404:
                    raise
                remote = {}
            state['blocks'] = [block for block in state['blocks'] if remote.get(block['id']) == block['size']]
            state['completedBytes'] = sum(block['size'] for block in state['blocks'])
            state['status'] = 'uploading'
            self.write(state)
            self.transfer_event(state, control, len(state['blocks']), total, size)
            done = {block['number'] for block in state['blocks']}
            def upload(number):
                self.e._transfer_gate(control)
                with Path(state['filePath']).open('rb') as source:
                    source.seek(number * chunk)
                    length = min(chunk, size - number * chunk)
                    md5, sha = hashlib.md5(), hashlib.sha256()
                    remaining = length
                    while remaining:
                        data = source.read(min(1024**2, remaining))
                        if not data:
                            self.fail('conflict', 'Source file became shorter during block upload.')
                        md5.update(data)
                        sha.update(data)
                        remaining -= len(data)
                    ident = base64.b64encode((state['id'].split('-', 1)[1] + f'{number:08d}').encode()).decode()
                    client.request('PUT', path, query={'comp': 'block', 'blockid': ident},
                                   headers={'Content-MD5': base64.b64encode(md5.digest()).decode()},
                                   body=self.e._FilePart(source, number * chunk, length))
                return {'id': ident, 'number': number, 'size': length, 'sha256': sha.hexdigest()}
            import itertools
            limit = min(128, max(1, int(p.get('maxParts') or 32)))
            pending = itertools.islice((number for number in range(total) if number not in done), limit)
            with self.e.ThreadPoolExecutor(max_workers=min(8, profile.max_pool_connections)) as pool:
                for future in self.e._bounded_parallel(pool, upload, pending, min(8, profile.max_pool_connections)):
                    block = future.result()
                    state['blocks'].append(block)
                    state['completedBytes'] += block['size']
                    self.write(state)
                    self.transfer_event(state, control, len(state['blocks']), total, size)
            if len(state['blocks']) != total:
                state['status'] = 'paused'
                self.write(state)
                return self.transfer_public(state)
            self.e._transfer_gate(control)
            if self.e._file_identity(Path(state['filePath'])) != state['sourceIdentity']:
                self.fail('conflict', 'Source file changed during upload.')
            headers = {'Content-Type': 'application/xml'}
            headers.update({'If-Match': state['destinationETag']} if state['destinationETag'] else {'If-None-Match': '*'})
            options = state['options']
            headers.update({'x-ms-meta-' + key: str(value) for key, value in options.get('Metadata', {}).items()})
            headers.update({'x-ms-meta-object_browser_recovery_id': state['id'],
                            'x-ms-meta-object_browser_source_sha256': state['sourceIdentity']['sha256']})
            for aws, http in self.e._COPY_HEADERS.items():
                if aws in options:
                    headers['x-ms-blob-' + http.lower()] = str(options[aws])
            if options.get('StorageClass'):
                headers['x-ms-access-tier'] = options['StorageClass']
            root = ET.Element('BlockList')
            for block in sorted(state['blocks'], key=lambda value: value['number']):
                ET.SubElement(root, 'Uncommitted').text = block['id']
            state['status'] = 'completionUnknown'
            self.write(state)
            _, result, _ = client.request('PUT', path, query={'comp': 'blocklist'}, headers=headers, body=ET.tostring(root))
            state['versionId'] = result.get('x-ms-version-id')
            self.azure_verify_upload(state, client)
            if state['status'] == 'completed':
                self.transfer_event(state, control, total, total, size, 'completed')
            return self.transfer_public(state)
        except BaseException as error:
            if state['status'] == 'completionUnknown':
                self.azure_verify_upload(state, client)
                return self.transfer_public(state)
            state['status'] = 'paused'
            self.write(state)
            if isinstance(error, self.e._TransferCancelled):
                return self.transfer_public(state)
            raise
