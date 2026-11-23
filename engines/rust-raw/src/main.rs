mod benchmark_backend;
mod client;
mod operations;
mod secret_hygiene;
mod signing;
mod tools;
mod transfer;

#[path = "../../rust-common/src/benchmark.rs"]
mod benchmark;
#[path = "../../rust-common/src/benchmark_runtime.rs"]
mod benchmark_runtime;

#[path = "../../rust/src/download_destination.rs"]
mod download_destination;
#[path = "../../rust/src/request_transport.rs"]
mod request_transport;
#[path = "../../rust/src/source_snapshot.rs"]
mod source_snapshot;
#[path = "../../rust/src/transfer_workers.rs"]
mod transfer_workers;

use chrono::{SecondsFormat, Utc};
use http::{HeaderMap, HeaderValue};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::io;
use std::sync::Arc;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

const ENGINE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Deserialize)]
struct Request {
    #[serde(rename = "requestId")]
    request_id: String,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Clone, Debug)]
struct SidecarError {
    code: &'static str,
    message: String,
    details: Value,
}

impl SidecarError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self::with_details(code, message, Value::Object(Map::new()))
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
    fn fmt(&self, output: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        output.write_str(&self.message)
    }
}

impl std::error::Error for SidecarError {}

type SidecarResult = Result<Value, SidecarError>;

const METHODS: &[&str] = &[
    "health",
    "getCapabilities",
    "testProfile",
    "listBuckets",
    "createBucket",
    "deleteBucket",
    "getBucketAdminState",
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
    "listObjectVersions",
    "getObjectDetails",
    "createFolder",
    "copyObject",
    "moveObject",
    "deleteObjects",
    "deleteObjectVersions",
    "startUpload",
    "startDownload",
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
    "storageAction",
];

#[tokio::main]
async fn main() {
    let mut input = tokio::io::BufReader::new(tokio::io::stdin());
    let slots = Arc::new(Semaphore::new(request_transport::MAX_ACTIVE_REQUESTS));
    let admission = request_transport::Admission::new();
    let mut tasks = JoinSet::new();
    loop {
        let frame =
            match request_transport::read_frame(&mut input, request_transport::MAX_FRAME_BYTES)
                .await
            {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(_) => {
                    eprintln!("Could not read the desktop request stream.");
                    std::process::exit(1);
                }
            };
        while tasks.try_join_next().is_some() {}
        let bytes = match frame {
            request_transport::Frame::Data(bytes) => bytes,
            request_transport::Frame::Oversized => {
                reply(
                    None,
                    Err(SidecarError::new(
                        "invalid_request",
                        "Input frame exceeds the 64 MiB limit.",
                    )),
                );
                continue;
            }
        };
        if bytes.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let request = match serde_json::from_slice::<Request>(&bytes) {
            Ok(request) => request,
            Err(_) => {
                reply(
                    None,
                    Err(SidecarError::new(
                        "invalid_request",
                        "Invalid JSON request envelope.",
                    )),
                );
                continue;
            }
        };
        drop(bytes);

        match admission.admit(&request.method) {
            Ok(Some(queued)) => {
                let slots = slots.clone();
                tasks.spawn(async move {
                    let _queued = queued;
                    let _active = slots.acquire_owned().await.unwrap();
                    execute(request).await;
                });
            }
            Ok(None) => execute(request).await,
            Err(error) => reply(Some(&request.request_id), Err(error)),
        }
    }
    while tasks.join_next().await.is_some() {}
}

async fn execute(request: Request) {
    let request_id = request.request_id.clone();
    let secrets = secret_hygiene::collect(&request.params);
    let task = secret_hygiene::SECRETS.scope(secrets, async move {
        if !request.params.is_null() && !request.params.is_object() {
            return Err(SidecarError::new(
                "invalid_request",
                "Request params must be an object.",
            ));
        }
        dispatch(&request.method, request.params).await
    });
    let result = match tokio::spawn(task).await {
        Ok(result) => result,
        Err(_) => Err(SidecarError::new(
            "internal_error",
            "The raw S3 engine could not complete the request.",
        )),
    };
    reply(Some(&request_id), result);
}

fn reply(request_id: Option<&str>, result: SidecarResult) {
    let value = match result {
        Ok(result) => json!({"requestId":request_id,"ok":true,"result":result}),
        Err(error) => json!({"requestId":request_id,"ok":false,"error":{
            "code":error.code,"message":error.message,"details":error.details
        }}),
    };
    println!("{value}");
}

async fn dispatch(method: &str, params: Value) -> SidecarResult {
    match method {
        "health" => Ok(json!({
            "engine":"rust-raw","version":ENGINE_VERSION,"available":true,"methods":METHODS,
            "nativeSdk":"hyper-rustls-raw","endpointTypes":["s3Compatible","awsS3"]
        })),
        "getCapabilities" => Ok(capabilities()),
        "generatePresignedUrl" => presign(&params),
        "startUpload" => transfer::start_upload(params).await,
        "startDownload" => transfer::start_download(params).await,
        "runPutTestData" => tools::put_test_data(params).await,
        "runDeleteAll" => tools::delete_all(params).await,
        "cancelToolExecution" => tools::cancel(&params),
        "startBenchmark" => benchmark::start_benchmark(params).await,
        "getBenchmarkStatus" => benchmark::get_benchmark_status(params).await,
        "pauseBenchmark" => benchmark::pause_benchmark(params).await,
        "resumeBenchmark" => benchmark::resume_benchmark(params).await,
        "stopBenchmark" => benchmark::stop_benchmark(params).await,
        "exportBenchmarkResults" => benchmark::export_benchmark_results(params).await,
        "pauseTransfer" | "resumeTransfer" | "cancelTransfer" => Err(SidecarError::new(
            "unsupported_feature",
            "Interactive transfer controls are unavailable.",
        )),
        _ if METHODS.contains(&method) => operations::dispatch(method, params).await,
        _ => Err(SidecarError::new(
            "unsupported_feature",
            "The raw S3 engine does not support this method.",
        )),
    }
}

fn capabilities() -> Value {
    let items: Vec<_> = [
        ("bucket.browse", "Bucket browsing", true),
        ("bucket.lifecycle", "Lifecycle policy CRUD", true),
        ("bucket.policy", "Bucket policy CRUD", true),
        ("bucket.cors", "Bucket CORS CRUD", true),
        ("bucket.encryption", "Bucket encryption", true),
        ("bucket.tagging", "Bucket tagging", true),
        ("bucket.versioning", "Bucket versioning", true),
        ("bucket.objectLock", "Bucket Object Lock", true),
        ("object.retention", "Object retention and legal hold", true),
        ("object.copy_move", "Copy, move, rename", true),
        ("object.resumable", "Resumable transfer jobs", false),
        ("object.encryption.sse-s3", "SSE-S3", true),
        ("object.encryption.sse-kms", "SSE-KMS", false),
        ("object.encryption.dsse-kms", "DSSE-KMS", false),
        ("object.encryption.sse-c", "SSE-C", false),
        ("object.encryption.azure-scope", "Azure encryption scope", false),
        ("object.encryption.azure-cpk", "Azure customer-provided key", false),
        ("object.clientEncryption", "Client-side encryption", false),
        ("tools.bulk-delete", "Delete-all maintenance tool", true),
        ("benchmark", "Integrated benchmark mode", true),
        ("conformance.s3", "S3 API conformance harness", false),
    ].into_iter().map(|(key, label, supported)| {
        json!({"key":key,"label":label,"state":if supported {"supported"} else {"unsupported"}})
    }).collect();
    json!({"items":items})
}

fn presign(params: &Value) -> SidecarResult {
    encryption_headers(params, false)?;
    let client = client::Client::new(&params["profile"])?;
    let bucket = required_text(params, "bucketName", "A bucket name is required.")?;
    let key = required_text(params, "key", "An object key is required.")?;
    let expiration = params["expirationSeconds"].as_u64().unwrap_or(300);
    let url = client.presign(&bucket, &key, params["versionId"].as_str(), expiration)?;
    Ok(json!({"url":url}))
}

fn required_text(value: &Value, field: &str, message: &str) -> Result<String, SidecarError> {
    value[field]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| SidecarError::new("invalid_config", message))
}

fn uncertain_mutation(error: SidecarError, operation: &str) -> SidecarError {
    let status = error.details["statusCode"].as_u64();
    let uncertain = error.details["beforeSend"] != true
        && (matches!(
            error.code,
            "engine_unavailable" | "timeout" | "invalid_response"
        ) || matches!(status, Some(500..=599)) && error.code != "throttled");
    if !uncertain {
        return error;
    }
    let mut details = error.details;
    details["outcomeUnknown"] = json!(true);
    SidecarError::with_details(
        "unknown_outcome",
        format!(
            "{operation} was not confirmed. Inspect the destination before retrying. {}",
            error.message
        ),
        details,
    )
}

fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn encryption_headers(params: &Value, write: bool) -> Result<HeaderMap, SidecarError> {
    if !params["clientEncryption"].is_null() {
        return Err(SidecarError::new(
            "unsupported_feature",
            "The raw S3 engine does not support client-side encryption.",
        ));
    }
    let mut headers = HeaderMap::new();
    for (field, destination) in [("encryption", true), ("sourceEncryption", false)] {
        let value = &params[field];
        if value.is_null() {
            continue;
        }
        let supported = matches!(value["mode"].as_str(), Some("bucketDefault" | "sse-s3"));
        if !supported {
            return Err(SidecarError::new(
                "unsupported_feature",
                "The raw S3 engine does not support the requested object encryption mode.",
            ));
        }
        if value
            .as_object()
            .is_some_and(|fields| fields.keys().any(|key| key != "mode"))
        {
            return Err(SidecarError::new(
                "invalid_config",
                "Unexpected fields for the requested object encryption mode.",
            ));
        }
        if destination && write && value["mode"] == "sse-s3" {
            headers.insert(
                "x-amz-server-side-encryption",
                HeaderValue::from_static("AES256"),
            );
        }
    }
    Ok(headers)
}

fn short_uuid() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

fn emit_structured_log(level: &str, category: &str, message: String, source: &str) {
    eprintln!(
        "S3_BROWSER_LOG {}",
        json!({"level":level,"category":category,
        "message":secret_hygiene::text(&message),"source":source,"timestamp":now_iso()})
    );
}
