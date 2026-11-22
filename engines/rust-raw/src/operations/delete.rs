//! DeleteObjects batches with per-item outcomes. A batch is never replayed:
//! an uncertain request is reported as `unknown_outcome`, and later batches
//! are not attempted.

use super::*;

/// S3 accepts at most this many objects in one DeleteObjects request.
pub const DELETE_BATCH_LIMIT: usize = 1000;

/// Result for one requested key/version. `code` is `None` on success.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeleteOutcome {
    pub key: String,
    pub version_id: Option<String>,
    pub code: Option<String>,
    pub message: Option<String>,
}

impl DeleteOutcome {
    pub fn succeeded(&self) -> bool {
        self.code.is_none()
    }

    fn ok(key: &str, version: Option<&str>) -> Self {
        Self {
            key: key.to_string(),
            version_id: version.map(str::to_owned),
            code: None,
            message: None,
        }
    }

    fn failed(key: &str, version: Option<&str>, code: &str, message: &str) -> Self {
        Self {
            key: key.to_string(),
            version_id: version.map(str::to_owned),
            code: Some(code.to_string()),
            message: Some(crate::secret_hygiene::text(message)),
        }
    }

    fn failure_json(&self) -> Value {
        json!({
            "target": self.key,
            "versionId": self.version_id,
            "code": self.code.as_deref().unwrap_or("unknown"),
            "message": self.message.as_deref().unwrap_or("Unknown delete error."),
        })
    }
}

/// Builds the DeleteObjects request body for the given (already XML-safe)
/// objects. Carriage returns are sent as character references.
pub(crate) fn delete_request_body(
    objects: &[(&str, Option<&str>)],
) -> Result<Vec<u8>, SidecarError> {
    let mut body = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete xmlns=\"");
    body.push_str(xml::S3_NAMESPACE);
    body.push_str("\"><Quiet>false</Quiet>");
    for (key, version) in objects {
        body.push_str("<Object>");
        xml::text_element("Key", key, &mut body)?;
        if let Some(version) = version {
            xml::text_element("VersionId", version, &mut body)?;
        }
        body.push_str("</Object>");
    }
    body.push_str("</Delete>");
    Ok(body.into_bytes())
}

/// Matches a DeleteResult to the requested objects. Objects the provider did
/// not mention are reported as `unknown_outcome`.
pub(crate) fn match_delete_result(
    root: &Node,
    requested: &[(&str, Option<&str>)],
) -> Result<Vec<DeleteOutcome>, SidecarError> {
    let encoded = listing_encoded(root);
    let mut outcomes: Vec<Option<DeleteOutcome>> = vec![None; requested.len()];
    for entry in &root.children {
        let deleted = match entry.name.as_str() {
            "Deleted" => true,
            "Error" => false,
            _ => continue,
        };
        let key = decode_listing_value(entry.text_of("Key").unwrap_or_default(), encoded)?;
        let version = entry.text_of("VersionId").filter(|value| !value.is_empty());
        let exact = requested
            .iter()
            .enumerate()
            .position(|(index, (k, v))| outcomes[index].is_none() && *k == key && *v == version);
        let loose = || {
            requested.iter().enumerate().position(|(index, (k, v))| {
                outcomes[index].is_none() && *k == key && (v.is_none() || version.is_none())
            })
        };
        let Some(index) = exact.or_else(loose) else {
            continue;
        };
        let (k, v) = requested[index];
        outcomes[index] = Some(if deleted {
            DeleteOutcome::ok(k, v)
        } else {
            DeleteOutcome::failed(
                k,
                v,
                entry
                    .text_of("Code")
                    .filter(|code| !code.is_empty())
                    .unwrap_or("unknown"),
                entry
                    .text_of("Message")
                    .filter(|message| !message.is_empty())
                    .unwrap_or("Unknown delete error."),
            )
        });
    }
    Ok(outcomes
        .into_iter()
        .zip(requested)
        .map(|(outcome, (key, version))| {
            outcome.unwrap_or_else(|| {
                DeleteOutcome::failed(
                    key,
                    *version,
                    "unknown_outcome",
                    "The provider did not report a result for this object.",
                )
            })
        })
        .collect())
}

fn bypass_headers(bypass: bool) -> HeaderMap {
    let mut headers = HeaderMap::new();
    if bypass {
        headers.insert(
            HeaderName::from_static("x-amz-bypass-governance-retention"),
            HeaderValue::from_static("true"),
        );
    }
    headers
}

/// Deletes up to [`DELETE_BATCH_LIMIT`] objects with one DeleteObjects request
/// (Content-MD5 and `Quiet=false`). Keys XML 1.0 cannot carry are deleted one
/// at a time after the batch. Returns `Err` only when the batch request itself
/// failed; its outcome is then unknown and nothing later was attempted.
pub async fn delete_batch(
    client: &Client,
    bucket: &str,
    objects: &[(&str, Option<&str>)],
    bypass: bool,
) -> Result<Vec<DeleteOutcome>, SidecarError> {
    if objects.len() > DELETE_BATCH_LIMIT {
        return Err(invalid_config(format!(
            "A delete batch holds at most {DELETE_BATCH_LIMIT} objects."
        )));
    }
    let mut outcomes: Vec<Option<DeleteOutcome>> = vec![None; objects.len()];
    let mut batch = Vec::new();
    let mut single = Vec::new();
    for (index, (key, version)) in objects.iter().enumerate() {
        if key.is_empty() {
            outcomes[index] = Some(DeleteOutcome::failed(
                key,
                *version,
                "invalid_config",
                "An object key is required.",
            ));
        } else if accepts_batch_xml(key, *version) {
            batch.push(index);
        } else {
            single.push(index);
        }
    }
    if !batch.is_empty() {
        let requested: Vec<(&str, Option<&str>)> =
            batch.iter().map(|index| objects[*index]).collect();
        let body = delete_request_body(&requested)?;
        let mut headers = xml_headers(&body);
        headers.extend(bypass_headers(bypass));
        let (_, response) = call(
            client,
            Method::POST,
            Some(bucket),
            None,
            &[("delete", "")],
            headers,
            Payload::Bytes(Bytes::from(body)),
            Retry::Never,
        )
        .await?;
        let root = parse_document(&response, "DeleteResult")?;
        for (index, outcome) in batch.iter().zip(match_delete_result(&root, &requested)?) {
            outcomes[*index] = Some(outcome);
        }
    }
    for index in single {
        let (key, version) = objects[index];
        let query: Vec<(&str, &str)> = version
            .map(|value| ("versionId", value))
            .into_iter()
            .collect();
        let result = call(
            client,
            Method::DELETE,
            Some(bucket),
            Some(key),
            &query,
            bypass_headers(bypass),
            Payload::Empty,
            Retry::Never,
        )
        .await;
        outcomes[index] = Some(match result {
            Ok(_) => DeleteOutcome::ok(key, version),
            Err(error) => {
                let code = if error_status(&error).is_some() {
                    aws_code(&error).unwrap_or_else(|| error.code.to_string())
                } else {
                    "unknown_outcome".to_string()
                };
                DeleteOutcome::failed(key, version, &code, &error.message)
            }
        });
    }
    Ok(outcomes
        .into_iter()
        .map(|outcome| outcome.expect("every object has an outcome"))
        .collect())
}

fn accepts_batch_xml(key: &str, version: Option<&str>) -> bool {
    xml::is_xml_text(key) && version.is_none_or(xml::is_xml_text)
}

fn batch_failure(key: &str, version: Option<&str>, code: &str, message: &str) -> Value {
    if accepts_batch_xml(key, version) {
        return DeleteOutcome::failed(key, version, code, message).failure_json();
    }
    DeleteOutcome::failed(
        key,
        version,
        "not_attempted",
        "The individual deletion was skipped after its batch failed.",
    )
    .failure_json()
}

/// Runs batches in order. A definite HTTP rejection fails only its batch; an
/// uncertain batch stops the operation so nothing is replayed or skipped silently.
async fn delete_all(
    client: &Client,
    bucket: &str,
    objects: &[(&str, Option<&str>)],
    bypass: bool,
) -> SidecarResult {
    let mut succeeded = 0usize;
    let mut failures = Vec::new();
    for (index, chunk) in objects.chunks(DELETE_BATCH_LIMIT).enumerate() {
        match delete_batch(client, bucket, chunk, bypass).await {
            Ok(outcomes) => {
                for outcome in outcomes {
                    if outcome.succeeded() {
                        succeeded += 1;
                    } else {
                        failures.push(outcome.failure_json());
                    }
                }
            }
            Err(error)
                if error_status(&error).is_some_and(|status| (400..500).contains(&status)) =>
            {
                let code = aws_code(&error).unwrap_or_else(|| error.code.to_string());
                for (key, version) in chunk {
                    failures.push(batch_failure(key, *version, &code, &error.message));
                }
            }
            Err(error) => {
                let message = format!("Delete was not confirmed: {}", error.message);
                for (key, version) in chunk {
                    failures.push(batch_failure(key, *version, "unknown_outcome", &message));
                }
                for (key, version) in objects.iter().skip((index + 1) * DELETE_BATCH_LIMIT) {
                    failures.push(
                        DeleteOutcome::failed(
                            key,
                            *version,
                            "not_attempted",
                            "Stopped after an unconfirmed delete batch.",
                        )
                        .failure_json(),
                    );
                }
                break;
            }
        }
    }
    Ok(json!({"successCount": succeeded, "failureCount": failures.len(), "failures": failures}))
}

fn bypass_requested(params: &Value) -> bool {
    params["bypassGovernanceRetention"].as_bool() == Some(true)
}

pub(super) async fn delete_objects(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name and keys are required.")?;
    let keys: Vec<&str> = params["keys"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .filter(|key| !key.is_empty())
                .collect()
        })
        .unwrap_or_default();
    if keys.is_empty() {
        return Err(invalid_config("Bucket name and keys are required."));
    }
    let client = client_for(params)?;
    let objects: Vec<(&str, Option<&str>)> = keys.into_iter().map(|key| (key, None)).collect();
    delete_all(&client, &bucket, &objects, bypass_requested(params)).await
}

pub(super) async fn delete_object_versions(params: &Value) -> SidecarResult {
    let bucket = bucket_name(params, "Bucket name and versions are required.")?;
    let versions = params["versions"]
        .as_array()
        .filter(|items| !items.is_empty())
        .ok_or_else(|| invalid_config("Bucket name and versions are required."))?;
    let objects: Vec<(&str, Option<&str>)> = versions
        .iter()
        .map(|item| {
            (
                item["key"].as_str().unwrap_or_default(),
                item["versionId"]
                    .as_str()
                    .filter(|version| !version.is_empty()),
            )
        })
        .collect();
    let client = client_for(params)?;
    delete_all(&client, &bucket, &objects, bypass_requested(params)).await
}
