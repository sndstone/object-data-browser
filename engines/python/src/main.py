#!/usr/bin/env python3
"""Python desktop sidecar for real S3 profile testing and listing."""

from __future__ import annotations

import base64
import csv
import hashlib
import importlib.util
import hmac
import io
import json
import os
import re
from contextlib import contextmanager
import socket
import ssl
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from types import SimpleNamespace
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed, wait, FIRST_COMPLETED
from collections import OrderedDict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import formatdate, parsedate_to_datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse, parse_qsl


ENGINE_VERSION = "2.3.1"

# Serialize every write to stdout so transferProgress events emitted from worker
# threads never interleave with request/response lines.
_STDOUT_LOCK = threading.Lock()
_STDERR_LOCK = threading.Lock()


def _write_stdout_line(text: str) -> None:
    with _STDOUT_LOCK:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()


class _TransferCancelled(Exception):
    """Raised inside a transfer loop when the job has been cancelled."""

    def __init__(self, job_id: str):
        super().__init__(f"Transfer {job_id} cancelled.")
        self.job_id = job_id


class TransferControl:
    """Thread-safe live state for an in-flight transfer job."""

    def __init__(
        self,
        *,
        job_id: str,
        label: str,
        direction: str,
        total_bytes: int,
        item_count: int,
        strategy_label: str | None,
        part_size_bytes: int | None,
        parts_total: int | None,
    ) -> None:
        self.job_id = job_id
        self.label = label
        self.direction = direction
        self.total_bytes = total_bytes
        self.item_count = item_count
        self.strategy_label = strategy_label
        self.part_size_bytes = part_size_bytes
        self.parts_total = parts_total
        self.status = "running"
        self.bytes_transferred = 0
        self.items_completed = 0
        self.parts_completed = 0
        self.current_item_label: str | None = None
        self.lock = threading.Lock()
        # Set == running/allowed to proceed; cleared == paused.
        self.resume_event = threading.Event()
        self.resume_event.set()


_TRANSFER_REGISTRY: dict[str, TransferControl] = {}
_TRANSFER_REGISTRY_LOCK = threading.Lock()
# Tracks the job id registered by the transfer running on the current worker
# thread so the dispatch wrapper can clean up regardless of how it exits.
_CURRENT_TRANSFER = threading.local()


def _register_transfer(control: TransferControl) -> TransferControl:
    with _TRANSFER_REGISTRY_LOCK:
        _TRANSFER_REGISTRY[control.job_id] = control
    _CURRENT_TRANSFER.job_id = control.job_id
    return control


def _unregister_transfer(job_id: str) -> None:
    with _TRANSFER_REGISTRY_LOCK:
        _TRANSFER_REGISTRY.pop(job_id, None)


def _lookup_transfer(job_id: str) -> TransferControl | None:
    with _TRANSFER_REGISTRY_LOCK:
        return _TRANSFER_REGISTRY.get(job_id)


def _control_update(control: TransferControl | None, **fields: Any) -> None:
    if control is None:
        return
    with control.lock:
        for name, value in fields.items():
            setattr(control, name, value)


def _transfer_gate(control: TransferControl | None) -> None:
    """Block while the job is paused; raise _TransferCancelled if cancelled."""
    if control is None:
        return
    while True:
        with control.lock:
            status = control.status
        if status == "cancelled":
            raise _TransferCancelled(control.job_id)
        if status != "paused":
            return
        # Wait to be resumed or cancelled; re-check on a short timeout so a
        # cancel that arrives while paused is observed promptly.
        control.resume_event.wait(timeout=0.5)


def _transfer_checkpoint(
    control: TransferControl | None,
    *,
    bytes_transferred: int,
    items_completed: int,
    parts_completed: int,
    current_item_label: str | None,
) -> None:
    """Publish live progress into the registry, then honor pause/cancel."""
    _control_update(
        control,
        bytes_transferred=bytes_transferred,
        items_completed=items_completed,
        parts_completed=parts_completed,
        current_item_label=current_item_label,
    )
    _transfer_gate(control)


def _cancelled_job_from_control(job_id: str) -> dict[str, Any]:
    control = _lookup_transfer(job_id)
    if control is None:
        return _build_transfer_job(
            job_id=job_id,
            label=f"Transfer {job_id}",
            direction="transfer",
            progress=0.0,
            status="cancelled",
            bytes_transferred=0,
            total_bytes=0,
            output_lines=["Transfer cancelled."],
        )
    with control.lock:
        total = control.total_bytes
        transferred = control.bytes_transferred
        progress = (transferred / total) if total else 0.0
        return _build_transfer_job(
            job_id=control.job_id,
            label=control.label,
            direction=control.direction,
            progress=progress,
            status="cancelled",
            bytes_transferred=transferred,
            total_bytes=total,
            output_lines=[f"Transfer {control.job_id} cancelled."],
            strategy_label=control.strategy_label,
            current_item_label=control.current_item_label,
            item_count=control.item_count,
            items_completed=control.items_completed,
            part_size_bytes=control.part_size_bytes,
            parts_completed=(
                control.parts_completed if control.part_size_bytes is not None else None
            ),
            parts_total=(
                control.parts_total if control.part_size_bytes is not None else None
            ),
        )


def _run_transfer(fn: Any, params: dict[str, Any]) -> dict[str, Any]:
    """Dispatch wrapper that converts a mid-flight cancel into a cancelled job
    and always removes the job from the registry when the transfer ends."""
    _CURRENT_TRANSFER.job_id = None
    try:
        return fn(params)
    except _TransferCancelled as cancelled:
        return _cancelled_job_from_control(cancelled.job_id)
    finally:
        job_id = getattr(_CURRENT_TRANSFER, "job_id", None)
        if job_id:
            _unregister_transfer(job_id)
        _CURRENT_TRANSFER.job_id = None


def _run_tool(fn, params):
    finished = threading.Event()
    def heartbeat():
        while not finished.wait(5):
            _write_stdout_line(json.dumps({'event': 'toolProgress', 'status': 'running'}))
    threading.Thread(target=heartbeat, daemon=True).start()
    try:
        return fn(params)
    finally:
        finished.set()


class SidecarError(Exception):
    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


@dataclass(frozen=True)
class Profile:
    endpoint_url: str
    endpoint_type: str
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
    auth_mode: str = "static"
    aws_profile_name: str = ""
    role_arn: str = ""
    external_id: str = ""
    role_session_name: str = "object-browser"
    known_bucket: str = ""
    requester_pays: bool = False
    expected_bucket_owner: str = ""
    ca_bundle_path: str = ""
    azure_sas_token: str = ""


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
    endpoint_type = str(payload.get("endpointType", "")).strip() or "s3Compatible"
    access_key = str(payload.get("accessKey", "")).strip()
    secret_key = str(payload.get("secretKey", "")).strip()
    region = str(payload.get("region", "")).strip() or "us-east-1"

    auth_mode = str(payload.get("authMode") or "static")
    if auth_mode not in {"static", "awsProfile", "awsDefault", "assumeRole", "azureSas", "azureDefault"}:
        raise SidecarError("invalid_config", "Unknown authentication mode.")
    if auth_mode == 'awsProfile' and not str(payload.get('awsProfileName') or '').strip():
        raise SidecarError('invalid_config', 'Select a named AWS profile for this authentication mode.')
    if not endpoint_url and endpoint_type not in {"azureBlob", "awsS3"} and auth_mode == "static":
        raise SidecarError("invalid_config", "Endpoint URL is required.")
    if auth_mode == "static" and (not access_key or not secret_key):
        raise SidecarError("invalid_config", "Access key and secret key are required.")

    return Profile(
        endpoint_url=endpoint_url,
        endpoint_type=endpoint_type,
        region=region,
        access_key=access_key,
        secret_key=secret_key,
        session_token=str(payload.get("sessionToken") or "").strip() or None,
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
        auth_mode=auth_mode,
        aws_profile_name=str(payload.get("awsProfileName") or ""),
        role_arn=str(payload.get("roleArn") or ""),
        external_id=str(payload.get("externalId") or ""),
        role_session_name=str(payload.get("roleSessionName") or "object-browser"),
        known_bucket=str(payload.get("knownBucket") or ""),
        requester_pays=bool(payload.get("requesterPays", False)),
        expected_bucket_owner=str(payload.get("expectedBucketOwner") or ""),
        ca_bundle_path=str(payload.get("caBundlePath") or ""),
        azure_sas_token=str(payload.get("azureSasToken") or (payload.get("sessionToken") if auth_mode == "azureSas" else "") or "").lstrip("?"),
    )


_CLIENT_CACHE: OrderedDict[Profile, Any] = OrderedDict()
_CLIENT_CACHE_LOCK = threading.RLock()


def _build_client(profile: Profile):
    with _CLIENT_CACHE_LOCK:
        cached = _CLIENT_CACHE.get(profile)
        if cached is not None:
            _CLIENT_CACHE.move_to_end(profile)
            return cached
        client = _new_client(profile)
        _CLIENT_CACHE[profile] = client
        # Eviction removes credentials from our cache; do not close a client
        # which may still be serving another transfer.
        while len(_CLIENT_CACHE) > 16:
            _CLIENT_CACHE.popitem(last=False)
        return client


def _new_client(profile: Profile):
    imports = _lazy_boto_imports()
    config = imports["Config"](
        region_name=profile.region,
        connect_timeout=profile.connect_timeout_seconds,
        read_timeout=profile.read_timeout_seconds,
        retries={"total_max_attempts": profile.max_attempts, "mode": "adaptive"},
        max_pool_connections=profile.max_pool_connections,
        s3={"addressing_style": "path" if profile.path_style else "virtual"},
    )
    session = imports["boto3"].session.Session(
        profile_name=profile.aws_profile_name or None,
        region_name=profile.region,
    )
    if profile.auth_mode == "assumeRole":
        if not profile.role_arn:
            raise SidecarError("invalid_config", "An IAM role ARN is required.")
        from botocore.credentials import DeferredRefreshableCredentials, AssumeRoleCredentialFetcher
        from botocore.session import get_session
        source = session.get_credentials()
        if profile.access_key and profile.secret_key:
            from botocore.credentials import Credentials
            source = Credentials(profile.access_key, profile.secret_key, profile.session_token)
        extra = {"RoleSessionName": profile.role_session_name}
        if profile.external_id:
            extra["ExternalId"] = profile.external_id
        fetcher = AssumeRoleCredentialFetcher(
            client_creator=session._session.create_client,
            source_credentials=source, role_arn=profile.role_arn, extra_args=extra,
        )
        core = get_session()
        core._credentials = DeferredRefreshableCredentials(
            refresh_using=fetcher.fetch_credentials, method="assume-role",
        )
        session = imports["boto3"].session.Session(botocore_session=core)

    client_kwargs: dict[str, Any] = {
        "endpoint_url": profile.endpoint_url or None,
        "region_name": profile.region,
        "verify": profile.ca_bundle_path or profile.verify_tls,
        "config": config,
    }
    if profile.auth_mode == "static":
        client_kwargs["aws_access_key_id"] = profile.access_key
        client_kwargs["aws_secret_access_key"] = profile.secret_key
    if profile.session_token and profile.auth_mode == "static":
        client_kwargs["aws_session_token"] = profile.session_token
    if not profile.verify_tls:
        _emit_structured_log(
            "WARN",
            "tls",
            f"TLS certificate verification is disabled for endpoint {profile.endpoint_url}.",
            "python-engine",
        )
    client = session.client("s3", **client_kwargs)
    def request_context(params, model, **kwargs):
        members = model.input_shape.members if model.input_shape else {}
        if profile.requester_pays and "RequestPayer" in members:
            params.setdefault("RequestPayer", "requester")
        if profile.expected_bucket_owner and "ExpectedBucketOwner" in members:
            params.setdefault("ExpectedBucketOwner", profile.expected_bucket_owner)
    client.meta.events.register("before-parameter-build.s3", request_context)
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
    return json.dumps(value, indent=2, sort_keys=True, default=_serialize_dt)


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
    with _STDERR_LOCK:
        print(f"S3_BROWSER_LOG {payload}", file=sys.stderr, flush=True)


def _sanitize_headers(headers: Any) -> dict[str, str]:
    sanitized: dict[str, str] = {}
    for key, value in dict(headers or {}).items():
        lower = str(key).lower()
        if any(token in lower for token in ("authorization", "security-token", "access-key", "secret", "token")) or (lower in {'x-ms-copy-source', 'x-ms-rename-source'} and '?' in str(value)):
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
        state = ("denied" if code in {"AccessDenied", "Forbidden", "Unauthorized"}
                 else "unsupported" if code in {"MethodNotAllowed", "NotImplemented", "XNotImplemented"}
                 else "missing" if code.startswith("NoSuch") or "NotFound" in code
                 else "error")
        if api_calls:
            api_calls[-1].update({"state": state, "errorCode": code, "message": str(error)})
        if state == "denied":
            return default
        if state in {"missing", "unsupported"} and code != "NoSuchBucket":
            return default
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

    if isinstance(error, json.JSONDecodeError):
        return SidecarError(
            "invalid_request",
            "Malformed JSON request.",
            {"message": str(error)},
        )

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


# ---------------------------------------------------------------------------
# Azure Blob Storage support (Shared Key auth, Python standard library only)
# ---------------------------------------------------------------------------

_AZURE_API_VERSION = "2021-12-02"
_AZURE_PUT_BLOB_LIMIT = 64 * 1024 * 1024

_AZURE_UNSUPPORTED_METHODS = {
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
    "listObjectVersions",
    "deleteObjectVersions",
    "generatePresignedUrl",
}


def _is_azure_profile(profile_payload: Any) -> bool:
    if not isinstance(profile_payload, dict):
        return False
    return str(profile_payload.get("endpointType", "")).strip() == "azureBlob"


def _azure_parse_rfc1123(value: Any) -> datetime:
    try:
        parsed = parsedate_to_datetime(str(value))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed
    except (TypeError, ValueError):
        return datetime.now(tz=timezone.utc)


class _AzureBlobClient:
    """Minimal Azure Blob service client implementing Shared Key signing."""

    def __init__(self, profile: Profile):
        self.profile = profile
        self.account = profile.access_key or (urlparse(profile.endpoint_url).hostname or "").split(".")[0]
        self.credential = None
        if profile.auth_mode == "azureDefault":
            try:
                from azure.identity import DefaultAzureCredential
                self.credential = DefaultAzureCredential()
            except ImportError as error:
                raise SidecarError("unsupported_feature", "Azure Default credentials require azure-identity in the engine runtime.") from error
        try:
            self.key = base64.b64decode(profile.secret_key) if profile.auth_mode == 'static' else b''
        except (ValueError, TypeError) as error:
            raise SidecarError(
                "invalid_config",
                "Azure account access key must be valid base64.",
            ) from error
        if not self.key and profile.auth_mode not in {"azureSas", "azureDefault"}:
            raise SidecarError("invalid_config", "Azure account access key must not be empty.")
        if profile.auth_mode == "azureSas" and not profile.azure_sas_token:
            raise SidecarError("invalid_config", "An Azure SAS token is required.")

        base = profile.endpoint_url.strip().rstrip("/")
        if not base:
            base = f"https://{self.account}.blob.core.windows.net"
        parsed = urlparse(base)
        if not parsed.scheme or not parsed.netloc:
            raise SidecarError("invalid_config", f"Invalid Azure Blob endpoint URL: {base}")
        self.scheme = parsed.scheme
        self.netloc = parsed.netloc
        # Azurite-style endpoints embed "/{account}" in the URL path.
        self.base_path = parsed.path.rstrip("/")
        self.base_url = f"{self.scheme}://{self.netloc}{self.base_path}"
        self.timeout = max(profile.connect_timeout_seconds, profile.read_timeout_seconds)
        self.context: ssl.SSLContext | None = None
        if self.scheme == "https":
            context = ssl.create_default_context(cafile=profile.ca_bundle_path or None)
            if not profile.verify_tls:
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
                _emit_structured_log(
                    "WARN",
                    "tls",
                    f"TLS certificate verification is disabled for endpoint {self.base_url}.",
                    "python-engine",
                )
            self.context = context
        import urllib3
        self.pool = urllib3.PoolManager(
            num_pools=4, maxsize=profile.max_pool_connections, block=True,
            ssl_context=self.context, cert_reqs="CERT_REQUIRED" if profile.verify_tls else "CERT_NONE",
        )

    def blob_path(self, container: str, key: str | None = None) -> str:
        path = f"/{quote(container, safe='')}"
        if key is not None:
            path += f"/{quote(key, safe='/')}"
        return path

    def _string_to_sign(
        self,
        method: str,
        full_path: str,
        query: dict[str, str],
        headers: dict[str, str],
    ) -> str:
        def header(name: str) -> str:
            return str(headers.get(name, "") or "")

        content_length = header("Content-Length")
        if content_length == "0":
            content_length = ""

        canonical_headers = "".join(
            f"{name}:{value}\n"
            for name, value in sorted(
                (str(name).lower(), str(value).strip())
                for name, value in headers.items()
                if str(name).lower().startswith("x-ms-")
            )
        )
        canonical_resource = f"/{self.account}{full_path}"
        for name in sorted(query, key=lambda item: str(item).lower()):
            canonical_resource += f"\n{str(name).lower()}:{query[name]}"

        return (
            "\n".join(
                [
                    method.upper(),
                    header("Content-Encoding"),
                    header("Content-Language"),
                    content_length,
                    header("Content-MD5"),
                    header("Content-Type"),
                    "",  # Date is left empty because x-ms-date is always set.
                    header("If-Modified-Since"),
                    header("If-Match"),
                    header("If-None-Match"),
                    header("If-Unmodified-Since"),
                    header("Range"),
                ]
            )
            + "\n"
            + canonical_headers
            + canonical_resource
        )

    def _map_http_error(self, error: urllib.error.HTTPError) -> SidecarError:
        status = int(getattr(error, "code", 0) or 0)
        try:
            body = error.read()
        except Exception:  # noqa: BLE001
            body = b""
        code = str(error.headers.get("x-ms-error-code", "") or "") if error.headers else ""
        message = ""
        if body:
            try:
                root = ET.fromstring(body.decode("utf-8", errors="replace"))
                code = code or str(root.findtext("Code") or "")
                raw_message = str(root.findtext("Message") or "")
                message = raw_message.splitlines()[0] if raw_message else ""
            except ET.ParseError:
                pass
        if not message:
            if status == 404:
                message = "The specified resource does not exist."
            else:
                message = f"Azure Blob request failed with HTTP {status} ({code or 'Unknown'})."
        details = {"azureCode": code or "Unknown", "httpStatus": status}
        if status in {401, 403} or code in {
            "AuthenticationFailed",
            "AuthorizationFailure",
            "InvalidAuthenticationInfo",
            "InsufficientAccountPermissions",
        }:
            return SidecarError("auth_failed", message, details)
        if status == 503 or code == "ServerBusy":
            return SidecarError("throttled", message, details)
        if code == "OperationTimedOut":
            return SidecarError("timeout", message, details)
        return SidecarError("unknown", message, details)

    def open(
        self,
        method: str,
        path: str = "",
        query: dict[str, Any] | None = None,
        headers: dict[str, Any] | None = None,
        body: bytes | None = None,
    ):
        """Issue a signed request and return the open HTTP response."""
        query_params = {str(name): str(value) for name, value in dict(query or {}).items()}
        request_headers: dict[str, str] = {
            "x-ms-version": _AZURE_API_VERSION,
            "x-ms-date": formatdate(usegmt=True),
        }
        for name, value in dict(headers or {}).items():
            request_headers[str(name)] = str(value)
        if body is not None:
            request_headers["Content-Length"] = str(len(body))
            # urllib injects "application/x-www-form-urlencoded" when a body is
            # present and no Content-Type is set, which would break the
            # signature; pin an explicit value so the signed header matches.
            if not any(str(name).lower() == "content-type" for name in request_headers):
                request_headers["Content-Type"] = "application/octet-stream"

        full_path = f"{self.base_path}{path}" or "/"
        if self.profile.auth_mode == "azureSas":
            query_params.update(dict(parse_qsl(self.profile.azure_sas_token, keep_blank_values=True)))
        elif self.credential is not None:
            request_headers["Authorization"] = f"Bearer {self.credential.get_token('https://storage.azure.com/.default').token}"
        else:
            string_to_sign = self._string_to_sign(method, full_path, query_params, request_headers)
            signature = base64.b64encode(
                hmac.new(self.key, string_to_sign.encode("utf-8"), hashlib.sha256).digest()
            ).decode("ascii")
            request_headers["Authorization"] = f"SharedKey {self.account}:{signature}"

        url = f"{self.scheme}://{self.netloc}{full_path}"
        if query_params:
            url += "?" + "&".join(
                f"{quote(name, safe='')}={quote(value, safe='')}"
                for name, value in sorted(query_params.items())
            )

        if self.profile.enable_api_logging:
            _emit_structured_log(
                "API",
                "HttpSend",
                f"SEND {method.upper()} {url.split('?')[0]} HEADERS={json.dumps(_sanitize_headers(request_headers), sort_keys=True)} BODY=[{len(body or b'')} byte(s)]",
                "api",
            )

        try:
            import urllib3
            safe_retry = method.upper() in {"GET", "HEAD"} or (method.upper() == "PUT" and (query or {}).get("comp") == "block")
            retry = urllib3.Retry(
                total=max(0, self.profile.max_attempts - 1) if safe_retry else 0,
                allowed_methods={method.upper()} if safe_retry else set(),
                status_forcelist={429, 500, 502, 503, 504}, backoff_factor=0.2,
                raise_on_status=False,
            )
            response = self.pool.request(method.upper(), url, body=body, headers=request_headers,
                timeout=urllib3.Timeout(connect=self.profile.connect_timeout_seconds, read=self.profile.read_timeout_seconds),
                pool_timeout=self.profile.read_timeout_seconds, retries=retry, preload_content=False, redirect=False)
            if response.status >= 400:
                data = response.read()
                response.close()
                raise urllib.error.HTTPError(url.split('?')[0], response.status, "Azure request failed", response.headers, io.BytesIO(data))
        except urllib.error.HTTPError as error:
            mapped = self._map_http_error(error)
            if self.profile.enable_api_logging:
                _emit_structured_log(
                    "API",
                    "HttpReceive",
                    f"RECV {method.upper()} {url.split('?')[0]} STATUS={mapped.details.get('httpStatus')} CODE={mapped.details.get('azureCode')}",
                    "api",
                )
            raise mapped from error
        except (socket.timeout, TimeoutError) as error:
            raise SidecarError("timeout", str(error)) from error
        except ssl.SSLError as error:
            raise SidecarError("tls_error", str(error)) from error
        except urllib.error.URLError as error:
            reason = getattr(error, "reason", error)
            if isinstance(reason, ssl.SSLError):
                raise SidecarError("tls_error", str(reason)) from error
            if isinstance(reason, (socket.timeout, TimeoutError)):
                raise SidecarError("timeout", str(reason)) from error
            raise SidecarError("engine_unavailable", str(reason)) from error
        except (ConnectionError, OSError) as error:
            raise SidecarError("engine_unavailable", "Azure transport failed.") from error
        except urllib3.exceptions.HTTPError as error:
            raise SidecarError("engine_unavailable", "Azure transport failed; check connectivity and TLS settings.") from error

        if self.profile.enable_api_logging:
            _emit_structured_log(
                "API",
                "HttpReceive",
                f"RECV {method.upper()} {url.split('?')[0]} STATUS={response.status}",
                "api",
            )
        return response

    def request(
        self,
        method: str,
        path: str = "",
        query: dict[str, Any] | None = None,
        headers: dict[str, Any] | None = None,
        body: bytes | None = None,
    ) -> tuple[int, Any, bytes]:
        response = self.open(method, path, query=query, headers=headers, body=body)
        with response:
            data = response.read()
            return int(response.status), response.headers, data


_AZURE_CLIENT_CACHE = OrderedDict()


def _build_azure_client(profile):
    with _CLIENT_CACHE_LOCK:
        client = _AZURE_CLIENT_CACHE.get(profile)
        if client is None:
            client = _AzureBlobClient(profile)
            _AZURE_CLIENT_CACHE[profile] = client
            while len(_AZURE_CLIENT_CACHE) > 16:
                _AZURE_CLIENT_CACHE.popitem(last=False)
        else:
            _AZURE_CLIENT_CACHE.move_to_end(profile)
        return client


def _azure_block_size(size):
    if size > 50000 * 4000 * 1024**2:
        raise SidecarError("invalid_config", "Blob exceeds Azure's 50,000-block limit.")
    return max(8 * 1024**2, min(128 * 1024**2, (size + 127) // 128), (size + 49999) // 50000)


def _azure_parse_xml(body: bytes) -> ET.Element:
    try:
        return ET.fromstring(body)
    except ET.ParseError as error:
        raise SidecarError(
            "unknown",
            f"Azure Blob service returned an unparseable XML response: {error}",
        ) from error


def _azure_list_containers_page(
    client: _AzureBlobClient,
    marker: str | None = None,
    maxresults: int | None = None,
) -> tuple[list[dict[str, str]], str]:
    query: dict[str, Any] = {"comp": "list"}
    if marker:
        query["marker"] = marker
    if maxresults:
        query["maxresults"] = str(maxresults)
    _, _, body = client.request("GET", "", query=query)
    root = _azure_parse_xml(body)
    containers: list[dict[str, str]] = []
    for node in root.iterfind("Containers/Container"):
        name = str(node.findtext("Name") or "")
        if not name:
            continue
        containers.append(
            {
                "name": name,
                "lastModified": str(node.findtext("Properties/Last-Modified") or ""),
            }
        )
    next_marker = str(root.findtext("NextMarker") or "").strip()
    return containers, next_marker


def _azure_test_profile(profile_payload: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(profile_payload)
    client = _build_azure_client(profile)
    if profile.known_bucket:
        client.request('HEAD', client.blob_path(profile.known_bucket), query={'restype': 'container'})
        containers = [{'name': profile.known_bucket}]
    else:
        containers, _ = _azure_list_containers_page(client, maxresults=1)
    return {
        "ok": True,
        "bucketCount": len(containers),
        "endpoint": client.netloc,
    }


def _azure_list_buckets(profile_payload: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(profile_payload)
    client = _build_azure_client(profile)
    if profile.known_bucket:
        return {'items': [{'name': profile.known_bucket, 'region': profile.region, 'objectCountHint': 0,
                           'versioningEnabled': False, 'createdAt': _serialize_dt(None)}]}
    buckets: list[dict[str, Any]] = []
    marker: str | None = None
    while True:
        containers, marker = _azure_list_containers_page(client, marker=marker)
        for container in containers:
            buckets.append(
                {
                    "name": container["name"],
                    "region": profile.region,
                    "objectCountHint": 0,
                    "versioningEnabled": False,
                    "createdAt": _serialize_dt(_azure_parse_rfc1123(container["lastModified"])),
                }
            )
        if not marker:
            break
    return {"items": buckets}


def _azure_create_bucket(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_azure_client(profile)
    client.request("PUT", client.blob_path(bucket_name), query={"restype": "container"}, body=b"")
    return {
        "name": bucket_name,
        "region": profile.region,
        "objectCountHint": 0,
        "versioningEnabled": False,
        "createdAt": _serialize_dt(datetime.now(tz=timezone.utc)),
    }


def _azure_delete_bucket(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_azure_client(profile)
    client.request("DELETE", client.blob_path(bucket_name), query={"restype": "container"})
    return {"deleted": True, "bucketName": bucket_name}


def _azure_list_blobs_page(
    client: _AzureBlobClient,
    bucket_name: str,
    *,
    prefix: str = "",
    delimiter: str | None = None,
    marker: str | None = None,
    maxresults: int = 1000,
) -> tuple[ET.Element, str]:
    query: dict[str, Any] = {
        "restype": "container",
        "comp": "list",
        "maxresults": str(maxresults),
    }
    if prefix:
        query["prefix"] = prefix
    if delimiter:
        query["delimiter"] = delimiter
    if marker:
        query["marker"] = marker
    _, _, body = client.request("GET", client.blob_path(bucket_name), query=query)
    root = _azure_parse_xml(body)
    next_marker = str(root.findtext("NextMarker") or "").strip()
    return root, next_marker


def _azure_list_objects(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required for object listing.")

    prefix = str(params.get("prefix", "") or "")
    flat = bool(params.get("flat", False))
    cursor = params.get("cursor") or {}
    continuation_token = cursor.get("value") if isinstance(cursor, dict) else None

    client = _build_azure_client(profile)
    root, next_marker = _azure_list_blobs_page(
        client,
        bucket_name,
        prefix=prefix,
        delimiter=None if flat else "/",
        marker=str(continuation_token) if continuation_token else None,
    )
    if next_marker and next_marker == continuation_token:
        raise SidecarError('invalid_response', 'Azure returned a repeated listing continuation marker.')

    items: list[dict[str, Any]] = []
    for node in root.iterfind("Blobs/BlobPrefix"):
        folder_prefix = str(node.findtext("Name") or "")
        if not folder_prefix:
            continue
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

    for node in root.iterfind("Blobs/Blob"):
        key = str(node.findtext("Name") or "")
        if not key:
            continue
        if not flat and key == prefix:
            continue
        name = key[len(prefix) :] if prefix and key.startswith(prefix) else key
        if not name:
            name = key
        items.append(
            {
                "key": key,
                "name": name,
                "size": int(node.findtext("Properties/Content-Length") or 0),
                "storageClass": str(node.findtext("Properties/AccessTier") or "STANDARD"),
                "modifiedAt": _serialize_dt(
                    _azure_parse_rfc1123(node.findtext("Properties/Last-Modified") or "")
                ),
                "isFolder": False,
                "etag": str(node.findtext("Properties/Etag") or "").strip('"') or None,
                "metadataCount": 0,
            }
        )

    items.sort(key=lambda item: (not bool(item["isFolder"]), str(item["key"]).lower()))
    return {
        "items": items,
        "nextCursor": {
            "value": next_marker or None,
            "hasMore": bool(next_marker),
        },
    }


def _azure_get_bucket_admin_state(params: dict[str, Any]) -> dict[str, Any]:
    bucket_name = str(params.get("bucketName", "")).strip()
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required for bucket admin inspection.")
    # Azure Blob containers do not expose S3-style bucket administration, so a
    # benign disabled state is returned for routine UI polling.
    return {
        "bucketName": bucket_name,
        "versioningEnabled": False,
        "versioningStatus": "Suspended",
        "objectLockEnabled": False,
        "lifecycleEnabled": False,
        "policyAttached": False,
        "corsEnabled": False,
        "encryptionEnabled": False,
        "encryptionSummary": "Not configured",
        "objectLockMode": None,
        "objectLockRetentionDays": None,
        "tags": {},
        "lifecycleRules": [],
        "lifecycleJson": _json_dumps({"Rules": []}),
        "policyJson": "{}",
        "corsJson": _json_dumps([]),
        "encryptionJson": _json_dumps({}),
        "apiCalls": [],
    }


def _azure_get_object_details(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    key = str(params.get("key", ""))
    if not bucket_name or not key:
        raise SidecarError("invalid_config", "Bucket name and object key are required for object inspection.")

    client = _build_azure_client(profile)
    api_calls: list[dict[str, Any]] = []
    debug_events: list[dict[str, Any]] = []

    debug_events.append(
        {
            "timestamp": _serialize_dt(datetime.now(tz=timezone.utc)),
            "level": "DEBUG",
            "message": f"Fetching object diagnostics for {bucket_name}/{key}.",
        }
    )

    _, head_headers, _ = _call_api(
        api_calls,
        "HeadBlob",
        lambda: client.request("HEAD", client.blob_path(bucket_name, key), query={"versionid": str(params["versionId"])} if params.get("versionId") is not None else {}),
    )

    metadata = {
        str(name)[len("x-ms-meta-") :]: str(value)
        for name, value in head_headers.items()
        if str(name).lower().startswith("x-ms-meta-")
    }
    last_modified = head_headers.get("Last-Modified", "")
    headers = {
        "ETag": str(head_headers.get("ETag", "")).strip('"'),
        "Content-Length": str(head_headers.get("Content-Length", "")),
        "Content-Type": str(head_headers.get("Content-Type", "")),
        "Last-Modified": _serialize_dt(_azure_parse_rfc1123(last_modified)) if last_modified else "",
        "Storage-Class": str(head_headers.get("x-ms-access-tier", "") or "STANDARD"),
        "Cache-Control": str(head_headers.get("Cache-Control", "")),
        "Content-Disposition": str(head_headers.get("Content-Disposition", "")),
        "Content-Encoding": str(head_headers.get("Content-Encoding", "")),
        "Content-Language": str(head_headers.get("Content-Language", "")),
        "Expires": str(head_headers.get("Expires", "")),
    }
    headers = {name: value for name, value in headers.items() if value}

    debug_events.append(
        {
            "timestamp": _serialize_dt(datetime.now(tz=timezone.utc)),
            "level": "INFO",
            "message": f"Loaded metadata and 0 tag(s) for {key}.",
        }
    )

    return {
        "key": key,
        "etag": str(head_headers.get("ETag", "")).strip('"'),
        "versionId": head_headers.get('x-ms-version-id') or params.get('versionId'),
        "storageClass": head_headers.get('x-ms-access-tier'),
        "leaseStatus": head_headers.get('x-ms-lease-status'),
        "leaseState": head_headers.get('x-ms-lease-state'),
        "archiveStatus": head_headers.get('x-ms-archive-status'),
        "encryption": {'serverEncrypted': head_headers.get('x-ms-server-encrypted') == 'true', 'scope': head_headers.get('x-ms-encryption-scope')},
        "metadata": metadata,
        "headers": headers,
        "tags": {},
        "debugEvents": debug_events,
        "apiCalls": api_calls,
        "debugLogExcerpt": [
            f"Resolved endpoint {client.base_url}.",
            f"Completed HEAD diagnostics for {bucket_name}/{key}.",
        ],
        "rawDiagnostics": {
            "bucketName": bucket_name,
            "engineState": "healthy",
        },
    }


def _azure_create_folder(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    key = str(params.get("key", "")).strip()
    if not bucket_name or not key:
        raise SidecarError("invalid_config", "Bucket name and key are required to create a folder.")
    if not key.endswith("/"):
        key = f"{key}/"
    client = _build_azure_client(profile)
    client.request(
        "PUT",
        client.blob_path(bucket_name, key),
        headers={"x-ms-blob-type": "BlockBlob", "Content-Type": "application/octet-stream"},
        body=b"",
    )
    return {"created": True, "key": key}


def _azure_wait_for_copy(client: _AzureBlobClient, dest_path: str, copy_status: str, copy_id: str) -> None:
    if not copy_id:
        raise SidecarError("unknown", "Azure copy identity missing; source retained.")
    attempts = 0
    while copy_status == "pending" and attempts < 20:
        time.sleep(0.25)
        response = client.open("HEAD", dest_path)
        with response:
            response.read()
            if response.headers.get("x-ms-copy-id", "") != copy_id:
                raise SidecarError("object_conflict", "Azure copy identity changed; source retained.")
            copy_status = str(response.headers.get("x-ms-copy-status", "")).lower()
        attempts += 1
    if copy_status != "success":
        raise SidecarError(
            "timeout" if copy_status == "pending" else "unknown",
            f"Azure copy not confirmed ({copy_status or 'missing status'}); source retained. Inspect destination before retrying.",
        )


def _azure_copy_object(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    src_bucket = str(params.get("sourceBucketName", "")).strip()
    src_key = str(params.get("sourceKey", "")).strip()
    dest_bucket = str(params.get("destinationBucketName", "")).strip()
    dest_key = str(params.get("destinationKey", "")).strip()
    if not src_bucket or not src_key or not dest_bucket or not dest_key:
        raise SidecarError("invalid_config", "Copy source and destination are required.")
    client = _build_azure_client(profile)
    source_url = f"{client.scheme}://{client.netloc}{client.base_path}{client.blob_path(src_bucket, src_key)}"
    dest_path = client.blob_path(dest_bucket, dest_key)
    _, headers, _ = client.request(
        "PUT",
        dest_path,
        headers={"x-ms-copy-source": source_url},
        body=b"",
    )
    copy_status = str(headers.get("x-ms-copy-status", "")).lower()
    _azure_wait_for_copy(client, dest_path, copy_status, str(headers.get("x-ms-copy-id", "")))
    return {"successCount": 1, "failureCount": 0, "failures": []}


def _azure_move_object(params: dict[str, Any]) -> dict[str, Any]:
    if (str(params.get("sourceBucketName", "")).strip(), str(params.get("sourceKey", "")).strip()) == (str(params.get("destinationBucketName", "")).strip(), str(params.get("destinationKey", "")).strip()):
        raise SidecarError("invalid_config", "Move source and destination must differ.")
    result = _azure_copy_object(params)
    profile = _parse_profile(params.get("profile", {}))
    client = _build_azure_client(profile)
    client.request(
        "DELETE",
        client.blob_path(
            str(params.get("sourceBucketName", "")).strip(),
            str(params.get("sourceKey", "")).strip(),
        ),
    )
    return result


def _azure_delete_blob(client: _AzureBlobClient, bucket_name: str, key: str) -> None:
    """Delete one blob; missing blobs are treated as already deleted."""
    try:
        client.request("DELETE", client.blob_path(bucket_name, key))
    except SidecarError as error:
        if int(error.details.get("httpStatus", 0) or 0) == 404:
            return
        raise


def _azure_delete_objects(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    keys = [str(item) for item in params.get("keys", []) if str(item).strip()]
    if not bucket_name or not keys:
        raise SidecarError("invalid_config", "Bucket name and keys are required.")
    client = _build_azure_client(profile)
    success_count = 0
    failures: list[dict[str, Any]] = []
    max_workers = max(1, min(profile.max_pool_connections, 16))
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(_azure_delete_blob, client, bucket_name, key): key for key in keys}
        for future in as_completed(futures):
            key = futures[future]
            try:
                future.result()
                success_count += 1
            except SidecarError as error:
                failures.append(
                    {
                        "target": key,
                        "code": str(error.details.get("azureCode", error.code)),
                        "message": error.message,
                    }
                )
            except Exception as error:  # noqa: BLE001
                failures.append({"target": key, "code": "unknown", "message": str(error)})
    return {
        "successCount": success_count,
        "failureCount": len(failures),
        "failures": failures,
    }


def _azure_start_upload(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    prefix = str(params.get("prefix", ""))
    file_paths = [str(item) for item in params.get("filePaths", []) if str(item).strip()]
    object_key_by_path = {
        str(key): str(value).replace("\\", "/").lstrip("/")
        for key, value in dict(params.get("objectKeyByPath", {}) or {}).items()
        if str(value).strip()
    }
    if not bucket_name or not file_paths:
        raise SidecarError("invalid_config", "Bucket name and file paths are required.")
    client = _build_azure_client(profile)
    paths = [Path(file_path) for file_path in file_paths]
    block_sizes = {path: _azure_block_size(path.stat().st_size) for path in paths}
    total_bytes = sum(path.stat().st_size for path in paths)
    uses_multipart = any(path.stat().st_size >= _AZURE_PUT_BLOB_LIMIT for path in paths)
    parts_total = sum(
        max((path.stat().st_size + block_sizes[path] - 1) // block_sizes[path], 1)
        for path in paths
        if path.stat().st_size >= _AZURE_PUT_BLOB_LIMIT
    )
    part_size_bytes = max(block_sizes.values()) if parts_total > 0 else None
    job_id = f"upload-{uuid.uuid4().hex[:8]}"
    label = f"Upload {len(paths)} file(s) to {bucket_name}"
    strategy_label = _transfer_strategy_label("upload", uses_multipart)
    output_lines = [f"Queued {len(paths)} file(s) for upload to {bucket_name}."]
    bytes_transferred = 0
    items_completed = 0
    parts_completed = 0
    control = _register_transfer(
        TransferControl(
            job_id=job_id,
            label=label,
            direction="upload",
            total_bytes=total_bytes,
            item_count=len(paths),
            strategy_label=strategy_label,
            part_size_bytes=part_size_bytes,
            parts_total=parts_total if part_size_bytes is not None else None,
        )
    )
    _emit_transfer_event(
        _build_transfer_job(
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
    )
    for path in paths:
        _transfer_gate(control)
        target_name = object_key_by_path.get(str(path), path.name)
        target_key = f"{prefix}{target_name}" if prefix else target_name
        blob_path = client.blob_path(bucket_name, target_key)
        file_size = path.stat().st_size
        output_lines.append(f"Uploading {path.name} ({file_size} bytes) to {target_key}.")
        if file_size >= _AZURE_PUT_BLOB_LIMIT:
            chunk_size = block_sizes[path]
            block_count = (file_size + chunk_size - 1) // chunk_size
            upload_nonce = uuid.uuid4().hex
            block_ids = [base64.b64encode(f"{upload_nonce}-{index:08d}".encode()).decode() for index in range(block_count)]
            def upload_block(index):
                _transfer_gate(control)
                with path.open("rb") as handle:
                    length = min(chunk_size, file_size - index * chunk_size)
                    client.request("PUT", blob_path, query={"comp": "block", "blockid": block_ids[index]},
                                   body=_FilePart(handle, index * chunk_size, length))
                return length
            workers = max(1, min(8, profile.max_pool_connections, (256 * 1024**2) // chunk_size))
            with ThreadPoolExecutor(max_workers=workers) as pool:
                futures = [pool.submit(upload_block, index) for index in range(block_count)]
                try:
                    for future in as_completed(futures):
                        bytes_transferred += future.result()
                        parts_completed += 1
                        _transfer_checkpoint(control, bytes_transferred=bytes_transferred, items_completed=items_completed, parts_completed=parts_completed, current_item_label=path.name)
                        _emit_transfer_event(_build_transfer_job(job_id=job_id, label=label, direction="upload", progress=bytes_transferred / total_bytes if total_bytes else 1,
                            status="running", bytes_transferred=bytes_transferred, total_bytes=total_bytes, output_lines=list(output_lines), strategy_label=strategy_label,
                            current_item_label=path.name, item_count=len(paths), items_completed=items_completed, part_size_bytes=chunk_size,
                            parts_completed=parts_completed, parts_total=parts_total, can_pause=True, can_cancel=True))
                except BaseException:
                    for pending in futures: pending.cancel()
                    raise
            _transfer_gate(control)
            block_list_xml = "".join(f"<Latest>{block_id}</Latest>" for block_id in block_ids)
            block_list_body = (
                f'<?xml version="1.0" encoding="utf-8"?><BlockList>{block_list_xml}</BlockList>'
            ).encode("utf-8")
            client.request(
                "PUT",
                blob_path,
                query={"comp": "blocklist"},
                headers={"Content-Type": "application/xml"},
                body=block_list_body,
            )
        else:
            client.request(
                "PUT",
                blob_path,
                headers={"x-ms-blob-type": "BlockBlob", "Content-Type": "application/octet-stream"},
                body=path.read_bytes(),
            )
            bytes_transferred += file_size
        items_completed += 1
        _transfer_checkpoint(
            control,
            bytes_transferred=bytes_transferred,
            items_completed=items_completed,
            parts_completed=parts_completed,
            current_item_label=path.name,
        )
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


def _download_name(key: str) -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', key.replace('\\', '/').split('/')[-1]).rstrip(' .')[:180]
    if not name or name in {'.', '..'}:
        name = 'download'
    if name.split('.')[0].upper() in {'CON', 'PRN', 'AUX', 'NUL', *{f'COM{i}' for i in range(1, 10)}, *{f'LPT{i}' for i in range(1, 10)}}:
        name = '_' + name
    return name


@contextmanager
def _staged_download(destination: Path, key: str, policy: str, output_lines: list[str]):
    """Publish only validated bytes, without replacing any existing directory entry."""
    if policy not in {"keepBoth", "replace"}:
        raise SidecarError("invalid_config", "Unknown download conflict policy.")
    fd, temporary = tempfile.mkstemp(prefix='.odb-', suffix='.part', dir=destination)
    temporary = Path(temporary)
    try:
        with os.fdopen(fd, 'w+b') as handle:
            yield handle
            handle.flush()
            os.fsync(handle.fileno())
        name = _download_name(key)
        base = Path(name)
        occupied = {}
        for item in destination.iterdir():
            occupied.setdefault(item.name.casefold(), item)
        for index in range(100000):
            target = destination / (name if index == 0 else f'{base.stem} ({index}){base.suffix}')
            if policy == 'replace':
                target = occupied.get(target.name.casefold(), target)
                os.replace(temporary, target)
                output_lines.append(f'Saved {key} to {target}.')
                break
            # Treat case-only differences as conflicts on every platform.
            if target.name.casefold() in occupied:
                continue
            try:
                os.link(temporary, target)
                output_lines.append(f'Saved {key} to {target}.')
                break
            except FileExistsError:
                continue
        else:
            raise SidecarError('object_conflict', 'Could not allocate a unique download name.')
    finally:
        temporary.unlink(missing_ok=True)


def _validate_download_range(header: str, start: int, end: int, size: int, received: int) -> None:
    if header != f'bytes {start}-{end}/{size}' or received != end - start + 1:
        raise SidecarError('object_conflict', 'Download range or length does not match the requested object; partial file discarded.')


def _azure_start_download(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    keys = [str(item) for item in params.get("keys", []) if str(item).strip()]
    versions = {str(item["key"]): str(item["versionId"]) for item in params.get("objects", []) if item.get("versionId") is not None}
    if params.get("objects"): keys = [str(item["key"]) for item in params["objects"]]
    if params.get("versionId") is not None: versions.update({key: str(params["versionId"]) for key in keys})
    def version_query(key): return {"versionid": versions[key]} if key in versions else {}
    destination_path = str(params.get("destinationPath", "")).strip()
    if not bucket_name or not keys or not destination_path:
        raise SidecarError("invalid_config", "Bucket, keys, and destination path are required.")
    multipart_threshold_bytes = _int_param(params, "multipartThresholdMiB", 32) * 1024 * 1024
    multipart_chunk_bytes = _int_param(params, "multipartChunkMiB", 8) * 1024 * 1024
    client = _build_azure_client(profile)
    destination = Path(destination_path)
    destination.mkdir(parents=True, exist_ok=True)
    sizes: dict[str, int] = {}
    validators = {}
    for key in keys:
        _, head_headers, _ = client.request("HEAD", client.blob_path(bucket_name, key), query=version_query(key))
        sizes[key] = int(head_headers.get("Content-Length", 0) or 0)
        validators[key] = {"If-Match": head_headers["ETag"]} if head_headers.get("ETag") else {}
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
    control = _register_transfer(
        TransferControl(
            job_id=job_id,
            label=label,
            direction="download",
            total_bytes=total_bytes,
            item_count=len(keys),
            strategy_label=strategy_label,
            part_size_bytes=part_size_bytes,
            parts_total=parts_total if part_size_bytes is not None else None,
        )
    )
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
        _transfer_gate(control)
        target = destination / _download_name(key)
        object_size = sizes[key]
        blob_path = client.blob_path(bucket_name, key)
        output_lines.append(f"Downloading {key} ({object_size} bytes) to {target}.")
        before_object = bytes_transferred
        with _staged_download(destination, key, params.get("conflictPolicy", "keepBoth"), output_lines) as handle:
            if object_size >= multipart_threshold_bytes:
                handle.truncate(object_size)
                write_lock = threading.Lock()
                def download_range(start):
                    _transfer_gate(control)
                    end = min(start + multipart_chunk_bytes, object_size) - 1
                    response = client.open("GET", blob_path, query=version_query(key), headers={"Range": f"bytes={start}-{end}", **validators[key]})
                    try:
                        expected = end - start + 1
                        _validate_download_range(response.headers.get('Content-Range', ''), start, end, object_size, expected)
                        received = 0
                        while received <= expected:
                            data = response.read(min(1024 * 1024, expected - received + 1))
                            if not data: break
                            _transfer_gate(control)
                            with write_lock:
                                handle.seek(start + received)
                                handle.write(data)
                            received += len(data)
                    finally:
                        response.close()
                    _validate_download_range(response.headers.get('Content-Range', ''), start, end, object_size, received)
                    return received
                workers = max(1, min(8, profile.max_pool_connections, (256 * 1024**2) // multipart_chunk_bytes))
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    futures = _bounded_parallel(pool, download_range, range(0, object_size, multipart_chunk_bytes), workers * 2)
                    try:
                        for future in futures:
                            bytes_transferred += future.result()
                            parts_completed += 1
                            _transfer_checkpoint(control, bytes_transferred=bytes_transferred, items_completed=items_completed, parts_completed=parts_completed, current_item_label=key)
                            _emit_transfer_event(_build_transfer_job(job_id=job_id, label=label, direction="download", progress=bytes_transferred / total_bytes if total_bytes else 1,
                                status="running", bytes_transferred=bytes_transferred, total_bytes=total_bytes, output_lines=list(output_lines),
                                strategy_label=strategy_label, current_item_label=key, item_count=len(keys), items_completed=items_completed,
                                part_size_bytes=part_size_bytes, parts_completed=parts_completed, parts_total=parts_total, can_pause=True, can_cancel=True))
                    except BaseException:
                        futures.close()
                        raise
            else:
                response = client.open("GET", blob_path, query=version_query(key), headers=validators[key])
                with response:
                    while True:
                        chunk = response.read(min(multipart_chunk_bytes, 1024 * 1024))
                        if not chunk:
                            break
                        handle.write(chunk)
                        bytes_transferred += len(chunk)
                        _transfer_checkpoint(
                            control,
                            bytes_transferred=bytes_transferred,
                            items_completed=items_completed,
                            parts_completed=parts_completed,
                            current_item_label=key,
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
                                parts_completed=parts_completed if part_size_bytes is not None else None,
                                parts_total=parts_total if part_size_bytes is not None else None,
                                can_pause=True,
                                can_cancel=True,
                            )
                        )
            _transfer_gate(control)
            if bytes_transferred - before_object != object_size:
                raise SidecarError("object_conflict", "Download size changed or response was incomplete; partial file discarded.")
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


def _azure_run_put_testdata(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    config = params.get("config") or {}
    object_count = max(int(config.get("objectCount", 0) or 0), 0)
    versions = max(int(config.get("versions", 1) or 1), 1)
    bucket_name = str(config.get("bucketName", "")).strip()
    prefix = str(config.get("prefix", "") or "")
    threads = max(int(config.get("threads", 1) or 1), 1)
    size_bytes = max(int(config.get("objectSizeBytes", config.get("sizeBytes", 4096)) or 4096), 0)
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_azure_client(profile)
    payload = b"A" * size_bytes

    def put_one(index: int) -> None:
        key = f"{prefix}testdata-{index:06d}.bin"
        for _ in range(versions):
            client.request(
                "PUT",
                client.blob_path(bucket_name, key),
                headers={"x-ms-blob-type": "BlockBlob", "Content-Type": "application/octet-stream"},
                body=payload,
            )

    with ThreadPoolExecutor(max_workers=min(threads, 16)) as pool:
        futures = [pool.submit(put_one, index) for index in range(object_count)]
        for future in as_completed(futures):
            future.result()

    return _tool_state(
        "put-testdata.py",
        f"Prepared {object_count} object(s) with {versions} version(s) each for {bucket_name}.",
        [
            f"Bucket: {bucket_name}",
            f"Prefix: {config.get('prefix', '')}",
            f"Threads: {config.get('threads', 1)}",
        ],
    )


def _azure_run_delete_all(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    config = params.get("config") or {}
    bucket_name = str(config.get("bucketName", "")).strip()
    prefix = str(config.get("prefix", "") or "")
    max_workers = max(1, min(int(config.get("maxWorkers", 4) or 4), 16))
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_azure_client(profile)

    deleted_count = 0
    failure_count = 0
    marker: str | None = None
    while True:
        root, marker = _azure_list_blobs_page(client, bucket_name, prefix=prefix, marker=marker)
        keys = [
            str(node.findtext("Name") or "")
            for node in root.iterfind("Blobs/Blob")
            if str(node.findtext("Name") or "")
        ]
        if keys:
            with ThreadPoolExecutor(max_workers=max_workers) as pool:
                futures = [pool.submit(_azure_delete_blob, client, bucket_name, key) for key in keys]
                for future in as_completed(futures):
                    try:
                        future.result()
                        deleted_count += 1
                    except Exception:  # noqa: BLE001
                        failure_count += 1
        if not marker:
            break

    return _tool_state(
        "delete-all.py",
        f"Deleted {deleted_count} object(s) from {bucket_name}.",
        [
            f"Batch size: {config.get('batchSize', 1000)}",
            f"Workers: {config.get('maxWorkers', 1)}",
            f"Deleted: {deleted_count}",
            f"Failures: {failure_count}",
        ],
    )


class _AzureBenchmarkClient:
    """boto3-shaped facade over the Azure client for benchmark primitives."""

    def __init__(self, profile: Profile):
        self._client = _build_azure_client(profile)

    def put_object(self, Bucket: str, Key: str, Body: bytes = b"", **_: Any) -> dict[str, Any]:  # noqa: N803
        body = Body
        self._client.request(
            "PUT",
            self._client.blob_path(Bucket, Key),
            headers={"x-ms-blob-type": "BlockBlob", "Content-Type": "application/octet-stream"},
            body=body,
        )
        return {}

    def get_object(self, Bucket: str, Key: str, **_: Any) -> dict[str, Any]:  # noqa: N803
        response = self._client.open("GET", self._client.blob_path(Bucket, Key))
        return {"Body": response, "ContentLength": int(response.headers.get('Content-Length') or 0),
                "ResponseMetadata": {"RetryAttempts": len(getattr(getattr(response, 'retries', None), 'history', ()) or ())}}

    def delete_object(self, Bucket: str, Key: str, **_: Any) -> dict[str, Any]:  # noqa: N803
        self._client.request("DELETE", self._client.blob_path(Bucket, Key))
        return {}

    def delete_objects(self, Bucket: str, Delete: dict[str, Any], **_: Any) -> dict[str, Any]:  # noqa: N803
        deleted: list[dict[str, Any]] = []
        errors: list[dict[str, Any]] = []
        for entry in (Delete or {}).get("Objects", []):
            key = str(entry.get("Key", ""))
            try:
                self._client.request("DELETE", self._client.blob_path(Bucket, key))
                deleted.append({"Key": key})
            except SidecarError as error:
                errors.append(
                    {
                        "Key": key,
                        "Code": str(error.details.get("azureCode", error.code)),
                        "Message": error.message,
                    }
                )
        return {"Deleted": deleted, "Errors": errors}


def _handle_azure_request(method: str, params: dict[str, Any]) -> dict[str, Any] | None:
    """Dispatch a request for an azureBlob profile. Returns None to fall back
    to the shared (storage-agnostic) handlers, e.g. benchmark orchestration."""
    if method in _AZURE_UNSUPPORTED_METHODS:
        raise SidecarError(
            "unsupported_feature",
            f"Method {method} is not supported for Azure Blob profiles.",
        )
    if method == "testProfile":
        return _azure_test_profile(dict(params.get("profile") or {}))
    if method == "listBuckets":
        return _azure_list_buckets(dict(params.get("profile") or {}))
    if method == "createBucket":
        return _azure_create_bucket(params)
    if method == "deleteBucket":
        return _azure_delete_bucket(params)
    if method == "listObjects":
        return _azure_list_objects(params)
    if method == "getBucketAdminState":
        return _azure_get_bucket_admin_state(params)
    if method == "getObjectDetails":
        return _azure_get_object_details(params)
    if method == "createFolder":
        return _azure_create_folder(params)
    if method == "copyObject":
        return _azure_copy_object(params)
    if method == "moveObject":
        return _azure_move_object(params)
    if method == "deleteObjects":
        return _azure_delete_objects(params)
    if method == "startUpload":
        return _run_transfer(_azure_start_upload, params)
    if method == "startDownload":
        return _run_transfer(_azure_start_download, params)
    if method == "runPutTestData":
        return _azure_run_put_testdata(params)
    if method == "runDeleteAll":
        return _run_tool(_azure_run_delete_all, params)
    return None


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
        "version": ENGINE_VERSION,
        "available": available,
        "dependencyState": dependency_state,
        "methods": [
            "health",
            "getCapabilities",
            "storageAction",
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
    result = {
        "items": [
            {"key": "bucket.lifecycle", "label": "Lifecycle policy CRUD", "state": "supported"},
            {"key": "bucket.policy", "label": "Bucket policy CRUD", "state": "supported"},
            {"key": "bucket.cors", "label": "Bucket CORS CRUD", "state": "supported"},
            {"key": "bucket.encryption", "label": "Bucket encryption", "state": "supported"},
            {"key": "bucket.tagging", "label": "Bucket tagging", "state": "supported"},
            {"key": "bucket.versioning", "label": "Bucket versioning", "state": "supported"},
            {"key": "object.copy_move", "label": "Copy, move, rename", "state": "supported"},
            {"key": "object.resumable", "label": "Resumable transfer jobs", "state": "supported", "reason": "Explicit multipart/block upload and verified range-download checkpoints; credentials are resupplied on resume."},
            {"key": "tools.bulk-delete", "label": "Delete-all maintenance tool", "state": "supported"},
            {"key": "benchmark", "label": "Integrated benchmark mode", "state": "supported"},
            {"key": "storage.admin", "label": "Advanced storage administration", "state": "supported", "actions": _STORAGE_ACTIONS},
        ]
    }
    if _is_azure_profile(_.get('profile')):
        for item in result['items']:
            if item['key'].startswith('bucket.'):
                item.update({'state': 'unsupported', 'reason': 'Azure account administration requires provider-specific management APIs.'})
            elif item['key'] == 'storage.admin':
                item['actions'] = _storage_action({'profile': _['profile'], 'action': 'providerInfo'})['actions']
    return result


def _test_profile(profile_payload: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(profile_payload)
    client = _build_client(profile)
    response = ({"Buckets": [{"Name": profile.known_bucket}]} if profile.known_bucket else client.list_buckets())
    if profile.known_bucket:
        client.head_bucket(Bucket=profile.known_bucket)
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
    response = ({"Buckets": [{"Name": profile.known_bucket}]} if profile.known_bucket else client.list_buckets())
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
    if response.get('IsTruncated') and (not response.get('NextContinuationToken') or response.get('NextContinuationToken') == continuation_token):
        raise SidecarError('invalid_response', 'S3 returned a truncated listing without a progressing continuation token.')
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
        "versioningStatus": versioning.get("Status", "Disabled") if not any(x.get("operation") == "GetBucketVersioning" and x.get("state") for x in api_calls) else "Unknown",
        "objectLockEnabled": bool(object_lock.get("ObjectLockConfiguration")),
        "lifecycleEnabled": bool(rules),
        "policyAttached": bool(policy.get("Policy")),
        "corsEnabled": bool(cors.get("CORSRules")),
        "encryptionEnabled": bool(encryption_rules),
        "encryptionSummary": encryption_summary,
        "objectLockMode": retention.get("Mode"),
        "objectLockRetentionDays": retention.get("Days"),
        "objectLockRetentionYears": retention.get("Years"),
        "objectLockRetention": {"value": retention.get("Days", retention.get("Years")), "unit": "years" if "Years" in retention else "days"},
        "tags": tags,
        "lifecycleRules": rules,
        "lifecycleJson": _json_dumps({"Rules": lifecycle.get("Rules", [])}),
        "transitionDefaultMinimumObjectSize": lifecycle.get("TransitionDefaultMinimumObjectSize"),
        "policyJson": policy.get("Policy", "{}"),
        "corsJson": _json_dumps(cors.get("CORSRules", [])),
        "encryptionJson": _json_dumps(
            encryption.get("ServerSideEncryptionConfiguration", {})
        ),
        "apiCalls": api_calls,
        "sections": {item["operation"]: {"state": item.get("state", "supported"), "message": item.get("message", "")} for item in api_calls},
    }


def _put_bucket_lifecycle(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    lifecycle_json = str(params.get("lifecycleJson", "")).strip()
    if not bucket_name or not lifecycle_json:
        raise SidecarError("invalid_config", "Bucket name and lifecycle JSON are required.")
    client = _build_client(profile)
    lifecycle = json.loads(lifecycle_json)
    options = {}
    if params.get("transitionDefaultMinimumObjectSize"):
        options["TransitionDefaultMinimumObjectSize"] = params["transitionDefaultMinimumObjectSize"]
    if params.get("expectedLifecycleJson") is not None:
        current = _configuration_or_missing(lambda: client.get_bucket_lifecycle_configuration(Bucket=bucket_name), {"NoSuchLifecycleConfiguration"})
        if json.loads(_json_dumps({"Rules": current.get("Rules", [])})) != json.loads(params["expectedLifecycleJson"]):
            raise SidecarError("conflict", "Lifecycle changed since it was loaded. Refresh before applying.")
    client.put_bucket_lifecycle_configuration(
        Bucket=bucket_name,
        LifecycleConfiguration=lifecycle,
        **options,
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
    key = str(params.get("key", ""))
    options = params.get("options") or {}
    filter_value = str(options.get("filterValue", "")).strip()
    filter_mode = str(options.get("filterMode", "prefix")).strip()
    effective_prefix = key or (filter_value if filter_mode == "prefix" else "")
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required for version listing.")

    # The desktop ListCursor carries a single opaque string `value`, but the S3
    # list_object_versions API paginates on two markers. Encode both into the
    # cursor value as JSON and decode them back on the next request.
    cursor = params.get("cursor") or {}
    cursor_value = cursor.get("value") if isinstance(cursor, dict) else None
    key_marker = ""
    version_id_marker = ""
    if cursor_value:
        try:
            decoded = json.loads(cursor_value)
            if isinstance(decoded, dict):
                key_marker = str(decoded.get("keyMarker", "") or "")
                version_id_marker = str(decoded.get("versionIdMarker", "") or "")
            else:
                key_marker = str(cursor_value)
        except (TypeError, ValueError):
            # Older cursor shape: a bare key marker string.
            key_marker = str(cursor_value)

    client = _build_client(profile)
    request: dict[str, Any] = {
        "Bucket": bucket_name,
        "Prefix": effective_prefix,
        "MaxKeys": 1000,
    }
    if key_marker:
        request["KeyMarker"] = key_marker
    if version_id_marker:
        request["VersionIdMarker"] = version_id_marker
    response = client.list_object_versions(**request)
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

    has_more = bool(response.get("IsTruncated", False))
    next_key_marker = str(response.get("NextKeyMarker") or "")
    next_version_id_marker = str(response.get("NextVersionIdMarker") or "")
    if has_more and (next_key_marker or next_version_id_marker):
        if (next_key_marker, next_version_id_marker) == (key_marker, version_id_marker):
            raise SidecarError('invalid_response', 'S3 returned repeated version listing markers.')
        next_cursor_value: str | None = json.dumps(
            {
                "keyMarker": next_key_marker,
                "versionIdMarker": next_version_id_marker,
            }
        )
    else:
        if has_more:
            raise SidecarError('invalid_response', 'S3 returned a truncated version listing without continuation markers.')
        has_more = False
        next_cursor_value = None

    return {
        "items": items,
        "cursor": {"value": next_cursor_value, "hasMore": has_more},
        "totalCount": len(items),
        "versionCount": len([item for item in items if not item["deleteMarker"]]),
        "deleteMarkerCount": len([item for item in items if item["deleteMarker"]]),
    }


def _get_object_details(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    key = str(params.get("key", ""))
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

    head = _call_api(api_calls, "HeadObject", lambda: client.head_object(**_object_ref(params)))
    tag_response = _maybe_call(
        api_calls,
        "GetObjectTagging",
        lambda: client.get_object_tagging(**_object_ref(params)),
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
        "Content-Disposition": str(head.get('ContentDisposition', '')),
        "Content-Encoding": str(head.get('ContentEncoding', '')),
        "Content-Language": str(head.get('ContentLanguage', '')),
        "Expires": _serialize_dt(head['Expires']) if head.get('Expires') else '',
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
        "versionId": head.get('VersionId') or params.get('versionId'),
        "etag": str(head.get('ETag', '')).strip('"'),
        "storageClass": head.get('StorageClass', 'STANDARD'),
        "restore": head.get('Restore'),
        "archiveStatus": head.get('ArchiveStatus'),
        "encryption": {field: head[field] for field in ('ServerSideEncryption', 'SSEKMSKeyId', 'BucketKeyEnabled') if field in head},
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
    key = str(params.get("key", ""))
    expiration_seconds = max(int(params.get("expirationSeconds", 3600) or 3600), 1)
    if not bucket_name or not key:
        raise SidecarError("invalid_config", "Bucket name and object key are required to generate a presigned URL.")

    client = _build_client(profile)
    url = client.generate_presigned_url(
        "get_object",
        Params=_object_ref(params),
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
    return _storage_copy(params)


def _move_object(params: dict[str, Any]) -> dict[str, Any]:
    result = _copy_object(params)
    profile = _parse_profile(params.get("profile", {}))
    client = _build_client(profile)
    client.delete_object(
        Bucket=str(params.get("sourceBucketName", "")).strip(),
        Key=str(params.get("sourceKey", "")).strip(),
    )
    return result


# S3's DeleteObjects API rejects requests with more than 1000 keys per call.
_S3_DELETE_BATCH_LIMIT = 1000


def _chunked(items: list[Any], size: int):
    for start in range(0, len(items), size):
        yield items[start : start + size]


def _bounded_parallel(pool, function, items, pending_limit):
    iterator = iter(items)
    pending = set()
    def refill():
        while len(pending) < pending_limit:
            try: item = next(iterator)
            except StopIteration: return
            pending.add(pool.submit(function, item))
    try:
        refill()
        while pending:
            completed, _ = wait(pending, return_when=FIRST_COMPLETED)
            for future in completed:
                pending.remove(future)
                yield future
            refill()
    finally:
        for future in pending: future.cancel()


def _delete_objects(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    keys = [str(item) for item in params.get("keys", []) if str(item).strip()]
    if not bucket_name or not keys:
        raise SidecarError("invalid_config", "Bucket name and keys are required.")
    client = _build_client(profile)

    success_count = 0
    failures: list[dict[str, Any]] = []
    for chunk in _chunked(keys, _S3_DELETE_BATCH_LIMIT):
        try:
            response = client.delete_objects(
                Bucket=bucket_name,
                Delete={"Objects": [{"Key": key} for key in chunk], "Quiet": False},
            )
        except Exception as error:  # noqa: BLE001
            # Convert a chunk-level failure into per-key failures so the rest of
            # the operation can still proceed (partial-failure contract).
            mapped = _map_exception(error)
            for key in chunk:
                failures.append(
                    {
                        "target": key,
                        "code": mapped.code,
                        "message": mapped.message,
                    }
                )
            continue
        deleted = response.get("Deleted", [])
        errors = response.get("Errors", [])
        success_count += len(deleted)
        for item in errors:
            failures.append(
                {
                    "target": str(item.get("Key", "")),
                    "code": str(item.get("Code", "unknown")),
                    "message": str(item.get("Message", "Unknown delete error.")),
                }
            )

    return {
        "successCount": success_count,
        "failureCount": len(failures),
        "failures": failures,
    }


def _delete_object_versions(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    versions = params.get("versions") or []
    if not bucket_name or not versions:
        raise SidecarError("invalid_config", "Bucket name and versions are required.")
    client = _build_client(profile)

    objects = [
        {
            "Key": str(item.get("key", "")),
            "VersionId": str(item.get("versionId", "")),
        }
        for item in versions
    ]

    success_count = 0
    failures: list[dict[str, Any]] = []
    for chunk in _chunked(objects, _S3_DELETE_BATCH_LIMIT):
        try:
            response = client.delete_objects(
                Bucket=bucket_name,
                Delete={"Objects": chunk, "Quiet": False},
            )
        except Exception as error:  # noqa: BLE001
            # Convert a chunk-level failure into per-version failures so the rest
            # of the operation can still proceed (partial-failure contract).
            mapped = _map_exception(error)
            for obj in chunk:
                failures.append(
                    {
                        "target": obj["Key"],
                        "versionId": obj["VersionId"] or None,
                        "code": mapped.code,
                        "message": mapped.message,
                    }
                )
            continue
        deleted = response.get("Deleted", [])
        errors = response.get("Errors", [])
        success_count += len(deleted)
        for item in errors:
            failures.append(
                {
                    "target": str(item.get("Key", "")),
                    "versionId": str(item.get("VersionId", "")) or None,
                    "code": str(item.get("Code", "unknown")),
                    "message": str(item.get("Message", "Unknown delete error.")),
                }
            )

    return {
        "successCount": success_count,
        "failureCount": len(failures),
        "failures": failures,
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
    _write_stdout_line(json.dumps({"event": "transferProgress", "job": job}))


def _transfer_strategy_label(direction: str, uses_multipart: bool) -> str:
    return f'{"Multipart" if uses_multipart else "Single-part"} {direction}'


class _FilePart:
    """Seekable view of one file range; SDK hashing and retries stay bounded."""
    def __init__(self, handle, start, length):
        self.handle, self.start, self.length, self.position = handle, start, length, 0
        self.handle.seek(start)

    def read(self, size=-1):
        remaining = self.length - self.position
        amount = remaining if size is None or size < 0 else min(size, remaining)
        data = self.handle.read(amount)
        self.position += len(data)
        return data

    def tell(self): return self.position
    def seek(self, offset, whence=0):
        target = offset if whence == 0 else self.position + offset if whence == 1 else self.length + offset
        if target < 0 or target > self.length: raise ValueError("Seek outside multipart range")
        self.handle.seek(self.start + target)
        self.position = target
        return target
    def seekable(self): return True
    def readable(self): return True
    def __len__(self): return self.length


def _start_upload(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    bucket_name = str(params.get("bucketName", "")).strip()
    prefix = str(params.get("prefix", ""))
    file_paths = [str(item) for item in params.get("filePaths", []) if str(item).strip()]
    object_key_by_path = {
        str(key): str(value).replace("\\", "/").lstrip("/")
        for key, value in dict(params.get("objectKeyByPath", {}) or {}).items()
        if str(value).strip()
    }
    if not bucket_name or not file_paths:
        raise SidecarError("invalid_config", "Bucket name and file paths are required.")
    multipart_threshold_bytes = _int_param(params, "multipartThresholdMiB", 32) * 1024 * 1024
    multipart_chunk_bytes = min(max(_int_param(params, "multipartChunkMiB", 8), 5), 5120) * 1024 * 1024
    paths = [Path(file_path) for file_path in file_paths]
    sizes = {path: path.stat().st_size for path in paths}
    for size in sizes.values():
        if size > 50000 * 1024**3 or (size >= multipart_threshold_bytes and
                (size + multipart_chunk_bytes - 1) // multipart_chunk_bytes > 10000):
            raise SidecarError("invalid_config", "Upload exceeds S3 object or 10,000-part limits; select a larger part size.")
    client = _build_client(profile)
    total_bytes = sum(sizes[path] for path in paths)
    uses_multipart = any(size >= multipart_threshold_bytes for size in sizes.values())
    parts_total = sum(
        max((sizes[path] + multipart_chunk_bytes - 1) // multipart_chunk_bytes, 1)
        for path in paths
        if sizes[path] >= multipart_threshold_bytes
    )
    part_size_bytes = multipart_chunk_bytes if parts_total > 0 else None
    job_id = f"upload-{uuid.uuid4().hex[:8]}"
    label = f"Upload {len(paths)} file(s) to {bucket_name}"
    strategy_label = _transfer_strategy_label("upload", uses_multipart)
    output_lines = [f"Queued {len(paths)} file(s) for upload to {bucket_name}."]
    bytes_transferred = 0
    items_completed = 0
    parts_completed = 0
    control = _register_transfer(
        TransferControl(
            job_id=job_id,
            label=label,
            direction="upload",
            total_bytes=total_bytes,
            item_count=len(paths),
            strategy_label=strategy_label,
            part_size_bytes=part_size_bytes,
            parts_total=parts_total if part_size_bytes is not None else None,
        )
    )
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
        _transfer_gate(control)
        target_name = object_key_by_path.get(str(path), path.name)
        target_key = f"{prefix}{target_name}" if prefix else target_name
        file_size = path.stat().st_size
        output_lines.append(f"Uploading {path.name} ({file_size} bytes) to {target_key}.")
        if file_size >= multipart_threshold_bytes:
            response = client.create_multipart_upload(Bucket=bucket_name, Key=target_key)
            upload_id = response.get("UploadId")
            if not upload_id:
                raise SidecarError("engine_unavailable", "Multipart upload did not return an upload ID.")
            file_parts_total = max(
                (file_size + multipart_chunk_bytes - 1) // multipart_chunk_bytes, 1
            )
            max_workers = min(8, max(profile.max_pool_connections, 1))

            # One open file handle per worker thread instead of open/close per part.
            part_handle_local = threading.local()
            part_handles: list[Any] = []
            part_handles_lock = threading.Lock()

            def _get_part_handle():
                handle = getattr(part_handle_local, "handle", None)
                if handle is None:
                    handle = path.open("rb")
                    part_handle_local.handle = handle
                    with part_handles_lock:
                        part_handles.append(handle)
                return handle

            def _upload_one_part(part_number: int) -> tuple[int, Any, int]:
                offset = (part_number - 1) * multipart_chunk_bytes
                length = min(multipart_chunk_bytes, file_size - offset)
                handle = _get_part_handle()
                _transfer_gate(control)
                chunk = _FilePart(handle, offset, length)
                part_response = client.upload_part(
                    Bucket=bucket_name,
                    Key=target_key,
                    UploadId=upload_id,
                    PartNumber=part_number,
                    Body=chunk,
                )
                return part_number, part_response.get("ETag"), length

            completed_parts: list[dict[str, Any]] = []
            try:
                with ThreadPoolExecutor(max_workers=max_workers) as pool:
                    futures = _bounded_parallel(pool, _upload_one_part,
                                                range(1, file_parts_total + 1), max_workers * 2)
                    try:
                        for future in futures:
                            part_number, etag, chunk_length = future.result()
                            completed_parts.append(
                                {
                                    "ETag": etag,
                                    "PartNumber": part_number,
                                }
                            )
                            bytes_transferred += chunk_length
                            parts_completed += 1
                            _transfer_checkpoint(
                                control,
                                bytes_transferred=bytes_transferred,
                                items_completed=items_completed,
                                parts_completed=parts_completed,
                                current_item_label=path.name,
                            )
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
                    except BaseException:
                        futures.close()
                        raise
            except BaseException:
                try:
                    client.abort_multipart_upload(
                        Bucket=bucket_name,
                        Key=target_key,
                        UploadId=upload_id,
                    )
                except Exception:  # noqa: BLE001
                    pass
                raise
            finally:
                # Worker threads have exited with the executor; close their handles.
                for handle in part_handles:
                    try:
                        handle.close()
                    except Exception:  # noqa: BLE001
                        pass
            completed_parts.sort(key=lambda part: part["PartNumber"])
            try:
                _transfer_gate(control)
                client.complete_multipart_upload(
                    Bucket=bucket_name, Key=target_key, UploadId=upload_id,
                    MultipartUpload={"Parts": completed_parts},
                )
            except BaseException:
                try:
                    client.abort_multipart_upload(Bucket=bucket_name, Key=target_key, UploadId=upload_id)
                except Exception:
                    pass
                raise
        else:
            with path.open("rb") as handle:
                client.put_object(Bucket=bucket_name, Key=target_key, Body=handle)
            bytes_transferred += file_size
        items_completed += 1
        _transfer_checkpoint(
            control,
            bytes_transferred=bytes_transferred,
            items_completed=items_completed,
            parts_completed=parts_completed,
            current_item_label=path.name,
        )
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
    versions = {str(item["key"]): str(item["versionId"]) for item in params.get("objects", []) if item.get("versionId") is not None}
    if params.get("objects"):
        keys = [str(item["key"]) for item in params["objects"]]
    if params.get("versionId") is not None:
        versions.update({key: str(params["versionId"]) for key in keys})
    def version_kwargs(key):
        return {"VersionId": versions[key]} if key in versions else {}
    destination_path = str(params.get("destinationPath", "")).strip()
    if not bucket_name or not keys or not destination_path:
        raise SidecarError("invalid_config", "Bucket, keys, and destination path are required.")
    multipart_threshold_bytes = _int_param(params, "multipartThresholdMiB", 32) * 1024 * 1024
    multipart_chunk_bytes = _int_param(params, "multipartChunkMiB", 8) * 1024 * 1024
    client = _build_client(profile)
    destination = Path(destination_path)
    destination.mkdir(parents=True, exist_ok=True)
    heads = {key: client.head_object(Bucket=bucket_name, Key=key, **version_kwargs(key)) for key in keys}
    sizes = {key: int(heads[key].get("ContentLength", 0)) for key in keys}
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
    control = _register_transfer(
        TransferControl(
            job_id=job_id,
            label=label,
            direction="download",
            total_bytes=total_bytes,
            item_count=len(keys),
            strategy_label=strategy_label,
            part_size_bytes=part_size_bytes,
            parts_total=parts_total if part_size_bytes is not None else None,
        )
    )
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
        _transfer_gate(control)
        target = destination / _download_name(key)
        object_size = sizes[key]
        output_lines.append(f"Downloading {key} ({object_size} bytes) to {target}.")
        before_object = bytes_transferred
        with _staged_download(destination, key, params.get("conflictPolicy", "keepBoth"), output_lines) as handle:
            if object_size >= multipart_threshold_bytes:
                handle.truncate(object_size)
                write_lock = threading.Lock()
                ranges = ((start, min(start + multipart_chunk_bytes, object_size) - 1) for start in range(0, object_size, multipart_chunk_bytes))
                max_workers = min(8, max(profile.max_pool_connections, 1))

                def _download_one_range(
                    start: int,
                    end: int,
                    handle=handle,
                    write_lock=write_lock,
                    key=key,
                ) -> tuple[int, int, int]:
                    _transfer_gate(control)
                    response = client.get_object(
                        Bucket=bucket_name,
                        Key=key,
                        Range=f"bytes={start}-{end}",
                        **version_kwargs(key),
                        **({"IfMatch": heads[key]["ETag"]} if heads[key].get("ETag") else {}),
                    )
                    try:
                        _transfer_gate(control)
                        expected = end - start + 1
                        _validate_download_range(response.get('ContentRange', ''), start, end, object_size, expected)
                        received = 0
                        while received <= expected:
                            data = response['Body'].read(min(1024 * 1024, expected - received + 1))
                            if not data: break
                            _transfer_gate(control)
                            with write_lock:
                                handle.seek(start + received)
                                handle.write(data)
                            received += len(data)
                    finally:
                        response["Body"].close()
                    _validate_download_range(response.get('ContentRange', ''), start, end, object_size, received)
                    return start, end, received

                with ThreadPoolExecutor(max_workers=max_workers) as pool:
                    futures = _bounded_parallel(pool, lambda span: _download_one_range(*span), ranges, max_workers * 2)
                    try:
                        for future in futures:
                            range_start, range_end, chunk_size = future.result()
                            bytes_transferred += chunk_size
                            parts_completed += 1
                            _transfer_checkpoint(
                                control,
                                bytes_transferred=bytes_transferred,
                                items_completed=items_completed,
                                parts_completed=parts_completed,
                                current_item_label=key,
                            )
                            output_lines.append(
                                f"Downloaded byte range {range_start}-{range_end} for {key}."
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
                    except BaseException:
                        futures.close()
                        raise
            else:
                response = client.get_object(Bucket=bucket_name, Key=key, **version_kwargs(key), **({"IfMatch": heads[key]["ETag"]} if heads[key].get("ETag") else {}))
                try:
                    while True:
                        chunk = response["Body"].read(min(multipart_chunk_bytes, 1024 * 1024))
                        if not chunk:
                            break
                        handle.write(chunk)
                        bytes_transferred += len(chunk)
                        _transfer_checkpoint(
                            control,
                            bytes_transferred=bytes_transferred,
                            items_completed=items_completed,
                            parts_completed=parts_completed,
                            current_item_label=key,
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
                                parts_completed=parts_completed if part_size_bytes is not None else None,
                                parts_total=parts_total if part_size_bytes is not None else None,
                                can_pause=True,
                                can_cancel=True,
                            )
                        )
                finally:
                    response["Body"].close()
            _transfer_gate(control)
            if bytes_transferred - before_object != object_size:
                raise SidecarError("object_conflict", "Download size changed or response was incomplete; partial file discarded.")
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
    control = _lookup_transfer(job_id) if job_id else None
    if control is None:
        # No active transfer with this id: report an honest error instead of a
        # fabricated success. There is no dedicated "not found" code in the
        # contract, so reuse invalid_config (the jobId parameter is invalid).
        raise SidecarError(
            "invalid_config",
            f"No active transfer with job id '{job_id}'.",
            {"jobId": job_id},
        )

    with control.lock:
        if action == "cancelled":
            control.status = "cancelled"
            # Wake a paused transfer so it observes the cancellation.
            control.resume_event.set()
        elif action == "paused":
            if control.status != "cancelled":
                control.status = "paused"
                control.resume_event.clear()
        elif action == "running":
            if control.status != "cancelled":
                control.status = "running"
                control.resume_event.set()

        status = control.status
        total = control.total_bytes
        transferred = control.bytes_transferred
        progress = (transferred / total) if total else (1.0 if status == "cancelled" else 0.0)
        output_line = {
            "cancelled": "Cancellation requested; waiting for workers and cleanup.",
            "paused": "Transfer paused.",
            "running": "Transfer resumed.",
        }.get(action, f"Transfer {action}.")
        return _build_transfer_job(
            job_id=control.job_id,
            label=control.label,
            direction=control.direction,
            progress=progress,
            status="cancelling" if status == "cancelled" else status,
            bytes_transferred=transferred,
            total_bytes=total,
            output_lines=[output_line],
            strategy_label=control.strategy_label,
            current_item_label=control.current_item_label,
            item_count=control.item_count,
            items_completed=control.items_completed,
            part_size_bytes=control.part_size_bytes,
            parts_completed=(
                control.parts_completed if control.part_size_bytes is not None else None
            ),
            parts_total=(
                control.parts_total if control.part_size_bytes is not None else None
            ),
            can_pause=status == "running",
            can_resume=status == "paused",
            can_cancel=status in ("running", "paused"),
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
    profile = _parse_profile(params.get("profile", {}))
    config = params.get("config") or {}
    object_count = max(int(config.get("objectCount", 0) or 0), 0)
    versions = max(int(config.get("versions", 1) or 1), 1)
    bucket_name = str(config.get("bucketName", "")).strip()
    prefix = str(config.get("prefix", "") or "")
    threads = max(int(config.get("threads", 1) or 1), 1)
    size_bytes = max(
        int(config.get("objectSizeBytes", config.get("sizeBytes", 4096)) or 4096), 0
    )
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)
    payload = b"A" * size_bytes

    failure_count = 0
    errors: list[str] = []
    started = time.monotonic()

    def put_one(index: int) -> None:
        key = f"{prefix}testdata-{index:06d}.bin"
        for _ in range(versions):
            client.put_object(
                Bucket=bucket_name,
                Key=key,
                Body=payload,
                ContentType="application/octet-stream",
            )

    with ThreadPoolExecutor(max_workers=min(threads, 16)) as pool:
        futures = [pool.submit(put_one, index) for index in range(object_count)]
        for future in as_completed(futures):
            try:
                future.result()
            except Exception as error:  # noqa: BLE001
                failure_count += 1
                if len(errors) < 5:
                    errors.append(str(error))

    duration_seconds = time.monotonic() - started
    created_count = object_count - failure_count
    lines = [
        f"Bucket: {bucket_name}",
        f"Prefix: {prefix}",
        f"Threads: {threads}",
        f"Object size: {size_bytes} byte(s)",
        f"Created: {created_count} object(s) with {versions} version(s) each",
        f"Failures: {failure_count}",
        f"Duration: {duration_seconds:.2f}s",
    ]
    lines.extend(f"Error: {message}" for message in errors)
    state = _tool_state(
        "put-testdata",
        f"Created {created_count} object(s) with {versions} version(s) each in {bucket_name}."
        if failure_count == 0
        else f"Created {created_count} object(s) in {bucket_name} with {failure_count} failure(s).",
        lines,
    )
    if failure_count > 0:
        state["exitCode"] = 1
    return state


_DELETE_TRANSIENT_CODES = {'InternalError', 'InternalFailure', 'ServiceUnavailable', 'SlowDown', 'RequestTimeout', 'RequestTimeoutException', '500', '502', '503', '504'}
_DELETE_STALE_CODES = {'InternalError', 'InternalFailure', 'ServiceUnavailable', '500', '502', '503'}


def _delete_error_retryable(error):
    if isinstance(error, dict): return str(error.get('Code') or '') in _DELETE_TRANSIENT_CODES
    return _client_error_code(error) in _DELETE_TRANSIENT_CODES or isinstance(error, (TimeoutError, ConnectionError))


def _recover_delete_entry(client, bucket, entry, error, eligible, attempts=3):
    request = {'Bucket': bucket, **{k: v for k, v in entry.items() if k in {'Key', 'VersionId'}}}
    message = str(error.get('Message') or error.get('Code')) if isinstance(error, dict) else str(error)
    code = str(error.get('Code') or '') if isinstance(error, dict) else _client_error_code(error)
    if not _delete_error_retryable(error): return message
    for attempt in range(attempts):
        try:
            client.delete_object(**request)
            return None
        except Exception as failed:
            code, message = _client_error_code(failed), str(failed)
            if not _delete_error_retryable(failed): return message
            if attempt + 1 < attempts: time.sleep(min(0.1 * 2**attempt, 1))
    if not eligible or code not in _DELETE_STALE_CODES:
        return message
    # Recheck immediately before the destructive recovery. Suspended, enabled,
    # failed probes and a real version id all exclude the empty-PUT path.
    try:
        versioning = client.get_bucket_versioning(Bucket=bucket)
        if versioning.get('Status') or entry.get('VersionId') not in {None, 'null'}:
            return message
        condition = {'IfMatch': entry['_ETag']} if entry.get('_ETag') else {}
        client.put_object(Bucket=bucket, Key=entry['Key'], Body=b'', **condition)
    except Exception as failed:
        return f'{message}; empty PUT recovery failed: {failed}'
    for attempt in range(attempts):
        try:
            client.delete_object(Bucket=bucket, Key=entry['Key'])
            return None
        except Exception as failed:
            message = str(failed)
            if not _delete_error_retryable(failed): break
            if attempt + 1 < attempts: time.sleep(min(0.1 * 2**attempt, 1))
    return f'overwritten with an empty object; delete failed: {message}'


def _delete_batch_with_recovery(client, bucket, batch, eligible, attempts=3):
    pending = list(batch)
    failures = []
    last_errors = {}
    identity = lambda e: (str(e.get('Key') or ''), str(e.get('VersionId') or ''))
    for attempt in range(attempts):
        if not pending: break
        try:
            response = client.delete_objects(Bucket=bucket, Delete={'Objects': [{k: v for k, v in item.items() if k in {'Key', 'VersionId'}} for item in pending], 'Quiet': True})
            errors = response.get('Errors') or []
            errors_by_id = {identity(e): e for e in errors}
            retry = []
            for entry in pending:
                error = errors_by_id.get(identity(entry))
                # Some compatible implementations omit VersionId in errors.
                if error is None: error = next((e for e in errors if e.get('Key') == entry.get('Key') and not e.get('VersionId')), None)
                if error is None: continue
                if _delete_error_retryable(error):
                    retry.append(entry)
                    last_errors[identity(entry)] = error
                else: failures.append((entry, str(error.get('Message') or error.get('Code') or 'delete failed')))
            pending = retry
        except Exception as error:
            if not _delete_error_retryable(error):
                failures.extend((entry, str(error)) for entry in pending)
                pending = []
            else:
                for entry in pending: last_errors[identity(entry)] = error
        if pending and attempt + 1 < attempts: time.sleep(min(0.1 * 2**attempt, 1))
    for entry in pending:
        message = _recover_delete_entry(client, bucket, entry, last_errors[identity(entry)], eligible, attempts)
        if message: failures.append((entry, message))
    return failures


def _run_delete_all(params: dict[str, Any]) -> dict[str, Any]:
    profile = _parse_profile(params.get("profile", {}))
    config = params.get("config") or {}
    bucket_name = str(config.get("bucketName", "")).strip()
    prefix = str(config.get("prefix", "") or "")
    batch_size = max(1, min(int(config.get("batchSize", 1000) or 1000), 1000))
    max_workers = max(1, min(int(config.get("maxWorkers", 4) or 4), 16))
    deletion_delay_ms = max(int(config.get("deletionDelayMs", 0) or 0), 0)
    list_max_keys = max(1, min(int(config.get("listMaxKeys", 1000) or 1000), 1000))
    if not bucket_name:
        raise SidecarError("invalid_config", "Bucket name is required.")
    client = _build_client(profile)

    try:
        versioning = client.get_bucket_versioning(Bucket=bucket_name)
        never_versioned = not versioning.get("Status")
    except Exception:
        never_versioned = False
    hostname = (urlparse(profile.endpoint_url).hostname or "").lower()
    eligible_recovery = (profile.endpoint_type == "s3Compatible" and never_versioned
                         and not hostname.endswith(("amazonaws.com", "amazonaws.com.cn")))
    used_versions = not never_versioned
    abort_message: str | None = None

    def _iter_entries():
        nonlocal used_versions, abort_message
        base_kwargs: dict[str, Any] = {"Bucket": bucket_name, "MaxKeys": list_max_keys}
        if prefix:
            base_kwargs["Prefix"] = prefix
        try:
            page = None if never_versioned else client.list_object_versions(**dict(base_kwargs))
        except Exception as error:
            raise SidecarError("delete_failed", "Version listing failed; refusing to delete without knowing the version history.") from error
        if page is not None:
            seen_markers = set()
            while True:
                for group in ("Versions", "DeleteMarkers"):
                    for item in page.get(group) or []:
                        key = str(item.get("Key", ""))
                        if not key:
                            continue
                        entry: dict[str, Any] = {"Key": key}
                        version_id = item.get("VersionId")
                        # Pass VersionId through verbatim whenever the listing
                        # returned one. The literal "null" is a real version id
                        # (objects created before versioning was enabled);
                        # omitting it would only stack a delete marker.
                        if version_id:
                            entry["VersionId"] = version_id
                        else:
                            raise SidecarError("delete_failed", "Version listing omitted a version ID; refusing an ambiguous deletion.")
                        yield entry
                if not page.get("IsTruncated"):
                    return
                next_key_marker = str(page.get("NextKeyMarker") or "")
                next_version_marker = str(page.get("NextVersionIdMarker") or "")
                if not next_key_marker and not next_version_marker:
                    # Truncated page without continuation markers: continuing
                    # would refetch page 1 forever, so stop listing here.
                    abort_message = "Version listing was truncated without continuation markers. Deletion is incomplete."
                    return
                markers = (next_key_marker, next_version_marker)
                if markers in seen_markers:
                    abort_message = (
                        "Aborting: listing made no progress "
                        f"(markers repeated at key marker '{next_key_marker}' "
                        "with no new deletions or failures)."
                    )
                    return
                seen_markers.add(markers)
                next_kwargs = dict(base_kwargs)
                if next_key_marker:
                    next_kwargs["KeyMarker"] = next_key_marker
                if next_version_marker:
                    next_kwargs["VersionIdMarker"] = next_version_marker
                page = client.list_object_versions(**next_kwargs)
            return
        continuation: str | None = None
        seen_continuations = set()
        while True:
            v2_kwargs = dict(base_kwargs)
            if continuation:
                v2_kwargs["ContinuationToken"] = continuation
            page = client.list_objects_v2(**v2_kwargs)
            for item in page.get("Contents") or []:
                key = str(item.get("Key", ""))
                if key:
                    yield {"Key": key, "_ETag": item.get("ETag")}
            if not page.get("IsTruncated"):
                return
            continuation = page.get("NextContinuationToken")
            if not continuation or continuation in seen_continuations:
                # Truncated page without a continuation token: stop rather
                # than refetching page 1 forever.
                abort_message = "Object listing returned a missing or repeated continuation token. Deletion is incomplete."
                return
            seen_continuations.add(continuation)

    deleted_count = 0
    failure_count = 0
    errors: list[str] = []
    counter_lock = threading.Lock()
    started = time.monotonic()

    def delete_batch(batch: list[dict[str, Any]]) -> None:
        nonlocal deleted_count, failure_count
        failed = _delete_batch_with_recovery(client, bucket_name, batch, eligible_recovery,
                                              attempts=max(1, min(profile.max_attempts, 5)))
        with counter_lock:
            deleted_count += len(batch) - len(failed)
            failure_count += len(failed)
            for entry, message in failed:
                if len(errors) < 20:
                    errors.append(f"{entry['Key']}: {message}")

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = []
        batch: list[dict[str, Any]] = []
        for entry in _iter_entries():
            batch.append(entry)
            if len(batch) >= batch_size:
                futures.append(pool.submit(delete_batch, list(batch)))
                if len(futures) >= max_workers * 2:
                    futures.pop(0).result()
                batch.clear()
                if deletion_delay_ms > 0:
                    time.sleep(deletion_delay_ms / 1000.0)
        if batch:
            futures.append(pool.submit(delete_batch, list(batch)))
        for future in as_completed(futures):
            future.result()

    duration_seconds = time.monotonic() - started
    lines = [
        f"Bucket: {bucket_name}",
        f"Prefix: {prefix}",
        f"Listing mode: {'versions' if used_versions else 'objects'}",
        f"Batch size: {batch_size}",
        f"Workers: {max_workers}",
        f"Empty PUT recovery eligible: {eligible_recovery}",
        f"Deleted: {deleted_count}",
        f"Failures: {failure_count}",
        f"Duration: {duration_seconds:.2f}s",
    ]
    lines.extend(f"Error: {message}" for message in errors)
    if abort_message:
        lines.append(f"Error: {abort_message}")
    state = _tool_state(
        "delete-all",
        f"Deleted {deleted_count} object version(s) from {bucket_name}."
        if failure_count == 0
        else f"Deleted {deleted_count} object version(s) from {bucket_name} with {failure_count} failure(s).",
        lines,
    )
    if failure_count > 0 or abort_message:
        state["exitCode"] = 1
    return state


def _cancel_tool_execution(params: dict[str, Any]) -> dict[str, Any]:
    # Tool executions (runPutTestData / runDeleteAll) run synchronously and have
    # already returned their final state by the time the desktop host can send a
    # cancel. The job id is only minted at completion, so there is no live loop
    # to interrupt. Report an honest no-op rather than fabricating a cancel.
    job_id = str(params.get("jobId", "")).strip()
    return {
        "label": job_id or "tool",
        "running": False,
        "lastStatus": "Tool execution is not cancellable; it runs to completion synchronously.",
        "jobId": job_id,
        "cancellable": False,
        "outputLines": [
            f"No running tool execution to cancel for job id '{job_id}'.",
        ],
        "exitCode": 0,
    }


def _runtime_dir() -> Path:
    path = Path(tempfile.gettempdir()) / "object-data-browser-python-engine"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _benchmark_state_path(run_id: str) -> Path:
    if not re.fullmatch(r"bench-[a-zA-Z0-9_-]+", run_id):
        raise SidecarError("invalid_config", "Invalid benchmark identifier.")
    return _runtime_dir() / f"benchmark-{run_id}.json"


def _read_benchmark_state(run_id: str) -> dict[str, Any]:
    path = _benchmark_state_path(run_id)
    if not path.exists():
        raise SidecarError("invalid_config", f"Benchmark run {run_id} was not found.")
    state = json.loads(path.read_text())
    if 'historyTotals' in state:
        _restore_benchmark_history(state)
    public = _public_benchmark(state)
    if public != state:
        _write_benchmark_state(public)
    return public


def _write_benchmark_state(state: dict[str, Any]) -> None:
    path = _benchmark_state_path(str(state["id"]))
    temporary = path.with_suffix(f".{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as output:
            os.chmod(temporary, 0o600)
            json.dump(_public_benchmark(state), output)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _scrub_legacy_benchmark_artifacts():
    for path in _runtime_dir().glob('benchmark-bench-*.json'):
        try:
            if path.is_symlink() or not path.is_file(): continue
            if hasattr(os, 'getuid') and path.stat().st_uid != os.getuid(): continue
            state = json.loads(path.read_text())
            if path.name != f"benchmark-{state.get('id')}.json": continue
            public = _public_benchmark(state)
            if state == public: continue
            if public.get('status') in {'running', 'paused'}:
                public['status'] = 'paused'
                public['requiresReauthorization'] = True
            _write_benchmark_state(public)
        except (OSError, ValueError, TypeError, SidecarError):
            # Do not inspect foreign or malformed artifacts further, and never
            # print their contents into diagnostics.
            continue


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
    merged['enableApiLogging'] = bool(config.get('debugMode')) and not bool(config.get('reducedLogging'))
    merged['enableDebugLogging'] = bool(config.get('debugMode')) and not bool(config.get('reducedLogging'))
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


def _append_benchmark_log(state: dict[str, Any], line: str, routine: bool = False) -> None:
    if routine and (state.get('config') or {}).get('reducedLogging'):
        return
    log = [str(item) for item in state.get("liveLog", [])]
    log.append(line)
    state["liveLog"] = log[-60:]


def _benchmark_size_list(config: dict[str, Any]) -> list[int]:
    sizes = [int(item) for item in config.get("objectSizes", []) if int(item) > 0]
    return sizes or [4096]


def _benchmark_config_with_run_dir(config: dict[str, Any], run_id: str) -> dict[str, Any]:
    """Redirect output artifacts into a per-run folder named after the run id so
    repeated Start presses never overwrite an earlier run's results."""
    updated = dict(config)
    for key, default_name in (
        ("csvOutputPath", "benchmark-results.csv"),
        ("jsonOutputPath", "benchmark-results.json"),
        ("logFilePath", "benchmark.log"),
    ):
        raw = str(updated.get(key) or "").strip() or default_name
        path = Path(raw)
        if path.parent.name != run_id:
            updated[key] = str(path.parent / run_id / path.name)
    return updated


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
    config = state.get("config") or {}
    mode = str(config.get("workloadType", "mixed"))
    if mode == "write-only":
        return "PUT"
    if mode == "read-only":
        return "GET"
    if mode == "custom":
        ratios = [(operation, max(0, int(config.get(field) or 0))) for operation, field in
                  (("PUT", "writePercent"), ("GET", "readPercent"), ("DELETE", "deletePercent"))]
    else:
        ratios = _benchmark_ratios(mode)
    total = sum(weight for _, weight in ratios)
    if total <= 0:
        return "PUT"
    slot = int(state.get("processedCount", 0) or 0) % total
    cumulative = 0
    for operation, ratio in ratios:
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
    return max(1, min(active_count, max(int(config.get("concurrentThreads", 1) or 1), 2), int(config.get("operationBudget") or 1000), 1000))


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
    elapsed_seconds = max(float(state.get('activeElapsedSeconds') or 0),
                          max((float(item.get('elapsedMs') or 0) / 1000 for item in history), default=0))
    totals = state.get('historyTotals')
    operations_by_type = dict(totals['operationsByType']) if totals else _benchmark_operations_from_history(history)
    latency_values = [float(item.get("latencyMs", 0) or 0) for item in history]
    checksum_stats = {"validated_success": 0, "validated_failure": 0, "not_used": 0}
    for record in history:
        checksum_state = str(record.get("checksumState", "not_used"))
        if checksum_state not in checksum_stats:
            checksum_stats[checksum_state] = 0
        checksum_stats[checksum_state] += _benchmark_operation_count(record)
    if totals:
        checksum_stats = dict(totals['checksumStats'])

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

    latency_timeline: list[dict[str, Any]] = []
    for sequence, record in enumerate(history, start=1):
        second = max(int(record.get("second", 1) or 1), 1)
        measured = record.get('elapsedMs') is not None
        # Older saved runs have only a one-second bucket. Keep that explicitly
        # coarse instead of fabricating evenly spaced completion timestamps.
        elapsed_ms = float(record['elapsedMs']) if measured else (second - 1) * 1000.0
        latency_timeline.append(
            {
                "sequence": int(record.get('sequence') or sequence),
                "operation": str(record.get("operation", "")).upper(),
                "second": second,
                "elapsedMs": elapsed_ms,
                "label": _benchmark_timeline_label(elapsed_ms / 1000),
                "timingPrecision": "measured" if measured else "second",
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
    total_operations = int(totals['operationCount']) if totals else sum(_benchmark_operation_count(item) for item in history)
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
                "avgOpsPerSecond": round(count / elapsed_seconds, 1) if elapsed_seconds > 0 else 0.0,
                "peakOpsPerSecond": max(per_window) if per_window else 0,
                "p50LatencyMs": latency_percentiles["p50"],
                "p95LatencyMs": latency_percentiles["p95"],
                "p99LatencyMs": latency_percentiles["p99"],
            }
        )

    total_bytes = int(totals['bytesTransferred']) if totals else sum(int(item.get('bytesTransferred') or 0) for item in history)
    average_bytes = (total_bytes
                     / elapsed_seconds) if elapsed_seconds > 0 else 0.0
    peak_bytes = max(
        [int(item.get("bytesPerSecond", 0) or 0) for item in throughput_series] or [0]
    )
    average_ops = total_operations / elapsed_seconds if elapsed_seconds > 0 else 0.0
    peak_ops = max([int(item.get("opsPerSecond", 0) or 0) for item in throughput_series] or [0])
    size_list = _benchmark_size_list(config)
    average_object_size = int(sum(size_list) / max(len(size_list), 1))
    failures = int(totals['errorCount']) if totals else len([item for item in history if not bool(item.get("success", True))])

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
            "activeElapsedSeconds": elapsed_seconds,
            "historyLimit": _BENCHMARK_HISTORY_LIMIT,
            "historyRecordCount": int(totals['records']) if totals else len(history),
            "retainedHistoryRecords": len(history),
            "latencyPercentileScope": 'recent-records' if totals and totals['records'] > len(history) else 'all-records',
            "peakThroughputScope": 'recent-records' if totals and totals['records'] > len(history) else 'all-records',
            "totalBytesTransferred": total_bytes,
            "averageOpsPerSecond": round(average_ops, 1),
            "peakOpsPerSecond": peak_ops,
            "averageBytesPerSecond": round(average_bytes, 1),
            "peakBytesPerSecond": peak_bytes,
            "averageObjectSizeBytes": average_object_size,
            "checksumValidated": checksum_stats.get("validated_success", 0),
            "errorCount": failures,
            "retryCount": int(totals['retryCount']) if totals else sum(int(item.get('retryCount') or 0) for item in history),
            "dataMode": 'memory' if config.get('inMemoryData', True) else 'file',
            "dataCacheMb": max(0, int(config.get('dataCacheMb') or 0)),
            "checksumAlgorithm": config.get('checksumAlgorithm') or 'sha256',
            "runMode": config.get("testMode", "duration"),
            "workloadType": config.get("workloadType", "mixed"),
            "bucket": config.get("bucketName", ""),
            "prefix": config.get("prefix", ""),
        },
        "operationDetails": operation_details,
    }


_BENCHMARK_HISTORY_LIMIT = 10000
_BENCHMARK_CSV_FIELDS = ('sequence', 'timestamp', 'elapsedMs', 'second', 'operation',
                         'operationCount', 'latencyMs', 'sizeBytes', 'bytesTransferred',
                         'success', 'checksumState', 'retryCount', 'errorCode', 'key')


def _benchmark_empty_totals():
    return {'records': 0, 'operationCount': 0, 'operationsByType': {},
            'bytesTransferred': 0, 'totalLatencyMs': 0.0, 'errorCount': 0, 'retryCount': 0,
            'checksumStats': {'validated_success': 0, 'validated_failure': 0, 'not_used': 0}}


def _benchmark_accumulate(totals, row):
    count = _benchmark_operation_count(row)
    totals['records'] += 1
    totals['operationCount'] += count
    operation = str(row.get('operation') or '').upper()
    totals['operationsByType'][operation] = totals['operationsByType'].get(operation, 0) + count
    totals['bytesTransferred'] += int(row.get('bytesTransferred') or 0)
    totals['totalLatencyMs'] += float(row.get('latencyMs') or 0)
    totals['errorCount'] += int(not bool(row.get('success', True)))
    totals['retryCount'] += int(row.get('retryCount') or 0)
    checksum = str(row.get('checksumState') or 'not_used')
    totals['checksumStats'][checksum] = totals['checksumStats'].get(checksum, 0) + count


def _benchmark_write_csv_rows(output, rows, header=False):
    writer = csv.DictWriter(output, fieldnames=_BENCHMARK_CSV_FIELDS, extrasaction='ignore')
    if header:
        writer.writeheader()
    for row in rows:
        writer.writerow({**row, 'success': 'true' if row.get('success', True) else 'false'})


def _prepare_benchmark_history(state):
    path = Path(state['config']['csvOutputPath'])
    path.parent.mkdir(parents=True, exist_ok=True)
    if 'historyTotals' in state:
        if not path.exists():
            raise SidecarError('invalid_config', 'The benchmark CSV history is missing; start a new run.')
        return
    totals = _benchmark_empty_totals()
    rows = state.get('history') or []
    for row in rows:
        _benchmark_accumulate(totals, row)
        row['sequence'] = totals['records']
    with path.open('w', encoding='utf-8', newline='') as output:
        os.chmod(path, 0o600)
        _benchmark_write_csv_rows(output, rows, header=True)
    state['historyTotals'] = totals
    state['history'] = rows[-_BENCHMARK_HISTORY_LIMIT:]
    state['processedCount'] = totals['operationCount']


def _append_benchmark_history(state, rows):
    if not rows:
        return
    totals = state['historyTotals']
    for row in rows:
        _benchmark_accumulate(totals, row)
        row['sequence'] = totals['records']
    # Append every measured row before a bounded state checkpoint can drop it.
    # CSV quoting preserves keys containing commas, quotes or line breaks.
    with Path(state['config']['csvOutputPath']).open('a', encoding='utf-8', newline='') as output:
        _benchmark_write_csv_rows(output, rows)
    state['history'].extend(rows)
    if len(state['history']) > _BENCHMARK_HISTORY_LIMIT:
        del state['history'][:-_BENCHMARK_HISTORY_LIMIT]
    state['processedCount'] = totals['operationCount']


def _restore_benchmark_history(state):
    path = Path(state['config']['csvOutputPath'])
    if not path.exists():
        raise SidecarError('invalid_config', 'The benchmark CSV history is missing; start a new run.')
    totals, recent = _benchmark_empty_totals(), deque(maxlen=_BENCHMARK_HISTORY_LIMIT)
    elapsed_ms = 0.0
    try:
        with path.open(encoding='utf-8', newline='') as source:
            reader = csv.DictReader(source)
            if tuple(reader.fieldnames or ()) != _BENCHMARK_CSV_FIELDS:
                raise ValueError('Unexpected benchmark CSV schema')
            for raw in reader:
                row = {key: raw[key] for key in ('timestamp', 'operation', 'checksumState', 'errorCode', 'key')}
                for key in ('sequence', 'second', 'operationCount', 'sizeBytes', 'bytesTransferred', 'retryCount'):
                    row[key] = int(raw[key] or 0)
                row['latencyMs'] = float(raw['latencyMs'] or 0)
                if raw['elapsedMs']:
                    row['elapsedMs'] = float(raw['elapsedMs'])
                if raw['success'] not in {'true', 'false'} or row['sequence'] != totals['records'] + 1:
                    raise ValueError('Incomplete benchmark CSV row')
                row['success'] = raw['success'] == 'true'
                _benchmark_accumulate(totals, row)
                recent.append(row)
                elapsed_ms = max(elapsed_ms, row.get('elapsedMs', 0))
    except (ValueError, TypeError, KeyError, csv.Error) as error:
        raise SidecarError('invalid_config', 'Benchmark CSV history is incomplete; inspect the export before starting a new run.') from error
    if totals['records'] < int(state['historyTotals'].get('records') or 0):
        raise SidecarError('invalid_config', 'Benchmark CSV history is shorter than its checkpoint; start a new run.')
    state['historyTotals'] = totals
    state['history'] = list(recent)
    state['processedCount'] = totals['operationCount']
    state['activeElapsedSeconds'] = max(float(state.get('activeElapsedSeconds') or 0), elapsed_ms / 1000)
    _refresh_benchmark_snapshot(state)


def _persist_benchmark_outputs(state: dict[str, Any]) -> None:
    config = dict(state.get("config") or {})
    csv_path = Path(str(config.get("csvOutputPath", "benchmark-results.csv")))
    json_path = Path(str(config.get("jsonOutputPath", "benchmark-results.json")))
    log_path = Path(str(config.get("logFilePath", "benchmark.log")))
    for path in (csv_path, json_path, log_path):
        path.parent.mkdir(parents=True, exist_ok=True)

    if 'historyTotals' not in state:
        with csv_path.open('w', encoding='utf-8', newline='') as output:
            _benchmark_write_csv_rows(output, state.get('history') or [], header=True)
    json_path.write_text(json.dumps(state.get("resultSummary"), indent=2))
    log_path.write_text("\n".join(str(item) for item in state.get("liveLog", [])))


class _BenchmarkPayloadStore:
    """Bounded deterministic payload cache; large/file-mode bodies are streamed."""
    def __init__(self, config):
        self.limit = min(1024, max(0, int(config.get('dataCacheMb') or 0))) * 1024**2
        self.memory = bool(config.get('inMemoryData', True))
        self.cache = OrderedDict()
        self.bytes = 0
        self.lock = threading.RLock()

    @contextmanager
    def body(self, run_id, key, size, random_data):
        identity = (run_id if random_data else '', key if random_data else '', size)
        if self.memory and size <= min(self.limit, 128 * 1024**2):
            with self.lock:
                data = self.cache.get(identity)
                if data is None:
                    data = _benchmark_payload_bytes(run_id, key, size, random_data)
                    while self.bytes + size > self.limit and self.cache:
                        _, old = self.cache.popitem(last=False)
                        self.bytes -= len(old)
                    self.cache[identity] = data
                    self.bytes += size
                else:
                    self.cache.move_to_end(identity)
            yield data
            return
        if self.memory and size <= 8 * 1024**2:
            yield _benchmark_payload_bytes(run_id, key, size, random_data)
            return
        # Generate repeated payload blocks without allocating object-size RAM.
        with tempfile.TemporaryFile('w+b') as temporary:
            for block in _benchmark_payload_chunks(run_id, key, size, random_data):
                temporary.write(block)
            temporary.seek(0)
            yield _FilePart(temporary, 0, size)


def _benchmark_payload_chunks(run_id, key, size, random_data, chunk=1024**2):
    if not random_data:
        pattern = b'A'
    else:
        seed = f'{run_id}:{key}:{size}'.encode() or b's3-benchmark'
        length = min(max(len(seed) * 8, 64), 4096)
        pattern = bytes((seed[index % len(seed)] + index * 17) % 256 for index in range(length))
    for offset in range(0, size, chunk):
        length = min(chunk, size - offset)
        start = offset % len(pattern)
        yield (pattern * ((start + length + len(pattern) - 1) // len(pattern)))[start:start + length]


class _BenchmarkCrc:
    def __init__(self, castagnoli=False):
        self.castagnoli = castagnoli
        self.value = 0
        if castagnoli:
            table = []
            for index in range(256):
                crc = index
                for _ in range(8): crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
                table.append(crc)
            self.table = table

    def update(self, data):
        if not self.castagnoli:
            import zlib
            self.value = zlib.crc32(data, self.value)
        else:
            crc = self.value ^ 0xFFFFFFFF
            for byte in data: crc = self.table[(crc ^ byte) & 255] ^ (crc >> 8)
            self.value = crc ^ 0xFFFFFFFF

    def digest(self): return self.value.to_bytes(4, 'big')


def _benchmark_digest(algorithm):
    algorithm = str(algorithm or 'sha256').lower().replace('-', '')
    if algorithm == 'crc32': return _BenchmarkCrc()
    if algorithm == 'crc32c':
        try:
            import google_crc32c
            return google_crc32c.Checksum()
        except ImportError:
            return _BenchmarkCrc(castagnoli=True)
    if algorithm not in {'sha256', 'sha1', 'md5'}:
        raise SidecarError('invalid_config', 'Benchmark checksum algorithm must be crc32c, crc32, sha256, sha1 or md5.')
    return hashlib.new(algorithm)


class _BenchmarkMeteredClient:
    def __init__(self, client, state):
        self.client, self.state = client, state

    def __getattr__(self, name):
        target = getattr(self.client, name)
        def call(**kwargs):
            self.state['_operationContext'] = {'operation': {'put_object': 'PUT', 'get_object': 'GET', 'delete_object': 'DELETE', 'delete_objects': 'DELETE'}.get(name, name),
                                                'key': kwargs.get('Key', ''), 'sizeBytes': len(kwargs.get('Body', b''))}
            try:
                result = target(**kwargs)
            except Exception as error:
                response = getattr(error, 'response', {})
                self.state['_retryCount'] += int((response.get('ResponseMetadata') or {}).get('RetryAttempts') or 0)
                raise
            if isinstance(result, dict):
                self.state['_retryCount'] += int((result.get('ResponseMetadata') or {}).get('RetryAttempts') or 0)
            return result
        return call


def _run_benchmark_operation(state, client):
    state['_retryCount'] = 0
    started = time.perf_counter()
    previous = len(state.get('history') or [])
    try:
        _run_benchmark_operation_impl(state, _BenchmarkMeteredClient(client, state))
    except Exception as error:
        if len(state.get('history') or []) == previous:
            state.setdefault('history', []).append({
                **state.get('_operationContext', {'operation': 'UNKNOWN', 'key': '', 'sizeBytes': 0}),
                'timestamp': _now_iso(), 'second': int(state.get('activeElapsedSeconds') or 0) + 1,
                'latencyMs': (time.perf_counter() - started) * 1000, 'bytesTransferred': 0,
                'success': False, 'checksumState': 'not_used', 'operationCount': 1,
                'retryCount': state['_retryCount'], 'errorCode': _map_exception(error).code})
        raise
    finally:
        # Checksum validation records the completed GET before raising. Meter
        # that existing failure record too, without adding a second operation.
        if len(state.get('history') or []) > previous:
            record = state['history'][-1]
            record['retryCount'] = state['_retryCount']
            owner = _BENCHMARKS.get(state.get('id'))
            if owner:
                with owner.lock:
                    completed_elapsed = owner.elapsed()
            else:
                completed_elapsed = max(0, float(state.get('activeElapsedSeconds') or 0)) + max(0, time.perf_counter() - started)
            record['elapsedMs'] = completed_elapsed * 1000
            record['second'] = int(completed_elapsed) + 1
            record['timestamp'] = _now_iso()
        state.pop('_operationContext', None)
        state.pop('_retryCount', None)


def _run_benchmark_operation_impl(state: dict[str, Any], client: Any) -> None:
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
        owner = _BENCHMARKS.get(state['id'])
        store = owner.payload_store if owner else _BenchmarkPayloadStore(config)
        with store.body(str(state['id']), key, size_bytes, bool(config.get('randomData', True))) as payload:
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
                _run_benchmark_operation_impl(state, client)
                return
            raise
        digest = _benchmark_digest(config.get('checksumAlgorithm')) if checksum_enabled else None
        try:
            for block in iter(lambda: response['Body'].read(1024**2), b''):
                bytes_transferred += len(block)
                if digest is not None: digest.update(block)
        finally:
            response['Body'].close()
        latency_ms = (time.perf_counter() - started_at) * 1000
        if checksum_enabled:
            expected = _benchmark_digest(config.get('checksumAlgorithm'))
            for block in _benchmark_payload_chunks(str(state['id']), key, size_bytes, bool(config.get('randomData', True))):
                expected.update(block)
            checksum_state = 'validated_success' if bytes_transferred == size_bytes and digest.digest() == expected.digest() else 'validated_failure'
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
                _run_benchmark_operation_impl(state, client)
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
                    _run_benchmark_operation_impl(state, client)
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
            "success": checksum_state != 'validated_failure',
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
            routine=True,
        )
    else:
        _append_benchmark_log(
            state,
            f"{operation} {key} completed in {round(latency_ms, 1)} ms.",
            routine=True,
        )
    if checksum_state == 'validated_failure':
        raise SidecarError('checksum_mismatch', 'Benchmark download checksum validation failed.')


def _refresh_benchmark_snapshot(state: dict[str, Any]) -> None:
    summary = _rebuild_benchmark_summary(state)
    state["resultSummary"] = summary
    history = [dict(item) for item in state.get("history", [])]
    latency_values = [float(item.get("latencyMs", 0) or 0) for item in history]
    state["averageLatencyMs"] = (
        round(sum(latency_values) / max(len(latency_values), 1), 1)
        if latency_values
        else 0.0
    )
    if state.get('historyTotals', {}).get('records'):
        totals = state['historyTotals']
        state['averageLatencyMs'] = round(totals['totalLatencyMs'] / totals['records'], 1)
    state["throughputOpsPerSecond"] = summary['detailMetrics']['averageOpsPerSecond']


_BENCHMARKS = {}
_BENCHMARKS_LOCK = threading.RLock()
_PROFILE_PUBLIC_FIELDS = {'id', 'name', 'endpointType', 'region', 'pathStyle', 'verifyTls', 'authMode', 'awsProfileName', 'knownBucket', 'requesterPays', 'expectedBucketOwner'}


def _public_benchmark(state):
    public = dict(state)
    public['profile'] = {k: v for k, v in (state.get('profile') or {}).items() if k in _PROFILE_PUBLIC_FIELDS}
    return json.loads(json.dumps(public, default=_serialize_dt))


class _BenchmarkRun:
    def __init__(self, state, profile):
        self.state = state
        self.profile = profile
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.wake = threading.Event()
        self.wake.set()
        self.reserved = 0
        self.last_persisted = 0.0
        self.threads = []
        self.payload_store = _BenchmarkPayloadStore(state['config'])
        # Monotonic anchors are process-local and never enter saved state.
        self.elapsed_base = max(0, float(state.get('activeElapsedSeconds') or 0))
        self.elapsed_anchor = time.monotonic() if state['status'] == 'running' else None

    def elapsed(self):
        return self.elapsed_base + (max(0, time.monotonic() - self.elapsed_anchor)
                                    if self.elapsed_anchor is not None else 0)

    def update_clock(self):
        now = time.monotonic()
        if self.elapsed_anchor is not None:
            self.elapsed_base += max(0, now - self.elapsed_anchor)
        # Pausing stops dispatch immediately; in-flight work still counts as
        # active time until it drains. Idle paused time is excluded on resume.
        self.elapsed_anchor = now if self.state['status'] == 'running' or self.reserved else None
        self.state['activeElapsedSeconds'] = self.elapsed_base
        self.state['lastUpdatedAt'] = _now_iso()
        return self.elapsed_base

    def start(self):
        profile = _benchmark_profile(self.profile, self.state['config'])
        self.client = _AzureBenchmarkClient(profile) if profile.endpoint_type == 'azureBlob' else _build_client(profile)
        self.profile = {}
        workers = min(32, max(1, int(self.state['config'].get('concurrentThreads') or 1)))
        for index in range(workers):
            worker = threading.Thread(target=self.run, args=(index,), daemon=True)
            self.threads.append(worker)
            worker.start()

    def snapshot(self, persist=False):
        with self.lock:
            self.update_clock()
            _refresh_benchmark_snapshot(self.state)
            public = _public_benchmark(self.state)
            if persist:
                _write_benchmark_state(public)
                _persist_benchmark_outputs(public)
            return public

    def run(self, index):
        lane = _public_benchmark(self.state)
        lane['benchmarkPrefix'] += f'worker-{index}/'
        try:
            client = self.client
            while True:
                self.wake.wait(0.25)
                with self.lock:
                    state = self.state
                    if state['status'] in {'completed', 'stopped', 'failed'}: return
                    if state['status'] == 'paused': continue
                    elapsed = self.update_clock()
                    config = state['config']
                    operation_mode = config.get('testMode') == 'operation-count'
                    remaining = max(0, int(config.get('operationCount') or 1000) - state['processedCount'] - self.reserved) if operation_mode else 1000
                    expired = not operation_mode and elapsed >= max(1, int(config.get('durationSeconds') or 60))
                    if expired and self.reserved:
                        self.condition.wait(0.1)
                        continue
                    if expired or (remaining == 0 and self.reserved == 0):
                        state['status'] = 'completed'
                        state['completedAt'] = _now_iso()
                        state['activeElapsedSeconds'] = elapsed
                        self.snapshot(persist=True)
                        return
                    if remaining == 0:
                        self.condition.wait(0.1)
                        continue
                    reserve = min(remaining, _benchmark_delete_batch_size(config, len(lane.get('activeObjects', [])))) if _benchmark_operation_for_index(lane) == 'DELETE' else 1
                    self.reserved += reserve
                    lane['config']['operationBudget'] = reserve
                    lane['activeElapsedSeconds'] = elapsed
                    lane['history'] = []
                try:
                    _run_benchmark_operation(lane, client)
                except BaseException:
                    with self.lock:
                        self.reserved -= reserve
                        self.update_clock()
                        _append_benchmark_history(state, lane['history'])
                        self.condition.notify_all()
                    raise
                with self.lock:
                    self.reserved -= reserve
                    self.update_clock()
                    self.condition.notify_all()
                    _append_benchmark_history(state, lane['history'])
                    lane['processedCount'] = state['processedCount']
                    if lane.get('liveLog') and not config.get('reducedLogging'): _append_benchmark_log(state, lane['liveLog'][-1])
                    if time.monotonic() - self.last_persisted >= 0.5:
                        self.last_persisted = time.monotonic()
                        self.snapshot(persist=True)
        except Exception as error:
            with self.lock:
                if self.state['status'] != 'stopped': self.state['status'] = 'failed'
                self.state['completedAt'] = _now_iso()
                # Do not serialize exception text; authentication errors can embed tokens.
                _append_benchmark_log(self.state, f'Benchmark failed ({_map_exception(error).code}).')
                self.snapshot(persist=True)
        finally:
            with self.lock:
                if self.state['status'] in {'completed', 'stopped', 'failed'}:
                    self.profile = {}


def _materialize_benchmark_state(state):
    # Status reads never execute workload requests.
    with _BENCHMARKS_LOCK: run = _BENCHMARKS.get(str(state['id']))
    if run: return run.snapshot()
    if state.get('status') in {'running', 'paused'}:
        state['status'] = 'paused'
        state['requiresReauthorization'] = True
        _append_benchmark_log(state, 'Owning engine stopped. Resume explicitly to authorize a new worker.')
        _write_benchmark_state(state)
    return _public_benchmark(state)


def _start_benchmark(params):
    profile = dict(params.get('profile') or {})
    if not profile: raise SidecarError('invalid_config', 'Profile configuration is required for benchmark runs.')
    _parse_profile(profile)
    run_id = f'bench-{uuid.uuid4().hex[:8]}'
    config = _benchmark_config_with_run_dir(dict(params.get('config') or {}), run_id)
    if not config.get('bucketName'): raise SidecarError('invalid_config', 'A benchmark bucket is required.')
    if any(size > 5 * 1024**3 for size in _benchmark_size_list(config)):
        raise SidecarError('invalid_config', 'Single-request benchmark objects cannot exceed 5 GiB.')
    if config.get('validateChecksum', True): _benchmark_digest(config.get('checksumAlgorithm'))
    if not 0 <= int(config.get('dataCacheMb') or 0) <= 1024:
        raise SidecarError('invalid_config', 'Benchmark data cache must be between 0 and 1024 MiB.')
    state = {'id': run_id, 'profile': {k: v for k, v in profile.items() if k in _PROFILE_PUBLIC_FIELDS},
             'config': config, 'status': 'running', 'processedCount': 0,
             'startedAt': _now_iso(), 'completedAt': None, 'lastUpdatedAt': _now_iso(),
             'activeElapsedSeconds': 0.0, 'averageLatencyMs': 0, 'throughputOpsPerSecond': 0,
             'liveLog': ['Benchmark started.'], 'resultSummary': None, 'history': [],
             'activeObjects': [], 'nextObjectIndex': 0, 'nextActiveIndex': 0, 'nextSizeIndex': 0,
             'benchmarkPrefix': _benchmark_base_prefix(config, run_id)}
    run = _BenchmarkRun(state, profile)
    _prepare_benchmark_history(state)
    with _BENCHMARKS_LOCK: _BENCHMARKS[run_id] = run
    result = run.snapshot(persist=True)
    run.start()
    return result


def _get_benchmark_status(params):
    run_id = str(params.get('runId') or '')
    with _BENCHMARKS_LOCK: run = _BENCHMARKS.get(run_id)
    return run.snapshot() if run else _materialize_benchmark_state(_read_benchmark_state(run_id))


def _benchmark_control(params, status):
    run_id = str(params.get('runId') or '')
    with _BENCHMARKS_LOCK: run = _BENCHMARKS.get(run_id)
    if run is None:
        state = _read_benchmark_state(run_id)
        if status == 'running':
            profile = dict(params.get('profile') or {})
            _parse_profile(profile)
            state['requiresReauthorization'] = False
            state['status'] = 'running'
            state['lastUpdatedAt'] = _now_iso()
            # New namespace prevents accidental overlap with an interrupted worker.
            state['benchmarkPrefix'] += f'resumed-{uuid.uuid4().hex[:8]}/'
            run = _BenchmarkRun(state, profile)
            _prepare_benchmark_history(state)
            with _BENCHMARKS_LOCK: _BENCHMARKS[run_id] = run
            run.start()
        else:
            state['status'] = status
            _write_benchmark_state(state)
            return _public_benchmark(state)
    with run.lock:
        if run.state['status'] in {'completed', 'failed', 'stopped'}: return run.snapshot()
        run.update_clock()
        run.state['status'] = status
        run.state['lastUpdatedAt'] = _now_iso()
        if status == 'paused': run.wake.clear()
        else: run.wake.set()
        if status == 'stopped': run.state['completedAt'] = _now_iso()
        return run.snapshot(persist=True)


def _pause_benchmark(params): return _benchmark_control(params, 'paused')
def _resume_benchmark(params): return _benchmark_control(params, 'running')
def _stop_benchmark(params): return _benchmark_control(params, 'stopped')


def _export_benchmark_results(params):
    state = _get_benchmark_status(params)
    _persist_benchmark_outputs(state)
    format_name = str(params.get('format') or 'csv')
    return {'format': format_name, 'path': state['config'].get('csvOutputPath' if format_name == 'csv' else 'jsonOutputPath'), 'summary': state.get('resultSummary')}


# Recovery manifests contain object/file identity and multipart checkpoints only.
# Credentials are re-supplied by the host for every explicit recovery request.
def _recovery_dir():
    path = Path(os.environ.get('OBJECT_BROWSER_TRANSFER_DIR') or (Path.home() / '.object-data-browser' / 'transfers'))
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def _recovery_path(recovery_id):
    if not re.fullmatch(r'upload-[a-f0-9]{32}', str(recovery_id)):
        raise SidecarError('invalid_config', 'Invalid transfer recovery identifier.')
    return _recovery_dir() / f'{recovery_id}.json'


def _recovery_write(state):
    state['updatedAt'] = _now_iso()
    path = _recovery_path(state['id'])
    temporary = path.with_suffix(f'.{uuid.uuid4().hex}.tmp')
    try:
        with temporary.open('x', encoding='utf-8') as output:
            os.chmod(temporary, 0o600)
            json.dump(state, output)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def _recovery_lock(recovery_id):
    path = _recovery_path(recovery_id).with_suffix('.lock')
    with path.open('a+b') as handle:
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
        except (OSError, BlockingIOError) as error:
            raise SidecarError('conflict', 'This recovery upload is already active in another request.') from error
        try:
            yield
        finally:
            if os.name == 'nt':
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _file_identity(path):
    stat = path.stat()
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''): digest.update(block)
    after = path.stat()
    if (stat.st_size, stat.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise SidecarError('conflict', 'Source file changed while computing its identity.')
    return {'size': stat.st_size, 'modifiedNs': stat.st_mtime_ns, 'sha256': digest.hexdigest()}


def _recovery_profile_ref(payload):
    reference = {k: payload.get(k) for k in ('id', 'endpointUrl', 'endpointType', 'region', 'pathStyle')}
    endpoint = urlparse(str(reference.get('endpointUrl') or ''))
    reference['endpointUrl'] = endpoint._replace(netloc=endpoint.netloc.rsplit('@', 1)[-1], query='', fragment='').geturl()
    return reference


def _recovery_public(state):
    return {k: v for k, v in state.items() if k not in {'options', 'parts'}}


def _recovery_verify_completion(state, client):
    try:
        head = client.head_object(Bucket=state['bucketName'], Key=state['key'], **({'VersionId': state['versionId']} if state.get('versionId') else {}))
    except Exception:
        return False
    metadata = head.get('Metadata') or {}
    if int(head.get('ContentLength') or 0) == state['fileSize'] and metadata.get('object-browser-recovery-id') == state['id'] and metadata.get('object-browser-source-sha256') == state['sourceIdentity']['sha256']:
        state.update({'status': 'completed', 'completedBytes': state['fileSize'], 'requiresVerification': False,
                      'versionId': head.get('VersionId'), 'ownerPid': None})
        _recovery_write(state)
        return True
    return False


def _transfer_recovery_action(params):
    action = params['action']
    profile_payload = params.get('profile') or {}
    profile = _parse_profile(profile_payload)
    reference = _recovery_profile_ref(profile_payload)
    if action == 'listTransferRecovery':
        items = []
        for path in _recovery_dir().glob('*.json'):
            try:
                state = json.loads(path.read_text())
                if state.get('profileRef') != reference: continue
                if params.get('bucketName') and state.get('bucketName') != params['bucketName']: continue
                if state.get('id', '').startswith(('upload-', 'azureupload-', 'download-')):
                    items.append({k: v for k, v in state.items() if k not in {'options', 'parts', 'blocks', 'ranges'}})
            except (OSError, ValueError):
                continue
        return {'items': sorted(items, key=lambda item: item.get('updatedAt', ''), reverse=True)}
    if profile.endpoint_type == 'azureBlob':
        return _advanced_workflow(params)
    if action == 'startResumableUpload':
        path = Path(str(params.get('filePath') or '')).expanduser().resolve()
        if not path.is_file(): raise SidecarError('invalid_config', 'An existing local file is required.')
        ref = _object_ref(params)
        identity = _file_identity(path)
        size = identity['size']
        chunk = max(5 * 1024**2, int(params.get('multipartChunkMiB') or 8) * 1024**2, (size + 9999) // 10000)
        if chunk > 5 * 1024**3 or size > 50000 * 1024**3:
            raise SidecarError('invalid_config', 'File exceeds S3 multipart size limits.')
        recovery_id = 'upload-' + uuid.uuid4().hex
        state = {'id': recovery_id, 'recoveryId': recovery_id, 'profileRef': reference, 'bucketName': ref['Bucket'], 'key': ref['Key'],
                 'filePath': str(path), 'fileSize': size, 'sourceIdentity': identity, 'partSize': chunk, 'parts': [],
                 'completedBytes': 0, 'status': 'prepared', 'createdAt': _now_iso(), 'ownerPid': None,
                 'conflictPolicy': params.get('conflictPolicy') or 'replace', 'options': _copy_options({}, params.get('options') or {})}
        if state['conflictPolicy'] not in {'replace', 'overwrite', 'fail', 'skip'}:
            raise SidecarError('invalid_config', 'Conflict policy must be replace, fail, or skip.')
        _recovery_write(state)
    else:
        recovery_id = str(params.get('recoveryId') or '')
        path = _recovery_path(recovery_id)
        if not path.exists(): raise SidecarError('invalid_config', 'Transfer recovery manifest was not found.')
        state = json.loads(path.read_text())
        if state.get('profileRef') != reference:
            raise SidecarError('conflict', 'The selected profile does not match the upload endpoint and profile ID.')
    with _recovery_lock(recovery_id):
        if action != 'startResumableUpload': state = json.loads(_recovery_path(recovery_id).read_text())
        client = _build_client(profile)
        if state['status'] == 'completionUnknown':
            if not _recovery_verify_completion(state, client):
                state['requiresVerification'] = True
                state['error'] = 'Completion outcome is unknown. Inspect the destination and multipart upload before any new upload.'
                _recovery_write(state)
            return _recovery_public(state)
        if state['status'] in {'completed', 'skipped', 'aborted'}:
            return _recovery_public(state)
        if action == 'abortUpload':
            if state.get('uploadId'):
                client.abort_multipart_upload(Bucket=state['bucketName'], Key=state['key'], UploadId=state['uploadId'])
            state.update({'status': 'aborted', 'ownerPid': None})
            _recovery_write(state)
            return _recovery_public(state)
        if state['status'] in {'cancelled', 'failed'}:
            return _recovery_public(state)
        current = _file_identity(Path(state['filePath']))
        if current != state['sourceIdentity']:
            raise SidecarError('conflict', 'Source file identity changed. Abort the old multipart upload before starting a new upload.')
        return _run_transfer(lambda _: _execute_recovery_upload(state, profile, client), params)


def _execute_recovery_upload(state, profile, client):
    ref = {'Bucket': state['bucketName'], 'Key': state['key']}
    size, chunk = state['fileSize'], state['partSize']
    count = max(1, (size + chunk - 1) // chunk)
    control = _register_transfer(TransferControl(job_id=state['id'], label=f"Recoverable upload {state['key']}", direction='upload',
        total_bytes=size, item_count=1, strategy_label='Recoverable multipart upload', part_size_bytes=chunk, parts_total=count))
    state.update({'ownerPid': os.getpid(), 'status': 'uploading'})
    _recovery_write(state)
    def progress():
        _emit_transfer_event(_build_transfer_job(job_id=state['id'], label=control.label, direction='upload', progress=state['completedBytes'] / size if size else 0,
            status='running', bytes_transferred=state['completedBytes'], total_bytes=size, output_lines=[], current_item_label=state['key'],
            item_count=1, items_completed=0, part_size_bytes=chunk, parts_completed=len(state['parts']), parts_total=count, can_pause=True, can_cancel=True))
    progress()
    def heartbeat():
        while True:
            time.sleep(5)
            if _lookup_transfer(state['id']) is not control: return
            progress()
    threading.Thread(target=heartbeat, daemon=True).start()
    try:
        options = dict(state['options'])
        options['Metadata'] = {**options.get('Metadata', {}), 'object-browser-recovery-id': state['id'],
                               'object-browser-source-sha256': state['sourceIdentity']['sha256']}
        conditional = {'IfNoneMatch': '*'} if state['conflictPolicy'] in {'fail', 'skip'} else {}
        if not state.get('uploadId') and state['conflictPolicy'] in {'fail', 'skip'}:
            try:
                client.head_object(**ref)
            except Exception as error:
                if _client_error_code(error) not in {'404', 'NoSuchKey', 'NotFound'}: raise
            else:
                if state['conflictPolicy'] == 'skip':
                    state['status'] = 'skipped'
                    _recovery_write(state)
                    return _recovery_public(state)
                raise SidecarError('conflict', 'Destination already exists.')
        if size == 0:
            state['status'] = 'completionUnknown'
            _recovery_write(state)
            client.put_object(**ref, Body=b'', **options, **conditional)
        else:
            if not state.get('uploadId'):
                response = client.create_multipart_upload(**ref, **options)
                state['uploadId'] = response['UploadId']
                _recovery_write(state)
            remote = {}
            marker = None
            while True:
                response = client.list_parts(**ref, UploadId=state['uploadId'], **({'PartNumberMarker': marker} if marker else {}))
                for part in response.get('Parts', []): remote[int(part['PartNumber'])] = part
                if not response.get('IsTruncated'): break
                next_marker = response.get('NextPartNumberMarker')
                if not next_marker or next_marker == marker: raise SidecarError('conflict', 'Multipart part listing did not progress.')
                marker = next_marker
            # Only reuse parts checkpointed by this app and independently found
            # with the same ETag and length at the endpoint.
            reusable = []
            for part in state['parts']:
                number = part['PartNumber']
                actual = remote.get(number)
                expected_size = min(chunk, size - (number - 1) * chunk)
                if actual and actual.get('ETag') == part['ETag'] and int(actual.get('Size') or 0) == expected_size:
                    reusable.append(part)
            state['parts'] = reusable
            state['completedBytes'] = sum(min(chunk, size - (p['PartNumber'] - 1) * chunk) for p in reusable)
            _recovery_write(state)
            done = {part['PartNumber'] for part in reusable}
            def upload(number):
                _transfer_gate(control)
                with Path(state['filePath']).open('rb') as source:
                    length = min(chunk, size - (number - 1) * chunk)
                    response = client.upload_part(**ref, UploadId=state['uploadId'], PartNumber=number,
                        Body=_FilePart(source, (number - 1) * chunk, length))
                return {'PartNumber': number, 'ETag': response['ETag']}, length
            with ThreadPoolExecutor(max_workers=min(8, profile.max_pool_connections)) as pool:
                futures = [pool.submit(upload, n) for n in range(1, count + 1) if n not in done]
                try:
                    for future in as_completed(futures):
                        part, length = future.result()
                        state['parts'].append(part)
                        state['completedBytes'] += length
                        _recovery_write(state)
                        _transfer_checkpoint(control, bytes_transferred=state['completedBytes'], items_completed=0, parts_completed=len(state['parts']), current_item_label=state['key'])
                        progress()
                except BaseException:
                    for pending in futures: pending.cancel()
                    raise
            _transfer_gate(control)
            if _file_identity(Path(state['filePath'])) != state['sourceIdentity']:
                raise SidecarError('conflict', 'Source file changed during upload.')
            # Persist uncertainty before dispatch. A killed process can never
            # mistakenly replay a possibly successful completion on resume.
            state['status'] = 'completionUnknown'
            _recovery_write(state)
            result = client.complete_multipart_upload(**ref, UploadId=state['uploadId'], MultipartUpload={'Parts': sorted(state['parts'], key=lambda p: p['PartNumber'])}, **conditional)
            state['versionId'] = result.get('VersionId')
        if not _recovery_verify_completion(state, client):
            state['requiresVerification'] = True
            _recovery_write(state)
        return _recovery_public(state)
    except BaseException as error:
        if state['status'] == 'completionUnknown':
            state['requiresVerification'] = not _recovery_verify_completion(state, client)
        else:
            if state.get('uploadId'):
                try:
                    client.abort_multipart_upload(**ref, UploadId=state['uploadId'])
                except Exception:
                    state['cleanupRequired'] = True
            state['status'] = 'cancelled' if isinstance(error, _TransferCancelled) else 'failed'
        state['error'] = 'Upload cancelled.' if isinstance(error, _TransferCancelled) else 'Upload did not finish; inspect its status and cleanup requirement.'
        _recovery_write(state)
        if isinstance(error, _TransferCancelled): return _recovery_public(state)
        if state['status'] == 'completionUnknown': return _recovery_public(state)
        raise
    finally:
        state['ownerPid'] = None
        _recovery_write(state)


# Advanced operations use the same clients and credentials as ordinary browsing.
_STORAGE_ACTIONS = [
    'startResumableUpload', 'resumeUpload', 'listTransferRecovery', 'abortUpload',
    'providerInfo', 'ensureBucket', 'getBucketAdminState', 'getBucketConfiguration', 'putLifecycle', 'getAccess', 'putAccess', 'objectDetails', 'objectTags',
    'objectProperties', 'getObjectProtection', 'setObjectProtection',
    'getBucketProtection', 'setBucketProtection', 'restoreObject',
    'listMultipartUploads', 'listParts', 'abortMultipartUpload', 'copyObject',
    'listObjects', 'listObjectVersions', 'downloadVersion', 'presignVersion', 'deleteVersion',
    'planHistoryCopy', 'resumeHistoryCopy', 'inspectHistoryCopy', 'resolveHistoryCopy',
    'planBucketConfigurationCopy', 'applyBucketConfigurationCopy',
    'startResumableDownload', 'resumeDownload', 'abortDownload',
]

_ADVANCED_MODULE = None


def _advanced_module():
    global _ADVANCED_MODULE
    if _ADVANCED_MODULE is None:
        spec = importlib.util.spec_from_file_location('object_browser_advanced_workflows', Path(__file__).with_name('advanced_workflows.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _ADVANCED_MODULE = module
    return _ADVANCED_MODULE


def _advanced_workflow(params):
    return _advanced_module().handle(params, SimpleNamespace(**globals()))


def _object_ref(params):
    ref = {'Bucket': str(params.get('bucketName') or ''), 'Key': str(params.get('key') or '')}
    if not ref['Bucket'] or not ref['Key']:
        raise SidecarError('invalid_config', 'Bucket name and exact object key are required.')
    if params.get('versionId') is not None:
        ref['VersionId'] = str(params['versionId'])
    return ref


def _clean_sdk(value):
    if isinstance(value, dict):
        return {k: _clean_sdk(v) for k, v in value.items() if k != 'ResponseMetadata'}
    if isinstance(value, list):
        return [_clean_sdk(v) for v in value]
    return _serialize_dt(value) if isinstance(value, datetime) else value


def _configuration_or_missing(fn, missing_codes):
    try:
        return fn()
    except Exception as error:
        if _client_error_code(error) in missing_codes: return {}
        raise


def _storage_action(params):
    action = str(params.get('action') or '')
    if action in _advanced_module().ACTIONS:
        return _advanced_workflow(params)
    if action in {'startResumableUpload', 'resumeUpload', 'listTransferRecovery', 'abortUpload'}:
        return _transfer_recovery_action(params)
    if action == 'copyObject':
        return _storage_copy(params)
    profile = _parse_profile(params.get('profile') or {})
    if action == 'getBucketAdminState':
        return _azure_get_bucket_admin_state(params) if profile.endpoint_type == 'azureBlob' else _get_bucket_admin_state(params)
    if action == 'deleteVersion':
        if params.get('versionId') is None or params.get('versionId') == '':
            raise SidecarError('invalid_config', 'An explicit version ID is required, including the literal null version ID.')
        ref = _object_ref(params)
        if profile.endpoint_type == 'azureBlob':
            client = _build_azure_client(profile)
            client.request('DELETE', client.blob_path(ref['Bucket'], ref['Key']), query={'versionid': ref['VersionId']})
        else:
            _build_client(profile).delete_object(**ref)
        return {'successCount': 1, 'failureCount': 0, 'failures': [], 'deleted': True}
    if action == 'ensureBucket':
        bucket = str(params.get('bucketName') or '')
        if not bucket: raise SidecarError('invalid_config', 'Destination bucket name is required.')
        if profile.endpoint_type == 'azureBlob':
            client = _build_azure_client(profile)
            try:
                client.request('HEAD', client.blob_path(bucket), query={'restype': 'container'})
                return {'exists': True, 'created': False}
            except SidecarError as error:
                if error.details.get('httpStatus') != 404: raise
            _azure_create_bucket(params)
        else:
            client = _build_client(profile)
            try:
                client.head_bucket(Bucket=bucket)
                if params.get('versioningEnabled') is True:
                    client.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={'Status': 'Enabled'})
                return {'exists': True, 'created': False}
            except Exception as error:
                if _client_error_code(error) not in {'NoSuchBucket', '404', 'NotFound'}: raise
            _create_bucket(params)
            if params.get('versioningEnabled') is True:
                client.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={'Status': 'Enabled'})
        return {'exists': True, 'created': True}
    if action == 'putLifecycle':
        if profile.endpoint_type == 'azureBlob':
            raise SidecarError('unsupported_feature', 'Azure lifecycle policies require storage account management access.')
        return _put_bucket_lifecycle(params)
    if action == 'providerInfo':
        azure = profile.endpoint_type == 'azureBlob'
        return {'provider': profile.endpoint_type, 'actions':
                (['providerInfo', 'ensureBucket', 'getBucketAdminState', 'objectDetails', 'objectTags', 'objectProperties', 'copyObject', 'listObjects', 'listObjectVersions', 'downloadVersion', 'deleteVersion',
                  'getObjectProtection', 'setObjectProtection', 'presignVersion', 'startResumableUpload', 'resumeUpload', 'abortUpload', 'listTransferRecovery'] + sorted(_advanced_module().AZURE_ACTIONS)) if azure else _STORAGE_ACTIONS,
                'requirements': {'accountManagement': 'azureDefault credentials, accountResourceId and management RBAC',
                                 'adls': 'Confirmed hierarchical namespace and paired public-cloud HTTPS endpoint',
                                 'presignVersion': 'Shared Key or Azure Default user delegation; cannot attenuate an existing SAS'} if azure else {},
                'support': 'unknown' if profile.endpoint_type == 's3Compatible' else 'supported',
                'storageClasses': ['Hot', 'Cool', 'Cold', 'Archive'] if azure else ['STANDARD', 'STANDARD_IA', 'ONEZONE_IA', 'INTELLIGENT_TIERING', 'GLACIER_IR', 'GLACIER', 'DEEP_ARCHIVE']}
    if action == 'listObjects':
        return _azure_list_objects(params) if profile.endpoint_type == 'azureBlob' else _list_objects(params)
    if action == 'downloadVersion':
        return _run_transfer(_azure_start_download if profile.endpoint_type == 'azureBlob' else _start_download,
                             {**params, 'keys': [params['key']], 'destinationPath': params.get('destinationPath') or params.get('destinationDirectory') or ''})
    if profile.endpoint_type == 'azureBlob':
        return _azure_storage_action(params)
    client = _build_client(profile)
    bucket = str(params.get('bucketName') or '')
    if action == 'getBucketConfiguration':
        if not bucket: raise SidecarError('invalid_config', 'Bucket name is required.')
        calls, result = [], {}
        sections = [
            ('replication', 'GetBucketReplication', lambda: client.get_bucket_replication(Bucket=bucket)),
            ('notification', 'GetBucketNotificationConfiguration', lambda: client.get_bucket_notification_configuration(Bucket=bucket)),
            ('ownershipControls', 'GetBucketOwnershipControls', lambda: client.get_bucket_ownership_controls(Bucket=bucket)),
            ('publicAccessBlock', 'GetPublicAccessBlock', lambda: client.get_public_access_block(Bucket=bucket)),
        ]
        for field, operation, request in sections:
            try:
                result[field] = _clean_sdk(_maybe_call(calls, operation, request, {}))
            except Exception:
                result[field] = None
        result['sections'] = {call['operation']: {'state': call.get('state', 'supported'), 'message': call.get('message', '')} for call in calls}
        result['apiCalls'] = calls
        return result
    if action == 'getAccess':
        calls = []
        policy = _maybe_call(calls, 'GetBucketPolicy', lambda: client.get_bucket_policy(Bucket=bucket), {})
        acl = _maybe_call(calls, 'GetBucketAcl', lambda: client.get_bucket_acl(Bucket=bucket), {})
        ownership = _maybe_call(calls, 'GetBucketOwnershipControls', lambda: client.get_bucket_ownership_controls(Bucket=bucket), {})
        block = _maybe_call(calls, 'GetPublicAccessBlock', lambda: client.get_public_access_block(Bucket=bucket), {})
        return {'policyJson': policy.get('Policy', '{}'), 'acl': _clean_sdk(acl),
                'ownershipControls': ownership.get('OwnershipControls', {}),
                'publicAccessBlock': block.get('PublicAccessBlockConfiguration', {}), 'sections': calls}
    if action == 'putAccess':
        if 'expectedPolicyJson' in params:
            current = _configuration_or_missing(lambda: client.get_bucket_policy(Bucket=bucket), {'NoSuchBucketPolicy'})
            if json.loads(current.get('Policy') or '{}') != json.loads(params['expectedPolicyJson'] or '{}'):
                raise SidecarError('conflict', 'Bucket policy changed. Refresh before applying the preset.')
        if params.get('policyJson') is not None:
            policy = json.loads(params['policyJson'])
            if not policy or policy.get('Statement') == []:
                client.delete_bucket_policy(Bucket=bucket)
            else:
                client.put_bucket_policy(Bucket=bucket, Policy=params['policyJson'])
        if params.get('acl'):
            client.put_bucket_acl(Bucket=bucket, ACL=params['acl'])
        return {'applied': True}
    if action == 'objectDetails':
        return _get_object_details(params)
    if action == 'listObjectVersions':
        return _list_object_versions(params)
    if action == 'presignVersion':
        return _generate_presigned_url(params)
    if action in {'getBucketProtection', 'setBucketProtection'}:
        if action.startswith('set'):
            client.put_object_lock_configuration(Bucket=bucket, ObjectLockConfiguration=params['configuration'])
        return {'configuration': _clean_sdk(client.get_object_lock_configuration(Bucket=bucket)).get('ObjectLockConfiguration', {})}
    if action == 'listMultipartUploads':
        request = {'Bucket': bucket, 'MaxUploads': 1000, 'Prefix': str(params.get('prefix') or '')}
        cursor = params.get('cursor') or {}
        for key in ('KeyMarker', 'UploadIdMarker'):
            if cursor.get(key): request[key] = cursor[key]
        response = client.list_multipart_uploads(**request)
        return {'items': _clean_sdk(response.get('Uploads', [])), 'isTruncated': bool(response.get('IsTruncated')),
                'nextCursor': {'KeyMarker': response.get('NextKeyMarker'), 'UploadIdMarker': response.get('NextUploadIdMarker'), 'hasMore': bool(response.get('IsTruncated'))}}
    ref = _object_ref(params)
    if action == 'objectTags':
        if 'tags' in params:
            client.put_object_tagging(**ref, Tagging={'TagSet': [{'Key': str(k), 'Value': str(v)} for k, v in params['tags'].items()]})
        return {'tags': {i['Key']: i['Value'] for i in client.get_object_tagging(**ref).get('TagSet', [])}}
    if action in {'getObjectProtection', 'setObjectProtection'}:
        if action.startswith('set'):
            if params.get('retention') is not None:
                request = {'Retention': params['retention']}
                if params.get('bypassGovernanceRetention'): request['BypassGovernanceRetention'] = True
                client.put_object_retention(**ref, **request)
            if params.get('legalHold') is not None:
                hold = params['legalHold']
                client.put_object_legal_hold(**ref, LegalHold=hold if isinstance(hold, dict) else {'Status': 'ON' if hold else 'OFF'})
        calls = []
        retention = _maybe_call(calls, 'GetObjectRetention', lambda: client.get_object_retention(**ref), {})
        hold = _maybe_call(calls, 'GetObjectLegalHold', lambda: client.get_object_legal_hold(**ref), {})
        return {'retention': _clean_sdk(retention.get('Retention', {})), 'legalHold': hold.get('LegalHold', {}), 'sections': calls}
    if action == 'restoreObject':
        request = {'Days': max(1, int(params.get('days') or 7)), 'GlacierJobParameters': {'Tier': params.get('tier') or 'Standard'}}
        response = client.restore_object(**ref, RestoreRequest=request)
        return {'requested': True, 'statusCode': response.get('ResponseMetadata', {}).get('HTTPStatusCode')}
    if action in {'listParts', 'abortMultipartUpload'}:
        ref.pop('VersionId', None)
        ref['UploadId'] = params['uploadId']
        if action == 'abortMultipartUpload':
            client.abort_multipart_upload(**ref)
            return {'aborted': True}
        marker = (params.get('cursor') or {}).get('PartNumberMarker')
        if marker: ref['PartNumberMarker'] = int(marker)
        response = client.list_parts(**ref)
        return {'items': _clean_sdk(response.get('Parts', [])), 'isTruncated': bool(response.get('IsTruncated')),
                'nextCursor': {'PartNumberMarker': response.get('NextPartNumberMarker'), 'hasMore': bool(response.get('IsTruncated'))}}
    if action == 'objectProperties':
        return _storage_copy({**params, 'sourceProfile': params['profile'], 'destinationProfile': params['profile'],
                              'sourceBucketName': bucket, 'destinationBucketName': bucket,
                              'sourceKey': ref['Key'], 'destinationKey': ref['Key'], 'sourceVersionId': params.get('versionId'),
                              'conflictPolicy': 'replace', 'options': {k: params[k] for k in ('metadata', 'headers', 'storageClass', 'encryption', 'expectedETag') if k in params}})
    raise SidecarError('unsupported_feature', f'Unknown storage action: {action}')


_COPY_HEADERS = {'ContentType': 'Content-Type', 'CacheControl': 'Cache-Control', 'ContentDisposition': 'Content-Disposition',
                 'ContentEncoding': 'Content-Encoding', 'ContentLanguage': 'Content-Language', 'Expires': 'Expires'}


def _copy_options(head, options):
    result = {'Metadata': dict(options.get('metadata', head.get('Metadata') or {}))}
    for aws, http in _COPY_HEADERS.items():
        value = (options.get('headers') or {}).get(http, (options.get('headers') or {}).get(aws, head.get(aws)))
        if value is not None: result[aws] = value
    if options.get('storageClass') or head.get('StorageClass'):
        result['StorageClass'] = options.get('storageClass') or head['StorageClass']
    encryption = options.get('encryption') or {}
    if isinstance(encryption, str): encryption = {'ServerSideEncryption': encryption}
    for field in ('ServerSideEncryption', 'SSEKMSKeyId', 'BucketKeyEnabled'):
        if field in encryption: result[field] = encryption[field]
    return result


def _check_mutation_result(result, required_field=None):
    if not isinstance(result, dict) or result.get('Error') or result.get('Errors'):
        raise SidecarError('invalid_response', 'Storage returned an embedded mutation error; success was not verified.')
    if required_field and not result.get(required_field):
        raise SidecarError('invalid_response', f'Storage omitted {required_field}; success was not verified.')


def _relay_chunks(body, chunk_size):
    """Large S3 parts spill to a private temporary file, bounded to one part."""
    while True:
        with tempfile.SpooledTemporaryFile(max_size=8 * 1024**2, mode='w+b') as part:
            received = 0
            while received < chunk_size:
                block = body.read(min(1024 * 1024, chunk_size - received))
                if not block: break
                part.write(block)
                received += len(block)
            if not received: return
            part.seek(0)
            yield _FilePart(part, 0, received)
            if received < chunk_size: return


def _storage_copy(params):
    return _run_transfer(_storage_copy_impl, params)


def _storage_copy_impl(params):
    source_profile = _parse_profile(params.get('sourceProfile') or params.get('profile') or {})
    dest_profile = _parse_profile(params.get('destinationProfile') or params.get('profile') or {})
    source = {'Bucket': str(params.get('sourceBucketName') or ''), 'Key': str(params.get('sourceKey') or '')}
    dest = {'Bucket': str(params.get('destinationBucketName') or ''), 'Key': str(params.get('destinationKey') or '')}
    if not all((*source.values(), *dest.values())):
        raise SidecarError('invalid_config', 'Copy source and destination bucket names and keys are required.')
    if params.get('sourceVersionId') is not None: source['VersionId'] = str(params['sourceVersionId'])
    src_azure, dst_azure = source_profile.endpoint_type == 'azureBlob', dest_profile.endpoint_type == 'azureBlob'
    src = _build_azure_client(source_profile) if src_azure else _build_client(source_profile)
    dst = _build_azure_client(dest_profile) if dst_azure else _build_client(dest_profile)
    src_query = {'versionid': source['VersionId']} if 'VersionId' in source else {}
    if src_azure:
        _, headers, _ = src.request('HEAD', src.blob_path(source['Bucket'], source['Key']), query=src_query)
        head = {'ContentLength': int(headers.get('Content-Length') or 0), 'ETag': headers.get('ETag'),
                'Metadata': {k[10:]: v for k, v in headers.items() if k.lower().startswith('x-ms-meta-')}}
        for aws, http in _COPY_HEADERS.items():
            if headers.get(http): head[aws] = headers[http]
    else:
        head = src.head_object(**source)
    size = int(head.get('ContentLength') or 0)
    options = params.get('options') or {}
    expected = params.get('expectedSourceETag') or options.get('expectedETag') or params.get('expectedETag')
    if expected and str(expected).strip('"') != str(head.get('ETag') or '').strip('"'):
        raise SidecarError('conflict', 'Source object changed. Refresh before copying.')
    policy = params.get('conflictPolicy') or 'replace'
    if policy not in {'replace', 'overwrite', 'skip', 'fail'}:
        raise SidecarError('invalid_config', 'Copy conflict policy must be replace, skip, or fail.')
    if policy in {'skip', 'fail'}:
        try:
            if dst_azure: dst.request('HEAD', dst.blob_path(dest['Bucket'], dest['Key']))
            else: dst.head_object(**dest)
        except Exception as error:
            if _client_error_code(error) not in {'404', 'NoSuchKey', 'NotFound'} and not (isinstance(error, SidecarError) and error.details.get('httpStatus') == 404): raise
        else:
            if policy == 'fail': raise SidecarError('conflict', 'Destination object already exists.')
            return {'successCount': 0, 'failureCount': 0, 'failures': [], 'skipped': True, 'bytesCopied': 0}
    job_id = f"copy-{uuid.uuid4().hex[:8]}"
    control = _register_transfer(TransferControl(job_id=job_id, label=f"Copy {source['Key']}", direction="copy", total_bytes=size,
        item_count=1, strategy_label="Object copy", part_size_bytes=None, parts_total=None))
    def publish_copy(transferred=None, completed=False):
        if transferred is not None:
            _transfer_checkpoint(control, bytes_transferred=transferred, items_completed=int(completed), parts_completed=0, current_item_label=source['Key'])
        _emit_transfer_event(_build_transfer_job(job_id=job_id, label=control.label, direction="copy", progress=control.bytes_transferred / size if size else int(completed),
            status="completed" if completed else "running", bytes_transferred=control.bytes_transferred, total_bytes=size, output_lines=[], current_item_label=source['Key'],
            item_count=1, items_completed=int(completed), can_pause=not completed, can_cancel=not completed))
    publish_copy(0)
    def heartbeat():
        while True:
            time.sleep(5)
            if _lookup_transfer(job_id) is not control: return
            publish_copy()
    threading.Thread(target=heartbeat, daemon=True).start()
    if source_profile == dest_profile and source['Bucket'] == dest['Bucket'] and source['Key'] == dest['Key'] and 'encryption' not in options:
        options = {**options, 'encryption': {field: head[field] for field in ('ServerSideEncryption', 'SSEKMSKeyId', 'BucketKeyEnabled') if field in head}}
    put_options = _copy_options(head, options)
    source_tags = {}
    if options.get('preserveTags', True):
        if src_azure:
            _, _, tag_xml = src.request('GET', src.blob_path(source['Bucket'], source['Key']), query={**src_query, 'comp': 'tags'})
            tag_root = _azure_parse_xml(tag_xml)
            source_tags = {node.findtext('Key'): node.findtext('Value') for node in tag_root.iterfind('TagSet/Tag')}
        else:
            source_tags = {tag['Key']: tag['Value'] for tag in src.get_object_tagging(**source).get('TagSet', [])}
    if options.get('tags') is not None: source_tags = dict(options['tags'])
    if source_tags and not dst_azure:
        put_options['Tagging'] = '&'.join(f"{quote(k, safe='')}={quote(v, safe='')}" for k, v in source_tags.items())
    # Independent credentials are never guessed to have server-side cross-account access.
    same_authority = source_profile == dest_profile
    strategy = 'relay'
    result = {}
    if not src_azure and not dst_azure and same_authority and policy not in {'skip', 'fail'}:
        strategy = 'server-side-copy'
        copy_source = dict(source)
        match = {'CopySourceIfMatch': head['ETag']} if head.get('ETag') else {}
        if size <= 5 * 1024**3:
            result = dst.copy_object(**dest, CopySource=copy_source, MetadataDirective='REPLACE', TaggingDirective='REPLACE', **put_options, **match)
            _check_mutation_result(result, 'CopyObjectResult')
        else:
            upload = dst.create_multipart_upload(**dest, **put_options)['UploadId']
            try:
                chunk = max(64 * 1024**2, (size + 9999) // 10000)
                if chunk > 5 * 1024**3: raise SidecarError('invalid_config', 'Object exceeds S3 multipart limits.')
                parts = []
                def copy_part(index):
                    _transfer_gate(control)
                    start = index * chunk
                    response = dst.upload_part_copy(**dest, UploadId=upload, PartNumber=index + 1,
                        CopySource=copy_source, CopySourceRange=f'bytes={start}-{min(start + chunk, size) - 1}', **match)
                    return {'PartNumber': index + 1, 'ETag': response['CopyPartResult']['ETag']}
                with ThreadPoolExecutor(max_workers=min(8, dest_profile.max_pool_connections)) as pool:
                    for part in pool.map(copy_part, range((size + chunk - 1) // chunk)):
                        parts.append(part)
                        publish_copy(min(size, len(parts) * chunk))
                _transfer_gate(control)
                result = dst.complete_multipart_upload(**dest, UploadId=upload, MultipartUpload={'Parts': parts})
                _check_mutation_result(result)
            except BaseException:
                dst.abort_multipart_upload(**dest, UploadId=upload)
                raise
    else:
        # Relay spills one part at a time above 8 MiB; no credentials go to disk.
        # Source identity is pinned for the entire stream by version/ETag.
        if src_azure:
            body = src.open('GET', src.blob_path(source['Bucket'], source['Key']), query=src_query,
                            headers={'If-Match': head['ETag']} if head.get('ETag') else {})
        else:
            body = src.get_object(**source, **({'IfMatch': head['ETag']} if head.get('ETag') else {}))['Body']
        try:
            chunk = max(8 * 1024**2, (size + (49999 if dst_azure else 9999)) // (50000 if dst_azure else 10000))
            if chunk > (4000 * 1024**2 if dst_azure else 5 * 1024**3):
                raise SidecarError('unsupported_feature', 'Object exceeds the destination multipart size limits.')
            if dst_azure:
                path = dst.blob_path(dest['Bucket'], dest['Key'])
                block_ids = []
                copied = 0
                upload_nonce = uuid.uuid4().hex
                for block in _relay_chunks(body, chunk):
                    _transfer_gate(control)
                    block_id = base64.b64encode(f'{upload_nonce}-{len(block_ids):08d}'.encode()).decode()
                    dst.request('PUT', path, query={'comp': 'block', 'blockid': block_id}, body=block)
                    block_ids.append(block_id)
                    copied += len(block)
                    publish_copy(copied)
                if copied != size: raise SidecarError('conflict', 'Source size changed while copying.')
                headers = {'Content-Type': 'application/xml'}
                headers.update({f'x-ms-meta-{k}': v for k, v in put_options.get('Metadata', {}).items()})
                if source_tags: headers['x-ms-tags'] = '&'.join(f"{quote(k, safe='')}={quote(v, safe='')}" for k, v in source_tags.items())
                for aws, http in _COPY_HEADERS.items():
                    if aws in put_options: headers['x-ms-blob-' + http.lower()] = str(put_options[aws])
                if options.get('storageClass'): headers['x-ms-access-tier'] = options['storageClass']
                if policy in {'skip', 'fail'}: headers['If-None-Match'] = '*'
                xml = ('<BlockList>' + ''.join(f'<Latest>{v}</Latest>' for v in block_ids) + '</BlockList>').encode()
                _, final_headers, _ = dst.request('PUT', path, query={'comp': 'blocklist'}, headers=headers, body=xml)
                result = {'VersionId': final_headers.get('x-ms-version-id')}
            elif size <= chunk:
                data = body.read(chunk + 1)
                if len(data) != size: raise SidecarError('conflict', 'Source size changed while copying.')
                result = dst.put_object(**dest, Body=data, **put_options, **({'IfNoneMatch': '*'} if policy in {'skip', 'fail'} else {}))
            else:
                upload = dst.create_multipart_upload(**dest, **put_options)['UploadId']
                try:
                    parts, copied = [], 0
                    for block in _relay_chunks(body, chunk):
                        _transfer_gate(control)
                        number = len(parts) + 1
                        response = dst.upload_part(**dest, UploadId=upload, PartNumber=number, Body=block)
                        parts.append({'PartNumber': number, 'ETag': response['ETag']})
                        copied += len(block)
                        publish_copy(copied)
                    if copied != size: raise SidecarError('conflict', 'Source size changed while copying.')
                    result = dst.complete_multipart_upload(**dest, UploadId=upload, MultipartUpload={'Parts': parts},
                                                           **({'IfNoneMatch': '*'} if policy in {'skip', 'fail'} else {}))
                    _check_mutation_result(result)
                except BaseException:
                    dst.abort_multipart_upload(**dest, UploadId=upload)
                    raise
        finally:
            body.close()
    _check_mutation_result(result)
    verify = {'Bucket': dest['Bucket'], 'Key': dest['Key']}
    if result.get('VersionId'): verify['VersionId'] = result['VersionId']
    if dst_azure:
        _, destination_head, _ = dst.request('HEAD', dst.blob_path(dest['Bucket'], dest['Key']), query={'versionid': result['VersionId']} if result.get('VersionId') else {})
        dest_size = int(destination_head.get('Content-Length') or 0)
    else:
        dest_size = int(dst.head_object(**verify).get('ContentLength') or 0)
    if dest_size != size: raise SidecarError('conflict', 'Destination size verification failed after copying.')
    publish_copy(size, completed=True)
    return {'successCount': 1, 'failureCount': 0, 'failures': [], 'skipped': False, 'bytesCopied': size,
            'versionId': result.get('VersionId'), 'strategy': strategy}


def _azure_storage_action(params):
    action = params['action']
    if action in {'presignVersion', 'getObjectProtection', 'setObjectProtection'}:
        return _advanced_workflow(params)
    if action not in {'objectDetails', 'listObjectVersions', 'objectTags', 'objectProperties'}:
        raise SidecarError('unsupported_feature', f'{action} is not available for Azure Blob on this engine.')
    if action == 'objectDetails': return _azure_get_object_details(params)
    client = _build_azure_client(_parse_profile(params['profile']))
    if action == 'listObjectVersions':
        bucket = str(params.get('bucketName') or '')
        key = str(params.get('key') or '')
        query = {'restype': 'container', 'comp': 'list', 'include': 'versions', 'maxresults': '1000',
                 'prefix': key or str(params.get('prefix') or '')}
        if (params.get('cursor') or {}).get('value'): query['marker'] = params['cursor']['value']
        _, _, data = client.request('GET', client.blob_path(bucket), query=query)
        root = _azure_parse_xml(data)
        items = []
        for node in root.iterfind('Blobs/Blob'):
            name = node.findtext('Name') or ''
            if key and name != key: continue
            items.append({'key': name, 'versionId': node.findtext('VersionId') or '',
                          'modifiedAt': _serialize_dt(_azure_parse_rfc1123(node.findtext('Properties/Last-Modified'))),
                          'latest': node.findtext('IsCurrentVersion') == 'true', 'deleteMarker': False,
                          'size': int(node.findtext('Properties/Content-Length') or 0),
                          'storageClass': node.findtext('Properties/AccessTier') or 'Hot'})
        marker = root.findtext('NextMarker') or None
        return {'items': items, 'cursor': {'value': marker, 'hasMore': bool(marker)}, 'totalCount': len(items), 'versionCount': len(items), 'deleteMarkerCount': 0}
    ref = _object_ref(params)
    path = client.blob_path(ref['Bucket'], ref['Key'])
    query = {'versionid': ref['VersionId']} if 'VersionId' in ref else {}
    if action == 'objectTags':
        if 'tags' in params:
            root = ET.Element('Tags')
            tag_set = ET.SubElement(root, 'TagSet')
            for k, v in params['tags'].items():
                node = ET.SubElement(tag_set, 'Tag')
                ET.SubElement(node, 'Key').text = str(k)
                ET.SubElement(node, 'Value').text = str(v)
            client.request('PUT', path, query={**query, 'comp': 'tags'}, headers={'Content-Type': 'application/xml'}, body=ET.tostring(root))
        _, _, data = client.request('GET', path, query={**query, 'comp': 'tags'})
        root = _azure_parse_xml(data)
        return {'tags': {n.findtext('Key'): n.findtext('Value') for n in root.iterfind('TagSet/Tag')}}
    if action == 'objectProperties':
        if params.get('encryption'):
            raise SidecarError('unsupported_feature', 'Azure encryption changes are managed by the storage account; this operation does not change encryption.')
        condition = {'If-Match': params['expectedETag']} if params.get('expectedETag') else {}
        if 'metadata' in params:
            client.request('PUT', path, query={**query, 'comp': 'metadata'}, headers={**condition, **{f'x-ms-meta-{k}': v for k, v in params['metadata'].items()}}, body=b'')
        if params.get('storageClass'):
            client.request('PUT', path, query={**query, 'comp': 'tier'}, headers={'x-ms-access-tier': params['storageClass']}, body=b'')
        if params.get('headers'):
            client.request('PUT', path, query={**query, 'comp': 'properties'}, headers={**condition, **{'x-ms-blob-' + k.lower(): v for k, v in params['headers'].items()}}, body=b'')
        return {'applied': True}
    raise SidecarError('unsupported_feature', f'{action} is not available for Azure Blob on this engine.')


def handle_request(payload: dict[str, Any]) -> dict[str, Any]:
    method = payload.get("method")
    params = payload.get("params") or {}

    if _is_azure_profile(params.get("profile") if isinstance(params, dict) else None):
        azure_result = _handle_azure_request(str(method), dict(params))
        if azure_result is not None:
            return azure_result

    if method == "storageAction":
        return _storage_action(dict(params))
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
        return _run_transfer(_start_upload, dict(params))
    if method == "startDownload":
        return _run_transfer(_start_download, dict(params))
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
        return _run_tool(_run_delete_all, dict(params))
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


def _process_line(line: str) -> None:
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

    _write_stdout_line(json.dumps(response))


_CONTROL_PLANE_METHODS = frozenset(
    {"pauseTransfer", "resumeTransfer", "cancelTransfer", "cancelToolExecution"}
)


def _is_control_plane_request(line: str) -> bool:
    """Cheap check so control requests never queue behind blocked workers.

    A paused transfer blocks its worker thread in _transfer_gate; if every
    worker is blocked, a resume/cancel submitted to the pool would never run.
    Control requests are therefore handled on the reader thread instead.
    """
    try:
        payload = json.loads(line)
    except (TypeError, ValueError):
        return False
    return isinstance(payload, dict) and payload.get("method") in _CONTROL_PLANE_METHODS


def main() -> int:
    _scrub_legacy_benchmark_artifacts()
    # Read requests on the main thread but handle each on a worker so that
    # control requests (pause/resume/cancel) can be processed while a transfer
    # is still streaming. stdout writes are serialized by _write_stdout_line.
    # Control-plane requests run on the reader thread itself: they are quick
    # registry mutations, and running them here guarantees they land even when
    # every worker is blocked in a paused transfer.
    executor = ThreadPoolExecutor(max_workers=8)
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            if _is_control_plane_request(line):
                _process_line(line)
            else:
                executor.submit(_process_line, line)
    finally:
        executor.shutdown(wait=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
