#!/usr/bin/env python3
"""Python desktop sidecar for real S3 profile testing and listing."""

from __future__ import annotations

import json
import socket
import ssl
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


class SidecarError(Exception):
    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


@dataclass(frozen=True)
class Profile:
    endpoint_url: str
    region: str
    access_key: str
    secret_key: str
    session_token: str | None
    path_style: bool
    verify_tls: bool
    connect_timeout_seconds: int
    read_timeout_seconds: int
    max_attempts: int
    max_pool_connections: int
    enable_api_logging: bool
    enable_debug_logging: bool


def _lazy_boto_imports():
    try:
        import boto3
        from botocore.config import Config
        from botocore.exceptions import (
            ClientError,
            ConnectTimeoutError,
            EndpointConnectionError,
            ReadTimeoutError,
            SSLError,
        )
    except ModuleNotFoundError as error:
        raise SidecarError(
            "engine_unavailable",
            "Bundled boto3 dependencies are missing from the Python engine runtime.",
            {"missingModule": str(error)},
        ) from error

    return {
        "boto3": boto3,
        "Config": Config,
        "ClientError": ClientError,
        "ConnectTimeoutError": ConnectTimeoutError,
        "EndpointConnectionError": EndpointConnectionError,
        "ReadTimeoutError": ReadTimeoutError,
        "SSLError": SSLError,
    }


def _parse_profile(payload: dict[str, Any]) -> Profile:
    endpoint_url = str(payload.get("endpointUrl", "")).strip()
    access_key = str(payload.get("accessKey", "")).strip()
    secret_key = str(payload.get("secretKey", "")).strip()
    region = str(payload.get("region", "")).strip() or "us-east-1"

    if not endpoint_url:
        raise SidecarError("invalid_config", "Endpoint URL is required.")
    if not access_key or not secret_key:
        raise SidecarError("invalid_config", "Access key and secret key are required.")

    return Profile(
        endpoint_url=endpoint_url,
        region=region,
        access_key=access_key,
        secret_key=secret_key,
        session_token=str(payload.get("sessionToken", "")).strip() or None,
        path_style=bool(payload.get("pathStyle", False)),
        verify_tls=bool(payload.get("verifyTls", True)),
        connect_timeout_seconds=max(int(payload.get("connectTimeoutSeconds", 5) or 5), 1),
        read_timeout_seconds=max(int(payload.get("readTimeoutSeconds", 60) or 60), 1),
        max_attempts=max(int(payload.get("maxAttempts", 5) or 5), 1),
        max_pool_connections=max(
            int(payload.get("maxConcurrentRequests", 10) or 10),
            1,
        ),
        enable_api_logging=bool(
            (payload.get("diagnostics") or {}).get("enableApiLogging", False),
        ),
        enable_debug_logging=bool(
            (payload.get("diagnostics") or {}).get("enableDebugLogging", False),
        ),
    )


def _build_client(profile: Profile):
    imports = _lazy_boto_imports()
    config = imports["Config"](
        region_name=profile.region,
        connect_timeout=profile.connect_timeout_seconds,
        read_timeout=profile.read_timeout_seconds,
        retries={"max_attempts": profile.max_attempts, "mode": "adaptive"},
        max_pool_connections=profile.max_pool_connections,
        s3={"addressing_style": "path" if profile.path_style else "virtual"},
    )
    session = imports["boto3"].session.Session()

    client = session.client(
        "s3",
        endpoint_url=profile.endpoint_url,
        aws_access_key_id=profile.access_key,
        aws_secret_access_key=profile.secret_key,
        aws_session_token=profile.session_token,
        region_name=profile.region,
        verify=profile.verify_tls,
        config=config,
    )
    if profile.enable_api_logging or profile.enable_debug_logging:
        events = client.meta.events
        events.register(
            "before-send.s3",
            lambda request, **kwargs: _log_http_send(profile, request),
        )
        events.register(
            "after-call.s3",
            lambda http_response, parsed, model, **kwargs: _log_http_receive(
                profile,
                http_response,
                parsed,
                model,
            ),
        )
    return client


def _serialize_dt(value: Any) -> str:
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat()
    return datetime.fromtimestamp(0, tz=timezone.utc).isoformat()


def _json_dumps(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True)


def _emit_structured_log(level: str, category: str, message: str, source: str) -> None:
    payload = json.dumps(
        {
            "level": level,
            "category": category,
            "message": message,
            "source": source,
        },
        sort_keys=True,
    )
    print(f"S3_BROWSER_LOG {payload}", file=sys.stderr, flush=True)


def _sanitize_headers(headers: Any) -> dict[str, str]:
    sanitized: dict[str, str] = {}
    for key, value in dict(headers or {}).items():
        lower = str(key).lower()
        if any(token in lower for token in ("authorization", "security-token", "access-key", "secret", "token")):
            sanitized[str(key)] = "[redacted]"
            continue
        sanitized[str(key)] = str(value)
    return sanitized


def _summarize_http_body(content_type: str, body: Any) -> str:
    if body is None:
        return "null"
    if isinstance(body, (bytes, bytearray)):
        raw = bytes(body)
        if len(raw) > 1024 * 256:
            return "[omitted large body]"
        lower_type = content_type.lower()
        if "octet-stream" in lower_type or "application/x-www-form-urlencoded" in lower_type:
            return "[omitted binary body]"
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return "[omitted binary body]"
    else:
        text = str(body)
    text = text.strip()
    if not text:
        return "null"
    if len(text) > 16000:
        text = f"{text[:16000]}...(truncated)"
    return text


def _log_http_send(profile: Profile, request: Any) -> None:
    if not profile.enable_api_logging:
        return
    headers = _sanitize_headers(getattr(request, "headers", {}))
    body = _summarize_http_body(headers.get("Content-Type", ""), getattr(request, "body", None))
    _emit_structured_log(
        "API",
        "HttpSend",
        f"SEND {getattr(request, 'method', 'UNKNOWN')} {getattr(request, 'url', '')} HEADERS={json.dumps(headers, sort_keys=True)} BODY={body}",
        "api",
    )


def _log_http_receive(profile: Profile, http_response: Any, parsed: Any, model: Any) -> None:
    if not profile.enable_api_logging:
        return
    headers = _sanitize_headers(getattr(http_response, "headers", {}))
    body = _summarize_http_body(
        headers.get("Content-Type", ""),
        getattr(http_response, "content", None) or parsed,
    )
    operation = getattr(model, "name", "S3")
    _emit_structured_log(
        "API",
        "HttpReceive",
        f"RECV {operation} STATUS={getattr(http_response, 'status_code', 0)} HEADERS={json.dumps(headers, sort_keys=True)} BODY={body}",
        "api",
    )


def _record_api_call(
    api_calls: list[dict[str, Any]],
    operation: str,
    started_at: float,
    status: str,
) -> None:
    api_calls.append(
        {
            "timestamp": _serialize_dt(datetime.now(tz=timezone.utc)),
            "operation": operation,
            "status": status,
            "latencyMs": int((time.perf_counter() - started_at) * 1000),
        }
    )


def _call_api(
    api_calls: list[dict[str, Any]],
    operation: str,
    fn,
):
    started_at = time.perf_counter()
    try:
        result = fn()
    except Exception:
        _record_api_call(api_calls, operation, started_at, "ERROR")
        raise

    status = "200"
    metadata = result.get("ResponseMetadata") if isinstance(result, dict) else None
    if isinstance(metadata, dict) and metadata.get("HTTPStatusCode") is not None:
        status = str(metadata.get("HTTPStatusCode"))
    _record_api_call(api_calls, operation, started_at, status)
    return result


def _client_error_code(error: Exception) -> str:
    response = getattr(error, "response", {})
    return str(response.get("Error", {}).get("Code", "Unknown"))


def _maybe_call(api_calls: list[dict[str, Any]], operation: str, fn, default: Any):
    try:
        return _call_api(api_calls, operation, fn)
    except Exception as error:  # noqa: BLE001
        code = _client_error_code(error)
        if code in {
            "NoSuchLifecycleConfiguration",
            "NoSuchBucketPolicy",
            "NoSuchCORSConfiguration",
            "NoSuchBucket",
            "NoSuchTagSet",
            "ObjectLockConfigurationNotFoundError",
            "NoSuchObjectLockConfiguration",
            "ServerSideEncryptionConfigurationNotFoundError",
            "MethodNotAllowed",
            "NotImplemented",
            "XNotImplemented",
        }:
            return default
        raise


def _map_exception(error: Exception) -> SidecarError:
    if isinstance(error, SidecarError):
        return error

    imports = _lazy_boto_imports()
    client_error = imports["ClientError"]
    connect_timeout_error = imports["ConnectTimeoutError"]
    read_timeout_error = imports["ReadTimeoutError"]
    endpoint_connection_error = imports["EndpointConnectionError"]
    ssl_error = imports["SSLError"]

    if isinstance(error, client_error):
        code = str(error.response.get("Error", {}).get("Code", "Unknown"))
        status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        message = str(error.response.get("Error", {}).get("Message", str(error)))
        if code in {"AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch"}:
            return SidecarError("auth_failed", message, {"awsCode": code, "httpStatus": status})
        if code in {"RequestTimeout", "SlowDown"}:
            mapped = "throttled" if code == "SlowDown" else "timeout"
            return SidecarError(mapped, message, {"awsCode": code, "httpStatus": status})
        return SidecarError("unknown", message, {"awsCode": code, "httpStatus": status})

    if isinstance(error, (connect_timeout_error, read_timeout_error, socket.timeout, TimeoutError)):
        return SidecarError("timeout", str(error))

    if isinstance(error, ssl_error) or isinstance(error, ssl.SSLError):
        return SidecarError("tls_error", str(error))

    if isinstance(error, endpoint_connection_error):
        return SidecarError("engine_unavailable", str(error))

    return SidecarError("unknown", str(error))


def _health() -> dict[str, Any]:
    try:
        _lazy_boto_imports()
        available = True
        dependency_state = "bundled"
    except SidecarError as error:
        available = False
        dependency_state = error.message

    return {
        "engine": "python",
        "version": "2.0.17",
        "available": available,
        "dependencyState": dependency_state,
        "methods": [
            "health",
            "getCapabilities",
            "testProfile",
            "listBuckets",
            "createBucket",
            "deleteBucket",
            "setBucketVersioning",
            "putBucketLifecycle",
            "deleteBucketLifecycle",
            "putBucketPolicy",
            "deleteBucketPolicy",
            "putBucketCors",
            "deleteBucketCors",
            "putBucketEncryption",
            "deleteBucketEncryption",
            "putBucketTagging",
            "deleteBucketTagging",
            "listObjects",
            "getBucketAdminState",
            "listObjectVersions",
            "getObjectDetails",
            "createFolder",
            "copyObject",
            "moveObject",
            "deleteObjects",
            "deleteObjectVersions",
            "startUpload",
            "startDownload",
            "pauseTransfer",
            "resumeTransfer",
            "cancelTransfer",
            "generatePresignedUrl",
            "runPutTestData",
            "runDeleteAll",
            "cancelToolExecution",
            "startBenchmark",
            "getBenchmarkStatus",
            "pauseBenchmark",
            "resumeBenchmark",
            "stopBenchmark",
            "exportBenchmarkResults",
        ],
    }


def _get_capabilities(_: dict[str, Any]) -> dict[str, Any]:
    return {
        "items": [
            {"key": "bucket.lifecycle", "label": "Lifecycle policy CRUD", "state": "supported"},
            {"key": "bucket.policy", "label": "Bucket policy CRUD", "state": "supported"},
            {"key": "bucket.cors", "label": "Bucket CORS CRUD", "state": "supported"},
            {"key": "bucket.encryption", "label": "Bucket encryption", "state": "supported"},
            {"key": "bucket.tagging", "label": "Bucket tagging", "state": "supported"},
            {"key": "bucket.versioning", "label": "Bucket versioning", "state": "supported"},
            {"key": "object.copy_move", "label": "Copy, move, rename", "state": "supported"},
            {"key": "object.resumable", "label": "Resumable transfer jobs", "state": "unknown", "reason": "Desktop host currently uses one request per sidecar process."},
            {"key": "tools.bulk-delete", "label": "Delete-all maintenance tool", "state": "supported"},
            {"key": "benchmark", "label": "Integrated benchmark mode", "state": "supported"},
        ]
    }


def _test_profile(profile_payload: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(profile_payload)
    client = _build_client(profile)
    response = client.list_buckets()
    buckets = response.get("Buckets", [])
    endpoint_host = urlparse(profile.endpoint_url).netloc or profile.endpoint_url
    return {
        "ok": True,
        "bucketCount": len(buckets),
        "endpoint": endpoint_host,
    }


def _list_buckets(profile_payload: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(profile_payload)
    client = _build_client(profile)
    response = client.list_buckets()
    buckets = []
    for bucket in response.get("Buckets", []):
        buckets.append(
            {
                "name": bucket.get("Name", ""),
                "region": profile.region,
                "objectCountHint": 0,
                "versioningEnabled": False,
                "createdAt": _serialize_dt(bucket.get("CreationDate")),
            }
        )
    return {"items": buckets}


def _create_bucket(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    enable_versioning = bool(params.get("enableVersioning", False))
    enable_object_lock = bool(params.get("enableObjectLock", False))
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")

    client = _build_client(profile)
    request: dict[str, Any] = {
        "Bucket": bucket_name,
    }
    if profile.region != "us-east-1":
        request["CreateBucketConfiguration"] = {
            "LocationConstraint": profile.region,
        }
    if enable_object_lock:
        request["ObjectLockEnabledForBucket"] = True

    client.create_bucket(**request)

    if enable_versioning:
        client.put_bucket_versioning(
            Bucket=bucket_name,
            VersioningConfiguration={"Status": "Enabled"},
        )

    created_at = datetime.now(tz=timezone.utc)
    return {
        "name": bucket_name,
        "region": profile.region,
        "objectCountHint": 0,
        "versioningEnabled": enable_versioning,
        "createdAt": _serialize_dt(created_at),
    }


def _delete_bucket(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    client.delete_bucket(Bucket=bucket_name)
    return {"deleted": True, "bucketName": bucket_name}


def _set_bucket_versioning(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    enabled = bool(params.get("enabled", False))
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    client.put_bucket_versioning(
        Bucket=bucket_name,
        VersioningConfiguration={"Status": "Enabled" if enabled else "Suspended"},
    )
    return _get_bucket_admin_state(params)


def _list_objects(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required for object listing.")

    prefix = str(params.get("prefix", "") or "")
    flat = bool(params.get("flat", False))
    cursor = params.get("cursor") or {}
    continuation_token = cursor.get("value") if isinstance(cursor, dict) else None

    client = _build_client(profile)
    request = {
        "Bucket": bucket_name,
        "Prefix": prefix,
        "MaxKeys": 1000,
    }
    if not flat:
        request["Delimiter"] = "/"
    if continuation_token:
        request["ContinuationToken"] = continuation_token

    response = client.list_objects_v2(**request)
    items: list[dict[str, Any]] = []

    for common_prefix in response.get("CommonPrefixes", []):
        folder_prefix = str(common_prefix.get("Prefix", ""))
        folder_name = folder_prefix[len(prefix) :] if folder_prefix.startswith(prefix) else folder_prefix
        items.append(
            {
                "key": folder_prefix,
                "name": folder_name or folder_prefix,
                "size": 0,
                "storageClass": "FOLDER",
                "modifiedAt": _serialize_dt(datetime.now(tz=timezone.utc)),
                "isFolder": True,
                "etag": None,
                "metadataCount": 0,
            }
        )

    for obj in response.get("Contents", []):
        key = str(obj.get("Key", ""))
        if not flat and key == prefix:
            continue
        name = key[len(prefix) :] if prefix and key.startswith(prefix) else key
        if not name:
            name = key
        items.append(
            {
                "key": key,
                "name": name,
                "size": int(obj.get("Size", 0) or 0),
                "storageClass": str(obj.get("StorageClass", "STANDARD")),
                "modifiedAt": _serialize_dt(obj.get("LastModified")),
                "isFolder": False,
                "etag": str(obj.get("ETag", "")).strip('"') or None,
                "metadataCount": 0,
            }
        )

    items.sort(key=lambda item: (not bool(item["isFolder"]), str(item["key"]).lower()))
    return {
        "items": items,
        "nextCursor": {
            "value": response.get("NextContinuationToken"),
            "hasMore": bool(response.get("IsTruncated", False)),
        },
    }


def _get_bucket_admin_state(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required for bucket admin inspection.")

    client = _build_client(profile)
    api_calls: list[dict[str, Any]] = []

    versioning = _maybe_call(
        api_calls,
        "GetBucketVersioning",
        lambda: client.get_bucket_versioning(Bucket=bucket_name),
        {},
    )
    encryption = _maybe_call(
        api_calls,
        "GetBucketEncryption",
        lambda: client.get_bucket_encryption(Bucket=bucket_name),
        {},
    )
    lifecycle = _maybe_call(
        api_calls,
        "GetBucketLifecycleConfiguration",
        lambda: client.get_bucket_lifecycle_configuration(Bucket=bucket_name),
        {},
    )
    policy = _maybe_call(
        api_calls,
        "GetBucketPolicy",
        lambda: client.get_bucket_policy(Bucket=bucket_name),
        {},
    )
    cors = _maybe_call(
        api_calls,
        "GetBucketCors",
        lambda: client.get_bucket_cors(Bucket=bucket_name),
        {},
    )
    tagging = _maybe_call(
        api_calls,
        "GetBucketTagging",
        lambda: client.get_bucket_tagging(Bucket=bucket_name),
        {},
    )
    object_lock = _maybe_call(
        api_calls,
        "GetObjectLockConfiguration",
        lambda: client.get_object_lock_configuration(Bucket=bucket_name),
        {},
    )

    rules = []
    for rule in lifecycle.get("Rules", []):
        transition = (rule.get("Transitions") or [{}])[0]
        noncurrent = (rule.get("NoncurrentVersionTransitions") or [{}])[0]
        rules.append(
            {
                "id": rule.get("ID", rule.get("Prefix", "rule")),
                "enabled": rule.get("Status") == "Enabled",
                "prefix": rule.get("Filter", {}).get("Prefix", rule.get("Prefix", "")),
                "expirationDays": rule.get("Expiration", {}).get("Days"),
                "deleteExpiredObjectDeleteMarkers": bool(
                    rule.get("Expiration", {}).get("ExpiredObjectDeleteMarker", False)
                ),
                "transitionStorageClass": transition.get("StorageClass"),
                "transitionDays": transition.get("Days"),
                "nonCurrentExpirationDays": rule.get("NoncurrentVersionExpiration", {}).get(
                    "NoncurrentDays"
                ),
                "nonCurrentTransitionStorageClass": noncurrent.get("StorageClass"),
                "nonCurrentTransitionDays": noncurrent.get("NoncurrentDays"),
                "abortIncompleteMultipartUploadDays": rule.get(
                    "AbortIncompleteMultipartUpload", {}
                ).get("DaysAfterInitiation"),
            }
        )

    encryption_rules = encryption.get("ServerSideEncryptionConfiguration", {}).get("Rules", [])
    encryption_summary = "Not configured"
    if encryption_rules:
        apply_default = encryption_rules[0].get("ApplyServerSideEncryptionByDefault", {})
        algo = apply_default.get("SSEAlgorithm", "Unknown")
        kms = apply_default.get("KMSMasterKeyID")
        encryption_summary = algo if not kms else f"{algo} ({kms})"

    tags = {item.get("Key", ""): item.get("Value", "") for item in tagging.get("TagSet", [])}
    object_lock_rule = object_lock.get("ObjectLockConfiguration", {}).get("Rule", {})
    retention = object_lock_rule.get("DefaultRetention", {})

    return {
        "bucketName": bucket_name,
        "versioningEnabled": versioning.get("Status") == "Enabled",
        "versioningStatus": versioning.get("Status", "Suspended"),
        "objectLockEnabled": bool(object_lock.get("ObjectLockConfiguration")),
        "lifecycleEnabled": bool(rules),
        "policyAttached": bool(policy.get("Policy")),
        "corsEnabled": bool(cors.get("CORSRules")),
        "encryptionEnabled": bool(encryption_rules),
        "encryptionSummary": encryption_summary,
        "objectLockMode": retention.get("Mode"),
        "objectLockRetentionDays": retention.get("Days") or retention.get("Years"),
        "tags": tags,
        "lifecycleRules": rules,
        "lifecycleJson": _json_dumps({"Rules": lifecycle.get("Rules", [])}),
        "policyJson": policy.get("Policy", "{}"),
        "corsJson": _json_dumps(cors.get("CORSRules", [])),
        "encryptionJson": _json_dumps(
            encryption.get("ServerSideEncryptionConfiguration", {})
        ),
        "apiCalls": api_calls,
    }


def _put_bucket_lifecycle(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    lifecycle_json = str(params.get("lifecycleJson", "")).strip()
    if not bucket_name or not lifecycle_json:
        raise SidecarError("invalid_config", "Bucket name and lifecycle JSON are required.")
    client = _build_client(profile)
    lifecycle = json.loads(lifecycle_json)
    client.put_bucket_lifecycle_configuration(
        Bucket=bucket_name,
        LifecycleConfiguration=lifecycle,
    )
    return _get_bucket_admin_state(params)


def _delete_bucket_lifecycle(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    client.delete_bucket_lifecycle(Bucket=bucket_name)
    return _get_bucket_admin_state(params)


def _put_bucket_policy(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    policy_json = str(params.get("policyJson", "")).strip()
    if not bucket_name or not policy_json:
        raise SidecarError("invalid_config", "Bucket name and policy JSON are required.")
    client = _build_client(profile)
    client.put_bucket_policy(Bucket=bucket_name, Policy=policy_json)
    return _get_bucket_admin_state(params)


def _delete_bucket_policy(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    client.delete_bucket_policy(Bucket=bucket_name)
    return _get_bucket_admin_state(params)


def _put_bucket_cors(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    cors_json = str(params.get("corsJson", "")).strip()
    if not bucket_name or not cors_json:
        raise SidecarError("invalid_config", "Bucket name and CORS JSON are required.")
    client = _build_client(profile)
    client.put_bucket_cors(Bucket=bucket_name, CORSConfiguration={"CORSRules": json.loads(cors_json)})
    return _get_bucket_admin_state(params)


def _delete_bucket_cors(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    client.delete_bucket_cors(Bucket=bucket_name)
    return _get_bucket_admin_state(params)


def _put_bucket_encryption(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    encryption_json = str(params.get("encryptionJson", "")).strip()
    if not bucket_name or not encryption_json:
        raise SidecarError("invalid_config", "Bucket name and encryption JSON are required.")
    client = _build_client(profile)
    client.put_bucket_encryption(
        Bucket=bucket_name,
        ServerSideEncryptionConfiguration=json.loads(encryption_json),
    )
    return _get_bucket_admin_state(params)


def _delete_bucket_encryption(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    client.delete_bucket_encryption(Bucket=bucket_name)
    return _get_bucket_admin_state(params)


def _put_bucket_tagging(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    tags = params.get("tags")
    if not bucket_name or not isinstance(tags, dict):
        raise SidecarError("invalid_config", "Bucket name and tags are required.")
    client = _build_client(profile)
    client.put_bucket_tagging(
        Bucket=bucket_name,
        Tagging={"TagSet": [{"Key": str(key), "Value": str(value)} for key, value in tags.items()]},
    )
    return _get_bucket_admin_state(params)


def _delete_bucket_tagging(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    client.delete_bucket_tagging(Bucket=bucket_name)
    return _get_bucket_admin_state(params)


def _list_object_versions(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    key = str(params.get("key", "")).strip()
    options = params.get("options") or {}
    filter_value = str(options.get("filterValue", "")).strip()
    filter_mode = str(options.get("filterMode", "prefix")).strip()
    effective_prefix = key or (filter_value if filter_mode == "prefix" else "")
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required for version listing.")

    client = _build_client(profile)
    response = client.list_object_versions(Bucket=bucket_name, Prefix=effective_prefix, MaxKeys=1000)
    items: list[dict[str, Any]] = []

    for version in response.get("Versions", []):
        version_key = str(version.get("Key", ""))
        if key and version_key != key:
            continue
        items.append(
            {
                "key": version_key,
                "versionId": version.get("VersionId", ""),
                "modifiedAt": _serialize_dt(version.get("LastModified")),
                "latest": bool(version.get("IsLatest", False)),
                "deleteMarker": False,
                "size": int(version.get("Size", 0) or 0),
                "storageClass": version.get("StorageClass", "STANDARD"),
            }
        )

    for marker in response.get("DeleteMarkers", []):
        marker_key = str(marker.get("Key", ""))
        if key and marker_key != key:
            continue
        items.append(
            {
                "key": marker_key,
                "versionId": marker.get("VersionId", ""),
                "modifiedAt": _serialize_dt(marker.get("LastModified")),
                "latest": bool(marker.get("IsLatest", False)),
                "deleteMarker": True,
                "size": 0,
                "storageClass": "DELETE_MARKER",
            }
        )

    items.sort(key=lambda item: item["modifiedAt"], reverse=True)
    return {
        "items": items,
        "cursor": {"value": None, "hasMore": False},
        "totalCount": len(items),
        "versionCount": len([item for item in items if not item["deleteMarker"]]),
        "deleteMarkerCount": len([item for item in items if item["deleteMarker"]]),
    }


def _get_object_details(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    key = str(params.get("key", "")).strip()
    if not bucket_name or not key:
        raise SidecarError("invalid_config", "Bucket name and object key are required for object inspection.")

    client = _build_client(profile)
    api_calls: list[dict[str, Any]] = []
    debug_events: list[dict[str, Any]] = []

    debug_events.append(
        {
            "timestamp": _serialize_dt(datetime.now(tz=timezone.utc)),
            "level": "DEBUG",
            "message": f"Fetching object diagnostics for {bucket_name}/{key}.",
        }
    )

    head = _call_api(api_calls, "HeadObject", lambda: client.head_object(Bucket=bucket_name, Key=key))
    tag_response = _maybe_call(
        api_calls,
        "GetObjectTagging",
        lambda: client.get_object_tagging(Bucket=bucket_name, Key=key),
        {},
    )

    tags = {item.get("Key", ""): item.get("Value", "") for item in tag_response.get("TagSet", [])}
    metadata = {key: str(value) for key, value in head.get("Metadata", {}).items()}
    headers = {
        "ETag": str(head.get("ETag", "")).strip('"'),
        "Content-Length": str(head.get("ContentLength", "")),
        "Content-Type": str(head.get("ContentType", "")),
        "Last-Modified": _serialize_dt(head.get("LastModified")),
        "Storage-Class": str(head.get("StorageClass", "STANDARD")),
        "Cache-Control": str(head.get("CacheControl", "")),
    }
    headers = {key: value for key, value in headers.items() if value}

    debug_events.append(
        {
            "timestamp": _serialize_dt(datetime.now(tz=timezone.utc)),
            "level": "INFO",
            "message": f"Loaded metadata and {len(tags)} tag(s) for {key}.",
        }
    )

    return {
        "key": key,
        "metadata": metadata,
        "headers": headers,
        "tags": tags,
        "debugEvents": debug_events,
        "apiCalls": api_calls,
        "debugLogExcerpt": [
            f"Resolved endpoint {profile.endpoint_url}.",
            f"Completed HEAD and tagging diagnostics for {bucket_name}/{key}.",
        ],
        "rawDiagnostics": {
            "bucketName": bucket_name,
            "engineState": "healthy",
        },
    }


def _generate_presigned_url(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    key = str(params.get("key", "")).strip()
    expiration_seconds = max(int(params.get("expirationSeconds", 3600) or 3600), 1)
    if not bucket_name or not key:
        raise SidecarError("invalid_config", "Bucket name and object key are required to generate a presigned URL.")

    client = _build_client(profile)
    url = client.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket_name, "Key": key},
        ExpiresIn=expiration_seconds,
    )
    return {"url": url}


def _create_folder(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    key = str(params.get("key", "")).strip()
    if not bucket_name or not key:
        raise SidecarError("invalid_config", "Bucket name and key are required to create a folder.")
    if not key.endswith("/"):
        key = f"{key}/"
    client = _build_client(profile)
    client.put_object(Bucket=bucket_name, Key=key, Body=b"")
    return {"created": True, "key": key}


def _copy_object(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    src_bucket = str(params.get("sourceBucketName", "")).strip()
    src_key = str(params.get("sourceKey", "")).strip()
    dest_bucket = str(params.get("destinationBucketName", "")).strip()
    dest_key = str(params.get("destinationKey", "")).strip()
    if not src_bucket or not src_key or not dest_bucket or not dest_key:
        raise SidecarError("invalid_config", "Copy source and destination are required.")
    client = _build_client(profile)
    client.copy_object(
        Bucket=dest_bucket,
        Key=dest_key,
        CopySource={"Bucket": src_bucket, "Key": src_key},
    )
    return {"successCount": 1, "failureCount": 0, "failures": []}


def _move_object(params: dict[str, Any]) -> dict[str, Any]:
    result = _copy_object(params)
    profile = _parse_profile(params.get("profile", {}))
    client = _build_client(profile)
    client.delete_object(
        Bucket=str(params.get("sourceBucketName", "")).strip(),
        Key=str(params.get("sourceKey", "")).strip(),
    )
    return result


def _delete_objects(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    keys = [str(item) for item in params.get("keys", []) if str(item).strip()]
    if not bucket_name or not keys:
        raise SidecarError("invalid_config", "Bucket name and keys are required.")
    client = _build_client(profile)
    response = client.delete_objects(
        Bucket=bucket_name,
        Delete={"Objects": [{"Key": key} for key in keys], "Quiet": False},
    )
    deleted = response.get("Deleted", [])
    errors = response.get("Errors", [])
    return {
        "successCount": len(deleted),
        "failureCount": len(errors),
        "failures": [
            {
                "target": str(item.get("Key", "")),
                "code": str(item.get("Code", "unknown")),
                "message": str(item.get("Message", "Unknown delete error.")),
            }
            for item in errors
        ],
    }


def _delete_object_versions(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    versions = params.get("versions") or []
    if not bucket_name or not versions:
        raise SidecarError("invalid_config", "Bucket name and versions are required.")
    client = _build_client(profile)
    response = client.delete_objects(
        Bucket=bucket_name,
        Delete={
            "Objects": [
                {"Key": str(item.get("key", "")), "VersionId": str(item.get("versionId", ""))}
                for item in versions
            ],
            "Quiet": False,
        },
    )
    deleted = response.get("Deleted", [])
    errors = response.get("Errors", [])
    return {
        "successCount": len(deleted),
        "failureCount": len(errors),
        "failures": [
            {
                "target": str(item.get("Key", "")),
                "versionId": str(item.get("VersionId", "")) or None,
                "code": str(item.get("Code", "unknown")),
                "message": str(item.get("Message", "Unknown delete error.")),
            }
            for item in errors
        ],
    }


def _int_param(params: dict[str, Any], key: str, default: int) -> int:
    value = params.get(key, default)
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return max(int(value), 1)
    try:
        return max(int(str(value).strip()), 1)
    except (TypeError, ValueError):
        return default


def _build_transfer_job(
    *,
    job_id: str,
    label: str,
    direction: str,
    progress: float,
    status: str,
    bytes_transferred: int,
    total_bytes: int,
    output_lines: list[str],
    strategy_label: str | None = None,
    current_item_label: str | None = None,
    item_count: int | None = None,
    items_completed: int | None = None,
    part_size_bytes: int | None = None,
    parts_completed: int | None = None,
    parts_total: int | None = None,
    can_pause: bool = False,
    can_resume: bool = False,
    can_cancel: bool = False,
) -> dict[str, Any]:
    return {
        "id": job_id,
        "label": label,
        "direction": direction,
        "progress": progress,
        "status": status,
        "bytesTransferred": bytes_transferred,
        "totalBytes": total_bytes,
        "strategyLabel": strategy_label,
        "currentItemLabel": current_item_label,
        "itemCount": item_count,
        "itemsCompleted": items_completed,
        "partSizeBytes": part_size_bytes,
        "partsCompleted": parts_completed,
        "partsTotal": parts_total,
        "canPause": can_pause,
        "canResume": can_resume,
        "canCancel": can_cancel,
        "outputLines": output_lines,
    }


def _emit_transfer_event(job: dict[str, Any]) -> None:
    print(json.dumps({"event": "transferProgress", "job": job}), flush=True)


def _transfer_strategy_label(direction: str, uses_multipart: bool) -> str:
    return f'{"Multipart" if uses_multipart else "Single-part"} {direction}'


def _start_upload(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    prefix = str(params.get("prefix", "")).strip()
    file_paths = [str(item) for item in params.get("filePaths", []) if str(item).strip()]
    object_key_by_path = {
        str(key): str(value).replace("\\", "/").lstrip("/")
        for key, value in dict(params.get("objectKeyByPath", {}) or {}).items()
        if str(value).strip()
    }
    if not bucket_name or not file_paths:
        raise SidecarError("invalid_config", "Bucket name and file paths are required.")
    multipart_threshold_bytes = _int_param(params, "multipartThresholdMiB", 32) * 1024 * 1024
    multipart_chunk_bytes = _int_param(params, "multipartChunkMiB", 8) * 1024 * 1024
    client = _build_client(profile)
    paths = [Path(file_path) for file_path in file_paths]
    total_bytes = sum(path.stat().st_size for path in paths)
    uses_multipart = any(path.stat().st_size >= multipart_threshold_bytes for path in paths)
    parts_total = sum(
        max((path.stat().st_size + multipart_chunk_bytes - 1) // multipart_chunk_bytes, 1)
        for path in paths
        if path.stat().st_size >= multipart_threshold_bytes
    )
    part_size_bytes = multipart_chunk_bytes if parts_total > 0 else None
    job_id = f"upload-{uuid.uuid4().hex[:8]}"
    label = f"Upload {len(paths)} file(s) to {bucket_name}"
    strategy_label = _transfer_strategy_label("upload", uses_multipart)
    output_lines = [f"Queued {len(paths)} file(s) for upload to {bucket_name}."]
    bytes_transferred = 0
    items_completed = 0
    parts_completed = 0
    queued_job = _build_transfer_job(
        job_id=job_id,
        label=label,
        direction="upload",
        progress=0,
        status="queued",
        bytes_transferred=0,
        total_bytes=total_bytes,
        output_lines=list(output_lines),
        strategy_label=strategy_label,
        current_item_label=paths[0].name if paths else None,
        item_count=len(paths),
        items_completed=items_completed,
        part_size_bytes=part_size_bytes,
        parts_completed=parts_completed if part_size_bytes is not None else None,
        parts_total=parts_total if part_size_bytes is not None else None,
        can_pause=True,
        can_cancel=True,
    )
    _emit_transfer_event(queued_job)
    for path in paths:
        target_name = object_key_by_path.get(str(path), path.name)
        target_key = f"{prefix}{target_name}" if prefix else target_name
        file_size = path.stat().st_size
        output_lines.append(f"Uploading {path.name} ({file_size} bytes) to {target_key}.")
        if file_size >= multipart_threshold_bytes:
            response = client.create_multipart_upload(Bucket=bucket_name, Key=target_key)
            upload_id = response.get("UploadId")
            if not upload_id:
                raise SidecarError("engine_unavailable", "Multipart upload did not return an upload ID.")
            completed_parts: list[dict[str, Any]] = []
            part_number = 1
            with path.open("rb") as handle:
                while True:
                    chunk = handle.read(multipart_chunk_bytes)
                    if not chunk:
                        break
                    part_response = client.upload_part(
                        Bucket=bucket_name,
                        Key=target_key,
                        UploadId=upload_id,
                        PartNumber=part_number,
                        Body=chunk,
                    )
                    completed_parts.append(
                        {
                            "ETag": part_response.get("ETag"),
                            "PartNumber": part_number,
                        }
                    )
                    bytes_transferred += len(chunk)
                    parts_completed += 1
                    output_lines.append(f"Uploaded part {part_number} for {path.name}.")
                    _emit_transfer_event(
                        _build_transfer_job(
                            job_id=job_id,
                            label=label,
                            direction="upload",
                            progress=bytes_transferred / total_bytes if total_bytes else 1,
                            status="running",
                            bytes_transferred=bytes_transferred,
                            total_bytes=total_bytes,
                            output_lines=list(output_lines),
                            strategy_label=strategy_label,
                            current_item_label=path.name,
                            item_count=len(paths),
                            items_completed=items_completed,
                            part_size_bytes=part_size_bytes,
                            parts_completed=parts_completed,
                            parts_total=parts_total,
                            can_pause=True,
                            can_cancel=True,
                        )
                    )
                    part_number += 1
            client.complete_multipart_upload(
                Bucket=bucket_name,
                Key=target_key,
                UploadId=upload_id,
                MultipartUpload={"Parts": completed_parts},
            )
        else:
            with path.open("rb") as handle:
                client.put_object(Bucket=bucket_name, Key=target_key, Body=handle)
            bytes_transferred += file_size
        items_completed += 1
        output_lines.append(f"Finished uploading {path.name}.")
        _emit_transfer_event(
            _build_transfer_job(
                job_id=job_id,
                label=label,
                direction="upload",
                progress=bytes_transferred / total_bytes if total_bytes else 1,
                status="running",
                bytes_transferred=bytes_transferred,
                total_bytes=total_bytes,
                output_lines=list(output_lines),
                strategy_label=strategy_label,
                current_item_label=path.name,
                item_count=len(paths),
                items_completed=items_completed,
                part_size_bytes=part_size_bytes,
                parts_completed=parts_completed if part_size_bytes is not None else None,
                parts_total=parts_total if part_size_bytes is not None else None,
                can_pause=True,
                can_cancel=True,
            )
        )
    output_lines.append(f"Uploaded {len(paths)} file(s) into {bucket_name}.")
    return _build_transfer_job(
        job_id=job_id,
        label=label,
        direction="upload",
        progress=1,
        status="completed",
        bytes_transferred=bytes_transferred,
        total_bytes=total_bytes,
        output_lines=output_lines,
        strategy_label=strategy_label,
        current_item_label=paths[-1].name if paths else None,
        item_count=len(paths),
        items_completed=items_completed,
        part_size_bytes=part_size_bytes,
        parts_completed=parts_completed if part_size_bytes is not None else None,
        parts_total=parts_total if part_size_bytes is not None else None,
    )


def _start_download(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    keys = [str(item) for item in params.get("keys", []) if str(item).strip()]
    destination_path = str(params.get("destinationPath", "")).strip()
    if not bucket_name or not keys or not destination_path:
        raise SidecarError("invalid_config", "Bucket, keys, and destination path are required.")
    multipart_threshold_bytes = _int_param(params, "multipartThresholdMiB", 32) * 1024 * 1024
    multipart_chunk_bytes = _int_param(params, "multipartChunkMiB", 8) * 1024 * 1024
    client = _build_client(profile)
    destination = Path(destination_path)
    destination.mkdir(parents=True, exist_ok=True)
    sizes = {
        key: int(client.head_object(Bucket=bucket_name, Key=key).get("ContentLength", 0))
        for key in keys
    }
    total_bytes = sum(sizes.values())
    uses_multipart = any(size >= multipart_threshold_bytes for size in sizes.values())
    parts_total = sum(
        max((size + multipart_chunk_bytes - 1) // multipart_chunk_bytes, 1)
        for size in sizes.values()
        if size >= multipart_threshold_bytes
    )
    part_size_bytes = multipart_chunk_bytes if parts_total > 0 else None
    job_id = f"download-{uuid.uuid4().hex[:8]}"
    label = f"Download {len(keys)} object(s) from {bucket_name}"
    strategy_label = _transfer_strategy_label("download", uses_multipart)
    output_lines = [f"Queued {len(keys)} object(s) for download to {destination_path}."]
    bytes_transferred = 0
    items_completed = 0
    parts_completed = 0
    _emit_transfer_event(
        _build_transfer_job(
            job_id=job_id,
            label=label,
            direction="download",
            progress=0,
            status="queued",
            bytes_transferred=0,
            total_bytes=total_bytes,
            output_lines=list(output_lines),
            strategy_label=strategy_label,
            current_item_label=keys[0] if keys else None,
            item_count=len(keys),
            items_completed=items_completed,
            part_size_bytes=part_size_bytes,
            parts_completed=parts_completed if part_size_bytes is not None else None,
            parts_total=parts_total if part_size_bytes is not None else None,
            can_pause=True,
            can_cancel=True,
        )
    )
    for key in keys:
        target = destination / Path(key).name
        object_size = sizes[key]
        output_lines.append(f"Downloading {key} ({object_size} bytes) to {target}.")
        with target.open("wb") as handle:
            if object_size >= multipart_threshold_bytes:
                start = 0
                while start < object_size:
                    end = min(start + multipart_chunk_bytes - 1, object_size - 1)
                    response = client.get_object(
                        Bucket=bucket_name,
                        Key=key,
                        Range=f"bytes={start}-{end}",
                    )
                    handle.write(response["Body"].read())
                    chunk_size = end - start + 1
                    bytes_transferred += chunk_size
                    parts_completed += 1
                    output_lines.append(
                        f"Downloaded byte range {start}-{end} for {key}."
                    )
                    _emit_transfer_event(
                        _build_transfer_job(
                            job_id=job_id,
                            label=label,
                            direction="download",
                            progress=bytes_transferred / total_bytes if total_bytes else 1,
                            status="running",
                            bytes_transferred=bytes_transferred,
                            total_bytes=total_bytes,
                            output_lines=list(output_lines),
                            strategy_label=strategy_label,
                            current_item_label=key,
                            item_count=len(keys),
                            items_completed=items_completed,
                            part_size_bytes=part_size_bytes,
                            parts_completed=parts_completed,
                            parts_total=parts_total,
                            can_pause=True,
                            can_cancel=True,
                        )
                    )
                    start = end + 1
            else:
                response = client.get_object(Bucket=bucket_name, Key=key)
                while True:
                    chunk = response["Body"].read(min(multipart_chunk_bytes, 1024 * 1024))
                    if not chunk:
                        break
                    handle.write(chunk)
                    bytes_transferred += len(chunk)
                    _emit_transfer_event(
                        _build_transfer_job(
                            job_id=job_id,
                            label=label,
                            direction="download",
                            progress=bytes_transferred / total_bytes if total_bytes else 1,
                            status="running",
                            bytes_transferred=bytes_transferred,
                            total_bytes=total_bytes,
                            output_lines=list(output_lines),
                            strategy_label=strategy_label,
                            current_item_label=key,
                            item_count=len(keys),
                            items_completed=items_completed,
                            part_size_bytes=part_size_bytes,
                            parts_completed=parts_completed if part_size_bytes is not None else None,
                            parts_total=parts_total if part_size_bytes is not None else None,
                            can_pause=True,
                            can_cancel=True,
                        )
                    )
        items_completed += 1
        output_lines.append(f"Finished downloading {key}.")
    output_lines.append(f"Downloaded {len(keys)} object(s) into {destination_path}.")
    return _build_transfer_job(
        job_id=job_id,
        label=label,
        direction="download",
        progress=1,
        status="completed",
        bytes_transferred=bytes_transferred,
        total_bytes=total_bytes,
        output_lines=output_lines,
        strategy_label=strategy_label,
        current_item_label=keys[-1] if keys else None,
        item_count=len(keys),
        items_completed=items_completed,
        part_size_bytes=part_size_bytes,
        parts_completed=parts_completed if part_size_bytes is not None else None,
        parts_total=parts_total if part_size_bytes is not None else None,
    )


def _transfer_control(params: dict[str, Any], action: str) -> dict[str, Any]:
    job_id = str(params.get("jobId", "")).strip()
    return _build_transfer_job(
        job_id=job_id or f"transfer-{uuid.uuid4().hex[:8]}",
        label=f"Transfer {action}",
        direction="transfer",
        progress=1.0 if action == "cancelled" else 0.0,
        status=action,
        bytes_transferred=0,
        total_bytes=0,
        output_lines=[f"Transfer {action}."],
    )


def _tool_state(label: str, status: str, lines: list[str]) -> dict[str, Any]:
    return {
        "label": label,
        "running": False,
        "lastStatus": status,
        "jobId": f"tool-{uuid.uuid4().hex[:8]}",
        "cancellable": False,
        "outputLines": lines,
        "exitCode": 0,
    }


def _run_put_testdata(params: dict[str, Any]) -> dict[str, Any]:
    config = params.get("config") or {}
    object_count = int(config.get("objectCount", 0) or 0)
    versions = int(config.get("versions", 0) or 0)
    bucket_name = str(config.get("bucketName", "")).strip()
    return _tool_state(
        "put-testdata.py",
        f"Prepared {object_count} object(s) with {versions} version(s) each for {bucket_name}.",
        [
            f"Bucket: {bucket_name}",
            f"Prefix: {config.get('prefix', '')}",
            f"Threads: {config.get('threads', 1)}",
        ],
    )


def _run_delete_all(params: dict[str, Any]) -> dict[str, Any]:
    config = params.get("config") or {}
    bucket_name = str(config.get("bucketName", "")).strip()
    return _tool_state(
        "delete-all.py",
        f"Prepared delete-all sweep for {bucket_name}.",
        [
            f"Batch size: {config.get('batchSize', 1000)}",
            f"Workers: {config.get('maxWorkers', 1)}",
        ],
    )


def _cancel_tool_execution(params: dict[str, Any]) -> dict[str, Any]:
    job_id = str(params.get("jobId", "")).strip()
    return {
        "label": job_id or "tool",
        "running": False,
        "lastStatus": f"Cancelled tool execution {job_id}.",
        "jobId": job_id,
        "cancellable": False,
        "outputLines": [f"Tool execution {job_id} cancelled."],
        "exitCode": 130,
    }


def _runtime_dir() -> Path:
    path = Path(tempfile.gettempdir()) / "object-data-browser-python-engine"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _benchmark_state_path(run_id: str) -> Path:
    return _runtime_dir() / f"benchmark-{run_id}.json"


def _read_benchmark_state(run_id: str) -> dict[str, Any]:
    path = _benchmark_state_path(run_id)
    if not path.exists():
        raise SidecarError("invalid_config", f"Benchmark run {run_id} was not found.")
    return json.loads(path.read_text())


def _write_benchmark_state(state: dict[str, Any]) -> None:
    _benchmark_state_path(str(state["id"])).write_text(json.dumps(state))


def _now_iso() -> str:
    return _serialize_dt(datetime.now(tz=timezone.utc))


def _benchmark_ratios(workload_type: str) -> list[tuple[str, int]]:
    if workload_type == "write-heavy":
        return [("PUT", 60), ("GET", 30), ("DELETE", 10)]
    if workload_type == "read-heavy":
        return [("PUT", 25), ("GET", 65), ("DELETE", 10)]
    if workload_type == "delete":
        return [("PUT", 0), ("GET", 0), ("DELETE", 100)]
    return [("PUT", 34), ("GET", 33), ("DELETE", 33)]


def _benchmark_operations_from_history(history: list[dict[str, Any]]) -> dict[str, int]:
    operations = {"PUT": 0, "GET": 0, "DELETE": 0}
    for record in history:
        operation = str(record.get("operation", "")).upper()
        if operation not in operations:
            operations[operation] = 0
        operations[operation] += _benchmark_operation_count(record)
    return {key: value for key, value in operations.items() if value > 0}


def _benchmark_profile(profile_payload: dict[str, Any], config: dict[str, Any]) -> Profile:
    merged = dict(profile_payload)
    merged["connectTimeoutSeconds"] = int(
        config.get("connectTimeoutSeconds", merged.get("connectTimeoutSeconds", 5)) or 5
    )
    merged["readTimeoutSeconds"] = int(
        config.get("readTimeoutSeconds", merged.get("readTimeoutSeconds", 60)) or 60
    )
    merged["maxAttempts"] = int(config.get("maxAttempts", merged.get("maxAttempts", 5)) or 5)
    merged["maxConcurrentRequests"] = int(
        config.get("maxPoolConnections", merged.get("maxConcurrentRequests", 10)) or 10
    )
    return _parse_profile(merged)


def _append_benchmark_log(state: dict[str, Any], line: str) -> None:
    log = [str(item) for item in state.get("liveLog", [])]
    log.append(line)
    state["liveLog"] = log[-60:]


def _benchmark_size_list(config: dict[str, Any]) -> list[int]:
    sizes = [int(item) for item in config.get("objectSizes", []) if int(item) > 0]
    return sizes or [4096]


def _benchmark_base_prefix(config: dict[str, Any], run_id: str) -> str:
    prefix = str(config.get("prefix", "")).strip()
    if prefix and not prefix.endswith("/"):
        prefix = f"{prefix}/"
    return f"{prefix}{run_id}/"


def _benchmark_payload_bytes(run_id: str, key: str, size_bytes: int, random_data: bool) -> bytes:
    if size_bytes <= 0:
        return b""
    if not random_data:
        return (b"A" * size_bytes)[:size_bytes]
    seed = f"{run_id}:{key}:{size_bytes}".encode("utf-8") or b"s3-benchmark"
    pattern_length = min(max(len(seed) * 8, 64), 4096)
    pattern = bytearray(pattern_length)
    for index in range(pattern_length):
        pattern[index] = (seed[index % len(seed)] + (index * 17)) % 256
    repeats = (size_bytes // len(pattern)) + 1
    return (bytes(pattern) * repeats)[:size_bytes]


def _benchmark_percentile(values: list[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    rank = ((len(ordered) - 1) * percentile) / 100
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    weight = rank - lower
    return float(ordered[lower] + ((ordered[upper] - ordered[lower]) * weight))


def _benchmark_latency_percentiles(values: list[float]) -> dict[str, float]:
    return {
        "p50": round(_benchmark_percentile(values, 50), 1),
        "p75": round(_benchmark_percentile(values, 75), 1),
        "p90": round(_benchmark_percentile(values, 90), 1),
        "p95": round(_benchmark_percentile(values, 95), 1),
        "p99": round(_benchmark_percentile(values, 99), 1),
        "p999": round(_benchmark_percentile(values, 99.9), 1),
    }


def _benchmark_operation_for_index(state: dict[str, Any]) -> str:
    slot = int(state.get("processedCount", 0) or 0) % 100
    cumulative = 0
    for operation, ratio in _benchmark_ratios(str(state.get("config", {}).get("workloadType", "mixed"))):
        cumulative += ratio
        if slot < cumulative:
            return operation
    return "PUT"


def _benchmark_operation_count(record: dict[str, Any]) -> int:
    return max(int(record.get("operationCount", 1) or 1), 1)


def _benchmark_timeline_label(elapsed_seconds: float) -> str:
    if elapsed_seconds >= 100:
        return f"{elapsed_seconds:.0f}s"
    if elapsed_seconds >= 10:
        return f"{elapsed_seconds:.1f}s"
    return f"{elapsed_seconds:.2f}s"


def _benchmark_delete_mode(config: dict[str, Any]) -> str:
    return "multi-object-post" if str(config.get("deleteMode", "single")) == "multi-object-post" else "single"


def _benchmark_delete_batch_size(config: dict[str, Any], active_count: int) -> int:
    if _benchmark_delete_mode(config) != "multi-object-post":
        return 1
    return max(1, min(active_count, max(int(config.get("concurrentThreads", 1) or 1), 2), 1000))


def _benchmark_upsert_active_object(
    active_objects: list[dict[str, Any]],
    key: str,
    size_bytes: int,
) -> None:
    for entry in active_objects:
        if str(entry.get("key", "")) == key:
            entry["sizeBytes"] = size_bytes
            return
    active_objects.append({"key": key, "sizeBytes": size_bytes})


def _is_missing_benchmark_key(error: Exception) -> bool:
    code = _client_error_code(error)
    message = str(error).lower()
    return code in {"NoSuchKey", "NotFound", "404"} or "does not exist" in message


def _rebuild_benchmark_summary(state: dict[str, Any]) -> dict[str, Any]:
    config = dict(state.get("config") or {})
    history = [dict(item) for item in state.get("history", [])]
    operations_by_type = _benchmark_operations_from_history(history)
    latency_values = [float(item.get("latencyMs", 0) or 0) for item in history]
    checksum_stats = {"validated_success": 0, "validated_failure": 0, "not_used": 0}
    for record in history:
        checksum_state = str(record.get("checksumState", "not_used"))
        if checksum_state not in checksum_stats:
            checksum_stats[checksum_state] = 0
        checksum_stats[checksum_state] += _benchmark_operation_count(record)

    windows: dict[int, list[dict[str, Any]]] = {}
    for record in history:
        second = max(int(record.get("second", 1) or 1), 1)
        windows.setdefault(second, []).append(record)

    throughput_series: list[dict[str, Any]] = []
    for second in sorted(windows):
        items = windows[second]
        latencies = [float(item.get("latencyMs", 0) or 0) for item in items]
        per_operation: dict[str, int] = {}
        latency_by_operation: dict[str, list[float]] = {}
        bytes_per_second = 0
        for item in items:
            operation = str(item.get("operation", "")).upper()
            operation_count = _benchmark_operation_count(item)
            per_operation[operation] = per_operation.get(operation, 0) + operation_count
            latency_by_operation.setdefault(operation, []).append(
                float(item.get("latencyMs", 0) or 0)
            )
            bytes_per_second += int(item.get("bytesTransferred", 0) or 0)
        ops_per_second = sum(_benchmark_operation_count(item) for item in items)
        throughput_series.append(
            {
                "second": second,
                "label": f"{second}s",
                "opsPerSecond": ops_per_second,
                "bytesPerSecond": bytes_per_second,
                "averageLatencyMs": round(sum(latencies) / max(len(latencies), 1), 1),
                "p95LatencyMs": round(_benchmark_percentile(latencies, 95), 1),
                "operations": per_operation,
                "latencyByOperationMs": {
                    operation: round(sum(values) / max(len(values), 1), 1)
                    for operation, values in latency_by_operation.items()
                },
            }
        )

    second_positions: dict[int, int] = {}
    latency_timeline: list[dict[str, Any]] = []
    for sequence, record in enumerate(history, start=1):
        second = max(int(record.get("second", 1) or 1), 1)
        position = second_positions.get(second, 0) + 1
        second_positions[second] = position
        elapsed_ms = float(record.get("elapsedMs", 0) or 0)
        if elapsed_ms <= 0:
            elapsed_seconds = (second - 1) + (position / (len(windows.get(second, [])) + 1))
            elapsed_ms = elapsed_seconds * 1000
        else:
            elapsed_seconds = elapsed_ms / 1000
        latency_timeline.append(
            {
                "sequence": sequence,
                "operation": str(record.get("operation", "")).upper(),
                "second": second,
                "elapsedMs": round(elapsed_ms, 1),
                "label": _benchmark_timeline_label(elapsed_seconds),
                "latencyMs": round(float(record.get("latencyMs", 0) or 0), 1),
                "sizeBytes": int(record.get("sizeBytes", 0) or 0),
                "bytesTransferred": int(record.get("bytesTransferred", 0) or 0),
                "operationCount": _benchmark_operation_count(record),
                "success": bool(record.get("success", True)),
                "key": str(record.get("key", "")),
            }
        )

    size_latency_buckets: list[dict[str, Any]] = []
    observed_sizes = sorted(
        {
            int(record.get("sizeBytes", 0) or 0)
            for record in history
            if int(record.get("sizeBytes", 0) or 0) > 0
        }
        | set(_benchmark_size_list(config))
    )
    for size_bytes in observed_sizes:
        bucket_latencies = [
            float(item.get("latencyMs", 0) or 0)
            for item in history
            if int(item.get("sizeBytes", 0) or 0) == size_bytes
        ]
        size_latency_buckets.append(
            {
                "sizeBytes": size_bytes,
                "count": len(bucket_latencies),
                "avgLatencyMs": round(sum(bucket_latencies) / max(len(bucket_latencies), 1), 1)
                if bucket_latencies
                else 0.0,
                "p50LatencyMs": round(_benchmark_percentile(bucket_latencies, 50), 1),
                "p95LatencyMs": round(_benchmark_percentile(bucket_latencies, 95), 1),
                "p99LatencyMs": round(_benchmark_percentile(bucket_latencies, 99), 1),
            }
        )

    latency_percentiles_by_operation: dict[str, dict[str, float]] = {}
    operation_details: list[dict[str, Any]] = []
    total_operations = sum(_benchmark_operation_count(item) for item in history)
    sample_count = len(throughput_series)
    for operation, count in operations_by_type.items():
        op_latencies = [
            float(item.get("latencyMs", 0) or 0)
            for item in history
            if str(item.get("operation", "")).upper() == operation
        ]
        latency_percentiles = _benchmark_latency_percentiles(op_latencies)
        latency_percentiles_by_operation[operation] = latency_percentiles
        per_window = [
            int(window.get("operations", {}).get(operation, 0) or 0)
            for window in throughput_series
        ]
        operation_details.append(
            {
                "operation": operation,
                "count": count,
                "sharePct": round((count / max(total_operations, 1)) * 100, 1),
                "avgOpsPerSecond": round(sum(per_window) / max(len(per_window), 1), 1),
                "peakOpsPerSecond": max(per_window) if per_window else 0,
                "p50LatencyMs": latency_percentiles["p50"],
                "p95LatencyMs": latency_percentiles["p95"],
                "p99LatencyMs": latency_percentiles["p99"],
            }
        )

    average_bytes = (
        sum(float(item.get("bytesPerSecond", 0) or 0) for item in throughput_series)
        / max(len(throughput_series), 1)
        if throughput_series
        else 0.0
    )
    peak_bytes = max(
        [int(item.get("bytesPerSecond", 0) or 0) for item in throughput_series] or [0]
    )
    average_ops = (
        sum(float(item.get("opsPerSecond", 0) or 0) for item in throughput_series)
        / max(len(throughput_series), 1)
        if throughput_series
        else 0.0
    )
    peak_ops = max([int(item.get("opsPerSecond", 0) or 0) for item in throughput_series] or [0])
    size_list = _benchmark_size_list(config)
    average_object_size = int(sum(size_list) / max(len(size_list), 1))
    failures = len([item for item in history if not bool(item.get("success", True))])

    return {
        "totalOperations": total_operations,
        "operationsByType": operations_by_type,
        "latencyPercentilesMs": _benchmark_latency_percentiles(latency_values),
        "latencyPercentilesByOperationMs": latency_percentiles_by_operation,
        "throughputSeries": throughput_series,
        "latencyTimeline": latency_timeline,
        "sizeLatencyBuckets": size_latency_buckets,
        "checksumStats": checksum_stats,
        "detailMetrics": {
            "sampleCount": sample_count,
            "sampleWindowSeconds": 1,
            "averageOpsPerSecond": round(average_ops, 1),
            "peakOpsPerSecond": peak_ops,
            "averageBytesPerSecond": round(average_bytes, 1),
            "peakBytesPerSecond": peak_bytes,
            "averageObjectSizeBytes": average_object_size,
            "checksumValidated": checksum_stats.get("validated_success", 0),
            "errorCount": failures,
            "retryCount": 0,
            "runMode": config.get("testMode", "duration"),
            "workloadType": config.get("workloadType", "mixed"),
            "bucket": config.get("bucketName", ""),
            "prefix": config.get("prefix", ""),
        },
        "operationDetails": operation_details,
    }


def _persist_benchmark_outputs(state: dict[str, Any]) -> None:
    config = dict(state.get("config") or {})
    csv_path = Path(str(config.get("csvOutputPath", "benchmark-results.csv")))
    json_path = Path(str(config.get("jsonOutputPath", "benchmark-results.json")))
    log_path = Path(str(config.get("logFilePath", "benchmark.log")))
    for path in (csv_path, json_path, log_path):
        path.parent.mkdir(parents=True, exist_ok=True)

    history = [dict(item) for item in state.get("history", [])]
    csv_lines = ["second,operation,operationCount,latencyMs,sizeBytes,bytesTransferred,success,checksumState,key"]
    for item in history:
        csv_lines.append(
            ",".join(
                [
                    str(int(item.get("second", 0) or 0)),
                    str(item.get("operation", "")),
                    str(_benchmark_operation_count(item)),
                    str(round(float(item.get("latencyMs", 0) or 0), 1)),
                    str(int(item.get("sizeBytes", 0) or 0)),
                    str(int(item.get("bytesTransferred", 0) or 0)),
                    "true" if bool(item.get("success", True)) else "false",
                    str(item.get("checksumState", "not_used")),
                    str(item.get("key", "")),
                ]
            )
        )
    csv_path.write_text("\n".join(csv_lines) + "\n")
    json_path.write_text(json.dumps(state.get("resultSummary"), indent=2))
    log_path.write_text("\n".join(str(item) for item in state.get("liveLog", [])))


def _run_benchmark_operation(state: dict[str, Any], client: Any) -> None:
    config = dict(state.get("config") or {})
    active_objects = [dict(item) for item in state.get("activeObjects", [])]
    history = [dict(item) for item in state.get("history", [])]
    operation = _benchmark_operation_for_index(state)
    size_list = _benchmark_size_list(config)
    next_size_index = int(state.get("nextSizeIndex", 0) or 0)
    size_bytes = size_list[next_size_index % len(size_list)]
    state["nextSizeIndex"] = next_size_index + 1
    checksum_enabled = bool(config.get("validateChecksum", True))
    object_limit = max(int(config.get("objectCount", len(size_list) or 1) or 1), 1)
    active_index = int(state.get("nextActiveIndex", 0) or 0)

    if operation in {"GET", "DELETE"} and not active_objects:
        operation = "PUT"

    key = ""
    bytes_transferred = 0
    checksum_state = "not_used"
    operation_count = 1
    if operation == "PUT":
        next_object_index = int(state.get("nextObjectIndex", 0) or 0)
        if len(active_objects) >= object_limit and active_objects:
            selected = active_objects[active_index % len(active_objects)]
            key = str(selected.get("key", ""))
            state["nextActiveIndex"] = active_index + 1
        else:
            key = f"{state['benchmarkPrefix']}obj-{next_object_index:06d}-{size_bytes}.bin"
            state["nextObjectIndex"] = next_object_index + 1
        payload = _benchmark_payload_bytes(str(state["id"]), key, size_bytes, bool(config.get("randomData", True)))
        started_at = time.perf_counter()
        client.put_object(Bucket=str(config.get("bucketName", "")), Key=key, Body=payload)
        latency_ms = (time.perf_counter() - started_at) * 1000
        bytes_transferred = len(payload)
        _benchmark_upsert_active_object(active_objects, key, size_bytes)
    elif operation == "GET":
        selected = active_objects[active_index % len(active_objects)]
        key = str(selected.get("key", ""))
        size_bytes = int(selected.get("sizeBytes", size_bytes) or size_bytes)
        state["nextActiveIndex"] = active_index + 1
        started_at = time.perf_counter()
        try:
            response = client.get_object(Bucket=str(config.get("bucketName", "")), Key=key)
        except Exception as error:  # noqa: BLE001
            if _is_missing_benchmark_key(error):
                active_objects = [
                    item for item in active_objects if str(item.get("key", "")) != key
                ]
                state["activeObjects"] = active_objects
                _append_benchmark_log(
                    state,
                    f"Skipped missing benchmark object {key}; rotating to the next object.",
                )
                _run_benchmark_operation(state, client)
                return
            raise
        body = response["Body"].read()
        latency_ms = (time.perf_counter() - started_at) * 1000
        bytes_transferred = len(body)
        if checksum_enabled:
            expected = _benchmark_payload_bytes(
                str(state["id"]),
                key,
                size_bytes,
                bool(config.get("randomData", True)),
            )
            checksum_state = "validated_success" if body == expected else "validated_failure"
        response["Body"].close()
    else:
        delete_batch_size = _benchmark_delete_batch_size(config, len(active_objects))
        selected_batch = [
            active_objects[(active_index + offset) % len(active_objects)]
            for offset in range(delete_batch_size)
        ]
        selected_keys = [str(item.get("key", "")) for item in selected_batch]
        state["nextActiveIndex"] = active_index + delete_batch_size
        started_at = time.perf_counter()
        if _benchmark_delete_mode(config) == "multi-object-post" and len(selected_keys) > 1:
            response = client.delete_objects(
                Bucket=str(config.get("bucketName", "")),
                Delete={"Objects": [{"Key": item} for item in selected_keys], "Quiet": False},
            )
            latency_ms = (time.perf_counter() - started_at) * 1000
            deleted_keys = {
                str(item.get("Key", ""))
                for item in response.get("Deleted", [])
                if str(item.get("Key", "")).strip()
            }
            missing_keys: set[str] = set()
            fatal_errors: list[str] = []
            for item in response.get("Errors", []):
                target = str(item.get("Key", "")).strip()
                code = str(item.get("Code", "")).strip().lower()
                message = str(item.get("Message", "")).strip()
                if code in {"nosuchkey", "notfound", "404"} or "does not exist" in message.lower():
                    if target:
                        missing_keys.add(target)
                    continue
                fatal_errors.append(
                    f"{target or '(unknown)'}: {message or str(item.get('Code', 'delete error'))}",
                )
            if fatal_errors:
                raise SidecarError("delete_failed", "; ".join(fatal_errors[:5]))
            removed_keys = deleted_keys | missing_keys
            active_objects = [
                item for item in active_objects if str(item.get("key", "")) not in removed_keys
            ]
            if missing_keys:
                _append_benchmark_log(
                    state,
                    f"Skipped {len(missing_keys)} missing benchmark object(s) during multi-delete POST.",
                )
            operation_count = len(deleted_keys)
            if operation_count == 0:
                state["activeObjects"] = active_objects
                _run_benchmark_operation(state, client)
                return
            first_key = next(iter(deleted_keys))
            key = (
                f"{first_key} (+{operation_count - 1} more)"
                if operation_count > 1
                else first_key
            )
            size_bytes = 0
        else:
            selected = selected_batch[0]
            key = str(selected.get("key", ""))
            size_bytes = int(selected.get("sizeBytes", size_bytes) or size_bytes)
            try:
                client.delete_object(Bucket=str(config.get("bucketName", "")), Key=key)
            except Exception as error:  # noqa: BLE001
                if _is_missing_benchmark_key(error):
                    active_objects = [
                        item for item in active_objects if str(item.get("key", "")) != key
                    ]
                    state["activeObjects"] = active_objects
                    _append_benchmark_log(
                        state,
                        f"Skipped missing benchmark object {key}; rotating to the next object.",
                    )
                    _run_benchmark_operation(state, client)
                    return
                raise
            latency_ms = (time.perf_counter() - started_at) * 1000
            active_objects = [
                item for item in active_objects if str(item.get("key", "")) != key
            ]

    elapsed_seconds = max(float(state.get("activeElapsedSeconds", 0.0) or 0.0), 0.0)
    history.append(
        {
            "timestamp": _now_iso(),
            "second": max(int(elapsed_seconds), 0) + 1,
            "operation": operation,
            "key": key,
            "sizeBytes": size_bytes,
            "latencyMs": round(latency_ms, 1),
            "bytesTransferred": bytes_transferred,
            "success": True,
            "checksumState": checksum_state,
            "operationCount": operation_count,
        }
    )
    state["activeObjects"] = active_objects
    state["history"] = history
    state["processedCount"] = sum(_benchmark_operation_count(item) for item in history)
    if operation == "DELETE" and operation_count > 1:
        _append_benchmark_log(
            state,
            f"DELETE POST removed {operation_count} object(s) in {round(latency_ms, 1)} ms.",
        )
    else:
        _append_benchmark_log(
            state,
            f"{operation} {key} completed in {round(latency_ms, 1)} ms.",
        )


def _refresh_benchmark_snapshot(state: dict[str, Any]) -> None:
    status = str(state.get("status", "") or "")
    if status not in {"completed", "stopped", "failed"}:
        now = datetime.now(tz=timezone.utc)
        last_updated = datetime.fromisoformat(
            str(state.get("lastUpdatedAt") or state["startedAt"]),
        )
        delta_seconds = max((now - last_updated).total_seconds(), 0.0)
        state["activeElapsedSeconds"] = (
            float(state.get("activeElapsedSeconds", 0.0) or 0.0) + delta_seconds
        )
        state["lastUpdatedAt"] = _serialize_dt(now)

    summary = _rebuild_benchmark_summary(state)
    state["resultSummary"] = summary
    history = [dict(item) for item in state.get("history", [])]
    latency_values = [float(item.get("latencyMs", 0) or 0) for item in history]
    state["averageLatencyMs"] = (
        round(sum(latency_values) / max(len(latency_values), 1), 1)
        if latency_values
        else 0.0
    )
    throughput_series = list(summary.get("throughputSeries", []))
    state["throughputOpsPerSecond"] = (
        float(throughput_series[-1].get("opsPerSecond", 0) or 0)
        if throughput_series
        else 0.0
    )


def _materialize_benchmark_state(state: dict[str, Any]) -> dict[str, Any]:
    if state["status"] in {"paused", "completed", "stopped", "failed"}:
        return state

    config = dict(state.get("config") or {})
    now = datetime.now(tz=timezone.utc)
    last_updated = datetime.fromisoformat(str(state.get("lastUpdatedAt") or state["startedAt"]))
    delta_seconds = max((now - last_updated).total_seconds(), 0.0)
    active_elapsed = float(state.get("activeElapsedSeconds", 0.0) or 0.0) + delta_seconds
    state["activeElapsedSeconds"] = active_elapsed
    state["lastUpdatedAt"] = _serialize_dt(now)
    if bool(config.get("debugMode", False)):
        _emit_structured_log(
            "DEBUG",
            "BenchmarkTrace",
            f"Benchmark tick status={state.get('status', 'unknown')} elapsed={active_elapsed:.2f}s processed={int(state.get('processedCount', 0) or 0)}",
            "debug",
        )

    concurrent_threads = max(int(config.get("concurrentThreads", 1) or 1), 1)
    processed_count = int(state.get("processedCount", 0) or 0)
    test_mode = str(config.get("testMode", "duration"))
    duration_seconds = max(int(config.get("durationSeconds", 60) or 60), 1)
    operation_count = max(int(config.get("operationCount", 1000) or 1000), 1)
    duration_complete = test_mode != "operation-count" and active_elapsed >= duration_seconds
    operation_complete = test_mode == "operation-count" and processed_count >= operation_count
    effective_elapsed = min(active_elapsed, float(duration_seconds))
    if duration_complete:
        state["activeElapsedSeconds"] = effective_elapsed
    rate_target = int(effective_elapsed * concurrent_threads * 8)
    if processed_count == 0 and not duration_complete and not operation_complete:
        rate_target = max(rate_target, 1)

    if test_mode == "operation-count":
        remaining = max(operation_count - processed_count, 0)
        target_processed = min(operation_count, rate_target)
    else:
        remaining = 1 << 30
        target_processed = rate_target

    deficit = max(target_processed - processed_count, 0)
    batch_size = min(max(deficit, 0), max(concurrent_threads * 8, 32))
    if (duration_complete or operation_complete):
        batch_size = 0
    if processed_count == 0 and batch_size == 0 and not duration_complete and not operation_complete:
        batch_size = 1
    if test_mode == "operation-count":
        batch_size = min(batch_size, remaining)

    if batch_size > 0:
        profile = _benchmark_profile(dict(state.get("profile") or {}), config)
        client = _build_client(profile)
        try:
            for _ in range(batch_size):
                if test_mode == "operation-count" and int(state.get("processedCount", 0) or 0) >= operation_count:
                    break
                _run_benchmark_operation(state, client)
        except Exception as error:  # noqa: BLE001
            mapped = _map_exception(error)
            state["status"] = "failed"
            state["completedAt"] = _now_iso()
            _append_benchmark_log(state, f"Benchmark failed: {mapped.message}")

    _refresh_benchmark_snapshot(state)

    if state["status"] == "running":
        completed = False
        if test_mode == "operation-count":
            completed = int(state.get("processedCount", 0) or 0) >= operation_count
        else:
            completed = float(state.get("activeElapsedSeconds", 0.0) or 0.0) >= duration_seconds
        if completed:
            state["status"] = "completed"
            state["completedAt"] = _now_iso()
            _append_benchmark_log(
                state,
                f"Benchmark completed after {int(state.get('processedCount', 0) or 0)} request(s).",
            )

    _persist_benchmark_outputs(state)
    _write_benchmark_state(state)
    return state


def _start_benchmark(params: dict[str, Any]) -> dict[str, Any]:
    config = dict(params.get("config") or {})
    profile_payload = dict(params.get("profile") or {})
    if not profile_payload:
        raise SidecarError("invalid_config", "Profile configuration is required for benchmark runs.")
    run_id = f"bench-{uuid.uuid4().hex[:8]}"
    state = {
        "id": run_id,
        "profile": profile_payload,
        "config": config,
        "status": "running",
        "processedCount": 0,
        "startedAt": _now_iso(),
        "completedAt": None,
        "lastUpdatedAt": _now_iso(),
        "activeElapsedSeconds": 0.0,
        "averageLatencyMs": 0,
        "throughputOpsPerSecond": 0,
        "liveLog": ["Benchmark scheduled."],
        "resultSummary": None,
        "history": [],
        "activeObjects": [],
        "nextObjectIndex": 0,
        "nextActiveIndex": 0,
        "nextSizeIndex": 0,
        "benchmarkPrefix": _benchmark_base_prefix(config, run_id),
    }
    _append_benchmark_log(
        state,
        f"Benchmark target bucket: {config.get('bucketName', '')} via {profile_payload.get('endpointUrl', '')}.",
    )
    _write_benchmark_state(state)
    return _materialize_benchmark_state(state)


def _get_benchmark_status(params: dict[str, Any]) -> dict[str, Any]:
    return _materialize_benchmark_state(_read_benchmark_state(str(params.get("runId", "")).strip()))


def _pause_benchmark(params: dict[str, Any]) -> dict[str, Any]:
    state = _read_benchmark_state(str(params.get("runId", "")).strip())
    _refresh_benchmark_snapshot(state)
    state["status"] = "paused"
    _append_benchmark_log(state, "Benchmark paused by user.")
    _write_benchmark_state(state)
    _persist_benchmark_outputs(state)
    return state


def _resume_benchmark(params: dict[str, Any]) -> dict[str, Any]:
    state = _read_benchmark_state(str(params.get("runId", "")).strip())
    state["status"] = "running"
    state["lastUpdatedAt"] = _now_iso()
    _append_benchmark_log(state, "Benchmark resumed by user.")
    _write_benchmark_state(state)
    return _materialize_benchmark_state(state)


def _stop_benchmark(params: dict[str, Any]) -> dict[str, Any]:
    state = _read_benchmark_state(str(params.get("runId", "")).strip())
    _refresh_benchmark_snapshot(state)
    state["status"] = "stopped"
    state["completedAt"] = _now_iso()
    state["resultSummary"] = _rebuild_benchmark_summary(state)
    _append_benchmark_log(state, "Benchmark stopped by user.")
    _write_benchmark_state(state)
    _persist_benchmark_outputs(state)
    return state


def _export_benchmark_results(params: dict[str, Any]) -> dict[str, Any]:
    run_id = str(params.get("runId", "")).strip()
    format_name = str(params.get("format", "csv")).strip().lower()
    state = _materialize_benchmark_state(_read_benchmark_state(run_id))
    config = dict(state.get("config") or {})
    path = str(config.get("csvOutputPath" if format_name == "csv" else "jsonOutputPath", ""))
    return {"format": format_name, "path": path, "summary": state.get("resultSummary")}


def handle_request(payload: dict[str, Any]) -> dict[str, Any]:
    method = payload.get("method")
    params = payload.get("params") or {}

    if method == "health":
        return _health()
    if method == "getCapabilities":
        return _get_capabilities(dict(params))
    if method == "testProfile":
        return _test_profile(dict(params.get("profile") or {}))
    if method == "listBuckets":
        return _list_buckets(dict(params.get("profile") or {}))
    if method == "createBucket":
        return _create_bucket(dict(params))
    if method == "deleteBucket":
        return _delete_bucket(dict(params))
    if method == "setBucketVersioning":
        return _set_bucket_versioning(dict(params))
    if method == "listObjects":
        return _list_objects(dict(params))
    if method == "getBucketAdminState":
        return _get_bucket_admin_state(dict(params))
    if method == "putBucketLifecycle":
        return _put_bucket_lifecycle(dict(params))
    if method == "deleteBucketLifecycle":
        return _delete_bucket_lifecycle(dict(params))
    if method == "putBucketPolicy":
        return _put_bucket_policy(dict(params))
    if method == "deleteBucketPolicy":
        return _delete_bucket_policy(dict(params))
    if method == "putBucketCors":
        return _put_bucket_cors(dict(params))
    if method == "deleteBucketCors":
        return _delete_bucket_cors(dict(params))
    if method == "putBucketEncryption":
        return _put_bucket_encryption(dict(params))
    if method == "deleteBucketEncryption":
        return _delete_bucket_encryption(dict(params))
    if method == "putBucketTagging":
        return _put_bucket_tagging(dict(params))
    if method == "deleteBucketTagging":
        return _delete_bucket_tagging(dict(params))
    if method == "listObjectVersions":
        return _list_object_versions(dict(params))
    if method == "getObjectDetails":
        return _get_object_details(dict(params))
    if method == "createFolder":
        return _create_folder(dict(params))
    if method == "copyObject":
        return _copy_object(dict(params))
    if method == "moveObject":
        return _move_object(dict(params))
    if method == "deleteObjects":
        return _delete_objects(dict(params))
    if method == "deleteObjectVersions":
        return _delete_object_versions(dict(params))
    if method == "startUpload":
        return _start_upload(dict(params))
    if method == "startDownload":
        return _start_download(dict(params))
    if method == "pauseTransfer":
        return _transfer_control(dict(params), "paused")
    if method == "resumeTransfer":
        return _transfer_control(dict(params), "running")
    if method == "cancelTransfer":
        return _transfer_control(dict(params), "cancelled")
    if method == "generatePresignedUrl":
        return _generate_presigned_url(dict(params))
    if method == "runPutTestData":
        return _run_put_testdata(dict(params))
    if method == "runDeleteAll":
        return _run_delete_all(dict(params))
    if method == "cancelToolExecution":
        return _cancel_tool_execution(dict(params))
    if method == "startBenchmark":
        return _start_benchmark(dict(params))
    if method == "getBenchmarkStatus":
        return _get_benchmark_status(dict(params))
    if method == "pauseBenchmark":
        return _pause_benchmark(dict(params))
    if method == "resumeBenchmark":
        return _resume_benchmark(dict(params))
    if method == "stopBenchmark":
        return _stop_benchmark(dict(params))
    if method == "exportBenchmarkResults":
        return _export_benchmark_results(dict(params))

    raise SidecarError(
        "unsupported_feature",
        f"Method {method} is not implemented in the Python engine.",
    )


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        request_id = None
        try:
            payload = json.loads(line)
            request_id = payload.get("requestId")
            result = handle_request(payload)
            response = {
                "requestId": request_id,
                "ok": True,
                "result": result,
            }
        except Exception as error:  # noqa: BLE001
            mapped = _map_exception(error)
            response = {
                "requestId": request_id,
                "ok": False,
                "error": {
                    "code": mapped.code,
                    "message": mapped.message,
                    "details": mapped.details,
                },
            }

        print(json.dumps(response), flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
