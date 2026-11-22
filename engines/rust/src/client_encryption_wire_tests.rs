use super::*;
use crate::client_encryption::{
    tests::{object, plaintext, vectors},
    CHUNK, SEALED,
};
use std::sync::atomic::{AtomicBool, Ordering as MemoryOrdering};

// Binary, concurrent variant of the engine loopback fixture. Workers respond
// independently so retries and completions really can arrive out of order.
pub(crate) struct BinaryFixture {
    pub(crate) endpoint: String,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl BinaryFixture {
    pub(crate) fn new(respond: impl Fn(&FixtureRequest) -> Vec<u8> + Send + Sync + 'static) -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let respond = Arc::new(respond);
        let thread = std::thread::spawn(move || {
            let mut workers = Vec::new();
            while !stopped.load(MemoryOrdering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let respond = respond.clone();
                        workers.push(std::thread::spawn(move || {
                            stream.set_nonblocking(false).unwrap();
                            stream
                                .set_read_timeout(Some(Duration::from_secs(10)))
                                .unwrap();
                            stream
                                .set_write_timeout(Some(Duration::from_secs(10)))
                                .unwrap();
                            let mut reader = BufReader::new(&mut stream);
                            // A range worker can cancel a connection before sending
                            // its HTTP request when another range fails authentication.
                            if reader.fill_buf().unwrap().is_empty() {
                                return;
                            }
                            let request = read_request(&mut reader).unwrap();
                            stream.write_all(&respond(&request)).unwrap();
                        }));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(2))
                    }
                    Err(error) => panic!("{error}"),
                }
            }
            for worker in workers {
                worker.join().unwrap();
            }
        });
        Self {
            endpoint,
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for BinaryFixture {
    fn drop(&mut self) {
        self.stop.store(true, MemoryOrdering::SeqCst);
        self.thread.take().unwrap().join().unwrap();
    }
}
pub(crate) fn binary(status: &str, headers: &str, body: &[u8]) -> Vec<u8> {
    let mut output = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\n{headers}Connection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    output.extend_from_slice(body);
    output
}
#[derive(Default)]
struct Stored {
    object: Vec<u8>,
    parts: BTreeMap<u64, Vec<u8>>,
    attempts: Vec<(u64, Vec<u8>)>,
    finished: Vec<u64>,
    ranges: Vec<(u64, u64)>,
    retry_range: bool,
    puts: Vec<Vec<u8>>,
    plain_gets: usize,
    aborts: usize,
    requests: Vec<(String, BTreeMap<String, String>)>,
}
fn storage_fixture(
    state: Arc<Mutex<Stored>>,
    customer_headers: bool,
    retry_parts: bool,
) -> BinaryFixture {
    BinaryFixture::new(move |request| {
        let first = request.lines().next().unwrap();
        let headers = request
            .head
            .split("\r\n\r\n")
            .next()
            .unwrap()
            .lines()
            .skip(1)
            .filter_map(|line| line.split_once(':'))
            .map(|(name, value)| (name.to_ascii_lowercase(), value.trim().to_owned()))
            .filter(|(name, _)| {
                !matches!(
                    name.as_str(),
                    "authorization" | "x-amz-date" | "amz-sdk-invocation-id" | "amz-sdk-request"
                )
            })
            .collect();
        state
            .lock()
            .unwrap()
            .requests
            .push((first.to_owned(), headers));
        if !customer_headers {
            assert!(encryption_headers(request).is_empty());
        }
        if customer_headers && !request.starts_with("DELETE") {
            assert_eq!(
                header(request, "x-amz-server-side-encryption-customer-key"),
                Some(KEY)
            );
        }
        assert!(!request.head.contains("fileKey"));
        assert!(!request.head.contains("hidden-report.pdf"));
        if request.starts_with("HEAD") {
            let size = state.lock().unwrap().object.len();
            return format!("HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nETag: \"fixture\"\r\nConnection: close\r\n\r\n").into_bytes();
        }
        if request.starts_with("GET") {
            assert_eq!(header(request, "if-match"), Some("\"fixture\""));
            let mut state = state.lock().unwrap();
            if let Some(range) = header(request, "range") {
                let (start, end) = range
                    .strip_prefix("bytes=")
                    .unwrap()
                    .split_once('-')
                    .unwrap();
                let (start, end) = (start.parse::<u64>().unwrap(), end.parse::<u64>().unwrap());
                state.ranges.push((start, end));
                // Retry chunk zero once; the nonce request remains successful.
                if state.retry_range && end - start + 1 > 16 {
                    state.retry_range = false;
                    return binary(
                        "503 Service Unavailable",
                        "",
                        b"<Error><Code>SlowDown</Code></Error>",
                    );
                }
                return binary(
                    "206 Partial Content",
                    &format!(
                        "ETag: \"fixture\"\r\nContent-Range: bytes {start}-{end}/{}\r\n",
                        state.object.len()
                    ),
                    &state.object[start as usize..=end as usize],
                );
            }
            state.plain_gets += 1;
            return binary("200 OK", "ETag: \"fixture\"\r\n", &state.object);
        }
        if request.starts_with("DELETE") {
            state.lock().unwrap().aborts += 1;
            return binary("204 No Content", "", b"");
        }
        if request.starts_with("POST") {
            if first.contains("uploads") {
                return binary("200 OK", "", b"<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>");
            }
            let mut state = state.lock().unwrap();
            let expected: Vec<_> = state.parts.keys().copied().collect();
            let xml = std::str::from_utf8(&request.body).unwrap();
            let mut previous = 0;
            for index in expected {
                let position = xml
                    .find(&format!("<PartNumber>{index}</PartNumber>"))
                    .unwrap();
                assert!(position >= previous);
                previous = position;
            }
            state.object = state
                .parts
                .values()
                .flat_map(|part| part.iter().copied())
                .collect();
            return binary("200 OK", "", b"<CompleteMultipartUploadResult><ETag>\"fixture\"</ETag></CompleteMultipartUploadResult>");
        }
        assert!(request.starts_with("PUT"));
        if first.contains("partNumber=") {
            let url = url::Url::parse(&format!(
                "http://fixture{}",
                first.split_whitespace().nth(1).unwrap()
            ))
            .unwrap();
            let index = url
                .query_pairs()
                .find(|(name, _)| name == "partNumber")
                .unwrap()
                .1
                .parse::<u64>()
                .unwrap();
            let fail = {
                let mut state = state.lock().unwrap();
                let fail = retry_parts
                    && index == 1
                    && !state.attempts.iter().any(|(part, _)| *part == index);
                state.attempts.push((index, request.body.clone()));
                fail
            };
            if fail {
                // Allow part two to finish before the first part is retried.
                let deadline = Instant::now() + Duration::from_secs(10);
                while !state.lock().unwrap().finished.contains(&2) {
                    assert!(
                        Instant::now() < deadline,
                        "part two did not finish before retry"
                    );
                    std::thread::sleep(Duration::from_millis(2));
                }
                return binary(
                    "503 Service Unavailable",
                    "",
                    b"<Error><Code>SlowDown</Code></Error>",
                );
            }
            let mut state = state.lock().unwrap();
            state.parts.insert(index, request.body.clone());
            state.finished.push(index);
        } else {
            let mut state = state.lock().unwrap();
            state.puts.push(request.body.clone());
            state.object = request.body.clone();
        }
        binary("200 OK", "ETag: \"fixture\"\r\n", b"")
    })
}

#[tokio::test]
async fn age_payload_single_and_multipart_round_trip_retry_and_corruption_never_publish() {
    let cases = vectors();
    for (case, threshold) in [
        (&cases[0], 32),
        (&cases[4], 32),
        (&cases[7], 32),
        (&cases[7], 1),
    ] {
        let directory = Directory::new();
        let source = directory.0.join("source");
        let destination = directory.0.join("downloads");
        let plain = plaintext(case);
        fs::write(&source, &plain).unwrap();
        let expected = object(case);
        let state = Arc::new(Mutex::new(Stored {
            retry_range: true,
            ..Stored::default()
        }));
        let fixture = storage_fixture(state.clone(), true, threshold == 1);
        let mut p = profile(&fixture.endpoint);
        p["maxAttempts"] = json!(3);
        let mut upload = json!({"profile":p,"bucketName":"bucket","filePaths":[source],
            "multipartThresholdMiB":threshold,"multipartChunkMiB":5,"encryption":customer(),
            "clientEncryption":{"format":"age-v1","header":case["header"],
                "payloadNonce":case["payloadNonce"],"fileKey":case["fileKey"]}});
        upload["objectKeyByPath"][source.to_string_lossy().as_ref()] = json!("prefix/vector.age");
        let (result, lines) = captured_call("startUpload", upload).await;
        let result = result.unwrap();
        assert!(!lines.join("\n").contains(case["fileKey"].as_str().unwrap()));
        assert_eq!(result["totalBytes"], expected.len() as u64);
        assert_eq!(state.lock().unwrap().object, expected);
        if threshold == 1 {
            let state = state.lock().unwrap();
            assert_eq!(state.finished.len(), 3);
            assert_ne!(state.finished[0], 1);
            let retried: Vec<_> = state
                .attempts
                .iter()
                .filter(|(index, _)| *index == 1)
                .collect();
            assert_eq!(retried.len(), 2);
            assert_eq!(retried[0].1, retried[1].1);
            for (index, bytes) in &state.parts {
                let start = (*index as usize - 1) * 5 * 1024 * 1024;
                assert_eq!(
                    bytes,
                    &expected[start..(start + 5 * 1024 * 1024).min(expected.len())]
                );
            }
        }
        let download = json!({"profile":p,"bucketName":"bucket","keys":["prefix/vector.age"],
            "destinationPath":destination,"encryption":customer(),
            "clientEncryption":{"format":"age-v1","headerLength":case["headerLength"],"fileKey":case["fileKey"]}});
        let (result, lines) = captured_call("startDownload", download.clone()).await;
        assert!(!lines.join("\n").contains(case["fileKey"].as_str().unwrap()));
        assert_eq!(result.unwrap()["totalBytes"], expected.len() as u64);
        assert_eq!(fs::read(destination.join("vector")).unwrap(), plain);
        // KeepBoth and replace both use the decrypted base name.
        let mut again = download.clone();
        again["conflictPolicy"] = json!("keepBoth");
        call("startDownload", again).await.unwrap();
        assert_eq!(fs::read_dir(&destination).unwrap().count(), 2);
        let mut replace = download.clone();
        replace["conflictPolicy"] = json!("replace");
        call("startDownload", replace).await.unwrap();
        assert_eq!(fs::read_dir(&destination).unwrap().count(), 2);
        assert_eq!(fs::read(destination.join("vector")).unwrap(), plain);
        let mut named = download.clone();
        named["clientEncryption"]["fileName"] = json!("hidden-report.pdf");
        let (result, lines) = captured_call("startDownload", named.clone()).await;
        result.unwrap();
        assert_eq!(fs::read(destination.join("hidden-report.pdf")).unwrap(), plain);
        // The field is redacted wherever the request is echoed; the published
        // path may name the file.
        assert!(!lines.join("\n").contains("\"fileName\":\"hidden-report.pdf\""));
        call("startDownload", named.clone()).await.unwrap();
        assert_eq!(fs::read(destination.join("hidden-report (1).pdf")).unwrap(), plain);
        named["conflictPolicy"] = json!("replace");
        call("startDownload", named).await.unwrap();
        assert_eq!(fs::read(destination.join("hidden-report.pdf")).unwrap(), plain);
        {
            let mut state = state.lock().unwrap();
            let prefix = case["headerLength"].as_u64().unwrap() + 16;
            assert_eq!(state.ranges[0], (prefix - 16, prefix - 1));
            assert!(state
                .ranges
                .iter()
                .filter(|(_, end)| *end >= prefix)
                .all(|(start, _)| (*start - prefix) % SEALED == 0));
            let index = if plain.len() as u64 > CHUNK { 1 } else { 0 };
            state.object[(prefix + index * SEALED) as usize] ^= 1;
        }
        let mut corrupt = download;
        corrupt["conflictPolicy"] = json!("replace");
        let (error, lines) = captured_call("startDownload", corrupt.clone()).await;
        assert!(!lines.join("\n").contains(case["fileKey"].as_str().unwrap()));
        let error = error.unwrap_err();
        assert_eq!(error.code, "decryption_failed");
        assert_eq!(
            error.details["chunk"],
            if plain.len() as u64 > CHUNK { 1 } else { 0 }
        );
        assert_eq!(fs::read(destination.join("vector")).unwrap(), plain);
        assert_eq!(
            fs::read_dir(&destination).unwrap().count(),
            4,
            "staged file leaked"
        );
        let failed_destination = directory.0.join("failed");
        corrupt["destinationPath"] = json!(failed_destination);
        let error = call("startDownload", corrupt).await.unwrap_err();
        assert_eq!(error.code, "decryption_failed");
        assert_eq!(fs::read_dir(&failed_destination).unwrap().count(), 0);
        assert_eq!(state.lock().unwrap().aborts, 0);
    }
}

#[tokio::test]
async fn absent_or_null_client_encryption_preserves_plain_upload_and_download() {
    let directory = Directory::new();
    let source = directory.0.join("source.age");
    let bytes = plaintext(&vectors()[4]);
    fs::write(&source, &bytes).unwrap();
    let state = Arc::new(Mutex::new(Stored::default()));
    let fixture = storage_fixture(state.clone(), false, false);
    for explicit_null in [false, true] {
        let destination = directory
            .0
            .join(if explicit_null { "null" } else { "absent" });
        let mut upload = json!({"profile":profile(&fixture.endpoint),"bucketName":"bucket","filePaths":[source]});
        let mut download = json!({"profile":profile(&fixture.endpoint),"bucketName":"bucket","keys":["source.age"],"destinationPath":destination});
        if explicit_null {
            upload["clientEncryption"] = Value::Null;
            download["clientEncryption"] = Value::Null;
        }
        call("startUpload", upload).await.unwrap();
        call("startDownload", download).await.unwrap();
        assert_eq!(fs::read(destination.join("source.age")).unwrap(), bytes);
    }
    let state = state.lock().unwrap();
    assert_eq!(state.puts, vec![bytes.clone(), bytes]);
    assert_eq!(state.plain_gets, 2);
    assert!(state.ranges.is_empty());
    assert_eq!(state.requests.len(), 6);
    assert_eq!(state.requests[..3], state.requests[3..]);
}

#[tokio::test]
async fn multiple_encrypted_files_or_keys_are_invalid_before_network() {
    let case = &vectors()[0];
    for (method, params) in [
        (
            "startUpload",
            json!({"filePaths":["a","b"],"clientEncryption":{"format":"age-v1","header":case["header"],"payloadNonce":case["payloadNonce"],"fileKey":case["fileKey"]}}),
        ),
        (
            "startDownload",
            json!({"keys":["a","b"],"clientEncryption":{"format":"age-v1","headerLength":168,"fileKey":case["fileKey"]}}),
        ),
    ] {
        let mut params = params;
        params["profile"] = profile("http://127.0.0.1:1");
        params["bucketName"] = json!("bucket");
        assert_eq!(
            call(method, params).await.unwrap_err().code,
            "invalid_config"
        );
    }
}

#[tokio::test]
async fn impossible_ciphertext_length_fails_before_get_and_publication() {
    let directory = Directory::new();
    let state = Arc::new(Mutex::new(Stored {
        object: vec![0; 168 + 16 + 17 + SEALED as usize],
        ..Stored::default()
    }));
    let fixture = storage_fixture(state.clone(), false, false);
    // SEALED+17 is valid (one-byte final plaintext); SEALED+1 is impossible.
    state
        .lock()
        .unwrap()
        .object
        .truncate(168 + 16 + 1 + SEALED as usize);
    let error = call("startDownload", json!({"profile":profile(&fixture.endpoint),"bucketName":"bucket",
        "keys":["vector.age"],"destinationPath":directory.0,"clientEncryption":{"format":"age-v1","headerLength":168,"fileKey":vectors()[0]["fileKey"]}})).await.unwrap_err();
    assert_eq!(error.code, "decryption_failed");
    assert!(state.lock().unwrap().ranges.is_empty());
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
}

#[tokio::test]
async fn payload_capability_uses_engine_item_shape() {
    let capabilities = call("getCapabilities", json!({})).await.unwrap();
    let items = capabilities["items"]
        .as_array()
        .or_else(|| capabilities["capabilities"].as_array())
        .unwrap();
    let capability = items
        .iter()
        .find(|item| item["key"] == "object.clientEncryption")
        .unwrap();
    assert_eq!(capability["state"], "supported");
    assert_eq!(capability["formats"], json!(["age-v1"]));
}

#[tokio::test]
async fn encrypted_multipart_failure_or_source_change_aborts_without_completing() {
    for change_source in [false, true] {
        let directory = Directory::new();
        let case = vectors().last().unwrap().clone();
        let source = directory.0.join("source");
        fs::write(&source, plaintext(&case)).unwrap();
        let aborted = Arc::new(AtomicBool::new(false));
        let completed = Arc::new(AtomicBool::new(false));
        let (abort_seen, complete_seen, changed_path) =
            (aborted.clone(), completed.clone(), source.clone());
        let fixture = BinaryFixture::new(move |request| {
            let first = request.lines().next().unwrap();
            if request.starts_with("DELETE") {
                abort_seen.store(true, MemoryOrdering::SeqCst);
                return binary("204 No Content", "", b"");
            }
            if request.starts_with("POST") && first.contains("uploads") {
                return binary("200 OK", "", b"<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>");
            }
            if request.starts_with("POST") {
                complete_seen.store(true, MemoryOrdering::SeqCst);
                return binary("200 OK", "", b"<CompleteMultipartUploadResult/>");
            }
            if change_source {
                fs::write(&changed_path, b"changed").unwrap();
                binary("200 OK", "ETag: \"fixture\"\r\n", b"")
            } else {
                binary(
                    "403 Forbidden",
                    "",
                    b"<Error><Code>AccessDenied</Code></Error>",
                )
            }
        });
        let mut p = profile(&fixture.endpoint);
        p["maxConcurrentRequests"] = json!(1);
        let error = call("startUpload", json!({"profile":p,"bucketName":"bucket","filePaths":[source],
            "multipartThresholdMiB":1,"multipartChunkMiB":5,"clientEncryption":{"format":"age-v1",
                "header":case["header"],"payloadNonce":case["payloadNonce"],"fileKey":case["fileKey"]}})).await.unwrap_err();
        if change_source {
            assert_eq!(error.code, "object_conflict");
        }
        assert!(aborted.load(MemoryOrdering::SeqCst));
        assert!(!completed.load(MemoryOrdering::SeqCst));
    }
}

#[tokio::test]
async fn invalid_download_names_are_rejected_before_network() {
    let case = &vectors()[0];
    for name in [Value::Null, json!(1), json!(false), json!([]), json!({}), json!(""), json!("."), json!(".."), json!("a/b"), json!("a\\b"), json!("a\0b")] {
        let params = json!({"profile":profile("http://127.0.0.1:1"),"bucketName":"bucket","keys":["token.age"],
            "destinationPath":"unused","clientEncryption":{"format":"age-v1","headerLength":case["headerLength"],"fileKey":case["fileKey"],"fileName":name}});
        assert_eq!(call("startDownload", params).await.unwrap_err().code, "invalid_config");
    }
}
