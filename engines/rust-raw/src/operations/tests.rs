use super::delete::{delete_request_body, match_delete_result};
use super::xml::{document, escape_text, parse, to_json, Doc};
use super::*;

fn node(text: &str) -> Node {
    parse(text.as_bytes()).expect("valid XML")
}

#[test]
fn parses_prefixed_namespaces_and_keeps_leaf_whitespace() {
    let root = node(concat!(
        "<?xml version=\"1.0\"?>\n",
        "<s3:ListBucketResult xmlns:s3=\"http://s3.amazonaws.com/doc/2006-03-01/\">\n",
        "  <s3:Contents><s3:Key>  spaced &amp; &#13;cr&#x41;<![CDATA[<raw>]]></s3:Key></s3:Contents>\n",
        "</s3:ListBucketResult>",
    ));
    assert_eq!(root.name, "ListBucketResult");
    assert_eq!(
        root.child("Contents").unwrap().text_of("Key"),
        Some("  spaced & \rcrA<raw>")
    );
}

#[test]
fn rejects_malformed_or_unknown_entity_xml() {
    assert!(parse(b"<a><b></a>").is_err());
    assert!(parse(b"<a>&custom;</a>").is_err());
    assert!(parse(b"").is_err());
    assert!(parse(b"<a/><b/>").is_err());
}

#[test]
fn object_listing_form_decodes_only_when_encoding_is_reported() {
    let encoded = node(concat!(
        "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>",
        "<NextContinuationToken>t+2</NextContinuationToken><Unknown>ignored</Unknown>",
        "<Contents><Key>dir%2Fa+b%2Bc</Key><Size>5</Size><ETag>\"abc\"</ETag><LastModified>2024-01-02T03:04:05.678Z</LastModified></Contents>",
        "<Contents><Key>dir%2F</Key><Size>0</Size></Contents>",
        "<CommonPrefixes><Prefix>dir%2Fsub%20x%2F</Prefix></CommonPrefixes>",
        "</ListBucketResult>",
    ));
    let (items, next, more) = object_page(&encoded, "dir/", false).unwrap();
    assert!(more);
    assert_eq!(next.as_deref(), Some("t+2"));
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["key"], "dir/sub x/");
    assert_eq!(items[0]["isFolder"], true);
    assert_eq!(items[1]["key"], "dir/a b+c");
    assert_eq!(items[1]["name"], "a b+c");
    assert_eq!(items[1]["etag"], "abc");
    assert_eq!(items[1]["storageClass"], "STANDARD");
    assert_eq!(items[1]["modifiedAt"], "2024-01-02T03:04:05Z");

    let plain = node("<ListBucketResult><Contents><Key>a+b%20</Key></Contents></ListBucketResult>");
    let (items, _, more) = object_page(&plain, "", true).unwrap();
    assert!(!more);
    assert_eq!(items[0]["key"], "a+b%20");
    assert!(decode_listing_value("%zz", true).is_err());
    assert!(decode_listing_value("%ff", true).is_err());
}

#[test]
fn version_cursors_accept_desktop_mobile_and_bare_shapes() {
    assert_eq!(
        decode_version_cursor(&json!({"value": null})).unwrap(),
        (String::new(), String::new())
    );
    assert_eq!(
        decode_version_cursor(&json!({"value": "{\"keyMarker\":\"k\",\"versionIdMarker\":\"v\"}"}))
            .unwrap(),
        ("k".to_string(), "v".to_string())
    );
    assert_eq!(
        decode_version_cursor(&json!({"value": "{\"key\":\"k\",\"version\":\"v\"}"})).unwrap(),
        ("k".to_string(), "v".to_string())
    );
    assert_eq!(
        decode_version_cursor(&json!({"value": "bare"})).unwrap(),
        ("bare".to_string(), String::new())
    );
    assert!(decode_version_cursor(&json!({"value": "{broken"})).is_err());
    assert!(decode_version_cursor(&json!({"value": "{}"})).is_err());
}

#[test]
fn version_page_orders_filters_and_encodes_cursor() {
    let root = node(concat!(
        "<ListVersionsResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>",
        "<NextKeyMarker>a%20b</NextKeyMarker><NextVersionIdMarker>v1</NextVersionIdMarker>",
        "<Version><Key>a%20b</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest><LastModified>2024-01-02T00:00:00Z</LastModified><Size>3</Size></Version>",
        "<DeleteMarker><Key>a%20b</Key><VersionId>dm</VersionId><IsLatest>false</IsLatest><LastModified>2024-01-03T00:00:00Z</LastModified></DeleteMarker>",
        "<Version><Key>other</Key><VersionId>x</VersionId><LastModified>2024-01-04T00:00:00Z</LastModified></Version>",
        "</ListVersionsResult>",
    ));
    let page = version_page(&root, "a b", "", "").unwrap();
    assert_eq!(page["totalCount"], 2);
    assert_eq!(page["items"][0]["versionId"], "dm");
    assert_eq!(page["items"][0]["storageClass"], "DELETE_MARKER");
    assert_eq!(page["items"][1]["size"], 3);
    assert_eq!(page["deleteMarkerCount"], 1);
    let cursor: Value = serde_json::from_str(page["cursor"]["value"].as_str().unwrap()).unwrap();
    assert_eq!(cursor, json!({"keyMarker": "a b", "versionIdMarker": "v1"}));
    assert!(version_page(&root, "a b", "a b", "v1").is_err());
}

#[test]
fn encryption_round_trip_keeps_blocked_types_and_extensions() {
    let original = node(concat!(
        "<ServerSideEncryptionConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">",
        "<Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>k 1</KMSMasterKeyID></ApplyServerSideEncryptionByDefault>",
        "<BucketKeyEnabled>true</BucketKeyEnabled>",
        "<BlockedEncryptionTypes><EncryptionType>SSE-C</EncryptionType></BlockedEncryptionTypes>",
        "<VendorExtension>keep</VendorExtension></Rule></ServerSideEncryptionConfiguration>",
    ));
    let json_value = to_json(Doc::Encryption, &original);
    assert_eq!(
        json_value["Rules"][0]["BlockedEncryptionTypes"]["EncryptionType"],
        json!(["SSE-C"])
    );
    assert_eq!(json_value["Rules"][0]["BucketKeyEnabled"], true);
    assert_eq!(json_value["Rules"][0]["VendorExtension"], "keep");
    let written = document(
        Doc::Encryption,
        "ServerSideEncryptionConfiguration",
        &json_value,
    )
    .unwrap();
    let reparsed = parse(&written).unwrap();
    assert_eq!(to_json(Doc::Encryption, &reparsed), json_value);
}

#[test]
fn lifecycle_round_trip_maps_boto_lists_and_whitespace() {
    let configuration = json!({"Rules": [{
        "ID": " rule ",
        "Status": "Enabled",
        "Filter": {"And": {"Prefix": " logs/", "Tags": [{"Key": "a", "Value": "1"}, {"Key": "b", "Value": "<2>"}]}},
        "Transitions": [{"Days": 30, "StorageClass": "GLACIER"}],
        "NoncurrentVersionTransitions": [{"NoncurrentDays": 7, "StorageClass": "STANDARD_IA"}],
        "Expiration": {"ExpiredObjectDeleteMarker": true},
        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 2},
    }, {"ID": "all", "Status": "Disabled", "Filter": {}, "Expiration": {"Days": 1}}]});
    let written = document(Doc::Lifecycle, "LifecycleConfiguration", &configuration).unwrap();
    let text = String::from_utf8(written.clone()).unwrap();
    assert!(text.contains("<Tag><Key>b</Key><Value>&lt;2&gt;</Value></Tag>"));
    assert!(text.contains("<Filter></Filter>"));
    assert_eq!(
        to_json(Doc::Lifecycle, &parse(&written).unwrap()),
        configuration
    );
    let summary = lifecycle_rule_summary(&configuration["Rules"][0]);
    assert_eq!(summary["prefix"], " logs/");
    assert_eq!(summary["transitionDays"], 30);
    assert_eq!(summary["deleteExpiredObjectDeleteMarkers"], true);
    assert_eq!(summary["abortIncompleteMultipartUploadDays"], 2);
}

#[test]
fn cors_and_tagging_use_boto_shapes() {
    let cors = node(concat!(
        "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin><AllowedMethod>GET</AllowedMethod>",
        "<AllowedMethod>PUT</AllowedMethod><MaxAgeSeconds>60</MaxAgeSeconds></CORSRule></CORSConfiguration>",
    ));
    assert_eq!(
        to_json(Doc::Cors, &cors),
        json!({"CORSRules": [{"AllowedOrigins": ["*"], "AllowedMethods": ["GET", "PUT"], "MaxAgeSeconds": 60}]})
    );
    let tagging =
        node("<Tagging><TagSet><Tag><Key>k</Key><Value> v </Value></Tag></TagSet></Tagging>");
    assert_eq!(
        to_json(Doc::Tagging, &tagging),
        json!({"TagSet": [{"Key": "k", "Value": " v "}]})
    );
    let empty = node("<Tagging><TagSet/></Tagging>");
    assert_eq!(to_json(Doc::Tagging, &empty), json!({"TagSet": []}));
}

#[test]
fn xml_writer_refuses_unsafe_names_and_characters() {
    assert!(escape_text("bad\u{1}").is_err());
    assert_eq!(escape_text("a&b\r\n").unwrap(), "a&amp;b&#13;\n");
    assert!(document(Doc::Tagging, "Tagging", &json!({"bad name": "x"})).is_err());
    assert!(document(Doc::Tagging, "Tagging", &json!({"<x>": "x"})).is_err());
}

#[test]
fn object_lock_mapping_requires_an_enabled_configuration() {
    let enabled = to_json(
        Doc::ObjectLock,
        &node("<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Years>2</Years></DefaultRetention></Rule></ObjectLockConfiguration>"),
    );
    let summary = object_lock_summary(Some(&enabled));
    assert_eq!(summary["enabled"], true);
    assert_eq!(summary["mode"], "GOVERNANCE");
    assert_eq!(summary["years"], 2);
    assert_eq!(summary["unit"], "years");
    assert_eq!(object_lock_summary(Some(&json!({})))["enabled"], false);
    assert_eq!(object_lock_summary(None)["enabled"], false);
    let written = document(Doc::ObjectLock, "ObjectLockConfiguration", &enabled).unwrap();
    assert!(String::from_utf8(written).unwrap().contains(
        "<Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Years>2</Years></DefaultRetention></Rule>"
    ));
}

#[test]
fn delete_body_escapes_keys_and_results_match_by_key_and_version() {
    let body =
        String::from_utf8(delete_request_body(&[("a&b\r", None), ("c", Some("null"))]).unwrap())
            .unwrap();
    assert!(body.contains("<Quiet>false</Quiet>"));
    assert!(body.contains("<Object><Key>a&amp;b&#13;</Key></Object>"));
    assert!(body.contains("<Object><Key>c</Key><VersionId>null</VersionId></Object>"));
    assert_eq!(content_md5(b""), "1B2M2Y8AsgTpgAmY7PhCfg==");

    let requested = [
        ("a&b\r", None),
        ("c", Some("null")),
        ("d", Some("v")),
        ("e", None),
    ];
    let result = node(concat!(
        "<DeleteResult><Deleted><Key>a&amp;b&#13;</Key><DeleteMarker>true</DeleteMarker><DeleteMarkerVersionId>m</DeleteMarkerVersionId></Deleted>",
        "<Error><Key>c</Key><VersionId>null</VersionId><Code>AccessDenied</Code><Message>denied</Message></Error>",
        "<Deleted><Key>d</Key></Deleted><Deleted><Key>zzz</Key></Deleted></DeleteResult>",
    ));
    let outcomes = match_delete_result(&result, &requested).unwrap();
    assert!(outcomes[0].succeeded());
    assert_eq!(outcomes[1].code.as_deref(), Some("AccessDenied"));
    assert_eq!(outcomes[1].version_id.as_deref(), Some("null"));
    assert!(outcomes[2].succeeded());
    assert_eq!(outcomes[3].code.as_deref(), Some("unknown_outcome"));
}

#[test]
fn copy_source_escapes_plus_and_keeps_separators() {
    assert_eq!(
        copy::copy_source("bucket", "a b+c/d%", None),
        "bucket/a%20b%2Bc/d%25"
    );
    assert_eq!(
        copy::copy_source("b", "k", Some("v+1")),
        "b/k?versionId=v%2B1"
    );
}

#[test]
fn reports_encryption_and_object_lock_headers() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-amz-server-side-encryption",
        HeaderValue::from_static("aws:kms"),
    );
    headers.insert(
        "x-amz-server-side-encryption-aws-kms-key-id",
        HeaderValue::from_static("key"),
    );
    headers.insert(
        "x-amz-server-side-encryption-bucket-key-enabled",
        HeaderValue::from_static("true"),
    );
    headers.insert(
        "x-amz-object-lock-mode",
        HeaderValue::from_static("COMPLIANCE"),
    );
    headers.insert(
        "x-amz-object-lock-retain-until-date",
        HeaderValue::from_static("2030-01-01T00:00:00.000Z"),
    );
    headers.insert(
        "x-amz-object-lock-legal-hold",
        HeaderValue::from_static("ON"),
    );
    assert_eq!(
        reported_encryption(&headers).unwrap(),
        json!({"mode": "sse-kms", "kmsKeyId": "key", "bucketKeyEnabled": true})
    );
    let lock = reported_object_lock(&headers).unwrap();
    assert_eq!(lock["mode"], "COMPLIANCE");
    assert_eq!(lock["retainUntilDate"], "2030-01-01T00:00:00Z");
    assert_eq!(lock["legalHold"], true);
    assert!(reported_object_lock(&HeaderMap::new()).is_none());
    assert!(reported_encryption(&HeaderMap::new()).is_none());
}

#[test]
fn normalises_timestamps_and_endpoint_hosts() {
    assert_eq!(
        iso_time("Wed, 21 Oct 2015 07:28:00 GMT"),
        "2015-10-21T07:28:00Z"
    );
    assert_eq!(iso_time("not a date"), "not a date");
    assert_eq!(
        endpoint_host(&json!({"endpointUrl": "https://user@s3.example.com:9000/path"})),
        "s3.example.com:9000"
    );
}

#[test]
fn bounded_runner_keeps_order_and_limit() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .unwrap();
    let active = std::sync::atomic::AtomicUsize::new(0);
    let peak = std::sync::atomic::AtomicUsize::new(0);
    let values = runtime
        .block_on(copy::run_bounded(9, 3, |index| {
            let active = &active;
            let peak = &peak;
            Box::pin(async move {
                let now = active.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                peak.fetch_max(now, std::sync::atomic::Ordering::SeqCst);
                tokio::time::sleep(std::time::Duration::from_millis((9 - index as u64) * 2)).await;
                active.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                Ok(index * 10)
            })
        }))
        .unwrap();
    assert_eq!(values, (0..9).map(|index| index * 10).collect::<Vec<_>>());
    assert!(peak.load(std::sync::atomic::Ordering::SeqCst) <= 3);
    let failed = runtime.block_on(copy::run_bounded(4, 2, |index| {
        Box::pin(async move {
            if index == 1 {
                Err(SidecarError::new("unknown_outcome", "part failed"))
            } else {
                Ok(index)
            }
        })
    }));
    assert!(failed.is_err());
}

#[test]
fn read_hint_marks_bare_bad_request_only_without_a_key() {
    let error =
        SidecarError::with_details("invalid_config", "bad request", json!({"statusCode": 400}));
    assert_eq!(
        with_read_hint(error, false).details["encryptionHint"],
        "sse_c_key_required"
    );
    let error =
        SidecarError::with_details("invalid_config", "bad request", json!({"statusCode": 400}));
    assert!(with_read_hint(error, true)
        .details
        .get("encryptionHint")
        .is_none());
}
