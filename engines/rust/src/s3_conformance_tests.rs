use super::*;
use crate::object_encryption_tests::{
    header,
    payload::{binary, BinaryFixture},
};
use std::sync::atomic::{AtomicUsize, Ordering};

const ACCESS: &str = "conformance-fixture-access";
const SECRET: &str = "conformance-fixture-secret";
const TOKEN: &str = "conformance-fixture-session-token";
const SSE: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
const SOURCE_SSE: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";

fn profile(endpoint: &str) -> Value {
    json!({
        "endpointType":"awsS3", "endpointUrl":endpoint, "pathStyle":true, "maxAttempts":5,
        "accessKey":ACCESS, "secretKey":SECRET, "sessionToken":TOKEN,
        "diagnostics":{"enableApiLogging":true, "enableDebugLogging":true},
    })
}

async fn call(method: &str, params: Value) -> SidecarResult {
    handle_request(Request {
        request_id: "conformance-fixture".into(),
        method: method.into(),
        params,
    })
    .await
}

async fn invoke(fixture: &BinaryFixture, op: &str, input: Value) -> Value {
    call(
        "s3ConformanceOp",
        json!({"profile":profile(&fixture.endpoint), "op":op, "input":input}),
    )
    .await
    .unwrap()
}

fn observation(value: &Value, outcome: &str, status: u16, attempts: u64) {
    assert_eq!(value["outcome"], outcome, "{value}");
    assert_eq!(value["httpStatus"], status);
    assert_eq!(value["attempts"], attempts);
    assert!(value["latencyMs"].as_f64().is_some_and(|ms| ms >= 0.0));
}

fn summary(body: &[u8]) -> Value {
    json!({"length":body.len(), "sha256":format!("{:x}", Sha256::digest(body))})
}

const LOCAL_CA: &str = include_str!("test_fixtures/s3_conformance_tls/ca.pem");
const UNRELATED_CA: &str = include_str!("test_fixtures/s3_conformance_tls/unrelated-ca.pem");

struct CaBundleFile(PathBuf);

impl CaBundleFile {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("rust-conformance-ca-{}.pem", Uuid::new_v4())))
    }
}

impl Drop for CaBundleFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

async fn https_fixture() -> (String, tokio::task::JoinHandle<()>) {
    use rustls::pki_types::PrivateKeyDer;
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::net::TcpListener;

    let cert = CertificateDer::from_pem_slice(include_bytes!(
        "test_fixtures/s3_conformance_tls/localhost.pem"
    ))
    .unwrap();
    let key = PrivateKeyDer::from_pem_slice(include_bytes!(
        "test_fixtures/s3_conformance_tls/localhost-test-key.pem"
    ))
    .unwrap();
    let server_config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert], key)
    .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(server_config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("https://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        loop {
            let (tcp, _) = listener.accept().await.unwrap();
            let Ok(tls) = acceptor.accept(tcp).await else {
                // The client rejects the certificate in the untrusted cases.
                continue;
            };
            let mut stream = BufReader::new(tls);
            let mut line = String::new();
            loop {
                line.clear();
                assert_ne!(stream.read_line(&mut line).await.unwrap(), 0);
                if line == "\r\n" {
                    break;
                }
            }
            stream
                .write_all(&binary("200 OK", "", b"tls object"))
                .await
                .unwrap();
            stream.shutdown().await.unwrap();
        }
    });
    (endpoint, task)
}

#[tokio::test]
async fn sdk_and_presigned_requests_use_all_custom_ca_roots_and_reload_changes() {
    let (endpoint, server) = https_fixture().await;
    let no_bundle = profile(&endpoint);
    let bundle = CaBundleFile::new();
    // Only the second root signed the fixture's leaf certificate.
    fs::write(&bundle.0, format!("{UNRELATED_CA}{LOCAL_CA}")).unwrap();
    let mut trusted = no_bundle.clone();
    trusted["verifyTls"] = json!(true);
    trusted["caBundlePath"] = json!(bundle.0);

    let sdk_input = json!({"Bucket":"fixture-bucket", "Key":"key"});
    for (op, input) in [
        ("GetObject", sdk_input.clone()),
        (
            "PresignedRequest",
            json!({"Bucket":"fixture-bucket", "Key":"key", "Method":"GET", "ExpiresIn":60}),
        ),
    ] {
        let result = call(
            "s3ConformanceOp",
            json!({"profile":trusted, "op":op, "input":input}),
        )
        .await
        .unwrap();
        observation(&result, "service", 200, 1);
        assert_eq!(result["output"]["Body"], summary(b"tls object"));
        let result = call(
            "s3ConformanceOp",
            json!({"profile":no_bundle, "op":op, "input":input}),
        )
        .await
        .unwrap();
        observation(&result, "transport", 0, 1);
    }

    fs::write(&bundle.0, UNRELATED_CA).unwrap();
    let result = call(
        "s3ConformanceOp",
        json!({"profile":trusted, "op":"GetObject", "input":sdk_input}),
    )
    .await
    .unwrap();
    observation(&result, "transport", 0, 1);

    server.abort();
    assert!(server.await.unwrap_err().is_cancelled());
}

#[tokio::test]
async fn missing_or_invalid_ca_bundle_returns_invalid_config() {
    let bundle = CaBundleFile::new();
    let mut profile = profile("https://127.0.0.1:1");
    profile["caBundlePath"] = json!(bundle.0);
    let params = json!({"profile":profile, "op":"ListBuckets", "input":{}});
    let error = call("s3ConformanceOp", params.clone()).await.unwrap_err();
    assert_eq!(error.code, "invalid_config");

    // A bad PEM or bad DER after a valid root must fail the whole bundle.
    for contents in [
        String::new(),
        format!("{LOCAL_CA}-----BEGIN CERTIFICATE-----\ninvalid-fixture-secret\n-----END CERTIFICATE-----\n"),
        format!("{LOCAL_CA}-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n"),
    ] {
        fs::write(&bundle.0, contents).unwrap();
        let error = call("s3ConformanceOp", params.clone()).await.unwrap_err();
        assert_eq!(error.code, "invalid_config");
        assert!(!error.message.contains("invalid-fixture-secret"));
    }
}

#[tokio::test]
async fn conformance_https_rejects_disabled_certificate_verification() {
    let mut profile = profile("https://127.0.0.1:1");
    profile["verifyTls"] = json!(false);
    let error = call(
        "s3ConformanceOp",
        json!({"profile":profile, "op":"ListBuckets", "input":{}}),
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "unsupported_feature");
}

#[test]
fn body_matches_contract_vectors_and_rejects_invalid_shapes() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../../../contracts/vectors/s3-conformance-body.json"
    ))
    .unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let body = request_body(Some(&json!({"generate": {
            "size":case["size"], "seed":case["seed"],
        }})))
        .unwrap();
        let first = body
            .iter()
            .take(8)
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        assert_eq!(json!(first), case["first8Hex"]);
        assert_eq!(summary(&body)["sha256"], case["sha256"]);
    }
    assert!(request_body(None).unwrap().is_empty());
    assert_eq!(request_body(Some(&json!({"base64": "YQ=="}))).unwrap(), "a");
    assert_eq!(request_body(Some(&json!({"text": "☀"}))).unwrap().len(), 3);
    for body in [
        Value::Null,
        json!({"generate":{"size":16 * MIB + 1, "seed":0}}),
        json!({"generate":{"size":1, "seed":65536}}),
        json!({"generate":{"size":-1, "seed":0}}),
        json!({"text":"é".repeat(32769)}),
        json!({"base64":"invalid encoding"}),
        json!({"base64":base64::encode(vec![0; MIB + 1])}),
        json!({"text":"a","base64":"YQ=="}),
    ] {
        assert_eq!(
            request_body(Some(&body)).unwrap_err().code,
            "invalid_request"
        );
    }
}

#[tokio::test]
async fn put_and_get_use_the_sdk_and_observe_lowercase_bounded_headers() {
    let contents = Arc::new(Mutex::new(Vec::new()));
    let observation_contents = contents.clone();
    let fixture = BinaryFixture::new(move |request| {
        if request.starts_with("PUT ") {
            assert!(header(request, "x-amz-checksum-crc64nvme").is_none());
            assert!(header(request, "x-amz-sdk-checksum-algorithm").is_none());
            assert_eq!(header(request, "content-type"), Some("text/plain"));
            *contents.lock().unwrap() = request.body.clone();
            return binary(
                "200 OK",
                "ETag: \"put-tag\"\r\nX-AmZ-Request-Id: put-id\r\n",
                b"",
            );
        }
        assert!(request.starts_with("GET "));
        assert!(header(request, "x-amz-checksum-mode").is_none());
        let extra = (0..20)
            .map(|i| format!("X-AmZ-Meta-{i}: value\r\n"))
            .collect::<String>();
        let headers = format!(
            "X-AmZ-Meta-Long: {}\r\nAccess-Control-Expose-Headers: one\r\naccess-control-expose-headers: two\r\n{extra}\
             X-Internal: unlisted-fixture-value\r\nX-AmZ-Security-Token: {TOKEN}\r\n\
             X-Amz-Server-Side-Encryption-Customer-Key-MD5: excluded-key-md5\r\nETag: \"get-tag\"\r\n",
            "a".repeat(530)
        );
        binary("200 OK", &headers, &contents.lock().unwrap())
    });
    let put = call(
        "s3ConformanceOp",
        json!({
            "profile":profile(&fixture.endpoint), "op":"PutObject",
            "input":{"Bucket":"fixture-bucket", "Key":"name", "ContentType":"text/plain"},
            "body":{"text":"payload ☀"}
        }),
    )
    .await
    .unwrap();
    observation(&put, "service", 200, 1);
    assert_eq!(put["headers"]["etag"], "\"put-tag\"");
    assert_eq!(put["requestId"], "put-id");
    assert_eq!(
        *observation_contents.lock().unwrap(),
        "payload ☀".as_bytes()
    );

    let get = invoke(
        &fixture,
        "GetObject",
        json!({"Bucket":"fixture-bucket","Key":"name"}),
    )
    .await;
    observation(&get, "service", 200, 1);
    assert_eq!(get["output"]["Body"], summary("payload ☀".as_bytes()));
    let headers = get["headers"].as_object().unwrap();
    assert_eq!(headers["access-control-expose-headers"], "one, two");
    assert_eq!(headers["x-amz-meta-long"].as_str().unwrap().len(), 512);
    assert_eq!(
        headers
            .keys()
            .filter(|k| k.starts_with("x-amz-meta-"))
            .count(),
        16
    );
    assert!(!get.to_string().contains("unlisted-fixture-value"));
    assert!(!get.to_string().contains("excluded-key-md5"));
    assert!(!get.to_string().contains(TOKEN));
    assert!(headers.keys().all(|key| *key == key.to_ascii_lowercase()));
}

#[tokio::test]
async fn service_errors_keep_status_and_headers_without_retries_or_redirects() {
    let sends = Arc::new(AtomicUsize::new(0));
    let observed = sends.clone();
    let fixture = BinaryFixture::new(move |request| {
        sends.fetch_add(1, Ordering::SeqCst);
        let line = request.lines().next().unwrap();
        if line.starts_with("HEAD ") {
            return binary("404 Not Found", "X-Amz-Delete-Marker: true\r\n", b"");
        }
        let path = line
            .split_whitespace()
            .nth(1)
            .unwrap()
            .split('?')
            .next()
            .unwrap();
        if path.ends_with("/not-modified") {
            return binary("304 Not Modified", "ETag: \"cached\"\r\n", b"");
        }
        if path.ends_with("/redirect") {
            return binary(
                "307 Temporary Redirect",
                "Location: /different?private=value\r\n",
                b"",
            );
        }
        if path.ends_with("/slow") {
            return binary(
                "503 Service Unavailable",
                "",
                b"<Error><Code>SlowDown</Code></Error>",
            );
        }
        let error = format!("<Error><Code>NoSuchKey</Code><Message>{SECRET} {TOKEN} https://example.test/path?secret=hidden {}</Message></Error>", "é".repeat(330));
        binary(
            "404 Not Found",
            "X-Amz-Delete-Marker: true\r\n",
            error.as_bytes(),
        )
    });
    let get = invoke(
        &fixture,
        "GetObject",
        json!({"Bucket":"fixture-bucket","Key":"missing"}),
    )
    .await;
    observation(&get, "service", 404, 1);
    assert_eq!(get["errorCode"], "NoSuchKey");
    assert_eq!(get["headers"]["x-amz-delete-marker"], "true");
    assert_eq!(get["errorMessage"].as_str().unwrap().chars().count(), 256);
    for secret in [SECRET, TOKEN, "secret=hidden"] {
        assert!(!get.to_string().contains(secret));
    }
    let head = invoke(
        &fixture,
        "HeadObject",
        json!({"Bucket":"fixture-bucket","Key":"missing"}),
    )
    .await;
    observation(&head, "service", 404, 1);
    assert_eq!(head["headers"]["x-amz-delete-marker"], "true");
    let unchanged = invoke(
        &fixture,
        "GetObject",
        json!({"Bucket":"fixture-bucket","Key":"not-modified","IfNoneMatch":"\"cached\""}),
    )
    .await;
    observation(&unchanged, "service", 304, 1);
    assert_eq!(unchanged["headers"]["etag"], "\"cached\"");
    let redirect = invoke(
        &fixture,
        "GetObject",
        json!({"Bucket":"fixture-bucket","Key":"redirect"}),
    )
    .await;
    observation(&redirect, "service", 307, 1);
    assert_eq!(redirect["headers"]["location"], "/different");
    let slow = invoke(
        &fixture,
        "GetObject",
        json!({"Bucket":"fixture-bucket","Key":"slow"}),
    )
    .await;
    observation(&slow, "service", 503, 1);
    assert_eq!(slow["errorCode"], "SlowDown");
    assert_eq!(observed.load(Ordering::SeqCst), 5);
}

#[tokio::test]
async fn list_and_delete_projections_use_aws_names_and_keep_opaque_values() {
    const CURSOR: &str = "https://cursor.invalid/value?opaque=abc+%";
    let fixture = BinaryFixture::new(move |request| {
        if request.starts_with("GET ") {
            let body = format!("<ListBucketResult><IsTruncated>true</IsTruncated><KeyCount>1</KeyCount>\
                <NextContinuationToken>{CURSOR}</NextContinuationToken><Contents><Key>key</Key><Size>7</Size>\
                <LastModified>2026-01-01T00:00:00.123Z</LastModified><ETag>&quot;q&quot;</ETag><StorageClass>STANDARD</StorageClass>\
                </Contents><CommonPrefixes><Prefix>folder/</Prefix></CommonPrefixes></ListBucketResult>");
            return binary("200 OK", "", body.as_bytes());
        }
        assert!(request.starts_with("POST "));
        let body = std::str::from_utf8(&request.body).unwrap();
        assert!(body.contains("<VersionId>null</VersionId>"));
        assert!(body.contains("<Quiet>false</Quiet>"));
        binary("200 OK", "", b"<DeleteResult><Deleted><Key>deleted</Key><VersionId>null</VersionId><DeleteMarker>true</DeleteMarker><DeleteMarkerVersionId>dm</DeleteMarkerVersionId></Deleted><Error><Key>denied</Key><Code>AccessDenied</Code><Message>Denied.</Message></Error></DeleteResult>")
    });
    let list = invoke(
        &fixture,
        "ListObjectsV2",
        json!({"Bucket":"fixture-bucket","MaxKeys":1}),
    )
    .await;
    observation(&list, "service", 200, 1);
    assert_eq!(
        list["output"],
        json!({
            "IsTruncated":true, "KeyCount":1, "NextContinuationToken":CURSOR,
            "Contents":[{"Key":"key", "Size":7, "LastModified":"2026-01-01T00:00:00.123Z",
                "ETag":"\"q\"", "StorageClass":"STANDARD"}],
            "CommonPrefixes":[{"Prefix":"folder/"}],
        })
    );
    let delete = invoke(
        &fixture,
        "DeleteObjects",
        json!({
            "Bucket":"fixture-bucket", "Delete":{"Objects":[{"Key":"deleted", "VersionId":"null"},
                {"Key":"denied"}], "Quiet":false}
        }),
    )
    .await;
    observation(&delete, "service", 200, 1);
    assert_eq!(
        delete["output"],
        json!({
            "Deleted":[{"Key":"deleted","VersionId":"null","DeleteMarker":true,"DeleteMarkerVersionId":"dm"}],
            "Errors":[{"Key":"denied","Code":"AccessDenied","Message":"Denied."}],
        })
    );
}

#[tokio::test]
async fn preflight_rpc_and_sdk_errors_are_distinct() {
    let fixture = BinaryFixture::new(|_| {
        binary(
            "200 OK",
            "X-Amz-Request-Id: malformed\r\n",
            b"<WrongRoot><KeyCount>invalid</KeyCount></WrongRoot>",
        )
    });
    let profile = profile(&fixture.endpoint);
    let unknown = call(
        "s3ConformanceOp",
        json!({"profile":profile,"op":"Unknown","input":{}}),
    )
    .await
    .unwrap_err();
    assert_eq!(unknown.code, "unsupported_feature");
    let forbidden = call(
        "s3ConformanceOp",
        json!({
            "profile":profile,"op":"GetObject",
            "input":{"Bucket":"fixture-bucket","Key":"key","SSECustomerKey":SSE}
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(forbidden.code, "invalid_request");
    assert!(!forbidden.message.contains(SSE));
    let gcs = call(
        "s3ConformanceOp",
        json!({
            "profile":{"endpointType":"googleCloudStorage"},"op":"ListBuckets","input":{}
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(gcs.code, "unsupported_feature");
    let capability = call("getCapabilities", json!({"profile":profile}))
        .await
        .unwrap();
    let item = capability["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["key"] == "conformance.s3")
        .unwrap();
    assert_eq!(item["state"], "supported");
    assert_eq!(item["ops"].as_array().unwrap().len(), 88);

    let validation = invoke(&fixture, "GetObject", json!({"Key":"key"})).await;
    observation(&validation, "sdk_validation", 0, 0);
    let decode = invoke(
        &fixture,
        "ListObjectsV2",
        json!({"Bucket":"fixture-bucket"}),
    )
    .await;
    observation(&decode, "sdk_decode", 200, 1);
    assert_eq!(decode["requestId"], "malformed");
}

#[tokio::test]
async fn copy_source_is_encoded_once_and_sse_keys_are_scoped() {
    let fixture = BinaryFixture::new(move |request| {
        assert_eq!(
            header(request, "x-amz-copy-source"),
            Some("source%2Ffolder%2Fa%2B%20%25%C3%A9?versionId=v%2B%20%25")
        );
        assert!(header(request, "x-amz-server-side-encryption-customer-key") == Some(SSE));
        assert!(
            header(
                request,
                "x-amz-copy-source-server-side-encryption-customer-key"
            ) == Some(SOURCE_SSE)
        );
        let auth = header(request, "authorization").unwrap();
        let error = format!(
            "<Error><Code>AccessDenied</Code><Message>{SSE} {SOURCE_SSE} {auth}</Message></Error>"
        );
        binary(
            "403 Forbidden",
            &format!("X-Amz-Meta-Echo: {SSE}\r\n"),
            error.as_bytes(),
        )
    });
    let logs = Arc::new(Mutex::new(Vec::new()));
    let result = secret_hygiene::CAPTURE
        .scope(
            Some(logs.clone()),
            call(
                "s3ConformanceOp",
                json!({
                    "profile":profile(&fixture.endpoint),"op":"CopyObject",
                    "input":{"Bucket":"fixture-bucket","Key":"dest",
                        "CopySource":{"Bucket":"source","Key":"folder/a+ %é","VersionId":"v+ %"}},
                    "encryption":{"mode":"sse-c","customerKey":SSE},
                    "sourceEncryption":{"mode":"sse-c","customerKey":SOURCE_SSE},
                }),
            ),
        )
        .await
        .unwrap();
    observation(&result, "service", 403, 1);
    assert_eq!(result["errorCode"], "AccessDenied");
    assert_eq!(result["headers"]["x-amz-meta-echo"], "[redacted]");
    assert!(logs.lock().unwrap().is_empty());
    for secret in [SSE, SOURCE_SSE, "Credential=", "Signature="] {
        assert!(!result.to_string().contains(secret));
    }
}

#[tokio::test]
async fn presigned_get_and_put_send_signed_requests_without_exposing_query_values() {
    let fixture = BinaryFixture::new(move |request| {
        let line = request.lines().next().unwrap();
        let path = line.split_whitespace().nth(1).unwrap();
        let url = url::Url::parse(&format!("http://fixture.invalid{path}")).unwrap();
        let query: BTreeMap<_, _> = url.query_pairs().collect();
        assert!(query
            .get("X-Amz-Signature")
            .is_some_and(|value| value.len() == 64));
        assert!(query
            .get("X-Amz-Security-Token")
            .is_some_and(|value| value == TOKEN));
        if line.starts_with("PUT ") {
            assert!(query
                .get("X-Amz-SignedHeaders")
                .unwrap()
                .contains("content-type"));
            assert_eq!(
                header(request, "content-type"),
                Some("application/octet-stream")
            );
            assert!(header(request, "authorization").is_none());
            assert!(header(request, "amz-sdk-invocation-id").is_none());
            assert_eq!(request.body, b"abc");
            return binary("200 OK", "", b"");
        }
        assert!(line.starts_with("GET "));
        assert!(query
            .get("versionId")
            .is_some_and(|value| value == "version+ /%"));
        let reflected = format!("http://{}{}", header(request, "host").unwrap(), path);
        let body = format!(
            "<Error><Code>AccessDenied</Code><Message>{TOKEN} {}</Message></Error>",
            query.get("X-Amz-Signature").unwrap()
        );
        binary(
            "403 Forbidden",
            &format!(
                "Location: {reflected}\r\nX-Amz-Meta-Credential: {}\r\n",
                query.get("X-Amz-Credential").unwrap()
            ),
            body.as_bytes(),
        )
    });
    let put = call("s3ConformanceOp", json!({
        "profile":profile(&fixture.endpoint), "op":"PresignedRequest",
        "input":{"Bucket":"fixture-bucket","Key":"key","Method":"PUT","ContentType":"application/octet-stream","ExpiresIn":60},
        "body":{"base64":"YWJj"}
    })).await.unwrap();
    observation(&put, "service", 200, 1);
    assert_eq!(put["output"]["Body"], summary(b""));
    assert_eq!(put["output"]["Presign"]["Method"], "PUT");
    let get = invoke(&fixture, "PresignedRequest", json!({
        "Bucket":"fixture-bucket", "Key":"key", "Method":"GET", "VersionId":"version+ /%", "ExpiresIn":60, "DelayMs":1
    })).await;
    observation(&get, "service", 403, 1);
    assert_eq!(get["errorCode"], "AccessDenied");
    assert_eq!(get["errorMessage"], "[redacted] [redacted]");
    let presign = &get["output"]["Presign"];
    assert_eq!(presign["Scheme"], "http");
    assert_eq!(
        presign["Host"],
        fixture.endpoint.trim_start_matches("http://")
    );
    assert!(presign["PresignMs"].as_f64().is_some());
    let keys = presign["QueryKeys"].as_array().unwrap();
    assert!(keys.contains(&json!("X-Amz-Signature")));
    assert!(keys
        .windows(2)
        .all(|pair| pair[0].as_str().unwrap() < pair[1].as_str().unwrap()));
    for secret in [TOKEN, ACCESS, "X-Amz-Signature=", "version+ /%"] {
        assert!(!get.to_string().contains(secret));
    }
}

#[tokio::test]
async fn digest_caps_at_32_mib_and_marks_truncation() {
    let body = Bytes::from(vec![0; RESPONSE_LIMIT + 1]);
    let mut expected = summary(&body[..RESPONSE_LIMIT]);
    expected["truncated"] = json!(true);
    assert_eq!(
        digest_body(ByteStream::from(body), Duration::from_secs(1))
            .await
            .unwrap(),
        expected
    );
}

#[tokio::test]
async fn explicit_checksum_mode_preserves_validation_failures() {
    let fixture = BinaryFixture::new(|request| {
        assert_ne!(header(request, "x-amz-checksum-mode"), Some("DISABLED"));
        binary(
            "200 OK",
            "X-Amz-Checksum-Crc32: AAAAAA==\r\n",
            b"invalid checksum",
        )
    });
    let unchecked = invoke(
        &fixture,
        "GetObject",
        json!({
            "Bucket":"fixture-bucket", "Key":"unchecked",
        }),
    )
    .await;
    observation(&unchecked, "service", 200, 1);
    let checked = invoke(
        &fixture,
        "GetObject",
        json!({
            "Bucket":"fixture-bucket", "Key":"checked", "ChecksumMode":"ENABLED",
        }),
    )
    .await;
    observation(&checked, "sdk_decode", 200, 1);
    assert_eq!(checked["headers"]["x-amz-checksum-crc32"], "AAAAAA==");
}
