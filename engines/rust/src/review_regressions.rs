use super::*;
use std::io::Read;

#[tokio::test]
async fn benchmark_snapshot_and_pending_controls_do_not_need_execution_lock() {
    let id = format!("control-test-{}", Uuid::new_v4());
    let live = Arc::new(BenchmarkOwner::new(json!({
        "id":id,"status":"running","processedCount":7,
        "profile":{"secretKey":"must-not-be-published"}
    })));
    LIVE_BENCHMARKS.get_or_init(Default::default).lock().unwrap().insert(id.clone(), live.clone());
    let _execution = live.state.lock().await;
    let params = json!({"runId":id});
    tokio::time::timeout(Duration::from_millis(500), async {
        let status = get_benchmark_status(params.clone()).await.unwrap();
        assert_eq!(status["processedCount"], 7);
        assert!(status.get("profile").is_none());
        assert_eq!(pause_benchmark(params.clone()).await.unwrap()["controlPending"], "paused");
        assert_eq!(get_benchmark_status(params.clone()).await.unwrap()["controlPending"], "paused");
        assert!(resume_benchmark(params.clone()).await.unwrap().get("controlPending").is_none());
        assert_eq!(stop_benchmark(params.clone()).await.unwrap()["controlPending"], "stopped");
        assert_eq!(resume_benchmark(params.clone()).await.unwrap()["controlPending"], "stopped");
        assert_eq!(pause_benchmark(params.clone()).await.unwrap()["controlPending"], "stopped");
        assert_eq!(_execution["status"], "running");
        assert_eq!(_execution["processedCount"], 7);
    }).await.unwrap();
    LIVE_BENCHMARKS.get().unwrap().lock().unwrap().remove(&id);
}

#[tokio::test]
async fn benchmark_controls_acknowledge_blocked_network_and_settle_dispatched_work() {
    for action in ["paused", "stopped"] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            assert!(request(&mut stream).starts_with("PUT"));
            entered_tx.send(()).unwrap();
            release_rx.recv_timeout(Duration::from_secs(10)).unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nETag: \"test\"\r\nConnection: close\r\n\r\n").unwrap();
        });
        let output_dir = std::env::temp_dir().join(format!("rust-benchmark-control-{}", Uuid::new_v4()));
        let started = start_benchmark(json!({
            "profile":{"id":"fixture","endpointType":"awsS3","endpointUrl":endpoint,"region":"us-east-1","accessKey":"fixture","secretKey":"fixture","pathStyle":true,"maxAttempts":1},
            "config":{"bucketName":"bucket","workloadType":"write-only","objectCount":10,"objectSizes":[32],
                "testMode":"operation-count","operationCount":100,"concurrentThreads":1,"maxPoolConnections":1,"maxAttempts":1,
                "csvOutputPath":output_dir.join("results.csv"),"jsonOutputPath":output_dir.join("results.json"),"logFilePath":output_dir.join("benchmark.log")}
        })).await.unwrap();
        let params = json!({"runId":started["id"]});
        let live = live_benchmark(&params).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), entered_rx).await.unwrap().unwrap();

        let status = tokio::time::timeout(Duration::from_millis(500), get_benchmark_status(params.clone())).await.unwrap().unwrap();
        assert_eq!(status["status"], "running");
        assert!(status.get("profile").is_none());
        let paused = tokio::time::timeout(Duration::from_millis(500), pause_benchmark(params.clone())).await.unwrap().unwrap();
        assert_eq!(paused["controlPending"], "paused");
        if action == "stopped" {
            let resumed = tokio::time::timeout(Duration::from_millis(500), resume_benchmark(params.clone())).await.unwrap().unwrap();
            assert!(resumed.get("controlPending").is_none());
            let stopped = tokio::time::timeout(Duration::from_millis(500), stop_benchmark(params.clone())).await.unwrap().unwrap();
            assert_eq!(stopped["controlPending"], "stopped");
            assert_eq!(resume_benchmark(params.clone()).await.unwrap()["controlPending"], "stopped");
            assert_eq!(pause_benchmark(params.clone()).await.unwrap()["controlPending"], "stopped");
        }
        release_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let snapshot = get_benchmark_status(params.clone()).await.unwrap();
                if snapshot["status"] == action {
                    assert_eq!(snapshot["processedCount"], 1);
                    assert!(snapshot.get("controlPending").is_none());
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.unwrap();
        server.join().unwrap();
        if action == "paused" {
            assert!(Arc::ptr_eq(&live, &live_benchmark(&params).await.unwrap()));
            stop_benchmark(params.clone()).await.unwrap();
        }
        // Wait for the worker's final cleanup before removing its artifacts.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if !LIVE_BENCHMARKS.get().unwrap().lock().unwrap().contains_key(params["runId"].as_str().unwrap()) {
                    break;
                }
                tokio::task::yield_now().await;
            }
        }).await.unwrap();
        fs::remove_file(benchmark_state_path(params["runId"].as_str().unwrap()).unwrap()).unwrap();
        fs::remove_dir_all(output_dir).unwrap();
    }
}

fn request(stream: &mut std::net::TcpStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut bytes = Vec::new();
    while !bytes.ends_with(b"\r\n\r\n") {
        let mut byte = [0];
        stream.read_exact(&mut byte).unwrap();
        bytes.push(byte[0]);
    }
    let header = String::from_utf8(bytes).unwrap();
    let length = header
        .lines()
        .find_map(|line| {
            line.to_lowercase()
                .strip_prefix("content-length:")
                .and_then(|v| v.trim().parse::<usize>().ok())
        })
        .unwrap_or(0);
    let mut body = vec![0; length];
    stream.read_exact(&mut body).unwrap();
    // Benchmark payloads are binary; only the head is inspected.
    format!("{header}{}", String::from_utf8_lossy(&body))
}

#[tokio::test]
async fn moves_delete_only_explicit_versions_and_keep_exact_keys() {
    for selected in [None, Some("null")] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let text = request(&mut stream);
                let response = if text.starts_with("HEAD") {
                    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nETag: \"copied\"\r\nx-amz-version-id: discovered-v2\r\nConnection: close\r\n\r\n".to_owned()
                } else if text.starts_with("DELETE") {
                    "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".to_owned()
                } else {
                    let body = "<CopyObjectResult><ETag>\"destination\"</ETag></CopyObjectResult>";
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                };
                requests.push(text);
                stream.write_all(response.as_bytes()).unwrap();
            }
            requests
        });
        let mut params = json!({"profile":{"endpointType":"awsS3","endpointUrl":endpoint,"region":"us-east-1","accessKey":"fixture","secretKey":"fixture","pathStyle":true,"maxAttempts":1},
            "sourceBucketName":"bucket","sourceKey":" report ","destinationBucketName":"bucket","destinationKey":"renamed"});
        if let Some(version) = selected {
            params["sourceVersionId"] = json!(version);
        }
        let result = tokio::time::timeout(Duration::from_secs(10), move_object(params))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result["successCount"], 1);
        let requests = server.join().unwrap();
        let delete = requests.iter().find(|r| r.starts_with("DELETE")).unwrap();
        assert!(delete.starts_with("DELETE /bucket/%20report%20"));
        assert_eq!(delete.contains("versionId="), selected.is_some());
        if selected.is_some() {
            assert!(delete.contains("versionId=null"));
        }
        assert!(delete.to_lowercase().contains("if-match: \"copied\""));
    }
}

#[test]
fn listing_keys_decode_once_and_preserve_plus() {
    assert_eq!(
        decode_listing_key(
            Some("a%252Fb%2B%E9%9B%AA%01"),
            Some(&aws_sdk_s3::types::EncodingType::Url)
        )
        .unwrap(),
        "a%2Fb+雪\x01"
    );
    assert_eq!(
        decode_listing_key(Some("literal%2F+"), None).unwrap(),
        "literal%2F+"
    );
}

#[tokio::test]
async fn delete_selection_batches_and_preserves_prior_success_on_failure() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        for batch in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            let text = request(&mut stream);
            assert_eq!(
                text.matches("<Object>").count(),
                if batch == 0 { 1000 } else { 1 }
            );
            let body = if batch == 0 {
                format!(
                    "<DeleteResult>{}</DeleteResult>",
                    (0..1000)
                        .map(|i| format!("<Deleted><Key>key-{i}</Key></Deleted>"))
                        .collect::<String>()
                )
            } else {
                "<Error><Code>AccessDenied</Code></Error>".into()
            };
            let status = if batch == 0 {
                "200 OK"
            } else {
                "403 Forbidden"
            };
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        }
    });
    let params = json!({"profile":{"endpointType":"s3Compatible","endpointUrl":endpoint,"region":"us-east-1","accessKey":"fixture","secretKey":"fixture","pathStyle":true,"maxAttempts":1},
        "bucketName":"bucket", "keys":(0..1001).map(|i|format!("key-{i}")).collect::<Vec<_>>()});
    let result = tokio::time::timeout(Duration::from_secs(10), delete_objects(params))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result["successCount"], 1000);
    assert_eq!(result["failureCount"], 1);
    assert_eq!(result["failures"][0]["target"], "key-1000");
    server.join().unwrap();
}
