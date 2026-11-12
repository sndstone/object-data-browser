use super::*;
use std::io::Read;

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
    format!("{header}{}", String::from_utf8(body).unwrap())
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
