use super::*;
use std::io::{BufRead, BufReader, Read};

const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
const SOURCE_KEY: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
const KEY_MD5: &str = "tP/LI3N87DFaSk0aoqYgzg==";

fn profile(endpoint: &str) -> Value {
    json!({"endpointType":"s3Compatible","endpointUrl":endpoint,"region":"us-east-1",
        "accessKey":"fixture","secretKey":"fixture","pathStyle":true,"maxAttempts":1,
        "maxConcurrentRequests":2,"diagnostics":{"enableApiLogging":true}})
}
fn customer() -> Value {
    json!({"mode":"sse-c","customerKey":KEY})
}
fn source_customer() -> Value {
    json!({"mode":"sse-c","customerKey":SOURCE_KEY})
}
fn modes() -> Vec<Option<Value>> {
    vec![
        None,
        Some(Value::Null),
        Some(json!({"mode":"bucketDefault"})),
        Some(json!({"mode":"sse-s3"})),
        Some(
            json!({"mode":"sse-kms","kmsKeyId":"alias/test","kmsEncryptionContext":{"a":"b"},"bucketKeyEnabled":false}),
        ),
        Some(json!({"mode":"dsse-kms","kmsKeyId":"alias/test","kmsEncryptionContext":{"a":"b"}})),
        Some(customer()),
    ]
}
fn with_mode(mut params: Value, mode: &Option<Value>) -> Value {
    if let Some(mode) = mode {
        params["encryption"] = mode.clone();
    }
    params
}
async fn call(method: &str, params: Value) -> SidecarResult {
    tokio::time::timeout(
        Duration::from_secs(90),
        handle_request(Request {
            request_id: "encryption-fixture".into(),
            method: method.into(),
            params,
        }),
    )
    .await
    .expect("fixture request timed out")
}
async fn captured_call(method: &str, params: Value) -> (SidecarResult, Vec<String>) {
    let captured = Arc::new(Mutex::new(Vec::new()));
    let result = secret_hygiene::CAPTURE
        .scope(Some(captured.clone()), async {
            let result = call(method, params).await;
            match &result {
                Ok(value) => write_response("encryption-fixture".into(), Ok(value.clone())),
                Err(error) => write_response(
                    "encryption-fixture".into(),
                    Err(SidecarError::with_details(
                        error.code,
                        &error.message,
                        error.details.clone(),
                    )),
                ),
            }
            result
        })
        .await;
    let lines = captured.lock().unwrap().clone();
    assert!(!lines.is_empty());
    assert!(
        !lines.join("\n").contains(SOURCE_KEY),
        "source customer key leaked into captured logs/output"
    );
    assert!(
        !lines.join("\n").contains(KEY),
        "customer key leaked into captured logs/output"
    );
    (result, lines)
}

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("rust-encryption-{}", Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn file(&self, size: u64) -> PathBuf {
        let path = self.0.join("upload.bin");
        fs::File::create(&path).unwrap().set_len(size).unwrap();
        path
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

struct Fixture {
    endpoint: String,
    thread: std::thread::JoinHandle<Vec<FixtureRequest>>,
}
impl Fixture {
    fn new(
        count: usize,
        mut respond: impl FnMut(&FixtureRequest) -> String + Send + 'static,
    ) -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let thread = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(90);
            let mut requests = Vec::new();
            while requests.len() < count {
                let (mut stream, _) = match listener.accept() {
                    Ok(stream) => stream,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        assert!(
                            Instant::now() < deadline,
                            "fixture did not receive expected requests"
                        );
                        std::thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(error) => panic!("{error}"),
                };
                // Accepted sockets can inherit O_NONBLOCK on macOS.
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(60)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(Duration::from_secs(60)))
                    .unwrap();
                let request = exchange(&mut stream, &mut respond).unwrap();
                requests.push(request);
            }
            requests
        });
        Self { endpoint, thread }
    }
    fn join(self) -> Vec<FixtureRequest> {
        self.thread.join().unwrap()
    }
}
// Keep wire framing independent of sockets so fragmented and binary bodies are
// covered even in environments that prohibit binding a loopback listener.
#[derive(Debug)]
struct FixtureRequest {
    head: String,
    body: Vec<u8>,
}
impl std::ops::Deref for FixtureRequest {
    type Target = str;
    fn deref(&self) -> &str {
        &self.head
    }
}
fn read_chunked(reader: &mut impl BufRead) -> io::Result<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "missing chunk size",
            ));
        }
        let size = usize::from_str_radix(line.trim().split(';').next().unwrap(), 16)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        if size == 0 {
            loop {
                line.clear();
                if reader.read_line(&mut line)? == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "missing trailer terminator",
                    ));
                }
                if line == "\r\n" {
                    return Ok(body);
                }
            }
        }
        let offset = body.len();
        body.resize(offset + size, 0);
        reader.read_exact(&mut body[offset..])?;
        let mut end = [0; 2];
        reader.read_exact(&mut end)?;
        if end != *b"\r\n" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid chunk terminator",
            ));
        }
    }
}
fn read_request(reader: &mut impl BufRead) -> io::Result<FixtureRequest> {
    let mut bytes = Vec::new();
    loop {
        let offset = bytes.len();
        if reader.read_until(b'\n', &mut bytes)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "incomplete request headers",
            ));
        }
        if &bytes[offset..] == b"\r\n" {
            break;
        }
    }
    let head = String::from_utf8(bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let mut body =
        if header(&head, "transfer-encoding").is_some_and(|v| v.eq_ignore_ascii_case("chunked")) {
            read_chunked(reader)?
        } else {
            let length = header(&head, "content-length")
                .unwrap_or("0")
                .parse::<usize>()
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            let mut body = vec![0; length];
            reader.read_exact(&mut body)?;
            body
        };
    if header(&head, "content-encoding").is_some_and(|v| {
        v.split(',')
            .any(|v| v.trim().eq_ignore_ascii_case("aws-chunked"))
    }) {
        body = read_chunked(&mut io::Cursor::new(body))?;
    }
    Ok(FixtureRequest { head, body })
}
fn exchange(
    stream: &mut (impl Read + Write),
    respond: &mut impl FnMut(&FixtureRequest) -> String,
) -> io::Result<FixtureRequest> {
    let request = read_request(&mut BufReader::new(&mut *stream))?;
    stream.write_all(respond(&request).as_bytes())?;
    Ok(request)
}
fn response(status: &str, headers: &str, body: &str) -> String {
    let length = if headers.to_ascii_lowercase().contains("content-length:") {
        String::new()
    } else {
        format!("Content-Length: {}\r\n", body.len())
    };
    format!("HTTP/1.1 {status}\r\n{length}{headers}Connection: close\r\n\r\n{body}")
}
fn ok(body: &str) -> String {
    response("200 OK", "ETag: \"fixture\"\r\n", body)
}
fn header<'a>(request: &'a str, name: &str) -> Option<&'a str> {
    request
        .split("\r\n\r\n")
        .next()
        .unwrap()
        .lines()
        .skip(1)
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case(name).then_some(value.trim())
        })
}
fn encryption_headers(request: &str) -> BTreeMap<String, String> {
    request
        .split("\r\n\r\n")
        .next()
        .unwrap()
        .lines()
        .skip(1)
        .filter_map(|line| {
            let (name, value) = line.split_once(':')?;
            let name = name.to_ascii_lowercase();
            (name.starts_with("x-amz-server-side-encryption")
                || name.starts_with("x-amz-copy-source-server-side-encryption")
                || name.starts_with("x-ms-encryption"))
            .then_some((name, value.trim().to_owned()))
        })
        .collect()
}
fn expected(mode: &Option<Value>, customer_only: bool, source: bool) -> BTreeMap<String, String> {
    let mode = mode.as_ref().unwrap_or(&Value::Null);
    let mut result = BTreeMap::new();
    let mut insert = |name: &str, value: &str| {
        result.insert(name.to_owned(), value.to_owned());
    };
    if mode["mode"] == "sse-c" {
        let prefix = if source {
            "x-amz-copy-source-server-side-encryption-customer"
        } else {
            "x-amz-server-side-encryption-customer"
        };
        insert(&format!("{prefix}-algorithm"), "AES256");
        let key = mode["customerKey"].as_str().unwrap();
        insert(&format!("{prefix}-key"), key);
        insert(
            &format!("{prefix}-key-md5"),
            if key == KEY {
                KEY_MD5
            } else {
                "4Funlf7OsLF0HL+vKU+fkg=="
            },
        );
    } else if !customer_only && !source {
        match mode["mode"].as_str() {
            Some("sse-s3") => insert("x-amz-server-side-encryption", "AES256"),
            Some("sse-kms" | "dsse-kms") => {
                insert(
                    "x-amz-server-side-encryption",
                    if mode["mode"] == "sse-kms" {
                        "aws:kms"
                    } else {
                        "aws:kms:dsse"
                    },
                );
                insert("x-amz-server-side-encryption-aws-kms-key-id", "alias/test");
                insert("x-amz-server-side-encryption-context", "eyJhIjoiYiJ9");
                if mode["mode"] == "sse-kms" {
                    insert("x-amz-server-side-encryption-bucket-key-enabled", "false");
                }
            }
            _ => {}
        }
    }
    result
}

#[test]
fn encryption_validation_modes_fields_keys_and_transport() {
    let s3 = profile("https://storage.example");
    for mode in modes() {
        assert!(Encryption::parse(mode.as_ref().unwrap_or(&Value::Null), &s3, false).is_ok());
    }
    let invalid = [
        json!({}),
        json!([]),
        json!({"mode":"unknown"}),
        json!({"mode":"bucketDefault","customerKey":KEY}),
        json!({"mode":"sse-s3","kmsKeyId":"key"}),
        json!({"mode":"sse-s3","unknown":true}),
        json!({"mode":"sse-kms","kmsEncryptionContext":{"a":1}}),
        json!({"mode":"sse-kms","kmsKeyId":1}),
        json!({"mode":"sse-kms","bucketKeyEnabled":"false"}),
        json!({"mode":"dsse-kms","bucketKeyEnabled":false}),
        json!({"mode":"sse-c"}),
        json!({"mode":"sse-c","customerKey":"invalid"}),
        json!({"mode":"sse-c","customerKey":aws_smithy_types::base64::encode([0;31])}),
        json!({"mode":"sse-c","customerKey":aws_smithy_types::base64::encode([0;33])}),
        json!({"mode":"sse-c","customerKey":KEY,"bucketKeyEnabled":true}),
        json!({"mode":"azure-scope","encryptionScope":"scope"}),
        json!({"mode":"azure-cpk","customerKey":KEY}),
    ];
    for mode in invalid {
        let error = Encryption::parse(&mode, &s3, false)
            .err()
            .expect("must reject invalid encryption");
        assert_eq!(error.code, "invalid_config");
        assert!(!format!("{error:?}").contains(KEY));
    }
    for endpoint in [
        "http://localhost:9000",
        "http://127.2.3.4",
        "http://[::1]",
        "https://storage.example",
    ] {
        assert!(Encryption::parse(&customer(), &profile(endpoint), false).is_ok());
    }
    for endpoint in [
        "http://storage.example",
        "http://localhost.example",
        "http://128.0.0.1",
        "ftp://127.0.0.1",
    ] {
        assert_eq!(
            Encryption::parse(&customer(), &profile(endpoint), false)
                .err()
                .unwrap()
                .code,
            "invalid_config"
        );
    }
    assert!(Encryption::parse(&json!({"mode":"sse-kms"}), &s3, true).is_err());
    assert!(Encryption::parse(&customer(), &s3, true).is_ok());
    let source = Encryption::parse(&source_customer(), &s3, true).unwrap();
    assert_eq!(
        source.customer_md5.as_deref(),
        Some("4Funlf7OsLF0HL+vKU+fkg==")
    );
    assert!(Encryption::parse(&json!({"mode":"bucketDefault"}), &s3, true).is_ok());
    let mut azure = profile("https://account.blob.core.windows.net");
    azure["endpointType"] = json!("azureBlob");
    for mode in [json!({"mode":"sse-s3"}), customer()] {
        assert_eq!(
            Encryption::parse(&mode, &azure, false).err().unwrap().code,
            "invalid_config"
        );
    }
    for mode in [
        json!({"mode":"azure-scope","encryptionScope":"scope"}),
        json!({"mode":"azure-cpk","customerKey":KEY}),
    ] {
        assert_eq!(
            Encryption::parse(&mode, &azure, false).err().unwrap().code,
            "unsupported_feature"
        );
    }
}

#[tokio::test]
async fn single_writes_folder_and_test_data_send_exact_headers_and_redact_output() {
    let directory = Directory::new();
    let file = directory.file(8);
    for mode in modes() {
        let fixture = Fixture::new(4, |_| ok(""));
        let profile = profile(&fixture.endpoint);
        let (result, _) = captured_call(
            "createFolder",
            with_mode(
                json!({"profile":profile,"bucketName":"bucket","key":"folder"}),
                &mode,
            ),
        )
        .await;
        result.unwrap();
        let (result, _) = captured_call("runPutTestData", with_mode(json!({"profile":profile,"config":{"bucketName":"bucket","objectCount":1,"versions":2,"objectSizeBytes":8}}), &mode)).await;
        assert_eq!(result.unwrap()["exitCode"], 0);
        let (result, logs) = captured_call(
            "startUpload",
            with_mode(
                json!({"profile":profile,"bucketName":"bucket","filePaths":[file]}),
                &mode,
            ),
        )
        .await;
        assert_eq!(result.unwrap()["status"], "completed");
        assert!(logs.iter().any(|line| line.contains("HttpSend")));
        for request in fixture.join() {
            assert!(request.starts_with("PUT"));
            assert_eq!(encryption_headers(&request), expected(&mode, false, false));
        }
    }
}

#[tokio::test]
async fn multipart_upload_encrypts_create_each_part_and_completion_without_changing_defaults() {
    let directory = Directory::new();
    let file = directory.file(6 * 1024 * 1024);
    for mode in modes() {
        let fixture = Fixture::new(4, |request| {
            if request.starts_with("POST") && request.lines().next().unwrap().contains("uploads") {
                ok("<InitiateMultipartUploadResult><UploadId>fixture-upload</UploadId></InitiateMultipartUploadResult>")
            } else if request.starts_with("POST") {
                ok("<CompleteMultipartUploadResult><ETag>\"fixture\"</ETag></CompleteMultipartUploadResult>")
            } else {
                ok("")
            }
        });
        let (result, _) = captured_call(
            "startUpload",
            with_mode(
                json!({"profile":profile(&fixture.endpoint),"bucketName":"bucket",
            "filePaths":[file],"multipartThresholdMiB":1,"multipartChunkMiB":5}),
                &mode,
            ),
        )
        .await;
        assert_eq!(result.unwrap()["partsCompleted"], 2);
        let requests = fixture.join();
        for request in &requests {
            let create = request.lines().next().unwrap().contains("uploads");
            assert_eq!(encryption_headers(request), expected(&mode, !create, false));
        }
        assert_eq!(
            requests
                .iter()
                .filter(|request| request.starts_with("PUT"))
                .count(),
            2
        );
    }
}

#[tokio::test]
async fn copy_and_move_apply_destination_and_source_keys_independently() {
    for method in ["copyObject", "moveObject"] {
        for mode in modes() {
            for source in [None, Some(source_customer())] {
                let fixture = Fixture::new(if method == "moveObject" { 3 } else { 2 }, |request| {
                    if request.starts_with("HEAD") {
                        response("200 OK", "Content-Length: 3\r\nETag: \"fixture\"\r\n", "")
                    } else if request.starts_with("DELETE") {
                        response("204 No Content", "", "")
                    } else {
                        ok("<CopyObjectResult><ETag>\"fixture\"</ETag></CopyObjectResult>")
                    }
                });
                let mut params = with_mode(
                    json!({"profile":profile(&fixture.endpoint),"sourceBucketName":"bucket","sourceKey":"source",
                    "destinationBucketName":"bucket","destinationKey":"destination","sourceVersionId":"version"}),
                    &mode,
                );
                if let Some(source) = &source {
                    params["sourceEncryption"] = source.clone();
                }
                let (result, _) = captured_call(method, params).await;
                assert_eq!(result.unwrap()["successCount"], 1);
                for request in fixture.join() {
                    let expected = if request.starts_with("HEAD") {
                        expected(&source, true, false)
                    } else if request.starts_with("DELETE") {
                        BTreeMap::new()
                    } else {
                        let mut headers = expected(&mode, false, false);
                        headers.extend(expected(&source, true, true));
                        headers
                    };
                    assert_eq!(encryption_headers(&request), expected);
                }
            }
        }
    }
}

#[tokio::test]
async fn multipart_copy_sends_customer_keys_on_every_part_and_keeps_legacy_inheritance() {
    let size = 5_u64 * 1024 * 1024 * 1024 + 1;
    let part_count = size.div_ceil(128 * 1024 * 1024) as usize;
    for mode in modes() {
        for inherit in [false, true] {
            let source = if inherit {
                Some(source_customer())
            } else {
                None
            };
            let fixture = Fixture::new(part_count + 4, move |request| {
                let first = request.lines().next().unwrap();
                if request.starts_with("HEAD") {
                    response(
                        "200 OK",
                        &format!(
                            "Content-Length: {size}\r\nETag: \"fixture\"\r\n{}",
                            if inherit {
                                "x-amz-server-side-encryption: aws:kms\r\nx-amz-server-side-encryption-aws-kms-key-id: inherited\r\nx-amz-server-side-encryption-bucket-key-enabled: true\r\n"
                            } else {
                                ""
                            }
                        ),
                        "",
                    )
                } else if first.contains("tagging") {
                    ok("<Tagging><TagSet/></Tagging>")
                } else if request.starts_with("POST") && first.contains("uploads") {
                    ok("<InitiateMultipartUploadResult><UploadId>fixture-upload</UploadId></InitiateMultipartUploadResult>")
                } else if request.starts_with("PUT") {
                    ok("<CopyPartResult><ETag>\"fixture\"</ETag></CopyPartResult>")
                } else {
                    ok("<CompleteMultipartUploadResult><ETag>\"fixture\"</ETag></CompleteMultipartUploadResult>")
                }
            });
            let mut params = with_mode(
                json!({"profile":profile(&fixture.endpoint),"sourceBucketName":"bucket","sourceKey":"source",
                "destinationBucketName":"bucket","destinationKey":"destination"}),
                &mode,
            );
            if let Some(source) = &source {
                params["sourceEncryption"] = source.clone();
            }
            let (result, _) = captured_call("copyObject", params).await;
            assert_eq!(result.unwrap()["successCount"], 1);
            let requests = fixture.join();
            for request in &requests {
                let first = request.lines().next().unwrap();
                let mut want = if request.starts_with("HEAD") {
                    expected(&source, true, false)
                } else if request.starts_with("GET") {
                    BTreeMap::new()
                } else if first.contains("uploads") {
                    expected(&mode, false, false)
                } else {
                    expected(&mode, true, false)
                };
                if request.starts_with("PUT") {
                    want.extend(expected(&source, true, true));
                }
                if inherit
                    && first.contains("uploads")
                    && matches!(
                        mode.as_ref().and_then(|value| value["mode"].as_str()),
                        None | Some("bucketDefault")
                    )
                {
                    want.insert("x-amz-server-side-encryption".into(), "aws:kms".into());
                    want.insert(
                        "x-amz-server-side-encryption-aws-kms-key-id".into(),
                        "inherited".into(),
                    );
                    want.insert(
                        "x-amz-server-side-encryption-bucket-key-enabled".into(),
                        "true".into(),
                    );
                }
                assert_eq!(encryption_headers(request), want);
            }
            assert_eq!(
                requests
                    .iter()
                    .filter(|request| request.starts_with("PUT"))
                    .count(),
                part_count
            );
        }
    }
}

#[tokio::test]
async fn download_head_get_and_each_retried_range_use_only_customer_headers() {
    for ranged in [false, true] {
        for mode in modes() {
            let directory = Directory::new();
            let size = if ranged { 2 * 1024 * 1024 } else { 8 };
            let mut truncated = false;
            let fixture = Fixture::new(if ranged { 4 } else { 2 }, move |request| {
                if request.starts_with("HEAD") {
                    return response(
                        "200 OK",
                        &format!("Content-Length: {size}\r\nETag: \"fixture\"\r\n"),
                        "",
                    );
                }
                if let Some(range) = header(request, "range") {
                    let (start, end) = range
                        .strip_prefix("bytes=")
                        .unwrap()
                        .split_once('-')
                        .unwrap();
                    let length =
                        end.parse::<usize>().unwrap() - start.parse::<usize>().unwrap() + 1;
                    let broken = !truncated;
                    truncated = true;
                    response("206 Partial Content", &format!("Content-Length: {length}\r\nContent-Range: bytes {start}-{end}/{size}\r\nETag: \"fixture\"\r\n"), &"R".repeat(length - usize::from(broken)))
                } else {
                    ok(&"R".repeat(size))
                }
            });
            let mut p = profile(&fixture.endpoint);
            p["maxAttempts"] = json!(2);
            let (result, logs) = captured_call(
                "startDownload",
                with_mode(
                    json!({"profile":p,"bucketName":"bucket","keys":["download.bin"],
                "destinationPath":directory.0,"multipartThresholdMiB":1,"multipartChunkMiB":1}),
                    &mode,
                ),
            )
            .await;
            assert_eq!(result.unwrap()["bytesTransferred"], size);
            assert_eq!(
                fs::read(directory.0.join("download.bin")).unwrap(),
                vec![b'R'; size]
            );
            assert!(logs.iter().any(|line| line.contains("HttpSend")));
            for request in fixture.join() {
                assert_eq!(encryption_headers(&request), expected(&mode, true, false));
            }
        }
    }
}

#[tokio::test]
async fn object_details_sends_customer_key_and_normalizes_reported_encryption() {
    let reports = [("", None), ("x-amz-server-side-encryption: AES256\r\n", Some("sse-s3")),
        ("x-amz-server-side-encryption: aws:kms\r\nx-amz-server-side-encryption-aws-kms-key-id: reported-key\r\nx-amz-server-side-encryption-bucket-key-enabled: false\r\n", Some("sse-kms")),
        ("x-amz-server-side-encryption: aws:kms:dsse\r\n", Some("dsse-kms")),
        ("x-amz-server-side-encryption-customer-algorithm: AES256\r\nx-amz-server-side-encryption-customer-key-md5: reported-md5\r\n", Some("sse-c"))];
    for (report, reported_mode) in reports {
        for mode in modes() {
            let fixture = Fixture::new(2, move |request| {
                if request.starts_with("HEAD") {
                    response("200 OK", &format!("Content-Length: 3\r\n{report}"), "")
                } else {
                    ok("<Tagging><TagSet/></Tagging>")
                }
            });
            let (result, _) = captured_call("getObjectDetails", with_mode(json!({"profile":profile(&fixture.endpoint),"bucketName":"bucket","key":"source"}), &mode)).await;
            let result = result.unwrap();
            assert_eq!(result["encryption"]["mode"].as_str(), reported_mode);
            if reported_mode.is_none() {
                assert!(result.get("encryption").is_none());
            }
            if reported_mode == Some("sse-kms") {
                assert_eq!(result["encryption"]["kmsKeyId"], "reported-key");
                assert_eq!(result["encryption"]["bucketKeyEnabled"], false);
            }
            if reported_mode == Some("sse-c") {
                assert_eq!(result["encryption"]["customerKeyMd5"], "reported-md5");
            }
            for request in fixture.join() {
                assert_eq!(
                    encryption_headers(&request),
                    if request.starts_with("HEAD") {
                        expected(&mode, true, false)
                    } else {
                        BTreeMap::new()
                    }
                );
            }
        }
    }
}

#[tokio::test]
async fn presign_rejects_customer_keys_and_ignores_other_modes() {
    let p = profile("http://127.0.0.1:1");
    for mode in modes() {
        let (result, _) = captured_call(
            "generatePresignedUrl",
            with_mode(
                json!({"profile":p,"bucketName":"bucket","key":"source"}),
                &mode,
            ),
        )
        .await;
        if mode.as_ref().is_some_and(|value| value["mode"] == "sse-c") {
            assert_eq!(result.unwrap_err().code, "unsupported_feature");
        } else {
            assert!(!result.unwrap()["url"]
                .as_str()
                .unwrap()
                .contains("server-side-encryption"));
        }
    }
}

#[tokio::test]
async fn capabilities_report_all_six_modes_without_probing() {
    let result = call("getCapabilities", json!({})).await.unwrap();
    for mode in [
        "sse-s3",
        "sse-kms",
        "dsse-kms",
        "sse-c",
        "azure-scope",
        "azure-cpk",
    ] {
        let key = format!("object.encryption.{mode}");
        let items = result["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["key"] == key)
            .collect::<Vec<_>>();
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["state"],
            if mode.starts_with("azure") {
                "unsupported"
            } else {
                "supported"
            }
        );
        if mode.starts_with("azure") {
            assert!(!items[0]["reason"].as_str().unwrap().is_empty());
        }
    }
}

#[tokio::test]
async fn provider_errors_add_precise_hints_keep_codes_and_never_retry_a_different_mode() {
    let cases = [
        (
            "KMS.AccessDeniedException",
            "kms:GenerateDataKey access denied",
            Some("kms_access_denied"),
        ),
        (
            "KMS.DisabledException",
            "kms: key disabled",
            Some("kms_key_unavailable"),
        ),
        (
            "AccessDenied",
            "SSE-C is blocked for this bucket",
            Some("sse_c_blocked"),
        ),
        ("AccessDenied", "Access Denied", None),
        (
            "InvalidRequest",
            "customer key is required",
            Some("sse_c_key_required"),
        ),
        (
            "InvalidRequest",
            "customer key does not match",
            Some("sse_c_key_mismatch"),
        ),
    ];
    for (code, message, hint) in cases {
        let fixture = Fixture::new(1, move |_| {
            response(
                "403 Forbidden",
                "",
                &format!("<Error><Code>{code}</Code><Message>{message} {KEY}</Message></Error>"),
            )
        });
        let (result, logs) = captured_call("createFolder", json!({"profile":profile(&fixture.endpoint),"bucketName":"bucket","key":"folder","encryption":customer()})).await;
        let error = result.unwrap_err();
        assert_eq!(error.details["encryptionHint"].as_str(), hint);
        assert_eq!(error.details["awsCode"], code);
        if code == "AccessDenied" {
            assert_eq!(error.code, "auth_failed");
        }
        assert!(!format!("{error:?}").contains(KEY));
        assert!(logs.join("\n").contains("[redacted]"));
        assert_eq!(
            encryption_headers(&fixture.join()[0]),
            expected(&Some(customer()), false, false)
        );
    }
    for method in ["getObjectDetails", "startDownload"] {
        let directory = Directory::new();
        let fixture = Fixture::new(1, |_| response("400 Bad Request", "", ""));
        let error = call(method, json!({"profile":profile(&fixture.endpoint),"bucketName":"bucket","key":"source","keys":["source"],"destinationPath":directory.0})).await.unwrap_err();
        assert_eq!(error.details["encryptionHint"], "sse_c_key_required");
        assert!(encryption_headers(&fixture.join()[0]).is_empty());
    }
}

#[tokio::test]
async fn secret_fields_headers_diagnostics_and_persisted_benchmark_state_are_redacted() {
    for name in [
        "x-amz-server-side-encryption-customer-key",
        "X-Amz-Copy-Source-Server-Side-Encryption-Customer-Key",
        "x-ms-encryption-key",
        "customerKey",
    ] {
        assert_eq!(sanitize_header_value(name, KEY), "[redacted]");
    }
    let value = json!({"encryption":{"customerKey":KEY},"nested":[{"customerKey":KEY}]});
    assert!(!secret_hygiene::value(value.clone())
        .to_string()
        .contains(KEY));
    assert!(!summarize_body("application/json", value.to_string().as_bytes()).contains(KEY));
    secret_hygiene::SECRETS.scope(vec![KEY.into()], async {
        let state = json!({"id":format!("secret-test-{}",Uuid::new_v4()), "config":value,"resultSummary":{"message":KEY}});
        assert!(!public_benchmark_state(&state).to_string().contains(KEY));
        let mut diagnostics = json!({});
        diagnostics[KEY] = json!(KEY);
        assert!(!secret_hygiene::value(diagnostics).to_string().contains(KEY));
        write_benchmark_state(&state).unwrap();
        let path = benchmark_state_path(state["id"].as_str().unwrap()).unwrap();
        assert!(!fs::read_to_string(&path).unwrap().contains(KEY));
        fs::remove_file(path).unwrap();
        let directory = Directory::new();
        let output_state = json!({"config":{"csvOutputPath":directory.0.join("result.csv"),"jsonOutputPath":directory.0.join("result.json"),"logFilePath":directory.0.join("result.log")},
            "resultSummary":{"customerKey":KEY,"message":KEY},"liveLog":[KEY],"history":[{"key":KEY}]});
        persist_benchmark_outputs(&output_state).unwrap();
        for name in ["result.csv", "result.json", "result.log"] {
            assert!(!fs::read_to_string(directory.0.join(name)).unwrap().contains(KEY));
        }
        assert!(!format!("{:?}", SidecarError::new("unknown", KEY)).contains(KEY));
        let result = run_bounded(1, 1, |_| async {
            assert!(!secret_hygiene::text(KEY).contains(KEY));
            Ok(())
        }, |_| {}).await;
        result.unwrap();
    }).await;
}

#[test]
fn bucket_encryption_preserves_all_rule_fields_including_blocked_types() {
    let raw = json!({"Rules":[
        {"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"key"},"BucketKeyEnabled":false,"BlockedEncryptionTypes":{"EncryptionType":["SSE-C","NONE","future-type"]}},
        {"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true,"BlockedEncryptionTypes":{"EncryptionType":["NONE"]}}]});
    let result = lifecycle::without_nulls(encryption_raw(
        &parse_encryption_configuration(&raw).unwrap(),
    ));
    assert_eq!(result, raw);
    assert_eq!(
        lifecycle::without_nulls(encryption_raw(
            &parse_encryption_configuration(&result).unwrap()
        )),
        raw
    );
}

#[tokio::test]
async fn bucket_admin_read_then_put_round_trips_blocked_types_on_the_wire() {
    let xml = "<ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>key</KMSMasterKeyID></ApplyServerSideEncryptionByDefault><BucketKeyEnabled>false</BucketKeyEnabled><BlockedEncryptionTypes><EncryptionType>SSE-C</EncryptionType><EncryptionType>NONE</EncryptionType></BlockedEncryptionTypes></Rule></ServerSideEncryptionConfiguration>";
    let fixture = Fixture::new(15, move |request| {
        let first = request.lines().next().unwrap();
        if request.starts_with("PUT") {
            ok("")
        } else if first.contains("encryption") {
            ok(xml)
        } else {
            response(
                "404 Not Found",
                "",
                "<Error><Code>NoSuchConfiguration</Code></Error>",
            )
        }
    });
    let p = profile(&fixture.endpoint);
    let state = call(
        "getBucketAdminState",
        json!({"profile":p,"bucketName":"bucket"}),
    )
    .await
    .unwrap();
    let result = call(
        "putBucketEncryption",
        json!({"profile":p,"bucketName":"bucket","encryptionJson":state["encryptionJson"]}),
    )
    .await
    .unwrap();
    assert_eq!(state["encryptionJson"], result["encryptionJson"]);
    let requests = fixture.join();
    let put = requests
        .iter()
        .find(|request| request.starts_with("PUT"))
        .unwrap();
    let body = std::str::from_utf8(&put.body).unwrap();
    assert!(body.contains("<BlockedEncryptionTypes><EncryptionType>SSE-C</EncryptionType><EncryptionType>NONE</EncryptionType></BlockedEncryptionTypes>"));
    assert!(body.contains("<BucketKeyEnabled>false</BucketKeyEnabled>"));
    assert!(body.contains("<KMSMasterKeyID>key</KMSMasterKeyID>"));
}

#[tokio::test]
async fn customer_presign_is_rejected_before_client_initialization() {
    let error = call("generatePresignedUrl", json!({"profile":profile("http://127.0.0.1:1"),"bucketName":"bucket","key":"object","encryption":customer()})).await.unwrap_err();
    assert_eq!(error.code, "unsupported_feature");
}

#[test]
fn reported_encryption_omits_unreported_fields_and_maps_all_s3_algorithms() {
    use aws_sdk_s3::operation::head_object::HeadObjectOutput;
    assert!(object_encryption::reported(&HeadObjectOutput::builder().build()).is_none());
    for (algorithm, mode) in [
        ("AES256", "sse-s3"),
        ("aws:kms", "sse-kms"),
        ("aws:kms:dsse", "dsse-kms"),
    ] {
        let output = HeadObjectOutput::builder()
            .server_side_encryption(ServerSideEncryption::from(algorithm))
            .build();
        assert_eq!(
            object_encryption::reported(&output).unwrap(),
            json!({"mode":mode})
        );
    }
    let output = HeadObjectOutput::builder()
        .sse_customer_algorithm("AES256")
        .sse_customer_key_md5(KEY_MD5)
        .build();
    assert_eq!(
        object_encryption::reported(&output).unwrap(),
        json!({"mode":"sse-c","customerKeyMd5":KEY_MD5})
    );
    let output = HeadObjectOutput::builder()
        .server_side_encryption(ServerSideEncryption::AwsKms)
        .ssekms_key_id("key")
        .bucket_key_enabled(false)
        .build();
    assert_eq!(
        object_encryption::reported(&output).unwrap(),
        json!({"mode":"sse-kms","kmsKeyId":"key","bucketKeyEnabled":false})
    );
}

#[test]
fn encryption_error_hints_require_provider_evidence() {
    for (code, message, hint) in [
        (
            "KMS.AccessDeniedException",
            "access denied",
            Some("kms_access_denied"),
        ),
        (
            "AccessDenied",
            "kms:GenerateDataKey is not authorized",
            Some("kms_access_denied"),
        ),
        (
            "KMS.NotFoundException",
            "key unavailable",
            Some("kms_key_unavailable"),
        ),
        ("AccessDenied", "SSE-C is blocked", Some("sse_c_blocked")),
        ("AccessDenied", "Access Denied", None),
        (
            "InvalidRequest",
            "customer key required",
            Some("sse_c_key_required"),
        ),
        (
            "InvalidRequest",
            "customer key does not match",
            Some("sse_c_key_mismatch"),
        ),
        ("InvalidRequest", "invalid configuration", None),
        (
            "AccessDenied",
            "Server-side encryption is required by policy",
            Some("encryption_required_by_policy"),
        ),
        (
            "NotImplemented",
            "This encryption mode is not supported",
            Some("unsupported_by_endpoint"),
        ),
    ] {
        assert_eq!(object_encryption::hint(code, message), hint);
    }
}

#[test]
fn request_future_sizes_stay_bounded() {
    let request = || Request {
        request_id: "size".into(),
        method: "health".into(),
        params: Value::Null,
    };
    // Boxing method futures keeps the largest SDK branch out of every caller.
    assert!(std::mem::size_of_val(&dispatch_request(request())) < 1024);
    assert!(std::mem::size_of_val(&handle_request(request())) < 2048);
}

#[test]
fn bucket_admin_dispatch_fits_default_worker_stack() {
    #[derive(Debug)]
    struct StopBeforeTransmit(Arc<Mutex<usize>>);
    impl Intercept for StopBeforeTransmit {
        fn name(&self) -> &'static str {
            "StopBeforeTransmit"
        }
        fn modify_before_transmit(
            &self,
            _: &mut BeforeTransmitInterceptorContextMut<'_>,
            _: &RuntimeComponents,
            _: &mut ConfigBag,
        ) -> Result<(), BoxError> {
            *self.0.lock().unwrap() += 1;
            Err(io::Error::other("stack test stops before network").into())
        }
    }
    // Exercise both direct polling (as in the wire tests) and the production
    // spawn path, with 2 MiB stacks. Every admin operation reaches the SDK.
    std::thread::Builder::new().stack_size(2 * 1024 * 1024).spawn(|| {
        Runtime::new().unwrap().block_on(async {
            let mut value = profile("http://127.0.0.1:1");
            value["accessKey"] = json!(Uuid::new_v4().to_string());
            let parsed = parse_profile(&value).unwrap();
            let calls = Arc::new(Mutex::new(0));
            let client = Client::from_conf(aws_sdk_s3::config::Builder::new()
                .behavior_version_latest().region(Region::new("us-east-1"))
                .credentials_provider(Credentials::new("fixture", "fixture", None, None, "test"))
                .endpoint_url("http://127.0.0.1:1").force_path_style(true)
                .retry_config(RetryConfig::standard().with_max_attempts(1))
                .interceptor(StopBeforeTransmit(calls.clone())).build());
            CLIENTS.get_or_init(Default::default).lock().await.push((parsed.clone(), client));
            let request = || Request { request_id: "stack".into(), method: "getBucketAdminState".into(),
                params: json!({"profile":value,"bucketName":"bucket"}) };
            for result in [handle_request(request()).await, tokio::spawn(handle_request(request())).await.unwrap()] {
                assert_eq!(result.unwrap()["apiCalls"].as_array().unwrap().len(), 7);
            }
            let request = Request { request_id: "stack-put".into(), method: "putBucketEncryption".into(),
                params: json!({"profile":value,"bucketName":"bucket","encryptionJson":"{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}"}) };
            assert!(tokio::spawn(handle_request(request)).await.unwrap().is_err());
            assert_eq!(*calls.lock().unwrap(), 15);
            CLIENTS.get().unwrap().lock().await.retain(|(profile, _)| profile != &parsed);
        });
    }).unwrap().join().unwrap();
}

#[test]
fn fixture_parses_fragmented_binary_bodies_and_exact_content_length() {
    let body = vec![0xff; 6 * 1024 * 1024];
    let mut bytes = format!(
        "PUT /bucket/object HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
        body.len()
    )
    .into_bytes();
    bytes.extend_from_slice(&body);
    bytes.extend_from_slice(b"next request");
    // A tiny buffer forces headers and body to cross many read boundaries.
    let mut reader = BufReader::with_capacity(3, io::Cursor::new(bytes));
    let request = read_request(&mut reader).unwrap();
    assert!(request.starts_with("PUT /bucket/object"));
    assert_eq!(request.body, body);
    let mut remaining = Vec::new();
    reader.read_to_end(&mut remaining).unwrap();
    assert_eq!(remaining, b"next request");
    for bytes in [
        b"GET / HTTP/1.1\r\n".as_slice(),
        b"PUT / HTTP/1.1\r\nContent-Length: 2\r\n\r\nx",
    ] {
        assert_eq!(
            read_request(&mut io::Cursor::new(bytes))
                .unwrap_err()
                .kind(),
            io::ErrorKind::UnexpectedEof
        );
    }
}

#[test]
fn fixture_decodes_http_and_aws_chunks_with_trailers() {
    let chunks = b"2;chunk-signature=fixture\r\n\xff\0\r\n1\r\nx\r\n0\r\nx-amz-checksum-crc32: fixture\r\n\r\n";
    for head in [
        "Transfer-Encoding: chunked\r\n".to_owned(),
        format!(
            "Content-Encoding: aws-chunked\r\nContent-Length: {}\r\n",
            chunks.len()
        ),
    ] {
        let mut bytes = format!("PUT / HTTP/1.1\r\n{head}\r\n").into_bytes();
        bytes.extend_from_slice(chunks);
        let request =
            read_request(&mut BufReader::with_capacity(2, io::Cursor::new(bytes))).unwrap();
        assert_eq!(request.body, b"\xff\0x");
    }
    assert_eq!(
        read_chunked(&mut io::Cursor::new(b"1\r\nx!!"))
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidData
    );
}

#[test]
fn fixture_exchange_responds_after_reading_body_and_preserves_head_lengths() {
    struct MemoryStream {
        input: io::Cursor<Vec<u8>>,
        output: Vec<u8>,
    }
    impl Read for MemoryStream {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let length = buffer.len().min(2);
            self.input.read(&mut buffer[..length])
        }
    }
    impl Write for MemoryStream {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            self.output.extend_from_slice(buffer);
            Ok(buffer.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut stream = MemoryStream {
        input: io::Cursor::new(b"PUT / HTTP/1.1\r\nContent-Length: 2\r\n\r\n\xff\0".to_vec()),
        output: Vec::new(),
    };
    exchange(&mut stream, &mut |request| {
        assert_eq!(request.body, b"\xff\0");
        response(
            "403 Forbidden",
            "",
            "<Error><Code>AccessDenied</Code></Error>",
        )
    })
    .unwrap();
    let output = String::from_utf8(stream.output).unwrap();
    assert_eq!(header(&output, "content-length"), Some("40"));
    assert!(output.ends_with("<Error><Code>AccessDenied</Code></Error>"));
    assert_eq!(
        header(
            &response("200 OK", "Content-Length: 100\r\n", ""),
            "content-length"
        ),
        Some("100")
    );
}

#[tokio::test]
async fn sdk_builds_exact_encryption_headers_without_network() {
    let client = Client::from_conf(
        aws_sdk_s3::config::Builder::new()
            .behavior_version_latest()
            .region(Region::new("us-east-1"))
            .credentials_provider(Credentials::new("fixture", "fixture", None, None, "test"))
            .endpoint_url("http://127.0.0.1:1")
            .force_path_style(true)
            .retry_config(RetryConfig::standard().with_max_attempts(1))
            .build(),
    );
    // Stop after SDK serialization. No connection is opened, even on failure.
    macro_rules! check_headers {
        ($builder:expr, $expected:expr) => {{
            let captured = Arc::new(Mutex::new(None));
            let output = captured.clone();
            let result = $builder
                .customize()
                .map_request(move |request| {
                    let head = format!(
                        "{} {} HTTP/1.1\r\n{}\r\n",
                        request.method(),
                        request.uri(),
                        request
                            .headers()
                            .iter()
                            .map(|(name, value)| format!("{name}: {value}\r\n"))
                            .collect::<String>()
                    );
                    *output.lock().unwrap() = Some(encryption_headers(&head));
                    Err::<aws_sdk_s3::config::http::HttpRequest, _>(io::Error::other(
                        "captured before sending",
                    ))
                })
                .send()
                .await;
            assert!(result.is_err());
            assert_eq!(
                captured
                    .lock()
                    .unwrap()
                    .take()
                    .expect("SDK did not build request"),
                $expected
            );
        }};
    }
    for mode in modes() {
        let encryption = Encryption::parse(
            mode.as_ref().unwrap_or(&Value::Null),
            &profile("http://127.0.0.1:1"),
            false,
        )
        .unwrap();
        check_headers!(
            encryption_write!(client.put_object().bucket("bucket").key("key"), &encryption),
            expected(&mode, false, false)
        );
        check_headers!(
            encryption_write!(
                client.create_multipart_upload().bucket("bucket").key("key"),
                &encryption
            ),
            expected(&mode, false, false)
        );
        check_headers!(
            encryption_customer!(
                client
                    .upload_part()
                    .bucket("bucket")
                    .key("key")
                    .upload_id("upload")
                    .part_number(1),
                &encryption
            ),
            expected(&mode, true, false)
        );
        check_headers!(
            encryption_customer!(
                client
                    .complete_multipart_upload()
                    .bucket("bucket")
                    .key("key")
                    .upload_id("upload"),
                &encryption
            ),
            expected(&mode, true, false)
        );
        check_headers!(
            encryption_customer!(
                client.head_object().bucket("bucket").key("key"),
                &encryption
            ),
            expected(&mode, true, false)
        );
        check_headers!(
            encryption_customer!(
                client
                    .get_object()
                    .bucket("bucket")
                    .key("key")
                    .range("bytes=0-7"),
                &encryption
            ),
            expected(&mode, true, false)
        );
        for source in [None, Some(source_customer())] {
            let source_encryption = Encryption::parse(
                source.as_ref().unwrap_or(&Value::Null),
                &profile("http://127.0.0.1:1"),
                true,
            )
            .unwrap();
            let mut want = expected(&mode, false, false);
            want.extend(expected(&source, true, true));
            check_headers!(
                encryption_source!(
                    encryption_write!(
                        client
                            .copy_object()
                            .bucket("bucket")
                            .key("key")
                            .copy_source("bucket/source"),
                        &encryption
                    ),
                    &source_encryption
                ),
                want
            );
            let mut want = expected(&mode, true, false);
            want.extend(expected(&source, true, true));
            check_headers!(
                encryption_source!(
                    encryption_customer!(
                        client
                            .upload_part_copy()
                            .bucket("bucket")
                            .key("key")
                            .copy_source("bucket/source")
                            .upload_id("upload")
                            .part_number(1),
                        &encryption
                    ),
                    &source_encryption
                ),
                want
            );
        }
    }
}

#[path = "client_encryption_wire_tests.rs"]
mod payload;
