use crate::client::{Client, Payload, Retry};
use crate::download_destination::DestinationIndex;
use crate::source_snapshot::SourceSnapshot;
use crate::transfer_workers::run_bounded;
use crate::{
    encryption_headers, now_iso, required_text, uncertain_mutation, SidecarError, SidecarResult,
};
use bytes::Bytes;
use http::header::{self, HeaderMap, HeaderValue};
use http::{Method, StatusCode};
use quick_xml::events::Event;
use quick_xml::Reader;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncSeekExt, AsyncWriteExt, BufWriter};
use uuid::Uuid;

const MIB: u64 = 1024 * 1024;
const DOWNLOAD_WRITE_BUFFER: usize = 64 * 1024;
const MIN_UPLOAD_PART_MIB: u64 = 5;
const MAX_UPLOAD_PART_MIB: u64 = 5120;
const DEFAULT_UPLOAD_PART_MIB: u64 = 8;
const DEFAULT_MULTIPART_THRESHOLD_MIB: u64 = 32;
const MAX_S3_PARTS: u64 = 10_000;
const MAX_SINGLE_PUT_BYTES: u64 = 5 * 1024 * MIB;
const MAX_S3_OBJECT_BYTES: u64 = 50_000 * 1024 * 1024 * 1024;
const MAX_PART_OUTPUT_LINES: u64 = 64;
const S3_XMLNS: &str = "http://s3.amazonaws.com/doc/2006-03-01/";

/// Interactive transfer controls are unsupported in the sequential Rust engine,
/// matching the SDK engine contract.
#[allow(dead_code)]
pub fn unsupported_transfer_control() -> SidecarError {
    SidecarError::new(
        "unsupported_feature",
        "Interactive transfer control is unavailable in the sequential Rust engine.",
    )
}

#[derive(Serialize)]
#[serde(rename = "CompleteMultipartUpload")]
struct CompleteMultipartUploadRequest<'a> {
    #[serde(rename = "@xmlns")]
    xmlns: &'static str,
    #[serde(rename = "Part")]
    parts: &'a [CompletedPartXml<'a>],
}

#[derive(Serialize)]
struct CompletedPartXml<'a> {
    #[serde(rename = "PartNumber")]
    part_number: u32,
    #[serde(rename = "ETag")]
    etag: &'a str,
}

#[derive(Deserialize)]
struct InitiateMultipartUploadResult {
    #[serde(rename = "UploadId")]
    upload_id: Option<String>,
}

#[derive(Deserialize)]
struct CompleteMultipartUploadResult {
    #[serde(rename = "ETag")]
    #[allow(dead_code)]
    etag: Option<String>,
}

#[derive(Deserialize)]
struct S3XmlError {
    #[serde(rename = "Code")]
    code: Option<String>,
    #[serde(rename = "Message")]
    message: Option<String>,
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
            output_lines,
        ));
    }
}

#[allow(clippy::too_many_arguments)]
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
    output_lines: Vec<String>,
) -> Value {
    crate::secret_hygiene::value(json!({
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
    }))
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
        (bytes_transferred as f64 / total_bytes as f64).clamp(0.0, 1.0)
    }
}

fn short_uuid() -> String {
    Uuid::new_v4().to_string()[..8].to_string()
}

fn exact_string_array(value: &Value) -> Vec<String> {
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

fn exact_string_map(value: &Value) -> BTreeMap<String, String> {
    value
        .as_object()
        .map(|items| {
            items
                .iter()
                .filter_map(|(key, value)| {
                    value
                        .as_str()
                        .filter(|item| !item.is_empty())
                        .map(|item| (key.clone(), item.to_owned()))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn upload_part_size_bytes(value: &Value) -> u64 {
    let mib = match (value.as_i64(), value.as_u64()) {
        (Some(size), _) => {
            size.clamp(MIN_UPLOAD_PART_MIB as i64, MAX_UPLOAD_PART_MIB as i64) as u64
        }
        (_, Some(size)) => size.clamp(MIN_UPLOAD_PART_MIB, MAX_UPLOAD_PART_MIB),
        _ => DEFAULT_UPLOAD_PART_MIB,
    };
    mib * MIB
}

fn validate_upload_size(size: u64, threshold: u64, chunk: u64) -> Result<(), SidecarError> {
    let threshold = threshold.min(MAX_SINGLE_PUT_BYTES + 1);
    if size > MAX_S3_OBJECT_BYTES || (size >= threshold && size.div_ceil(chunk) > MAX_S3_PARTS) {
        return Err(SidecarError::new(
            "invalid_config",
            "Upload exceeds S3 object or 10,000-part limits; select a larger part size.",
        ));
    }
    Ok(())
}

fn resolve_upload_key(
    raw_path: &str,
    path: &Path,
    prefix: &str,
    object_key_by_path: &BTreeMap<String, String>,
) -> Result<String, SidecarError> {
    let target_name = match object_key_by_path.get(raw_path) {
        Some(mapped) if !mapped.is_empty() => mapped.clone(),
        _ => path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_owned(),
    };
    let key = if prefix.is_empty() {
        target_name
    } else {
        format!("{prefix}{target_name}")
    };
    if key.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Upload object key is required.",
        ));
    }
    Ok(key)
}

fn transfer_concurrency(client: &Client) -> usize {
    client.max_connections.clamp(1, 8)
}

fn profile_max_attempts(params: &Value) -> u32 {
    params["profile"]["maxAttempts"]
        .as_u64()
        .unwrap_or(5)
        .clamp(1, 20) as u32
}

fn header_str<'a>(headers: &'a HeaderMap, name: &header::HeaderName) -> Option<&'a str> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
}

fn response_etag(headers: &HeaderMap) -> Option<String> {
    header_str(headers, &header::ETAG)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn parse_content_length(headers: &HeaderMap) -> Result<Option<u64>, SidecarError> {
    match headers.get(header::CONTENT_LENGTH) {
        None => Ok(None),
        Some(raw) => {
            let text = raw.to_str().map_err(|_| {
                SidecarError::new("invalid_response", "Invalid Content-Length header.")
            })?;
            let parsed = text.trim().parse::<u64>().map_err(|_| {
                SidecarError::new(
                    "invalid_response",
                    format!("Invalid Content-Length header value: {}", text.trim()),
                )
            })?;
            Ok(Some(parsed))
        }
    }
}

fn xml_root_local_name(bytes: &[u8]) -> Result<Option<Vec<u8>>, SidecarError> {
    let mut reader = Reader::from_reader(bytes);
    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(event)) | Ok(Event::Empty(event)) => {
                return Ok(Some(event.local_name().as_ref().to_vec()));
            }
            Ok(Event::Eof) => return Ok(None),
            Ok(Event::Text(event)) => {
                if !event.as_ref().iter().all(u8::is_ascii_whitespace) {
                    return Err(SidecarError::new(
                        "invalid_response",
                        "Unexpected text before XML root element.",
                    ));
                }
            }
            Ok(Event::Decl(_))
            | Ok(Event::Comment(_))
            | Ok(Event::PI(_))
            | Ok(Event::DocType(_)) => {}
            Ok(_) => {
                return Err(SidecarError::new(
                    "invalid_response",
                    "Unexpected XML token before root element.",
                ));
            }
            Err(error) => {
                return Err(SidecarError::new(
                    "invalid_response",
                    format!("Malformed XML response: {error}"),
                ));
            }
        }
        buf.clear();
    }
}

fn map_s3_error(status: StatusCode, aws_code: &str, message: String) -> SidecarError {
    let code = match aws_code {
        "AccessDenied" | "InvalidAccessKeyId" | "SignatureDoesNotMatch" | "ExpiredToken" => {
            "auth_failed"
        }
        "RequestTimeout" => "timeout",
        "SlowDown" | "ServiceUnavailable" => "throttled",
        "PreconditionFailed" => "object_conflict",
        "NoSuchKey" | "NoSuchBucket" | "NoSuchUpload" => "not_found",
        _ => match status.as_u16() {
            401 | 403 => "auth_failed",
            404 => "not_found",
            408 | 504 => "timeout",
            409 | 412 => "object_conflict",
            429 => "throttled",
            500..=599 => "engine_unavailable",
            _ => "unknown",
        },
    };
    SidecarError::with_details(
        code,
        message,
        json!({
            "awsCode": aws_code,
            "httpStatus": status.as_u16(),
        }),
    )
}

fn check_embedded_xml_error(status: StatusCode, body: &[u8]) -> Result<(), SidecarError> {
    if body.iter().all(u8::is_ascii_whitespace) {
        return Ok(());
    }
    if xml_root_local_name(body)?.as_deref() == Some(b"Error") {
        let text = std::str::from_utf8(body).map_err(|_| {
            SidecarError::new(
                "invalid_response",
                "S3 XML error response was not valid UTF-8.",
            )
        })?;
        let parsed: S3XmlError = quick_xml::de::from_str(text).map_err(|error| {
            SidecarError::new(
                "invalid_response",
                format!("Failed to parse S3 XML error response: {error}"),
            )
        })?;
        let aws_code = parsed.code.as_deref().unwrap_or("Unknown");
        let message = parsed
            .message
            .filter(|m| !m.trim().is_empty())
            .unwrap_or_else(|| format!("S3 returned error {aws_code}."));
        return Err(map_s3_error(status, aws_code, message));
    }
    Ok(())
}

fn ensure_http_status(
    status: StatusCode,
    expected: Option<StatusCode>,
    body: &[u8],
) -> Result<(), SidecarError> {
    if let Some(expected_status) = expected {
        if status != expected_status {
            check_embedded_xml_error(status, body)?;
            let code = match status.as_u16() {
                401 | 403 => "auth_failed",
                404 => "not_found",
                408 | 504 => "timeout",
                409 | 412 => "object_conflict",
                429 => "throttled",
                500..=599 => "engine_unavailable",
                _ => "object_conflict",
            };
            return Err(SidecarError::with_details(
                code,
                format!(
                    "Unexpected HTTP status {}; expected {}.",
                    status.as_u16(),
                    expected_status.as_u16()
                ),
                json!({ "httpStatus": status.as_u16() }),
            ));
        }
    } else if !status.is_success() {
        check_embedded_xml_error(status, body)?;
        return Err(map_s3_error(
            status,
            status.canonical_reason().unwrap_or("HttpError"),
            format!("S3 request failed with HTTP {}.", status.as_u16()),
        ));
    }
    Ok(())
}

fn parse_initiate_multipart_upload(body: &[u8]) -> Result<String, SidecarError> {
    check_embedded_xml_error(StatusCode::OK, body)?;
    let root = xml_root_local_name(body)?;
    if root.as_deref() != Some(b"InitiateMultipartUploadResult") {
        return Err(SidecarError::new(
            "invalid_response",
            "Multipart upload initialization returned an unexpected XML payload.",
        ));
    }
    let text = std::str::from_utf8(body).map_err(|_| {
        SidecarError::new(
            "invalid_response",
            "Multipart upload initialization response was not valid UTF-8.",
        )
    })?;
    let parsed: InitiateMultipartUploadResult = quick_xml::de::from_str(text).map_err(|error| {
        SidecarError::new(
            "invalid_response",
            format!("Failed to parse InitiateMultipartUploadResult: {error}"),
        )
    })?;
    parsed.upload_id.filter(|id| !id.is_empty()).ok_or_else(|| {
        SidecarError::new(
            "invalid_response",
            "Multipart upload did not return an upload ID.",
        )
    })
}

fn serialize_complete_multipart_upload(parts: &[(u32, String)]) -> Result<Bytes, SidecarError> {
    let xml_parts: Vec<CompletedPartXml<'_>> = parts
        .iter()
        .map(|(part_number, etag)| CompletedPartXml {
            part_number: *part_number,
            etag: etag.as_str(),
        })
        .collect();
    let payload = CompleteMultipartUploadRequest {
        xmlns: S3_XMLNS,
        parts: &xml_parts,
    };
    let xml = quick_xml::se::to_string(&payload).map_err(|error| {
        SidecarError::new(
            "internal_error",
            format!("Failed to serialize CompleteMultipartUpload XML: {error}"),
        )
    })?;
    Ok(Bytes::from(xml))
}

fn parse_complete_multipart_upload(body: &[u8]) -> Result<(), SidecarError> {
    check_embedded_xml_error(StatusCode::OK, body)?;
    let root = xml_root_local_name(body)?;
    if root.as_deref() != Some(b"CompleteMultipartUploadResult") {
        return Err(SidecarError::new(
            "invalid_response",
            "Multipart upload completion returned an unexpected XML payload.",
        ));
    }
    let text = std::str::from_utf8(body).map_err(|_| {
        SidecarError::new(
            "invalid_response",
            "Multipart upload completion response was not valid UTF-8.",
        )
    })?;
    let _parsed: CompleteMultipartUploadResult =
        quick_xml::de::from_str(text).map_err(|error| {
            SidecarError::new(
                "invalid_response",
                format!("Failed to parse CompleteMultipartUploadResult: {error}"),
            )
        })?;
    Ok(())
}

struct PlannedUpload {
    path: PathBuf,
    key: String,
    file_name: String,
    file_size: u64,
    snapshot: SourceSnapshot,
}

#[allow(clippy::too_many_arguments)]
async fn upload_file_multipart(
    client: &Arc<Client>,
    bucket_name: &str,
    key: &str,
    path: &Path,
    file_size: u64,
    chunk_bytes: u64,
    concurrency: usize,
    progress: &Arc<TransferProgress>,
    file_name: &str,
    write_headers: &HeaderMap,
    part_headers: &HeaderMap,
    snapshot: &SourceSnapshot,
) -> Result<(), SidecarError> {
    snapshot.check(path)?;
    let part_count = file_size.div_ceil(chunk_bytes);
    if part_count == 0 || part_count > MAX_S3_PARTS {
        return Err(SidecarError::new(
            "invalid_config",
            "Upload exceeds S3 object or 10,000-part limits; select a larger part size.",
        ));
    }

    let init_response = client
        .send(
            Method::POST,
            Some(bucket_name),
            Some(key),
            &[("uploads", "")],
            write_headers.clone(),
            Payload::Empty,
            Retry::Never,
        )
        .await?;
    let init_status = init_response.status;
    let init_body = init_response.bytes().await?;
    ensure_http_status(init_status, None, &init_body)?;
    let upload_id = parse_initiate_multipart_upload(&init_body)?;

    let mut parts: Vec<(u32, String)> = Vec::with_capacity(part_count as usize);
    let parts_result = run_bounded(
        part_count,
        concurrency,
        |index| {
            let part_number = (index + 1) as u32;
            let offset = index * chunk_bytes;
            let length = chunk_bytes.min(file_size - offset);
            let client = Arc::clone(client);
            let bucket_name = bucket_name.to_owned();
            let key = key.to_owned();
            let upload_id = upload_id.clone();
            let path = path.to_path_buf();
            let progress = Arc::clone(progress);
            let file_name = file_name.to_owned();
            let snapshot = snapshot.clone();
            let part_headers = part_headers.clone();
            async move {
                snapshot.check(&path)?;
                let part_number_str = part_number.to_string();
                let response = client
                    .send(
                        Method::PUT,
                        Some(&bucket_name),
                        Some(&key),
                        &[
                            ("partNumber", part_number_str.as_str()),
                            ("uploadId", upload_id.as_str()),
                        ],
                        part_headers,
                        Payload::file(path.clone(), offset, length, Some(snapshot.clone()))
                            .on_upload_activity({
                                let progress = progress.clone();
                                Arc::new(move || progress.note_activity())
                            }),
                        Retry::Safe,
                    )
                    .await?;
                let status = response.status;
                let etag = response_etag(&response.headers);
                let body = response.bytes().await?;
                ensure_http_status(status, None, &body)?;
                check_embedded_xml_error(status, &body)?;
                let etag = etag.ok_or_else(|| {
                    SidecarError::new(
                        "invalid_response",
                        format!("Upload part {part_number} did not return an ETag."),
                    )
                })?;
                snapshot.check(&path)?;
                {
                    let mut state = progress.state.lock().unwrap();
                    state.bytes_transferred += length;
                    state.parts_completed += 1;
                    state.push_part_line(format!("Uploaded part {part_number} for {file_name}."));
                }
                progress.emit("running", Some(file_name));
                Ok::<(u32, String), SidecarError>((part_number, etag))
            }
        },
        |part| parts.push(part),
    )
    .await
    .and_then(|()| snapshot.check(path));

    let complete_result = match parts_result {
        Err(error) => Err(error),
        Ok(()) => {
            parts.sort_by_key(|(part_number, _)| *part_number);
            if parts.len() as u64 != part_count
                || parts.iter().enumerate().any(|(idx, (part_number, etag))| {
                    *part_number as u64 != (idx as u64 + 1) || etag.is_empty()
                })
            {
                Err(SidecarError::new(
                    "invalid_response",
                    "Multipart upload parts were incomplete or missing ETags.",
                ))
            } else {
                match serialize_complete_multipart_upload(&parts) {
                    Err(error) => Err(error),
                    Ok(xml_body) => {
                        let mut headers = part_headers.clone();
                        headers.insert(
                            header::CONTENT_TYPE,
                            HeaderValue::from_static("application/xml"),
                        );
                        let complete_response = client
                            .send(
                                Method::POST,
                                Some(bucket_name),
                                Some(key),
                                &[("uploadId", upload_id.as_str())],
                                headers,
                                Payload::Bytes(xml_body),
                                Retry::Never,
                            )
                            .await;
                        match complete_response {
                            Err(error) => Err(error),
                            Ok(response) => {
                                let status = response.status;
                                match response.bytes().await {
                                    Err(error) => Err(error),
                                    Ok(body) => ensure_http_status(status, None, &body)
                                        .and_then(|()| parse_complete_multipart_upload(&body)),
                                }
                            }
                        }
                        .map_err(|error| uncertain_mutation(error, "Multipart upload completion"))
                    }
                }
            }
        }
    };

    if complete_result.is_err() {
        // Workers have already drained inside run_bounded before we reach here.
        let _ = client
            .send(
                Method::DELETE,
                Some(bucket_name),
                Some(key),
                &[("uploadId", upload_id.as_str())],
                HeaderMap::new(),
                Payload::Empty,
                Retry::Safe,
            )
            .await;
    }

    complete_result
}

pub async fn start_upload(params: Value) -> SidecarResult {
    let write_headers = encryption_headers(&params, true)?;
    let part_headers = encryption_headers(&params, false)?;
    let bucket_name = required_text(&params, "bucketName", "Bucket name is required.")?;
    let prefix = params["prefix"].as_str().unwrap_or_default();
    let file_paths = exact_string_array(params.get("filePaths").unwrap_or(&Value::Null));
    let object_key_by_path =
        exact_string_map(params.get("objectKeyByPath").unwrap_or(&Value::Null));
    if file_paths.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Bucket name and file paths are required.",
        ));
    }

    let multipart_threshold_bytes = params["multipartThresholdMiB"]
        .as_u64()
        .unwrap_or(DEFAULT_MULTIPART_THRESHOLD_MIB)
        .max(1)
        .saturating_mul(MIB)
        .min(MAX_SINGLE_PUT_BYTES + 1);
    let multipart_chunk_bytes = upload_part_size_bytes(&params["multipartChunkMiB"]);

    let mut total_bytes = 0_u64;
    let mut parts_total = 0_u64;
    let mut uses_multipart = false;
    let mut plan = Vec::with_capacity(file_paths.len());

    for raw_path in &file_paths {
        let path = PathBuf::from(raw_path);
        let snapshot = SourceSnapshot::capture(&path)?;
        let file_size = fs::metadata(&path)
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?
            .len();
        snapshot.check(&path)?;
        validate_upload_size(file_size, multipart_threshold_bytes, multipart_chunk_bytes)?;
        let key = resolve_upload_key(raw_path, &path, prefix, &object_key_by_path)?;
        let file_name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_owned();
        total_bytes = total_bytes
            .checked_add(file_size)
            .ok_or_else(|| SidecarError::new("invalid_config", "Total upload size overflow."))?;
        if file_size >= multipart_threshold_bytes {
            uses_multipart = true;
            parts_total += file_size.div_ceil(multipart_chunk_bytes);
        }
        plan.push(PlannedUpload {
            path,
            key,
            file_name,
            file_size,
            snapshot,
        });
    }

    let client = Arc::new(Client::new(&params["profile"])?);
    let concurrency = transfer_concurrency(&client);
    let job_id = format!("upload-{}", short_uuid());
    let label = format!("Upload {} file(s) to {bucket_name}", plan.len());
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
        item_count: plan.len(),
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
                "Queued {} file(s) for upload to {bucket_name} at {}.",
                plan.len(),
                now_iso()
            )],
        }),
    });
    progress.emit(
        "queued",
        plan.first()
            .map(|item| item.file_name.clone())
            .filter(|name| !name.is_empty()),
    );

    for item in &plan {
        item.snapshot.check(&item.path)?;
        {
            let mut state = progress.state.lock().unwrap();
            state.output_lines.push(format!(
                "Uploading {} ({} bytes) to {}.",
                item.file_name, item.file_size, item.key
            ));
        }

        if item.file_size >= multipart_threshold_bytes {
            upload_file_multipart(
                &client,
                &bucket_name,
                &item.key,
                &item.path,
                item.file_size,
                multipart_chunk_bytes,
                concurrency,
                &progress,
                &item.file_name,
                &write_headers,
                &part_headers,
                &item.snapshot,
            )
            .await?;
        } else {
            let response = client
                .send(
                    Method::PUT,
                    Some(&bucket_name),
                    Some(&item.key),
                    &[],
                    write_headers.clone(),
                    Payload::file(
                        item.path.clone(),
                        0,
                        item.file_size,
                        Some(item.snapshot.clone()),
                    )
                    .on_upload_activity({
                        let progress = progress.clone();
                        Arc::new(move || progress.note_activity())
                    }),
                    Retry::Rejected,
                )
                .await
                .map_err(|error| uncertain_mutation(error, "Object upload"))?;
            let status = response.status;
            let body = response
                .bytes()
                .await
                .map_err(|error| uncertain_mutation(error, "Object upload"))?;
            ensure_http_status(status, None, &body)?;
            check_embedded_xml_error(status, &body)?;
            item.snapshot.check(&item.path)?;
            {
                let mut state = progress.state.lock().unwrap();
                state.bytes_transferred += item.file_size;
            }
        }

        item.snapshot.check(&item.path)?;
        {
            let mut state = progress.state.lock().unwrap();
            state.items_completed += 1;
            state
                .output_lines
                .push(format!("Finished uploading {}.", item.file_name));
        }
        progress.emit("running", Some(item.file_name.clone()));
    }

    let (bytes_transferred, items_completed, parts_completed, output_lines) = {
        let mut state = progress.state.lock().unwrap();
        state.output_lines.push(format!(
            "Uploaded {} file(s) into {bucket_name}.",
            plan.len()
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
        plan.last()
            .map(|item| item.file_name.clone())
            .filter(|name| !name.is_empty()),
        plan.len(),
        items_completed,
        part_size_bytes,
        if part_total_value.is_some() {
            Some(parts_completed)
        } else {
            None
        },
        part_total_value,
        output_lines,
    ))
}

#[allow(clippy::too_many_arguments)]
async fn download_object_ranged(
    client: &Arc<Client>,
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
    customer_headers: &HeaderMap,
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
    run_bounded(
        part_count,
        concurrency,
        |index| {
            let start = index * chunk_bytes;
            let end = (start + chunk_bytes - 1).min(object_size.saturating_sub(1));
            let expected_bytes = end - start + 1;
            let expected_content_range = format!("bytes {start}-{end}/{object_size}");
            let range_header = format!("bytes={start}-{end}");
            let client = Arc::clone(client);
            let customer_headers = customer_headers.clone();
            let validator = validator.clone();
            let version_id = version_id.clone();
            let bucket_name = bucket_name.to_owned();
            let key = key.to_owned();
            let target = target.to_path_buf();
            let progress = Arc::clone(progress);
            async move {
                let mut attempt = 0_u32;
                let range_bytes = loop {
                    let attempt_result: Result<u64, SidecarError> = async {
                        let mut headers = customer_headers.clone();
                        headers.insert(
                            header::RANGE,
                            HeaderValue::from_str(&range_header).map_err(|error| {
                                SidecarError::new("invalid_config", error.to_string())
                            })?,
                        );
                        if let Some(etag) = &validator {
                            headers.insert(
                                header::IF_MATCH,
                                HeaderValue::from_str(etag).map_err(|error| {
                                    SidecarError::new("invalid_response", error.to_string())
                                })?,
                            );
                        }
                        let mut query = Vec::with_capacity(1);
                        if let Some(version) = &version_id {
                            query.push(("versionId", version.as_str()));
                        }

                        let mut response = client
                            .send(
                                Method::GET,
                                Some(&bucket_name),
                                Some(&key),
                                &query,
                                headers,
                                Payload::Empty,
                                Retry::Never,
                            )
                            .await?;

                        if response.status != StatusCode::PARTIAL_CONTENT {
                            let status = response.status;
                            drop(response);
                            return Err(SidecarError::with_details(
                                "object_conflict",
                                format!(
                                    "Ranged download returned HTTP {}; expected 206 Partial Content.",
                                    status.as_u16()
                                ),
                                json!({ "httpStatus": status.as_u16() }),
                            ));
                        }
                        if validator
                            .as_deref()
                            .is_some_and(|etag| response_etag(&response.headers).as_deref() != Some(etag))
                        {
                            return Err(SidecarError::new(
                                "object_conflict",
                                "Download ETag mismatch; partial file discarded.",
                            ));
                        }
                        if header_str(&response.headers, &header::CONTENT_RANGE)
                            != Some(expected_content_range.as_str())
                        {
                            return Err(SidecarError::new(
                                "object_conflict",
                                "Download range mismatch; partial file discarded.",
                            ));
                        }
                        if let Some(content_length) = parse_content_length(&response.headers)? {
                            if content_length != expected_bytes {
                                return Err(SidecarError::new(
                                    "object_conflict",
                                    format!(
                                        "Ranged download for {key} bytes {start}-{end} advertised {content_length} byte(s); expected {expected_bytes}."
                                    ),
                                ));
                            }
                        }

                        let mut file = tokio::fs::OpenOptions::new()
                            .write(true)
                            .open(&target)
                            .await
                            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
                        file.seek(SeekFrom::Start(start))
                            .await
                            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
                        let mut file = BufWriter::with_capacity(DOWNLOAD_WRITE_BUFFER, file);
                        let mut range_bytes = 0_u64;
                        while let Some(chunk) = response.next_chunk().await? {
                            if range_bytes.saturating_add(chunk.len() as u64) > expected_bytes {
                                return Err(SidecarError::new(
                                    "object_conflict",
                                    "Oversized range body.",
                                ));
                            }
                            if !chunk.is_empty() {
                                file.write_all(&chunk).await.map_err(|error| {
                                    SidecarError::new("invalid_config", error.to_string())
                                })?;
                                range_bytes += chunk.len() as u64;
                                progress.note_activity();
                            }
                        }
                        file.flush().await.map_err(|error| {
                            SidecarError::new("invalid_config", error.to_string())
                        })?;
                        if range_bytes != expected_bytes {
                            return Err(SidecarError::new(
                                "engine_unavailable",
                                format!(
                                    "Ranged download for {key} bytes {start}-{end} returned {range_bytes} byte(s); expected {expected_bytes}."
                                ),
                            ));
                        }
                        Ok(range_bytes)
                    }
                    .await;

                    match attempt_result {
                        Ok(bytes) => break bytes,
                        Err(error)
                            if crate::client::is_transient(&error)
                                && attempt < max_attempts.clamp(1, 20) - 1 =>
                        {
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
        },
        |()| {},
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn download_object_single(
    client: &Arc<Client>,
    validator: Option<String>,
    version_id: Option<String>,
    bucket_name: &str,
    key: &str,
    target: &Path,
    object_size: u64,
    max_attempts: u32,
    progress: &Arc<TransferProgress>,
    customer_headers: &HeaderMap,
) -> Result<(), SidecarError> {
    let mut attempt = 0_u32;
    let downloaded_bytes = loop {
        let attempt_result: Result<u64, SidecarError> = async {
            let mut headers = customer_headers.clone();
            if let Some(etag) = &validator {
                headers.insert(
                    header::IF_MATCH,
                    HeaderValue::from_str(etag).map_err(|error| {
                        SidecarError::new("invalid_response", error.to_string())
                    })?,
                );
            }
            let mut query = Vec::with_capacity(1);
            if let Some(version) = &version_id {
                query.push(("versionId", version.as_str()));
            }
            let mut response = client
                .send(
                    Method::GET,
                    Some(bucket_name),
                    Some(key),
                    &query,
                    headers,
                    Payload::Empty,
                    Retry::Never,
                )
                .await?;
            if response.status != StatusCode::OK {
                let status = response.status;
                drop(response);
                return Err(SidecarError::with_details(
                    "object_conflict",
                    format!(
                        "Download returned HTTP {}; expected 200 OK.",
                        status.as_u16()
                    ),
                    json!({ "httpStatus": status.as_u16() }),
                ));
            }
            if validator
                .as_deref()
                .is_some_and(|etag| response_etag(&response.headers).as_deref() != Some(etag))
            {
                return Err(SidecarError::new(
                    "object_conflict",
                    "Download ETag mismatch; partial file discarded.",
                ));
            }
            if let Some(content_length) = parse_content_length(&response.headers)? {
                if content_length != object_size {
                    return Err(SidecarError::new(
                        "object_conflict",
                        "Download size mismatch; partial file discarded.",
                    ));
                }
            }
            let file = tokio::fs::File::create(target)
                .await
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            let mut file = BufWriter::with_capacity(DOWNLOAD_WRITE_BUFFER, file);
            let mut object_bytes = 0_u64;
            while let Some(chunk) = response.next_chunk().await? {
                if object_bytes.saturating_add(chunk.len() as u64) > object_size {
                    return Err(SidecarError::new(
                        "object_conflict",
                        "Oversized download body; partial file discarded.",
                    ));
                }
                if !chunk.is_empty() {
                    file.write_all(&chunk)
                        .await
                        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
                    object_bytes += chunk.len() as u64;
                    progress.note_activity();
                }
            }
            file.flush()
                .await
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
            if object_bytes != object_size {
                return Err(SidecarError::new(
                    "engine_unavailable",
                    "Download size mismatch; partial file discarded.",
                ));
            }
            Ok(object_bytes)
        }
        .await;

        match attempt_result {
            Ok(bytes) => break bytes,
            Err(error)
                if crate::client::is_transient(&error)
                    && attempt < max_attempts.clamp(1, 20) - 1 =>
            {
                attempt += 1;
                tokio::time::sleep(Duration::from_millis(100 << attempt.min(4))).await;
            }
            Err(error) => return Err(error),
        }
    };
    {
        let mut state = progress.state.lock().unwrap();
        state.bytes_transferred += downloaded_bytes;
    }
    progress.emit("running", Some(key.to_owned()));
    Ok(())
}

struct DownloadHeadMeta {
    size: u64,
    etag: Option<String>,
    version_id: Option<String>,
}

impl DownloadHeadMeta {
    fn can_range(&self, threshold: u64) -> bool {
        self.size >= threshold
            && self.size > 0
            && (self.etag.is_some() || self.version_id.as_deref().is_some_and(|id| id != "null"))
    }
}

pub async fn start_download(params: Value) -> SidecarResult {
    let customer_headers = encryption_headers(&params, false)?;
    let bucket_name = required_text(
        &params,
        "bucketName",
        "Bucket, keys, and destination path are required.",
    )?;
    let destination_path = required_text(
        &params,
        "destinationPath",
        "Bucket, keys, and destination path are required.",
    )?;
    let keys = exact_string_array(params.get("keys").unwrap_or(&Value::Null));
    if keys.is_empty() {
        return Err(SidecarError::new(
            "invalid_config",
            "Bucket, keys, and destination path are required.",
        ));
    }
    let conflict_policy = params["conflictPolicy"].as_str().unwrap_or("keepBoth");
    if conflict_policy != "keepBoth" && conflict_policy != "replace" {
        return Err(SidecarError::new(
            "invalid_config",
            "Unknown download conflict policy.",
        ));
    }
    let version_id = params["versionId"]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let multipart_threshold_bytes = params["multipartThresholdMiB"]
        .as_u64()
        .unwrap_or(DEFAULT_MULTIPART_THRESHOLD_MIB)
        .max(1)
        .saturating_mul(MIB);
    let multipart_chunk_bytes = params["multipartChunkMiB"]
        .as_u64()
        .unwrap_or(DEFAULT_UPLOAD_PART_MIB)
        .max(1)
        .saturating_mul(MIB);
    let max_attempts = profile_max_attempts(&params);

    let client = Arc::new(Client::new(&params["profile"])?);
    let concurrency = transfer_concurrency(&client);

    let destination = PathBuf::from(&destination_path);
    fs::create_dir_all(&destination)
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;

    let mut head_meta: Vec<Option<DownloadHeadMeta>> = (0..keys.len()).map(|_| None).collect();
    run_bounded(
        keys.len() as u64,
        concurrency,
        |index| {
            let client = Arc::clone(&client);
            let customer_headers = customer_headers.clone();
            let bucket_name = bucket_name.clone();
            let key = keys[index as usize].clone();
            let version_id = version_id.clone();
            async move {
                let mut query = Vec::with_capacity(1);
                if let Some(version) = &version_id {
                    query.push(("versionId", version.as_str()));
                }
                let response = client
                    .send(
                        Method::HEAD,
                        Some(&bucket_name),
                        Some(&key),
                        &query,
                        customer_headers,
                        Payload::Empty,
                        Retry::Safe,
                    )
                    .await
                    .map_err(|error| crate::operations::with_read_hint(error, false))?;
                let status = response.status;
                let headers = response.headers.clone();
                if !status.is_success() {
                    let body = response.bytes().await.unwrap_or_default();
                    ensure_http_status(status, None, &body)?;
                }
                let size = parse_content_length(&headers)?.ok_or_else(|| {
                    SidecarError::new(
                        "invalid_response",
                        format!("HEAD response for {key} did not include Content-Length."),
                    )
                })?;
                let etag = response_etag(&headers);
                let version_id = version_id.or_else(|| {
                    header_str(
                        &headers,
                        &header::HeaderName::from_static("x-amz-version-id"),
                    )
                    .filter(|id| !id.is_empty())
                    .map(str::to_owned)
                });
                Ok::<(usize, DownloadHeadMeta), SidecarError>((
                    index as usize,
                    DownloadHeadMeta {
                        size,
                        etag,
                        version_id,
                    },
                ))
            }
        },
        |(index, meta)| {
            head_meta[index] = Some(meta);
        },
    )
    .await?;

    let mut total_bytes = 0_u64;
    let mut parts_total = 0_u64;
    let mut uses_multipart = false;
    let metas: Vec<DownloadHeadMeta> = head_meta
        .into_iter()
        .map(|item| {
            item.ok_or_else(|| {
                SidecarError::new("internal_error", "Missing HEAD metadata for download key.")
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    for meta in &metas {
        total_bytes = total_bytes
            .checked_add(meta.size)
            .ok_or_else(|| SidecarError::new("invalid_config", "Total download size overflow."))?;
        if meta.can_range(multipart_threshold_bytes) {
            uses_multipart = true;
            parts_total += meta.size.div_ceil(multipart_chunk_bytes);
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
                "Queued {} object(s) for download to {destination_path} at {}.",
                keys.len(),
                now_iso()
            )],
        }),
    });
    progress.emit("queued", keys.first().cloned());

    let mut destination_index = DestinationIndex::new(&destination)
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;

    for (key, meta) in keys.iter().zip(&metas) {
        let staged = destination_index
            .stage()
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        let target = staged.0.clone();
        let object_size = meta.size;
        {
            let mut state = progress.state.lock().unwrap();
            state.output_lines.push(format!(
                "Downloading {key} ({object_size} bytes) to {:?}.",
                target
            ));
        }

        if meta.can_range(multipart_threshold_bytes) {
            download_object_ranged(
                &client,
                meta.etag.clone(),
                meta.version_id.clone(),
                &bucket_name,
                key,
                &target,
                object_size,
                multipart_chunk_bytes,
                concurrency,
                max_attempts,
                &progress,
                &customer_headers,
            )
            .await?;
        } else {
            download_object_single(
                &client,
                meta.etag.clone(),
                meta.version_id.clone(),
                &bucket_name,
                key,
                &target,
                object_size,
                max_attempts,
                &progress,
                &customer_headers,
            )
            .await?;
        }

        let staged_meta = fs::metadata(&target)
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
        if staged_meta.len() != object_size {
            return Err(SidecarError::new(
                "object_conflict",
                "Downloaded file size did not match HEAD Content-Length; partial file discarded.",
            ));
        }

        tokio::fs::OpenOptions::new()
            .write(true)
            .open(&target)
            .await
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?
            .sync_all()
            .await
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;

        let final_path = staged
            .publish_with_index(&mut destination_index, key, conflict_policy)
            .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
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
        output_lines,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TempDir(PathBuf);
    impl TempDir {
        fn new(prefix: &str) -> Self {
            let path = std::env::temp_dir().join(format!("odb-raw-{prefix}-{}", Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn loopback_profile(endpoint: &str, max_attempts: u32) -> Value {
        json!({
            "id": "fixture",
            "endpointType": "s3Compatible",
            "endpointUrl": endpoint,
            "region": "us-east-1",
            "accessKey": "fixture",
            "secretKey": "fixture",
            "pathStyle": true,
            "verifyTls": false,
            "maxAttempts": max_attempts,
            "maxPoolConnections": 4,
            "connectTimeoutSeconds": 2,
            "readTimeoutSeconds": 5
        })
    }

    struct RawRequest {
        method: String,
        target: String,
        headers: BTreeMap<String, String>,
        body: Vec<u8>,
    }

    fn read_http_request(stream: &mut std::net::TcpStream) -> Option<RawRequest> {
        stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
        let mut reader = BufReader::new(stream.try_clone().ok()?);
        let mut request_line = String::new();
        if reader.read_line(&mut request_line).ok()? == 0 {
            return None;
        }
        let mut parts = request_line.split_whitespace();
        let method = parts.next()?.to_owned();
        let target = parts.next()?.to_owned();
        let mut headers = BTreeMap::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).ok()?;
            let trimmed = line.trim_end_matches(['\r', '\n']);
            if trimmed.is_empty() {
                break;
            }
            if let Some((name, value)) = trimmed.split_once(':') {
                headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_owned());
            }
        }
        let content_length = headers
            .get("content-length")
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        let mut body = vec![0_u8; content_length];
        if content_length > 0 {
            reader.read_exact(&mut body).ok()?;
        }
        Some(RawRequest {
            method,
            target,
            headers,
            body,
        })
    }

    #[test]
    fn upload_part_sizes_are_clamped_to_s3_limits() {
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
            assert_eq!(upload_part_size_bytes(&input), expected * MIB);
        }
    }

    #[test]
    fn upload_size_validation_checks_object_and_part_boundaries() {
        let chunk = 5 * MIB;
        for size in [0, chunk - 1, chunk, chunk * 10_000] {
            validate_upload_size(size, 1, chunk).unwrap();
        }
        validate_upload_size(MAX_S3_OBJECT_BYTES, 1, 5 * 1024 * MIB).unwrap();
        validate_upload_size(MAX_SINGLE_PUT_BYTES, MAX_S3_OBJECT_BYTES, chunk).unwrap();
        for (size, threshold, part_size) in [
            (chunk * 10_000 + 1, 1, chunk),
            (chunk * 10_000 + 1, MAX_S3_OBJECT_BYTES, chunk),
            (chunk * 10_000 + 1, chunk * 10_000 + 1, chunk),
            (MAX_S3_OBJECT_BYTES + 1, u64::MAX, chunk),
            (u64::MAX, 1, chunk),
        ] {
            let error = validate_upload_size(size, threshold, part_size).unwrap_err();
            assert_eq!(error.code, "invalid_config");
        }
    }

    #[test]
    fn upload_key_resolution_preserves_exact_prefix_and_mapped_keys() {
        let mut mapping = BTreeMap::new();
        mapping.insert(
            "/tmp/local.txt".to_owned(),
            " /nested/ report .txt ".to_owned(),
        );
        let key = resolve_upload_key(
            "/tmp/local.txt",
            Path::new("/tmp/local.txt"),
            " pre/ ",
            &mapping,
        )
        .unwrap();
        assert_eq!(key, " pre/  /nested/ report .txt ");

        let fallback = resolve_upload_key(
            "/tmp/other.bin",
            Path::new("/tmp/other.bin"),
            " pre/ ",
            &mapping,
        )
        .unwrap();
        assert_eq!(fallback, " pre/ other.bin");
    }

    #[test]
    fn xml_helpers_round_trip_and_detect_embedded_errors() {
        let init = br#"<?xml version="1.0" encoding="UTF-8"?>
            <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <Bucket>b</Bucket><Key>k</Key><UploadId>up-123</UploadId>
            </InitiateMultipartUploadResult>"#;
        assert_eq!(parse_initiate_multipart_upload(init).unwrap(), "up-123");

        let xml = serialize_complete_multipart_upload(&[
            (1, "\"etag-1\"".to_owned()),
            (2, "\"etag-2\"".to_owned()),
        ])
        .unwrap();
        let xml_str = std::str::from_utf8(&xml).unwrap();
        assert!(xml_str.contains("xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\""));
        assert!(
            xml_str.find("<PartNumber>1</PartNumber>").unwrap()
                < xml_str.find("<PartNumber>2</PartNumber>").unwrap()
        );
        assert!(
            xml_str.contains("<ETag>\"etag-1\"</ETag>")
                || xml_str.contains("<ETag>&quot;etag-1&quot;</ETag>")
        );

        let complete_ok = br#"
            <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <ETag>"final-etag"</ETag>
            </CompleteMultipartUploadResult>"#;
        parse_complete_multipart_upload(complete_ok).unwrap();

        let embedded_err = br#"
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>InternalError</Code><Message>Completion failed</Message></Error>"#;
        let err = parse_complete_multipart_upload(embedded_err).unwrap_err();
        assert!(err.message.contains("Completion failed"));
    }

    #[test]
    fn interactive_controls_are_explicitly_unsupported() {
        let err = unsupported_transfer_control();
        assert_eq!(err.code, "unsupported_feature");
    }

    #[tokio::test]
    async fn single_and_multipart_upload_preserve_exact_keys_order_parts_and_abort_on_200_error() {
        let dir = TempDir::new("upload");
        let small = dir.0.join("small.txt");
        fs::write(&small, b"hello raw upload").unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let req = read_http_request(&mut stream).unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nETag: \"small-etag\"\r\nConnection: close\r\n\r\n")
                .unwrap();
            req
        });

        let result = start_upload(json!({
            "profile": loopback_profile(&endpoint, 1),
            "bucketName": "bucket",
            "prefix": " dir/ ",
            "filePaths": [small.to_string_lossy()],
            "objectKeyByPath": { small.to_string_lossy().to_string(): " report .txt " },
            "multipartThresholdMiB": 32,
            "multipartChunkMiB": 5,
        }))
        .await
        .unwrap();
        assert_eq!(result["status"], "completed");
        assert_eq!(result["bytesTransferred"], 16);
        assert_eq!(result["canPause"], false);
        assert_eq!(result["canResume"], false);
        assert_eq!(result["canCancel"], false);
        let req = server.join().unwrap();
        assert_eq!(req.method, "PUT");
        assert_eq!(req.target, "/bucket/%20dir/%20%20report%20.txt%20");
        assert_eq!(req.body, b"hello raw upload");

        // Multipart upload where CompleteMultipartUpload returns HTTP 200 with embedded <Error>
        // must fail and issue AbortMultipartUpload.
        let big = dir.0.join("big.bin");
        let part_size = 5 * MIB as usize;
        let payload = vec![b'Z'; part_size + 128];
        fs::write(&big, &payload).unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let aborts = Arc::new(AtomicUsize::new(0));
        let aborts_clone = Arc::clone(&aborts);
        let server = std::thread::spawn(move || {
            let mut complete_body = String::new();
            for _ in 0..5 {
                let (mut stream, _) = listener.accept().unwrap();
                let req = read_http_request(&mut stream).unwrap();
                if req.method == "POST" && req.target.contains("uploads") {
                    let body = b"<InitiateMultipartUploadResult><UploadId>u-42</UploadId></InitiateMultipartUploadResult>";
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .unwrap();
                    stream.write_all(body).unwrap();
                } else if req.method == "PUT" && req.target.contains("uploadId=u-42") {
                    let part_num = if req.target.contains("partNumber=1") {
                        "1"
                    } else {
                        "2"
                    };
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nETag: \"p-{part_num}\"\r\nConnection: close\r\n\r\n"
                    )
                    .unwrap();
                } else if req.method == "POST" && req.target.contains("uploadId=u-42") {
                    complete_body = String::from_utf8(req.body).unwrap();
                    let body = b"   \n<Error><Code>InternalError</Code><Message>complete failed</Message></Error>";
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .unwrap();
                    stream.write_all(body).unwrap();
                } else if req.method == "DELETE" && req.target.contains("uploadId=u-42") {
                    aborts_clone.fetch_add(1, Ordering::SeqCst);
                    stream
                        .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        .unwrap();
                }
            }
            complete_body
        });

        let err = start_upload(json!({
            "profile": loopback_profile(&endpoint, 1),
            "bucketName": "bucket",
            "prefix": "",
            "filePaths": [big.to_string_lossy()],
            "multipartThresholdMiB": 5,
            "multipartChunkMiB": 5,
        }))
        .await
        .unwrap_err();
        assert!(
            err.message.contains("complete failed")
                || err.code == "engine_unavailable"
                || err.code == "unknown"
        );
        let complete_xml = server.join().unwrap();
        assert_eq!(aborts.load(Ordering::SeqCst), 1);
        assert!(
            complete_xml.find("<PartNumber>1</PartNumber>").unwrap()
                < complete_xml.find("<PartNumber>2</PartNumber>").unwrap()
        );
    }

    #[tokio::test]
    async fn download_validates_206_content_range_etag_and_cleans_temp_on_failure() {
        let dir = TempDir::new("download");
        let data = vec![b'A'; MIB as usize + 37];
        let data_clone = data.clone();

        // Successful ranged download with If-Match binding.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let mut saw_if_match = 0;
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let req = read_http_request(&mut stream).unwrap();
                if req.method == "HEAD" {
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n",
                        data_clone.len()
                    )
                    .unwrap();
                } else if req.method == "GET" {
                    if req.headers.get("if-match").map(String::as_str) == Some("\"v1\"") {
                        saw_if_match += 1;
                    }
                    let range = req.headers.get("range").unwrap();
                    let (s, e) = range
                        .strip_prefix("bytes=")
                        .unwrap()
                        .split_once('-')
                        .unwrap();
                    let start: usize = s.parse().unwrap();
                    let end: usize = e.parse().unwrap();
                    let slice = &data_clone[start..=end];
                    write!(
                        stream,
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n",
                        slice.len(),
                        data_clone.len()
                    )
                    .unwrap();
                    stream.write_all(slice).unwrap();
                }
            }
            saw_if_match
        });

        let result = start_download(json!({
            "profile": loopback_profile(&endpoint, 1),
            "bucketName": "bucket",
            "keys": ["nested/file.bin"],
            "destinationPath": dir.0.to_string_lossy(),
            "multipartThresholdMiB": 1,
            "multipartChunkMiB": 1,
        }))
        .await
        .unwrap();
        assert_eq!(result["status"], "completed");
        assert_eq!(result["bytesTransferred"], data.len() as u64);
        assert_eq!(fs::read(dir.0.join("file.bin")).unwrap(), data);
        assert_eq!(server.join().unwrap(), 2);

        // Use one range here so the fixture can return HTTP 200 without an
        // unanswered concurrent request racing the expected error.
        let fail_dir = TempDir::new("download-fail");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let data_clone = data.clone();
        let server = std::thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let req = read_http_request(&mut stream).unwrap();
                if req.method == "HEAD" {
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n",
                        data_clone.len()
                    )
                    .unwrap();
                } else {
                    assert_eq!(req.method, "GET");
                    assert_eq!(
                        req.headers.get("range").map(String::as_str),
                        Some(format!("bytes=0-{}", data_clone.len() - 1).as_str())
                    );
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n",
                        data_clone.len()
                    )
                    .unwrap();
                    let _ = stream.write_all(&data_clone);
                    break;
                }
            }
        });

        let err = start_download(json!({
            "profile": loopback_profile(&endpoint, 1),
            "bucketName": "bucket",
            "keys": ["nested/file.bin"],
            "destinationPath": fail_dir.0.to_string_lossy(),
            "multipartThresholdMiB": 1,
            "multipartChunkMiB": 2,
        }))
        .await
        .unwrap_err();
        server.join().unwrap();
        assert_eq!(err.code, "object_conflict");
        assert_eq!(err.details["httpStatus"], 200);
        assert!(fs::read_dir(&fail_dir.0).unwrap().next().is_none());
    }

    #[tokio::test]
    async fn multipart_upload_aborts_when_part_etag_is_missing_and_validates_broken_range_retry() {
        let dir = TempDir::new("missing-etag");
        let big = dir.0.join("big.bin");
        let part_size = 5 * MIB as usize;
        fs::write(&big, vec![b'Q'; part_size + 10]).unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let aborts = Arc::new(AtomicUsize::new(0));
        let aborts_clone = Arc::clone(&aborts);
        let server = std::thread::spawn(move || {
            let mut saw_abort = false;
            while !saw_abort {
                let (mut stream, _) = listener.accept().unwrap();
                let Some(req) = read_http_request(&mut stream) else {
                    continue;
                };
                if req.method == "POST" && req.target.contains("uploads") {
                    let body = b"<InitiateMultipartUploadResult><UploadId>u-no-etag</UploadId></InitiateMultipartUploadResult>";
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .unwrap();
                    stream.write_all(body).unwrap();
                } else if req.method == "PUT" {
                    // Omit ETag header on UploadPart -> must fail and abort upload.
                    stream
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        )
                        .unwrap();
                } else if req.method == "DELETE" && req.target.contains("uploadId=u-no-etag") {
                    aborts_clone.fetch_add(1, Ordering::SeqCst);
                    saw_abort = true;
                    stream
                        .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        .unwrap();
                }
            }
        });

        let err = start_upload(json!({
            "profile": loopback_profile(&endpoint, 1),
            "bucketName": "bucket",
            "prefix": "",
            "filePaths": [big.to_string_lossy()],
            "multipartThresholdMiB": 5,
            "multipartChunkMiB": 5,
        }))
        .await
        .unwrap_err();
        assert_eq!(err.code, "invalid_response");
        server.join().unwrap();
        assert_eq!(aborts.load(Ordering::SeqCst), 1);

        // Ranged download retries a truncated stream body when maxAttempts > 1.
        let dl_dir = TempDir::new("range-retry");
        let data = vec![b'M'; MIB as usize];
        let data_clone = data.clone();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let mut gets = 0;
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let req = read_http_request(&mut stream).unwrap();
                if req.method == "HEAD" {
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"v-retry\"\r\nConnection: close\r\n\r\n",
                        data_clone.len()
                    )
                    .unwrap();
                } else {
                    gets += 1;
                    write!(
                        stream,
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes 0-{}/{}\r\nETag: \"v-retry\"\r\nConnection: close\r\n\r\n",
                        data_clone.len(),
                        data_clone.len() - 1,
                        data_clone.len()
                    )
                    .unwrap();
                    if gets == 1 {
                        let _ = stream.write_all(&data_clone[..1024]);
                    } else {
                        let _ = stream.write_all(&data_clone);
                    }
                }
            }
            gets
        });

        let result = start_download(json!({
            "profile": loopback_profile(&endpoint, 3),
            "bucketName": "bucket",
            "keys": ["retry.bin"],
            "destinationPath": dl_dir.0.to_string_lossy(),
            "multipartThresholdMiB": 1,
            "multipartChunkMiB": 1,
        }))
        .await
        .unwrap();
        assert_eq!(result["status"], "completed");
        assert_eq!(result["bytesTransferred"], data.len() as u64);
        assert_eq!(result["partsCompleted"], 1);
        assert_eq!(fs::read(dl_dir.0.join("retry.bin")).unwrap(), data);
        assert_eq!(server.join().unwrap(), 2);
    }

    #[tokio::test]
    async fn download_conflict_policies_keep_both_and_replace_preserve_existing_on_failure() {
        let dir = TempDir::new("conflict");
        fs::write(dir.0.join("report.txt"), b"LOCAL").unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            for _ in 0..4 {
                let (mut stream, _) = listener.accept().unwrap();
                let req = read_http_request(&mut stream).unwrap();
                let body: &[u8] = if req.target.ends_with("a/report.txt") {
                    b"FIRST"
                } else {
                    b"SECOND"
                };
                if req.method == "HEAD" {
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"e1\"\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .unwrap();
                } else {
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"e1\"\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .unwrap();
                    stream.write_all(body).unwrap();
                }
            }
        });

        let result = start_download(json!({
            "profile": loopback_profile(&endpoint, 1),
            "bucketName": "bucket",
            "keys": ["a/report.txt", "b/report.txt"],
            "destinationPath": dir.0.to_string_lossy(),
            "conflictPolicy": "keepBoth",
            "multipartThresholdMiB": 32,
            "multipartChunkMiB": 1,
        }))
        .await
        .unwrap();
        assert_eq!(result["status"], "completed");
        assert_eq!(fs::read(dir.0.join("report.txt")).unwrap(), b"LOCAL");
        let mut contents: Vec<Vec<u8>> = fs::read_dir(&dir.0)
            .unwrap()
            .map(|e| fs::read(e.unwrap().path()).unwrap())
            .collect();
        contents.sort();
        assert_eq!(
            contents,
            vec![b"FIRST".to_vec(), b"LOCAL".to_vec(), b"SECOND".to_vec()]
        );
        server.join().unwrap();

        // Short body under conflictPolicy=replace must fail and leave LOCAL untouched.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let req = read_http_request(&mut stream).unwrap();
                if req.method == "HEAD" {
                    stream
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nETag: \"e2\"\r\nConnection: close\r\n\r\n")
                        .unwrap();
                } else {
                    stream
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nETag: \"e2\"\r\nConnection: close\r\n\r\nNO")
                        .unwrap();
                }
            }
        });

        let err = start_download(json!({
            "profile": loopback_profile(&endpoint, 1),
            "bucketName": "bucket",
            "keys": ["report.txt"],
            "destinationPath": dir.0.to_string_lossy(),
            "conflictPolicy": "replace",
            "multipartThresholdMiB": 32,
            "multipartChunkMiB": 1,
        }))
        .await
        .unwrap_err();
        assert_eq!(err.code, "object_conflict");
        assert_eq!(fs::read(dir.0.join("report.txt")).unwrap(), b"LOCAL");
        server.join().unwrap();
    }
}
