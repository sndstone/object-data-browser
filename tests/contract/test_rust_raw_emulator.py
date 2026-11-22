"""Opt-in raw-engine tests against a disposable, authenticated AWS Emulator."""

import http.client
import json
import os
import socket
import ssl
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import pytest


def rpc(engine, method, **params):
    request_id = uuid.uuid4().hex
    engine.send(dict(requestId=request_id, method=method, params=params))
    return receive(engine, request_id)


def receive(engine, request_id):
    while True:
        response = engine.recv_json(timeout=20)
        if response.get("requestId") == request_id:
            return response


def result(response):
    if not response["ok"]:
        error = response["error"]
        pytest.fail(f"S3 RPC failed: {error['code']} / {error.get('details', {}).get('awsCode')}")
    return response["result"]


def error(response, code, aws_code=None):
    assert response["ok"] is False
    assert response["error"]["code"] == code
    if aws_code:
        assert response["error"]["details"]["awsCode"] == aws_code


@pytest.fixture
def raw_engine(engine):
    if result(rpc(engine, "health"))["engine"] != "rust-raw":
        pytest.skip("Raw Rust engine only")
    return engine


@pytest.fixture(scope="session")
def emulator():
    endpoint = os.getenv("ODB_S3_EMULATOR_URL")
    if not endpoint:
        pytest.skip("Set ODB_S3_EMULATOR_URL for live emulator tests")
    address = urlsplit(endpoint)
    if (address.scheme != "https" or not address.hostname or address.username or address.password
            or address.path not in ("", "/") or address.query or address.fragment):
        pytest.fail("Use the disposable AWS Emulator's direct HTTPS address")
    access = os.getenv("ODB_S3_EMULATOR_ACCESS_KEY")
    secret = os.getenv("ODB_S3_EMULATOR_SECRET_KEY")
    ca_path = os.getenv("ODB_S3_EMULATOR_CA")
    if not (access and secret and ca_path):
        pytest.fail("Set emulator access key, secret key and CA variables")
    context = ssl.create_default_context(cafile=ca_path)
    connection = http.client.HTTPSConnection(address.hostname, address.port, timeout=5, context=context)
    try:
        connection.request("GET", "/__admin/health")
        health = connection.getresponse()
        assert (health.status, health.read()) == (200, b"ok")
    finally:
        connection.close()
    profile = dict(id="raw-live", endpointType="s3Compatible", endpointUrl=endpoint,
                   region="us-east-1", pathStyle=True, verifyTls=True, caBundlePath=ca_path,
                   accessKey=access, secretKey=secret, maxAttempts=2,
                   readTimeoutSeconds=5, connectTimeoutSeconds=3)
    return address, context, profile


@pytest.fixture(scope="session")
def plain_http(emulator):
    address, context, _ = emulator

    class Forward(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        reject_parts_for = None
        abort_statuses = []

        def log_message(self, *_):
            pass

        def forward(self):
            # Preserve signed Host, raw URL and request headers. Only this
            # fixture's loopback hop is cleartext.
            length = int(self.headers.get("Content-Length", "0"))
            payload = self.rfile.read(length) if length else None
            target = urlsplit(self.path)
            if (self.command == "PUT" and target.path == self.reject_parts_for
                    and "partNumber=" in target.query):
                denial = b"<Error><Code>AccessDenied</Code></Error>"
                self.send_response_only(403)
                self.send_header("Content-Length", str(len(denial)))
                self.end_headers()
                self.wfile.write(denial)
                return
            upstream = http.client.HTTPSConnection(
                address.hostname, address.port, timeout=10, context=context)
            try:
                upstream.putrequest(self.command, self.path, skip_host=True,
                                    skip_accept_encoding=True)
                for name, value in self.headers.raw_items():
                    if name.lower() not in ("connection", "keep-alive"):
                        upstream.putheader(name, value)
                upstream.endheaders(payload)
                response = upstream.getresponse()
                body = response.read()
                if (self.command == "DELETE" and target.path == self.reject_parts_for
                        and "uploadId=" in target.query):
                    self.abort_statuses.append(response.status)
                self.send_response_only(response.status)
                for name, value in response.getheaders():
                    if name.lower() not in ("connection", "keep-alive", "transfer-encoding",
                                            "content-length"):
                        self.send_header(name, value)
                response_length = response.getheader("Content-Length", "0")
                self.send_header("Content-Length", response_length if self.command == "HEAD" else str(len(body)))
                self.end_headers()
                if body:
                    self.wfile.write(body)
            finally:
                upstream.close()

        do_HEAD = do_GET = do_PUT = do_POST = do_DELETE = forward

    with ThreadingHTTPServer(("127.0.0.1", 0), Forward) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}", Forward
        finally:
            server.shutdown()
            thread.join()


@pytest.fixture(params=["https", "http"])
def endpoint(request, emulator):
    _, context, profile = emulator
    if request.param == "http":
        url, _ = request.getfixturevalue("plain_http")
        profile = dict(profile, endpointUrl=url)
        del profile["caBundlePath"]
    return profile, context


@pytest.fixture
def bucket(raw_engine, endpoint):
    profile, context = endpoint
    name = "odb-raw-test-" + uuid.uuid4().hex
    return raw_engine, profile, context, name


def create(engine, profile, name, **options):
    return result(rpc(engine, "createBucket", profile=profile, bucketName=name, **options))


def drain(engine, profile, name):
    report = result(rpc(engine, "runDeleteAll", profile=profile,
                        config=dict(bucketName=name, batchSize=5, listMaxKeys=5)))
    assert report["verifiedEmpty"] and report["exitCode"] == 0
    result(rpc(engine, "deleteBucket", profile=profile, bucketName=name))


def read_url(url, context, headers=None):
    address = urlsplit(url)
    connection_class = http.client.HTTPSConnection if address.scheme == "https" else http.client.HTTPConnection
    options = {"context": context} if address.scheme == "https" else {}
    connection = connection_class(address.hostname, address.port, timeout=10, **options)
    try:
        connection.request("GET", address.path + "?" + address.query, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def test_bucket_configuration_and_validation(bucket):
    engine, profile, _, name = bucket

    def call(method, **params):
        return result(rpc(engine, method, profile=profile, bucketName=name, **params))

    create(engine, profile, name, enableVersioning=True)
    try:
        assert result(rpc(engine, "getCapabilities"))["items"]
        assert call("testProfile")["ok"]
        assert result(rpc(engine, "testProfile", profile=dict(profile, knownBucket=name)))["bucketCount"] == 1
        assert name in {item["name"] for item in call("listBuckets")["items"]}
        assert call("getBucketAdminState")["versioningStatus"] == "Enabled"
        assert call("setBucketVersioning", enabled=False)["versioningStatus"] == "Suspended"
        call("createFolder", key="suspended")
        suspended = call("listObjectVersions", key="suspended/")["items"]
        assert [item["versionId"] for item in suspended] == ["null"]
        assert call("deleteObjectVersions", versions=[dict(key="suspended/", versionId="null")])["successCount"] == 1
        assert call("setBucketVersioning", enabled=True)["versioningStatus"] == "Enabled"

        rules = {"Rules": [{"ID": "expire", "Status": "Enabled", "Filter": {"Prefix": "expired/"},
                            "Expiration": {"Days": 30}}]}
        lifecycle = call("putBucketLifecycle", lifecycleJson=json.dumps(rules), expectedLifecycleJson="[]")
        assert json.loads(lifecycle["lifecycleJson"])["Rules"] == rules["Rules"]
        error(rpc(engine, "putBucketLifecycle", profile=profile, bucketName=name,
                  lifecycleJson=json.dumps(rules), expectedLifecycleJson="[]"), "object_conflict")
        assert not call("deleteBucketLifecycle")["lifecycleEnabled"]

        policy = {"Version": "2012-10-17", "Statement": [{
            "Effect": "Deny", "Principal": "*", "Action": "s3:GetObject",
            "Resource": f"arn:aws:s3:::{name}/policy-test/*"}]}
        assert json.loads(call("putBucketPolicy", policyJson=json.dumps(policy))["policyJson"]) == policy
        assert not call("deleteBucketPolicy")["policyAttached"]
        cors = [{"AllowedOrigins": ["https://example.test"], "AllowedMethods": ["GET"],
                 "AllowedHeaders": ["*"], "MaxAgeSeconds": 60}]
        assert json.loads(call("putBucketCors", corsJson=json.dumps(cors))["corsJson"]) == cors
        assert not call("deleteBucketCors")["corsEnabled"]
        sse = {"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}
        assert call("putBucketEncryption", encryptionJson=json.dumps(sse))["encryptionSummary"] == "AES256"
        reset = call("deleteBucketEncryption")
        assert reset["sections"]["GetBucketEncryption"]["state"] in ("absent", "available")
        error(rpc(engine, "putBucketTagging", profile=profile, bucketName=name,
                  tags={"qualification": "invalid%tag"}), "invalid_config", "InvalidTag")
        assert call("putBucketTagging", tags={"qualification": "s3+test"})["tags"] == {"qualification": "s3+test"}
        assert call("deleteBucketTagging")["tags"] == {}
    finally:
        drain(engine, profile, name)


def test_objects_versions_transfers_and_presigning(bucket, tmp_path):
    engine, profile, context, name = bucket

    def call(method, **params):
        return result(rpc(engine, method, profile=profile, bucketName=name, **params))

    def upload(source, key, **params):
        return call("startUpload", filePaths=[str(source)], objectKeyByPath={str(source): key},
                    **params)

    def signed(key, version=None):
        return call("generatePresignedUrl", key=key, versionId=version)["url"]

    source = tmp_path / "file.bin"
    target = tmp_path / "downloads"
    target.mkdir()
    key = " folder//x +%雪&<.bin "
    large = "nested/large.bin"
    copy = "copies/version +%雪.bin"
    moved = "copies/moved.bin"
    create(engine, profile, name, enableVersioning=True)
    try:
        assert call("createFolder", key="nested")["key"] == "nested/"
        source.write_bytes(b"version 1")
        assert upload(source, key)["status"] == "completed"
        first = call("getObjectDetails", key=key)["versionId"]
        source.write_bytes(b"version 2")
        assert upload(source, key, encryption={"mode": "sse-s3"})["status"] == "completed"
        second = call("getObjectDetails", key=key)["versionId"]
        assert first != second
        assert call("getObjectDetails", key=key, versionId=first)["headers"]["Content-Length"] == "9"
        assert read_url(signed(key, first), context) == (200, b"version 1")
        assert read_url(signed(key), context, {"Range": "bytes=2-5"}) == (206, b"rsio")
        status, _ = read_url(signed(key), context, {"Range": "bytes=999-"})
        assert status == 416

        payload = bytes(range(256)) * 24576 + b"last"
        source.write_bytes(payload)
        assert upload(source, large, multipartThresholdMiB=1, multipartChunkMiB=5)["partsCompleted"] == 2
        transfer = call("startDownload", keys=[large], destinationPath=str(target),
                        multipartThresholdMiB=1, multipartChunkMiB=1)
        assert transfer["status"] == "completed" and transfer["partsCompleted"] > 1
        assert (target / "large.bin").read_bytes() == payload
        assert call("startDownload", keys=[large], destinationPath=str(target))["status"] == "completed"
        assert (target / "large (1).bin").read_bytes() == payload

        page = call("listObjects", flat=True, maxKeys=1)
        listed = []
        for _ in range(4):
            listed.extend(item["key"] for item in page["items"])
            if not page["nextCursor"]["hasMore"]:
                break
            page = call("listObjects", flat=True, maxKeys=1, cursor=page["nextCursor"])
        assert set(listed) == {key, large, "nested/"} and len(listed) == 3
        assert [item["key"] for item in call("listObjects", prefix="nested/")["items"]] == [large]
        assert any(item["isFolder"] for item in call("listObjects")["items"])
        error(rpc(engine, "deleteBucket", profile=profile, bucketName=name), "conflict", "BucketNotEmpty")

        args = dict(sourceBucketName=name, sourceKey=key, sourceVersionId=first, destinationBucketName=name)
        assert call("copyObject", **args, destinationKey=copy)["successCount"] == 1
        assert read_url(signed(copy), context) == (200, b"version 1")
        exclusive_key = "copies/exclusive.bin"
        aws_copy = dict(args, profile=dict(profile, endpointType="awsS3"),
                        destinationKey=exclusive_key, conflictPolicy="skip")
        exclusive = result(rpc(engine, "copyObject", **aws_copy))
        assert exclusive["successCount"] == 1
        assert exclusive["strategy"] == "multipart server-side copy"
        assert read_url(signed(exclusive_key), context) == (200, b"version 1")
        assert result(rpc(engine, "copyObject", **aws_copy))["skipped"]
        error(rpc(engine, "copyObject", **dict(aws_copy, conflictPolicy="fail")),
              "object_conflict")
        assert call("moveObject", **args, destinationKey=moved)["successCount"] == 1
        assert read_url(signed(moved), context) == (200, b"version 1")
        error(rpc(engine, "getObjectDetails", profile=profile, bucketName=name,
                  key=key, versionId=first), "not_found")
        error(rpc(engine, "deleteObjectVersions", profile=profile, bucketName=name,
                  versions=[{"key": key, "versionId": second}, {"key": key}]), "invalid_config")
        assert read_url(signed(key), context) == (200, b"version 2")
        assert call("deleteObjects", keys=[key])["successCount"] == 1
        page = call("listObjectVersions", key=key, maxKeys=1)
        assert page["items"][0]["deleteMarker"]
        marker = page["items"][0]["versionId"]
        assert page["cursor"]["hasMore"]
        tail = call("listObjectVersions", key=key, maxKeys=1, cursor=page["cursor"])
        assert [entry["versionId"] for entry in tail["items"]] == [second]
        assert call("listObjectVersions", key=key,
                    options={"showVersions": False})["versionCount"] == 0
        call("deleteObjectVersions", versions=[{"key": key, "versionId": marker},
                                          {"key": key, "versionId": second}])
        assert call("listObjectVersions", key=key)["items"] == []
        call("deleteObjects", keys=[copy, moved])
        assert all(entry["key"] not in (copy, moved) for entry in call("listObjects", flat=True)["items"])
    finally:
        drain(engine, profile, name)


def test_failed_part_aborts_live_emulator_upload(raw_engine, emulator, plain_http, tmp_path):
    _, _, profile = emulator
    url, forwarder = plain_http
    profile = dict(profile, endpointUrl=url)
    del profile["caBundlePath"]
    name = "odb-raw-test-" + uuid.uuid4().hex
    create(raw_engine, profile, name)
    source = tmp_path / "abort.bin"
    source.write_bytes(b"a" * (5 * 1024 * 1024 + 1))
    forwarder.reject_parts_for = f"/{name}/{source.name}"
    forwarder.abort_statuses.clear()
    try:
        response = rpc(raw_engine, "startUpload", profile=profile, bucketName=name,
                       filePaths=[str(source)], multipartThresholdMiB=1, multipartChunkMiB=5)
        error(response, "auth_failed", "AccessDenied")
        assert forwarder.abort_statuses == [204]
        assert result(rpc(raw_engine, "listObjects", profile=profile, bucketName=name))["items"] == []
    finally:
        forwarder.reject_parts_for = None
        drain(raw_engine, profile, name)


def test_object_lock(bucket, tmp_path):
    engine, profile, _, name = bucket

    def call(method, **params):
        return result(rpc(engine, method, profile=profile, bucketName=name, **params))

    create(engine, profile, name, enableObjectLock=True, enableVersioning=True)
    key = "locked +%雪.txt"
    version = None
    try:
        cfg = {"ObjectLockEnabled": "Enabled", "Rule": {"DefaultRetention": {"Mode": "GOVERNANCE", "Days": 1}}}
        assert call("storageAction", action="setBucketProtection", configuration=cfg)["configuration"] == cfg
        assert call("storageAction", action="getBucketProtection")["objectLockEnabled"]
        assert call("getBucketAdminState")["objectLockMode"] == "GOVERNANCE"
        source = tmp_path / "locked.txt"
        source.write_bytes(b"protected")
        call("startUpload", filePaths=[str(source)], objectKeyByPath={str(source): key})
        version = call("getObjectDetails", key=key)["versionId"]
        target = dict(key=key, versionId=version)
        state = call("storageAction", action="getObjectProtection", **target)
        assert state["retention"]["Mode"] == "GOVERNANCE"
        later = (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
        state = call("storageAction", action="setObjectProtection", **target, legalHold=True,
                     retention={"Mode": "GOVERNANCE", "RetainUntilDate": later})
        assert state["legalHold"]["Status"] == "ON"
        error(rpc(engine, "storageAction", profile=profile, bucketName=name, **target,
                  action="deleteVersion", bypassGovernanceRetention=True), "auth_failed", "AccessDenied")
        assert call("storageAction", action="setObjectProtection", **target, legalHold=False)["legalHold"]["Status"] == "OFF"
        error(rpc(engine, "storageAction", profile=profile, bucketName=name, **target,
                  action="deleteVersion"), "auth_failed", "AccessDenied")
        call("storageAction", action="deleteVersion", **target, bypassGovernanceRetention=True)
        version = None
        assert call("listObjectVersions", key=key)["items"] == []
    finally:
        if version:
            target = dict(key=key, versionId=version)
            call("storageAction", action="setObjectProtection", **target, legalHold=False)
            call("storageAction", action="deleteVersion", **target, bypassGovernanceRetention=True)
        drain(engine, profile, name)


def test_emulator_errors(bucket):
    engine, profile, _, name = bucket
    create(engine, profile, name)
    try:
        for field in ("accessKey", "secretKey"):
            wrong = "ODBQualificationInvalid" + uuid.uuid4().hex
            response = rpc(engine, "listBuckets", profile=dict(profile, **{field: wrong}))
            error(response, "auth_failed")
            diagnostic = json.dumps(response) + "".join(engine._stderr_lines)
            if any(secret in diagnostic for secret in (wrong, profile["accessKey"], profile["secretKey"])):
                pytest.fail("Authentication diagnostics contained credentials")
        error(rpc(engine, "listObjects", profile=profile, bucketName=name + "-missing"),
              "not_found", "NoSuchBucket")
        error(rpc(engine, "getObjectDetails", profile=profile, bucketName=name, key="missing +%雪"),
              "not_found")
        error(rpc(engine, "getObjectDetails", profile=profile, bucketName=name, key="x", versionId="invalid-version"),
              "invalid_config")
        error(rpc(engine, "listObjects", profile=profile, bucketName="bad/bucket"), "invalid_config")
        error(rpc(engine, "getObjectDetails", profile=profile, bucketName=name, key="雪" * 342),
              "invalid_config")
        error(rpc(engine, "putBucketCors", profile=profile, bucketName=name, corsJson="{"),
              "invalid_config")
        assert result(rpc(engine, "listObjects", profile=profile, bucketName=name))["items"] == []
    finally:
        drain(engine, profile, name)


def test_tool_and_benchmark_controls(bucket, tmp_path):
    engine, profile, _, name = bucket

    def call(method, **params):
        return result(rpc(engine, method, profile=profile, **params))

    create(engine, profile, name, enableVersioning=True)
    try:
        report = call("runPutTestData", config=dict(bucketName=name, prefix="seed/", objectCount=2,
                                                   versions=2, objectSizeBytes=16, threads=2))
        assert report["exitCode"] == 0
        versions = call("listObjectVersions", bucketName=name, prefix="seed/")["items"]
        assert len(versions) == 4
        job = uuid.uuid4().hex
        engine.send(dict(requestId=job, method="runPutTestData", params=dict(
            profile=profile, jobId=job, config=dict(bucketName=name, prefix="cancel/",
                                                   objectCount=500, objectSizeBytes=32))))
        deadline = time.monotonic() + 5
        # Observe an actual write, so cancellation is independent of RPC scheduling.
        while time.monotonic() < deadline:
            keys = call("listObjects", bucketName=name, prefix="cancel/")["items"]
            if keys:
                break
        else:
            pytest.fail("Test-data job did not start")
        assert call("cancelToolExecution", jobId=job)["jobId"] == job
        assert result(receive(engine, job))["exitCode"] == 130
        assert len(call("listObjects", bucketName=name, prefix="cancel/")["items"]) < 500

        config = dict(engineId="rust-raw", bucketName=name, prefix="benchmark/", testMode="duration",
                      durationSeconds=60, objectCount=100, objectSizes=[256], concurrentThreads=2,
                      workloadType="custom", writePercent=1, readPercent=99, deletePercent=0,
                      validateChecksum=True, checksumAlgorithm="sha256", reducedLogging=True,
                      inMemoryData=True, csvOutputPath=str(tmp_path / "result.csv"),
                      jsonOutputPath=str(tmp_path / "result.json"),
                      logFilePath=str(tmp_path / "benchmark.log"))
        run_id = call("startBenchmark", config=config)["id"]

        def wait_for(predicate):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                state = call("getBenchmarkStatus", runId=run_id)
                if predicate(state):
                    return state
                time.sleep(.05)
            pytest.fail("Benchmark did not reach the requested state")

        try:
            wait_for(lambda state: state["processedCount"] > 1)
            call("pauseBenchmark", runId=run_id)
            paused = wait_for(lambda state: state["status"] == "paused")
            call("resumeBenchmark", runId=run_id)
            wait_for(lambda state: state["status"] == "running"
                     and state["processedCount"] > paused["processedCount"])
        finally:
            call("stopBenchmark", runId=run_id)
            stopped = wait_for(lambda state: state["status"] == "stopped")
        assert stopped["resultSummary"]["totalOperations"] > 0
        assert stopped["resultSummary"]["checksumStats"]["validated_success"] > 0
        for fmt in ("csv", "json"):
            export = call("exportBenchmarkResults", runId=run_id, format=fmt)
            assert export["path"] == str(tmp_path / run_id / f"result.{fmt}")
            assert (tmp_path / run_id / f"result.{fmt}").stat().st_size > 0
    finally:
        drain(engine, profile, name)


def fixture_profile(url, **overrides):
    return dict({
        "id": "raw-local", "endpointType": "s3Compatible", "endpointUrl": url,
        "region": "us-east-1", "pathStyle": True, "accessKey": "fixture-access",
        "secretKey": "fixture-secret", "maxAttempts": 2, "maxPoolConnections": 1,
        "readTimeoutSeconds": 1, "connectTimeoutSeconds": 1,
    }, **overrides)


@pytest.mark.parametrize("overrides", [
    {"endpointUrl": "localhost:1234"},
    {"endpointUrl": "ftp://localhost"},
    {"endpointUrl": "http://localhost:70000"},
    {"endpointUrl": "http://person:example@localhost"},
    {"endpointUrl": "http://localhost?bad=config"},
    {"endpointUrl": "http://localhost#fragment"},
    {"endpointType": "unknown"},
    {"region": "us/east"},
    {"accessKey": "not/valid"},
    {"secretKey": ""},
])
def test_bad_profile_is_rejected_before_network(raw_engine, overrides):
    error(rpc(raw_engine, "testProfile", profile=fixture_profile("http://127.0.0.1:1", **overrides)),
          "invalid_config")


def test_connection_refused_reports_before_send(raw_engine):
    # Closing the socket first makes the OS reject the connection. On macOS
    # a bound-but-idle socket can instead silently drop it.
    with socket.socket() as bound:
        bound.bind(("127.0.0.1", 0))
        port = bound.getsockname()[1]
    profile = fixture_profile(f"http://127.0.0.1:{port}", readTimeoutSeconds=3)
    response = rpc(raw_engine, "testProfile", profile=profile)
    error(response, "engine_unavailable")
    assert response["error"]["details"]["beforeSend"] is True


@pytest.fixture
def faulty_s3():
    class State:
        mode = ""
        calls = []
        release = threading.Event()
        payload = bytes(range(256)) * 4096
        etag = '"original"'

    state = State()

    class Faulty(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                # A rejected or timed-out response can close the client connection.
                pass

        def log_message(self, *_):
            pass

        def reply(self, status, body=b"", length=None, **headers):
            self.send_response(status)
            self.send_header("Content-Length", str(len(body) if length is None else length))
            for name, value in headers.items():
                self.send_header(name.replace("_", "-"), value)
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_HEAD(self):
            state.calls.append(("HEAD", self.path))
            if state.mode == "header-timeout":
                state.release.wait(5)
                self.close_connection = True
                return
            self.reply(200, length=len(state.payload), ETag=state.etag,
                       x_amz_version_id="immutable-version")

        def do_GET(self):
            state.calls.append(("GET", self.path))
            range_header = self.headers.get("Range")
            if not range_header:
                if state.mode == "retry-503" and state.calls.count(("GET", self.path)) == 1:
                    self.reply(503, b"<Error><Code>ServiceUnavailable</Code></Error>")
                elif state.mode == "malformed-list":
                    self.reply(200, b"<ListBucketResult><IsTruncated>true")
                else:
                    self.reply(200, b"<ListAllMyBucketsResult><Buckets/></ListAllMyBucketsResult>")
                return
            if self.headers.get("If-Match") != state.etag or "versionId=immutable-version" not in self.path:
                self.reply(412, b"<Error><Code>PreconditionFailed</Code></Error>")
                return
            start, end = map(int, range_header.removeprefix("bytes=").split("-"))
            data = state.payload[start:end + 1]
            full_length = len(data)
            content_range = f"bytes {start}-{end}/{len(state.payload)}"
            etag = state.etag
            if state.mode in ("416", "416-empty"):
                body = b"<Error><Code>InvalidRange</Code></Error>" if state.mode == "416" else b""
                self.reply(416, body,
                           Content_Range=f"bytes */{len(state.payload)}")
                return
            if state.mode == "wrong-range":
                content_range = f"bytes {start + 1}-{end}/{len(state.payload)}"
            if state.mode == "wrong-etag":
                etag = '"changed"'
            if state.mode == "body-timeout":
                self.reply(206, b"", length=full_length, Content_Range=content_range, ETag=etag)
                state.release.wait(5)
                self.close_connection = True
                return
            disconnect = state.mode == "truncated" or (
                state.mode == "recovered" and state.calls.count(("GET", self.path)) == 1)
            if disconnect:
                data = data[:128 * 1024]
                self.close_connection = True
            self.reply(206, data, length=full_length, Content_Range=content_range, ETag=etag)

        def do_PUT(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            state.calls.append(("PUT", self.path))
            self.close_connection = True

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            state.calls.append(("POST", self.path))
            self.reply(400)

    with ThreadingHTTPServer(("127.0.0.1", 0), Faulty) as server:
        thread = threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True)
        thread.start()
        try:
            yield fixture_profile(f"http://127.0.0.1:{server.server_port}"), state
        finally:
            state.release.set()
            server.shutdown()
            thread.join()


def test_bad_s3_xml_is_a_structured_error(raw_engine, faulty_s3):
    profile, state = faulty_s3
    state.mode = "malformed-list"
    error(rpc(raw_engine, "listObjects", profile=profile, bucketName="fixture"),
          "invalid_response")
    assert [method for method, _ in state.calls] == ["GET"]


def test_read_retries_a_transient_server_failure(raw_engine, faulty_s3):
    profile, state = faulty_s3
    state.mode = "retry-503"
    assert result(rpc(raw_engine, "listBuckets", profile=profile))["items"] == []
    assert [method for method, _ in state.calls] == ["GET", "GET"]


def test_header_timeout_has_bounded_attempts(raw_engine, faulty_s3):
    profile, state = faulty_s3
    state.mode = "header-timeout"
    response = rpc(raw_engine, "testProfile", profile=dict(profile, knownBucket="fixture"))
    error(response, "timeout")
    assert [method for method, _ in state.calls] == ["HEAD", "HEAD"]


@pytest.mark.parametrize("invalid_version", [
    {"key": "current"},
    {"key": "current", "versionId": ""},
    {"key": "雪" * 342, "versionId": "a-version"},
])
def test_version_delete_rejects_entire_malformed_batch(raw_engine, faulty_s3, invalid_version):
    profile, state = faulty_s3
    error(rpc(raw_engine, "deleteObjectVersions", profile=profile, bucketName="fixture",
              versions=[{"key": "valid", "versionId": "null"}, invalid_version]),
          "invalid_config")
    assert state.calls == []


@pytest.mark.parametrize("mode,code,attempts", [
    ("wrong-range", "object_conflict", 1),
    ("wrong-etag", "object_conflict", 1),
    ("416", "object_conflict", 1),
    ("416-empty", "object_conflict", 1),
    ("truncated", "engine_unavailable", 2),
    ("body-timeout", "timeout", 2),
    ("recovered", None, 2),
])
def test_bad_or_interrupted_range_keeps_destination_atomic(
        raw_engine, faulty_s3, tmp_path, mode, code, attempts):
    profile, state = faulty_s3
    state.mode = mode
    destination = tmp_path / "existing.bin"
    destination.write_bytes(b"local original")
    response = rpc(raw_engine, "startDownload", profile=profile, bucketName="fixture",
                   keys=[destination.name], destinationPath=str(tmp_path), conflictPolicy="replace",
                   multipartThresholdMiB=1, multipartChunkMiB=1)
    if code:
        error(response, code)
        assert destination.read_bytes() == b"local original"
    else:
        assert result(response)["status"] == "completed"
        assert destination.read_bytes() == state.payload
    assert list(tmp_path.iterdir()) == [destination]
    assert [method for method, _ in state.calls] == ["HEAD"] + ["GET"] * attempts


def test_lost_upload_response_reports_unknown_outcome_without_replay(
        raw_engine, faulty_s3, tmp_path):
    profile, state = faulty_s3
    source = tmp_path / "source.bin"
    source.write_bytes(b"server received this body")
    response = rpc(raw_engine, "startUpload", profile=profile, bucketName="fixture",
                   filePaths=[str(source)])
    error(response, "unknown_outcome")
    assert response["error"]["details"]["outcomeUnknown"] is True
    assert [method for method, _ in state.calls] == ["PUT"]
