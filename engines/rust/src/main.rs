#[cfg(test)]
mod review_regressions;
mod request_transport;
mod secret_hygiene;
#[macro_use]
mod object_encryption;
#[cfg(test)]
mod object_encryption_tests;
use object_encryption::Encryption;
mod client_encryption;
use client_encryption::ClientEncryption;
#[path = "../../rust-common/src/benchmark.rs"]
mod benchmark;
#[path = "../../rust-common/src/benchmark_runtime.rs"]
mod benchmark_runtime;
mod benchmark_backend;
use benchmark::*;
mod transfer_workers;
mod source_snapshot;
mod delete_all;
mod download_destination;
mod lifecycle;
mod server_copy;
mod s3_conformance;
use aws_config::{retry::RetryConfig, BehaviorVersion};
use aws_credential_types::Credentials;
use aws_sdk_s3::config::interceptors::{
    BeforeDeserializationInterceptorContextMut, BeforeTransmitInterceptorContextMut,
};
use aws_sdk_s3::config::{timeout::TimeoutConfig, ConfigBag, Intercept, Region, RuntimeComponents};
use aws_sdk_s3::error::ProvideErrorMetadata;
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::types::{
    BucketLifecycleConfiguration, BucketLocationConstraint, BucketVersioningStatus,
    CompletedMultipartUpload, CompletedPart, CorsConfiguration, CorsRule,
    CreateBucketConfiguration, Delete, LifecycleRule, ObjectIdentifier, ServerSideEncryption,
    ServerSideEncryptionByDefault, ServerSideEncryptionConfiguration, ServerSideEncryptionRule,
    Tag, Tagging, VersioningConfiguration,
};
use aws_sdk_s3::Client;
use bytes::Bytes;
use chrono::{SecondsFormat, Utc};
use download_destination::DestinationIndex;
#[cfg(test)]
use download_destination::StagedDownload;
use source_snapshot::SourceSnapshot;
use transfer_workers::run_bounded;
use lifecycle::{lifecycle_rule_raw, parse_lifecycle_rules};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::error::Error;
use std::fs;
use std::io::{self, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::sync::atomic::Ordering as AtomicOrdering;
use std::time::{Duration, Instant, SystemTime};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};
use tokio::runtime::Runtime;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;
use uuid::Uuid;

const ENGINE_VERSION: &str = "2.4.0";

const SUPPORTED_METHODS: &[&str] = &[
    "health",
    "getCapabilities",
    "s3ConformanceOp",
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
];

#[derive(Deserialize)]
struct Request {
    #[serde(rename = "requestId")]
    request_id: String,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Serialize)]
struct Response {
    #[serde(rename = "requestId")]
    request_id: String,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Profile {
    endpoint_type: String,
    auth_mode: String,
    aws_profile_name: String,
    role_arn: String,
    external_id: Option<String>,
    role_session_name: String,
    requester_pays: bool,
    expected_bucket_owner: Option<String>,
    endpoint_url: String,
    region: String,
    access_key: String,
    secret_key: String,
    session_token: Option<String>,
    path_style: bool,
    verify_tls: bool,
    connect_timeout_seconds: i64,
    read_timeout_seconds: i64,
    max_attempts: u32,
    max_pool_connections: usize,
    enable_api_logging: bool,
    enable_debug_logging: bool,
}

type BoxError = Box<dyn Error + Send + Sync + 'static>;

#[derive(Debug)]
struct SidecarError {
    code: &'static str,
    message: String,
    details: Value,
}

impl SidecarError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: secret_hygiene::text(&message.into()),
            details: Value::Object(Map::new()),
        }
    }

    fn with_details(code: &'static str, message: impl Into<String>, details: Value) -> Self {
        Self {
            code,
            message: secret_hygiene::text(&message.into()),
            details: secret_hygiene::value(details),
        }
    }
}

impl std::fmt::Display for SidecarError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for SidecarError {}

type SidecarResult = Result<Value, SidecarError>;

fn main() {
    let runtime = Runtime::new().expect("tokio runtime");
    runtime.block_on(async {
        let mut input = tokio::io::BufReader::new(tokio::io::stdin());
        let slots = Arc::new(Semaphore::new(request_transport::MAX_ACTIVE_REQUESTS));
        let admission = request_transport::Admission::new();
        let mut tasks = JoinSet::new();
        while let Ok(Some(frame)) = request_transport::read_frame(&mut input, request_transport::MAX_FRAME_BYTES).await {
            while tasks.try_join_next().is_some() {}
            let bytes = match frame {
                request_transport::Frame::Data(bytes) => bytes,
                request_transport::Frame::Oversized => {
                    println!("{}", json!({"requestId":null,"ok":false,"error":{"code":"invalid_request","message":"Input frame exceeds the 64 MiB limit."}}));
                    continue;
                }
            };
            if bytes.iter().all(u8::is_ascii_whitespace) { continue; }
            let request = match serde_json::from_slice::<Request>(&bytes) {
                Ok(r) => r,
                Err(_) => { println!("{}", json!({"requestId":null,"ok":false,"error":{"code":"invalid_config","message":"Malformed JSON request."}})); continue; }
            };
            drop(bytes);
            let permit = match admission.admit(&request.method) {
                Ok(permit) => permit,
                Err(error) => {
                    write_response(request.request_id, Err(error));
                    continue;
                }
            };
            // Execute the cheap/control path directly: it never waits for a transfer
            // slot, and a flood of controls cannot create an unbounded task queue.
            if permit.is_none() {
                execute_request(request).await;
                continue;
            }
            let slots = slots.clone();
            tasks.spawn(async move {
                let _admission = permit;
                let _slot = slots.acquire_owned().await.unwrap();
                execute_request(request).await;
            });
        }
        while tasks.join_next().await.is_some() {}
    });
}

async fn execute_request(request: Request) {
    let request_id = request.request_id.clone();
    let result = match tokio::spawn(handle_request(request)).await {
        Ok(result) => result,
        Err(error) => Err(SidecarError::new("internal_error", error.to_string())),
    };
    write_response(request_id, result);
}

fn write_response(request_id: String, result: SidecarResult) {
    let response = match result {
        Ok(result) => Response { request_id, ok:true, result:Some(result), error:None },
        Err(error) => Response { request_id, ok:false, result:None, error:Some(json!({"code":error.code,"message":error.message,"details":error.details})) },
    };
    if let Ok(output) = serde_json::to_string(&response) {
        #[cfg(test)] secret_hygiene::capture(&output);
        println!("{output}");
    }
}

async fn handle_request(request: Request) -> SidecarResult {
    let conformance = request.method == "s3ConformanceOp";
    let secrets = if conformance {
        secret_hygiene::collect_conformance(&request.params)
    } else {
        secret_hygiene::collect(&request.params)
    };
    secret_hygiene::SECRETS.scope(secrets, async {
        match dispatch_request(request).await {
            // Conformance already filters the observation using the signed
            // request's secrets as well as this scope. Preserve its field names.
            Ok(value) if conformance => Ok(value),
            Ok(value) => Ok(secret_hygiene::value(value)),
            Err(error) => Err(SidecarError::with_details(error.code, error.message, error.details)),
        }
    }).await
}

async fn dispatch_request(request: Request) -> SidecarResult {
    // SDK futures are large. Keep them behind a pointer at the dispatch
    // boundary so debug poll frames do not reserve space for every method.
    match request.method.as_str() {
        "health" => Ok(json!({
            "engine": "rust",
            "version": ENGINE_VERSION,
            "available": true,
            "methods": SUPPORTED_METHODS,
            "nativeSdk": "aws-sdk-rust",
            "endpointTypes": ["s3Compatible", "awsS3"],
        })),
        "getCapabilities" => Ok(json!({
            "items": [
                s3_conformance::capability(&request.params["profile"]),
                {"key": "bucket.lifecycle", "label": "Lifecycle policy CRUD", "state": "supported"},
                {"key": "bucket.policy", "label": "Bucket policy CRUD", "state": "supported"},
                {"key": "bucket.cors", "label": "Bucket CORS CRUD", "state": "supported"},
                {"key": "bucket.encryption", "label": "Bucket encryption", "state": "supported"},
                {"key": "bucket.tagging", "label": "Bucket tagging", "state": "supported"},
                {"key": "bucket.versioning", "label": "Bucket versioning", "state": "supported"},
                {"key":"object.clientEncryption", "label":"Client-side encryption", "state":"supported", "formats":["age-v1"]},
                {"key":"object.encryption.sse-s3", "label":"sse-s3", "state":"supported"},
                {"key":"object.encryption.sse-kms", "label":"sse-kms", "state":"supported"},
                {"key":"object.encryption.dsse-kms", "label":"dsse-kms", "state":"supported"},
                {"key":"object.encryption.sse-c", "label":"sse-c", "state":"supported"},
                {"key":"object.encryption.azure-scope", "label":"azure-scope", "state":"unsupported", "reason":"The Rust engine does not support Azure Blob profiles."},
                {"key":"object.encryption.azure-cpk", "label":"azure-cpk", "state":"unsupported", "reason":"The Rust engine does not support Azure Blob profiles."},
                {"key": "object.copy_move", "label": "Copy, move, rename", "state": "supported"},
                {"key": "object.resumable", "label": "Resumable transfer jobs", "state": "unknown", "reason": "Desktop host currently uses one request per sidecar process."},
                {"key": "tools.bulk-delete", "label": "Delete-all maintenance tool", "state": "supported"},
                {"key": "benchmark", "label": "Integrated benchmark mode", "state": "supported"},
            ]
        })),
        "s3ConformanceOp" => Box::pin(s3_conformance::run(request.params)).await,
        "testProfile" => {
            Box::pin(test_profile(
                request
                    .params
                    .get("profile")
                    .cloned()
                    .unwrap_or(Value::Null),
            ))
            .await
        }
        "listBuckets" => {
            Box::pin(list_buckets(
                request
                    .params
                    .get("profile")
                    .cloned()
                    .unwrap_or(Value::Null),
            ))
            .await
        }
        "createBucket" => Box::pin(create_bucket(request.params)).await,
        "deleteBucket" => Box::pin(delete_bucket(request.params)).await,
        "setBucketVersioning" => Box::pin(set_bucket_versioning(request.params)).await,
        "putBucketLifecycle" => Box::pin(put_bucket_lifecycle(request.params)).await,
        "deleteBucketLifecycle" => Box::pin(delete_bucket_lifecycle(request.params)).await,
        "putBucketPolicy" => Box::pin(put_bucket_policy(request.params)).await,
        "deleteBucketPolicy" => Box::pin(delete_bucket_policy(request.params)).await,
        "putBucketCors" => Box::pin(put_bucket_cors(request.params)).await,
        "deleteBucketCors" => Box::pin(delete_bucket_cors(request.params)).await,
        "putBucketEncryption" => Box::pin(put_bucket_encryption(request.params)).await,
        "deleteBucketEncryption" => Box::pin(delete_bucket_encryption(request.params)).await,
        "putBucketTagging" => Box::pin(put_bucket_tagging(request.params)).await,
        "deleteBucketTagging" => Box::pin(delete_bucket_tagging(request.params)).await,
        "listObjects" => Box::pin(list_objects(request.params)).await,
        "getBucketAdminState" => Box::pin(get_bucket_admin_state(request.params)).await,
        "listObjectVersions" => Box::pin(list_object_versions(request.params)).await,
        "getObjectDetails" => Box::pin(get_object_details(request.params)).await,
        "createFolder" => Box::pin(create_folder(request.params)).await,
        "copyObject" => Box::pin(copy_object(request.params)).await,
        "moveObject" => Box::pin(move_object(request.params)).await,
        "deleteObjects" => Box::pin(delete_objects(request.params)).await,
        "deleteObjectVersions" => Box::pin(delete_object_versions(request.params)).await,
        "startUpload" => Box::pin(start_upload(request.params)).await,
        "startDownload" => Box::pin(start_download(request.params)).await,
        "pauseTransfer" | "resumeTransfer" | "cancelTransfer" => Err(SidecarError::new(
            "unsupported_feature",
            "Interactive transfer control is unavailable in the sequential Rust engine.",
        )),
        "generatePresignedUrl" => Box::pin(generate_presigned_url(request.params)).await,
        "runPutTestData" => Box::pin(run_put_test_data(request.params)).await,
        "runDeleteAll" => Box::pin(run_delete_all(request.params)).await,
        "cancelToolExecution" => Ok(cancel_tool_execution(&request.params)),
        "startBenchmark" => Box::pin(start_benchmark(request.params)).await,
        "getBenchmarkStatus" => Box::pin(get_benchmark_status(request.params)).await,
        "pauseBenchmark" => Box::pin(pause_benchmark(request.params)).await,
        "resumeBenchmark" => Box::pin(resume_benchmark(request.params)).await,
        "stopBenchmark" => Box::pin(stop_benchmark(request.params)).await,
        "exportBenchmarkResults" => Box::pin(export_benchmark_results(request.params)).await,
        _ => Err(SidecarError::new(
            "unsupported_feature",
            format!(
                "Method {} is not implemented in the Rust engine.",
                request.method
            ),
        )),
    }
}

async fn test_profile(profile_value: Value) -> SidecarResult {
    let profile = parse_profile(&profile_value)?;
    let client = build_client(&profile).await?;
    if let Some(bucket) = profile_value["knownBucket"]
        .as_str()
        .filter(|v| !v.trim().is_empty())
    {
        client
            .list_objects_v2()
            .bucket(bucket.trim())
            .max_keys(1)
            .send()
            .await
            .map_err(map_sdk_error)?;
        return Ok(json!({"ok":true,"bucketCount":1,"endpoint":profile.endpoint_url}));
    }
    let output = client.list_buckets().send().await.map_err(map_sdk_error)?;
    let endpoint = url::Url::parse(&profile.endpoint_url)
        .ok()
        .and_then(|value| value.host_str().map(str::to_owned))
        .unwrap_or_else(|| profile.endpoint_url.clone());
    Ok(json!({
        "ok": true,
        "bucketCount": output.buckets().len(),
        "endpoint": endpoint,
    }))
}

async fn list_buckets(profile_value: Value) -> SidecarResult {
    let profile = parse_profile(&profile_value)?;
    let client = build_client(&profile).await?;
    if let Some(bucket) = profile_value["knownBucket"]
        .as_str()
        .filter(|v| !v.trim().is_empty())
    {
        return Ok(
            json!({"items":[{"name":bucket.trim(),"region":profile.region,"objectCountHint":0,"versioningEnabled":false,"createdAt":now_iso()}]}),
        );
    }
    let mut items = Vec::new();
    let mut token: Option<String> = None;
    let mut seen = std::collections::HashSet::new();
    loop {
        let output = client
            .list_buckets()
            .max_buckets(1000)
            .set_continuation_token(token.clone())
            .send()
            .await
            .map_err(map_sdk_error)?;
        items.extend(output.buckets().iter().map(|bucket|json!({"name":bucket.name().unwrap_or_default(),"region":profile.region,"objectCountHint":0,"versioningEnabled":false,"createdAt":serialize_aws_datetime(bucket.creation_date())})));
        token = output
            .continuation_token()
            .filter(|v| !v.is_empty())
            .map(str::to_owned);
        match &token {
            None => break,
            Some(t) => {
                if !seen.insert(t.clone()) {
                    return Err(SidecarError::new(
                        "invalid_response",
                        "Bucket listing repeated a continuation token.",
                    ));
                }
            }
        }
    }
    Ok(json!({ "items": items }))
}

async fn create_bucket(params: Value) -> SidecarResult {
    let profile = parse_profile(&params["profile"])?;
    let bucket_name = required_text(&params, "bucketName", "Bucket name is required.")?;
    let enable_versioning = params["enableVersioning"].as_bool().unwrap_or(false);
    let enable_object_lock = params["enableObjectLock"].as_bool().unwrap_or(false);
    let client = build_client(&profile).await?;

    let mut request = client.create_bucket().bucket(bucket_name.clone());
    if profile.region != "us-east-1" {
        request = request.create_bucket_configuration(
            CreateBucketConfiguration::builder()
                .location_constraint(BucketLocationConstraint::from(profile.region.as_str()))
                .build(),
        );
    }
    if enable_object_lock {
        request = request.object_lock_enabled_for_bucket(enable_object_lock);
    }
    request.send().await.map_err(map_sdk_error)?;

    if enable_versioning {
        client
            .put_bucket_versioning()
            .bucket(bucket_name.clone())
            .versioning_configuration(
                VersioningConfiguration::builder()
                    .status(BucketVersioningStatus::Enabled)
                    .build(),
            )
            .send()
            .await
            .map_err(map_sdk_error)?;
    }

    Ok(json!({
        "name": bucket_name,
        "region": profile.region,
        "objectCountHint": 0,
        "versioningEnabled": enable_versioning,
        "createdAt": now_iso(),
    }))
}

async fn delete_bucket(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    client
        .delete_bucket()
        .bucket(bucket_name.clone())
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({"deleted": true, "bucketName": bucket_name}))
}

async fn set_bucket_versioning(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let enabled = params["enabled"].as_bool().unwrap_or(false);
    client
        .put_bucket_versioning()
        .bucket(bucket_name)
        .versioning_configuration(
            VersioningConfiguration::builder()
                .status(if enabled {
                    BucketVersioningStatus::Enabled
                } else {
                    BucketVersioningStatus::Suspended
                })
                .build(),
        )
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn put_bucket_lifecycle(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let lifecycle_json = required_text(
        &params,
        "lifecycleJson",
        "Bucket name and lifecycle JSON are required.",
    )?;
    let parsed: Value = serde_json::from_str(&lifecycle_json).map_err(|error| {
        SidecarError::with_details(
            "invalid_config",
            "Lifecycle JSON could not be parsed.",
            json!({"reason": error.to_string()}),
        )
    })?;
    if parsed.as_object().is_none_or(|m| {
        m.keys()
            .any(|k| !matches!(k.as_str(), "Rules" | "TransitionDefaultMinimumObjectSize"))
    }) {
        return Err(SidecarError::new(
            "unsupported_feature",
            "Unsupported lifecycle configuration field; configuration was not changed.",
        ));
    }
    let rules = parse_lifecycle_rules(parsed.get("Rules").unwrap_or(&Value::Null))?;
    let config = BucketLifecycleConfiguration::builder()
        .set_rules(Some(rules))
        .build()
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    client
        .put_bucket_lifecycle_configuration()
        .bucket(bucket_name)
        .lifecycle_configuration(config)
        .set_transition_default_minimum_object_size(
            parsed["TransitionDefaultMinimumObjectSize"]
                .as_str()
                .map(aws_sdk_s3::types::TransitionDefaultMinimumObjectSize::from),
        )
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn delete_bucket_lifecycle(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    client
        .delete_bucket_lifecycle()
        .bucket(bucket_name)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn put_bucket_policy(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let policy_json = required_text(
        &params,
        "policyJson",
        "Bucket name and policy JSON are required.",
    )?;
    client
        .put_bucket_policy()
        .bucket(bucket_name)
        .policy(policy_json)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn delete_bucket_policy(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    client
        .delete_bucket_policy()
        .bucket(bucket_name)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn put_bucket_cors(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let cors_json = required_text(
        &params,
        "corsJson",
        "Bucket name and CORS JSON are required.",
    )?;
    let parsed: Value = serde_json::from_str(&cors_json).map_err(|error| {
        SidecarError::with_details(
            "invalid_config",
            "CORS JSON could not be parsed.",
            json!({"reason": error.to_string()}),
        )
    })?;
    let rules = parse_cors_rules(&parsed)?;
    client
        .put_bucket_cors()
        .bucket(bucket_name)
        .cors_configuration(
            CorsConfiguration::builder()
                .set_cors_rules(Some(rules))
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?,
        )
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn delete_bucket_cors(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    client
        .delete_bucket_cors()
        .bucket(bucket_name)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn put_bucket_encryption(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let encryption_json = required_text(
        &params,
        "encryptionJson",
        "Bucket name and encryption JSON are required.",
    )?;
    let parsed: Value = serde_json::from_str(&encryption_json).map_err(|error| {
        SidecarError::with_details(
            "invalid_config",
            "Encryption JSON could not be parsed.",
            json!({"reason": error.to_string()}),
        )
    })?;
    let config = parse_encryption_configuration(&parsed)?;
    client
        .put_bucket_encryption()
        .bucket(bucket_name)
        .server_side_encryption_configuration(config)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn delete_bucket_encryption(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    client
        .delete_bucket_encryption()
        .bucket(bucket_name)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn put_bucket_tagging(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let tags = params
        .get("tags")
        .and_then(Value::as_object)
        .ok_or_else(|| SidecarError::new("invalid_config", "Bucket name and tags are required."))?;
    let tag_set: Vec<Tag> = tags
        .iter()
        .map(|(key, value)| {
            Tag::builder()
                .key(key)
                .value(value.as_str().unwrap_or_default())
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let tagging = Tagging::builder()
        .set_tag_set(Some(tag_set))
        .build()
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    client
        .put_bucket_tagging()
        .bucket(bucket_name)
        .tagging(tagging)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn delete_bucket_tagging(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    client
        .delete_bucket_tagging()
        .bucket(bucket_name)
        .send()
        .await
        .map_err(map_sdk_error)?;
    get_bucket_admin_state(params).await
}

async fn list_objects(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let prefix = params["prefix"].as_str().unwrap_or_default();
    let flat = params["flat"].as_bool().unwrap_or(false);
    let continuation = params["cursor"]["value"]
        .as_str()
        .filter(|value| !value.is_empty());
    let mut request = client
        .list_objects_v2()
        .bucket(bucket_name.clone())
        .prefix(prefix)
        .max_keys(1000)
        .encoding_type(aws_sdk_s3::types::EncodingType::Url);
    if !flat {
        request = request.delimiter("/");
    }
    if let Some(token) = continuation {
        request = request.continuation_token(token);
    }
    let output = request.send().await.map_err(map_sdk_error)?;

    let mut items: Vec<Value> = Vec::new();
    for common_prefix in output.common_prefixes() {
        let folder_prefix = decode_listing_key(common_prefix.prefix(), output.encoding_type())?;
        let folder_name = folder_prefix
            .strip_prefix(prefix)
            .unwrap_or(&folder_prefix)
            .to_string();
        items.push(json!({
            "key": folder_prefix,
            "name": if folder_name.is_empty() { folder_prefix.as_str() } else { folder_name.as_str() },
            "size": 0,
            "storageClass": "FOLDER",
            "modifiedAt": now_iso(),
            "isFolder": true,
            "etag": Value::Null,
            "metadataCount": 0
        }));
    }
    for object in output.contents() {
        let key = decode_listing_key(object.key(), output.encoding_type())?;
        if !flat && key == prefix {
            continue;
        }
        let name = key.strip_prefix(prefix).unwrap_or(&key);
        items.push(json!({
            "key": key,
            "name": if name.is_empty() { key.as_str() } else { name },
            "size": object.size().unwrap_or_default(),
            "storageClass": object.storage_class().map(|v| v.as_str()).unwrap_or("STANDARD"),
            "modifiedAt": serialize_aws_datetime(object.last_modified()),
            "isFolder": false,
            "etag": trim_quotes_option(object.e_tag()),
            "metadataCount": 0
        }));
    }
    items.sort_by(|left, right| {
        let lf = left["isFolder"].as_bool().unwrap_or(false);
        let rf = right["isFolder"].as_bool().unwrap_or(false);
        if lf != rf {
            return rf.cmp(&lf);
        }
        left["key"]
            .as_str()
            .unwrap_or_default()
            .to_lowercase()
            .cmp(&right["key"].as_str().unwrap_or_default().to_lowercase())
    });

    Ok(json!({
        "items": items,
        "nextCursor": {
            "value": output.next_continuation_token(),
            "hasMore": output.is_truncated().unwrap_or(false)
        }
    }))
}

async fn get_bucket_admin_state(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let mut api_calls: Vec<Value> = Vec::new();

    let versioning = Box::pin(optional_api(
        &mut api_calls,
        "GetBucketVersioning",
        client.get_bucket_versioning().bucket(&bucket_name).send(),
    ))
    .await?;
    let encryption = Box::pin(optional_api(
        &mut api_calls,
        "GetBucketEncryption",
        client.get_bucket_encryption().bucket(&bucket_name).send(),
    ))
    .await?;
    let lifecycle = Box::pin(optional_api(
        &mut api_calls,
        "GetBucketLifecycleConfiguration",
        client
            .get_bucket_lifecycle_configuration()
            .bucket(&bucket_name)
            .send(),
    ))
    .await?;
    let policy = Box::pin(optional_api(
        &mut api_calls,
        "GetBucketPolicy",
        client.get_bucket_policy().bucket(&bucket_name).send(),
    ))
    .await?;
    let cors = Box::pin(optional_api(
        &mut api_calls,
        "GetBucketCors",
        client.get_bucket_cors().bucket(&bucket_name).send(),
    ))
    .await?;
    let tagging = Box::pin(optional_api(
        &mut api_calls,
        "GetBucketTagging",
        client.get_bucket_tagging().bucket(&bucket_name).send(),
    ))
    .await?;
    let object_lock = Box::pin(optional_api(
        &mut api_calls,
        "GetObjectLockConfiguration",
        client
            .get_object_lock_configuration()
            .bucket(&bucket_name)
            .send(),
    ))
    .await?;

    let lifecycle_rules: Vec<Value> = lifecycle
        .as_ref()
        .map(|output| output.rules().iter().map(lifecycle_rule_summary).collect())
        .unwrap_or_default();
    let lifecycle_json = lifecycle
        .as_ref()
        .map(|output| serde_json::to_string_pretty(&lifecycle::without_nulls(json!({"Rules": output.rules().iter().map(lifecycle_rule_raw).collect::<Vec<_>>(), "TransitionDefaultMinimumObjectSize": output.transition_default_minimum_object_size().map(|v| v.as_str()) }))).unwrap_or_else(|_| "{\n  \"Rules\": []\n}".to_string()))
        .unwrap_or_else(|| "{\n  \"Rules\": []\n}".to_string());

    let encryption_enabled = encryption
        .as_ref()
        .and_then(|output| output.server_side_encryption_configuration())
        .map(|config| !config.rules().is_empty())
        .unwrap_or(false);
    let encryption_json = encryption
        .as_ref()
        .and_then(|output| output.server_side_encryption_configuration())
        .map(|config| {
            serde_json::to_string_pretty(&encryption_raw(config))
                .unwrap_or_else(|_| "{}".to_string())
        })
        .unwrap_or_else(|| "{}".to_string());
    let encryption_summary = encryption
        .as_ref()
        .and_then(|output| output.server_side_encryption_configuration())
        .and_then(|config| config.rules().first())
        .and_then(|rule| rule.apply_server_side_encryption_by_default())
        .map(|value| {
            let algo = value.sse_algorithm().as_str();
            match value.kms_master_key_id() {
                Some(kms) if !kms.is_empty() => format!("{algo} ({kms})"),
                _ => algo.to_string(),
            }
        })
        .unwrap_or_else(|| "Not configured".to_string());

    let tags: Map<String, Value> = tagging
        .as_ref()
        .map(|output| {
            output
                .tag_set()
                .iter()
                .map(|tag| {
                    (
                        tag.key().to_string(),
                        Value::String(tag.value().to_string()),
                    )
                })
                .collect()
        })
        .unwrap_or_default();

    let (
        object_lock_enabled,
        object_lock_mode,
        object_lock_retention_value,
        object_lock_retention_unit,
    ) = if let Some(output) = object_lock {
        if let Some(configuration) = output.object_lock_configuration() {
            if let Some(rule) = configuration.rule() {
                if let Some(retention) = rule.default_retention() {
                    let retention_value = retention
                        .days()
                        .map(Value::from)
                        .or_else(|| retention.years().map(Value::from))
                        .unwrap_or(Value::Null);
                    (
                        true,
                        retention
                            .mode()
                            .map(|value| Value::String(value.as_str().to_string()))
                            .unwrap_or(Value::Null),
                        retention_value,
                        if retention.days().is_some() {
                            json!("days")
                        } else if retention.years().is_some() {
                            json!("years")
                        } else {
                            Value::Null
                        },
                    )
                } else {
                    (true, Value::Null, Value::Null, Value::Null)
                }
            } else {
                (true, Value::Null, Value::Null, Value::Null)
            }
        } else {
            (false, Value::Null, Value::Null, Value::Null)
        }
    } else {
        (false, Value::Null, Value::Null, Value::Null)
    };

    Ok(json!({
        "bucketName": bucket_name,
        "versioningEnabled": matches!(versioning.as_ref().and_then(|v|v.status()), Some(BucketVersioningStatus::Enabled)),
        "versioningStatus": versioning.as_ref().map(|v|v.status().map(|s|s.as_str()).unwrap_or("never-enabled")).unwrap_or("unknown"),
        "objectLockEnabled": object_lock_enabled,
        "lifecycleEnabled": !lifecycle_rules.is_empty(),
        "policyAttached": policy.as_ref().and_then(|v| v.policy()).map(|v| !v.is_empty()).unwrap_or(false),
        "corsEnabled": cors.as_ref().map(|value| !value.cors_rules().is_empty()).unwrap_or(false),
        "encryptionEnabled": encryption_enabled,
        "encryptionSummary": encryption_summary,
        "objectLockMode": object_lock_mode,
        "objectLockRetentionDays": if object_lock_retention_unit == "days" { object_lock_retention_value.clone() } else { Value::Null },
        "objectLockRetentionYears": if object_lock_retention_unit == "years" { object_lock_retention_value.clone() } else { Value::Null },
        "objectLockRetentionValue": object_lock_retention_value,
        "objectLockRetentionUnit": object_lock_retention_unit,
        "tags": tags,
        "lifecycleRules": lifecycle_rules,
        "lifecycleJson": lifecycle_json,
        "policyJson": policy.and_then(|value| value.policy().map(str::to_owned)).unwrap_or_else(|| "{}".to_string()),
        "corsJson": serde_json::to_string_pretty(&cors.as_ref().map(|value| value.cors_rules().iter().map(cors_rule_raw).collect::<Vec<_>>()).unwrap_or_default()).unwrap_or_else(|_| "[]".to_string()),
        "encryptionJson": encryption_json,
        "sections": section_statuses(&api_calls),
        "versioningState": versioning.as_ref().map(|v|v.status().map(|s|s.as_str()).unwrap_or("never-enabled")).unwrap_or("unknown"),
        "apiCalls": api_calls,
    }))
}

async fn list_object_versions(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let key = params["key"].as_str().unwrap_or_default();
    let filter_value = params["options"]["filterValue"]
        .as_str()
        .unwrap_or_default();
    let filter_mode = params["options"]["filterMode"].as_str().unwrap_or("prefix");
    let effective_prefix = if key.is_empty() {
        if filter_mode == "prefix" {
            filter_value
        } else {
            ""
        }
    } else {
        key
    };
    let cursor = params["cursor"]["value"].as_str().unwrap_or("");
    let marker: Value =
        serde_json::from_str(cursor).unwrap_or_else(|_| json!({"keyMarker":cursor}));
    let output = client
        .list_object_versions()
        .bucket(bucket_name)
        .prefix(effective_prefix)
        .max_keys(1000)
        .encoding_type(aws_sdk_s3::types::EncodingType::Url)
        .set_key_marker(
            marker["keyMarker"]
                .as_str()
                .filter(|v| !v.is_empty())
                .map(str::to_owned),
        )
        .set_version_id_marker(
            marker["versionIdMarker"]
                .as_str()
                .filter(|v| !v.is_empty())
                .map(str::to_owned),
        )
        .send()
        .await
        .map_err(map_sdk_error)?;

    let mut items = Vec::new();
    for version in output.versions() {
        let version_key = decode_listing_key(version.key(), output.encoding_type())?;
        if !key.is_empty() && version_key != key {
            continue;
        }
        items.push(json!({
            "key": version_key,
            "versionId": version.version_id().unwrap_or_default(),
            "modifiedAt": serialize_aws_datetime(version.last_modified()),
            "latest": version.is_latest().unwrap_or(false),
            "deleteMarker": false,
            "size": version.size().unwrap_or_default(),
            "storageClass": version.storage_class().map(|value| value.as_str()).unwrap_or("STANDARD"),
        }));
    }
    for marker in output.delete_markers() {
        let marker_key = decode_listing_key(marker.key(), output.encoding_type())?;
        if !key.is_empty() && marker_key != key {
            continue;
        }
        items.push(json!({
            "key": marker_key,
            "versionId": marker.version_id().unwrap_or_default(),
            "modifiedAt": serialize_aws_datetime(marker.last_modified()),
            "latest": marker.is_latest().unwrap_or(false),
            "deleteMarker": true,
            "size": 0,
            "storageClass": "DELETE_MARKER",
        }));
    }
    items.sort_by(|left, right| {
        right["modifiedAt"]
            .as_str()
            .cmp(&left["modifiedAt"].as_str())
    });
    let delete_marker_count = items
        .iter()
        .filter(|value| value["deleteMarker"].as_bool().unwrap_or(false))
        .count();
    Ok(json!({
        "items": items,
        "cursor": {"value": if output.is_truncated().unwrap_or(false) {Some(json!({"keyMarker":decode_listing_key(output.next_key_marker(), output.encoding_type())?,"versionIdMarker":output.next_version_id_marker()}).to_string())} else {None}, "hasMore": output.is_truncated().unwrap_or(false)},
        "totalCount": items.len(),
        "versionCount": items.len() - delete_marker_count,
        "deleteMarkerCount": delete_marker_count,
    }))
}

async fn get_object_details(params: Value) -> SidecarResult {
    let encryption = Encryption::parse(&params["encryption"], &params["profile"], false)?;
    let (profile, bucket_name, client) = bucket_context(&params).await?;
    let key = required_text(
        &params,
        "key",
        "Bucket name and object key are required for object inspection.",
    )?;
    let mut api_calls = Vec::new();
    let mut debug_events = vec![json!({
        "timestamp": now_iso(),
        "level": "DEBUG",
        "message": format!("Fetching object diagnostics for {bucket_name}/{key}."),
    })];

    let head = record_api_with(
        &mut api_calls,
        "HeadObject",
        encryption_customer!(client
            .head_object()
            .bucket(&bucket_name)
            .key(&key)
            .set_version_id(params["versionId"].as_str().map(str::to_owned)), &encryption)
        .send(),
        |error| object_encryption::read_error(error, encryption.customer()),
    )
    .await?;
    let tagging = optional_api(
        &mut api_calls,
        "GetObjectTagging",
        client
            .get_object_tagging()
            .bucket(&bucket_name)
            .key(&key)
            .set_version_id(params["versionId"].as_str().map(str::to_owned))
            .send(),
    )
    .await?;

    let metadata: Map<String, Value> = head
        .metadata()
        .into_iter()
        .flat_map(|items| items.iter())
        .map(|(key, value)| (key.to_string(), Value::String(value.to_string())))
        .collect();
    let mut headers = Map::new();
    if let Some(etag) = head
        .e_tag()
        .and_then(|value| trim_quotes_option(Some(value)))
    {
        headers.insert("ETag".to_string(), Value::String(etag));
    }
    headers.insert(
        "Content-Length".to_string(),
        Value::String(head.content_length().unwrap_or_default().to_string()),
    );
    if let Some(content_type) = head.content_type() {
        if !content_type.is_empty() {
            headers.insert(
                "Content-Type".to_string(),
                Value::String(content_type.to_string()),
            );
        }
    }
    headers.insert(
        "Last-Modified".to_string(),
        Value::String(serialize_aws_datetime(head.last_modified())),
    );
    if let Some(storage_class) = head.storage_class() {
        headers.insert(
            "Storage-Class".to_string(),
            Value::String(storage_class.as_str().to_string()),
        );
    }
    if let Some(cache_control) = head.cache_control() {
        if !cache_control.is_empty() {
            headers.insert(
                "Cache-Control".to_string(),
                Value::String(cache_control.to_string()),
            );
        }
    }

    let tags: Map<String, Value> = tagging
        .as_ref()
        .map(|output| {
            output
                .tag_set()
                .iter()
                .map(|tag| {
                    (
                        tag.key().to_string(),
                        Value::String(tag.value().to_string()),
                    )
                })
                .collect()
        })
        .unwrap_or_default();

    debug_events.push(json!({
        "timestamp": now_iso(),
        "level": "INFO",
        "message": format!("Loaded metadata and {} tag(s) for {key}.", tags.len()),
    }));

    let mut result = json!({
        "key": key,
        "metadata": metadata,
        "headers": headers,
        "tags": tags,
        "debugEvents": debug_events,
        "sections": section_statuses(&api_calls),
        "apiCalls": api_calls,
        "debugLogExcerpt": [
            format!("Resolved endpoint {}.", profile.endpoint_url),
            format!("Completed HEAD and tagging diagnostics for {bucket_name}/{key}.")
        ],
        "rawDiagnostics": {
            "bucketName": bucket_name,
            "engineState": "healthy"
        }
    });
    if let Some(encryption) = object_encryption::reported(&head) { result["encryption"] = encryption; }
    Ok(result)
}

async fn create_folder(params: Value) -> SidecarResult {
    let encryption = Encryption::parse(&params["encryption"], &params["profile"], false)?;
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let mut key = required_text(
        &params,
        "key",
        "Bucket name and key are required to create a folder.",
    )?;
    if !key.ends_with('/') {
        key.push('/');
    }
    encryption_write!(client
        .put_object()
        .bucket(bucket_name)
        .key(&key)
        .body(ByteStream::from(Vec::<u8>::new())), &encryption)
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({"created": true, "key": key}))
}

async fn copy_object(params: Value) -> SidecarResult {
    server_copy::run(params).await
}

async fn move_object(params: Value) -> SidecarResult {
    if params["sourceBucketName"] == params["destinationBucketName"]
        && params["sourceKey"] == params["destinationKey"]
    {
        return Err(SidecarError::new(
            "invalid_config",
            "A move requires different source and destination keys or buckets.",
        ));
    }
    let mut result = copy_object(params.clone()).await?;
    let version = params["sourceVersionId"].as_str().or_else(|| params["versionId"].as_str()).map(str::to_owned);
    if version.is_none() && params["profile"]["endpointType"] != "awsS3" {
        result["successCount"] = json!(0);
        result["failureCount"] = json!(1);
        result["copyCompleted"] = json!(true);
        result["sourceRetained"] = json!(true);
        result["failures"] = json!([{"target":params["sourceKey"], "code":"source_delete_unsupported", "message":"Copy completed. Source retained because this endpoint has no verified conditional-delete capability."}]);
        return Ok(result);
    }
    let profile = parse_profile(&params["profile"])?;
    let client = build_client(&profile).await?;
    let deleted = client
        .delete_object()
        .bucket(required_text(
            &params,
            "sourceBucketName",
            "Source bucket required.",
        )?)
        .key(required_text(&params, "sourceKey", "Source key required.")?)
        .set_version_id(version.clone())
        .set_if_match(result["sourceETag"].as_str().map(str::to_owned))
        .send()
        .await
        .map_err(map_sdk_error);
    if let Err(error) = deleted {
        result["successCount"] = json!(0);
        result["failureCount"] = json!(1);
        result["copiedCount"] = json!(1);
        result["sourceRetained"] = json!(true);
        result["failures"] = json!([{"target":params["sourceKey"], "versionId":version, "code":"source_delete_failed", "message":format!("Copy completed; source deletion was not confirmed: {}", error.message)}]);
    }
    Ok(result)
}

async fn delete_objects(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let keys = string_array(params.get("keys").unwrap_or(&Value::Null));
    if keys.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Bucket name and keys are required.",
        ));
    }
    let objects: Vec<ObjectIdentifier> = keys
        .into_iter()
        .map(|key| {
            ObjectIdentifier::builder()
                .key(key)
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    delete_identifiers(&client, &bucket_name, objects).await
}

async fn delete_object_versions(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let versions = params
        .get("versions")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            SidecarError::new("invalid_config", "Bucket name and versions are required.")
        })?;
    let objects: Vec<ObjectIdentifier> = versions
        .iter()
        .map(|item| {
            let mut builder =
                ObjectIdentifier::builder().key(item["key"].as_str().unwrap_or_default());
            if let Some(version_id) = item["versionId"].as_str() {
                if !version_id.is_empty() {
                    builder = builder.version_id(version_id);
                }
            }
            builder
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    delete_identifiers(&client, &bucket_name, objects).await
}

async fn delete_identifiers(client: &Client, bucket: &str, objects: Vec<ObjectIdentifier>) -> SidecarResult {
    let mut completed = 0;
    let mut failures = Vec::new();
    for (index, batch) in objects.chunks(1000).enumerate() {
        let delete = Delete::builder().set_objects(Some(batch.to_vec())).quiet(false).build()
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        match client.delete_objects().bucket(bucket).delete(delete).send().await {
            Ok(output) => {
                completed += output.deleted().len();
                failures.extend(output.errors().iter().map(|item| json!({"target":item.key().unwrap_or_default(), "versionId":item.version_id(), "code":item.code().unwrap_or("unknown"), "message":item.message().unwrap_or("Unknown delete error.")})));
            }
            Err(error) => {
                for (offset, item) in objects[index*1000..].iter().enumerate() {
                    failures.push(json!({"target":item.key(), "versionId":item.version_id(),
                        "code":if offset < batch.len() {"unknown_outcome"} else {"not_attempted"},
                        "message":if offset < batch.len() {format!("Delete was not confirmed: {error}")} else {"Stopped after an unconfirmed delete batch.".to_string()}}));
                }
                break;
            }
        }
    }
    Ok(json!({"successCount":completed, "failureCount":failures.len(), "failures":failures}))
}

struct TransferProgress {
    job_id: String,
    label: String,
    direction: &'static str,
    total_bytes: u64,
    strategy_label: String,
    item_count: usize,
    part_size_bytes: Option<u64>,
    parts_total: Option<u64>,
    state: Mutex<TransferProgressState>,
    activity_interval: Duration,
}

const MAX_PART_OUTPUT_LINES: u64 = 64;

struct TransferProgressState {
    bytes_transferred: u64,
    parts_completed: u64,
    items_completed: usize,
    part_lines_recorded: u64,
    output_lines: Vec<String>,
    last_activity_emit: Instant,
    current_item: Option<String>,
}

impl TransferProgressState {
    fn push_part_line(&mut self, line: String) {
        if self.part_lines_recorded < MAX_PART_OUTPUT_LINES {
            self.output_lines.push(line);
        } else if self.part_lines_recorded == MAX_PART_OUTPUT_LINES {
            self.output_lines
                .push("… further part updates omitted.".to_string());
        }
        self.part_lines_recorded += 1;
    }
}

impl TransferProgress {
    // A liveness event is emitted only when real bytes advance. Stalled streams
    // remain subject to the host watchdog; counters commit only successful parts.
    fn note_activity(&self) {
        self.emit("running", None);
    }
    fn emit(&self, status: &str, current_item: Option<String>) {
        let (bytes_transferred, parts_completed, items_completed, output_lines, current_item) = {
            let mut state = self.state.lock().unwrap();
            if current_item.is_some() {
                state.current_item = current_item;
            }
            if status == "running" && state.last_activity_emit.elapsed() < self.activity_interval {
                return;
            }
            state.last_activity_emit = Instant::now();
            (
                state.bytes_transferred,
                state.parts_completed,
                state.items_completed,
                state.output_lines.clone(),
                state.current_item.clone(),
            )
        };
        emit_transfer_event(&transfer_job(
            self.job_id.clone(),
            self.label.clone(),
            self.direction,
            progress_fraction(bytes_transferred, self.total_bytes),
            status,
            bytes_transferred,
            self.total_bytes,
            Some(self.strategy_label.clone()),
            current_item,
            self.item_count,
            items_completed,
            self.part_size_bytes,
            if self.parts_total.is_some() {
                Some(parts_completed)
            } else {
                None
            },
            self.parts_total,
            true,
            false,
            true,
            output_lines,
        ));
    }
}

fn transfer_concurrency(profile: &Profile) -> usize {
    profile.max_pool_connections.clamp(1, 8)
}

// Bound file-reader chunks to 256 KiB instead of the SDK's 4 KiB default.
// Multipart workers stream independently (at most eight); no whole part is buffered.
const UPLOAD_FILE_BUFFER_BYTES: usize = 256 * 1024;

struct TransferBody {
    body: aws_smithy_types::body::SdkBody,
    progress: Arc<TransferProgress>,
}
impl http_body::Body for TransferBody {
    type Data = Bytes;
    type Error = BoxError;
    fn poll_frame(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<http_body::Frame<Bytes>, BoxError>>> {
        let this = self.get_mut();
        let result = std::pin::Pin::new(&mut this.body).poll_frame(cx);
        if let std::task::Poll::Ready(Some(Ok(frame))) = &result {
            if frame.data_ref().is_some_and(|bytes| !bytes.is_empty()) {
                this.progress.note_activity();
            }
        }
        result
    }
    fn is_end_stream(&self) -> bool {
        http_body::Body::is_end_stream(&self.body)
    }
    fn size_hint(&self) -> http_body::SizeHint {
        http_body::Body::size_hint(&self.body)
    }
}
fn with_transfer_activity(body: ByteStream, progress: &Arc<TransferProgress>) -> ByteStream {
    let progress = progress.clone();
    body.map(move |body| {
        aws_smithy_types::body::SdkBody::from_body_1_x(TransferBody {
            body,
            progress: progress.clone(),
        })
    })
}

async fn upload_file_multipart(
    client: &Client,
    bucket_name: &str,
    key: &str,
    path: &Path,
    file_size: u64,
    chunk_bytes: u64,
    concurrency: usize,
    progress: &Arc<TransferProgress>,
    file_name: &str,
    encryption: &Encryption,
    client_encryption: Option<&ClientEncryption>,
    source_snapshot: &SourceSnapshot,
) -> Result<(), SidecarError> {
    let snapshot = if client_encryption.is_some() {
        source_snapshot.check(path)?;
        source_snapshot.clone()
    } else {
        SourceSnapshot::capture(path)?
    };
    let upload_id = encryption_write!(client
        .create_multipart_upload()
        .bucket(bucket_name)
        .key(key), &encryption)
        .send()
        .await
        .map_err(map_sdk_error)?
        .upload_id()
        .map(str::to_owned)
        .ok_or_else(|| {
            SidecarError::new(
                "engine_unavailable",
                "Multipart upload did not return an upload ID.",
            )
        })?;
    let part_count = file_size.div_ceil(chunk_bytes);
    let mut parts: Vec<(i32, Option<String>)> = Vec::with_capacity(part_count as usize);
    let result = run_bounded(
        part_count,
        concurrency,
        |index| {
            let part_number = (index + 1) as i32;
            let offset = index * chunk_bytes;
            let length = chunk_bytes.min(file_size - offset);
            let client = client.clone();
            let bucket_name = bucket_name.to_string();
            let key = key.to_string();
            let upload_id = upload_id.clone();
            let path = path.to_path_buf();
            let progress = Arc::clone(progress);
            let file_name = file_name.to_string();
            let snapshot = snapshot.clone();
            let encryption = encryption.clone();
            let client_encryption = client_encryption.cloned();
            async move {
                snapshot.check(&path)?;
                let body = if let Some(config) = &client_encryption {
                    config.body(&path, &snapshot, config.plaintext_length(file_size)?, offset, length)
                } else {
                    ByteStream::read_from()
                        .path(&path)
                        .offset(offset)
                        .length(aws_sdk_s3::primitives::Length::Exact(length))
                        .buffer_size(UPLOAD_FILE_BUFFER_BYTES)
                        .build()
                        .await
                        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?
                };
                let output = encryption_customer!(client
                    .upload_part()
                    .bucket(&bucket_name)
                    .key(&key)
                    .upload_id(&upload_id)
                    .part_number(part_number)
                    .body(with_transfer_activity(body, &progress)), &encryption)
                    .send()
                    .await
                    .map_err(map_sdk_error)?;
                if client_encryption.is_some() {
                    snapshot.check(&path)?;
                }
                {
                    let mut state = progress.state.lock().unwrap();
                    state.bytes_transferred += length;
                    state.parts_completed += 1;
                    state.push_part_line(format!("Uploaded part {part_number} for {file_name}."));
                }
                progress.emit("running", Some(file_name));
                Ok::<(i32, Option<String>), SidecarError>((
                    part_number,
                    output.e_tag().map(str::to_owned),
                ))
            }
        },
        |part| parts.push(part),
    )
    .await
    .and_then(|()| snapshot.check(path));
    let complete_result = match result {
        Err(error) => Err(error),
        Ok(()) => {
            parts.sort_by_key(|(part_number, _)| *part_number);
            let completed_parts = parts
                .into_iter()
                .map(|(part_number, e_tag)| {
                    CompletedPart::builder()
                        .set_e_tag(e_tag)
                        .part_number(part_number)
                        .build()
                })
                .collect::<Vec<_>>();
            encryption_customer!(client
                .complete_multipart_upload()
                .bucket(bucket_name)
                .key(key)
                .upload_id(&upload_id)
                .multipart_upload(
                    CompletedMultipartUpload::builder()
                        .set_parts(Some(completed_parts))
                        .build(),
                ), &encryption)
                .send()
                .await
                .map(|_| ())
                .map_err(map_sdk_error)
        }
    };
    if complete_result.is_err() {
        let _ = client
            .abort_multipart_upload()
            .bucket(bucket_name)
            .key(key)
            .upload_id(&upload_id)
            .send()
            .await;
    }
    complete_result
}

fn upload_part_size_bytes(value: &Value) -> u64 {
    let mib = match (value.as_i64(), value.as_u64()) {
        (Some(size), _) => size.clamp(5, 5120) as u64,
        (_, Some(size)) => size.clamp(5, 5120),
        _ => 8,
    };
    mib * 1024 * 1024
}

fn validate_upload_size(size: u64, threshold: u64, chunk: u64) -> Result<(), SidecarError> {
    if size > 50000 * 1024_u64.pow(3) || (size >= threshold && size.div_ceil(chunk) > 10000) {
        return Err(SidecarError::new(
            "invalid_config",
            "Upload exceeds S3 object or 10,000-part limits; select a larger part size.",
        ));
    }
    Ok(())
}

async fn start_upload(params: Value) -> SidecarResult {
    let encryption = Encryption::parse(&params["encryption"], &params["profile"], false)?;
    let profile = parse_profile(&params["profile"])?;
    let bucket_name = required_text(&params, "bucketName", "Bucket name is required.")?;
    let prefix = params["prefix"].as_str().unwrap_or_default();
    let file_paths = string_array(params.get("filePaths").unwrap_or(&Value::Null));
    let object_key_by_path = string_map(params.get("objectKeyByPath").unwrap_or(&Value::Null));
    let client_encryption = ClientEncryption::parse(&params["clientEncryption"], true, file_paths.len())?;
    if file_paths.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Bucket name and file paths are required.",
        ));
    }
    let multipart_threshold_bytes = params["multipartThresholdMiB"]
        .as_u64()
        .unwrap_or(32)
        .max(1)
        * 1024
        * 1024;
    let multipart_chunk_bytes = upload_part_size_bytes(&params["multipartChunkMiB"]);
    let paths = file_paths.iter().map(PathBuf::from).collect::<Vec<_>>();
    let mut total_bytes = 0_u64;
    let mut parts_total = 0_u64;
    let mut uses_multipart = false;
    let snapshots = paths
        .iter()
        .map(|path| SourceSnapshot::capture(path))
        .collect::<Result<Vec<_>, _>>()?;
    for path in &paths {
        let metadata = fs::metadata(path)
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        let size = match &client_encryption {
            Some(config) => config.object_length(metadata.len())?,
            None => metadata.len(),
        };
        validate_upload_size(
            size,
            multipart_threshold_bytes,
            multipart_chunk_bytes,
        )?;
        total_bytes += size;
        if size >= multipart_threshold_bytes {
            uses_multipart = true;
            parts_total += size.div_ceil(multipart_chunk_bytes);
        }
    }
    let client = build_client(&profile).await?;
    let concurrency = transfer_concurrency(&profile);
    let job_id = format!("upload-{}", short_uuid());
    let label = format!("Upload {} file(s) to {bucket_name}", paths.len());
    let strategy_label = transfer_strategy_label("upload", uses_multipart);
    let part_size_bytes = if parts_total > 0 {
        Some(multipart_chunk_bytes)
    } else {
        None
    };
    let part_total_value = if parts_total > 0 {
        Some(parts_total)
    } else {
        None
    };
    let progress = Arc::new(TransferProgress {
        job_id: job_id.clone(),
        label: label.clone(),
        direction: "upload",
        total_bytes,
        strategy_label: strategy_label.clone(),
        item_count: paths.len(),
        part_size_bytes,
        parts_total: part_total_value,
        activity_interval: Duration::from_millis(
            params["progressIntervalMs"]
                .as_u64()
                .unwrap_or(100)
                .clamp(50, 2000),
        ),
        state: Mutex::new(TransferProgressState {
            last_activity_emit: Instant::now(),
            current_item: None,
            bytes_transferred: 0,
            parts_completed: 0,
            items_completed: 0,
            part_lines_recorded: 0,
            output_lines: vec![format!(
                "Queued {} file(s) for upload to {bucket_name}.",
                paths.len()
            )],
        }),
    });
    progress.emit(
        "queued",
        paths
            .first()
            .and_then(|path| path.file_name())
            .and_then(|value| value.to_str())
            .map(str::to_owned),
    );
    for (path, snapshot) in paths.iter().zip(&snapshots) {
        snapshot.check(path)?;
        let default_name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        let target_name = object_key_by_path
            .get(&path.to_string_lossy().to_string())
            .map(|value| value.replace('\\', "/").trim_start_matches('/').to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| default_name.clone());
        let key = if prefix.is_empty() {
            target_name
        } else {
            format!("{prefix}{target_name}")
        };
        let file_name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        let file_size = fs::metadata(path)
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?
            .len();
        let plaintext_size = file_size;
        let file_size = match &client_encryption {
            Some(config) => config.object_length(plaintext_size)?,
            None => plaintext_size,
        };
        {
            let mut state = progress.state.lock().unwrap();
            state.output_lines.push(format!(
                "Uploading {file_name} ({file_size} bytes) to {key}."
            ));
        }
        if file_size >= multipart_threshold_bytes {
            upload_file_multipart(
                &client,
                &bucket_name,
                &key,
                path,
                file_size,
                multipart_chunk_bytes,
                concurrency,
                &progress,
                &file_name,
                &encryption,
                client_encryption.as_ref(),
                snapshot,
            )
            .await?;
        } else {
            let body = if let Some(config) = &client_encryption {
                config.body(path, snapshot, plaintext_size, 0, file_size)
            } else {
                ByteStream::read_from()
                    .path(path)
                    .buffer_size(UPLOAD_FILE_BUFFER_BYTES)
                    .build()
                    .await
                    .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?
            };
            let mut request = client.put_object().bucket(&bucket_name).key(&key)
                .body(with_transfer_activity(body, &progress));
            if client_encryption.is_some() {
                request = request.content_length(file_size as i64);
            }
            encryption_write!(request, &encryption)
                .send()
                .await
                .map_err(map_sdk_error)?;
            let mut state = progress.state.lock().unwrap();
            state.bytes_transferred += file_size;
        }
        snapshot.check(path)?;
        {
            let mut state = progress.state.lock().unwrap();
            state.items_completed += 1;
            state
                .output_lines
                .push(format!("Finished uploading {file_name}."));
        }
        progress.emit("running", Some(file_name));
    }
    let (bytes_transferred, items_completed, parts_completed, output_lines) = {
        let mut state = progress.state.lock().unwrap();
        state.output_lines.push(format!(
            "Uploaded {} file(s) into {bucket_name}.",
            paths.len()
        ));
        (
            state.bytes_transferred,
            state.items_completed,
            state.parts_completed,
            state.output_lines.clone(),
        )
    };
    Ok(transfer_job(
        job_id,
        label,
        "upload",
        1.0,
        "completed",
        bytes_transferred,
        total_bytes,
        Some(strategy_label),
        paths
            .last()
            .and_then(|path| path.file_name())
            .and_then(|value| value.to_str())
            .map(str::to_owned),
        paths.len(),
        items_completed,
        part_size_bytes,
        if part_total_value.is_some() {
            Some(parts_completed)
        } else {
            None
        },
        part_total_value,
        false,
        false,
        false,
        output_lines,
    ))
}

async fn download_object_ranged(
    client: &Client,
    validator: Option<String>,
    version_id: Option<String>,
    bucket_name: &str,
    key: &str,
    target: &Path,
    object_size: u64,
    chunk_bytes: u64,
    concurrency: usize,
    max_attempts: u32,
    progress: &Arc<TransferProgress>,
    encryption: &Encryption,
) -> Result<(), SidecarError> {
    {
        let file = tokio::fs::File::create(target)
            .await
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        file.set_len(object_size)
            .await
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    }
    let part_count = object_size.div_ceil(chunk_bytes);
    run_bounded(part_count, concurrency, |index| {
        let start = index * chunk_bytes;
        let end = (start + chunk_bytes - 1).min(object_size.saturating_sub(1));
        let client = client.clone();
        let encryption = encryption.clone();
        let validator = validator.clone();
        let version_id = version_id.clone();
        let bucket_name = bucket_name.to_string();
        let key = key.to_string();
        let target = target.to_path_buf();
        let progress = Arc::clone(progress);
        async move {
            let mut attempt = 0;
            let range_bytes = loop {
                let result: Result<u64, SidecarError> = async {
            let output = encryption_customer!(client
                .get_object()
                .bucket(&bucket_name)
                .key(&key)
                .range(format!("bytes={start}-{end}"))
                .set_if_match(validator.clone())
                .set_version_id(version_id.clone()), &encryption)
                .send()
                .await
                .map_err(|error| object_encryption::read_error(error, encryption.customer()))?;
            if validator.as_deref().is_some_and(|etag| output.e_tag() != Some(etag)) {
                return Err(SidecarError::new("object_conflict", "Download ETag mismatch; partial file discarded."));
            }
            if output.content_range() != Some(format!("bytes {start}-{end}/{object_size}").as_str()) {
                return Err(SidecarError::new("object_conflict", "Download range mismatch; partial file discarded."));
            }
            let mut file = tokio::fs::OpenOptions::new()
                .write(true)
                .open(&target)
                .await
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            file.seek(SeekFrom::Start(start))
                .await
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            let mut body = output.body;
            let mut range_bytes = 0_u64;
            while let Some(chunk) = body
                .try_next()
                .await
                .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?
            {
                if range_bytes + chunk.len() as u64 > end-start+1 { return Err(SidecarError::new("object_conflict", "Oversized range body.")); }
                file.write_all(&chunk)
                    .await
                    .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
                range_bytes += chunk.len() as u64;
                progress.note_activity();
            }
            file.flush()
                .await
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            let expected_bytes = end - start + 1;
            if range_bytes != expected_bytes {
                return Err(SidecarError::new(
                    "engine_unavailable",
                    format!(
                        "Ranged download for {key} bytes {start}-{end} returned {range_bytes} byte(s); expected {expected_bytes}."
                    ),
                ));
            }
                    Ok(range_bytes)
                }.await;
                match result {
                    Ok(bytes) => break bytes,
                    Err(error) if error.code == "engine_unavailable" && attempt < max_attempts.clamp(1, 10) - 1 => {
                        attempt += 1;
                        tokio::time::sleep(Duration::from_millis(100 << attempt.min(4))).await;
                    }
                    Err(error) => return Err(error),
                }
            };
            {
                let mut state = progress.state.lock().unwrap();
                state.bytes_transferred += range_bytes;
                state.parts_completed += 1;
                state.push_part_line(format!("Downloaded byte range {start}-{end} for {key}."));
            }
            progress.emit("running", Some(key));
            Ok::<(), SidecarError>(())
        }
    }, |()| {}).await
}

async fn start_download(params: Value) -> SidecarResult {
    let encryption = Encryption::parse(&params["encryption"], &params["profile"], false)?;
    let keys = string_array(params.get("keys").unwrap_or(&Value::Null));
    let client_encryption = ClientEncryption::parse(&params["clientEncryption"], false, keys.len())?;
    let (profile, bucket_name, client) = bucket_context(&params).await?;
    let destination_path = required_text(
        &params,
        "destinationPath",
        "Bucket, keys, and destination path are required.",
    )?;
    if keys.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Bucket, keys, and destination path are required.",
        ));
    }
    let multipart_threshold_bytes = params["multipartThresholdMiB"]
        .as_u64()
        .unwrap_or(32)
        .max(1)
        * 1024
        * 1024;
    let multipart_chunk_bytes =
        params["multipartChunkMiB"].as_u64().unwrap_or(8).max(1) * 1024 * 1024;
    let destination = PathBuf::from(&destination_path);
    fs::create_dir_all(&destination)
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    let mut total_bytes = 0_u64;
    let mut parts_total = 0_u64;
    let mut uses_multipart = false;
    let mut object_sizes = BTreeMap::new();
    let mut validators = BTreeMap::new();
    run_bounded(keys.len() as u64, transfer_concurrency(&profile), |index| {
        let client = client.clone();
        let encryption = encryption.clone();
        let bucket = bucket_name.clone();
        let key = keys[index as usize].clone();
        let version = params["versionId"].as_str().map(str::to_owned);
        async move {
            let head = encryption_customer!(client.head_object().bucket(bucket).key(&key).set_version_id(version), &encryption).send().await.map_err(|error| object_encryption::read_error(error, encryption.customer()))?;
            Ok((key, head))
        }
    }, |(key, head)| {
        let size = head.content_length().unwrap_or_default().max(0) as u64;
        object_sizes.insert(key.clone(), size);
        validators.insert(key, head.e_tag().map(str::to_owned));
        total_bytes += size;
        if size >= multipart_threshold_bytes {
            uses_multipart = true;
            parts_total += size.div_ceil(multipart_chunk_bytes);
        }
    }).await?;
    if let Some(config) = &client_encryption {
        parts_total = 0;
        uses_multipart = true;
        for size in object_sizes.values() {
            parts_total += client_encryption::chunk_count(config.plaintext_length(*size)?);
        }
    }
    let concurrency = transfer_concurrency(&profile);
    let job_id = format!("download-{}", short_uuid());
    let label = format!("Download {} object(s) from {bucket_name}", keys.len());
    let strategy_label = transfer_strategy_label("download", uses_multipart);
    let part_size_bytes = if parts_total > 0 {
        Some(if client_encryption.is_some() { client_encryption::SEALED } else { multipart_chunk_bytes })
    } else {
        None
    };
    let part_total_value = if parts_total > 0 {
        Some(parts_total)
    } else {
        None
    };
    let progress = Arc::new(TransferProgress {
        job_id: job_id.clone(),
        label: label.clone(),
        direction: "download",
        total_bytes,
        strategy_label: strategy_label.clone(),
        item_count: keys.len(),
        part_size_bytes,
        parts_total: part_total_value,
        activity_interval: Duration::from_millis(
            params["progressIntervalMs"]
                .as_u64()
                .unwrap_or(100)
                .clamp(50, 2000),
        ),
        state: Mutex::new(TransferProgressState {
            last_activity_emit: Instant::now(),
            current_item: None,
            bytes_transferred: 0,
            parts_completed: 0,
            items_completed: 0,
            part_lines_recorded: 0,
            output_lines: vec![format!(
                "Queued {} object(s) for download to {destination_path}.",
                keys.len()
            )],
        }),
    });
    progress.emit("queued", keys.first().cloned());
    let mut destination_index = DestinationIndex::new(&destination)
        .map_err(|e| SidecarError::new("invalid_config", e.to_string()))?;
    for key in &keys {
        let staged = destination_index.stage()
            .map_err(|e| SidecarError::new("invalid_config", e.to_string()))?;
        let target = staged.0.clone();
        let object_size = *object_sizes.get(key).unwrap_or(&0);
        {
            let mut state = progress.state.lock().unwrap();
            state.output_lines.push(format!(
                "Downloading {key} ({object_size} bytes) to {:?}.",
                target
            ));
        }
        if let Some(config) = &client_encryption {
            client_encryption::download(config, &client, &bucket_name, key, &target, object_size,
                validators.get(key).cloned().flatten(), params["versionId"].as_str().map(str::to_owned),
                concurrency, profile.max_attempts, &progress, &encryption).await?;
        } else if object_size >= multipart_threshold_bytes {
            download_object_ranged(
                &client,
                validators.get(key).cloned().flatten(),
                params["versionId"].as_str().map(str::to_owned),
                &bucket_name,
                key,
                &target,
                object_size,
                multipart_chunk_bytes,
                concurrency,
                profile.max_attempts,
                &progress,
                &encryption,
            )
            .await?;
        } else {
            let output = encryption_customer!(client
                .get_object()
                .bucket(&bucket_name)
                .key(key)
                .set_version_id(params["versionId"].as_str().map(str::to_owned))
                .set_if_match(validators.get(key).cloned().flatten()), &encryption)
                .send()
                .await
                .map_err(|error| object_encryption::read_error(error, encryption.customer()))?;
            let mut file = tokio::fs::File::create(&target)
                .await
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            let mut body = output.body;
            let mut object_bytes = 0_u64;
            while let Some(chunk) = body
                .try_next()
                .await
                .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?
            {
                if object_bytes + chunk.len() as u64 > object_size {
                    return Err(SidecarError::new(
                        "object_conflict",
                        "Oversized download body; partial file discarded.",
                    ));
                }
                file.write_all(&chunk)
                    .await
                    .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
                object_bytes += chunk.len() as u64;
                progress.note_activity();
            }
            if object_bytes != object_size {
                return Err(SidecarError::new(
                    "object_conflict",
                    "Download size mismatch; partial file discarded.",
                ));
            }
            file.flush()
                .await
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            {
                let mut state = progress.state.lock().unwrap();
                state.bytes_transferred += object_bytes;
            }
            progress.emit("running", Some(key.clone()));
        }
        tokio::fs::OpenOptions::new()
            .write(true)
            .open(&target)
            .await
            .map_err(|e| SidecarError::new("invalid_config", e.to_string()))?
            .sync_all()
            .await
            .map_err(|e| SidecarError::new("invalid_config", e.to_string()))?;
        let published_key = if let Some(name) = client_encryption.as_ref().and_then(|config| config.file_name.as_deref()) {
            name
        } else if client_encryption.is_some() {
            key.strip_suffix(".age")
                .filter(|name| !name.rsplit(['/', '\\']).next().unwrap_or_default().is_empty())
                .unwrap_or(key)
        } else {
            key
        };
        let final_path = staged
            .publish_with_index(
                &mut destination_index,
                published_key,
                params["conflictPolicy"].as_str().unwrap_or("keepBoth"),
            )
            .map_err(|e| SidecarError::new("invalid_config", e.to_string()))?;
        {
            let mut state = progress.state.lock().unwrap();
            state
                .output_lines
                .push(format!("Saved {key} to {}.", final_path.display()));
            state.items_completed += 1;
            state
                .output_lines
                .push(format!("Finished downloading {key}."));
        }
    }
    let (bytes_transferred, items_completed, parts_completed, output_lines) = {
        let mut state = progress.state.lock().unwrap();
        state.output_lines.push(format!(
            "Downloaded {} object(s) into {destination_path}.",
            keys.len()
        ));
        (
            state.bytes_transferred,
            state.items_completed,
            state.parts_completed,
            state.output_lines.clone(),
        )
    };
    Ok(transfer_job(
        job_id,
        label,
        "download",
        1.0,
        "completed",
        bytes_transferred,
        total_bytes,
        Some(strategy_label),
        keys.last().cloned(),
        keys.len(),
        items_completed,
        part_size_bytes,
        if part_total_value.is_some() {
            Some(parts_completed)
        } else {
            None
        },
        part_total_value,
        false,
        false,
        false,
        output_lines,
    ))
}

async fn generate_presigned_url(params: Value) -> SidecarResult {
    let encryption = Encryption::parse(&params["encryption"], &params["profile"], false)?;
    if encryption.customer() { return Err(SidecarError::new("unsupported_feature", "Customer-provided encryption requires secret headers and cannot be shared as a presigned URL.")); }
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let key = required_text(
        &params,
        "key",
        "Bucket name and object key are required to generate a presigned URL.",
    )?;
    let expiration_seconds = params["expirationSeconds"].as_u64().unwrap_or(3600).max(1);
    let presigned = client
        .get_object()
        .bucket(bucket_name)
        .key(key)
        .set_version_id(params["versionId"].as_str().map(str::to_owned))
        .presigned(
            PresigningConfig::expires_in(Duration::from_secs(expiration_seconds))
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?,
        )
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({"url": presigned.uri().to_string()}))
}

fn tool_state(label: &str, status: String, output_lines: Vec<String>, exit_code: i64) -> Value {
    json!({
        "label": label,
        "running": false,
        "lastStatus": status,
        "jobId": format!("tool-{}", short_uuid()),
        "cancellable": false,
        "outputLines": output_lines,
        "exitCode": exit_code,
    })
}

async fn run_put_test_data(params: Value) -> SidecarResult {
    let encryption = Encryption::parse(&params["encryption"], &params["profile"], false)?;
    let profile = parse_profile(&params["profile"])?;
    let config = &params["config"];
    let bucket_name = config["bucketName"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_string();
    if bucket_name.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Bucket name is required.",
        ));
    }
    let object_count = config["objectCount"].as_u64().unwrap_or(0) as usize;
    let versions = config["versions"].as_u64().unwrap_or(1).max(1) as usize;
    let prefix = config["prefix"].as_str().unwrap_or_default().to_string();
    let threads = config["threads"].as_u64().unwrap_or(1).clamp(1, 16) as usize;
    let size_bytes = config["objectSizeBytes"]
        .as_u64()
        .or_else(|| config["sizeBytes"].as_u64())
        .unwrap_or(4096) as usize;
    let client = build_client(&profile).await?;
    let payload = Bytes::from(vec![b'A'; size_bytes]);

    let mut created_versions = 0_usize;
    let result = run_bounded(
        object_count as u64,
        threads,
        |index| {
            let client = client.clone();
            let bucket = bucket_name.clone();
            let key = format!("{prefix}testdata-{index:06}.bin");
            let payload = payload.clone();
            let encryption = encryption.clone();
            async move {
                for _ in 0..versions {
                    encryption_write!(client
                        .put_object()
                        .bucket(&bucket)
                        .key(&key)
                        .body(ByteStream::from(payload.clone())), &encryption)
                        .send()
                        .await
                        .map_err(map_sdk_error)?;
                }
                Ok::<usize, SidecarError>(versions)
            }
        },
        |count| created_versions += count,
    )
    .await;
    let mut output_lines = vec![
        format!("Bucket: {bucket_name}"),
        format!("Prefix: {prefix}"),
        format!("Threads: {threads}"),
        format!("Object size: {size_bytes} bytes"),
    ];
    if let Err(error) = result {
        output_lines.push(format!(
            "Created {created_versions} object version(s) before failing."
        ));
        output_lines.push(format!("Error: {}", error.message));
        return Ok(tool_state(
            "put-testdata",
            format!("put-testdata failed: {}", error.message),
            output_lines,
            1,
        ));
    }
    output_lines.push(format!("Created {created_versions} object version(s)."));
    Ok(tool_state(
        "put-testdata",
        format!(
            "Created {object_count} object(s) with {versions} version(s) each in {bucket_name}."
        ),
        output_lines,
        0,
    ))
}

async fn run_delete_all(params: Value) -> SidecarResult {
    delete_all::run(params).await
}
fn cancel_tool_execution(params: &Value) -> Value {
    delete_all::cancel(params)
}

static CLIENTS: OnceLock<tokio::sync::Mutex<Vec<(Profile, Client)>>> = OnceLock::new();

async fn build_client(profile: &Profile) -> Result<Client, SidecarError> {
    {
        let clients = CLIENTS.get_or_init(Default::default).lock().await;
        if let Some((_, client)) = clients.iter().find(|(key, _)| key == profile) {
            return Ok(client.clone());
        }
    }
    let shared_config = load_profile_config(profile).await?;
    let config = aws_sdk_s3::config::Builder::from(&shared_config)
        .endpoint_url(profile.endpoint_url.clone())
        .force_path_style(profile.path_style)
        .request_checksum_calculation(if profile.endpoint_type == "awsS3" { aws_sdk_s3::config::RequestChecksumCalculation::WhenSupported } else { aws_sdk_s3::config::RequestChecksumCalculation::WhenRequired })
        .response_checksum_validation(if profile.endpoint_type == "awsS3" { aws_sdk_s3::config::ResponseChecksumValidation::WhenSupported } else { aws_sdk_s3::config::ResponseChecksumValidation::WhenRequired })
        .timeout_config(profile_timeout_config(profile))
        .interceptor(ProfileHeaders {
            requester_pays: profile.requester_pays,
            expected_bucket_owner: profile.expected_bucket_owner.clone(),
        })
        .interceptor(HttpTraceInterceptor {
            enable_api_logging: profile.enable_api_logging,
        })
        .build();
    let client = Client::from_conf(config);
    let mut clients = CLIENTS.get_or_init(Default::default).lock().await;
    if let Some((_, cached)) = clients.iter().find(|(key, _)| key == profile) {
        return Ok(cached.clone());
    }
    if clients.len() >= 16 {
        clients.remove(0);
    }
    clients.push((profile.clone(), client.clone()));
    Ok(client)
}

async fn load_profile_config(profile: &Profile) -> Result<aws_config::SdkConfig, SidecarError> {
    let mut loader = aws_config::defaults(BehaviorVersion::latest())
        .region(Region::new(profile.region.clone()))
        .retry_config(RetryConfig::standard().with_max_attempts(profile.max_attempts));
    if profile.auth_mode == "static" || (profile.auth_mode == "assumeRole" && !profile.access_key.is_empty() && !profile.secret_key.is_empty()) {
        loader = loader.credentials_provider(Credentials::new(
            profile.access_key.clone(),
            profile.secret_key.clone(),
            profile.session_token.clone(),
            None,
            "static",
        ));
    } else if profile.auth_mode == "awsProfile"
        || (profile.auth_mode == "assumeRole" && !profile.aws_profile_name.is_empty())
    {
        let name = if profile.aws_profile_name.is_empty() {
            "default"
        } else {
            &profile.aws_profile_name
        };
        loader = loader.profile_name(name).credentials_provider(
            aws_config::profile::ProfileFileCredentialsProvider::builder()
                .profile_name(name)
                .build(),
        );
    }
    let mut shared_config = loader.load().await;
    if profile.auth_mode == "assumeRole" {
        if profile.role_arn.is_empty() {
            return Err(SidecarError::new("invalid_config", "Role ARN is required."));
        }
        let mut role = aws_config::sts::AssumeRoleProvider::builder(&profile.role_arn)
            .session_name(&profile.role_session_name)
            .configure(&shared_config);
        if let Some(external) = &profile.external_id {
            role = role.external_id(external);
        }
        shared_config = shared_config
            .to_builder()
            .credentials_provider(
                aws_credential_types::provider::SharedCredentialsProvider::new(role.build().await),
            )
            .build();
    }
    Ok(shared_config)
}

fn profile_timeout_config(profile: &Profile) -> TimeoutConfig {
    TimeoutConfig::builder()
        .connect_timeout(Duration::from_secs(profile.connect_timeout_seconds as u64))
        .read_timeout(Duration::from_secs(profile.read_timeout_seconds as u64))
        .build()
}

async fn bucket_context(params: &Value) -> Result<(Profile, String, Client), SidecarError> {
    let profile = parse_profile(&params["profile"])?;
    let bucket_name = required_text(params, "bucketName", "Bucket name is required.")?;
    let client = build_client(&profile).await?;
    Ok((profile, bucket_name, client))
}

fn parse_profile(value: &Value) -> Result<Profile, SidecarError> {
    parse_profile_inner(value, true)
}

fn parse_profile_inner(value: &Value, check_tls_options: bool) -> Result<Profile, SidecarError> {
    if value["endpointType"].as_str().unwrap_or_default().trim() == "azureBlob" {
        return Err(SidecarError::new(
            "unsupported_feature",
            "Azure Blob profiles are not supported by the rust engine yet. Switch the engine to Go or Python in Settings.",
        ));
    }
    // Only S3 profile types may reach the S3 client; a non-S3 secret must
    // never be sent to an S3 endpoint as an access key.
    match value["endpointType"].as_str().unwrap_or_default().trim() {
        "" | "s3Compatible" | "awsS3" => {}
        "googleCloudStorage" => {
            return Err(SidecarError::new(
                "unsupported_feature",
                "Google Cloud Storage profiles are not supported by the rust engine yet. Switch the engine to Go or Python in Settings.",
            ));
        }
        _ => {
            return Err(SidecarError::new(
                "invalid_config",
                "Unknown endpoint type.",
            ));
        }
    }
    let auth_mode = value["authMode"].as_str().unwrap_or("static");
    if !matches!(
        auth_mode,
        "static" | "awsDefault" | "awsProfile" | "assumeRole"
    ) {
        return Err(SidecarError::new(
            "unsupported_feature",
            "Unknown authentication mode.",
        ));
    }
    if check_tls_options
        && (value["caBundlePath"].as_str().is_some_and(|v| !v.is_empty())
            || (value["verifyTls"] == false
                && value["endpointUrl"]
                    .as_str()
                    .unwrap_or("")
                    .starts_with("https://")))
    {
        return Err(SidecarError::new("unsupported_feature", "This Rust build does not support the requested custom-CA or disabled-TLS-verification option. Use Python."));
    }
    let endpoint_url = value["endpointUrl"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_string();
    let access_key = value["accessKey"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_string();
    let secret_key = value["secretKey"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_string();
    let mut region = value["region"]
        .as_str()
        .unwrap_or("us-east-1")
        .trim()
        .to_string();
    if region.is_empty() {
        region = "us-east-1".to_string();
    }
    if endpoint_url.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Endpoint URL is required.",
        ));
    }
    if auth_mode == "static" && (access_key.is_empty() || secret_key.is_empty()) {
        return Err(SidecarError::new(
            "invalid_config",
            "Access key and secret key are required.",
        ));
    }
    Ok(Profile {
        endpoint_type: value["endpointType"].as_str().unwrap_or("s3Compatible").to_string(),
        auth_mode: auth_mode.to_string(),
        aws_profile_name: value["awsProfileName"].as_str().unwrap_or("").to_string(),
        role_arn: value["roleArn"].as_str().unwrap_or("").to_string(),
        external_id: value["externalId"]
            .as_str()
            .filter(|v| !v.is_empty())
            .map(str::to_owned),
        role_session_name: value["roleSessionName"]
            .as_str()
            .filter(|v| !v.is_empty())
            .unwrap_or("object-browser")
            .to_string(),
        requester_pays: value["requesterPays"].as_bool().unwrap_or(false),
        expected_bucket_owner: value["expectedBucketOwner"]
            .as_str()
            .filter(|v| !v.is_empty())
            .map(str::to_owned),
        endpoint_url,
        region,
        access_key,
        secret_key,
        session_token: value["sessionToken"]
            .as_str()
            .filter(|token| !token.trim().is_empty())
            .map(|token| token.to_string()),
        path_style: value["pathStyle"].as_bool().unwrap_or(false),
        verify_tls: !value
            .get("verifyTls")
            .is_some_and(|verify| !verify.as_bool().unwrap_or(true)),
        connect_timeout_seconds: value["connectTimeoutSeconds"].as_i64().unwrap_or(5).max(1),
        read_timeout_seconds: value["readTimeoutSeconds"].as_i64().unwrap_or(60).max(1),
        max_attempts: value["maxAttempts"].as_u64().unwrap_or(5).max(1) as u32,
        max_pool_connections: value["maxConcurrentRequests"].as_u64().unwrap_or(10).max(1) as usize,
        enable_api_logging: value["diagnostics"]["enableApiLogging"]
            .as_bool()
            .unwrap_or(false),
        enable_debug_logging: value["diagnostics"]["enableDebugLogging"]
            .as_bool()
            .unwrap_or(false),
    })
}

async fn record_api<T, E>(
    api_calls: &mut Vec<Value>,
    operation: &str,
    future: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, SidecarError>
where
    E: Into<aws_sdk_s3::Error>,
{
    record_api_with(api_calls, operation, future, map_sdk_error).await
}

async fn record_api_with<T, E>(
    api_calls: &mut Vec<Value>,
    operation: &str,
    future: impl std::future::Future<Output = Result<T, E>>,
    map_error: impl FnOnce(E) -> SidecarError,
) -> Result<T, SidecarError> {
    let started = std::time::Instant::now();
    match future.await {
        Ok(result) => {
            api_calls.push(json!({
                "timestamp": now_iso(),
                "operation": operation,
                "status": "200",
                "latencyMs": started.elapsed().as_millis()
            }));
            Ok(result)
        }
        Err(error) => {
            api_calls.push(json!({
                "timestamp": now_iso(),
                "operation": operation,
                "status": "ERROR",
                "latencyMs": started.elapsed().as_millis()
            }));
            Err(map_error(error))
        }
    }
}

async fn optional_api<T, E>(
    api_calls: &mut Vec<Value>,
    operation: &str,
    future: impl std::future::Future<Output = Result<T, E>>,
) -> Result<Option<T>, SidecarError>
where
    E: Into<aws_sdk_s3::Error>,
{
    match record_api(api_calls, operation, future).await {
        Ok(result) => {
            if let Some(last) = api_calls.last_mut() {
                last["sectionState"] = json!("available");
            }
            Ok(Some(result))
        }
        Err(error) => {
            let code = error.details["awsCode"].as_str().unwrap_or("Unknown");
            let state = if matches!(
                code,
                "AccessDenied"
                    | "InvalidAccessKeyId"
                    | "SignatureDoesNotMatch"
                    | "AllAccessDisabled"
            ) {
                "denied"
            } else if matches!(
                code,
                "NotImplemented" | "XNotImplemented" | "MethodNotAllowed"
            ) {
                "unsupported"
            } else if matches!(
                code,
                "NoSuchLifecycleConfiguration"
                    | "NoSuchBucketPolicy"
                    | "NoSuchCORSConfiguration"
                    | "NoSuchTagSet"
                    | "ObjectLockConfigurationNotFoundError"
                    | "NoSuchObjectLockConfiguration"
                    | "ServerSideEncryptionConfigurationNotFoundError"
            ) {
                "absent"
            } else {
                "error"
            };
            if let Some(last) = api_calls.last_mut() {
                last["sectionState"] = json!(state);
                last["code"] = json!(code);
                last["reason"] = json!(error.message);
            }
            Ok(None)
        }
    }
}
fn section_statuses(calls: &[Value]) -> Value {
    Value::Object(calls.iter().map(|c|(c["operation"].as_str().unwrap_or("").to_string(),json!({"state":c["sectionState"].as_str().unwrap_or(if c["status"]=="200" {"available"}else{"error"}),"code":c["code"],"reason":c["reason"],"message":c["reason"]}))).collect())
}

fn parse_cors_rules(value: &Value) -> Result<Vec<CorsRule>, SidecarError> {
    let Some(items) = value.as_array() else {
        return Ok(Vec::new());
    };
    let mut rules = Vec::new();
    for item in items {
        let mut builder = CorsRule::builder();
        for allowed_header in string_array(item.get("AllowedHeaders").unwrap_or(&Value::Null)) {
            builder = builder.allowed_headers(allowed_header);
        }
        for allowed_method in string_array(item.get("AllowedMethods").unwrap_or(&Value::Null)) {
            builder = builder.allowed_methods(allowed_method);
        }
        for allowed_origin in string_array(item.get("AllowedOrigins").unwrap_or(&Value::Null)) {
            builder = builder.allowed_origins(allowed_origin);
        }
        for expose_header in string_array(item.get("ExposeHeaders").unwrap_or(&Value::Null)) {
            builder = builder.expose_headers(expose_header);
        }
        if let Some(id) = item
            .get("ID")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        {
            builder = builder.id(id);
        }
        if let Some(max_age) = item.get("MaxAgeSeconds").and_then(Value::as_i64) {
            builder = builder.max_age_seconds(max_age as i32);
        }
        rules.push(
            builder
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?,
        );
    }
    Ok(rules)
}

fn parse_encryption_configuration(
    value: &Value,
) -> Result<ServerSideEncryptionConfiguration, SidecarError> {
    let Some(items) = value.get("Rules").and_then(Value::as_array) else {
        return ServerSideEncryptionConfiguration::builder()
            .build()
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()));
    };
    let mut rules = Vec::new();
    for item in items {
        let mut builder = ServerSideEncryptionRule::builder();
        if let Some(defaults) = item
            .get("ApplyServerSideEncryptionByDefault")
            .and_then(Value::as_object)
        {
            let mut defaults_builder = ServerSideEncryptionByDefault::builder();
            if let Some(algorithm) = defaults.get("SSEAlgorithm").and_then(Value::as_str) {
                defaults_builder =
                    defaults_builder.sse_algorithm(ServerSideEncryption::from(algorithm));
            }
            if let Some(key_id) = defaults
                .get("KMSMasterKeyID")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
            {
                defaults_builder = defaults_builder.kms_master_key_id(key_id);
            }
            builder = builder.apply_server_side_encryption_by_default(
                defaults_builder
                    .build()
                    .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?,
            );
        }
        if let Some(bucket_key_enabled) = item.get("BucketKeyEnabled").and_then(Value::as_bool) {
            builder = builder.bucket_key_enabled(bucket_key_enabled);
        }
        if let Some(blocked) = item.get("BlockedEncryptionTypes").filter(|v| !v.is_null()) {
            let types = blocked["EncryptionType"].as_array().ok_or_else(|| SidecarError::new("invalid_config", "BlockedEncryptionTypes.EncryptionType must be an array."))?;
            let mut block = aws_sdk_s3::types::BlockedEncryptionTypes::builder();
            for value in types {
                let value = value.as_str().ok_or_else(|| SidecarError::new("invalid_config", "Blocked encryption types must be strings."))?;
                block = block.encryption_type(aws_sdk_s3::types::EncryptionType::from(value));
            }
            builder = builder.blocked_encryption_types(block.build());
        }
        rules.push(builder.build());
    }
    ServerSideEncryptionConfiguration::builder()
        .set_rules(Some(rules))
        .build()
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))
}

fn lifecycle_rule_summary(rule: &LifecycleRule) -> Value {
    let transition = rule.transitions().first();
    let noncurrent = rule.noncurrent_version_transitions().first();
    json!({
        "id": rule.id().unwrap_or("rule"),
        "enabled": matches!(rule.status(), aws_sdk_s3::types::ExpirationStatus::Enabled),
        "prefix": rule.filter().and_then(|value| value.prefix()).unwrap_or_default(),
        "expirationDays": rule.expiration().and_then(|value| value.days()),
        "deleteExpiredObjectDeleteMarkers": rule.expiration().and_then(|value| value.expired_object_delete_marker()).unwrap_or(false),
        "transitionStorageClass": transition.and_then(|value| value.storage_class()).map(|value| value.as_str()),
        "transitionDays": transition.and_then(|value| value.days()),
        "nonCurrentExpirationDays": rule.noncurrent_version_expiration().and_then(|value| value.noncurrent_days()),
        "nonCurrentTransitionStorageClass": noncurrent.and_then(|value| value.storage_class()).map(|value| value.as_str()),
        "nonCurrentTransitionDays": noncurrent.and_then(|value| value.noncurrent_days()),
        "abortIncompleteMultipartUploadDays": rule.abort_incomplete_multipart_upload().and_then(|value| value.days_after_initiation()),
    })
}

fn cors_rule_raw(rule: &CorsRule) -> Value {
    json!({
        "AllowedHeaders": rule.allowed_headers(),
        "AllowedMethods": rule.allowed_methods(),
        "AllowedOrigins": rule.allowed_origins(),
        "ExposeHeaders": rule.expose_headers(),
        "ID": rule.id(),
        "MaxAgeSeconds": rule.max_age_seconds(),
    })
}

fn encryption_raw(config: &ServerSideEncryptionConfiguration) -> Value {
    json!({
        "Rules": config.rules().iter().map(|rule| json!({
            "ApplyServerSideEncryptionByDefault": rule.apply_server_side_encryption_by_default().map(|value| json!({
                "SSEAlgorithm": value.sse_algorithm().as_str(),
                "KMSMasterKeyID": value.kms_master_key_id(),
            })),
            "BucketKeyEnabled": rule.bucket_key_enabled(),
            "BlockedEncryptionTypes": rule.blocked_encryption_types().map(|blocked| json!({"EncryptionType":blocked.encryption_type().iter().map(|value| value.as_str()).collect::<Vec<_>>()})),
        })).collect::<Vec<_>>()
    })
}

fn transfer_job(
    job_id: String,
    label: String,
    direction: &str,
    progress: f64,
    status: &str,
    bytes_transferred: u64,
    total_bytes: u64,
    strategy_label: Option<String>,
    current_item_label: Option<String>,
    item_count: usize,
    items_completed: usize,
    part_size_bytes: Option<u64>,
    parts_completed: Option<u64>,
    parts_total: Option<u64>,
    _can_pause: bool,
    _can_resume: bool,
    _can_cancel: bool,
    output_lines: Vec<String>,
) -> Value {
    json!({
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
        "canPause": false,
        "canResume": false,
        "canCancel": false,
        "outputLines": output_lines,
    })
}

fn transfer_control(params: &Value, action: &str) -> Value {
    let job_id = params["jobId"]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("transfer-{}", short_uuid()));
    transfer_job(
        job_id,
        format!("Transfer {action}"),
        "transfer",
        if action == "cancelled" { 1.0 } else { 0.0 },
        action,
        0,
        0,
        None,
        None,
        0,
        0,
        None,
        None,
        None,
        false,
        false,
        false,
        vec![format!("Transfer {action}.")],
    )
}

fn emit_transfer_event(job: &Value) {
    let payload = json!({
        "event": "transferProgress",
        "job": job,
    });
    if let Ok(serialized) = serde_json::to_string(&payload) {
        let serialized = secret_hygiene::text(&serialized);
        #[cfg(test)] secret_hygiene::capture(&serialized);
        println!("{serialized}");
        let _ = io::stdout().flush();
    }
}

fn transfer_strategy_label(direction: &str, uses_multipart: bool) -> String {
    format!(
        "{} {direction}",
        if uses_multipart {
            "Multipart"
        } else {
            "Single-part"
        }
    )
}

fn progress_fraction(bytes_transferred: u64, total_bytes: u64) -> f64 {
    if total_bytes == 0 {
        1.0
    } else {
        bytes_transferred as f64 / total_bytes as f64
    }
}

fn append_log(state: &mut Value, line: &str) {
    if let Some(items) = state["liveLog"].as_array_mut() {
        items.push(Value::String(line.to_string()));
    }
}

fn required_text(value: &Value, field: &str, message: &str) -> Result<String, SidecarError> {
    value[field]
        .as_str()
        .map(|v| {
            if matches!(field, "key" | "sourceKey" | "destinationKey") {
                v
            } else {
                v.trim()
            }
        })
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| SidecarError::new("invalid_config", message))
}

fn string_array(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .filter(|item| !item.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn string_map(value: &Value) -> BTreeMap<String, String> {
    value
        .as_object()
        .map(|items| {
            items
                .iter()
                .filter_map(|(key, value)| {
                    value
                        .as_str()
                        .map(str::trim)
                        .filter(|item| !item.is_empty())
                        .map(|item| (key.clone(), item.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn trim_quotes_option(value: Option<&str>) -> Option<String> {
    value
        .map(|text| text.trim().trim_matches('"').to_string())
        .filter(|text| !text.is_empty())
}

fn serialize_system_time(value: Option<SystemTime>) -> String {
    value
        .map(chrono::DateTime::<Utc>::from)
        .unwrap_or_else(|| chrono::DateTime::<Utc>::from(SystemTime::UNIX_EPOCH))
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn serialize_aws_datetime(value: Option<&aws_sdk_s3::primitives::DateTime>) -> String {
    let system_time = value.and_then(|timestamp| SystemTime::try_from(timestamp.clone()).ok());
    serialize_system_time(system_time)
}

fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn short_uuid() -> String {
    Uuid::new_v4().to_string()[..8].to_string()
}

fn emit_structured_log(level: &str, category: &str, message: String, source: &str) {
    let payload = json!({
        "level": level,
        "category": category,
        "message": message,
        "source": source,
    });
    let output = format!("S3_BROWSER_LOG {}", secret_hygiene::value(payload));
    #[cfg(test)] secret_hygiene::capture(&output);
    eprintln!("{output}");
}

fn sanitize_header_value(name: &str, value: &str) -> String {
    let lower = name.to_ascii_lowercase();
    if secret_hygiene::sensitive(name)
        || lower.contains("authorization")
        || lower.contains("security-token")
        || lower.contains("access-key")
        || lower.contains("secret")
        || lower.contains("token")
    {
        "[redacted]".to_string()
    } else {
        secret_hygiene::text(value)
    }
}

fn sanitize_headers<'a>(headers: impl Iterator<Item = (&'a str, &'a str)>) -> Map<String, Value> {
    let mut sanitized = Map::new();
    for (key, value) in headers {
        sanitized.insert(
            key.to_string(),
            Value::String(sanitize_header_value(key, value)),
        );
    }
    sanitized
}

fn summarize_body(content_type: &str, body: &[u8]) -> String {
    if body.is_empty() {
        return "null".to_string();
    }
    if body.len() > 1024 * 256 {
        return "[omitted large body]".to_string();
    }
    let lower = content_type.to_ascii_lowercase();
    if lower.contains("octet-stream") || lower.contains("application/x-www-form-urlencoded") {
        return "[omitted binary body]".to_string();
    }
    match std::str::from_utf8(body) {
        Ok(text) => {
            let text = text.trim();
            let text = if let Ok(value) = serde_json::from_str::<Value>(text) {
                secret_hygiene::value(value).to_string()
            } else {
                secret_hygiene::text(text)
            };
            if text.is_empty() {
                "null".to_string()
            } else if text.len() > 16000 {
                format!("{}...(truncated)", text.chars().take(16000).collect::<String>())
            } else {
                text
            }
        }
        Err(_) => "[omitted binary body]".to_string(),
    }
}

#[derive(Debug)]
struct ProfileHeaders {
    requester_pays: bool,
    expected_bucket_owner: Option<String>,
}
impl Intercept for ProfileHeaders {
    fn name(&self) -> &'static str {
        "ProfileHeaders"
    }
    fn modify_before_signing(
        &self,
        context: &mut BeforeTransmitInterceptorContextMut<'_>,
        _: &RuntimeComponents,
        _: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        if self.requester_pays {
            context
                .request_mut()
                .headers_mut()
                .insert("x-amz-request-payer", "requester");
        }
        if let Some(owner) = &self.expected_bucket_owner {
            context
                .request_mut()
                .headers_mut()
                .insert("x-amz-expected-bucket-owner", owner.clone());
        }
        Ok(())
    }
}

#[derive(Debug)]
struct HttpTraceInterceptor {
    enable_api_logging: bool,
}

impl Intercept for HttpTraceInterceptor {
    fn name(&self) -> &'static str {
        "HttpTraceInterceptor"
    }

    fn modify_before_transmit(
        &self,
        context: &mut BeforeTransmitInterceptorContextMut<'_>,
        _runtime_components: &RuntimeComponents,
        _cfg: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        if !self.enable_api_logging {
            return Ok(());
        }
        let request = context.request();
        let headers = sanitize_headers(request.headers().iter());
        let body = request
            .body()
            .bytes()
            .map(|bytes| {
                summarize_body(
                    request
                        .headers()
                        .get("content-type")
                        .map(|value| value.as_ref())
                        .unwrap_or(""),
                    bytes,
                )
            })
            .unwrap_or_else(|| "[omitted streaming body]".to_string());
        emit_structured_log(
            "API",
            "HttpSend",
            format!(
                "SEND {} {} HEADERS={} BODY={}",
                request.method(),
                request.uri(),
                Value::Object(headers),
                body,
            ),
            "api",
        );
        Ok(())
    }

    fn modify_before_deserialization(
        &self,
        context: &mut BeforeDeserializationInterceptorContextMut<'_>,
        _runtime_components: &RuntimeComponents,
        _cfg: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        if !self.enable_api_logging {
            return Ok(());
        }
        let response = context.response();
        let headers = sanitize_headers(response.headers().iter());
        let body = response
            .body()
            .bytes()
            .map(|bytes| {
                summarize_body(
                    response
                        .headers()
                        .get("content-type")
                        .map(|value| value.as_ref())
                        .unwrap_or(""),
                    bytes,
                )
            })
            .unwrap_or_else(|| "[omitted streaming body]".to_string());
        emit_structured_log(
            "API",
            "HttpReceive",
            format!(
                "RECV STATUS={} HEADERS={} BODY={}",
                response.status(),
                Value::Object(headers),
                body,
            ),
            "api",
        );
        Ok(())
    }
}

fn map_sdk_error<E>(error: E) -> SidecarError
where
    E: Into<aws_sdk_s3::Error>,
{
    let error = error.into();
    let code = error.code().unwrap_or("Unknown").to_string();
    let messages = sdk_error_messages(&error);
    let message = messages
        .iter()
        .find(|item| !is_generic_sdk_message(item))
        .cloned()
        .or_else(|| messages.first().cloned())
        .unwrap_or_else(|| "Unknown engine error.".to_string());
    let lowered = message.to_ascii_lowercase();
    let mut details = json!({
        "awsCode": code,
        "errorChain": messages,
    });
    if let Some(hint) = object_encryption::hint(&code, &messages.join(" ")) { details["encryptionHint"] = json!(hint); }
    match code.as_str() {
        "AccessDenied" | "InvalidAccessKeyId" | "SignatureDoesNotMatch" => {
            SidecarError::with_details("auth_failed", message, details)
        }
        "RequestTimeout" => SidecarError::with_details("timeout", message, details),
        "SlowDown" => SidecarError::with_details("throttled", message, details),
        _ if message_indicates_auth_failure(&lowered) => {
            SidecarError::with_details("auth_failed", message, details)
        }
        _ if message_indicates_timeout(&lowered) => {
            SidecarError::with_details("timeout", message, details)
        }
        _ if message_indicates_tls_failure(&lowered) => {
            SidecarError::with_details("tls_error", message, details)
        }
        _ => SidecarError::with_details("unknown", message, details),
    }
}

fn sdk_error_messages(error: &aws_sdk_s3::Error) -> Vec<String> {
    let mut messages = Vec::new();

    if let Some(message) = error.message() {
        let trimmed = message.trim();
        if !trimmed.is_empty() {
            messages.push(trimmed.to_string());
        }
    }

    let rendered = error.to_string();
    let rendered = rendered.trim();
    if !rendered.is_empty() && !messages.iter().any(|item| item == rendered) {
        messages.push(rendered.to_string());
    }

    let mut source: Option<&(dyn Error + 'static)> = error.source();
    while let Some(current) = source {
        let rendered = current.to_string();
        let rendered = rendered.trim();
        if !rendered.is_empty() && !messages.iter().any(|item| item == rendered) {
            messages.push(rendered.to_string());
        }
        source = current.source();
    }

    if messages.is_empty() {
        messages.push("Unknown engine error.".to_string());
    }

    messages
}

fn is_generic_sdk_message(message: &str) -> bool {
    matches!(
        message.trim().to_ascii_lowercase().as_str(),
        "unhandled error" | "dispatch failure" | "service error"
    )
}

fn message_indicates_auth_failure(message: &str) -> bool {
    message.contains("accessdenied")
        || message.contains("invalidaccesskeyid")
        || message.contains("signaturedoesnotmatch")
        || message.contains("forbidden")
        || message.contains("authorization")
        || message.contains("credentials")
}

fn message_indicates_timeout(message: &str) -> bool {
    message.contains("timed out") || message.contains("timeout")
}

fn message_indicates_tls_failure(message: &str) -> bool {
    message.contains("certificate")
        || message.contains("tls")
        || message.contains("ssl")
        || message.contains("x509")
}

#[cfg(test)]
mod advanced_regressions {
    use super::*;

    fn transfer_test_progress() -> Arc<TransferProgress> {
        Arc::new(TransferProgress {
            job_id: "test-transfer".into(),
            label: "test".into(),
            direction: "download",
            total_bytes: 8,
            strategy_label: "test".into(),
            item_count: 1,
            part_size_bytes: Some(8),
            parts_total: Some(1),
            activity_interval: Duration::from_millis(100),
            state: Mutex::new(TransferProgressState {
                bytes_transferred: 0,
                parts_completed: 0,
                items_completed: 0,
                part_lines_recorded: 0,
                output_lines: vec![],
                last_activity_emit: Instant::now() - Duration::from_secs(1),
                current_item: Some("test.bin".into()),
            }),
        })
    }

    #[tokio::test]
    async fn upload_liveness_wrapper_preserves_retry_body_and_does_not_commit_bytes() {
        let progress = transfer_test_progress();
        let body =
            with_transfer_activity(ByteStream::from(Bytes::from_static(b"abcdefgh")), &progress);
        let inner = body.into_inner();
        let retry = inner.try_clone().expect("upload must remain replayable");
        assert_eq!(
            ByteStream::new(inner).collect().await.unwrap().into_bytes(),
            b"abcdefgh"[..]
        );
        assert_eq!(
            ByteStream::new(retry).collect().await.unwrap().into_bytes(),
            b"abcdefgh"[..]
        );
        let state = progress.state.lock().unwrap();
        assert_eq!(state.bytes_transferred, 0);
        assert_eq!(state.parts_completed, 0);
        assert!(state.last_activity_emit.elapsed() < Duration::from_secs(1));
        assert_eq!(state.current_item.as_deref(), Some("test.bin"));
    }

    #[tokio::test]
    async fn broken_range_body_is_retried_with_validators_and_counted_once() {
        use std::io::Read;
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let mut requests = vec![];
            for attempt in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = vec![];
                while !request.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                }
                requests.push(String::from_utf8(request).unwrap().to_lowercase());
                stream.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 8\r\nContent-Range: bytes 0-7/8\r\nETag: \"test\"\r\nConnection: close\r\n\r\n").unwrap();
                stream
                    .write_all(if attempt == 0 { b"abcd" } else { b"abcdefgh" })
                    .unwrap();
            }
            requests
        });
        let client = Client::from_conf(
            aws_sdk_s3::config::Builder::new()
                .behavior_version_latest()
                .region(Region::new("us-east-1"))
                .credentials_provider(Credentials::new("fixture", "fixture", None, None, "test"))
                .endpoint_url(endpoint)
                .force_path_style(true)
                .retry_config(RetryConfig::standard().with_max_attempts(1))
                .build(),
        );
        let staged = StagedDownload::new(&std::env::temp_dir()).unwrap();
        let progress = transfer_test_progress();
        tokio::time::timeout(
            Duration::from_secs(10),
            download_object_ranged(
                &client,
                Some("\"test\"".into()),
                Some("selected-version".into()),
                "fixture-bucket",
                "test.bin",
                &staged.0,
                8,
                8,
                1,
                3,
                &progress,
                &Encryption::default(),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(fs::read(&staged.0).unwrap(), b"abcdefgh");
        let state = progress.state.lock().unwrap();
        assert_eq!(state.bytes_transferred, 8);
        assert_eq!(state.parts_completed, 1);
        for request in server.join().unwrap() {
            assert!(request.contains("range: bytes=0-7"));
            assert!(request.contains("if-match: \"test\""));
            assert!(request.contains("versionid=selected-version"));
        }
    }
    #[test]
    fn upload_part_sizes_are_clamped_to_s3_limits() {
        let mib = 1024 * 1024;
        for (input, expected) in [
            (json!(-1), 5),
            (json!(0), 5),
            (json!(1), 5),
            (json!(5), 5),
            (json!(8), 8),
            (json!(5120), 5120),
            (json!(5121), 5120),
            (json!(u64::MAX), 5120),
            (Value::Null, 8),
        ] {
            assert_eq!(upload_part_size_bytes(&input), expected * mib);
        }
    }

    #[test]
    fn upload_size_validation_checks_object_and_part_boundaries() {
        let chunk = 5 * 1024 * 1024;
        let max_object = 50000 * 1024_u64.pow(3);
        for size in [0, chunk - 1, chunk, chunk * 10000] {
            validate_upload_size(size, 1, chunk).unwrap();
        }
        validate_upload_size(max_object, 1, 5 * 1024_u64.pow(3)).unwrap();
        // The part-count limit only applies when multipart is selected.
        validate_upload_size(chunk * 10000 + 1, max_object, chunk).unwrap();
        for (size, threshold, part_size) in [
            (chunk * 10000 + 1, 1, chunk),
            (chunk * 10000 + 1, chunk * 10000 + 1, chunk),
            (max_object + 1, u64::MAX, chunk),
            (u64::MAX, 1, chunk),
        ] {
            let error = validate_upload_size(size, threshold, part_size).unwrap_err();
            assert_eq!(error.code, "invalid_config");
            assert!(error.message.contains("10,000-part limits"));
        }
    }

    #[tokio::test]
    async fn invalid_upload_is_rejected_before_client_creation() {
        let staged = StagedDownload::new(&std::env::temp_dir()).unwrap();
        fs::OpenOptions::new()
            .write(true)
            .open(&staged.0)
            .unwrap()
            .set_len(5 * 1024 * 1024 * 10000 + 1)
            .unwrap();
        let error = start_upload(json!({
            "profile": {
                "endpointUrl": "not a valid endpoint",
                "accessKey": "test", "secretKey": "test"
            },
            "bucketName": "test",
            "filePaths": [staged.0],
            "multipartThresholdMiB": 1,
            "multipartChunkMiB": 1
        }))
        .await
        .unwrap_err();
        assert_eq!(error.code, "invalid_config");
        assert!(error.message.contains("10,000-part limits"));
    }

    #[test]
    fn parallel_benchmark_does_not_reuse_an_inflight_key() {
        let mut state = json!({"config":{"workloadType":"write-only","objectCount":1,"objectSizes":[32]},"activeObjects":[{"key":"only-key","sizeBytes":32}],"processedCount":0});
        let tasks = plan_benchmark_batch(&mut state, 8, 100);
        assert_eq!(tasks.len(), 1);
        match &tasks[0].kind {
            BenchmarkTaskKind::Put { key, .. } => assert_eq!(key, "only-key"),
            _ => panic!("expected PUT"),
        }
    }
    #[test]
    fn object_keys_preserve_spaces() {
        let value = json!({"key":"  ","sourceKey":" %雪+ ","keys":["  "," %雪+ "]});
        assert_eq!(required_text(&value, "key", "required").unwrap(), "  ");
        assert_eq!(
            required_text(&value, "sourceKey", "required").unwrap(),
            " %雪+ "
        );
        assert_eq!(string_array(&value["keys"]), vec!["  ", " %雪+ "]);
    }
}

fn decode_listing_key(value: Option<&str>, encoding: Option<&aws_sdk_s3::types::EncodingType>) -> Result<String, SidecarError> {
    let raw = value.unwrap_or_default();
    if encoding != Some(&aws_sdk_s3::types::EncodingType::Url) { return Ok(raw.to_string()); }
    let form_decoded = raw.replace('+', " ");
    urlencoding::decode(&form_decoded)
        .map(|value| value.into_owned())
        .map_err(|_| SidecarError::new("invalid_response", "Invalid URL-encoded object key in listing."))
}
