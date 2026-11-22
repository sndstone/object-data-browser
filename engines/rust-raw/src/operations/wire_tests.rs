//! Request/response tests against a local HTTP/1.1 mock of S3.

use super::*;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

#[derive(Debug, Clone)]
struct Seen {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Seen {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }
}

type Reply = (u16, Vec<(&'static str, String)>, String);
type Handler = Arc<dyn Fn(&Seen) -> Reply + Send + Sync>;

async fn mock(handler: Handler) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            let handler = handler.clone();
            let log = log.clone();
            tokio::spawn(async move {
                let mut stream = BufReader::new(stream);
                loop {
                    let mut line = String::new();
                    if stream.read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    let mut parts = line.split_whitespace();
                    let method = parts.next().unwrap_or_default().to_string();
                    let target = parts.next().unwrap_or_default().to_string();
                    let mut headers = Vec::new();
                    loop {
                        let mut header = String::new();
                        stream.read_line(&mut header).await.unwrap();
                        if header == "\r\n" {
                            break;
                        }
                        let (name, value) = header.trim_end().split_once(':').unwrap();
                        headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
                    }
                    let length = headers
                        .iter()
                        .find(|(name, _)| name == "content-length")
                        .map(|(_, value)| value.parse::<usize>().unwrap())
                        .unwrap_or(0);
                    let mut body = vec![0; length];
                    stream.read_exact(&mut body).await.unwrap();
                    let request = Seen {
                        method,
                        target,
                        headers,
                        body,
                    };
                    let (status, reply_headers, reply_body) = handler(&request);
                    log.lock().unwrap().push(request.clone());
                    let mut response = format!(
                        "HTTP/1.1 {status} X\r\ncontent-length: {}\r\n",
                        reply_body.len()
                    );
                    for (name, value) in reply_headers {
                        response.push_str(&format!("{name}: {value}\r\n"));
                    }
                    response.push_str("\r\n");
                    response.push_str(&reply_body);
                    if request.method == "HEAD" {
                        response.truncate(response.len() - reply_body.len());
                    }
                    stream
                        .get_mut()
                        .write_all(response.as_bytes())
                        .await
                        .unwrap();
                }
            });
        }
    });
    (format!("http://{address}"), seen)
}

fn profile(endpoint: &str, endpoint_type: &str) -> Value {
    json!({"accessKey": "AKIDEXAMPLE", "secretKey": "secret", "endpointUrl": endpoint, "pathStyle": true,
           "endpointType": endpoint_type, "maxAttempts": 1, "readTimeoutSeconds": 5})
}

fn error(code: &str) -> String {
    format!("<Error><Code>{code}</Code><Message>{code}</Message></Error>")
}

#[tokio::test]
async fn delete_objects_sends_md5_and_reports_partial_failures() {
    let (endpoint, seen) = mock(Arc::new(|_request: &Seen| {
        (200, vec![], concat!(
            "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">",
            "<Deleted><Key>a b</Key></Deleted>",
            "<Error><Key>c&amp;d</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error>",
            "</DeleteResult>").to_string())
    }))
    .await;
    let result = dispatch(
        "deleteObjects",
        json!({
            "profile": profile(&endpoint, "s3Compatible"), "bucketName": "bucket",
            "keys": ["a b", "c&d"], "bypassGovernanceRetention": true,
        }),
    )
    .await
    .unwrap();
    assert_eq!(result["successCount"], 1);
    assert_eq!(result["failureCount"], 1);
    assert_eq!(
        result["failures"][0],
        json!({"target": "c&d", "versionId": null, "code": "AccessDenied", "message": "Access Denied"})
    );
    let requests = seen.lock().unwrap().clone();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "POST");
    assert_eq!(requests[0].target, "/bucket?delete=");
    assert_eq!(
        requests[0].header("content-md5"),
        Some(content_md5(&requests[0].body).as_str())
    );
    assert_eq!(
        requests[0].header("x-amz-bypass-governance-retention"),
        Some("true")
    );
    assert!(String::from_utf8_lossy(&requests[0].body).contains("<Key>c&amp;d</Key>"));
}

#[tokio::test]
async fn uncertain_delete_batch_is_not_replayed_and_later_batches_are_skipped() {
    let (endpoint, seen) = mock(Arc::new(|_request: &Seen| {
        (200, vec![], "<notxml".to_string())
    }))
    .await;
    let keys: Vec<String> = (0..1001).map(|index| format!("k{index}")).collect();
    let result = dispatch("deleteObjects", json!({"profile": profile(&endpoint, "s3Compatible"), "bucketName": "bucket", "keys": keys}))
        .await
        .unwrap();
    assert_eq!(result["successCount"], 0);
    assert_eq!(result["failureCount"], 1001);
    assert_eq!(result["failures"][0]["code"], "unknown_outcome");
    assert_eq!(result["failures"][1000]["code"], "not_attempted");
    assert_eq!(seen.lock().unwrap().len(), 1);
}

fn copy_handler(delete_status: u16) -> Handler {
    Arc::new(
        move |request: &Seen| match (request.method.as_str(), request.target.as_str()) {
            ("HEAD", "/src/a%2Bb") => (
                200,
                vec![
                    ("etag", "\"e1\"".into()),
                    ("content-length", "3".into()),
                    ("x-amz-version-id", "v1".into()),
                ],
                String::new(),
            ),
            ("PUT", "/dst/c") => (
                200,
                vec![("x-amz-version-id", "d1".into())],
                "<CopyObjectResult><ETag>\"e2\"</ETag></CopyObjectResult>".into(),
            ),
            ("HEAD", "/dst/c?versionId=d1") => (
                200,
                vec![("etag", "\"e2\"".into()), ("content-length", "3".into())],
                String::new(),
            ),
            ("DELETE", "/src/a%2Bb") if delete_status == 204 => (204, vec![], String::new()),
            ("DELETE", "/src/a%2Bb") => (delete_status, vec![], error("PreconditionFailed")),
            _ => (500, vec![], error("Unexpected")),
        },
    )
}

fn move_params(endpoint: &str, endpoint_type: &str) -> Value {
    json!({"profile": profile(endpoint, endpoint_type), "sourceBucketName": "src", "sourceKey": "a+b",
           "destinationBucketName": "dst", "destinationKey": "c"})
}

#[tokio::test]
async fn move_on_compatible_endpoint_keeps_source_after_verified_copy() {
    let (endpoint, seen) = mock(copy_handler(204)).await;
    let result = dispatch("moveObject", move_params(&endpoint, "s3Compatible"))
        .await
        .unwrap();
    assert_eq!(result["copyCompleted"], true);
    assert_eq!(result["sourceRetained"], true);
    assert_eq!(result["failures"][0]["code"], "source_delete_unsupported");
    let requests = seen.lock().unwrap().clone();
    assert!(requests.iter().all(|request| request.method != "DELETE"));
    let copy = requests
        .iter()
        .find(|request| request.method == "PUT")
        .unwrap();
    assert_eq!(
        copy.header("x-amz-copy-source"),
        Some("src/a%2Bb?versionId=v1")
    );
    assert_eq!(copy.header("x-amz-copy-source-if-match"), Some("\"e1\""));
}

#[tokio::test]
async fn move_on_aws_deletes_conditionally_and_reports_precondition_failures() {
    let (endpoint, seen) = mock(copy_handler(204)).await;
    let result = dispatch("moveObject", move_params(&endpoint, "awsS3"))
        .await
        .unwrap();
    assert_eq!(result["successCount"], 1);
    assert_eq!(result["destinationVersionId"], "d1");
    let delete = seen
        .lock()
        .unwrap()
        .iter()
        .find(|request| request.method == "DELETE")
        .cloned()
        .unwrap();
    assert_eq!(delete.header("if-match"), Some("\"e1\""));

    let (endpoint, _) = mock(copy_handler(412)).await;
    let result = dispatch("moveObject", move_params(&endpoint, "awsS3"))
        .await
        .unwrap();
    assert_eq!(result["successCount"], 0);
    assert_eq!(result["sourceRetained"], true);
    assert_eq!(result["failures"][0]["code"], "source_delete_failed");
}

#[tokio::test]
async fn copy_fail_policy_refuses_an_existing_destination_without_writing() {
    let (endpoint, seen) = mock(Arc::new(|request: &Seen| {
        match (request.method.as_str(), request.target.as_str()) {
            ("HEAD", _) => (
                200,
                vec![("etag", "\"e\"".into()), ("content-length", "1".into())],
                String::new(),
            ),
            _ => (500, vec![], error("Unexpected")),
        }
    }))
    .await;
    let mut params = move_params(&endpoint, "s3Compatible");
    params["conflictPolicy"] = json!("fail");
    let error = dispatch("copyObject", params.clone()).await.unwrap_err();
    assert_eq!(error.code, "object_conflict");
    params["conflictPolicy"] = json!("skip");
    assert_eq!(
        dispatch("copyObject", params).await.unwrap()["skipped"],
        true
    );
    assert!(seen
        .lock()
        .unwrap()
        .iter()
        .all(|request| request.method == "HEAD"));
}

#[tokio::test]
async fn admin_state_maps_missing_sections_and_versioning() {
    let (endpoint, _) = mock(Arc::new(|request: &Seen| {
        let query = request.target.split_once('?').map(|(_, query)| query).unwrap_or_default();
        match query {
            "versioning=" => (200, vec![], "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>".into()),
            "encryption=" => (404, vec![], error("ServerSideEncryptionConfigurationNotFoundError")),
            "lifecycle=" => (200, vec![("x-amz-transition-default-minimum-object-size", "all_storage_classes_128K".into())],
                "<LifecycleConfiguration><Rule><ID>r</ID><Status>Enabled</Status><Filter><Prefix>p/</Prefix></Filter><Expiration><Days>3</Days></Expiration></Rule></LifecycleConfiguration>".into()),
            "policy=" => (403, vec![], error("AccessDenied")),
            "cors=" => (501, vec![], error("NotImplemented")),
            "tagging=" => (200, vec![], "<Tagging><TagSet><Tag><Key>k</Key><Value>v</Value></Tag></TagSet></Tagging>".into()),
            "object-lock=" => (200, vec![], "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled></ObjectLockConfiguration>".into()),
            _ => (500, vec![], error("Unexpected")),
        }
    }))
    .await;
    let state = dispatch(
        "getBucketAdminState",
        json!({"profile": profile(&endpoint, "s3Compatible"), "bucketName": "bucket"}),
    )
    .await
    .unwrap();
    assert_eq!(state["versioningEnabled"], true);
    assert_eq!(state["encryptionEnabled"], false);
    assert_eq!(state["sections"]["GetBucketEncryption"]["state"], "absent");
    assert_eq!(state["sections"]["GetBucketPolicy"]["state"], "denied");
    assert_eq!(state["sections"]["GetBucketCors"]["state"], "unsupported");
    assert_eq!(state["lifecycleRules"][0]["prefix"], "p/");
    assert_eq!(state["lifecycleRules"][0]["expirationDays"], 3);
    assert_eq!(
        state["transitionDefaultMinimumObjectSize"],
        "all_storage_classes_128K"
    );
    assert!(state["lifecycleJson"]
        .as_str()
        .unwrap()
        .contains("all_storage_classes_128K"));
    assert_eq!(state["tags"], json!({"k": "v"}));
    assert_eq!(state["objectLockEnabled"], true);
}

#[tokio::test]
async fn list_objects_rejects_a_stuck_continuation_token() {
    let (endpoint, _) = mock(Arc::new(|_request: &Seen| {
        (200, vec![], "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>same</NextContinuationToken></ListBucketResult>".into())
    }))
    .await;
    let error = dispatch("listObjects", json!({
        "profile": profile(&endpoint, "s3Compatible"), "bucketName": "bucket", "cursor": {"value": "same"}
    }))
    .await
    .unwrap_err();
    assert_eq!(error.code, "invalid_response");
}
