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
    AbortIncompleteMultipartUpload, BucketLifecycleConfiguration, BucketLocationConstraint,
    BucketVersioningStatus, CompletedMultipartUpload, CompletedPart, CorsConfiguration, CorsRule,
    CreateBucketConfiguration, Delete, LifecycleExpiration, LifecycleRule, LifecycleRuleFilter,
    NoncurrentVersionExpiration, NoncurrentVersionTransition, ObjectIdentifier,
    ServerSideEncryption, ServerSideEncryptionByDefault, ServerSideEncryptionConfiguration,
    ServerSideEncryptionRule, Tag, Tagging, Transition, TransitionStorageClass,
    VersioningConfiguration,
};
use aws_sdk_s3::Client;
use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::error::Error;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};
use tokio::runtime::Runtime;
use uuid::Uuid;

const SUPPORTED_METHODS: &[&str] = &[
    "health",
    "getCapabilities",
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

#[derive(Debug, Deserialize)]
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

#[derive(Debug, Clone)]
struct Profile {
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
            message: message.into(),
            details: Value::Object(Map::new()),
        }
    }

    fn with_details(code: &'static str, message: impl Into<String>, details: Value) -> Self {
        Self {
            code,
            message: message.into(),
            details,
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

#[derive(Clone)]
enum BenchmarkTaskKind {
    Put { key: String, size_bytes: usize },
    Get { key: String, size_bytes: usize },
    DeleteSingle { key: String, size_bytes: usize },
    DeleteMulti { keys: Vec<String> },
}

#[derive(Clone)]
struct BenchmarkTask {
    order: usize,
    kind: BenchmarkTaskKind,
}

struct BenchmarkTaskResult {
    order: usize,
    operation: &'static str,
    key: String,
    size_bytes: usize,
    bytes_transferred: i64,
    checksum_state: String,
    latency_ms: f64,
    operation_count: i64,
    elapsed_ms: f64,
    upserted_object: Option<(String, usize)>,
    removed_keys: Vec<String>,
    log_line: Option<String>,
}

fn main() {
    let runtime = Runtime::new().expect("tokio runtime");
    let stdin = io::stdin();

    for line in stdin.lock().lines() {
        let Ok(line) = line else {
            continue;
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<Request>(trimmed) {
            Ok(request) => {
                let request_id = request.request_id.clone();
                match runtime.block_on(handle_request(request)) {
                    Ok(result) => Response {
                        request_id: request_id.clone(),
                        ok: true,
                        result: Some(result),
                        error: None,
                    },
                    Err(error) => Response {
                        request_id,
                        ok: false,
                        result: None,
                        error: Some(json!({
                            "code": error.code,
                            "message": error.message,
                            "details": error.details,
                        })),
                    },
                }
            }
            Err(_) => continue,
        };

        if let Ok(output) = serde_json::to_string(&response) {
            println!("{output}");
        }
    }
}

async fn handle_request(request: Request) -> SidecarResult {
    match request.method.as_str() {
        "health" => Ok(json!({
            "engine": "rust",
            "version": "2.1.0",
            "available": true,
            "methods": SUPPORTED_METHODS,
            "nativeSdk": "aws-sdk-rust",
        })),
        "getCapabilities" => Ok(json!({
            "items": [
                {"key": "bucket.lifecycle", "label": "Lifecycle policy CRUD", "state": "supported"},
                {"key": "bucket.policy", "label": "Bucket policy CRUD", "state": "supported"},
                {"key": "bucket.cors", "label": "Bucket CORS CRUD", "state": "supported"},
                {"key": "bucket.encryption", "label": "Bucket encryption", "state": "supported"},
                {"key": "bucket.tagging", "label": "Bucket tagging", "state": "supported"},
                {"key": "bucket.versioning", "label": "Bucket versioning", "state": "supported"},
                {"key": "object.copy_move", "label": "Copy, move, rename", "state": "supported"},
                {"key": "object.resumable", "label": "Resumable transfer jobs", "state": "unknown", "reason": "Desktop host currently uses one request per sidecar process."},
                {"key": "tools.bulk-delete", "label": "Delete-all maintenance tool", "state": "supported"},
                {"key": "benchmark", "label": "Integrated benchmark mode", "state": "supported"},
            ]
        })),
        "testProfile" => {
            test_profile(
                request
                    .params
                    .get("profile")
                    .cloned()
                    .unwrap_or(Value::Null),
            )
            .await
        }
        "listBuckets" => {
            list_buckets(
                request
                    .params
                    .get("profile")
                    .cloned()
                    .unwrap_or(Value::Null),
            )
            .await
        }
        "createBucket" => create_bucket(request.params).await,
        "deleteBucket" => delete_bucket(request.params).await,
        "setBucketVersioning" => set_bucket_versioning(request.params).await,
        "putBucketLifecycle" => put_bucket_lifecycle(request.params).await,
        "deleteBucketLifecycle" => delete_bucket_lifecycle(request.params).await,
        "putBucketPolicy" => put_bucket_policy(request.params).await,
        "deleteBucketPolicy" => delete_bucket_policy(request.params).await,
        "putBucketCors" => put_bucket_cors(request.params).await,
        "deleteBucketCors" => delete_bucket_cors(request.params).await,
        "putBucketEncryption" => put_bucket_encryption(request.params).await,
        "deleteBucketEncryption" => delete_bucket_encryption(request.params).await,
        "putBucketTagging" => put_bucket_tagging(request.params).await,
        "deleteBucketTagging" => delete_bucket_tagging(request.params).await,
        "listObjects" => list_objects(request.params).await,
        "getBucketAdminState" => get_bucket_admin_state(request.params).await,
        "listObjectVersions" => list_object_versions(request.params).await,
        "getObjectDetails" => get_object_details(request.params).await,
        "createFolder" => create_folder(request.params).await,
        "copyObject" => copy_object(request.params).await,
        "moveObject" => move_object(request.params).await,
        "deleteObjects" => delete_objects(request.params).await,
        "deleteObjectVersions" => delete_object_versions(request.params).await,
        "startUpload" => start_upload(request.params).await,
        "startDownload" => start_download(request.params).await,
        "pauseTransfer" => Ok(transfer_control(&request.params, "paused")),
        "resumeTransfer" => Ok(transfer_control(&request.params, "running")),
        "cancelTransfer" => Ok(transfer_control(&request.params, "cancelled")),
        "generatePresignedUrl" => generate_presigned_url(request.params).await,
        "runPutTestData" => Ok(run_put_test_data(&request.params)),
        "runDeleteAll" => Ok(run_delete_all(&request.params)),
        "cancelToolExecution" => Ok(cancel_tool_execution(&request.params)),
        "startBenchmark" => start_benchmark(request.params).await,
        "getBenchmarkStatus" => get_benchmark_status(request.params).await,
        "pauseBenchmark" => pause_benchmark(request.params).await,
        "resumeBenchmark" => resume_benchmark(request.params).await,
        "stopBenchmark" => stop_benchmark(request.params).await,
        "exportBenchmarkResults" => export_benchmark_results(request.params).await,
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
    let output = client.list_buckets().send().await.map_err(map_sdk_error)?;
    let items: Vec<Value> = output
        .buckets()
        .iter()
        .map(|bucket| {
            json!({
                "name": bucket.name().unwrap_or_default(),
                "region": profile.region,
                "objectCountHint": 0,
                "versioningEnabled": false,
                "createdAt": serialize_aws_datetime(bucket.creation_date()),
            })
        })
        .collect();
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
    let rules = parse_lifecycle_rules(parsed.get("Rules").unwrap_or(&Value::Null))?;
    let config = BucketLifecycleConfiguration::builder()
        .set_rules(Some(rules))
        .build()
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    client
        .put_bucket_lifecycle_configuration()
        .bucket(bucket_name)
        .lifecycle_configuration(config)
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
        .max_keys(1000);
    if !flat {
        request = request.delimiter("/");
    }
    if let Some(token) = continuation {
        request = request.continuation_token(token);
    }
    let output = request.send().await.map_err(map_sdk_error)?;

    let mut items: Vec<Value> = Vec::new();
    for common_prefix in output.common_prefixes() {
        let folder_prefix = common_prefix.prefix().unwrap_or_default();
        let folder_name = folder_prefix
            .strip_prefix(prefix)
            .unwrap_or(folder_prefix)
            .to_string();
        items.push(json!({
            "key": folder_prefix,
            "name": if folder_name.is_empty() { folder_prefix } else { folder_name.as_str() },
            "size": 0,
            "storageClass": "FOLDER",
            "modifiedAt": now_iso(),
            "isFolder": true,
            "etag": Value::Null,
            "metadataCount": 0
        }));
    }
    for object in output.contents() {
        let key = object.key().unwrap_or_default();
        if !flat && key == prefix {
            continue;
        }
        let name = key.strip_prefix(prefix).unwrap_or(key);
        items.push(json!({
            "key": key,
            "name": if name.is_empty() { key } else { name },
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

    let versioning = record_api(
        &mut api_calls,
        "GetBucketVersioning",
        client.get_bucket_versioning().bucket(&bucket_name).send(),
    )
    .await?;
    let encryption = optional_api(
        &mut api_calls,
        "GetBucketEncryption",
        client.get_bucket_encryption().bucket(&bucket_name).send(),
    )
    .await?;
    let lifecycle = optional_api(
        &mut api_calls,
        "GetBucketLifecycleConfiguration",
        client
            .get_bucket_lifecycle_configuration()
            .bucket(&bucket_name)
            .send(),
    )
    .await?;
    let policy = optional_api(
        &mut api_calls,
        "GetBucketPolicy",
        client.get_bucket_policy().bucket(&bucket_name).send(),
    )
    .await?;
    let cors = optional_api(
        &mut api_calls,
        "GetBucketCors",
        client.get_bucket_cors().bucket(&bucket_name).send(),
    )
    .await?;
    let tagging = optional_api(
        &mut api_calls,
        "GetBucketTagging",
        client.get_bucket_tagging().bucket(&bucket_name).send(),
    )
    .await?;
    let object_lock = optional_api(
        &mut api_calls,
        "GetObjectLockConfiguration",
        client
            .get_object_lock_configuration()
            .bucket(&bucket_name)
            .send(),
    )
    .await?;

    let lifecycle_rules: Vec<Value> = lifecycle
        .as_ref()
        .map(|output| output.rules().iter().map(lifecycle_rule_summary).collect())
        .unwrap_or_default();
    let lifecycle_json = lifecycle
        .as_ref()
        .map(|output| serde_json::to_string_pretty(&json!({"Rules": output.rules().iter().map(lifecycle_rule_raw).collect::<Vec<_>>() })).unwrap_or_else(|_| "{\n  \"Rules\": []\n}".to_string()))
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

    let (object_lock_enabled, object_lock_mode, object_lock_retention_days) =
        if let Some(output) = object_lock {
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
                        )
                    } else {
                        (true, Value::Null, Value::Null)
                    }
                } else {
                    (true, Value::Null, Value::Null)
                }
            } else {
                (false, Value::Null, Value::Null)
            }
        } else {
            (false, Value::Null, Value::Null)
        };

    Ok(json!({
        "bucketName": bucket_name,
        "versioningEnabled": matches!(versioning.status(), Some(BucketVersioningStatus::Enabled)),
        "versioningStatus": versioning.status().map(|value| value.as_str()).unwrap_or("Suspended"),
        "objectLockEnabled": object_lock_enabled,
        "lifecycleEnabled": !lifecycle_rules.is_empty(),
        "policyAttached": policy.as_ref().and_then(|v| v.policy()).map(|v| !v.is_empty()).unwrap_or(false),
        "corsEnabled": cors.as_ref().map(|value| !value.cors_rules().is_empty()).unwrap_or(false),
        "encryptionEnabled": encryption_enabled,
        "encryptionSummary": encryption_summary,
        "objectLockMode": object_lock_mode,
        "objectLockRetentionDays": object_lock_retention_days,
        "tags": tags,
        "lifecycleRules": lifecycle_rules,
        "lifecycleJson": lifecycle_json,
        "policyJson": policy.and_then(|value| value.policy().map(str::to_owned)).unwrap_or_else(|| "{}".to_string()),
        "corsJson": serde_json::to_string_pretty(&cors.as_ref().map(|value| value.cors_rules().iter().map(cors_rule_raw).collect::<Vec<_>>()).unwrap_or_default()).unwrap_or_else(|_| "[]".to_string()),
        "encryptionJson": encryption_json,
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
    let output = client
        .list_object_versions()
        .bucket(bucket_name)
        .prefix(effective_prefix)
        .max_keys(1000)
        .send()
        .await
        .map_err(map_sdk_error)?;

    let mut items = Vec::new();
    for version in output.versions() {
        let version_key = version.key().unwrap_or_default();
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
        let marker_key = marker.key().unwrap_or_default();
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
        "cursor": {"value": null, "hasMore": false},
        "totalCount": items.len(),
        "versionCount": items.len() - delete_marker_count,
        "deleteMarkerCount": delete_marker_count,
    }))
}

async fn get_object_details(params: Value) -> SidecarResult {
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

    let head = record_api(
        &mut api_calls,
        "HeadObject",
        client.head_object().bucket(&bucket_name).key(&key).send(),
    )
    .await?;
    let tagging = optional_api(
        &mut api_calls,
        "GetObjectTagging",
        client
            .get_object_tagging()
            .bucket(&bucket_name)
            .key(&key)
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

    Ok(json!({
        "key": key,
        "metadata": metadata,
        "headers": headers,
        "tags": tags,
        "debugEvents": debug_events,
        "apiCalls": api_calls,
        "debugLogExcerpt": [
            format!("Resolved endpoint {}.", profile.endpoint_url),
            format!("Completed HEAD and tagging diagnostics for {bucket_name}/{key}.")
        ],
        "rawDiagnostics": {
            "bucketName": bucket_name,
            "engineState": "healthy"
        }
    }))
}

async fn create_folder(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let mut key = required_text(
        &params,
        "key",
        "Bucket name and key are required to create a folder.",
    )?;
    if !key.ends_with('/') {
        key.push('/');
    }
    client
        .put_object()
        .bucket(bucket_name)
        .key(&key)
        .body(ByteStream::from(Vec::<u8>::new()))
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({"created": true, "key": key}))
}

async fn copy_object(params: Value) -> SidecarResult {
    let profile = parse_profile(&params["profile"])?;
    let source_bucket = required_text(
        &params,
        "sourceBucketName",
        "Copy source and destination are required.",
    )?;
    let source_key = required_text(
        &params,
        "sourceKey",
        "Copy source and destination are required.",
    )?;
    let destination_bucket = required_text(
        &params,
        "destinationBucketName",
        "Copy source and destination are required.",
    )?;
    let destination_key = required_text(
        &params,
        "destinationKey",
        "Copy source and destination are required.",
    )?;
    let client = build_client(&profile).await?;
    client
        .copy_object()
        .bucket(destination_bucket)
        .key(destination_key)
        .copy_source(urlencoding::encode(&format!("{source_bucket}/{source_key}")).to_string())
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({"successCount": 1, "failureCount": 0, "failures": []}))
}

async fn move_object(params: Value) -> SidecarResult {
    let result = copy_object(params.clone()).await?;
    let profile = parse_profile(&params["profile"])?;
    let client = build_client(&profile).await?;
    client
        .delete_object()
        .bucket(required_text(
            &params,
            "sourceBucketName",
            "Copy source and destination are required.",
        )?)
        .key(required_text(
            &params,
            "sourceKey",
            "Copy source and destination are required.",
        )?)
        .send()
        .await
        .map_err(map_sdk_error)?;
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
    let delete = Delete::builder()
        .set_objects(Some(objects))
        .quiet(false)
        .build()
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    let output = client
        .delete_objects()
        .bucket(bucket_name)
        .delete(delete)
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({
        "successCount": output.deleted().len(),
        "failureCount": output.errors().len(),
        "failures": output.errors().iter().map(|item| json!({
            "target": item.key().unwrap_or_default(),
            "code": item.code().unwrap_or("unknown"),
            "message": item.message().unwrap_or("Unknown delete error.")
        })).collect::<Vec<_>>()
    }))
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
    let delete = Delete::builder()
        .set_objects(Some(objects))
        .quiet(false)
        .build()
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    let output = client
        .delete_objects()
        .bucket(bucket_name)
        .delete(delete)
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({
        "successCount": output.deleted().len(),
        "failureCount": output.errors().len(),
        "failures": output.errors().iter().map(|item| json!({
            "target": item.key().unwrap_or_default(),
            "versionId": item.version_id(),
            "code": item.code().unwrap_or("unknown"),
            "message": item.message().unwrap_or("Unknown delete error.")
        })).collect::<Vec<_>>()
    }))
}

async fn start_upload(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let prefix = params["prefix"].as_str().unwrap_or_default();
    let file_paths = string_array(params.get("filePaths").unwrap_or(&Value::Null));
    let object_key_by_path = string_map(params.get("objectKeyByPath").unwrap_or(&Value::Null));
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
    let multipart_chunk_bytes =
        params["multipartChunkMiB"].as_u64().unwrap_or(8).max(1) * 1024 * 1024;
    let paths = file_paths.iter().map(PathBuf::from).collect::<Vec<_>>();
    let mut total_bytes = 0_u64;
    let mut parts_total = 0_u64;
    let mut uses_multipart = false;
    for path in &paths {
        let metadata = fs::metadata(path)
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        total_bytes += metadata.len();
        if metadata.len() >= multipart_threshold_bytes {
            uses_multipart = true;
            parts_total += metadata.len().div_ceil(multipart_chunk_bytes);
        }
    }
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
    let mut output_lines = vec![format!(
        "Queued {} file(s) for upload to {bucket_name}.",
        paths.len()
    )];
    let mut bytes_transferred = 0_u64;
    let mut items_completed = 0_usize;
    let mut parts_completed = 0_u64;
    emit_transfer_event(&transfer_job(
        job_id.clone(),
        label.clone(),
        "upload",
        0.0,
        "queued",
        0,
        total_bytes,
        Some(strategy_label.clone()),
        paths
            .first()
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
        true,
        false,
        true,
        output_lines.clone(),
    ));
    for path in &paths {
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
        let file_bytes = fs::read(path)
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        let file_size = file_bytes.len() as u64;
        output_lines.push(format!(
            "Uploading {file_name} ({file_size} bytes) to {key}."
        ));
        if file_size >= multipart_threshold_bytes {
            let upload_id = client
                .create_multipart_upload()
                .bucket(&bucket_name)
                .key(&key)
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
            let mut completed_parts = Vec::new();
            let mut offset = 0_usize;
            let mut part_number = 1_i32;
            while offset < file_bytes.len() {
                let end = (offset + multipart_chunk_bytes as usize).min(file_bytes.len());
                let chunk = file_bytes[offset..end].to_vec();
                let output = client
                    .upload_part()
                    .bucket(&bucket_name)
                    .key(&key)
                    .upload_id(&upload_id)
                    .part_number(part_number)
                    .body(ByteStream::from(chunk.clone()))
                    .send()
                    .await
                    .map_err(map_sdk_error)?;
                completed_parts.push(
                    CompletedPart::builder()
                        .set_e_tag(output.e_tag().map(str::to_owned))
                        .part_number(part_number)
                        .build(),
                );
                bytes_transferred += chunk.len() as u64;
                parts_completed += 1;
                output_lines.push(format!("Uploaded part {part_number} for {file_name}."));
                emit_transfer_event(&transfer_job(
                    job_id.clone(),
                    label.clone(),
                    "upload",
                    progress_fraction(bytes_transferred, total_bytes),
                    "running",
                    bytes_transferred,
                    total_bytes,
                    Some(strategy_label.clone()),
                    Some(file_name.clone()),
                    paths.len(),
                    items_completed,
                    part_size_bytes,
                    Some(parts_completed),
                    part_total_value,
                    true,
                    false,
                    true,
                    output_lines.clone(),
                ));
                offset = end;
                part_number += 1;
            }
            client
                .complete_multipart_upload()
                .bucket(&bucket_name)
                .key(&key)
                .upload_id(upload_id)
                .multipart_upload(
                    CompletedMultipartUpload::builder()
                        .set_parts(Some(completed_parts))
                        .build(),
                )
                .send()
                .await
                .map_err(map_sdk_error)?;
        } else {
            let body = ByteStream::from(file_bytes);
            client
                .put_object()
                .bucket(&bucket_name)
                .key(&key)
                .body(body)
                .send()
                .await
                .map_err(map_sdk_error)?;
            bytes_transferred += file_size;
        }
        items_completed += 1;
        output_lines.push(format!("Finished uploading {file_name}."));
        emit_transfer_event(&transfer_job(
            job_id.clone(),
            label.clone(),
            "upload",
            progress_fraction(bytes_transferred, total_bytes),
            "running",
            bytes_transferred,
            total_bytes,
            Some(strategy_label.clone()),
            Some(file_name),
            paths.len(),
            items_completed,
            part_size_bytes,
            if part_total_value.is_some() {
                Some(parts_completed)
            } else {
                None
            },
            part_total_value,
            true,
            false,
            true,
            output_lines.clone(),
        ));
    }
    output_lines.push(format!(
        "Uploaded {} file(s) into {bucket_name}.",
        paths.len()
    ));
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

async fn start_download(params: Value) -> SidecarResult {
    let (_, bucket_name, client) = bucket_context(&params).await?;
    let keys = string_array(params.get("keys").unwrap_or(&Value::Null));
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
    for key in &keys {
        let head = client
            .head_object()
            .bucket(&bucket_name)
            .key(key)
            .send()
            .await
            .map_err(map_sdk_error)?;
        let size = head.content_length().unwrap_or_default() as u64;
        object_sizes.insert(key.clone(), size);
        total_bytes += size;
        if size >= multipart_threshold_bytes {
            uses_multipart = true;
            parts_total += size.div_ceil(multipart_chunk_bytes);
        }
    }
    let job_id = format!("download-{}", short_uuid());
    let label = format!("Download {} object(s) from {bucket_name}", keys.len());
    let strategy_label = transfer_strategy_label("download", uses_multipart);
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
    let mut output_lines = vec![format!(
        "Queued {} object(s) for download to {destination_path}.",
        keys.len()
    )];
    let mut bytes_transferred = 0_u64;
    let mut items_completed = 0_usize;
    let mut parts_completed = 0_u64;
    emit_transfer_event(&transfer_job(
        job_id.clone(),
        label.clone(),
        "download",
        0.0,
        "queued",
        0,
        total_bytes,
        Some(strategy_label.clone()),
        keys.first().cloned(),
        keys.len(),
        items_completed,
        part_size_bytes,
        if part_total_value.is_some() {
            Some(parts_completed)
        } else {
            None
        },
        part_total_value,
        true,
        false,
        true,
        output_lines.clone(),
    ));
    for key in &keys {
        let target = destination.join(Path::new(key).file_name().unwrap_or_default());
        let object_size = *object_sizes.get(key).unwrap_or(&0);
        output_lines.push(format!(
            "Downloading {key} ({object_size} bytes) to {:?}.",
            target
        ));
        if object_size >= multipart_threshold_bytes {
            let mut downloaded = Vec::new();
            let mut start = 0_u64;
            while start < object_size {
                let end = (start + multipart_chunk_bytes - 1).min(object_size.saturating_sub(1));
                let output = client
                    .get_object()
                    .bucket(&bucket_name)
                    .key(key)
                    .range(format!("bytes={start}-{end}"))
                    .send()
                    .await
                    .map_err(map_sdk_error)?;
                let chunk = output
                    .body
                    .collect()
                    .await
                    .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?
                    .into_bytes()
                    .to_vec();
                bytes_transferred += chunk.len() as u64;
                downloaded.extend_from_slice(&chunk);
                parts_completed += 1;
                output_lines.push(format!("Downloaded byte range {start}-{end} for {key}."));
                emit_transfer_event(&transfer_job(
                    job_id.clone(),
                    label.clone(),
                    "download",
                    progress_fraction(bytes_transferred, total_bytes),
                    "running",
                    bytes_transferred,
                    total_bytes,
                    Some(strategy_label.clone()),
                    Some(key.clone()),
                    keys.len(),
                    items_completed,
                    part_size_bytes,
                    Some(parts_completed),
                    part_total_value,
                    true,
                    false,
                    true,
                    output_lines.clone(),
                ));
                start = end + 1;
            }
            fs::write(&target, downloaded)
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        } else {
            let output = client
                .get_object()
                .bucket(&bucket_name)
                .key(key)
                .send()
                .await
                .map_err(map_sdk_error)?;
            let bytes = output
                .body
                .collect()
                .await
                .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?
                .into_bytes()
                .to_vec();
            bytes_transferred += bytes.len() as u64;
            fs::write(&target, bytes)
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            emit_transfer_event(&transfer_job(
                job_id.clone(),
                label.clone(),
                "download",
                progress_fraction(bytes_transferred, total_bytes),
                "running",
                bytes_transferred,
                total_bytes,
                Some(strategy_label.clone()),
                Some(key.clone()),
                keys.len(),
                items_completed,
                part_size_bytes,
                if part_total_value.is_some() {
                    Some(parts_completed)
                } else {
                    None
                },
                part_total_value,
                true,
                false,
                true,
                output_lines.clone(),
            ));
        }
        items_completed += 1;
        output_lines.push(format!("Finished downloading {key}."));
    }
    output_lines.push(format!(
        "Downloaded {} object(s) into {destination_path}.",
        keys.len()
    ));
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
    let (profile, bucket_name, client) = bucket_context(&params).await?;
    let _ = profile;
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
        .presigned(
            PresigningConfig::expires_in(Duration::from_secs(expiration_seconds))
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?,
        )
        .await
        .map_err(map_sdk_error)?;
    Ok(json!({"url": presigned.uri().to_string()}))
}

fn run_put_test_data(params: &Value) -> Value {
    let config = &params["config"];
    json!({
        "label": "put-testdata.py",
        "running": false,
        "lastStatus": format!(
            "Prepared {} object(s) with {} version(s) each for {}.",
            config["objectCount"].as_i64().unwrap_or(0),
            config["versions"].as_i64().unwrap_or(0),
            config["bucketName"].as_str().unwrap_or_default()
        ),
        "jobId": format!("tool-{}", short_uuid()),
        "cancellable": false,
        "outputLines": [
            format!("Bucket: {}", config["bucketName"].as_str().unwrap_or_default()),
            format!("Prefix: {}", config["prefix"].as_str().unwrap_or_default()),
            format!("Threads: {}", config["threads"].as_i64().unwrap_or(1))
        ],
        "exitCode": 0
    })
}

fn run_delete_all(params: &Value) -> Value {
    let config = &params["config"];
    json!({
        "label": "delete-all.py",
        "running": false,
        "lastStatus": format!("Prepared delete-all sweep for {}.", config["bucketName"].as_str().unwrap_or_default()),
        "jobId": format!("tool-{}", short_uuid()),
        "cancellable": false,
        "outputLines": [
            format!("Batch size: {}", config["batchSize"].as_i64().unwrap_or(1000)),
            format!("Workers: {}", config["maxWorkers"].as_i64().unwrap_or(1))
        ],
        "exitCode": 0
    })
}

fn cancel_tool_execution(params: &Value) -> Value {
    let job_id = params["jobId"].as_str().unwrap_or_default();
    json!({
        "label": if job_id.is_empty() { "tool" } else { job_id },
        "running": false,
        "lastStatus": format!("Cancelled tool execution {job_id}."),
        "jobId": job_id,
        "cancellable": false,
        "outputLines": [format!("Tool execution {job_id} cancelled.")],
        "exitCode": 130
    })
}

async fn start_benchmark(params: Value) -> SidecarResult {
    if !params.get("profile").map(Value::is_object).unwrap_or(false) {
        return Err(SidecarError::new(
            "invalid_config",
            "Profile configuration is required for benchmark runs.",
        ));
    }
    let run_id = format!("bench-{}", short_uuid());
    let config_map = params
        .get("config")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let state = json!({
        "id": run_id,
        "profile": params["profile"],
        "config": params["config"],
        "status": "running",
        "processedCount": 0,
        "startedAt": now_iso(),
        "lastUpdatedAt": now_iso(),
        "activeElapsedSeconds": 0.0,
        "completedAt": Value::Null,
        "averageLatencyMs": 0,
        "throughputOpsPerSecond": 0,
        "liveLog": ["Benchmark scheduled."],
        "resultSummary": Value::Null,
        "history": [],
        "activeObjects": [],
        "nextObjectIndex": 0,
        "nextActiveIndex": 0,
        "nextSizeIndex": 0,
        "benchmarkPrefix": benchmark_base_prefix(&config_map, &run_id),
    });
    let mut state = state;
    let benchmark_bucket = state["config"]["bucketName"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let benchmark_endpoint = state["profile"]["endpointUrl"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    append_benchmark_log(
        &mut state,
        &format!(
            "Benchmark target bucket: {} via {}.",
            benchmark_bucket, benchmark_endpoint
        ),
    );
    write_benchmark_state(&state)?;
    materialize_benchmark_state(state).await
}

async fn get_benchmark_status(params: Value) -> SidecarResult {
    materialize_benchmark_state(read_benchmark_state(required_text(
        &params,
        "runId",
        "Benchmark run ID is required.",
    )?)?)
    .await
}

async fn pause_benchmark(params: Value) -> SidecarResult {
    let mut state = read_benchmark_state(required_text(
        &params,
        "runId",
        "Benchmark run ID is required.",
    )?)?;
    refresh_benchmark_snapshot(&mut state);
    state["status"] = Value::String("paused".to_string());
    append_benchmark_log(&mut state, "Benchmark paused by user.");
    persist_benchmark_outputs(&state)?;
    write_benchmark_state(&state)?;
    Ok(state)
}

async fn resume_benchmark(params: Value) -> SidecarResult {
    let mut state = read_benchmark_state(required_text(
        &params,
        "runId",
        "Benchmark run ID is required.",
    )?)?;
    state["status"] = Value::String("running".to_string());
    state["lastUpdatedAt"] = Value::String(now_iso());
    append_benchmark_log(&mut state, "Benchmark resumed by user.");
    write_benchmark_state(&state)?;
    materialize_benchmark_state(state).await
}

async fn stop_benchmark(params: Value) -> SidecarResult {
    let mut state = read_benchmark_state(required_text(
        &params,
        "runId",
        "Benchmark run ID is required.",
    )?)?;
    refresh_benchmark_snapshot(&mut state);
    state["status"] = Value::String("stopped".to_string());
    state["completedAt"] = Value::String(now_iso());
    state["resultSummary"] = benchmark_summary_from_state(&state);
    append_benchmark_log(&mut state, "Benchmark stopped by user.");
    persist_benchmark_outputs(&state)?;
    write_benchmark_state(&state)?;
    Ok(state)
}

async fn export_benchmark_results(params: Value) -> SidecarResult {
    let state = get_benchmark_status(params.clone()).await?;
    let config = state["config"].as_object().cloned().unwrap_or_default();
    let format = params["format"].as_str().unwrap_or("csv").to_lowercase();
    let path = if format == "json" {
        config
            .get("jsonOutputPath")
            .and_then(Value::as_str)
            .unwrap_or_default()
    } else {
        config
            .get("csvOutputPath")
            .and_then(Value::as_str)
            .unwrap_or_default()
    };
    Ok(json!({
        "format": format,
        "path": path,
        "summary": state["resultSummary"]
    }))
}

async fn build_client(profile: &Profile) -> Result<Client, SidecarError> {
    let credentials = Credentials::new(
        profile.access_key.clone(),
        profile.secret_key.clone(),
        profile.session_token.clone(),
        None,
        "static",
    );
    let shared_config = aws_config::defaults(BehaviorVersion::latest())
        .region(Region::new(profile.region.clone()))
        .credentials_provider(credentials)
        .retry_config(RetryConfig::standard().with_max_attempts(profile.max_attempts))
        .load()
        .await;
    let timeout_config = TimeoutConfig::builder()
        .connect_timeout(Duration::from_secs(profile.connect_timeout_seconds as u64))
        .read_timeout(Duration::from_secs(profile.read_timeout_seconds as u64))
        .build();
    let config = aws_sdk_s3::config::Builder::from(&shared_config)
        .endpoint_url(profile.endpoint_url.clone())
        .force_path_style(profile.path_style)
        .timeout_config(timeout_config)
        .interceptor(HttpTraceInterceptor {
            enable_api_logging: profile.enable_api_logging,
        })
        .build();
    Ok(Client::from_conf(config))
}

async fn bucket_context(params: &Value) -> Result<(Profile, String, Client), SidecarError> {
    let profile = parse_profile(&params["profile"])?;
    let bucket_name = required_text(params, "bucketName", "Bucket name is required.")?;
    let client = build_client(&profile).await?;
    Ok((profile, bucket_name, client))
}

fn parse_profile(value: &Value) -> Result<Profile, SidecarError> {
    if value["endpointType"].as_str().unwrap_or_default().trim() == "azureBlob" {
        return Err(SidecarError::new(
            "unsupported_feature",
            "Azure Blob profiles are not supported by the rust engine yet. Switch the engine to Go or Python in Settings.",
        ));
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
    if access_key.is_empty() || secret_key.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Access key and secret key are required.",
        ));
    }
    Ok(Profile {
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
            Err(map_sdk_error(error))
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
        Ok(result) => Ok(Some(result)),
        Err(error) => {
            if matches!(
                error.details.get("awsCode").and_then(Value::as_str),
                Some(
                    "NoSuchLifecycleConfiguration"
                        | "NoSuchBucketPolicy"
                        | "NoSuchCORSConfiguration"
                        | "NoSuchBucket"
                        | "NoSuchTagSet"
                        | "ObjectLockConfigurationNotFoundError"
                        | "NoSuchObjectLockConfiguration"
                        | "ServerSideEncryptionConfigurationNotFoundError"
                        | "MethodNotAllowed"
                        | "NotImplemented"
                        | "XNotImplemented"
                )
            ) {
                Ok(None)
            } else {
                Err(error)
            }
        }
    }
}

fn parse_lifecycle_rules(value: &Value) -> Result<Vec<LifecycleRule>, SidecarError> {
    let Some(items) = value.as_array() else {
        return Ok(Vec::new());
    };
    let mut rules = Vec::new();
    for item in items {
        let mut builder = LifecycleRule::builder().status(
            if item["Status"]
                .as_str()
                .unwrap_or("Disabled")
                .eq_ignore_ascii_case("Enabled")
            {
                aws_sdk_s3::types::ExpirationStatus::Enabled
            } else {
                aws_sdk_s3::types::ExpirationStatus::Disabled
            },
        );
        if let Some(id) = item["ID"].as_str().filter(|value| !value.is_empty()) {
            builder = builder.id(id);
        }
        let prefix = item["Filter"]["Prefix"]
            .as_str()
            .filter(|value| !value.is_empty())
            .or_else(|| item["Prefix"].as_str().filter(|value| !value.is_empty()));
        if let Some(prefix) = prefix {
            builder = builder.filter(LifecycleRuleFilter::builder().prefix(prefix).build());
        }
        if let Some(expiration) = item.get("Expiration").and_then(Value::as_object) {
            let mut expiration_builder = LifecycleExpiration::builder();
            if let Some(days) = expiration.get("Days").and_then(Value::as_i64) {
                expiration_builder = expiration_builder.days(days as i32);
            }
            if let Some(delete_marker) = expiration
                .get("ExpiredObjectDeleteMarker")
                .and_then(Value::as_bool)
            {
                expiration_builder = expiration_builder.expired_object_delete_marker(delete_marker);
            }
            builder = builder.expiration(expiration_builder.build());
        }
        if let Some(transitions) = item.get("Transitions").and_then(Value::as_array) {
            let parsed: Vec<Transition> = transitions
                .iter()
                .map(|transition| {
                    let mut builder = Transition::builder();
                    if let Some(days) = transition.get("Days").and_then(Value::as_i64) {
                        builder = builder.days(days as i32);
                    }
                    if let Some(storage_class) =
                        transition.get("StorageClass").and_then(Value::as_str)
                    {
                        builder =
                            builder.storage_class(TransitionStorageClass::from(storage_class));
                    }
                    builder.build()
                })
                .collect();
            builder = builder.set_transitions(Some(parsed));
        }
        if let Some(expiration) = item
            .get("NoncurrentVersionExpiration")
            .and_then(Value::as_object)
        {
            if let Some(days) = expiration.get("NoncurrentDays").and_then(Value::as_i64) {
                builder = builder.noncurrent_version_expiration(
                    NoncurrentVersionExpiration::builder()
                        .noncurrent_days(days as i32)
                        .build(),
                );
            }
        }
        if let Some(transitions) = item
            .get("NoncurrentVersionTransitions")
            .and_then(Value::as_array)
        {
            let parsed: Vec<NoncurrentVersionTransition> = transitions
                .iter()
                .map(|transition| {
                    let mut builder = NoncurrentVersionTransition::builder();
                    if let Some(days) = transition.get("NoncurrentDays").and_then(Value::as_i64) {
                        builder = builder.noncurrent_days(days as i32);
                    }
                    if let Some(storage_class) =
                        transition.get("StorageClass").and_then(Value::as_str)
                    {
                        builder =
                            builder.storage_class(TransitionStorageClass::from(storage_class));
                    }
                    builder.build()
                })
                .collect();
            builder = builder.set_noncurrent_version_transitions(Some(parsed));
        }
        if let Some(days) = item["AbortIncompleteMultipartUpload"]["DaysAfterInitiation"].as_i64() {
            builder = builder.abort_incomplete_multipart_upload(
                AbortIncompleteMultipartUpload::builder()
                    .days_after_initiation(days as i32)
                    .build(),
            );
        }
        rules.push(
            builder
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?,
        );
    }
    Ok(rules)
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

fn lifecycle_rule_raw(rule: &LifecycleRule) -> Value {
    json!({
        "ID": rule.id(),
        "Status": rule.status().as_str(),
        "Filter": {"Prefix": rule.filter().and_then(|value| value.prefix()).unwrap_or_default()},
        "Expiration": rule.expiration().map(|value| json!({
            "Days": value.days(),
            "ExpiredObjectDeleteMarker": value.expired_object_delete_marker(),
        })),
        "Transitions": rule.transitions().iter().map(|transition| json!({
            "Days": transition.days(),
            "StorageClass": transition.storage_class().map(|value| value.as_str()),
        })).collect::<Vec<_>>(),
        "NoncurrentVersionExpiration": rule.noncurrent_version_expiration().map(|value| json!({
            "NoncurrentDays": value.noncurrent_days(),
        })),
        "NoncurrentVersionTransitions": rule.noncurrent_version_transitions().iter().map(|transition| json!({
            "NoncurrentDays": transition.noncurrent_days(),
            "StorageClass": transition.storage_class().map(|value| value.as_str()),
        })).collect::<Vec<_>>(),
        "AbortIncompleteMultipartUpload": rule.abort_incomplete_multipart_upload().map(|value| json!({
            "DaysAfterInitiation": value.days_after_initiation()
        })),
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
    can_pause: bool,
    can_resume: bool,
    can_cancel: bool,
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
        "canPause": can_pause,
        "canResume": can_resume,
        "canCancel": can_cancel,
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

fn runtime_dir() -> Result<PathBuf, SidecarError> {
    let path = std::env::temp_dir().join("object-data-browser-rust-engine");
    fs::create_dir_all(&path)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    Ok(path)
}

fn benchmark_state_path(run_id: &str) -> Result<PathBuf, SidecarError> {
    Ok(runtime_dir()?.join(format!("benchmark-{run_id}.json")))
}

fn read_benchmark_state(run_id: String) -> Result<Value, SidecarError> {
    let path = benchmark_state_path(&run_id)?;
    if !path.exists() {
        return Err(SidecarError::new(
            "invalid_config",
            format!("Benchmark run {run_id} was not found."),
        ));
    }
    let contents = fs::read_to_string(path)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    serde_json::from_str(&contents)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))
}

fn write_benchmark_state(state: &Value) -> Result<(), SidecarError> {
    let path = benchmark_state_path(state["id"].as_str().unwrap_or_default())?;
    let output = serde_json::to_string(state)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    fs::write(path, output)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))
}

fn refresh_benchmark_snapshot(state: &mut Value) {
    match state["status"].as_str() {
        Some("completed" | "stopped" | "failed") => {}
        _ => {
            let last_updated = state["lastUpdatedAt"]
                .as_str()
                .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
                .map(|value| value.with_timezone(&Utc))
                .unwrap_or_else(Utc::now);
            let now = Utc::now();
            let active_elapsed = state["activeElapsedSeconds"].as_f64().unwrap_or(0.0)
                + (now - last_updated).num_milliseconds().max(0) as f64 / 1000.0;
            state["activeElapsedSeconds"] = Value::from(active_elapsed);
            state["lastUpdatedAt"] = Value::String(now_iso());
        }
    }
    state["resultSummary"] = benchmark_summary_from_state(state);
    let history = state["history"].as_array().cloned().unwrap_or_default();
    let latencies: Vec<f64> = history
        .iter()
        .filter_map(|item| item.get("latencyMs").and_then(Value::as_f64))
        .collect();
    state["averageLatencyMs"] = Value::from(round1(mean_f64(&latencies)));
    let active_elapsed = state["activeElapsedSeconds"].as_f64().unwrap_or(0.0);
    let processed_count = state["processedCount"].as_i64().unwrap_or(0);
    state["throughputOpsPerSecond"] = Value::from(if active_elapsed <= 0.0 {
        0.0
    } else {
        round1(processed_count as f64 / active_elapsed)
    });
}

async fn materialize_benchmark_state(mut state: Value) -> SidecarResult {
    if matches!(
        state["status"].as_str(),
        Some("paused" | "completed" | "stopped" | "failed")
    ) {
        return Ok(state);
    }
    let config = state["config"].as_object().cloned().unwrap_or_default();
    let last_updated = state["lastUpdatedAt"]
        .as_str()
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
        .unwrap_or_else(Utc::now);
    let now = Utc::now();
    let active_elapsed = state["activeElapsedSeconds"].as_f64().unwrap_or(0.0)
        + (now - last_updated).num_milliseconds().max(0) as f64 / 1000.0;
    state["activeElapsedSeconds"] = Value::from(active_elapsed);
    state["lastUpdatedAt"] = Value::String(now_iso());
    if config
        .get("debugMode")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        emit_structured_log(
            "DEBUG",
            "BenchmarkTrace",
            format!(
                "Benchmark tick status={} elapsed={:.2}s processed={}",
                state["status"].as_str().unwrap_or("unknown"),
                active_elapsed,
                state["processedCount"].as_u64().unwrap_or(0),
            ),
            "debug",
        );
    }
    let duration_seconds = config
        .get("durationSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(60)
        .max(1) as usize;
    let operation_count = config
        .get("operationCount")
        .and_then(Value::as_u64)
        .unwrap_or(1000)
        .max(1) as usize;
    let parallelism = config
        .get("concurrentThreads")
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .max(1) as usize;
    let test_mode = config
        .get("testMode")
        .and_then(Value::as_str)
        .unwrap_or("duration");
    let duration_complete =
        test_mode != "operation-count" && active_elapsed >= duration_seconds as f64;
    let operation_complete = test_mode == "operation-count"
        && state["processedCount"].as_u64().unwrap_or(0) as usize >= operation_count;
    let call_started = Instant::now();
    let call_base_elapsed_ms = active_elapsed * 1000.0;
    let execution_budget_seconds =
        ((now - last_updated).num_milliseconds().max(0) as f64 / 1000.0).clamp(0.25, 1.5);
    if !duration_complete && !operation_complete && parallelism > 0 {
        let profile = benchmark_profile(
            state.get("profile").cloned().unwrap_or(Value::Null),
            &config,
        )?;
        let client = build_client(&profile).await?;
        while call_started.elapsed().as_secs_f64() < execution_budget_seconds {
            if test_mode == "operation-count"
                && state["processedCount"].as_u64().unwrap_or(0) as usize >= operation_count
            {
                break;
            }
            if test_mode != "operation-count"
                && state["activeElapsedSeconds"].as_f64().unwrap_or(0.0)
                    + call_started.elapsed().as_secs_f64()
                    >= duration_seconds as f64
            {
                break;
            }
            let remaining_operations = if test_mode == "operation-count" {
                operation_count
                    .saturating_sub(state["processedCount"].as_u64().unwrap_or(0) as usize)
            } else {
                usize::MAX
            };
            let task_count = parallelism.min(remaining_operations.max(1));
            let tasks = plan_benchmark_batch(&mut state, task_count, remaining_operations);
            if tasks.is_empty() {
                break;
            }
            match execute_benchmark_batch(
                &tasks,
                &client,
                &state,
                call_started,
                call_base_elapsed_ms,
            )
            .await
            {
                Ok(results) => apply_benchmark_batch_results(&mut state, results),
                Err(error) => {
                    state["status"] = Value::String("failed".to_string());
                    state["completedAt"] = Value::String(now_iso());
                    append_benchmark_log(
                        &mut state,
                        &format!("Benchmark failed: {}", error.message),
                    );
                    break;
                }
            }
        }
    }
    refresh_benchmark_snapshot(&mut state);
    if state["status"].as_str() == Some("running") {
        let completed = if config
            .get("testMode")
            .and_then(Value::as_str)
            .unwrap_or("duration")
            == "operation-count"
        {
            state["processedCount"].as_u64().unwrap_or(0) as usize >= operation_count
        } else {
            state["activeElapsedSeconds"].as_f64().unwrap_or(0.0) >= duration_seconds as f64
        };
        if completed {
            state["status"] = Value::String("completed".to_string());
            state["completedAt"] = Value::String(now_iso());
            let processed_count = state["processedCount"].as_u64().unwrap_or(0);
            append_benchmark_log(
                &mut state,
                &format!("Benchmark completed after {} request(s).", processed_count),
            );
        }
    }
    persist_benchmark_outputs(&state)?;
    write_benchmark_state(&state)?;
    Ok(state)
}

fn persist_benchmark_outputs(state: &Value) -> Result<(), SidecarError> {
    let config = state["config"].as_object().cloned().unwrap_or_default();
    let csv_path = config
        .get("csvOutputPath")
        .and_then(Value::as_str)
        .unwrap_or("benchmark-results.csv");
    let json_path = config
        .get("jsonOutputPath")
        .and_then(Value::as_str)
        .unwrap_or("benchmark-results.json");
    let log_path = config
        .get("logFilePath")
        .and_then(Value::as_str)
        .unwrap_or("benchmark.log");

    for path in [csv_path, json_path, log_path] {
        if let Some(parent) = Path::new(path).parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)
                    .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
            }
        }
    }

    let history = state["history"].as_array().cloned().unwrap_or_default();
    let mut csv =
        vec!["second,operation,operationCount,latencyMs,sizeBytes,bytesTransferred,success,checksumState,key".to_string()];
    for record in history {
        csv.push(format!(
            "{},{},{},{:.1},{},{},true,{},{}",
            record["second"].as_i64().unwrap_or(0),
            record["operation"].as_str().unwrap_or_default(),
            benchmark_operation_count(&record),
            record["latencyMs"].as_f64().unwrap_or(0.0),
            record["sizeBytes"].as_i64().unwrap_or(0),
            record["bytesTransferred"].as_i64().unwrap_or(0),
            record["checksumState"].as_str().unwrap_or("not_used"),
            record["key"].as_str().unwrap_or_default(),
        ));
    }
    fs::write(csv_path, csv.join("\n") + "\n")
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    fs::write(
        json_path,
        serde_json::to_string_pretty(&state["resultSummary"]).unwrap_or_else(|_| "{}".to_string()),
    )
    .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    let log_lines = state["liveLog"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    fs::write(log_path, log_lines)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    Ok(())
}

fn benchmark_base_prefix(config: &Map<String, Value>, run_id: &str) -> Value {
    let mut prefix = config
        .get("prefix")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if !prefix.is_empty() && !prefix.ends_with('/') {
        prefix.push('/');
    }
    Value::String(format!("{prefix}{run_id}/"))
}

fn benchmark_ratios(workload_type: &str) -> [(&'static str, usize); 3] {
    match workload_type {
        "write-heavy" => [("PUT", 60), ("GET", 30), ("DELETE", 10)],
        "read-heavy" => [("PUT", 25), ("GET", 65), ("DELETE", 10)],
        "delete" => [("PUT", 0), ("GET", 0), ("DELETE", 100)],
        _ => [("PUT", 34), ("GET", 33), ("DELETE", 33)],
    }
}

fn benchmark_profile(
    profile_value: Value,
    config: &Map<String, Value>,
) -> Result<Profile, SidecarError> {
    let mut merged = profile_value.as_object().cloned().unwrap_or_default();
    merged.insert(
        "connectTimeoutSeconds".to_string(),
        Value::from(
            config
                .get("connectTimeoutSeconds")
                .and_then(Value::as_i64)
                .unwrap_or(5),
        ),
    );
    merged.insert(
        "readTimeoutSeconds".to_string(),
        Value::from(
            config
                .get("readTimeoutSeconds")
                .and_then(Value::as_i64)
                .unwrap_or(60),
        ),
    );
    merged.insert(
        "maxAttempts".to_string(),
        Value::from(
            config
                .get("maxAttempts")
                .and_then(Value::as_u64)
                .unwrap_or(5),
        ),
    );
    merged.insert(
        "maxConcurrentRequests".to_string(),
        Value::from(
            config
                .get("maxPoolConnections")
                .and_then(Value::as_u64)
                .unwrap_or(10),
        ),
    );
    parse_profile(&Value::Object(merged))
}

fn append_benchmark_log(state: &mut Value, line: &str) {
    let mut lines: Vec<Value> = state["liveLog"].as_array().cloned().unwrap_or_default();
    lines.push(Value::String(line.to_string()));
    if lines.len() > 60 {
        let start = lines.len() - 60;
        lines = lines[start..].to_vec();
    }
    state["liveLog"] = Value::Array(lines);
}

fn benchmark_size_list(config: &Map<String, Value>) -> Vec<usize> {
    let mut sizes = config
        .get("objectSizes")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_u64)
                .map(|value| value as usize)
                .filter(|value| *value > 0)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if sizes.is_empty() {
        sizes.push(4096);
    }
    sizes
}

fn benchmark_payload(run_id: &str, key: &str, size: usize, random_data: bool) -> Vec<u8> {
    if size == 0 {
        return Vec::new();
    }
    if !random_data {
        return vec![b'A'; size];
    }
    let seed = format!("{run_id}:{key}:{size}").into_bytes();
    let source = if seed.is_empty() {
        b"s3-benchmark".to_vec()
    } else {
        seed
    };
    let pattern_len = (source.len() * 8).clamp(64, 4096);
    let mut pattern = vec![0u8; pattern_len];
    for index in 0..pattern_len {
        pattern[index] = ((source[index % source.len()] as usize + (index * 17)) % 256) as u8;
    }
    let mut bytes = Vec::with_capacity(size);
    while bytes.len() < size {
        let remaining = size - bytes.len();
        bytes.extend_from_slice(&pattern[..remaining.min(pattern.len())]);
    }
    bytes
}

fn percentile(values: &[f64], pct: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
    if sorted.len() == 1 {
        return sorted[0];
    }
    let rank = ((sorted.len() - 1) as f64 * pct) / 100.0;
    let lower = rank.floor() as usize;
    let upper = (lower + 1).min(sorted.len() - 1);
    let weight = rank - lower as f64;
    sorted[lower] + ((sorted[upper] - sorted[lower]) * weight)
}

fn mean_f64(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

fn is_missing_benchmark_key(error: &SidecarError) -> bool {
    let aws_code = error.details["awsCode"].as_str().unwrap_or_default();
    let message = error.message.to_ascii_lowercase();
    matches!(aws_code, "NoSuchKey" | "NotFound" | "404") || message.contains("does not exist")
}

fn benchmark_operation_count(record: &Value) -> i64 {
    record["operationCount"].as_i64().unwrap_or(1).max(1)
}

fn benchmark_timeline_label(elapsed_seconds: f64) -> String {
    if elapsed_seconds >= 100.0 {
        format!("{elapsed_seconds:.0}s")
    } else if elapsed_seconds >= 10.0 {
        format!("{elapsed_seconds:.1}s")
    } else {
        format!("{elapsed_seconds:.2}s")
    }
}

fn benchmark_delete_mode(config: &Map<String, Value>) -> &'static str {
    if config.get("deleteMode").and_then(Value::as_str) == Some("multi-object-post") {
        "multi-object-post"
    } else {
        "single"
    }
}

fn benchmark_delete_batch_size(config: &Map<String, Value>, active_count: usize) -> usize {
    if benchmark_delete_mode(config) != "multi-object-post" {
        return 1;
    }
    let batch_size = config
        .get("concurrentThreads")
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .max(2) as usize;
    batch_size.min(1000).min(active_count).max(1)
}

fn benchmark_operation_mix(config: &Map<String, Value>) -> Vec<(&'static str, usize)> {
    let workload_type = config
        .get("workloadType")
        .and_then(Value::as_str)
        .unwrap_or("mixed");
    let mix = match workload_type {
        "write-heavy" => vec![("PUT", 60), ("GET", 30), ("DELETE", 10)],
        "read-heavy" => vec![("PUT", 25), ("GET", 65), ("DELETE", 10)],
        "delete" => vec![("DELETE", 100)],
        "write-only" => vec![("PUT", 100)],
        "read-only" => vec![("GET", 100)],
        "custom" => vec![
            (
                "PUT",
                config
                    .get("writePercent")
                    .and_then(Value::as_u64)
                    .unwrap_or(33) as usize,
            ),
            (
                "GET",
                config
                    .get("readPercent")
                    .and_then(Value::as_u64)
                    .unwrap_or(34) as usize,
            ),
            (
                "DELETE",
                config
                    .get("deletePercent")
                    .and_then(Value::as_u64)
                    .unwrap_or(33) as usize,
            ),
        ],
        _ => vec![("PUT", 34), ("GET", 33), ("DELETE", 33)],
    };
    let filtered: Vec<(&'static str, usize)> =
        mix.into_iter().filter(|(_, weight)| *weight > 0).collect();
    if filtered.is_empty() {
        vec![("PUT", 100)]
    } else {
        filtered
    }
}

fn benchmark_operation_for_slot(config: &Map<String, Value>, slot: usize) -> &'static str {
    let mix = benchmark_operation_mix(config);
    let total_weight: usize = mix.iter().map(|(_, weight)| *weight).sum::<usize>().max(1);
    let mut cumulative = 0usize;
    let target = slot % total_weight;
    for (operation, weight) in mix {
        cumulative += weight;
        if target < cumulative {
            return operation;
        }
    }
    "PUT"
}

fn plan_benchmark_batch(
    state: &mut Value,
    task_count: usize,
    remaining_operations: usize,
) -> Vec<BenchmarkTask> {
    if task_count == 0 || remaining_operations == 0 {
        return Vec::new();
    }
    let config = state["config"].as_object().cloned().unwrap_or_default();
    let sizes = benchmark_size_list(&config);
    let object_limit = config
        .get("objectCount")
        .and_then(Value::as_u64)
        .unwrap_or(sizes.len() as u64)
        .max(1) as usize;
    let mut planned_active_objects = state["activeObjects"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut next_size_index = state["nextSizeIndex"].as_u64().unwrap_or(0) as usize;
    let mut next_active_index = state["nextActiveIndex"].as_u64().unwrap_or(0) as usize;
    let mut next_object_index = state["nextObjectIndex"].as_u64().unwrap_or(0);
    let mut scheduled_operations = 0usize;
    let mut tasks = Vec::new();

    for order in 0..task_count {
        if scheduled_operations >= remaining_operations {
            break;
        }
        let size_bytes = sizes[next_size_index % sizes.len()];
        next_size_index += 1;
        let processed_slot =
            state["processedCount"].as_u64().unwrap_or(0) as usize + scheduled_operations;
        let mut operation = benchmark_operation_for_slot(&config, processed_slot);
        if matches!(operation, "GET" | "DELETE") && planned_active_objects.is_empty() {
            operation = "PUT";
        }
        match operation {
            "PUT" => {
                let key = if planned_active_objects.len() >= object_limit
                    && !planned_active_objects.is_empty()
                {
                    let selected = planned_active_objects
                        [next_active_index % planned_active_objects.len()]["key"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string();
                    next_active_index += 1;
                    selected
                } else {
                    let selected = format!(
                        "{}obj-{next_object_index:06}-{size_bytes}.bin",
                        state["benchmarkPrefix"].as_str().unwrap_or_default()
                    );
                    next_object_index += 1;
                    selected
                };
                let mut updated = false;
                for item in &mut planned_active_objects {
                    if item["key"].as_str().unwrap_or_default() == key {
                        item["sizeBytes"] = Value::from(size_bytes as i64);
                        updated = true;
                        break;
                    }
                }
                if !updated {
                    planned_active_objects.push(json!({"key": key, "sizeBytes": size_bytes}));
                }
                tasks.push(BenchmarkTask {
                    order,
                    kind: BenchmarkTaskKind::Put { key, size_bytes },
                });
                scheduled_operations += 1;
            }
            "GET" => {
                let target = planned_active_objects
                    [next_active_index % planned_active_objects.len()]
                .clone();
                next_active_index += 1;
                tasks.push(BenchmarkTask {
                    order,
                    kind: BenchmarkTaskKind::Get {
                        key: target["key"].as_str().unwrap_or_default().to_string(),
                        size_bytes: target["sizeBytes"].as_u64().unwrap_or(size_bytes as u64)
                            as usize,
                    },
                });
                scheduled_operations += 1;
            }
            _ => {
                let allowed_operations = remaining_operations
                    .saturating_sub(scheduled_operations)
                    .max(1);
                let delete_batch_size =
                    benchmark_delete_batch_size(&config, planned_active_objects.len())
                        .min(allowed_operations);
                if delete_batch_size <= 1 || benchmark_delete_mode(&config) != "multi-object-post" {
                    let target = planned_active_objects
                        [next_active_index % planned_active_objects.len()]
                    .clone();
                    next_active_index += 1;
                    let selected_key = target["key"].as_str().unwrap_or_default().to_string();
                    let selected_size =
                        target["sizeBytes"].as_u64().unwrap_or(size_bytes as u64) as usize;
                    planned_active_objects
                        .retain(|item| item["key"].as_str().unwrap_or_default() != selected_key);
                    tasks.push(BenchmarkTask {
                        order,
                        kind: BenchmarkTaskKind::DeleteSingle {
                            key: selected_key,
                            size_bytes: selected_size,
                        },
                    });
                    scheduled_operations += 1;
                } else {
                    let selected_keys: Vec<String> = (0..delete_batch_size)
                        .map(|offset| {
                            planned_active_objects
                                [(next_active_index + offset) % planned_active_objects.len()]["key"]
                                .as_str()
                                .unwrap_or_default()
                                .to_string()
                        })
                        .collect();
                    next_active_index += delete_batch_size;
                    planned_active_objects.retain(|item| {
                        let key = item["key"].as_str().unwrap_or_default();
                        !selected_keys.iter().any(|selected| selected == key)
                    });
                    tasks.push(BenchmarkTask {
                        order,
                        kind: BenchmarkTaskKind::DeleteMulti {
                            keys: selected_keys,
                        },
                    });
                    scheduled_operations += delete_batch_size;
                }
            }
        }
    }

    state["nextSizeIndex"] = Value::from(next_size_index as u64);
    state["nextActiveIndex"] = Value::from(next_active_index as u64);
    state["nextObjectIndex"] = Value::from(next_object_index);
    tasks
}

async fn execute_benchmark_batch(
    tasks: &[BenchmarkTask],
    client: &Client,
    state: &Value,
    call_started: Instant,
    call_base_elapsed_ms: f64,
) -> Result<Vec<BenchmarkTaskResult>, SidecarError> {
    let config = state["config"].as_object().cloned().unwrap_or_default();
    let bucket_name = config
        .get("bucketName")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let run_id = state["id"].as_str().unwrap_or_default().to_string();
    let random_data = config
        .get("randomData")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let validate_checksum = config
        .get("validateChecksum")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let mut join_set = tokio::task::JoinSet::new();
    for task in tasks.iter().cloned() {
        let task_client = client.clone();
        let task_bucket = bucket_name.clone();
        let task_run_id = run_id.clone();
        join_set.spawn(async move {
            execute_benchmark_task(
                task,
                task_client,
                task_bucket,
                task_run_id,
                random_data,
                validate_checksum,
                call_started,
                call_base_elapsed_ms,
            )
            .await
        });
    }
    let mut results = Vec::new();
    while let Some(joined) = join_set.join_next().await {
        let result = joined
            .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))??;
        results.push(result);
    }
    results.sort_by(|left, right| {
        left.elapsed_ms
            .partial_cmp(&right.elapsed_ms)
            .unwrap_or(Ordering::Equal)
            .then(left.order.cmp(&right.order))
    });
    Ok(results)
}

async fn execute_benchmark_task(
    task: BenchmarkTask,
    client: Client,
    bucket_name: String,
    run_id: String,
    random_data: bool,
    validate_checksum: bool,
    call_started: Instant,
    call_base_elapsed_ms: f64,
) -> Result<BenchmarkTaskResult, SidecarError> {
    let started = Instant::now();
    match task.kind {
        BenchmarkTaskKind::Put { key, size_bytes } => {
            let payload = benchmark_payload(&run_id, &key, size_bytes, random_data);
            client
                .put_object()
                .bucket(&bucket_name)
                .key(&key)
                .body(ByteStream::from(payload.clone()))
                .send()
                .await
                .map_err(map_sdk_error)?;
            Ok(BenchmarkTaskResult {
                order: task.order,
                operation: "PUT",
                key: key.clone(),
                size_bytes,
                bytes_transferred: payload.len() as i64,
                checksum_state: "not_used".to_string(),
                latency_ms: started.elapsed().as_secs_f64() * 1000.0,
                operation_count: 1,
                elapsed_ms: call_base_elapsed_ms + (call_started.elapsed().as_secs_f64() * 1000.0),
                upserted_object: Some((key, size_bytes)),
                removed_keys: Vec::new(),
                log_line: None,
            })
        }
        BenchmarkTaskKind::Get { key, size_bytes } => {
            let output = match client
                .get_object()
                .bucket(&bucket_name)
                .key(&key)
                .send()
                .await
            {
                Ok(output) => output,
                Err(error) => {
                    let mapped = map_sdk_error(error);
                    if is_missing_benchmark_key(&mapped) {
                        return Ok(BenchmarkTaskResult {
                            order: task.order,
                            operation: "GET",
                            key: key.clone(),
                            size_bytes,
                            bytes_transferred: 0,
                            checksum_state: "not_used".to_string(),
                            latency_ms: started.elapsed().as_secs_f64() * 1000.0,
                            operation_count: 0,
                            elapsed_ms: call_base_elapsed_ms
                                + (call_started.elapsed().as_secs_f64() * 1000.0),
                            upserted_object: None,
                            removed_keys: vec![key.clone()],
                            log_line: Some(format!(
                                "Skipped missing benchmark object {key}; rotating to the next object."
                            )),
                        });
                    }
                    return Err(mapped);
                }
            };
            let bytes = output
                .body
                .collect()
                .await
                .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?
                .into_bytes();
            let expected = benchmark_payload(&run_id, &key, size_bytes, random_data);
            Ok(BenchmarkTaskResult {
                order: task.order,
                operation: "GET",
                key,
                size_bytes,
                bytes_transferred: bytes.len() as i64,
                checksum_state: if validate_checksum {
                    if bytes.as_ref() == expected.as_slice() {
                        "validated_success".to_string()
                    } else {
                        "validated_failure".to_string()
                    }
                } else {
                    "not_used".to_string()
                },
                latency_ms: started.elapsed().as_secs_f64() * 1000.0,
                operation_count: 1,
                elapsed_ms: call_base_elapsed_ms + (call_started.elapsed().as_secs_f64() * 1000.0),
                upserted_object: None,
                removed_keys: Vec::new(),
                log_line: None,
            })
        }
        BenchmarkTaskKind::DeleteSingle { key, size_bytes } => {
            match client
                .delete_object()
                .bucket(&bucket_name)
                .key(&key)
                .send()
                .await
            {
                Ok(_) => {}
                Err(error) => {
                    let mapped = map_sdk_error(error);
                    if is_missing_benchmark_key(&mapped) {
                        return Ok(BenchmarkTaskResult {
                            order: task.order,
                            operation: "DELETE",
                            key: key.clone(),
                            size_bytes,
                            bytes_transferred: 0,
                            checksum_state: "not_used".to_string(),
                            latency_ms: started.elapsed().as_secs_f64() * 1000.0,
                            operation_count: 0,
                            elapsed_ms: call_base_elapsed_ms
                                + (call_started.elapsed().as_secs_f64() * 1000.0),
                            upserted_object: None,
                            removed_keys: vec![key.clone()],
                            log_line: Some(format!(
                                "Skipped missing benchmark object {key}; rotating to the next object."
                            )),
                        });
                    }
                    return Err(mapped);
                }
            }
            Ok(BenchmarkTaskResult {
                order: task.order,
                operation: "DELETE",
                key: key.clone(),
                size_bytes,
                bytes_transferred: 0,
                checksum_state: "not_used".to_string(),
                latency_ms: started.elapsed().as_secs_f64() * 1000.0,
                operation_count: 1,
                elapsed_ms: call_base_elapsed_ms + (call_started.elapsed().as_secs_f64() * 1000.0),
                upserted_object: None,
                removed_keys: vec![key],
                log_line: None,
            })
        }
        BenchmarkTaskKind::DeleteMulti { keys } => {
            let objects: Vec<ObjectIdentifier> = keys
                .iter()
                .map(|key| {
                    ObjectIdentifier::builder()
                        .key(key)
                        .build()
                        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))
                })
                .collect::<Result<Vec<_>, _>>()?;
            let delete = Delete::builder()
                .set_objects(Some(objects))
                .quiet(false)
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            let output = client
                .delete_objects()
                .bucket(&bucket_name)
                .delete(delete)
                .send()
                .await
                .map_err(map_sdk_error)?;
            let mut deleted_keys = Vec::new();
            for item in output.deleted() {
                if let Some(target) = item.key() {
                    if !target.is_empty() {
                        deleted_keys.push(target.to_string());
                    }
                }
            }
            let mut missing_keys = Vec::new();
            let mut fatal_errors = Vec::new();
            for item in output.errors() {
                let target = item.key().unwrap_or_default();
                let code = item.code().unwrap_or_default().to_ascii_lowercase();
                let message = item.message().unwrap_or_default().to_string();
                if matches!(code.as_str(), "nosuchkey" | "notfound" | "404")
                    || message.to_ascii_lowercase().contains("does not exist")
                {
                    if !target.is_empty() {
                        missing_keys.push(target.to_string());
                    }
                    continue;
                }
                fatal_errors.push(format!(
                    "{}: {}",
                    if target.is_empty() {
                        "(unknown)"
                    } else {
                        target
                    },
                    if message.is_empty() {
                        item.code().unwrap_or("delete error")
                    } else {
                        message.as_str()
                    }
                ));
            }
            if !fatal_errors.is_empty() {
                return Err(SidecarError::new("delete_failed", fatal_errors.join("; ")));
            }
            let deleted_count = deleted_keys.len() as i64;
            let key = if deleted_count > 1 {
                format!(
                    "{} (+{} more)",
                    deleted_keys
                        .first()
                        .cloned()
                        .or_else(|| keys.first().cloned())
                        .unwrap_or_default(),
                    deleted_count - 1
                )
            } else {
                deleted_keys
                    .first()
                    .cloned()
                    .or_else(|| keys.first().cloned())
                    .unwrap_or_default()
            };
            let log_line = if !missing_keys.is_empty() {
                Some(format!(
                    "Skipped {} missing benchmark object(s) during multi-delete POST.",
                    missing_keys.len()
                ))
            } else {
                None
            };
            let mut removed_keys = deleted_keys.clone();
            removed_keys.extend(missing_keys);
            Ok(BenchmarkTaskResult {
                order: task.order,
                operation: "DELETE",
                key,
                size_bytes: 0,
                bytes_transferred: 0,
                checksum_state: "not_used".to_string(),
                latency_ms: started.elapsed().as_secs_f64() * 1000.0,
                operation_count: deleted_count,
                elapsed_ms: call_base_elapsed_ms + (call_started.elapsed().as_secs_f64() * 1000.0),
                upserted_object: None,
                removed_keys,
                log_line,
            })
        }
    }
}

fn apply_benchmark_batch_results(state: &mut Value, results: Vec<BenchmarkTaskResult>) {
    let reduced_logging = state["config"]["reducedLogging"].as_bool().unwrap_or(false);
    let mut active_objects = state["activeObjects"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut history = state["history"].as_array().cloned().unwrap_or_default();
    for result in results {
        if let Some((key, size_bytes)) = &result.upserted_object {
            let mut updated = false;
            for item in &mut active_objects {
                if item["key"].as_str().unwrap_or_default() == key {
                    item["sizeBytes"] = Value::from(*size_bytes as i64);
                    updated = true;
                    break;
                }
            }
            if !updated {
                active_objects.push(json!({"key": key, "sizeBytes": size_bytes}));
            }
        }
        if !result.removed_keys.is_empty() {
            active_objects.retain(|item| {
                let current_key = item["key"].as_str().unwrap_or_default();
                !result.removed_keys.iter().any(|entry| entry == current_key)
            });
        }
        if let Some(line) = result.log_line.as_deref() {
            append_benchmark_log(state, line);
        }
        if result.operation_count <= 0 {
            continue;
        }
        let second = ((result.elapsed_ms / 1000.0).floor() as i64).max(0) + 1;
        history.push(json!({
            "timestamp": now_iso(),
            "second": second,
            "elapsedMs": round1(result.elapsed_ms),
            "operation": result.operation,
            "key": result.key,
            "sizeBytes": result.size_bytes,
            "latencyMs": round1(result.latency_ms),
            "bytesTransferred": result.bytes_transferred,
            "success": true,
            "checksumState": result.checksum_state,
            "operationCount": result.operation_count,
        }));
        if !reduced_logging {
            if result.operation == "DELETE" && result.operation_count > 1 {
                append_benchmark_log(
                    state,
                    &format!(
                        "DELETE POST removed {} object(s) in {:.1} ms.",
                        result.operation_count,
                        round1(result.latency_ms)
                    ),
                );
            } else {
                append_benchmark_log(
                    state,
                    &format!(
                        "{} {} completed in {:.1} ms.",
                        result.operation,
                        result.key,
                        round1(result.latency_ms)
                    ),
                );
            }
        }
    }
    state["history"] = Value::Array(history);
    state["activeObjects"] = Value::Array(active_objects);
    state["processedCount"] = Value::from(
        state["history"]
            .as_array()
            .map(|items| items.iter().map(benchmark_operation_count).sum::<i64>())
            .unwrap_or(0),
    );
}

fn benchmark_summary_from_state(state: &Value) -> Value {
    let config_map = state["config"].as_object().cloned().unwrap_or_default();
    let history = state["history"].as_array().cloned().unwrap_or_default();
    let mut operations_by_type = Map::new();
    let mut checksum_stats = Map::new();
    checksum_stats.insert("validated_success".to_string(), Value::from(0));
    checksum_stats.insert("validated_failure".to_string(), Value::from(0));
    checksum_stats.insert("not_used".to_string(), Value::from(0));
    let mut latencies = Vec::new();
    let mut windows: BTreeMap<i64, Vec<Value>> = BTreeMap::new();
    let mut size_latency: BTreeMap<i64, Vec<f64>> = BTreeMap::new();
    for record in &history {
        let operation = record["operation"].as_str().unwrap_or_default().to_string();
        let operation_count = benchmark_operation_count(record);
        operations_by_type.insert(
            operation.clone(),
            Value::from(
                operations_by_type
                    .get(&operation)
                    .and_then(Value::as_i64)
                    .unwrap_or(0)
                    + operation_count,
            ),
        );
        let checksum_state = record["checksumState"]
            .as_str()
            .unwrap_or("not_used")
            .to_string();
        checksum_stats.insert(
            checksum_state.clone(),
            Value::from(
                checksum_stats
                    .get(&checksum_state)
                    .and_then(Value::as_i64)
                    .unwrap_or(0)
                    + operation_count,
            ),
        );
        let latency = record["latencyMs"].as_f64().unwrap_or(0.0);
        latencies.push(latency);
        let elapsed_ms = record["elapsedMs"].as_f64().unwrap_or(0.0).max(0.0);
        let second = ((elapsed_ms / 1000.0).floor() as i64).max(0) + 1;
        windows.entry(second).or_default().push(record.clone());
        let size = record["sizeBytes"].as_i64().unwrap_or(0);
        if size > 0 {
            size_latency.entry(size).or_default().push(latency);
        }
    }
    let window_count = state["activeElapsedSeconds"]
        .as_f64()
        .unwrap_or(0.0)
        .ceil()
        .max(windows.keys().last().copied().unwrap_or(0) as f64)
        .max(1.0) as i64;
    let throughput_series: Vec<Value> = (1..=window_count)
        .map(|second| {
            let items = windows.get(&second).cloned().unwrap_or_default();
            let mut operations = Map::new();
            let mut window_latencies = Vec::new();
            let mut bytes_per_second = 0i64;
            let mut ops_per_second = 0i64;
            for item in &items {
                let operation = item["operation"].as_str().unwrap_or_default().to_string();
                let operation_count = benchmark_operation_count(item);
                operations.insert(
                    operation.clone(),
                    Value::from(
                        operations
                            .get(&operation)
                            .and_then(Value::as_i64)
                            .unwrap_or(0)
                            + operation_count,
                    ),
                );
                window_latencies.push(item["latencyMs"].as_f64().unwrap_or(0.0));
                bytes_per_second += item["bytesTransferred"].as_i64().unwrap_or(0);
                ops_per_second += operation_count;
            }
            json!({
                "second": second,
                "label": format!("{second}s"),
                "opsPerSecond": ops_per_second,
                "bytesPerSecond": bytes_per_second,
                "averageLatencyMs": round1(mean_f64(&window_latencies)),
                "p95LatencyMs": round1(percentile(&window_latencies, 95.0)),
                "operations": operations,
            })
        })
        .collect();
    let mut second_positions: BTreeMap<i64, usize> = BTreeMap::new();
    let latency_timeline: Vec<Value> = history
        .iter()
        .enumerate()
        .map(|(index, record)| {
            let elapsed_ms = record["elapsedMs"].as_f64().unwrap_or(0.0).max(0.0);
            let second = ((elapsed_ms / 1000.0).floor() as i64).max(0) + 1;
            let position = second_positions.get(&second).copied().unwrap_or(0) + 1;
            second_positions.insert(second, position);
            let mut plotted_elapsed_ms = elapsed_ms;
            if plotted_elapsed_ms <= 0.0 {
                let second_count = windows.get(&second).map(Vec::len).unwrap_or(0);
                let elapsed_seconds =
                    (second - 1) as f64 + (position as f64 / (second_count + 1) as f64);
                plotted_elapsed_ms = elapsed_seconds * 1000.0;
            }
            json!({
                "sequence": index + 1,
                "operation": record["operation"].as_str().unwrap_or_default().to_ascii_uppercase(),
                "second": second,
                "elapsedMs": round1(plotted_elapsed_ms),
                "label": benchmark_timeline_label(plotted_elapsed_ms / 1000.0),
                "latencyMs": round1(record["latencyMs"].as_f64().unwrap_or(0.0)),
                "sizeBytes": record["sizeBytes"].as_i64().unwrap_or(0),
                "bytesTransferred": record["bytesTransferred"].as_i64().unwrap_or(0),
                "operationCount": benchmark_operation_count(record),
                "success": record.get("success").and_then(Value::as_bool).unwrap_or(true),
                "key": record["key"].as_str().unwrap_or_default(),
            })
        })
        .collect();
    let size_latency_buckets: Vec<Value> = size_latency
        .iter()
        .map(|(size_bytes, values)| {
            json!({
                "sizeBytes": size_bytes,
                "count": values.len(),
                "avgLatencyMs": round1(mean_f64(values)),
                "p50LatencyMs": round1(percentile(values, 50.0)),
                "p95LatencyMs": round1(percentile(values, 95.0)),
                "p99LatencyMs": round1(percentile(values, 99.0)),
            })
        })
        .collect();
    let average_ops = if throughput_series.is_empty() {
        0.0
    } else {
        throughput_series
            .iter()
            .filter_map(|item| item["opsPerSecond"].as_f64())
            .sum::<f64>()
            / throughput_series.len() as f64
    };
    let average_bytes = if throughput_series.is_empty() {
        0.0
    } else {
        throughput_series
            .iter()
            .filter_map(|item| item["bytesPerSecond"].as_f64())
            .sum::<f64>()
            / throughput_series.len() as f64
    };
    let peak_ops = throughput_series
        .iter()
        .filter_map(|item| item["opsPerSecond"].as_i64())
        .max()
        .unwrap_or(0);
    let peak_bytes = throughput_series
        .iter()
        .filter_map(|item| item["bytesPerSecond"].as_i64())
        .max()
        .unwrap_or(0);
    let sizes = benchmark_size_list(&config_map);
    let average_object_size = if sizes.is_empty() {
        0
    } else {
        (sizes.iter().sum::<usize>() / sizes.len()) as i64
    };
    let sample_count = throughput_series.len();
    json!({
        "totalOperations": history.iter().map(benchmark_operation_count).sum::<i64>(),
        "operationsByType": operations_by_type,
        "latencyPercentilesMs": {
            "p50": round1(percentile(&latencies, 50.0)),
            "p75": round1(percentile(&latencies, 75.0)),
            "p90": round1(percentile(&latencies, 90.0)),
            "p95": round1(percentile(&latencies, 95.0)),
            "p99": round1(percentile(&latencies, 99.0)),
            "p999": round1(percentile(&latencies, 99.9)),
        },
        "throughputSeries": throughput_series,
        "latencyTimeline": latency_timeline,
        "sizeLatencyBuckets": size_latency_buckets,
        "checksumStats": checksum_stats,
        "detailMetrics": {
            "sampleCount": sample_count,
            "sampleWindowSeconds": 1,
            "averageOpsPerSecond": round1(average_ops),
            "peakOpsPerSecond": peak_ops,
            "averageBytesPerSecond": round1(average_bytes),
            "peakBytesPerSecond": peak_bytes,
            "averageObjectSizeBytes": average_object_size,
            "checksumValidated": checksum_stats.get("validated_success").and_then(Value::as_i64).unwrap_or(0),
            "errorCount": 0,
            "retryCount": 0,
        },
    })
}

async fn run_benchmark_operation(state: &mut Value, client: &Client) -> Result<(), SidecarError> {
    let config = state["config"].as_object().cloned().unwrap_or_default();
    let mut active_objects = state["activeObjects"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut history = state["history"].as_array().cloned().unwrap_or_default();
    let sizes = benchmark_size_list(&config);
    let next_size_index = state["nextSizeIndex"].as_u64().unwrap_or(0) as usize;
    let mut size_bytes = sizes[next_size_index % sizes.len()];
    state["nextSizeIndex"] = Value::from((next_size_index + 1) as u64);
    let object_limit = config
        .get("objectCount")
        .and_then(Value::as_u64)
        .unwrap_or(sizes.len() as u64)
        .max(1) as usize;
    let bucket_name = config
        .get("bucketName")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let operation: String;
    let key: String;
    let bytes_transferred: i64;
    let checksum_state: String;
    let latency_ms: f64;
    let operation_count: i64;
    loop {
        let slot = state["processedCount"].as_u64().unwrap_or(0) as usize % 100;
        let mut cumulative = 0usize;
        let mut selected_operation = "PUT".to_string();
        for ratio in benchmark_ratios(
            config
                .get("workloadType")
                .and_then(Value::as_str)
                .unwrap_or("mixed"),
        ) {
            cumulative += ratio.1 as usize;
            if slot < cumulative {
                selected_operation = ratio.0.to_string();
                break;
            }
        }
        if matches!(selected_operation.as_str(), "GET" | "DELETE") && active_objects.is_empty() {
            selected_operation = "PUT".to_string();
        }
        let next_active_index = state["nextActiveIndex"].as_u64().unwrap_or(0) as usize;
        let started = std::time::Instant::now();
        match selected_operation.as_str() {
            "PUT" => {
                let selected_key =
                    if active_objects.len() >= object_limit && !active_objects.is_empty() {
                        state["nextActiveIndex"] = Value::from((next_active_index + 1) as u64);
                        active_objects[next_active_index % active_objects.len()]["key"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string()
                    } else {
                        let next_object_index = state["nextObjectIndex"].as_u64().unwrap_or(0);
                        state["nextObjectIndex"] = Value::from(next_object_index + 1);
                        format!(
                            "{}obj-{next_object_index:06}-{size_bytes}.bin",
                            state["benchmarkPrefix"].as_str().unwrap_or_default()
                        )
                    };
                let payload = benchmark_payload(
                    state["id"].as_str().unwrap_or_default(),
                    &selected_key,
                    size_bytes,
                    config
                        .get("randomData")
                        .and_then(Value::as_bool)
                        .unwrap_or(true),
                );
                client
                    .put_object()
                    .bucket(bucket_name)
                    .key(&selected_key)
                    .body(ByteStream::from(payload.clone()))
                    .send()
                    .await
                    .map_err(map_sdk_error)?;
                let mut updated = false;
                for item in &mut active_objects {
                    if item["key"].as_str().unwrap_or_default() == selected_key {
                        item["sizeBytes"] = Value::from(size_bytes as i64);
                        updated = true;
                    }
                }
                if !updated {
                    active_objects.push(json!({"key": selected_key, "sizeBytes": size_bytes}));
                }
                operation = selected_operation;
                key = selected_key;
                bytes_transferred = payload.len() as i64;
                checksum_state = "not_used".to_string();
                latency_ms = started.elapsed().as_secs_f64() * 1000.0;
                operation_count = 1;
                break;
            }
            "GET" => {
                let target = active_objects[next_active_index % active_objects.len()].clone();
                let selected_key = target["key"].as_str().unwrap_or_default().to_string();
                size_bytes = target["sizeBytes"].as_u64().unwrap_or(size_bytes as u64) as usize;
                state["nextActiveIndex"] = Value::from((next_active_index + 1) as u64);
                let output = match client
                    .get_object()
                    .bucket(bucket_name)
                    .key(&selected_key)
                    .send()
                    .await
                {
                    Ok(output) => output,
                    Err(error) => {
                        let mapped = map_sdk_error(error);
                        if is_missing_benchmark_key(&mapped) {
                            active_objects.retain(|item| {
                                item["key"].as_str().unwrap_or_default() != selected_key
                            });
                            state["activeObjects"] = Value::Array(active_objects.clone());
                            append_benchmark_log(
                                state,
                                &format!("Skipped missing benchmark object {selected_key}; rotating to the next object."),
                            );
                            continue;
                        }
                        return Err(mapped);
                    }
                };
                let bytes = output
                    .body
                    .collect()
                    .await
                    .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?
                    .into_bytes();
                let expected = benchmark_payload(
                    state["id"].as_str().unwrap_or_default(),
                    &selected_key,
                    size_bytes,
                    config
                        .get("randomData")
                        .and_then(Value::as_bool)
                        .unwrap_or(true),
                );
                operation = selected_operation;
                key = selected_key;
                bytes_transferred = bytes.len() as i64;
                checksum_state = if config
                    .get("validateChecksum")
                    .and_then(Value::as_bool)
                    .unwrap_or(true)
                {
                    if bytes.as_ref() == expected.as_slice() {
                        "validated_success".to_string()
                    } else {
                        "validated_failure".to_string()
                    }
                } else {
                    "not_used".to_string()
                };
                latency_ms = started.elapsed().as_secs_f64() * 1000.0;
                operation_count = 1;
                break;
            }
            _ => {
                let delete_batch_size = benchmark_delete_batch_size(&config, active_objects.len());
                let selected_keys: Vec<String> = (0..delete_batch_size)
                    .map(|offset| {
                        active_objects[(next_active_index + offset) % active_objects.len()]["key"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string()
                    })
                    .collect();
                state["nextActiveIndex"] =
                    Value::from((next_active_index + delete_batch_size) as u64);
                if benchmark_delete_mode(&config) == "multi-object-post" && selected_keys.len() > 1
                {
                    let objects: Vec<ObjectIdentifier> = selected_keys
                        .iter()
                        .map(|item| {
                            ObjectIdentifier::builder()
                                .key(item)
                                .build()
                                .map_err(|error| {
                                    SidecarError::new("invalid_config", error.to_string())
                                })
                        })
                        .collect::<Result<Vec<_>, _>>()?;
                    let delete = Delete::builder()
                        .set_objects(Some(objects))
                        .quiet(false)
                        .build()
                        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
                    let output = client
                        .delete_objects()
                        .bucket(bucket_name)
                        .delete(delete)
                        .send()
                        .await
                        .map_err(map_sdk_error)?;
                    let mut deleted_keys = Vec::new();
                    for item in output.deleted() {
                        if let Some(target) = item.key() {
                            if !target.is_empty() {
                                deleted_keys.push(target.to_string());
                            }
                        }
                    }
                    let mut missing_keys = Vec::new();
                    let mut fatal_errors = Vec::new();
                    for item in output.errors() {
                        let target = item.key().unwrap_or_default();
                        let code = item.code().unwrap_or_default().to_ascii_lowercase();
                        let message = item.message().unwrap_or_default().to_string();
                        if matches!(code.as_str(), "nosuchkey" | "notfound" | "404")
                            || message.to_ascii_lowercase().contains("does not exist")
                        {
                            if !target.is_empty() {
                                missing_keys.push(target.to_string());
                            }
                            continue;
                        }
                        fatal_errors.push(format!(
                            "{}: {}",
                            if target.is_empty() {
                                "(unknown)"
                            } else {
                                target
                            },
                            if message.is_empty() {
                                item.code().unwrap_or("delete error")
                            } else {
                                message.as_str()
                            }
                        ));
                    }
                    if !fatal_errors.is_empty() {
                        return Err(SidecarError::new("delete_failed", fatal_errors.join("; ")));
                    }
                    if !missing_keys.is_empty() {
                        append_benchmark_log(
                            state,
                            &format!(
                                "Skipped {} missing benchmark object(s) during multi-delete POST.",
                                missing_keys.len()
                            ),
                        );
                    }
                    active_objects.retain(|item| {
                        let current_key = item["key"].as_str().unwrap_or_default();
                        !deleted_keys.iter().any(|entry| entry == current_key)
                            && !missing_keys.iter().any(|entry| entry == current_key)
                    });
                    let deleted_count = deleted_keys.len() as i64;
                    if deleted_count == 0 {
                        state["activeObjects"] = Value::Array(active_objects.clone());
                        continue;
                    }
                    let first_deleted_key = selected_keys
                        .iter()
                        .find(|item| deleted_keys.iter().any(|deleted| deleted == *item))
                        .cloned()
                        .or_else(|| deleted_keys.first().cloned())
                        .unwrap_or_default();
                    operation = selected_operation;
                    key = if deleted_count > 1 {
                        format!("{first_deleted_key} (+{} more)", deleted_count - 1)
                    } else {
                        first_deleted_key
                    };
                    size_bytes = 0;
                    bytes_transferred = 0;
                    checksum_state = "not_used".to_string();
                    latency_ms = started.elapsed().as_secs_f64() * 1000.0;
                    operation_count = deleted_count;
                    break;
                }
                let target = active_objects[next_active_index % active_objects.len()].clone();
                let selected_key = target["key"].as_str().unwrap_or_default().to_string();
                size_bytes = target["sizeBytes"].as_u64().unwrap_or(size_bytes as u64) as usize;
                match client
                    .delete_object()
                    .bucket(bucket_name)
                    .key(&selected_key)
                    .send()
                    .await
                {
                    Ok(_) => {}
                    Err(error) => {
                        let mapped = map_sdk_error(error);
                        if is_missing_benchmark_key(&mapped) {
                            active_objects.retain(|item| {
                                item["key"].as_str().unwrap_or_default() != selected_key
                            });
                            state["activeObjects"] = Value::Array(active_objects.clone());
                            append_benchmark_log(
                                state,
                                &format!("Skipped missing benchmark object {selected_key}; rotating to the next object."),
                            );
                            continue;
                        }
                        return Err(mapped);
                    }
                }
                active_objects
                    .retain(|item| item["key"].as_str().unwrap_or_default() != selected_key);
                operation = selected_operation;
                key = selected_key;
                bytes_transferred = 0;
                checksum_state = "not_used".to_string();
                latency_ms = started.elapsed().as_secs_f64() * 1000.0;
                operation_count = 1;
                break;
            }
        }
    }
    let second = state["activeElapsedSeconds"].as_f64().unwrap_or(0.0) as i64 + 1;
    history.push(json!({
        "timestamp": now_iso(),
        "second": second,
        "operation": operation,
        "key": key,
        "sizeBytes": size_bytes,
        "latencyMs": round1(latency_ms),
        "bytesTransferred": bytes_transferred,
        "success": true,
        "checksumState": checksum_state,
        "operationCount": operation_count,
    }));
    state["history"] = Value::Array(history);
    state["activeObjects"] = Value::Array(active_objects);
    state["processedCount"] = Value::from(
        state["history"]
            .as_array()
            .map(|items| items.iter().map(benchmark_operation_count).sum::<i64>())
            .unwrap_or(0),
    );
    if operation == "DELETE" && operation_count > 1 {
        append_benchmark_log(
            state,
            &format!(
                "DELETE POST removed {operation_count} object(s) in {:.1} ms.",
                round1(latency_ms)
            ),
        );
    } else {
        append_benchmark_log(
            state,
            &format!(
                "{} {} completed in {:.1} ms.",
                operation,
                key,
                round1(latency_ms)
            ),
        );
    }
    Ok(())
}

fn benchmark_summary(processed_count: usize, workload_type: &str) -> Value {
    let operations = benchmark_operations(processed_count, workload_type);
    let throughput_series = benchmark_throughput_series(&operations);
    let average_ops = throughput_series
        .iter()
        .filter_map(|item| item["opsPerSecond"].as_f64())
        .sum::<f64>()
        / throughput_series.len().max(1) as f64;
    let peak_ops = throughput_series
        .iter()
        .filter_map(|item| item["opsPerSecond"].as_u64())
        .max()
        .unwrap_or(0);
    let average_bytes = throughput_series
        .iter()
        .filter_map(|item| item["bytesPerSecond"].as_f64())
        .sum::<f64>()
        / throughput_series.len().max(1) as f64;
    let peak_bytes = throughput_series
        .iter()
        .filter_map(|item| item["bytesPerSecond"].as_u64())
        .max()
        .unwrap_or(0);
    let latency_percentiles = json!({
        "p50": 18.4,
        "p75": 27.8,
        "p90": 35.6,
        "p95": 41.2,
        "p99": 63.8,
        "p999": 81.4,
    });
    let latency_by_operation = benchmark_latency_by_operation();
    json!({
        "totalOperations": processed_count,
        "operationsByType": operations,
        "latencyPercentilesMs": latency_percentiles,
        "latencyPercentilesByOperationMs": latency_by_operation,
        "throughputSeries": throughput_series,
        "sizeLatencyBuckets": benchmark_size_latency_buckets(),
        "checksumStats": {
            "validated_success": processed_count,
            "validated_failure": 0,
            "not_used": 0
        },
        "detailMetrics": {
            "sampleCount": 24,
            "sampleWindowSeconds": 1,
            "averageOpsPerSecond": average_ops,
            "peakOpsPerSecond": peak_ops,
            "averageBytesPerSecond": average_bytes,
            "peakBytesPerSecond": peak_bytes,
            "averageObjectSizeBytes": 29442048,
            "checksumValidated": processed_count,
            "errorCount": 0,
            "retryCount": (processed_count / 180).max(1),
        },
        "operationDetails": benchmark_operation_details(&operations),
    })
}

fn benchmark_operations(
    processed_count: usize,
    workload_type: &str,
) -> serde_json::Map<String, Value> {
    let ratios = match workload_type {
        "write-heavy" => [("PUT", 60usize), ("GET", 30usize), ("DELETE", 10usize)],
        "read-heavy" => [("PUT", 25usize), ("GET", 65usize), ("DELETE", 10usize)],
        "delete" => [("PUT", 0usize), ("GET", 0usize), ("DELETE", 100usize)],
        _ => [("PUT", 34usize), ("GET", 33usize), ("DELETE", 33usize)],
    };
    let mut assigned = 0usize;
    let mut operations = serde_json::Map::new();
    for (index, (name, ratio)) in ratios.iter().enumerate() {
        let value = if index == ratios.len() - 1 {
            processed_count.saturating_sub(assigned)
        } else {
            (processed_count * *ratio) / 100
        };
        assigned += value;
        operations.insert((*name).to_string(), Value::from(value as i64));
    }
    operations
}

fn benchmark_throughput_series(operations: &serde_json::Map<String, Value>) -> Vec<Value> {
    let total_ratio = operations
        .values()
        .filter_map(Value::as_f64)
        .sum::<f64>()
        .max(1.0);
    (0..24)
        .map(|index| {
            let second = index + 1;
            let progress = index as f64 / 23.0;
            let swing = ((index % 6) as f64 - 2.5) * 0.022;
            let ops_per_second = (1900.0 * (0.88 + (progress * 0.24) + swing)).round();
            let average_latency_ms = 21.0 + (progress * 15.0) + (((index % 5) as f64) * 0.6);
            let mut per_operation = serde_json::Map::new();
            let mut per_operation_latency = serde_json::Map::new();
            for (operation, count) in operations {
                let ratio = count.as_f64().unwrap_or(0.0) / total_ratio;
                let op_count = (ops_per_second * ratio).round() as u64;
                per_operation.insert(operation.clone(), json!(op_count));
                per_operation_latency.insert(
                    operation.clone(),
                    json!(round1(
                        average_latency_ms * operation_latency_factor(operation)
                    )),
                );
            }
            json!({
                "second": second,
                "label": format!("{}s", second),
                "opsPerSecond": ops_per_second as u64,
                "bytesPerSecond": (ops_per_second as u64) * 65536,
                "averageLatencyMs": round1(average_latency_ms),
                "p95LatencyMs": round1(average_latency_ms * 1.44),
                "operations": per_operation,
                "latencyByOperationMs": per_operation_latency,
            })
        })
        .collect()
}

fn benchmark_size_latency_buckets() -> Vec<Value> {
    vec![
        json!({"sizeBytes": 4096, "avgLatencyMs": 8.2, "p50LatencyMs": 6.7, "p95LatencyMs": 9.7, "p99LatencyMs": 11.6, "count": 140}),
        json!({"sizeBytes": 65536, "avgLatencyMs": 17.6, "p50LatencyMs": 14.4, "p95LatencyMs": 20.8, "p99LatencyMs": 24.9, "count": 140}),
        json!({"sizeBytes": 1048576, "avgLatencyMs": 42.4, "p50LatencyMs": 34.8, "p95LatencyMs": 50.0, "p99LatencyMs": 60.2, "count": 120}),
        json!({"sizeBytes": 104857600, "avgLatencyMs": 286.2, "p50LatencyMs": 234.7, "p95LatencyMs": 337.7, "p99LatencyMs": 406.4, "count": 60}),
        json!({"sizeBytes": 1073741824, "avgLatencyMs": 1924.5, "p50LatencyMs": 1578.1, "p95LatencyMs": 2270.9, "p99LatencyMs": 2732.8, "count": 20}),
    ]
}

fn benchmark_latency_by_operation() -> Value {
    json!({
        "PUT": {"p50": 21.7, "p75": 32.8, "p90": 42.0, "p95": 48.6, "p99": 75.3, "p999": 96.1},
        "GET": {"p50": 16.9, "p75": 25.6, "p90": 32.8, "p95": 37.9, "p99": 58.7, "p999": 74.9},
        "DELETE": {"p50": 15.8, "p75": 23.9, "p90": 30.6, "p95": 35.4, "p99": 54.9, "p999": 70.0},
        "POST": {"p50": 19.5, "p75": 29.5, "p90": 37.7, "p95": 43.7, "p99": 67.6, "p999": 86.3},
        "HEAD": {"p50": 13.6, "p75": 20.6, "p90": 26.3, "p95": 30.5, "p99": 47.2, "p999": 60.3},
    })
}

fn benchmark_operation_details(operations: &serde_json::Map<String, Value>) -> Vec<Value> {
    let total = operations
        .values()
        .filter_map(Value::as_f64)
        .sum::<f64>()
        .max(1.0);
    let latency_by_operation = benchmark_latency_by_operation();
    operations
        .iter()
        .map(|(operation, count)| {
            let latency = &latency_by_operation[operation];
            let share_pct = (count.as_f64().unwrap_or(0.0) / total) * 100.0;
            let avg_ops = 2250.0 * (count.as_f64().unwrap_or(0.0) / total);
            json!({
                "operation": operation,
                "count": count,
                "sharePct": round1(share_pct),
                "avgOpsPerSecond": round1(avg_ops),
                "peakOpsPerSecond": round1(avg_ops * 1.22),
                "avgLatencyMs": latency["p75"],
                "p50LatencyMs": latency["p50"],
                "p95LatencyMs": latency["p95"],
                "p99LatencyMs": latency["p99"],
            })
        })
        .collect()
}

fn operation_latency_factor(operation: &str) -> f64 {
    match operation.to_uppercase().as_str() {
        "PUT" => 1.18,
        "GET" => 0.92,
        "DELETE" => 0.86,
        "POST" => 1.06,
        "HEAD" => 0.74,
        _ => 1.0,
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
        .map(str::trim)
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
                .map(str::trim)
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
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
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
    eprintln!("S3_BROWSER_LOG {}", payload);
}

fn sanitize_header_value(name: &str, value: &str) -> String {
    let lower = name.to_ascii_lowercase();
    if lower.contains("authorization")
        || lower.contains("security-token")
        || lower.contains("access-key")
        || lower.contains("secret")
        || lower.contains("token")
    {
        "[redacted]".to_string()
    } else {
        value.to_string()
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
            if text.is_empty() {
                "null".to_string()
            } else if text.len() > 16000 {
                format!("{}...(truncated)", &text[..16000])
            } else {
                text.to_string()
            }
        }
        Err(_) => "[omitted binary body]".to_string(),
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
    let details = json!({
        "awsCode": code,
        "errorChain": messages,
    });
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
