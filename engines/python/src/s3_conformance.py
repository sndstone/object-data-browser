"""S3 API conformance primitive for the Python (boto3) engine.

Implements `s3ConformanceOp` from contracts/transport_contract.md ("S3 API
conformance"). The host owns the test catalog; this module performs exactly one
S3 operation through boto3 and reports what the service returned.
"""
from __future__ import annotations

import base64
import dataclasses
import hashlib
import re
import threading
import time
from collections import OrderedDict
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlsplit, parse_qsl

CONFORMANCE_VERSION = 1

OPERATIONS = (
    'CreateBucket', 'HeadBucket', 'DeleteBucket', 'ListBuckets', 'GetBucketLocation',
    'GetBucketVersioning', 'PutBucketVersioning',
    'GetBucketTagging', 'PutBucketTagging', 'DeleteBucketTagging',
    'GetBucketCors', 'PutBucketCors', 'DeleteBucketCors',
    'GetBucketLifecycleConfiguration', 'PutBucketLifecycleConfiguration', 'DeleteBucketLifecycle',
    'GetBucketPolicy', 'PutBucketPolicy', 'DeleteBucketPolicy', 'GetBucketPolicyStatus',
    'GetBucketEncryption', 'PutBucketEncryption', 'DeleteBucketEncryption',
    'GetPublicAccessBlock', 'PutPublicAccessBlock', 'DeletePublicAccessBlock',
    'GetBucketOwnershipControls', 'PutBucketOwnershipControls', 'DeleteBucketOwnershipControls',
    'GetBucketAcl', 'PutBucketAcl',
    'GetBucketAccelerateConfiguration', 'PutBucketAccelerateConfiguration',
    'GetBucketRequestPayment', 'PutBucketRequestPayment',
    'GetBucketLogging',
    'GetBucketWebsite', 'PutBucketWebsite', 'DeleteBucketWebsite',
    'GetBucketNotificationConfiguration', 'PutBucketNotificationConfiguration',
    'GetBucketReplication', 'DeleteBucketReplication',
    'ListBucketAnalyticsConfigurations', 'GetBucketAnalyticsConfiguration',
    'PutBucketAnalyticsConfiguration', 'DeleteBucketAnalyticsConfiguration',
    'ListBucketMetricsConfigurations', 'GetBucketMetricsConfiguration',
    'PutBucketMetricsConfiguration', 'DeleteBucketMetricsConfiguration',
    'ListBucketInventoryConfigurations', 'GetBucketInventoryConfiguration',
    'PutBucketInventoryConfiguration', 'DeleteBucketInventoryConfiguration',
    'ListBucketIntelligentTieringConfigurations', 'GetBucketIntelligentTieringConfiguration',
    'PutBucketIntelligentTieringConfiguration', 'DeleteBucketIntelligentTieringConfiguration',
    'GetObjectLockConfiguration', 'PutObjectLockConfiguration',
    'PutObject', 'GetObject', 'HeadObject', 'DeleteObject', 'DeleteObjects', 'CopyObject',
    'GetObjectAttributes', 'ListObjects', 'ListObjectsV2', 'ListObjectVersions',
    'GetObjectTagging', 'PutObjectTagging', 'DeleteObjectTagging',
    'GetObjectAcl', 'PutObjectAcl',
    'CreateMultipartUpload', 'UploadPart', 'UploadPartCopy', 'ListParts', 'ListMultipartUploads',
    'CompleteMultipartUpload', 'AbortMultipartUpload',
    'GetObjectRetention', 'PutObjectRetention', 'GetObjectLegalHold', 'PutObjectLegalHold',
    'PresignedRequest',
)
_OPERATION_SET = frozenset(OPERATIONS)

# Operations that accept the SSE-C headers of the object they address.
_SSE_C_TARGET = frozenset({'PutObject', 'GetObject', 'HeadObject', 'CopyObject', 'CreateMultipartUpload',
                           'UploadPart', 'UploadPartCopy', 'CompleteMultipartUpload', 'GetObjectAttributes'})
# Operations whose copy source may need SSE-C headers.
_SSE_C_SOURCE = frozenset({'CopyObject', 'UploadPartCopy'})
_BODY_OPERATIONS = frozenset({'PutObject', 'UploadPart'})

HEADER_ALLOWLIST = frozenset({
    'etag', 'content-type', 'content-length', 'content-range', 'content-encoding', 'content-disposition',
    'content-language', 'cache-control', 'expires', 'last-modified', 'date', 'accept-ranges', 'location',
    'x-amz-request-id', 'x-amz-version-id', 'x-amz-delete-marker', 'x-amz-tagging-count',
    'x-amz-mp-parts-count', 'x-amz-storage-class', 'x-amz-expiration', 'x-amz-replication-status',
    'x-amz-copy-source-version-id', 'x-amz-bucket-region', 'x-amz-website-redirect-location',
    'x-amz-missing-meta', 'x-amz-restore', 'x-amz-abort-date', 'x-amz-abort-rule-id',
    'x-amz-server-side-encryption', 'x-amz-server-side-encryption-aws-kms-key-id',
    'x-amz-server-side-encryption-bucket-key-enabled', 'x-amz-server-side-encryption-customer-algorithm',
    'x-amz-object-lock-mode', 'x-amz-object-lock-retain-until-date', 'x-amz-object-lock-legal-hold',
    'access-control-allow-origin', 'access-control-allow-methods', 'access-control-expose-headers',
})
_MAX_HEADERS = 48
_MAX_META_HEADERS = 16
_MAX_HEADER_VALUE = 512
_MAX_ERROR_MESSAGE = 256
_MAX_GENERATED = 16 * 1024 * 1024
_MAX_BASE64 = 1024 * 1024
_MAX_TEXT = 64 * 1024
_MAX_BODY_READ = 32 * 1024 * 1024

_CLIENTS: OrderedDict = OrderedDict()
_CLIENTS_LOCK = threading.Lock()
# Per-call wire facts, recorded by client event handlers on the calling thread.
_WIRE = threading.local()
_URL_HEADERS = frozenset({'location', 'x-amz-website-redirect-location'})


_BLOCK = bytes((j * 7) & 0xFF for j in range(1024))
_ROTATIONS = [bytes((value + shift) & 0xFF for value in range(256)) for shift in range(256)]


def generate_body(size: int, seed: int) -> bytes:
    """byte i = (seed * 131 + i * 7 + (i >> 10)) & 0xFF, see contracts/vectors/s3-conformance-body.json.

    Within block k = i >> 10 the byte is (seed * 131 + k + 7 * j) & 0xFF because
    7 * 1024 is a multiple of 256, so each 1 KiB block is a rotation of one row.
    """
    base = seed * 131
    blocks = []
    for k in range((size + 1023) // 1024):
        blocks.append(_BLOCK.translate(_ROTATIONS[(base + k) & 0xFF]))
    return b''.join(blocks)[:size]


def filter_headers(headers: Any) -> dict[str, str]:
    """Lower-cased allowlisted response headers, repeated values joined, with caps."""
    result: dict[str, str] = {}
    meta = 0
    items = headers.items() if hasattr(headers, 'items') else headers
    for name, value in items or ():
        lower = str(name).lower()
        is_meta = lower.startswith('x-amz-meta-')
        if not (lower in HEADER_ALLOWLIST or is_meta or lower.startswith('x-amz-checksum-')):
            continue
        text = str(value)[:_MAX_HEADER_VALUE]
        if lower in result:
            result[lower] = (result[lower] + ', ' + text)[:_MAX_HEADER_VALUE]
            continue
        if len(result) >= _MAX_HEADERS:
            continue
        if is_meta:
            if meta >= _MAX_META_HEADERS:
                continue
            meta += 1
        result[lower] = text
    return result


def _iso(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    value = value.astimezone(timezone.utc)
    text = value.strftime('%Y-%m-%dT%H:%M:%S')
    if value.microsecond:
        text += '.%03d' % (value.microsecond // 1000)
    return text + 'Z'


def _digest_stream(stream) -> dict[str, Any]:
    digest = hashlib.sha256()
    length = 0
    truncated = False
    try:
        while True:
            chunk = stream.read(256 * 1024)
            if not chunk:
                break
            remaining = _MAX_BODY_READ - length
            if len(chunk) > remaining:
                digest.update(chunk[:remaining])
                length += remaining
                truncated = True
                break
            digest.update(chunk)
            length += len(chunk)
    finally:
        try:
            stream.close()
        except Exception:  # noqa: BLE001
            pass
    result: dict[str, Any] = {'length': length, 'sha256': digest.hexdigest()}
    if truncated:
        result['truncated'] = True
    return result


def normalize_output(value: Any) -> Any:
    """AWS member names kept; None dropped; datetimes ISO-8601 UTC; bytes base64."""
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == 'ResponseMetadata' or item is None:
                continue
            result[key] = normalize_output(item)
        return result
    if isinstance(value, (list, tuple)):
        return [normalize_output(item) for item in value if item is not None]
    if isinstance(value, datetime):
        return _iso(value)
    if isinstance(value, (bytes, bytearray)):
        return base64.b64encode(bytes(value)).decode('ascii')
    return value


def _body_bytes(body: Any, g) -> bytes:
    if body is None:
        return b''
    if not isinstance(body, dict) or len(body) != 1:
        raise g.SidecarError('invalid_request', 'body must contain exactly one of generate, base64 or text.')
    if 'generate' in body:
        spec = body['generate']
        if not isinstance(spec, dict):
            raise g.SidecarError('invalid_request', 'body.generate must be an object.')
        size, seed = spec.get('size'), spec.get('seed')
        if not isinstance(size, int) or isinstance(size, bool) or not 0 <= size <= _MAX_GENERATED:
            raise g.SidecarError('invalid_request', 'body.generate.size must be 0..16 MiB.')
        if not isinstance(seed, int) or isinstance(seed, bool) or not 0 <= seed <= 65535:
            raise g.SidecarError('invalid_request', 'body.generate.seed must be 0..65535.')
        return generate_body(size, seed)
    if 'base64' in body:
        try:
            data = base64.b64decode(str(body['base64']), validate=True)
        except (ValueError, TypeError):
            raise g.SidecarError('invalid_request', 'body.base64 is not valid base64.') from None
        if len(data) > _MAX_BASE64:
            raise g.SidecarError('invalid_request', 'body.base64 exceeds 1 MiB.')
        return data
    if 'text' in body:
        data = str(body['text']).encode('utf-8')
        if len(data) > _MAX_TEXT:
            raise g.SidecarError('invalid_request', 'body.text exceeds 64 KiB.')
        return data
    raise g.SidecarError('invalid_request', 'body must contain exactly one of generate, base64 or text.')


def _client(profile, g):
    with _CLIENTS_LOCK:
        cached = _CLIENTS.get(profile)
        if cached is not None:
            _CLIENTS.move_to_end(profile)
            return cached
    client = _prepare_client(g._new_client(profile, conformance=True))
    with _CLIENTS_LOCK:
        _CLIENTS[profile] = client
        while len(_CLIENTS) > 8:
            _CLIENTS.popitem(last=False)
    return client


def _prepare_client(client):
    """One observation must be one S3 request with its wire status.

    botocore's S3 region redirector re-sends a request after a 301/400 and may
    probe HeadBucket; it is removed from this dedicated client. Every send is
    counted, and the raw status is recorded before botocore turns an error
    embedded in a 200 response into a 500.
    """
    from botocore import handlers as bh  # noqa: PLC0415
    from botocore.utils import S3RegionRedirectorv2  # noqa: PLC0415
    events = client.meta.events
    emitter = getattr(events, '_emitter', events)
    for event in ('needs-retry.s3', 'before-parameter-build.s3', 'before-endpoint-resolution.s3'):
        try:
            handlers = list(emitter._handlers.prefix_search(event + '.GetObject'))
        except Exception:  # noqa: BLE001
            handlers = []
        for handler in handlers:
            if isinstance(getattr(handler, '__self__', None), S3RegionRedirectorv2):
                events.unregister(event, handler)

    def count_send(**_):
        _WIRE.sends = getattr(_WIRE, 'sends', 0) + 1

    def record_status(response_dict=None, **_):
        if response_dict is not None and getattr(_WIRE, 'status', None) is None:
            _WIRE.status = response_dict.get('status_code')

    events.register('before-send.s3', count_send)
    handle_200 = getattr(bh, '_handle_200_error', None)
    if handle_200 is not None:
        events.unregister('before-parse.s3.*', handle_200)
    events.register_first('before-parse.s3.*', record_status)
    if handle_200 is not None:
        events.register_first('before-parse.s3.*', handle_200)
    return client


class _Redactor:
    """Removes this profile's credentials and URL query strings from text."""

    def __init__(self, profile, g):
        self._g = g
        # Like the Java engine: short credentials ("test") are ordinary words in
        # S3 data and are not substring-replaced; customer keys always are.
        self._secrets = [value for value in (profile.secret_key, profile.session_token, profile.access_key)
                         if value and len(value) >= 16]

    def text(self, value: Any) -> Any:
        if not isinstance(value, str):
            return value
        value = _strip_urls(self._g._redact_customer_text(value))
        for secret in self._secrets:
            value = value.replace(secret, '[redacted]')
        return value

    def deep(self, value: Any) -> Any:
        if isinstance(value, dict):
            return {key: self.deep(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.deep(item) for item in value]
        return self.text(value)

    def headers(self, headers: dict[str, str]) -> dict[str, str]:
        result = {}
        for name, value in headers.items():
            if name in _URL_HEADERS:
                value = value.split('?', 1)[0] + ('?[query]' if '?' in value else '')
            result[name] = self.text(value)
        return result


def _sdk_name() -> str:
    try:
        import boto3  # noqa: PLC0415
        import botocore  # noqa: PLC0415
        return f'boto3 {boto3.__version__} (botocore {botocore.__version__})'
    except Exception:  # noqa: BLE001
        return 'boto3'


def capability(profile_payload: Any, g) -> dict[str, Any]:
    item = {
        'key': 'conformance.s3', 'label': 'S3 API conformance', 'version': CONFORMANCE_VERSION,
        'sdk': _sdk_name(),
        'client': {'maxAttempts': 1, 'requestChecksumCalculation': 'when_required',
                   'responseChecksumValidation': 'when_required', 'followRedirects': False},
        'ops': list(OPERATIONS),
    }
    endpoint_type = str((profile_payload or {}).get('endpointType') or 's3Compatible') if isinstance(profile_payload, dict) else 's3Compatible'
    if endpoint_type in {'s3Compatible', 'awsS3'}:
        item['state'] = 'supported'
    else:
        item['state'] = 'unsupported'
        item['reason'] = 'S3 API conformance applies to S3 profiles only.'
        item['ops'] = []
    return item


def _message(g, text: Any) -> str | None:
    if text is None:
        return None
    text = g._redact_customer_text(str(text))
    return text[:_MAX_ERROR_MESSAGE]


def _result(op, outcome, status, *, error_code=None, error_message=None, headers=None, output=None,
            latency_ms=0.0, attempts=1, request_id=None) -> dict[str, Any]:
    result: dict[str, Any] = {
        'op': op, 'outcome': outcome, 'httpStatus': int(status or 0),
        'headers': headers or {}, 'output': output or {},
        'latencyMs': round(latency_ms, 3), 'attempts': attempts,
    }
    if error_code is not None:
        result['errorCode'] = str(error_code)
    if error_message is not None:
        result['errorMessage'] = error_message
    if request_id:
        result['requestId'] = str(request_id)
    return result


_MAX_OUTPUT_JSON = 4 * 1024 * 1024


def _redact_result(result: dict[str, Any], redactor: _Redactor) -> dict[str, Any]:
    import json  # noqa: PLC0415
    if len(json.dumps(result.get('output') or {}, default=str)) > _MAX_OUTPUT_JSON:
        # S3 pages hold at most 1000 entries; anything larger is not projected.
        result['output'] = {'truncated': True}
    result['headers'] = redactor.headers(result.get('headers') or {})
    if result.get('errorMessage') is not None:
        result['errorMessage'] = redactor.text(result['errorMessage'])[:_MAX_ERROR_MESSAGE]
    result['output'] = redactor.deep(result.get('output') or {})
    return result


def _apply_encryption(op: str, params: dict[str, Any], profile, kwargs: dict[str, Any], g) -> None:
    encryption = g._parse_object_encryption(params.get('encryption'), profile)
    source = g._parse_object_encryption(params.get('sourceEncryption'), profile, source=True)
    for value, allowed, is_source in ((encryption, _SSE_C_TARGET, False), (source, _SSE_C_SOURCE, True)):
        if not value:
            continue
        if value.get('mode') != 'sse-c':
            raise g.SidecarError('invalid_request', 'Only sse-c is accepted as conformance encryption; '
                                 'other modes are ordinary input members.')
        if op not in allowed:
            raise g.SidecarError('invalid_request', f'{op} does not take customer-key encryption.')
        kwargs.update(g._s3_encryption_options(value, customer_only=True, source=is_source))


def _validate_input(raw: Any, g) -> dict[str, Any]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise g.SidecarError('invalid_request', 'input must be an object.')
    for name in raw:
        lower = str(name).lower()
        if lower.startswith('ssecustomer') or lower.startswith('copysourcessecustomer'):
            raise g.SidecarError('invalid_request', 'Customer keys travel only in encryption/sourceEncryption.')
    return dict(raw)


def handle(params: dict[str, Any], g) -> dict[str, Any]:
    profile_payload = params.get('profile') or {}
    endpoint_type = str(profile_payload.get('endpointType') or '').strip() or 's3Compatible'
    if endpoint_type not in {'s3Compatible', 'awsS3'}:
        raise g.SidecarError('unsupported_feature', 'S3 API conformance applies to S3 profiles only.')
    op = params.get('op')
    if not isinstance(op, str) or op not in _OPERATION_SET:
        raise g.SidecarError('unsupported_feature', 'This operation is not part of the conformance allowlist.')
    profile = dataclasses.replace(g._parse_profile(profile_payload), max_attempts=1)
    kwargs = _validate_input(params.get('input'), g)
    if op == 'PresignedRequest':
        if params.get('encryption') or params.get('sourceEncryption'):
            raise g.SidecarError('unsupported_feature', 'Customer-key encrypted objects cannot use presigned URLs.')
        return _redact_result(_presigned_request(profile, kwargs, params.get('body'), g), _Redactor(profile, g))
    if op in _BODY_OPERATIONS:
        kwargs['Body'] = _body_bytes(params.get('body'), g)
    elif params.get('body') is not None:
        raise g.SidecarError('invalid_request', f'{op} does not take a body.')
    _apply_encryption(op, params, profile, kwargs, g)
    client = _client(profile, g)
    return _redact_result(_invoke(client, op, kwargs, g), _Redactor(profile, g))


def _invoke(client, op: str, kwargs: dict[str, Any], g) -> dict[str, Any]:
    from botocore import exceptions as bce  # noqa: PLC0415
    from botocore import xform_name  # noqa: PLC0415

    method = getattr(client, xform_name(op))
    _WIRE.sends = 0
    _WIRE.status = None
    started = time.perf_counter()
    try:
        response = method(**kwargs)
        output = dict(response)
        if op == 'GetObject' and 'Body' in output:
            output['Body'] = _digest_stream(output['Body'])
        latency = (time.perf_counter() - started) * 1000
        meta = response.get('ResponseMetadata') or {}
        return _result(op, 'service', _WIRE.status or meta.get('HTTPStatusCode'),
                       headers=filter_headers(meta.get('HTTPHeaders') or {}),
                       output=normalize_output(output), latency_ms=latency,
                       attempts=_WIRE.sends or 1, request_id=meta.get('RequestId'))
    except bce.ClientError as error:
        latency = (time.perf_counter() - started) * 1000
        response = error.response or {}
        meta = response.get('ResponseMetadata') or {}
        err = response.get('Error') or {}
        # The wire status: an error embedded in a 200 response stays a 200.
        status = _WIRE.status or meta.get('HTTPStatusCode') or 0
        return _result(op, 'service' if status else 'sdk_decode', status,
                       error_code=err.get('Code'), error_message=_message(g, err.get('Message')),
                       headers=filter_headers(meta.get('HTTPHeaders') or {}), latency_ms=latency,
                       attempts=_WIRE.sends or 1, request_id=meta.get('RequestId'))
    except (bce.ParamValidationError, bce.NoCredentialsError, bce.PartialCredentialsError) as error:
        latency = (time.perf_counter() - started) * 1000
        return _result(op, 'sdk_validation', 0, error_code=type(error).__name__,
                       error_message=_message(g, error), latency_ms=latency, attempts=0)
    except (bce.ConnectionError, bce.HTTPClientError, bce.ConnectTimeoutError, bce.ReadTimeoutError) as error:
        latency = (time.perf_counter() - started) * 1000
        return _result(op, 'transport', 0, error_code=type(error).__name__,
                       error_message=_message(g, _strip_urls(str(error))), latency_ms=latency)
    except _decode_errors(bce) as error:
        latency = (time.perf_counter() - started) * 1000
        return _result(op, 'sdk_decode', 0, error_code=type(error).__name__,
                       error_message=_message(g, _strip_urls(str(error))), latency_ms=latency)
    except bce.BotoCoreError as error:
        if type(error).__name__ == 'MissingDependencyException':
            # e.g. CRC32C needs awscrt, which the bundled engine does not ship.
            raise g.SidecarError('unsupported_feature',
                                 f'boto3 needs an optional dependency for this request: {_strip_urls(str(error))[:160]}') from None
        latency = (time.perf_counter() - started) * 1000
        return _result(op, 'sdk_validation', 0, error_code=type(error).__name__,
                       error_message=_message(g, _strip_urls(str(error))), latency_ms=latency, attempts=0)


def _decode_errors(bce) -> tuple:
    """Response-parsing and checksum-validation failures, across botocore versions."""
    from botocore import parsers  # noqa: PLC0415
    names = ('FlexibleChecksumError', 'ChecksumError', 'ResponseStreamingError', 'IncompleteReadError')
    found = [getattr(bce, name) for name in names if isinstance(getattr(bce, name, None), type)]
    parser_error = getattr(parsers, 'ResponseParserError', None)
    if isinstance(parser_error, type):
        found.append(parser_error)
    return tuple(found)


def _strip_urls(text: str) -> str:
    """Drop query strings from any URL embedded in transport error text."""
    return re.sub(r'(https?://[^\s?\'"]*)\?[^\s\'"]*', r'\1?[query]', text)


def _presigned_request(profile, kwargs: dict[str, Any], body: Any, g) -> dict[str, Any]:
    import urllib3  # noqa: PLC0415

    method = str(kwargs.get('Method') or 'GET').upper()
    if method not in {'GET', 'PUT'}:
        raise g.SidecarError('invalid_request', 'PresignedRequest Method must be GET or PUT.')
    expires = kwargs.get('ExpiresIn', 300)
    delay = kwargs.get('DelayMs', 0)
    if not isinstance(expires, int) or isinstance(expires, bool) or not 1 <= expires <= 3600:
        raise g.SidecarError('invalid_request', 'ExpiresIn must be 1..3600 seconds.')
    if not isinstance(delay, int) or isinstance(delay, bool) or not 0 <= delay <= 5000:
        raise g.SidecarError('invalid_request', 'DelayMs must be 0..5000.')
    sdk_params: dict[str, Any] = {'Bucket': kwargs.get('Bucket'), 'Key': kwargs.get('Key')}
    headers: dict[str, str] = {}
    data = b''
    if method == 'GET':
        if kwargs.get('VersionId'):
            sdk_params['VersionId'] = kwargs['VersionId']
        if body is not None:
            raise g.SidecarError('invalid_request', 'A presigned GET does not take a body.')
    else:
        if kwargs.get('ContentType'):
            sdk_params['ContentType'] = kwargs['ContentType']
            headers['Content-Type'] = str(kwargs['ContentType'])
        data = _body_bytes(body, g)
    client = _client(profile, g)
    presign_started = time.perf_counter()
    url = client.generate_presigned_url('get_object' if method == 'GET' else 'put_object',
                                        Params=sdk_params, ExpiresIn=expires, HttpMethod=method)
    presign_ms = (time.perf_counter() - presign_started) * 1000
    parts = urlsplit(url)
    shape = {'Method': method, 'Scheme': parts.scheme, 'Host': parts.netloc,
             'QueryKeys': sorted({name for name, _ in parse_qsl(parts.query, keep_blank_values=True)}),
             'PresignMs': round(presign_ms, 3)}
    if delay:
        time.sleep(delay / 1000)
    if profile.ca_bundle_path:
        pool = urllib3.PoolManager(cert_reqs='CERT_REQUIRED', ca_certs=profile.ca_bundle_path)
    elif profile.verify_tls:
        try:
            import certifi  # noqa: PLC0415
            pool = urllib3.PoolManager(cert_reqs='CERT_REQUIRED', ca_certs=certifi.where())
        except ImportError:
            pool = urllib3.PoolManager(cert_reqs='CERT_REQUIRED')
    else:
        pool = urllib3.PoolManager(cert_reqs='CERT_NONE')
    timeout = urllib3.Timeout(connect=profile.connect_timeout_seconds, read=profile.read_timeout_seconds)
    started = time.perf_counter()
    try:
        response = pool.request(method, url, body=data if method == 'PUT' else None, headers=headers,
                                redirect=False, retries=False, preload_content=False, decode_content=False,
                                timeout=timeout)
    except Exception as error:  # noqa: BLE001
        latency = (time.perf_counter() - started) * 1000
        return _result('PresignedRequest', 'transport', 0, error_code=type(error).__name__,
                       error_message=_message(g, _strip_urls(str(error)).replace(url, '[presigned-url]')),
                       output={'Presign': shape}, latency_ms=latency)
    status = response.status
    error_code = error_message = None
    if status >= 300:
        # Error documents can echo the canonical request (including a session
        # token); only the Code and Message elements are extracted.
        raw = response.read(64 * 1024, decode_content=False) or b''
        response.release_conn()
        digest = {'length': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
        text = raw.decode('utf-8', 'replace')
        code = re.search(r'<Code>([^<]{1,128})</Code>', text)
        message = re.search(r'<Message>([^<]{0,512})</Message>', text)
        error_code = code.group(1) if code else None
        error_message = _message(g, message.group(1)) if message else None
    else:
        digest = _digest_stream(response)
        response.release_conn()
    latency = (time.perf_counter() - started) * 1000
    output = {'Presign': shape, 'Body': digest}
    return _result('PresignedRequest', 'service', status, error_code=error_code, error_message=error_message,
                   headers=filter_headers(response.headers), output=output, latency_ms=latency,
                   request_id=response.headers.get('x-amz-request-id'))
