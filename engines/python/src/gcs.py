"""Native Cloud Storage JSON API; no Google SDK or persistent credentials."""
from __future__ import annotations

import base64
import hashlib
import json
import re
import socket
import ssl
import threading
import time
import uuid
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, quote, urlencode, urlparse


_CLIENTS = OrderedDict()
_LOCK = threading.RLock()
_SCOPE = 'https://www.googleapis.com/auth/devstorage.read_write'
_UNIT = 256 * 1024
_TRANSIENT = {429, 500, 502, 503, 504}
_CONTROLS = {'health', 'pauseTransfer', 'resumeTransfer', 'cancelTransfer'}


def _url(value):
    parsed = urlparse(value)
    if parsed.scheme not in {'https', 'http'} or not parsed.netloc or parsed.username or parsed.password or parsed.fragment:
        raise ValueError('Invalid URL')
    return parsed


@contextmanager
def _secret_scope(e, client):
    with client.token_lock, e._CUSTOMER_KEYS_LOCK:
        for value in client.secrets:
            e._CUSTOMER_KEYS[value] = e._CUSTOMER_KEYS.get(value, 0) + 1
        client.active_scopes += 1
    try:
        yield
    finally:
        with client.token_lock, e._CUSTOMER_KEYS_LOCK:
            client.active_scopes -= 1
            for value in client.secrets:
                e._CUSTOMER_KEYS[value] -= 1
                if not e._CUSTOMER_KEYS[value]:
                    del e._CUSTOMER_KEYS[value]


class Client:
    def __init__(self, profile, e):
        self.profile, self.e = profile, e
        from cryptography.exceptions import UnsupportedAlgorithm
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey
            key = json.loads(profile.secret_key)
            self.email = key['client_email']
            self.project = key['project_id']
            self.token_uri = key['token_uri']
            pem = key['private_key']
            if not all(isinstance(value, str) and value.strip() for value in
                       (self.email, self.project, self.token_uri, pem)):
                raise ValueError('Missing key fields')
            _url(self.token_uri)
            self.key = serialization.load_pem_private_key(pem.encode(), password=None)
            if not isinstance(self.key, RSAPrivateKey):
                raise ValueError('RSA key required')
        except (ValueError, TypeError, KeyError, AttributeError, UnsupportedAlgorithm):
            raise e.SidecarError('invalid_config', 'Invalid Cloud Storage service-account key file.') from None
        self.secrets = {value for value in {profile.secret_key, pem, *pem.splitlines()} if value}
        self.base = (profile.endpoint_url or 'https://storage.googleapis.com').rstrip('/')
        try:
            parsed = _url(self.base)
            if parsed.query:
                raise ValueError('Endpoint query')
        except ValueError:
            raise e.SidecarError('invalid_config', 'Invalid Cloud Storage endpoint URL.') from None
        self.netloc = parsed.netloc
        import urllib3
        context = ssl.create_default_context(cafile=profile.ca_bundle_path or None)
        if not profile.verify_tls:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        self.pool = urllib3.PoolManager(num_pools=4, maxsize=profile.max_pool_connections,
            block=True, ssl_context=context, cert_reqs='CERT_REQUIRED' if profile.verify_tls else 'CERT_NONE')
        self.token, self.expires = '', 0
        self.token_lock = threading.RLock()
        self.active_scopes = 0

    def remember(self, value):
        if not value:
            return
        with self.token_lock, self.e._CUSTOMER_KEYS_LOCK:
            if value not in self.secrets:
                self.secrets.add(value)
                if self.active_scopes:
                    self.e._CUSTOMER_KEYS[value] = self.e._CUSTOMER_KEYS.get(value, 0) + self.active_scopes

    def sign(self, value):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding
        return self.key.sign(value, padding.PKCS1v15(), hashes.SHA256())

    def clean(self, value):
        with self.token_lock:
            for secret in self.secrets:
                value = value.replace(secret, '[redacted]')
        return value

    def error(self, status, data):
        reason = 'Unknown'
        try:
            error = json.loads(data)['error']
            if isinstance(error, dict):
                reason = str((error.get('errors') or [{}])[0].get('reason') or error.get('status') or reason)
            elif isinstance(error, str):
                reason = error
        except (ValueError, TypeError, KeyError, IndexError, AttributeError):
            pass
        # Service messages can echo credentials or session URIs. Only expose a
        # bounded reason identifier, with known secrets removed, never raw bodies.
        reason = self.clean(reason)
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', reason):
            reason = 'Unknown'
        code = {401: 'auth_failed', 403: 'auth_failed', 409: 'object_conflict',
                412: 'object_conflict', 429: 'throttled', 408: 'timeout', 504: 'timeout'}.get(status, 'unknown')
        return self.e.SidecarError(code, f'Cloud Storage request failed with HTTP {status} ({reason}).',
                                  {'provider': 'gcs', 'httpStatus': status, 'reason': reason})

    def _send(self, method, url, headers, body, retry=False):
        import urllib3
        try:
            return self.pool.request(method, url, headers=headers, body=body, preload_content=False,
                redirect=False, decode_content=False, pool_timeout=self.profile.read_timeout_seconds,
                timeout=urllib3.Timeout(connect=self.profile.connect_timeout_seconds, read=self.profile.read_timeout_seconds),
                retries=urllib3.Retry(total=max(0, self.profile.max_attempts - 1) if retry else 0,
                    allowed_methods={method} if retry else set(), status_forcelist=_TRANSIENT,
                    backoff_factor=0.2, raise_on_status=False))
        except (socket.timeout, TimeoutError, urllib3.exceptions.TimeoutError):
            raise self.e.SidecarError('timeout', 'Cloud Storage request timed out.', {'provider': 'gcs'}) from None
        except (ssl.SSLError, urllib3.exceptions.SSLError):
            raise self.e.SidecarError('tls_error', 'Cloud Storage TLS connection failed.', {'provider': 'gcs'}) from None
        except (OSError, urllib3.exceptions.HTTPError) as error:
            reason = getattr(error, 'reason', None)
            code = 'timeout' if isinstance(reason, urllib3.exceptions.TimeoutError) else 'tls_error' if isinstance(reason, urllib3.exceptions.SSLError) else 'engine_unavailable'
            raise self.e.SidecarError(code, 'Cloud Storage transport failed.', {'provider': 'gcs'}) from None

    def access_token(self, rejected=None):
        with self.token_lock:
            if self.token and time.time() < self.expires - 60 and (rejected is None or self.token != rejected):
                return self.token
            now = int(time.time())
            def encode(value):
                return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).rstrip(b'=')
            unsigned = encode({'alg': 'RS256', 'typ': 'JWT'}) + b'.' + encode({
                'iss': self.email, 'scope': _SCOPE, 'aud': self.token_uri, 'iat': now, 'exp': now + 3600})
            assertion = (unsigned + b'.' + base64.urlsafe_b64encode(self.sign(unsigned)).rstrip(b'=')).decode()
            body = urlencode({'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion': assertion}).encode()
            response = self._send('POST', self.token_uri,
                {'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': str(len(body))}, body)
            try:
                data = response.read()
                if response.status >= 400:
                    raise self.error(response.status, data)
                value = json.loads(data)
                token, expires = value['access_token'], int(value['expires_in'])
                if not isinstance(token, str) or not token or expires <= 0:
                    raise ValueError('Invalid token')
            except (ValueError, KeyError, TypeError):
                raise self.e.SidecarError('auth_failed', 'Cloud Storage token response is invalid.', {'provider': 'gcs'}) from None
            finally:
                response.close()
                response.release_conn()
            self.token, self.expires = token, time.time() + expires
            self.remember(token)
            return token

    def path(self, bucket, key=None):
        path = '/storage/v1/b/' + quote(bucket, safe='')
        if key is not None:
            path += '/o/' + quote(key, safe='')
        return path

    def open(self, method, path, query=None, headers=None, body=None):
        # Session URLs are opaque bearer credentials. Never log the path, URL,
        # response body or Location; diagnostics contain only operation/status.
        url = path if path.startswith(('https://', 'http://')) else self.base + path
        if query:
            url += ('&' if '?' in url else '?') + urlencode(query, quote_via=quote)
        request_headers = dict(headers or {})
        if body is not None:
            request_headers['Content-Length'] = str(len(body))
            request_headers.setdefault('Content-Type', 'application/octet-stream')
        token = self.access_token()
        for attempt in range(2):
            request_headers['Authorization'] = 'Bearer ' + token
            if self.profile.enable_api_logging:
                self.e._emit_structured_log('API', 'HttpSend', f'GCS SEND {method}', 'api')
            response = self._send(method, url, request_headers, body, retry=method in {'GET', 'HEAD'})
            if self.profile.enable_api_logging:
                self.e._emit_structured_log('API', 'HttpReceive', f'GCS RECV {method} STATUS={response.status}', 'api')
            if response.status == 401 and attempt == 0:
                response.read()
                response.close()
                response.release_conn()
                token = self.access_token(rejected=token)
                if body is not None and hasattr(body, 'seek'):
                    body.seek(0)
                continue
            if response.status >= 400 and response.status != 499:
                try:
                    raise self.error(response.status, response.read())
                finally:
                    response.close()
                    response.release_conn()
            return response

    def request(self, method, path, query=None, headers=None, body=None):
        response = self.open(method, path, query, headers, body)
        try:
            return response.status, response.headers, response.read()
        finally:
            response.close()
            response.release_conn()

    def json(self, method, path, query=None, value=None):
        _, _, data = self.request(method, path, query,
            {'Content-Type': 'application/json'} if value is not None else None,
            json.dumps(value).encode() if value is not None else None)
        try:
            result = json.loads(data) if data else {}
            if not isinstance(result, dict):
                raise ValueError('Expected object')
            return result
        except (ValueError, TypeError):
            raise self.e.SidecarError('invalid_response', 'Cloud Storage returned invalid JSON.', {'provider': 'gcs'}) from None


def _client(profile, e, profile_id=''):
    cache_key = (profile_id, profile)
    with _LOCK:
        client = _CLIENTS.get(cache_key)
        if client is None:
            client = Client(profile, e)
            _CLIENTS[cache_key] = client
        _CLIENTS.move_to_end(cache_key)
        while len(_CLIENTS) > 16:
            _, removed = _CLIENTS.popitem(last=False)
            removed.pool.clear()
        return client


def _required(params, e, *names):
    values = tuple(str(params.get(name) or '') for name in names)
    if not all(values):
        raise e.SidecarError('invalid_config', 'Required Cloud Storage target fields are missing.')
    return values


def _bucket(item):
    return {'name': item['name'], 'region': item.get('location', ''), 'objectCountHint': 0,
            'versioningEnabled': bool(item.get('versioning', {}).get('enabled')),
            'createdAt': item.get('timeCreated', '1970-01-01T00:00:00+00:00')}


def _listing(client, path, query, token=None):
    if token:
        query['pageToken'] = token
    result = client.json('GET', path, query)
    following = result.get('nextPageToken') or None
    if following and following == token:
        raise client.e.SidecarError('invalid_response', 'Cloud Storage returned a repeated listing cursor.')
    return result, following


def _buckets(client):
    if client.profile.known_bucket:
        return [_bucket(client.json('GET', client.path(client.profile.known_bucket)))]
    items, seen, token = [], set(), None
    while True:
        page, token = _listing(client, '/storage/v1/b', {'project': client.project, 'maxResults': 1000}, token)
        items.extend(_bucket(item) for item in page.get('items', []))
        if not token:
            return items
        if token in seen:
            raise client.e.SidecarError('invalid_response', 'Cloud Storage returned a repeated bucket listing cursor.')
        seen.add(token)


def _objects(params, client, versions=False):
    e = client.e
    bucket, = _required(params, e, 'bucketName')
    options = params.get('options') or {}
    key = str(params.get('key') or '') if versions else ''
    prefix = (key or (str(options.get('filterValue') or '') if options.get('filterMode', 'prefix') == 'prefix' else '')) if versions else str(params.get('prefix') or '')
    query = {'prefix': prefix, 'maxResults': 1000}
    if versions:
        query['versions'] = 'true'
    elif not params.get('flat'):
        query['delimiter'] = '/'
    token = (params.get('cursor') or {}).get('value')
    page, following = _listing(client, client.path(bucket) + '/o', query, token)
    items, live_generations = [], {}
    for item in page.get('items', []):
        name = item['name']
        if versions:
            if key and name != key:
                continue
            # Generations are opaque, never infer latest by numeric ordering.
            # timeDeleted marks noncurrent versions when present; otherwise ask
            # for the live generation (also handles keys with no live version).
            if 'timeDeleted' in item:
                latest = False
            else:
                if name not in live_generations:
                    try:
                        live = client.json('GET', client.path(bucket, name))
                        live_generations[name] = str(live.get('generation') or '')
                    except e.SidecarError as error:
                        if error.details.get('httpStatus') != 404:
                            raise
                        live_generations[name] = ''
                latest = live_generations[name] == str(item.get('generation'))
            items.append({'key': name, 'versionId': str(item['generation']),
                'latest': latest, 'deleteMarker': False, 'size': int(item.get('size', 0)),
                'storageClass': item.get('storageClass', 'STANDARD'), 'modifiedAt': item.get('updated', '')})
        else:
            if not params.get('flat') and name == prefix:
                continue
            items.append({'key': name, 'name': name[len(prefix):] if name.startswith(prefix) else name,
                'size': int(item.get('size', 0)), 'storageClass': item.get('storageClass', 'STANDARD'),
                'modifiedAt': item.get('updated', ''), 'isFolder': False, 'etag': item.get('etag'),
                'metadataCount': len(item.get('metadata') or {})})
    if versions:
        items.sort(key=lambda item: item['modifiedAt'], reverse=True)
        return {'items': items, 'cursor': {'value': following, 'hasMore': bool(following)},
                'totalCount': len(items), 'versionCount': len(items), 'deleteMarkerCount': 0}
    for name in page.get('prefixes', []):
        items.append({'key': name, 'name': name[len(prefix):], 'size': 0,
            'storageClass': 'FOLDER', 'modifiedAt': '', 'isFolder': True, 'etag': None, 'metadataCount': 0})
    items.sort(key=lambda item: (not item['isFolder'], item['key'].lower()))
    return {'items': items, 'nextCursor': {'value': following, 'hasMore': bool(following)}}


def _admin(params, client):
    bucket, = _required(params, client.e, 'bucketName')
    item = client.json('GET', client.path(bucket))
    enabled = bool(item.get('versioning', {}).get('enabled'))
    reason = 'Cloud Storage administration requires provider-specific schemas.'
    sections = {name: {'state': 'unsupported', 'message': reason} for name in
        ('GetBucketLifecycleConfiguration', 'GetBucketPolicy', 'GetBucketCors',
         'GetBucketEncryption', 'GetBucketTagging', 'GetObjectLockConfiguration')}
    sections['GetBucketVersioning'] = {'state': 'supported', 'message': ''}
    return {'bucketName': bucket, 'versioningEnabled': enabled,
        'versioningStatus': 'Enabled' if enabled else 'Disabled',
        'objectLockEnabled': False, 'lifecycleEnabled': False, 'policyAttached': False,
        'corsEnabled': False, 'encryptionEnabled': False, 'encryptionSummary': 'Unsupported',
        'tags': {}, 'lifecycleRules': [], 'lifecycleJson': '{}', 'policyJson': '{}',
        'corsJson': '[]', 'encryptionJson': '{}', 'apiCalls': [], 'sections': sections}


def _details(params, client):
    bucket, key = _required(params, client.e, 'bucketName', 'key')
    item = client.json('GET', client.path(bucket, key),
        {'generation': str(params['versionId'])} if params.get('versionId') is not None else None)
    headers = {name: str(item[field]) for name, field in
        (('Content-Length', 'size'), ('Content-Type', 'contentType'), ('ETag', 'etag'),
         ('Last-Modified', 'updated'), ('Storage-Class', 'storageClass'), ('Cache-Control', 'cacheControl'),
         ('Content-Disposition', 'contentDisposition'), ('Content-Encoding', 'contentEncoding')) if field in item}
    return {'key': key, 'versionId': str(item['generation']), 'etag': item.get('etag', ''),
        'storageClass': item.get('storageClass', 'STANDARD'), 'metadata': item.get('metadata') or {},
        'headers': headers, 'tags': {}, 'apiCalls': [], 'debugEvents': [], 'debugLogExcerpt': [],
        'rawDiagnostics': {'bucketName': bucket, 'engineState': 'healthy'}}


def _delete(params, client, versions=False):
    e = client.e
    bucket, = _required(params, e, 'bucketName')
    targets = [(str(item.get('key') or ''), str(item.get('versionId') or '')) for item in params.get('versions', [])] if versions else [(str(key), None) for key in params.get('keys', [])]
    if not targets or any(not key or (versions and not generation) for key, generation in targets):
        raise e.SidecarError('invalid_config', 'Object keys and exact generations are required.')
    def delete(target):
        key, generation = target
        try:
            client.request('DELETE', client.path(bucket, key), {'generation': generation} if generation is not None else None)
        except e.SidecarError as error:
            if error.details.get('httpStatus') != 404:
                return {'target': key, **({'versionId': generation} if versions else {}),
                        'code': error.code, 'message': error.message}
        return None
    workers = max(1, min(16, client.profile.max_pool_connections))
    failures = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for future in e._bounded_parallel(pool, delete, targets, workers * 2):
            failure = future.result()
            if failure:
                failures.append(failure)
    return {'successCount': len(targets) - len(failures), 'failureCount': len(failures), 'failures': failures}


def _copy(params, client, move=False):
    e = client.e
    source_bucket, source_key, dest_bucket, dest_key = _required(params, e,
        'sourceBucketName', 'sourceKey', 'destinationBucketName', 'destinationKey')
    if move and (source_bucket, source_key) == (dest_bucket, dest_key):
        raise e.SidecarError('invalid_config', 'Move source and destination must differ.')
    selected = params.get('sourceVersionId', params.get('versionId'))
    source = client.json('GET', client.path(source_bucket, source_key),
        {'generation': str(selected)} if selected is not None else None)
    generation = str(source.get('generation') or '')
    if not generation:
        raise e.SidecarError('object_conflict', 'Source generation is unavailable; copy stopped.')
    path = client.path(source_bucket, source_key) + '/rewriteTo/b/' + quote(dest_bucket, safe='') + '/o/' + quote(dest_key, safe='')
    query = {'sourceGeneration': generation, 'ifSourceGenerationMatch': generation}
    policy = params.get('conflictPolicy') or 'replace'
    if policy not in {'replace', 'overwrite', 'skip', 'fail'}:
        raise e.SidecarError('invalid_config', 'Copy conflict policy must be replace, skip, or fail.')
    if policy in {'skip', 'fail'}:
        try:
            client.json('GET', client.path(dest_bucket, dest_key))
        except e.SidecarError as error:
            if error.details.get('httpStatus') != 404:
                raise
        else:
            if policy == 'fail':
                raise e.SidecarError('conflict', 'Destination object already exists.')
            return {'copied': False, 'skipped': True, 'sourceKey': source_key, 'destinationKey': dest_key}
        # The check above gives a clear answer; this makes it atomic, so a
        # destination created in between is never overwritten.
        query['ifGenerationMatch'] = '0'
    token, seen = None, set()
    while True:
        if token:
            query['rewriteToken'] = token
        result = client.json('POST', path, query, {})
        if result.get('done') is True:
            break
        token = result.get('rewriteToken')
        if not token or token in seen:
            raise e.SidecarError('invalid_response', 'Cloud Storage rewrite did not advance.')
        seen.add(token)
    if move:
        try:
            # Without an explicitly selected historical generation, condition
            # the live object itself. Selecting the old generation here would
            # make the precondition succeed even if a replacement became live.
            delete_query = {'ifGenerationMatch': generation}
            if selected is not None:
                delete_query['generation'] = generation
            client.request('DELETE', client.path(source_bucket, source_key),
                delete_query)
        except e.SidecarError as error:
            if error.code == 'object_conflict':
                raise e.SidecarError('object_conflict', 'Source changed after copy; source retained.',
                    {**error.details, 'sourceRetained': True, 'copied': True}) from None
            raise
    return {'copied': True, 'sourceKey': source_key, 'destinationKey': dest_key}


def _signed(params, client):
    bucket, key = _required(params, client.e, 'bucketName', 'key')
    expires = min(604800, max(1, int(params.get('expirationSeconds') or 3600)))
    now = datetime.now(timezone.utc)
    date, stamp = now.strftime('%Y%m%d'), now.strftime('%Y%m%dT%H%M%SZ')
    scope = date + '/auto/storage/goog4_request'
    parsed = urlparse(client.base)
    path = parsed.path.rstrip('/') + '/' + quote(bucket, safe='') + '/' + quote(key, safe='/')
    query = {'X-Goog-Algorithm': 'GOOG4-RSA-SHA256', 'X-Goog-Credential': client.email + '/' + scope,
        'X-Goog-Date': stamp, 'X-Goog-Expires': str(expires), 'X-Goog-SignedHeaders': 'host'}
    if params.get('versionId') is not None:
        query['generation'] = str(params['versionId'])
    canonical_query = urlencode(sorted(query.items()), quote_via=quote, safe='~')
    canonical = '\n'.join(['GET', path, canonical_query, 'host:' + parsed.netloc + '\n', 'host', 'UNSIGNED-PAYLOAD'])
    to_sign = '\n'.join(['GOOG4-RSA-SHA256', stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    signature = client.sign(to_sign.encode()).hex()
    # The URL is returned only as the explicit requested result; never logged.
    return {'url': f'{parsed.scheme}://{parsed.netloc}{path}?{canonical_query}&X-Goog-Signature={signature}'}


class DownloadClient:
    """Small facade for the shared validated range/download publication path."""
    def __init__(self, client):
        self.client = client
        self.generations = {}

    def head_object(self, Bucket, Key, VersionId=None):
        item = self.client.json('GET', self.client.path(Bucket, Key),
            {'generation': VersionId} if VersionId is not None else None)
        generation = str(item.get('generation') or '')
        if not generation or 'size' not in item:
            raise self.client.e.SidecarError('invalid_response', 'Cloud Storage metadata omitted size or generation.')
        self.generations[(Bucket, Key, VersionId)] = generation
        return {'ContentLength': int(item['size']), 'ETag': item.get('etag')}

    def get_object(self, Bucket, Key, VersionId=None, Range=None, IfMatch=None):
        response = self.client.open('GET', self.client.path(Bucket, Key),
            {'alt': 'media', 'generation': self.generations[(Bucket, Key, VersionId)]},
            {'Accept-Encoding': 'gzip', **({'Range': Range} if Range is not None else {})})
        if Range is not None and response.status != 206:
            response.close()
            response.release_conn()
            raise self.client.e.SidecarError('object_conflict', 'Cloud Storage ignored the requested download range.')
        return {'Body': _DownloadBody(response), 'ContentRange': response.headers.get('Content-Range', '')}


class _DownloadBody:
    def __init__(self, response):
        self.response = response

    def read(self, size=-1):
        return self.response.read(size)

    def close(self):
        self.response.close()
        self.response.release_conn()


def _offset(headers, size, e):
    value = headers.get('Range')
    if not value:
        return 0
    match = re.fullmatch(r'bytes=0-(\d+)', value)
    if not match or not 0 < int(match[1]) + 1 <= size:
        raise e.SidecarError('invalid_response', 'Cloud Storage reported an invalid upload offset.')
    return int(match[1]) + 1


def _upload(params, client, e):
    profile = client.profile
    bucket, = _required(params, e, 'bucketName')
    paths = [Path(str(path)) for path in params.get('filePaths', []) if str(path)]
    if not paths:
        raise e.SidecarError('invalid_config', 'File paths are required.')
    config = e._parse_client_encryption(params, True, len(paths))
    snapshots = {path: e._source_snapshot(path) for path in paths}
    sizes = {path: e._age_object_size(config, snapshots[path][2]) if config else snapshots[path][2] for path in paths}
    if any(size > 5 * 1024**4 for size in sizes.values()):
        raise e.SidecarError('invalid_config', 'Cloud Storage objects cannot exceed 5 TiB.')
    threshold = e._int_param(params, 'multipartThresholdMiB', 32) * 1024**2
    requested = e._int_param(params, 'multipartChunkMiB', 8) * 1024**2
    chunk = max(_UNIT, ((requested + _UNIT - 1) // _UNIT) * _UNIT)
    total = sum(sizes[path] for path in paths)
    resumable = any(size >= threshold for size in sizes.values())
    parts_total = sum((sizes[path] + chunk - 1) // chunk for path in paths if sizes[path] >= threshold)
    job_id = 'upload-' + uuid.uuid4().hex[:8]
    label = f'Upload {len(paths)} file(s) to {bucket}'
    strategy = e._transfer_strategy_label('upload', resumable)
    lines = [f'Queued {len(paths)} file(s) for upload to {bucket}.']
    control = e._register_transfer(e.TransferControl(job_id=job_id, label=label, direction='upload',
        total_bytes=total, item_count=len(paths), strategy_label=strategy,
        part_size_bytes=chunk if resumable else None, parts_total=parts_total if resumable else None))
    transferred, completed, parts = 0, 0, 0
    def event(status, current):
        e._transfer_checkpoint(control, bytes_transferred=transferred, items_completed=completed,
                               parts_completed=parts, current_item_label=current)
        job = e._build_transfer_job(job_id=job_id, label=label, direction='upload',
            progress=transferred / total if total else int(status == 'completed'), status=status,
            bytes_transferred=transferred, total_bytes=total, output_lines=e._transfer_output_snapshot(lines),
            strategy_label=strategy, current_item_label=current, item_count=len(paths), items_completed=completed,
            part_size_bytes=chunk if resumable else None, parts_completed=parts if resumable else None,
            parts_total=parts_total if resumable else None, can_pause=status != 'completed', can_cancel=status != 'completed')
        e._emit_transfer_event(job)
        return job
    event('queued', paths[0].name)
    mapping = params.get('objectKeyByPath') or {}
    for path in paths:
        e._transfer_gate(control)
        e._verify_source(path, snapshots[path])
        key = str(params.get('prefix') or '') + str(mapping.get(str(path)) or path.name).replace('\\', '/').lstrip('/')
        size, session = sizes[path], None
        upload_path = '/upload/storage/v1/b/' + quote(bucket, safe='') + '/o'
        try:
            with path.open('rb') as handle:
                if size < threshold:
                    client.request('POST', upload_path, {'uploadType': 'media', 'name': key},
                        body=e._upload_body(handle, 0, size, control, config, path, snapshots[path]))
                    transferred += size
                else:
                    _, headers, _ = client.request('POST', upload_path, {'uploadType': 'resumable', 'name': key},
                        headers={'X-Upload-Content-Length': str(size), 'X-Upload-Content-Type': 'application/octet-stream',
                                 'Content-Type': 'application/json'}, body=b'{}')
                    location = headers.get('Location')
                    try:
                        _url(location)
                    except (ValueError, TypeError, AttributeError):
                        raise e.SidecarError('invalid_response', 'Cloud Storage did not return a valid resumable session.') from None
                    session = location
                    client.remember(session)
                    for name, value in parse_qsl(urlparse(session).query):
                        if name.lower() == 'upload_id':
                            client.remember(value)
                    offset, failures = 0, 0
                    while offset < size:
                        e._transfer_gate(control)
                        e._verify_source(path, snapshots[path])
                        end = min(size, ((offset // chunk) + 1) * chunk)
                        recovered = False
                        try:
                            status, response_headers, _ = client.request('PUT', session,
                                headers={'Content-Range': f'bytes {offset}-{end - 1}/{size}'},
                                body=e._upload_body(handle, offset, end - offset, control, config, path, snapshots[path]))
                        except Exception as error:
                            retryable = (isinstance(error, e.SidecarError) and
                                (error.code in {'timeout', 'engine_unavailable', 'throttled'} or error.details.get('httpStatus') in _TRANSIENT)) or e._retryable_body_error(error)
                            if not retryable:
                                raise
                            # Never blindly repeat a failed chunk: query committed
                            # bytes before sending more, within one retry budget.
                            failures += 1
                            if failures >= profile.max_attempts:
                                raise
                            while True:
                                e._transfer_gate(control)
                                try:
                                    status, response_headers, _ = client.request('PUT', session,
                                        headers={'Content-Range': f'bytes */{size}'}, body=b'')
                                    recovered = True
                                    break
                                except e.SidecarError as probe_error:
                                    failures += 1
                                    if failures >= profile.max_attempts or not (probe_error.code in {'timeout', 'engine_unavailable', 'throttled'} or probe_error.details.get('httpStatus') in _TRANSIENT):
                                        raise
                        if status in {200, 201}:
                            if end != size:
                                raise e.SidecarError('invalid_response', 'Cloud Storage finalized before the last upload chunk.')
                            following = size
                        elif status == 308:
                            following = _offset(response_headers, size, e)
                            if following < offset or following > end:
                                raise e.SidecarError('invalid_response', 'Cloud Storage upload offset moved outside the sent range.')
                            if following == offset and not recovered:
                                failures += 1
                                if failures >= profile.max_attempts:
                                    raise e.SidecarError('invalid_response', 'Cloud Storage resumable upload made no progress.')
                        else:
                            raise e.SidecarError('invalid_response', 'Unexpected Cloud Storage upload status.')
                        transferred += following - offset
                        offset = following
                        if offset == end:
                            parts += 1
                        e._verify_source(path, snapshots[path])
                        event('running', path.name)
                    if status == 308:
                        raise e.SidecarError('invalid_response', 'Cloud Storage did not finalize the upload.')
                    session = None
            e._verify_source(path, snapshots[path])
        except BaseException:
            if session:
                try:
                    client.request('DELETE', session)
                except Exception:
                    pass
            raise
        completed += 1
        lines.append(f'Finished uploading {path.name}.')
        event('running', path.name)
    return event('completed', paths[-1].name)


def capabilities(params, e):
    result = e._get_capabilities(params)
    for item in result['items']:
        key = item['key']
        if ((key.startswith('bucket.') and key != 'bucket.versioning') or
                key.startswith('object.encryption.') or key in {'object.resumable', 'tools.bulk-delete', 'benchmark', 'storage.admin'}):
            item.update(state='unsupported', reason='This Cloud Storage JSON API adapter does not implement this operation.')
            item.pop('actions', None)
        if key == 'object.resumable':
            item['reason'] = 'In-request resumable uploads are supported; durable recovery checkpoints are not implemented.'
    return result


def handle(method, params, e):
    # Transfers' control requests remain in the provider-independent dispatcher.
    if method in _CONTROLS:
        return None
    profile = e._parse_profile(params.get('profile') or {})
    for field in ('sourceProfile', 'destinationProfile'):
        if params.get(field) is not None and e._parse_profile(params[field]) != profile:
            raise e.SidecarError('unsupported_feature', 'Cross-profile copies are not implemented by the Cloud Storage adapter.')
    if any(params.get(field) is not None for field in ('encryption', 'sourceEncryption')):
        raise e.SidecarError('invalid_config', 'Object encryption is not supported for Cloud Storage profiles.')
    if method == 'getCapabilities':
        return capabilities(params, e)
    supported = {'testProfile', 'listBuckets', 'createBucket', 'deleteBucket', 'setBucketVersioning',
        'getBucketAdminState', 'listObjects', 'listObjectVersions', 'getObjectDetails', 'startUpload',
        'startDownload', 'deleteObjects', 'deleteObjectVersions', 'copyObject', 'moveObject',
        'createFolder', 'generatePresignedUrl'}
    if method not in supported:
        raise e.SidecarError('unsupported_feature', 'This operation is not supported for Cloud Storage profiles.')
    client = _client(profile, e, str((params.get('profile') or {}).get('id') or ''))
    with _secret_scope(e, client):
        try:
            return e._safe_diagnostics(_dispatch(method, params, client, e))
        except Exception as error:
            raise e._map_exception(error) from None


def _dispatch(method, params, client, e):
    profile = client.profile
    if method in {'testProfile', 'listBuckets'}:
        items = _buckets(client)
        return {'ok': True, 'bucketCount': len(items), 'endpoint': client.netloc} if method == 'testProfile' else {'items': items}
    if method == 'createBucket':
        bucket, = _required(params, e, 'bucketName')
        value = {'name': bucket}
        if profile.region:
            value['location'] = profile.region
        return _bucket(client.json('POST', '/storage/v1/b', {'project': client.project}, value))
    if method == 'deleteBucket':
        bucket, = _required(params, e, 'bucketName')
        client.request('DELETE', client.path(bucket))
        return {'deleted': True, 'bucketName': bucket}
    if method == 'setBucketVersioning':
        bucket, = _required(params, e, 'bucketName')
        client.json('PATCH', client.path(bucket), value={'versioning': {'enabled': bool(params.get('enabled', False))}})
        return _admin(params, client)
    if method == 'getBucketAdminState':
        return _admin(params, client)
    if method in {'listObjects', 'listObjectVersions'}:
        return _objects(params, client, method == 'listObjectVersions')
    if method == 'getObjectDetails':
        return _details(params, client)
    if method == 'createFolder':
        bucket, key = _required(params, e, 'bucketName', 'key')
        key = key if key.endswith('/') else key + '/'
        client.request('POST', '/upload/storage/v1/b/' + quote(bucket, safe='') + '/o',
            {'uploadType': 'media', 'name': key}, body=b'')
        return {'created': True, 'key': key}
    if method in {'deleteObjects', 'deleteObjectVersions'}:
        return _delete(params, client, method == 'deleteObjectVersions')
    if method in {'copyObject', 'moveObject'}:
        return _copy(params, client, method == 'moveObject')
    if method == 'generatePresignedUrl':
        return _signed(params, client)
    if method == 'startUpload':
        return e._run_transfer(lambda value: _upload(value, client, e), params)
    if method == 'startDownload':
        return e._run_transfer(lambda value: e._start_download(value, storage_client=DownloadClient(client)), params)
