//! Control-plane RPC handlers over the raw signed S3 client: buckets, bucket
//! administration, listings, object details, copy/move, deletes and the
//! `storageAction` subset this engine implements.
//!
//! JSON shapes follow the SDK-based Rust engine (and Python where the SDK
//! engine has no equivalent) so the Flutter host needs no engine-specific code.

mod copy;
mod delete;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod wire_tests;
pub mod xml;

// Reusable by tools and benchmarks.
#[allow(unused_imports)]
pub use delete::{delete_batch, DeleteOutcome, DELETE_BATCH_LIMIT};
#[allow(unused_imports)]
pub use xml::escape_text as escape_xml_text;

use crate::client::{Client, Payload, Retry};
use crate::{encryption_headers, now_iso, required_text, SidecarError, SidecarResult};
use bytes::Bytes;
use chrono::{SecondsFormat, Utc};
use http::{HeaderMap, HeaderName, HeaderValue, Method};
use md5::{Digest, Md5};
use serde_json::{json, Map, Value};
use std::future::Future;
use std::time::Instant;
use xml::{Doc, Node};

const EPOCH_ISO: &str = "1970-01-01T00:00:00Z";

/// Entry point for every method this module owns.
pub async fn dispatch(method: &str, params: Value) -> SidecarResult {
    match method {
        "testProfile" => Box::pin(test_profile(&params["profile"])).await,
        "listBuckets" => Box::pin(list_buckets(&params["profile"])).await,
        "createBucket" => Box::pin(create_bucket(&params)).await,
        "deleteBucket" => Box::pin(delete_bucket(&params)).await,
        "getBucketAdminState" => Box::pin(get_bucket_admin_state(&params)).await,
        "setBucketVersioning" => Box::pin(set_bucket_versioning(&params)).await,
        "putBucketLifecycle" => Box::pin(put_bucket_lifecycle(&params)).await,
        "deleteBucketLifecycle" => Box::pin(delete_subresource(&params, "lifecycle")).await,
        "putBucketPolicy" => Box::pin(put_bucket_policy(&params)).await,
        "deleteBucketPolicy" => Box::pin(delete_subresource(&params, "policy")).await,
        "putBucketCors" => Box::pin(put_bucket_cors(&params)).await,
        "deleteBucketCors" => Box::pin(delete_subresource(&params, "cors")).await,
        "putBucketEncryption" => Box::pin(put_bucket_encryption(&params)).await,
        "deleteBucketEncryption" => Box::pin(delete_subresource(&params, "encryption")).await,
        "putBucketTagging" => Box::pin(put_bucket_tagging(&params)).await,
        "deleteBucketTagging" => Box::pin(delete_subresource(&params, "tagging")).await,
        "listObjects" => Box::pin(list_objects(&params)).await,
        "listObjectVersions" => Box::pin(list_object_versions(&params)).await,
        "getObjectDetails" => Box::pin(get_object_details(&params)).await,
        "createFolder" => Box::pin(create_folder(&params)).await,
        "copyObject" => Box::pin(copy::copy_object(&params, false)).await,
        "moveObject" => Box::pin(copy::copy_object(&params, true)).await,
        "deleteObjects" => Box::pin(delete::delete_objects(&params)).await,
        "deleteObjectVersions" => Box::pin(delete::delete_object_versions(&params)).await,
        "storageAction" => Box::pin(storage_action(&params)).await,
        _ => Err(SidecarError::new(
            "unsupported_feature",
            format!("Method {method} is not implemented in the raw Rust engine."),
        )),
    }
}

/// `storageAction` names this engine implements (reported by `providerInfo`).
pub const STORAGE_ACTIONS: &[&str] = &[
    "providerInfo",
    "getBucketAdminState",
    "objectDetails",
    "listObjects",
    "listObjectVersions",
    "getObjectProtection",
    "setObjectProtection",
    "getBucketProtection",
    "setBucketProtection",
    "deleteVersion",
];

async fn storage_action(params: &Value) -> SidecarResult {
    let action = params["action"].as_str().unwrap_or_default();
    match action {
        "providerInfo" => Ok(provider_info(&params["profile"])),
        "getBucketAdminState" => get_bucket_admin_state(params).await,
        "objectDetails" => get_object_details(params).await,
        "listObjects" => list_objects(params).await,
        "listObjectVersions" => list_object_versions(params).await,
        "getBucketProtection" => bucket_protection(params, false).await,
        "setBucketProtection" => bucket_protection(params, true).await,
        "getObjectProtection" => object_protection(params, false).await,
        "setObjectProtection" => object_protection(params, true).await,
        "deleteVersion" => delete_version(params).await,
        _ => Err(SidecarError::new(
            "unsupported_feature",
            format!("Unknown storage action: {action}"),
        )),
    }
}

fn provider_info(profile: &Value) -> Value {
    let provider = profile["endpointType"].as_str().unwrap_or("s3Compatible");
    json!({
        "provider": provider,
        "actions": STORAGE_ACTIONS,
        "requirements": {},
        "support": if provider == "s3Compatible" { "unknown" } else { "supported" },
        "storageClasses": ["STANDARD", "STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"],
    })
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn invalid_config(message: impl Into<String>) -> SidecarError {
    SidecarError::new("invalid_config", message)
}

fn invalid_response(message: impl Into<String>) -> SidecarError {
    SidecarError::new("invalid_response", message)
}

fn client_for(params: &Value) -> Result<Client, SidecarError> {
    Client::new(&params["profile"])
}

fn bucket_name(params: &Value, message: &str) -> Result<String, SidecarError> {
    required_text(params, "bucketName", message)
}

/// Sends a request and drains its (bounded) body. `bytes()` also turns a
/// top-level `<Error>` document in a 200 response into an error.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn call(
    client: &Client,
    method: Method,
    bucket: Option<&str>,
    key: Option<&str>,
    query: &[(&str, &str)],
    headers: HeaderMap,
    payload: Payload,
    retry: Retry,
) -> Result<(HeaderMap, Bytes), SidecarError> {
    let response = client
        .send(method, bucket, key, query, headers, payload, retry)
        .await?;
    let headers = response.headers.clone();
    let body = response.bytes().await?;
    Ok((headers, body))
}

/// Parses a response body and checks its root element (by local name).
pub(crate) fn parse_document(body: &[u8], root: &str) -> Result<Node, SidecarError> {
    let node = xml::parse(body)?;
    if node.name != root {
        return Err(invalid_response(format!(
            "Expected an XML {root} document but the provider returned {}.",
            node.name
        )));
    }
    Ok(node)
}

pub(crate) fn content_md5(body: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(Md5::digest(body))
}

/// Content type and Content-MD5 for an XML request body. S3 requires an
/// integrity header on DeleteObjects and on several configuration writes.
pub(crate) fn xml_headers(body: &[u8]) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        http::header::CONTENT_TYPE,
        HeaderValue::from_static("application/xml"),
    );
    if let Ok(value) = HeaderValue::from_str(&content_md5(body)) {
        headers.insert(HeaderName::from_static("content-md5"), value);
    }
    headers
}

pub(crate) fn set_header(
    headers: &mut HeaderMap,
    name: &str,
    value: &str,
) -> Result<(), SidecarError> {
    let header_name = HeaderName::from_bytes(name.as_bytes())
        .map_err(|_| invalid_config(format!("{name} is not a valid header name.")))?;
    let header_value = HeaderValue::from_str(value).map_err(|_| {
        invalid_config(format!(
            "The {name} header value contains unsupported characters."
        ))
    })?;
    headers.insert(header_name, header_value);
    Ok(())
}

pub(crate) fn header_text(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .map(|value| String::from_utf8_lossy(value.as_bytes()).into_owned())
}

fn trim_etag(value: &str) -> String {
    value.trim().trim_matches('"').to_string()
}

/// The HTTP status an error carries, whichever detail name the client used.
pub(crate) fn error_status(error: &SidecarError) -> Option<u16> {
    ["statusCode", "status", "httpStatus"]
        .iter()
        .find_map(|field| {
            let value = error.details.get(*field)?;
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
                .and_then(|status| u16::try_from(status).ok())
        })
}

pub(crate) fn aws_code(error: &SidecarError) -> Option<String> {
    ["awsCode", "serviceCode"]
        .iter()
        .find_map(|field| {
            error
                .details
                .get(*field)
                .and_then(Value::as_str)
                .filter(|code| !code.is_empty())
        })
        .map(str::to_owned)
}

/// HEAD has no error body. A bare 400 without a customer key usually means
/// the object is SSE-C encrypted; add the contract hint without retrying.
pub(crate) fn with_read_hint(mut error: SidecarError, has_customer_key: bool) -> SidecarError {
    let bare = matches!(
        aws_code(&error).as_deref(),
        None | Some("Unknown" | "BadRequest" | "400")
    );
    if error_status(&error) == Some(400)
        && bare
        && !has_customer_key
        && error.details.get("encryptionHint").is_none()
    {
        if !error.details.is_object() {
            error.details = json!({});
        }
        error.details["encryptionHint"] = json!("sse_c_key_required");
    }
    error
}

/// Normalises provider timestamps (ISO 8601 or HTTP dates) to RFC 3339 with
/// second precision, matching the SDK engine. Unparseable text is returned as is.
pub(crate) fn iso_time(text: &str) -> String {
    let trimmed = text.trim();
    if let Ok(value) = chrono::DateTime::parse_from_rfc3339(trimmed) {
        return value
            .with_timezone(&Utc)
            .to_rfc3339_opts(SecondsFormat::Secs, true);
    }
    if let Ok(value) = chrono::DateTime::parse_from_rfc2822(trimmed) {
        return value
            .with_timezone(&Utc)
            .to_rfc3339_opts(SecondsFormat::Secs, true);
    }
    text.to_string()
}

/// Decodes a listing key. Form decoding (`+` is a space) applies only when the
/// response itself reports `EncodingType=url`; otherwise text is taken as is.
pub(crate) fn decode_listing_value(value: &str, encoded: bool) -> Result<String, SidecarError> {
    if !encoded {
        return Ok(value.to_string());
    }
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                output.push(b' ');
                index += 1;
            }
            b'%' => {
                let hex = bytes
                    .get(index + 1..index + 3)
                    .and_then(|pair| std::str::from_utf8(pair).ok())
                    .and_then(|pair| u8::from_str_radix(pair, 16).ok())
                    .ok_or_else(|| {
                        invalid_response("Invalid URL-encoded object key in listing.")
                    })?;
                output.push(hex);
                index += 3;
            }
            other => {
                output.push(other);
                index += 1;
            }
        }
    }
    String::from_utf8(output)
        .map_err(|_| invalid_response("Invalid URL-encoded object key in listing."))
}

fn listing_encoded(root: &Node) -> bool {
    root.text_of("EncodingType")
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("url"))
}

fn is_true(node: &Node, name: &str) -> bool {
    node.text_of(name)
        .is_some_and(|value| value.trim() == "true")
}

fn integer(node: &Node, name: &str) -> i64 {
    node.text_of(name)
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(0)
}

fn endpoint_host(profile: &Value) -> String {
    let endpoint = profile["endpointUrl"].as_str().unwrap_or_default();
    let without_scheme = endpoint
        .split_once("://")
        .map_or(endpoint, |(_, rest)| rest);
    let authority = without_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default();
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    if host.is_empty() {
        endpoint.to_string()
    } else {
        host.to_string()
    }
}

fn known_bucket(profile: &Value) -> Option<String> {
    profile["knownBucket"]
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn parse_json_param(
    params: &Value,
    field: &str,
    message: &str,
    label: &str,
) -> Result<Value, SidecarError> {
    let text = required_text(params, field, message)?;
    serde_json::from_str(&text).map_err(|error| {
        SidecarError::with_details(
            "invalid_config",
            format!("{label} JSON could not be parsed."),
            json!({"reason": error.to_string()}),
        )
    })
}

fn pretty(value: &Value, fallback: &str) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| fallback.to_string())
}

// ---------------------------------------------------------------------------
// API call records (apiCalls / sections)
// ---------------------------------------------------------------------------

async fn timed<T>(
    future: impl Future<Output = Result<T, SidecarError>>,
) -> (Result<T, SidecarError>, u128) {
    let started = Instant::now();
    let result = future.await;
    (result, started.elapsed().as_millis())
}

const ABSENT_CODES: &[&str] = &[
    "NoSuchLifecycleConfiguration",
    "NoSuchBucketPolicy",
    "NoSuchCORSConfiguration",
    "NoSuchTagSet",
    "ObjectLockConfigurationNotFoundError",
    "NoSuchObjectLockConfiguration",
    "ServerSideEncryptionConfigurationNotFoundError",
    "NoSuchObjectLegalHold",
    "NoSuchObjectRetention",
];

fn section_state(error: &SidecarError) -> &'static str {
    let code = aws_code(error).unwrap_or_default();
    if matches!(
        code.as_str(),
        "AccessDenied" | "InvalidAccessKeyId" | "SignatureDoesNotMatch" | "AllAccessDisabled"
    ) {
        return "denied";
    }
    if matches!(
        code.as_str(),
        "NotImplemented" | "XNotImplemented" | "MethodNotAllowed"
    ) {
        return "unsupported";
    }
    if ABSENT_CODES.contains(&code.as_str()) {
        return "absent";
    }
    match error_status(error) {
        Some(401 | 403) => "denied",
        Some(405 | 501) => "unsupported",
        _ => "error",
    }
}

fn record_call(calls: &mut Vec<Value>, operation: &str, ok: bool, latency: u128) {
    calls.push(json!({
        "timestamp": now_iso(),
        "operation": operation,
        "status": if ok { "200" } else { "ERROR" },
        "latencyMs": latency,
    }));
}

/// Records a required call; its error is returned to the caller.
fn required_call<T>(
    calls: &mut Vec<Value>,
    operation: &str,
    result: (Result<T, SidecarError>, u128),
) -> Result<T, SidecarError> {
    let (result, latency) = result;
    record_call(calls, operation, result.is_ok(), latency);
    if let Some(last) = calls.last_mut() {
        last["sectionState"] = json!(if result.is_ok() { "available" } else { "error" });
    }
    result
}

/// Records an optional section read. Missing, denied or unsupported
/// configuration becomes a section state; a missing bucket or object is an error.
fn optional_call<T>(
    calls: &mut Vec<Value>,
    operation: &str,
    result: (Result<T, SidecarError>, u128),
) -> Result<Option<T>, SidecarError> {
    let (result, latency) = result;
    record_call(calls, operation, result.is_ok(), latency);
    match result {
        Ok(value) => {
            if let Some(last) = calls.last_mut() {
                last["sectionState"] = json!("available");
            }
            Ok(Some(value))
        }
        Err(error) => {
            if matches!(
                aws_code(&error).as_deref(),
                Some("NoSuchBucket" | "NoSuchKey" | "NoSuchVersion")
            ) {
                return Err(error);
            }
            if let Some(last) = calls.last_mut() {
                last["sectionState"] = json!(section_state(&error));
                last["code"] = json!(aws_code(&error).unwrap_or_else(|| "Unknown".to_string()));
                last["reason"] = json!(error.message);
            }
            Ok(None)
        }
    }
}

fn section_statuses(calls: &[Value]) -> Value {
    Value::Object(
        calls
            .iter()
            .map(|call| {
                (
                    call["operation"].as_str().unwrap_or_default().to_string(),
                    json!({
                        "state": call["sectionState"].as_str().unwrap_or(if call["status"] == "200" { "available" } else { "error" }),
                        "code": call["code"],
                        "reason": call["reason"],
                        "message": call["reason"],
                    }),
                )
            })
            .collect(),
    )
}

// ---------------------------------------------------------------------------
// Profiles and buckets
// ---------------------------------------------------------------------------

async fn test_profile(profile: &Value) -> SidecarResult {
    let client = Client::new(profile)?;
    let endpoint = endpoint_host(profile);
    if let Some(bucket) = known_bucket(profile) {
        call(
            &client,
            Method::HEAD,
            Some(&bucket),
            None,
            &[],
            HeaderMap::new(),
            Payload::Empty,
            Retry::Safe,
        )
        .await?;
        return Ok(json!({"ok": true, "bucketCount": 1, "endpoint": endpoint}));
    }
    let buckets = all_buckets(&client).await?;
    Ok(json!({"ok": true, "bucketCount": buckets.len(), "endpoint": endpoint}))
}

async fn list_buckets(profile: &Value) -> SidecarResult {
    let client = Client::new(profile)?;
    if let Some(bucket) = known_bucket(profile) {
        return Ok(json!({"items": [{
            "name": bucket,
            "region": client.region,
            "objectCountHint": 0,
            "versioningEnabled": false,
            "createdAt": now_iso(),
        }]}));
    }
    let items: Vec<Value> = all_buckets(&client)
        .await?
        .into_iter()
        .map(|bucket| {
            json!({
                "name": bucket.text_of("Name").unwrap_or_default(),
                "region": bucket.text_of("BucketRegion").filter(|region| !region.is_empty()).unwrap_or(&client.region),
                "objectCountHint": 0,
                "versioningEnabled": false,
                "createdAt": bucket.text_of("CreationDate").map(iso_time).unwrap_or_else(|| EPOCH_ISO.to_string()),
            })
        })
        .collect();
    Ok(json!({"items": items}))
}

/// Every bucket, following continuation tokens until the listing ends.
async fn all_buckets(client: &Client) -> Result<Vec<Node>, SidecarError> {
    let mut buckets = Vec::new();
    let mut token: Option<String> = None;
    let mut seen = std::collections::HashSet::new();
    loop {
        let mut query: Vec<(&str, &str)> = vec![("max-buckets", "1000")];
        if let Some(value) = token.as_deref() {
            query.push(("continuation-token", value));
        }
        let (_, body) = call(
            client,
            Method::GET,
            None,
            None,
            &query,
            HeaderMap::new(),
            Payload::Empty,
            Retry::Safe,
        )
        .await?;
        let root = parse_document(&body, "ListAllMyBucketsResult")?;
        if let Some(list) = root.child("Buckets") {
            buckets.extend(list.children_named("Bucket").cloned());
        }
        token = root
            .text_of("ContinuationToken")
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        match &token {
            None => return Ok(buckets),
            Some(value) if !seen.insert(value.clone()) => {
                return Err(invalid_response(
                    "Bucket listing repeated a continuation token.",
                ));
            }
            Some(_) => {}
        }
    }
}

async fn create_bucket(params: &Value) -> SidecarResult {
    let bucket = required_text(params, "bucketName", "Bucket name is required.")?;
    let versioning = params["enableVersioning"].as_bool().unwrap_or(false);
    let object_lock = params["enableObjectLock"].as_bool().unwrap_or(false);
    let client = client_for(params)?;
    let region = client.region.clone();
    let (mut headers, payload) = if region.is_empty() || region == "us-east-1" {
        (HeaderMap::new(), Payload::Empty)
    } else {
        let mut body = String::from(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CreateBucketConfiguration xmlns=\"",
        );
        body.push_str(xml::S3_NAMESPACE);
        body.push_str("\">");
        xml::text_element("LocationConstraint", &region, &mut body)?;
        body.push_str("</CreateBucketConfiguration>");
        (
            xml_headers(body.as_bytes()),
            Payload::Bytes(Bytes::from(body)),
        )
    };
    if object_lock {
        set_header(&mut headers, "x-amz-bucket-object-lock-enabled", "true")?;
    }
    call(
        &client,
        Method::PUT,
        Some(&bucket),
        None,
        &[],
        headers,
        payload,
        Retry::Never,
    )
    .await?;
    if versioning {
        put_versioning(&client, &bucket, true).await?;
    }
    Ok(json!({
        "name": bucket,
        "region": region,
        "objectCountHint": 0,
        "versioningEnabled": versioning,
        "createdAt": now_iso(),
    }))
}

async fn delete_bucket(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name is required.")?;
    let client = client_for(params)?;
    call(
        &client,
        Method::DELETE,
        Some(&bucket),
        None,
        &[],
        HeaderMap::new(),
        Payload::Empty,
        Retry::Never,
    )
    .await?;
    Ok(json!({"deleted": true, "bucketName": bucket}))
}

async fn put_versioning(client: &Client, bucket: &str, enabled: bool) -> Result<(), SidecarError> {
    let body = xml::document(
        Doc::Versioning,
        "VersioningConfiguration",
        &json!({"Status": if enabled { "Enabled" } else { "Suspended" }}),
    )?;
    let headers = xml_headers(&body);
    call(
        client,
        Method::PUT,
        Some(bucket),
        None,
        &[("versioning", "")],
        headers,
        Payload::Bytes(Bytes::from(body)),
        Retry::Safe,
    )
    .await?;
    Ok(())
}

async fn set_bucket_versioning(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name is required.")?;
    let client = client_for(params)?;
    put_versioning(
        &client,
        &bucket,
        params["enabled"].as_bool().unwrap_or(false),
    )
    .await?;
    admin_state(&client, &bucket).await
}

// ---------------------------------------------------------------------------
// Bucket administration
// ---------------------------------------------------------------------------

async fn fetch_document(
    client: &Client,
    bucket: &str,
    subresource: &str,
    root: &str,
) -> Result<(Node, HeaderMap), SidecarError> {
    let (headers, body) = call(
        client,
        Method::GET,
        Some(bucket),
        None,
        &[(subresource, "")],
        HeaderMap::new(),
        Payload::Empty,
        Retry::Safe,
    )
    .await?;
    Ok((parse_document(&body, root)?, headers))
}

async fn fetch_policy(client: &Client, bucket: &str) -> Result<String, SidecarError> {
    let (_, body) = call(
        client,
        Method::GET,
        Some(bucket),
        None,
        &[("policy", "")],
        HeaderMap::new(),
        Payload::Empty,
        Retry::Safe,
    )
    .await?;
    String::from_utf8(body.to_vec())
        .map_err(|_| invalid_response("The bucket policy is not UTF-8 text."))
}

async fn get_bucket_admin_state(params: &Value) -> SidecarResult {
    let bucket = bucket_name(
        params,
        "Bucket name is required for bucket admin inspection.",
    )?;
    let client = client_for(params)?;
    admin_state(&client, &bucket).await
}

fn lifecycle_rule_summary(rule: &Value) -> Value {
    let filter = &rule["Filter"];
    let prefix = filter["Prefix"]
        .as_str()
        .or_else(|| filter["And"]["Prefix"].as_str())
        .or_else(|| rule["Prefix"].as_str())
        .unwrap_or_default();
    let transition = &rule["Transitions"][0];
    let noncurrent = &rule["NoncurrentVersionTransitions"][0];
    json!({
        "id": rule["ID"].as_str().unwrap_or("rule"),
        "enabled": rule["Status"] == "Enabled",
        "prefix": prefix,
        "expirationDays": rule["Expiration"]["Days"],
        "deleteExpiredObjectDeleteMarkers": rule["Expiration"]["ExpiredObjectDeleteMarker"].as_bool().unwrap_or(false),
        "transitionStorageClass": transition["StorageClass"],
        "transitionDays": transition["Days"],
        "nonCurrentExpirationDays": rule["NoncurrentVersionExpiration"]["NoncurrentDays"],
        "nonCurrentTransitionStorageClass": noncurrent["StorageClass"],
        "nonCurrentTransitionDays": noncurrent["NoncurrentDays"],
        "abortIncompleteMultipartUploadDays": rule["AbortIncompleteMultipartUpload"]["DaysAfterInitiation"],
    })
}

/// Object Lock configuration mapped from the provider document. Only
/// `ObjectLockEnabled=Enabled` (or a rule, which requires it) counts as enabled.
pub(crate) fn object_lock_summary(configuration: Option<&Value>) -> Value {
    let Some(configuration) = configuration else {
        return json!({"enabled": false, "mode": null, "days": null, "years": null, "value": null, "unit": null});
    };
    let retention = &configuration["Rule"]["DefaultRetention"];
    let enabled = configuration["ObjectLockEnabled"]
        .as_str()
        .is_some_and(|value| value.trim() == "Enabled")
        || configuration["Rule"].is_object();
    let days = retention["Days"].as_i64();
    let years = retention["Years"].as_i64();
    json!({
        "enabled": enabled,
        "mode": retention["Mode"].as_str(),
        "days": days,
        "years": years,
        "value": days.or(years),
        "unit": if days.is_some() { Some("days") } else if years.is_some() { Some("years") } else { None },
    })
}

async fn admin_state(client: &Client, bucket: &str) -> SidecarResult {
    let (versioning, encryption, lifecycle, policy, cors, tagging, object_lock) = tokio::join!(
        timed(fetch_document(
            client,
            bucket,
            "versioning",
            "VersioningConfiguration"
        )),
        timed(fetch_document(
            client,
            bucket,
            "encryption",
            "ServerSideEncryptionConfiguration"
        )),
        timed(fetch_document(
            client,
            bucket,
            "lifecycle",
            "LifecycleConfiguration"
        )),
        timed(fetch_policy(client, bucket)),
        timed(fetch_document(client, bucket, "cors", "CORSConfiguration")),
        timed(fetch_document(client, bucket, "tagging", "Tagging")),
        timed(fetch_document(
            client,
            bucket,
            "object-lock",
            "ObjectLockConfiguration"
        )),
    );
    let mut calls = Vec::new();
    let versioning = optional_call(&mut calls, "GetBucketVersioning", versioning)?;
    let encryption = optional_call(&mut calls, "GetBucketEncryption", encryption)?;
    let lifecycle = optional_call(&mut calls, "GetBucketLifecycleConfiguration", lifecycle)?;
    let policy = optional_call(&mut calls, "GetBucketPolicy", policy)?;
    let cors = optional_call(&mut calls, "GetBucketCors", cors)?;
    let tagging = optional_call(&mut calls, "GetBucketTagging", tagging)?;
    let object_lock = optional_call(&mut calls, "GetObjectLockConfiguration", object_lock)?;

    let versioning_state = match &versioning {
        None => "unknown".to_string(),
        Some((node, _)) => node
            .text_of("Status")
            .filter(|status| !status.is_empty())
            .unwrap_or("never-enabled")
            .to_string(),
    };

    let lifecycle_document = lifecycle
        .as_ref()
        .map(|(node, _)| xml::to_json(Doc::Lifecycle, node));
    let transition_minimum = lifecycle.as_ref().and_then(|(_, headers)| {
        header_text(headers, "x-amz-transition-default-minimum-object-size")
    });
    let lifecycle_rules: Vec<Value> = lifecycle_document
        .as_ref()
        .and_then(|document| document["Rules"].as_array())
        .map(|rules| rules.iter().map(lifecycle_rule_summary).collect())
        .unwrap_or_default();
    let lifecycle_json = match &lifecycle_document {
        Some(document) => {
            let mut value = match document {
                Value::Object(map) => map.clone(),
                _ => Map::new(),
            };
            value.entry("Rules").or_insert_with(|| json!([]));
            if let Some(minimum) = &transition_minimum {
                value.insert(
                    "TransitionDefaultMinimumObjectSize".to_string(),
                    json!(minimum),
                );
            }
            pretty(&Value::Object(value), "{\n  \"Rules\": []\n}")
        }
        None => "{\n  \"Rules\": []\n}".to_string(),
    };

    let encryption_document = encryption
        .as_ref()
        .map(|(node, _)| xml::to_json(Doc::Encryption, node));
    let encryption_rules = encryption_document
        .as_ref()
        .and_then(|document| document["Rules"].as_array())
        .cloned()
        .unwrap_or_default();
    let encryption_summary = encryption_rules
        .first()
        .and_then(|rule| rule["ApplyServerSideEncryptionByDefault"].as_object())
        .and_then(|defaults| {
            let algorithm = defaults.get("SSEAlgorithm")?.as_str()?;
            Some(
                match defaults
                    .get("KMSMasterKeyID")
                    .and_then(Value::as_str)
                    .filter(|key| !key.is_empty())
                {
                    Some(key) => format!("{algorithm} ({key})"),
                    None => algorithm.to_string(),
                },
            )
        })
        .unwrap_or_else(|| "Not configured".to_string());

    let cors_rules = cors
        .as_ref()
        .map(|(node, _)| xml::to_json(Doc::Cors, node)["CORSRules"].clone())
        .filter(Value::is_array)
        .unwrap_or_else(|| json!([]));

    let tags: Map<String, Value> = tagging
        .as_ref()
        .and_then(|(node, _)| {
            xml::to_json(Doc::Tagging, node)["TagSet"]
                .as_array()
                .cloned()
        })
        .unwrap_or_default()
        .iter()
        .map(|tag| {
            (
                tag["Key"].as_str().unwrap_or_default().to_string(),
                json!(tag["Value"].as_str().unwrap_or_default()),
            )
        })
        .collect();

    let lock_document = object_lock
        .as_ref()
        .map(|(node, _)| xml::to_json(Doc::ObjectLock, node));
    let lock = object_lock_summary(lock_document.as_ref());
    let policy_text = policy.filter(|text| !text.trim().is_empty());

    Ok(json!({
        "bucketName": bucket,
        "versioningEnabled": versioning_state == "Enabled",
        "versioningStatus": versioning_state,
        "versioningState": versioning_state,
        "objectLockEnabled": lock["enabled"],
        "objectLockMode": lock["mode"],
        "objectLockRetentionDays": lock["days"],
        "objectLockRetentionYears": lock["years"],
        "objectLockRetentionValue": lock["value"],
        "objectLockRetentionUnit": lock["unit"],
        "objectLockRetention": {"value": lock["value"], "unit": lock["unit"]},
        "lifecycleEnabled": !lifecycle_rules.is_empty(),
        "policyAttached": policy_text.is_some(),
        "corsEnabled": cors_rules.as_array().is_some_and(|rules| !rules.is_empty()),
        "encryptionEnabled": !encryption_rules.is_empty(),
        "encryptionSummary": encryption_summary,
        "tags": tags,
        "lifecycleRules": lifecycle_rules,
        "lifecycleJson": lifecycle_json,
        "transitionDefaultMinimumObjectSize": transition_minimum,
        "policyJson": policy_text.unwrap_or_else(|| "{}".to_string()),
        "corsJson": pretty(&cors_rules, "[]"),
        "encryptionJson": encryption_document.map(|document| pretty(&document, "{}")).unwrap_or_else(|| "{}".to_string()),
        "sections": section_statuses(&calls),
        "apiCalls": calls,
    }))
}

async fn put_document(
    client: &Client,
    bucket: &str,
    subresource: &str,
    body: Vec<u8>,
    extra: HeaderMap,
) -> Result<(), SidecarError> {
    let mut headers = xml_headers(&body);
    headers.extend(extra);
    call(
        client,
        Method::PUT,
        Some(bucket),
        None,
        &[(subresource, "")],
        headers,
        Payload::Bytes(Bytes::from(body)),
        Retry::Safe,
    )
    .await?;
    Ok(())
}

async fn delete_config(
    client: &Client,
    bucket: &str,
    subresource: &str,
) -> Result<(), SidecarError> {
    call(
        client,
        Method::DELETE,
        Some(bucket),
        None,
        &[(subresource, "")],
        HeaderMap::new(),
        Payload::Empty,
        Retry::Safe,
    )
    .await?;
    Ok(())
}

async fn delete_subresource(params: &Value, subresource: &str) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name is required.")?;
    let client = client_for(params)?;
    delete_config(&client, &bucket, subresource).await?;
    admin_state(&client, &bucket).await
}

async fn put_bucket_lifecycle(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name and lifecycle JSON are required.")?;
    let parsed = parse_json_param(
        params,
        "lifecycleJson",
        "Bucket name and lifecycle JSON are required.",
        "Lifecycle",
    )?;
    let mut configuration = match parsed {
        Value::Array(rules) => {
            let mut map = Map::new();
            map.insert("Rules".to_string(), Value::Array(rules));
            map
        }
        Value::Object(map) => map,
        _ => {
            return Err(invalid_config(
                "Lifecycle JSON must be an object with Rules.",
            ))
        }
    };
    let minimum = configuration
        .remove("TransitionDefaultMinimumObjectSize")
        .filter(|value| !value.is_null())
        .or_else(|| {
            Some(params["transitionDefaultMinimumObjectSize"].clone())
                .filter(|value| !value.is_null())
        });
    if !configuration.get("Rules").is_none_or(Value::is_array) {
        return Err(invalid_config("Lifecycle Rules must be an array."));
    }
    let client = client_for(params)?;
    if let Some(expected) = params
        .get("expectedLifecycleJson")
        .filter(|value| !value.is_null())
    {
        let expected: Value = match expected {
            Value::String(text) => serde_json::from_str(text)
                .map_err(|_| invalid_config("Expected lifecycle JSON could not be parsed."))?,
            other => other.clone(),
        };
        let expected_rules = if expected.is_array() {
            expected
        } else {
            expected["Rules"].clone()
        };
        let current = match fetch_document(&client, &bucket, "lifecycle", "LifecycleConfiguration")
            .await
        {
            Ok((node, _)) => xml::to_json(Doc::Lifecycle, &node)["Rules"].clone(),
            Err(error) if aws_code(&error).as_deref() == Some("NoSuchLifecycleConfiguration") => {
                json!([])
            }
            Err(error) => return Err(error),
        };
        let normalise = |value: Value| if value.is_null() { json!([]) } else { value };
        if normalise(current) != normalise(expected_rules) {
            return Err(SidecarError::new(
                "object_conflict",
                "Lifecycle changed since it was loaded. Refresh before applying.",
            ));
        }
    }
    let empty = configuration
        .get("Rules")
        .and_then(Value::as_array)
        .is_none_or(Vec::is_empty);
    if empty {
        delete_config(&client, &bucket, "lifecycle").await?;
    } else {
        let mut extra = HeaderMap::new();
        if let Some(minimum) = minimum {
            let text = minimum
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| minimum.to_string());
            set_header(
                &mut extra,
                "x-amz-transition-default-minimum-object-size",
                &text,
            )?;
        }
        let body = xml::document(
            Doc::Lifecycle,
            "LifecycleConfiguration",
            &Value::Object(configuration),
        )?;
        put_document(&client, &bucket, "lifecycle", body, extra).await?;
    }
    admin_state(&client, &bucket).await
}

async fn put_bucket_policy(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name and policy JSON are required.")?;
    let policy = required_text(
        params,
        "policyJson",
        "Bucket name and policy JSON are required.",
    )?;
    let client = client_for(params)?;
    let mut headers = HeaderMap::new();
    headers.insert(
        http::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    set_header(&mut headers, "content-md5", &content_md5(policy.as_bytes()))?;
    call(
        &client,
        Method::PUT,
        Some(&bucket),
        None,
        &[("policy", "")],
        headers,
        Payload::Bytes(Bytes::from(policy)),
        Retry::Safe,
    )
    .await?;
    admin_state(&client, &bucket).await
}

async fn put_bucket_cors(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name and CORS JSON are required.")?;
    let parsed = parse_json_param(
        params,
        "corsJson",
        "Bucket name and CORS JSON are required.",
        "CORS",
    )?;
    let rules = match parsed {
        Value::Array(rules) => rules,
        Value::Object(map) => match map.get("CORSRules") {
            Some(Value::Array(rules)) => rules.clone(),
            _ => return Err(invalid_config("CORS JSON must be an array of rules.")),
        },
        _ => return Err(invalid_config("CORS JSON must be an array of rules.")),
    };
    let client = client_for(params)?;
    if rules.is_empty() {
        delete_config(&client, &bucket, "cors").await?;
    } else {
        let body = xml::document(Doc::Cors, "CORSConfiguration", &json!({"CORSRules": rules}))?;
        put_document(&client, &bucket, "cors", body, HeaderMap::new()).await?;
    }
    admin_state(&client, &bucket).await
}

async fn put_bucket_encryption(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name and encryption JSON are required.")?;
    let parsed = parse_json_param(
        params,
        "encryptionJson",
        "Bucket name and encryption JSON are required.",
        "Encryption",
    )?;
    if !parsed.is_object() || parsed["Rules"].as_array().is_none_or(Vec::is_empty) {
        return Err(invalid_config(
            "Encryption JSON must contain at least one rule.",
        ));
    }
    let client = client_for(params)?;
    // Every rule field, including BlockedEncryptionTypes and provider
    // extensions, is written back exactly as given.
    let body = xml::document(
        Doc::Encryption,
        "ServerSideEncryptionConfiguration",
        &parsed,
    )?;
    put_document(&client, &bucket, "encryption", body, HeaderMap::new()).await?;
    admin_state(&client, &bucket).await
}

async fn put_bucket_tagging(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name and tags are required.")?;
    let tags = params["tags"]
        .as_object()
        .ok_or_else(|| invalid_config("Bucket name and tags are required."))?;
    let tag_set: Vec<Value> = tags
        .iter()
        .map(|(key, value)| {
            let value = match value {
                Value::String(text) => text.clone(),
                Value::Null => String::new(),
                other => other.to_string(),
            };
            json!({"Key": key, "Value": value})
        })
        .collect();
    let client = client_for(params)?;
    let body = xml::document(Doc::Tagging, "Tagging", &json!({"TagSet": tag_set}))?;
    put_document(&client, &bucket, "tagging", body, HeaderMap::new()).await?;
    admin_state(&client, &bucket).await
}

// ---------------------------------------------------------------------------
// Listings
// ---------------------------------------------------------------------------

async fn list_objects(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name is required for object listing.")?;
    let prefix = params["prefix"].as_str().unwrap_or_default().to_string();
    let flat = params["flat"].as_bool().unwrap_or(false);
    let continuation = params["cursor"]["value"]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let client = client_for(params)?;
    let max_keys = params["maxKeys"]
        .as_u64()
        .unwrap_or(1000)
        .clamp(1, 1000)
        .to_string();
    let mut query: Vec<(&str, &str)> = vec![
        ("list-type", "2"),
        ("prefix", prefix.as_str()),
        ("max-keys", max_keys.as_str()),
        ("encoding-type", "url"),
    ];
    if !flat {
        query.push(("delimiter", "/"));
    }
    if let Some(token) = continuation.as_deref() {
        query.push(("continuation-token", token));
    }
    let (_, body) = call(
        &client,
        Method::GET,
        Some(&bucket),
        None,
        &query,
        HeaderMap::new(),
        Payload::Empty,
        Retry::Safe,
    )
    .await?;
    let root = parse_document(&body, "ListBucketResult")?;
    let (items, next, has_more) = object_page(&root, &prefix, flat)?;
    if has_more && (next.is_none() || next == continuation) {
        return Err(invalid_response(
            "S3 returned a truncated listing without a progressing continuation token.",
        ));
    }
    Ok(json!({
        "items": items,
        "nextCursor": {"value": if has_more { next } else { None }, "hasMore": has_more},
    }))
}

/// Maps one ListObjectsV2 page. Unknown elements are ignored.
pub(crate) fn object_page(
    root: &Node,
    prefix: &str,
    flat: bool,
) -> Result<(Vec<Value>, Option<String>, bool), SidecarError> {
    let encoded = listing_encoded(root);
    let mut items = Vec::new();
    for entry in &root.children {
        match entry.name.as_str() {
            "CommonPrefixes" => {
                let folder =
                    decode_listing_value(entry.text_of("Prefix").unwrap_or_default(), encoded)?;
                let name = folder
                    .strip_prefix(prefix)
                    .filter(|name| !name.is_empty())
                    .unwrap_or(&folder)
                    .to_string();
                items.push(json!({
                    "key": folder,
                    "name": name,
                    "size": 0,
                    "storageClass": "FOLDER",
                    "modifiedAt": now_iso(),
                    "isFolder": true,
                    "etag": null,
                    "metadataCount": 0,
                }));
            }
            "Contents" => {
                let key = decode_listing_value(entry.text_of("Key").unwrap_or_default(), encoded)?;
                if !flat && key == prefix {
                    continue;
                }
                let name = key
                    .strip_prefix(prefix)
                    .filter(|name| !name.is_empty())
                    .unwrap_or(&key)
                    .to_string();
                let etag = entry
                    .text_of("ETag")
                    .map(trim_etag)
                    .filter(|etag| !etag.is_empty());
                items.push(json!({
                    "key": key,
                    "name": name,
                    "size": integer(entry, "Size"),
                    "storageClass": entry.text_of("StorageClass").filter(|class| !class.is_empty()).unwrap_or("STANDARD"),
                    "modifiedAt": entry.text_of("LastModified").map(iso_time).unwrap_or_else(|| EPOCH_ISO.to_string()),
                    "isFolder": false,
                    "etag": etag,
                    "metadataCount": 0,
                }));
            }
            _ => {}
        }
    }
    items.sort_by(|left, right| {
        let left_folder = left["isFolder"].as_bool().unwrap_or(false);
        let right_folder = right["isFolder"].as_bool().unwrap_or(false);
        right_folder.cmp(&left_folder).then_with(|| {
            left["key"]
                .as_str()
                .unwrap_or_default()
                .to_lowercase()
                .cmp(&right["key"].as_str().unwrap_or_default().to_lowercase())
        })
    });
    let next = root
        .text_of("NextContinuationToken")
        .filter(|token| !token.is_empty())
        .map(str::to_owned);
    Ok((items, next, is_true(root, "IsTruncated")))
}

/// Accepts the desktop cursor (`{"keyMarker","versionIdMarker"}`), the mobile
/// cursor (`{"key","version"}`) and the original bare key-marker string.
pub(crate) fn decode_version_cursor(cursor: &Value) -> Result<(String, String), SidecarError> {
    let raw = match &cursor["value"] {
        Value::String(text) if !text.is_empty() => text.clone(),
        Value::Object(map) => Value::Object(map.clone()).to_string(),
        _ => return Ok((String::new(), String::new())),
    };
    match serde_json::from_str::<Value>(&raw) {
        Ok(Value::Object(map)) => {
            let text = |names: &[&str]| {
                names
                    .iter()
                    .find_map(|name| map.get(*name).and_then(Value::as_str))
                    .unwrap_or_default()
                    .to_string()
            };
            let key = text(&["keyMarker", "key"]);
            let version = text(&["versionIdMarker", "version"]);
            if key.is_empty() && version.is_empty() {
                return Err(invalid_config(
                    "Version listing cursor has no continuation markers.",
                ));
            }
            Ok((key, version))
        }
        _ if raw.starts_with('{') => Err(invalid_config("Invalid version listing cursor.")),
        _ => Ok((raw, String::new())),
    }
}

async fn list_object_versions(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name is required for version listing.")?;
    let key = params["key"].as_str().unwrap_or_default().to_string();
    let options = &params["options"];
    let filter_mode = options["filterMode"]
        .as_str()
        .filter(|mode| !mode.is_empty())
        .unwrap_or("prefix");
    let filter_value = options["filterValue"].as_str().unwrap_or_default();
    let scope = params["prefix"].as_str().unwrap_or_default();
    let prefix = if !key.is_empty() {
        key.as_str()
    } else if filter_mode == "prefix" && filter_value.starts_with(scope) {
        filter_value
    } else {
        scope
    };
    let regex = if filter_mode == "regex" && !filter_value.is_empty() {
        Some(
            regex::RegexBuilder::new(filter_value)
                .case_insensitive(true)
                .build()
                .map_err(|_| invalid_config("Invalid object version regular expression."))?,
        )
    } else {
        None
    };
    let folded_filter = filter_value.to_lowercase();
    let max_keys = params["maxKeys"]
        .as_u64()
        .unwrap_or(1000)
        .clamp(1, 1000)
        .to_string();
    let (key_marker, version_marker) = decode_version_cursor(&params["cursor"])?;
    let client = client_for(params)?;
    let mut query: Vec<(&str, &str)> = vec![
        ("versions", ""),
        ("prefix", prefix),
        ("max-keys", max_keys.as_str()),
        ("encoding-type", "url"),
    ];
    if let Some(delimiter) = params["delimiter"].as_str().filter(|s| !s.is_empty()) {
        query.push(("delimiter", delimiter));
    }
    if !key_marker.is_empty() {
        query.push(("key-marker", key_marker.as_str()));
    }
    if !version_marker.is_empty() {
        query.push(("version-id-marker", version_marker.as_str()));
    }
    let (_, body) = call(
        &client,
        Method::GET,
        Some(&bucket),
        None,
        &query,
        HeaderMap::new(),
        Payload::Empty,
        Retry::Safe,
    )
    .await?;
    let root = parse_document(&body, "ListVersionsResult")?;
    let mut result = version_page(&root, &key, &key_marker, &version_marker)?;
    let items = result["items"]
        .as_array_mut()
        .expect("version page always contains an item array");
    items.retain(|item| {
        let flag = if item["deleteMarker"] == true {
            "showDeleteMarkers"
        } else {
            "showVersions"
        };
        if options[flag] == false {
            return false;
        }
        let key = item["key"].as_str().unwrap_or_default();
        let version = item["versionId"].as_str().unwrap_or_default();
        if !key.starts_with(prefix) {
            return false;
        }
        match (filter_mode, &regex) {
            (_, _) if filter_value.is_empty() => true,
            ("prefix", _) => key.starts_with(filter_value),
            ("regex", Some(regex)) => regex.is_match(key) || regex.is_match(version),
            _ => {
                key.to_lowercase().contains(&folded_filter)
                    || version.to_lowercase().contains(&folded_filter)
            }
        }
    });
    let count = items.len();
    let markers = items
        .iter()
        .filter(|item| item["deleteMarker"] == true)
        .count();
    result["totalCount"] = json!(count);
    result["deleteMarkerCount"] = json!(markers);
    result["versionCount"] = json!(count - markers);
    if params["delimiter"].is_string() {
        let common: Vec<_> = root
            .children
            .iter()
            .filter(|entry| entry.name == "CommonPrefixes")
            .filter_map(|entry| entry.text_of("Prefix"))
            .map(|value| decode_listing_value(value, listing_encoded(&root)))
            .collect::<Result<_, _>>()?;
        result["commonPrefixes"] = json!(common);
    }
    Ok(result)
}

/// Maps one ListObjectVersions page, keeping provider order within a second.
pub(crate) fn version_page(
    root: &Node,
    key: &str,
    key_marker: &str,
    version_marker: &str,
) -> SidecarResult {
    let encoded = listing_encoded(root);
    let mut items = Vec::new();
    for entry in &root.children {
        let delete_marker = match entry.name.as_str() {
            "Version" => false,
            "DeleteMarker" => true,
            _ => continue,
        };
        let entry_key = decode_listing_value(entry.text_of("Key").unwrap_or_default(), encoded)?;
        if !key.is_empty() && entry_key != key {
            continue;
        }
        let mut item = json!({
            "key": entry_key,
            "versionId": entry.text_of("VersionId").unwrap_or_default(),
            "modifiedAt": entry.text_of("LastModified").map(iso_time).unwrap_or_else(|| EPOCH_ISO.to_string()),
            "latest": is_true(entry, "IsLatest"),
            "deleteMarker": delete_marker,
            "size": if delete_marker { 0 } else { integer(entry, "Size") },
            "storageClass": if delete_marker { "DELETE_MARKER" } else { entry.text_of("StorageClass").filter(|class| !class.is_empty()).unwrap_or("STANDARD") },
        });
        if let Some(etag) = entry
            .text_of("ETag")
            .map(trim_etag)
            .filter(|etag| !etag.is_empty())
        {
            item["etag"] = json!(etag);
        }
        items.push(item);
    }
    // Stable: same-second versions keep the provider's newest-first order.
    items.sort_by(|left, right| {
        right["modifiedAt"]
            .as_str()
            .cmp(&left["modifiedAt"].as_str())
    });
    let has_more = is_true(root, "IsTruncated");
    let next_key =
        decode_listing_value(root.text_of("NextKeyMarker").unwrap_or_default(), encoded)?;
    let next_version = root
        .text_of("NextVersionIdMarker")
        .unwrap_or_default()
        .to_string();
    let cursor_value = if has_more {
        if (next_key.is_empty() && next_version.is_empty())
            || (next_key == key_marker && next_version == version_marker)
        {
            return Err(invalid_response(
                "S3 returned missing or repeated version listing markers.",
            ));
        }
        Some(json!({"keyMarker": next_key, "versionIdMarker": next_version}).to_string())
    } else {
        None
    };
    let delete_markers = items
        .iter()
        .filter(|item| item["deleteMarker"] == true)
        .count();
    Ok(json!({
        "items": items,
        "cursor": {"value": cursor_value, "hasMore": has_more},
        "totalCount": items.len(),
        "versionCount": items.len() - delete_markers,
        "deleteMarkerCount": delete_markers,
    }))
}

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

/// Encryption reported by a HEAD response (contract `getObjectDetails`).
pub(crate) fn reported_encryption(headers: &HeaderMap) -> Option<Value> {
    let mode = if headers.contains_key("x-amz-server-side-encryption-customer-algorithm") {
        "sse-c"
    } else {
        match header_text(headers, "x-amz-server-side-encryption")?.trim() {
            "AES256" => "sse-s3",
            "aws:kms" => "sse-kms",
            "aws:kms:dsse" => "dsse-kms",
            _ => return None,
        }
    };
    let mut result = json!({"mode": mode});
    if let Some(value) = header_text(headers, "x-amz-server-side-encryption-aws-kms-key-id") {
        result["kmsKeyId"] = json!(value);
    }
    match header_text(headers, "x-amz-server-side-encryption-bucket-key-enabled")
        .as_deref()
        .map(str::trim)
    {
        Some("true") => result["bucketKeyEnabled"] = json!(true),
        Some("false") => result["bucketKeyEnabled"] = json!(false),
        _ => {}
    }
    if let Some(value) = header_text(headers, "x-amz-server-side-encryption-customer-key-md5") {
        result["customerKeyMd5"] = json!(value);
    }
    Some(result)
}

/// Object Lock state reported by a HEAD response, when any is present.
pub(crate) fn reported_object_lock(headers: &HeaderMap) -> Option<Value> {
    let mode = header_text(headers, "x-amz-object-lock-mode");
    let until = header_text(headers, "x-amz-object-lock-retain-until-date");
    let hold = header_text(headers, "x-amz-object-lock-legal-hold");
    if mode.is_none() && until.is_none() && hold.is_none() {
        return None;
    }
    Some(json!({
        "mode": mode,
        "retainUntilDate": until.as_deref().map(iso_time),
        "legalHold": hold.as_deref().map(|value| value.trim().eq_ignore_ascii_case("ON")),
        "legalHoldStatus": hold,
    }))
}

fn object_metadata(headers: &HeaderMap) -> Map<String, Value> {
    headers
        .iter()
        .filter_map(|(name, value)| {
            let field = name.as_str().strip_prefix("x-amz-meta-")?;
            Some((
                field.to_string(),
                json!(String::from_utf8_lossy(value.as_bytes())),
            ))
        })
        .collect()
}

async fn get_object_details(params: &Value) -> SidecarResult {
    let read_headers = encryption_headers(params, false)?;
    let has_key = read_headers.contains_key("x-amz-server-side-encryption-customer-key");
    let message = "Bucket name and object key are required for object inspection.";
    let bucket = bucket_name(params, message)?;
    let key = required_text(params, "key", message)?;
    let version = params["versionId"]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let client = client_for(params)?;
    let mut query: Vec<(&str, &str)> = Vec::new();
    if let Some(value) = version.as_deref() {
        query.push(("versionId", value));
    }
    let mut calls = Vec::new();
    let mut debug_events = vec![json!({
        "timestamp": now_iso(),
        "level": "DEBUG",
        "message": format!("Fetching object diagnostics for {bucket}/{key}."),
    })];
    let head = timed(async {
        call(
            &client,
            Method::HEAD,
            Some(&bucket),
            Some(&key),
            &query,
            read_headers.clone(),
            Payload::Empty,
            Retry::Safe,
        )
        .await
        .map(|(headers, _)| headers)
        .map_err(|error| with_read_hint(error, has_key))
    })
    .await;
    let head = required_call(&mut calls, "HeadObject", head)?;
    let mut tag_query = query.clone();
    tag_query.push(("tagging", ""));
    let tagging = timed(async {
        let (_, body) = call(
            &client,
            Method::GET,
            Some(&bucket),
            Some(&key),
            &tag_query,
            HeaderMap::new(),
            Payload::Empty,
            Retry::Safe,
        )
        .await?;
        parse_document(&body, "Tagging")
    })
    .await;
    let tagging = optional_call(&mut calls, "GetObjectTagging", tagging)?;

    let tags: Map<String, Value> = tagging
        .as_ref()
        .and_then(|node| {
            xml::to_json(Doc::Tagging, node)["TagSet"]
                .as_array()
                .cloned()
        })
        .unwrap_or_default()
        .iter()
        .map(|tag| {
            (
                tag["Key"].as_str().unwrap_or_default().to_string(),
                json!(tag["Value"].as_str().unwrap_or_default()),
            )
        })
        .collect();
    let etag = header_text(&head, "etag")
        .map(|value| trim_etag(&value))
        .unwrap_or_default();
    let storage_class = header_text(&head, "x-amz-storage-class").filter(|value| !value.is_empty());
    let mut headers = Map::new();
    if !etag.is_empty() {
        headers.insert("ETag".to_string(), json!(etag));
    }
    headers.insert(
        "Content-Length".to_string(),
        json!(header_text(&head, "content-length").unwrap_or_else(|| "0".to_string())),
    );
    for (label, name) in [
        ("Content-Type", "content-type"),
        ("Cache-Control", "cache-control"),
        ("Content-Disposition", "content-disposition"),
        ("Content-Encoding", "content-encoding"),
        ("Content-Language", "content-language"),
        ("Expires", "expires"),
    ] {
        if let Some(value) = header_text(&head, name).filter(|value| !value.is_empty()) {
            headers.insert(label.to_string(), json!(value));
        }
    }
    if let Some(value) = header_text(&head, "last-modified") {
        headers.insert("Last-Modified".to_string(), json!(iso_time(&value)));
    }
    if let Some(value) = &storage_class {
        headers.insert("Storage-Class".to_string(), json!(value));
    }
    debug_events.push(json!({
        "timestamp": now_iso(),
        "level": "INFO",
        "message": format!("Loaded metadata and {} tag(s) for {key}.", tags.len()),
    }));
    let mut result = json!({
        "key": key,
        "versionId": header_text(&head, "x-amz-version-id").or(version),
        "etag": etag,
        "storageClass": storage_class.unwrap_or_else(|| "STANDARD".to_string()),
        "restore": header_text(&head, "x-amz-restore"),
        "archiveStatus": header_text(&head, "x-amz-archive-status"),
        "metadata": object_metadata(&head),
        "headers": headers,
        "tags": tags,
        "debugEvents": debug_events,
        "sections": section_statuses(&calls),
        "apiCalls": calls,
        "debugLogExcerpt": [
            format!("Resolved endpoint {}.", params["profile"]["endpointUrl"].as_str().unwrap_or_default()),
            format!("Completed HEAD and tagging diagnostics for {bucket}/{key}."),
        ],
        "rawDiagnostics": {"bucketName": bucket, "engineState": "healthy"},
    });
    if let Some(encryption) = reported_encryption(&head) {
        result["encryption"] = encryption;
    }
    if let Some(lock) = reported_object_lock(&head) {
        result["objectLock"] = lock;
    }
    Ok(result)
}

async fn create_folder(params: &Value) -> SidecarResult {
    let mut headers = encryption_headers(params, true)?;
    // S3 requires a checksum when the bucket applies default retention.
    headers.insert(
        "content-md5",
        HeaderValue::from_static("1B2M2Y8AsgTpgAmY7PhCfg=="),
    );
    let message = "Bucket name and key are required to create a folder.";
    let bucket = bucket_name(params, message)?;
    let mut key = required_text(params, "key", message)?;
    if !key.ends_with('/') {
        key.push('/');
    }
    let client = client_for(params)?;
    call(
        &client,
        Method::PUT,
        Some(&bucket),
        Some(&key),
        &[],
        headers,
        Payload::Empty,
        Retry::Never,
    )
    .await?;
    Ok(json!({"created": true, "key": key}))
}

// ---------------------------------------------------------------------------
// Object Lock (storageAction)
// ---------------------------------------------------------------------------

async fn bucket_protection(params: &Value, set: bool) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name is required.")?;
    let client = client_for(params)?;
    if set {
        let configuration = params
            .get("configuration")
            .filter(|value| value.is_object())
            .ok_or_else(|| invalid_config("An Object Lock configuration is required."))?;
        let body = xml::document(Doc::ObjectLock, "ObjectLockConfiguration", configuration)?;
        let headers = xml_headers(&body);
        // Retention changes can be irreversible; never replay an uncertain write.
        call(
            &client,
            Method::PUT,
            Some(&bucket),
            None,
            &[("object-lock", "")],
            headers,
            Payload::Bytes(Bytes::from(body)),
            Retry::Never,
        )
        .await?;
    }
    let mut calls = Vec::new();
    let read = timed(fetch_document(
        &client,
        &bucket,
        "object-lock",
        "ObjectLockConfiguration",
    ))
    .await;
    let configuration = optional_call(&mut calls, "GetObjectLockConfiguration", read)?
        .map(|(node, _)| xml::to_json(Doc::ObjectLock, &node))
        .unwrap_or_else(|| json!({}));
    let summary = object_lock_summary(
        Some(&configuration).filter(|value| value.as_object().is_some_and(|map| !map.is_empty())),
    );
    Ok(json!({
        "configuration": configuration,
        "objectLockEnabled": summary["enabled"],
        "defaultRetention": {"mode": summary["mode"], "days": summary["days"], "years": summary["years"]},
        "sections": calls.clone(),
        "apiCalls": calls,
    }))
}

struct ObjectRef {
    bucket: String,
    key: String,
    version: Option<String>,
}

impl ObjectRef {
    fn from(params: &Value) -> Result<Self, SidecarError> {
        let message = "Bucket name and exact object key are required.";
        Ok(Self {
            bucket: bucket_name(params, message)?,
            key: required_text(params, "key", message)?,
            version: params["versionId"]
                .as_str()
                .filter(|id| !id.is_empty())
                .map(str::to_owned),
        })
    }

    fn query<'a>(&'a self, subresource: &'a str) -> Vec<(&'a str, &'a str)> {
        let mut query = vec![(subresource, "")];
        if let Some(version) = self.version.as_deref() {
            query.push(("versionId", version));
        }
        query
    }
}

async fn object_protection(params: &Value, set: bool) -> SidecarResult {
    let mut object = ObjectRef::from(params)?;
    let client = client_for(params)?;
    if set {
        let retention = params
            .get("retention")
            .filter(|value| !value.is_null())
            .map(|value| {
                let mode = value["Mode"]
                    .as_str()
                    .unwrap_or_default()
                    .to_ascii_uppercase();
                if !matches!(mode.as_str(), "GOVERNANCE" | "COMPLIANCE") {
                    return Err(invalid_config(
                        "Retention mode must be GOVERNANCE or COMPLIANCE.",
                    ));
                }
                let date = value["RetainUntilDate"]
                    .as_str()
                    .and_then(|date| chrono::DateTime::parse_from_rfc3339(date).ok())
                    .ok_or_else(|| invalid_config("RetainUntilDate must be an RFC 3339 date."))?;
                let mut document = value.clone();
                document["Mode"] = json!(mode);
                document["RetainUntilDate"] = json!(date
                    .with_timezone(&Utc)
                    .to_rfc3339_opts(SecondsFormat::AutoSi, true));
                xml::document(Doc::Retention, "Retention", &document)
            })
            .transpose()?;
        let hold = params
            .get("legalHold")
            .filter(|value| !value.is_null())
            .map(|value| {
                let status = match value {
                    Value::Bool(on) => if *on { "ON" } else { "OFF" }.to_owned(),
                    _ => value["Status"]
                        .as_str()
                        .unwrap_or_default()
                        .to_ascii_uppercase(),
                };
                if !matches!(status.as_str(), "ON" | "OFF") {
                    return Err(invalid_config("Legal hold status must be ON or OFF."));
                }
                xml::document(Doc::LegalHold, "LegalHold", &json!({"Status": status}))
            })
            .transpose()?;
        if retention.is_none() && hold.is_none() {
            return Err(invalid_config("Provide retention or legal hold to update."));
        }
        if object.version.is_none() {
            let (headers, _) = call(
                &client,
                Method::HEAD,
                Some(&object.bucket),
                Some(&object.key),
                &[],
                HeaderMap::new(),
                Payload::Empty,
                Retry::Safe,
            )
            .await?;
            object.version = Some(
                header_text(&headers, "x-amz-version-id")
                    .filter(|version| !version.is_empty())
                    .ok_or_else(|| {
                        invalid_response("Object protection requires the exact version ID.")
                    })?,
            );
        }
        let mut retention_applied = false;
        for (subresource, document) in [("retention", retention), ("legal-hold", hold)] {
            let Some(body) = document else { continue };
            let mut headers = xml_headers(&body);
            if subresource == "retention" && params["bypassGovernanceRetention"] == true {
                set_header(&mut headers, "x-amz-bypass-governance-retention", "true")?;
            }
            if let Err(error) = call(
                &client,
                Method::PUT,
                Some(&object.bucket),
                Some(&object.key),
                &object.query(subresource),
                headers,
                Payload::Bytes(Bytes::from(body)),
                Retry::Never,
            )
            .await
            {
                let mut error = crate::uncertain_mutation(error, "Object protection update");
                if retention_applied {
                    error.details["retentionApplied"] = json!(true);
                    error.message = format!(
                        "Retention was updated. Legal hold update failed: {}",
                        error.message
                    );
                }
                return Err(error);
            }
            if subresource == "retention" {
                retention_applied = true;
            }
        }
    }
    let (retention, hold) = tokio::join!(
        timed(async {
            let (_, body) = call(
                &client,
                Method::GET,
                Some(&object.bucket),
                Some(&object.key),
                &object.query("retention"),
                HeaderMap::new(),
                Payload::Empty,
                Retry::Safe,
            )
            .await?;
            parse_document(&body, "Retention")
        }),
        timed(async {
            let (_, body) = call(
                &client,
                Method::GET,
                Some(&object.bucket),
                Some(&object.key),
                &object.query("legal-hold"),
                HeaderMap::new(),
                Payload::Empty,
                Retry::Safe,
            )
            .await?;
            parse_document(&body, "LegalHold")
        }),
    );
    let mut calls = Vec::new();
    let retention = optional_call(&mut calls, "GetObjectRetention", retention)?
        .map(|node| {
            let mut value = xml::to_json(Doc::Retention, &node);
            if let Some(date) = value["RetainUntilDate"].as_str().map(iso_time) {
                value["RetainUntilDate"] = json!(date);
            }
            value
        })
        .unwrap_or_else(|| json!({}));
    let hold = optional_call(&mut calls, "GetObjectLegalHold", hold)?
        .map(|node| xml::to_json(Doc::LegalHold, &node))
        .unwrap_or_else(|| json!({}));
    Ok(json!({
        "retention": retention,
        "legalHold": hold,
        "sections": calls.clone(),
        "apiCalls": calls,
    }))
}

async fn delete_version(params: &Value) -> SidecarResult {
    let object = ObjectRef::from(params)?;
    let version = object
        .version
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            invalid_config(
                "An explicit version ID is required, including the literal null version ID.",
            )
        })?;
    let client = client_for(params)?;
    let mut headers = HeaderMap::new();
    if params["bypassGovernanceRetention"].as_bool() == Some(true) {
        set_header(&mut headers, "x-amz-bypass-governance-retention", "true")?;
    }
    call(
        &client,
        Method::DELETE,
        Some(&object.bucket),
        Some(&object.key),
        &[("versionId", version)],
        headers,
        Payload::Empty,
        Retry::Never,
    )
    .await?;
    Ok(json!({"successCount": 1, "failureCount": 0, "failures": [], "deleted": true}))
}
