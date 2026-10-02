//! Bounded, version-aware deletion and the opt-in-by-workflow compatible-store metadata repair.
use super::*;
use std::sync::atomic::AtomicBool;
static JOBS: OnceLock<Mutex<BTreeMap<String, Arc<AtomicBool>>>> = OnceLock::new();

#[derive(Clone)]
struct Entry {
    id: ObjectIdentifier,
    etag: Option<String>,
    size: Option<i64>,
    modified: Option<String>,
}
fn retryable(code: &str) -> bool {
    matches!(
        code,
        "InternalError"
            | "InternalServerError"
            | "ServiceUnavailable"
            | "SlowDown"
            | "RequestTimeout"
            | "OperationAborted"
            | "503"
            | "500"
    )
}
fn stale_eligible(code: &str) -> bool {
    retryable(code) || matches!(code, "NoSuchKey" | "NoSuchObject" | "InvalidObjectState")
}
fn code(error: &SidecarError) -> &str {
    error.details["awsCode"].as_str().unwrap_or("Unknown")
}
fn checkpoint(cancel: &AtomicBool) -> Result<(), SidecarError> {
    if cancel.load(AtomicOrdering::Relaxed) {
        Err(SidecarError::new("cancelled", "Deletion cancelled."))
    } else {
        Ok(())
    }
}
async fn backoff(attempt: u32, cancel: &AtomicBool) -> Result<(), SidecarError> {
    for _ in 0..(1_u32 << attempt.min(5)) {
        checkpoint(cancel)?;
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    checkpoint(cancel)
}
async fn versioning(client: &Client, bucket: &str) -> Result<String, SidecarError> {
    let result = client
        .get_bucket_versioning()
        .bucket(bucket)
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(result
        .status()
        .map(|v| v.as_str())
        .unwrap_or("never-enabled")
        .to_string())
}
fn eligible(profile: &Value) -> bool {
    let host = url::Url::parse(profile["endpointUrl"].as_str().unwrap_or(""))
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .unwrap_or_default()
        .to_lowercase();
    profile["endpointType"].as_str().unwrap_or("s3Compatible") == "s3Compatible"
        && !host.is_empty()
        && !(host == "amazonaws.com"
            || host.ends_with(".amazonaws.com")
            || host.ends_with(".amazonaws.com.cn")
            || host.ends_with(".c2s.ic.gov")
            || host.ends_with(".sc2s.sgov.gov"))
}
async fn present(
    client: &Client,
    bucket: &str,
    entry: &Entry,
) -> Result<Option<Entry>, SidecarError> {
    let result = client
        .list_objects_v2()
        .bucket(bucket)
        .prefix(entry.id.key())
        .max_keys(1)
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(result
        .contents()
        .iter()
        .find(|o| o.key() == Some(entry.id.key()))
        .map(|o| Entry {
            id: entry.id.clone(),
            etag: o.e_tag().map(str::to_owned),
            size: o.size(),
            modified: o.last_modified().map(ToString::to_string),
        }))
}
fn same(a: &Entry, b: &Entry) -> bool {
    a.etag.is_some() && a.etag == b.etag && a.size == b.size && a.modified == b.modified
}
async fn single(
    client: &Client,
    bucket: &str,
    entry: &Entry,
    retries: u32,
    cancel: &AtomicBool,
) -> Result<(), SidecarError> {
    for attempt in 0..=retries {
        checkpoint(cancel)?;
        match client
            .delete_object()
            .bucket(bucket)
            .key(entry.id.key())
            .set_version_id(entry.id.version_id().map(str::to_owned))
            .set_if_match(entry.etag.clone())
            .send()
            .await
        {
            Ok(_) => return Ok(()),
            Err(e) => {
                let e = map_sdk_error(e);
                if attempt == retries || !retryable(code(&e)) {
                    return Err(e);
                }
                backoff(attempt, cancel).await?;
            }
        }
    }
    unreachable!()
}
async fn recover(
    client: &Client,
    bucket: &str,
    entry: Entry,
    retries: u32,
    repair: bool,
    cancel: Arc<AtomicBool>,
    batch_error: Option<String>,
) -> Result<String, SidecarError> {
    checkpoint(&cancel)?;
    // Version failures retain their exact version ID; no key-only fallback is possible.
    if entry.id.version_id().is_some() {
        return Err(SidecarError::new(
            "delete_failed",
            batch_error.unwrap_or_else(|| "Version deletion failed.".into()),
        ));
    }
    if let Some(e) = batch_error.as_deref() {
        if !stale_eligible(e) {
            return Err(SidecarError::new(
                "delete_failed",
                format!("{}: {e}; recovery skipped.", entry.id.key()),
            ));
        }
    }
    let mut before = present(client, bucket, &entry).await?;
    if before.is_none() {
        return Ok("deleted".into());
    }
    if batch_error.is_none() {
        for attempt in 0..retries {
            backoff(attempt, &cancel).await?;
            let response = client
                .delete_objects()
                .bucket(bucket)
                .delete(
                    Delete::builder()
                        .objects(entry.id.clone())
                        .quiet(false)
                        .build()
                        .unwrap(),
                )
                .send()
                .await
                .map_err(map_sdk_error)?;
            if response
                .errors()
                .iter()
                .any(|e| !stale_eligible(e.code().unwrap_or("Unknown")))
            {
                return Err(SidecarError::new(
                    "delete_failed",
                    "Recovery skipped after denied or unknown batch outcome.",
                ));
            }
            before = present(client, bucket, &entry).await?;
            if before.is_none() {
                return Ok("deleted after ordinary retries".into());
            }
        }
    }
    if !repair {
        return Err(SidecarError::new(
            "delete_failed",
            format!(
                "{} remains after bounded deletion; metadata recovery is not eligible.",
                entry.id.key()
            ),
        ));
    }
    if !same(&entry, before.as_ref().unwrap()) {
        return Err(SidecarError::new(
            "source_changed",
            "Object changed; recovery skipped.",
        ));
    }
    let result = single(client, bucket, &entry, retries, &cancel).await;
    if let Err(e) = &result {
        if !stale_eligible(code(e)) {
            return Err(SidecarError::new("delete_failed", e.message.clone()));
        }
    }
    checkpoint(&cancel)?;
    let current = present(client, bucket, &entry).await?;
    if current.is_none() {
        return Ok("deleted after individual DELETE".into());
    }
    if !same(&entry, current.as_ref().unwrap()) {
        return Err(SidecarError::new(
            "source_changed",
            "Object changed; recovery skipped.",
        ));
    }
    if versioning(client, bucket).await? != "never-enabled" {
        return Err(SidecarError::new(
            "invalid_config",
            "Versioning changed; metadata recovery skipped.",
        ));
    }
    // HEAD also catches retention and legal hold when the provider reports them.
    match client
        .head_object()
        .bucket(bucket)
        .key(entry.id.key())
        .send()
        .await
    {
        Ok(head) => {
            if head.e_tag() != entry.etag.as_deref()
                || head.object_lock_mode().is_some()
                || head
                    .object_lock_legal_hold_status()
                    .is_some_and(|v| v.as_str() == "ON")
            {
                return Err(SidecarError::new(
                    "source_changed",
                    "Object changed or is protected; recovery skipped.",
                ));
            }
        }
        Err(e) => {
            let e = map_sdk_error(e);
            if !matches!(code(&e), "NoSuchKey" | "NotFound" | "404") {
                return Err(e);
            }
        }
    }
    checkpoint(&cancel)?;
    // Never replay an ambiguous PUT; conditional replacement protects a concurrent upload.
    let reset = client
        .put_object()
        .bucket(bucket)
        .key(entry.id.key())
        .set_if_match(entry.etag.clone())
        .body(ByteStream::from_static(b""))
        .send()
        .await
        .map_err(|e| {
            SidecarError::with_details(
                "unknown_outcome",
                "Empty PUT failed or its completion is unknown; no further overwrite attempted.",
                json!({"cause":map_sdk_error(e).message}),
            )
        })?;
    if let Err(e) = checkpoint(&cancel) {
        return Err(SidecarError::new(
            e.code,
            "overwritten with an empty object; delete failed (cancelled)",
        ));
    }
    let mut empty_entry = entry.clone();
    empty_entry.etag = reset.e_tag().map(str::to_owned);
    if empty_entry.etag.is_none() {
        return Err(SidecarError::new(
            "empty_object_left",
            "overwritten with an empty object; delete failed (PUT returned no identity validator)",
        ));
    }
    let deletion = single(client, bucket, &empty_entry, retries, &cancel).await;
    if deletion.is_err()
        || present(client, bucket, &entry)
            .await
            .map_err(|_| {
                SidecarError::new(
                    "empty_object_left",
                    "overwritten with an empty object; delete outcome unknown",
                )
            })?
            .is_some()
    {
        return Err(SidecarError::new(
            "empty_object_left",
            "overwritten with an empty object; delete failed",
        ));
    }
    Ok("deleted after empty PUT metadata reset".into())
}

pub(super) async fn run(params: Value) -> SidecarResult {
    let mut profile = parse_profile(&params["profile"])?;
    profile.max_attempts = 1;
    let config = &params["config"];
    let bucket = required_text(config, "bucketName", "Bucket name is required.")?;
    let retries = config["maxRetries"].as_u64().unwrap_or(3).min(10) as u32;
    let page_size = config["listMaxKeys"]
        .as_i64()
        .unwrap_or(1000)
        .clamp(1, 1000) as i32;
    let batch_size = config["batchSize"].as_u64().unwrap_or(1000).clamp(1, 1000) as usize;
    let workers = config["maxWorkers"].as_u64().unwrap_or(4).clamp(1, 16) as usize;
    let prefix = config["prefix"].as_str().unwrap_or("");
    let id = params["jobId"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| format!("tool-{}", short_uuid()));
    let cancel = Arc::new(AtomicBool::new(false));
    JOBS.get_or_init(Default::default)
        .lock()
        .unwrap()
        .insert(id.clone(), cancel.clone());
    let client = build_client(&profile).await?;
    let state = versioning(&client, &bucket)
        .await
        .unwrap_or_else(|_| "unknown".into());
    let versions = state != "never-enabled";
    let repair = state == "never-enabled" && eligible(&params["profile"]);
    let mut deleted = 0_u64;
    let mut failed = 0_u64;
    let mut empty = 0_u64;
    let mut skipped = 0_u64;
    let mut unknown = 0_u64;
    let mut lines = vec![format!(
        "Bucket: {bucket}; versioning: {state}; metadata recovery eligible: {repair}."
    )];
    let mut previous_page = String::new();
    let mut repeat_count = 0_u32;
    let mut pending_versions = std::collections::BTreeSet::new();
    let execution: Result<(), SidecarError> = async {
        loop {
            checkpoint(&cancel)?;
            let entries: Vec<Entry> = if versions {
                let p = client
                    .list_object_versions()
                    .bucket(&bucket)
                    .prefix(prefix)
                    .max_keys(page_size)
                    .send()
                    .await
                    .map_err(map_sdk_error)?;
                p.versions()
                    .iter()
                    .map(|v| (v.key(), v.version_id()))
                    .chain(p.delete_markers().iter().map(|v| (v.key(), v.version_id())))
                    .map(|(k, v)| {
                        if v.is_none() {
                            return Err(SidecarError::new(
                                "invalid_config",
                                "Version listing omitted a version ID; refusing key-only deletion.",
                            ));
                        }
                        Ok(Entry {
                            id: ObjectIdentifier::builder()
                                .key(k.unwrap_or(""))
                                .set_version_id(v.map(str::to_owned))
                                .build()
                                .unwrap(),
                            etag: None,
                            size: None,
                            modified: None,
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()?
            } else {
                client
                    .list_objects_v2()
                    .bucket(&bucket)
                    .prefix(prefix)
                    .max_keys(page_size)
                    .send()
                    .await
                    .map_err(map_sdk_error)?
                    .contents()
                    .iter()
                    .map(|v| Entry {
                        id: ObjectIdentifier::builder()
                            .key(v.key().unwrap_or(""))
                            .build()
                            .unwrap(),
                        etag: v.e_tag().map(str::to_owned),
                        size: v.size(),
                        modified: v.last_modified().map(ToString::to_string),
                    })
                    .collect()
            };
            if versions {
                let listed = entries
                    .iter()
                    .map(|e| (e.id.key().to_string(), e.id.version_id().map(str::to_owned)))
                    .collect::<std::collections::BTreeSet<_>>();
                deleted += pending_versions.difference(&listed).count() as u64;
                pending_versions.retain(|v| listed.contains(v));
            }
            if entries.is_empty() {
                break;
            }
            let page = serde_json::to_string(
                &entries
                    .iter()
                    .map(|e| (e.id.key(), e.id.version_id()))
                    .collect::<Vec<_>>(),
            )
            .unwrap();
            if page == previous_page {
                repeat_count += 1;
                if !versions || repeat_count > retries {
                    return Err(SidecarError::new(
                        "delete_failed",
                        "Keys remain after bounded deletion retries; stopped repeated listing.",
                    ));
                }
                backoff(repeat_count - 1, &cancel).await?;
            } else {
                repeat_count = 0;
            }
            previous_page = page;
            for batch in entries.chunks(batch_size) {
                let mut pending = batch.to_vec();
                let mut final_errors = BTreeMap::new();
                for attempt in 0..=retries {
                    checkpoint(&cancel)?;
                    let response = client
                        .delete_objects()
                        .bucket(&bucket)
                        .delete(
                            Delete::builder()
                                .set_objects(Some(pending.iter().map(|e| e.id.clone()).collect()))
                                .quiet(false)
                                .build()
                                .unwrap(),
                        )
                        .send()
                        .await;
                    let mut retry = vec![];
                    match response {
                        Ok(output) => {
                            for entry in &pending {
                                let error = output.errors().iter().find(|e| {
                                    e.key() == Some(entry.id.key())
                                        && e.version_id() == entry.id.version_id()
                                });
                                if let Some(error) = error {
                                    let c = error.code().unwrap_or("Unknown").to_string();
                                    if attempt < retries && retryable(&c) {
                                        retry.push(entry.clone());
                                    } else {
                                        final_errors.insert(
                                            (
                                                entry.id.key().to_string(),
                                                entry.id.version_id().map(str::to_owned),
                                            ),
                                            c,
                                        );
                                    }
                                } else if !output.deleted().iter().any(|e| {
                                    e.key() == Some(entry.id.key())
                                        && e.version_id() == entry.id.version_id()
                                }) {
                                    final_errors.insert(
                                        (
                                            entry.id.key().to_string(),
                                            entry.id.version_id().map(str::to_owned),
                                        ),
                                        "UnknownOutcome".into(),
                                    );
                                }
                            }
                        }
                        Err(error) => {
                            let e = map_sdk_error(error);
                            for entry in &pending {
                                if attempt < retries && retryable(code(&e)) {
                                    retry.push(entry.clone());
                                } else {
                                    final_errors.insert(
                                        (
                                            entry.id.key().to_string(),
                                            entry.id.version_id().map(str::to_owned),
                                        ),
                                        code(&e).into(),
                                    );
                                }
                            }
                        }
                    }
                    if retry.is_empty() {
                        break;
                    }
                    pending = retry;
                    backoff(attempt, &cancel).await?;
                }
                let semaphore = Arc::new(Semaphore::new(workers));
                let mut tasks = JoinSet::new();
                for entry in batch {
                    let error = final_errors
                        .get(&(
                            entry.id.key().to_string(),
                            entry.id.version_id().map(str::to_owned),
                        ))
                        .cloned();
                    if versions && error.is_none() {
                        pending_versions.insert((
                            entry.id.key().to_string(),
                            entry.id.version_id().map(str::to_owned),
                        ));
                        continue;
                    }
                    let entry = entry.clone();
                    let client = client.clone();
                    let bucket = bucket.clone();
                    let cancel = cancel.clone();
                    let sem = semaphore.clone();
                    tasks.spawn(async move {
                        let _permit = sem.acquire_owned().await.unwrap();
                        let key = entry.id.key().to_string();
                        (
                            key,
                            recover(&client, &bucket, entry, retries, repair, cancel, error).await,
                        )
                    });
                }
                while let Some(result) = tasks.join_next().await {
                    match result {
                        Ok((key, Ok(outcome))) => {
                            deleted += 1;
                            if outcome != "deleted" && lines.len() < 200 {
                                lines.push(format!("{key}: {outcome}"));
                            }
                        }
                        Ok((key, Err(e))) => {
                            failed += 1;
                            if e.message.contains("skipped") || e.message.contains("not eligible") {
                                skipped += 1;
                            }
                            if e.code == "unknown_outcome"
                                || e.message.contains("UnknownOutcome")
                                || e.message.contains("outcome unknown")
                            {
                                unknown += 1;
                            }
                            if e.code == "empty_object_left"
                                || e.message.contains("overwritten with an empty object")
                            {
                                empty += 1;
                            }
                            if lines.len() < 200 {
                                lines.push(format!("{key}: {}", e.message));
                            }
                        }
                        Err(e) => {
                            failed += 1;
                            lines.push(format!("Worker failed: {e}"));
                        }
                    }
                }
                if failed > 0 {
                    return Err(SidecarError::new(
                        "delete_failed",
                        "Stopped with unresolved objects; bucket was not deleted.",
                    ));
                }
                if let Some(delay) = config["deletionDelayMs"].as_u64() {
                    if delay > 0 {
                        tokio::time::sleep(Duration::from_millis(delay.min(60_000))).await;
                    }
                }
            }
        }
        Ok(())
    }
    .await;
    JOBS.get().unwrap().lock().unwrap().remove(&id);
    let exit = if cancel.load(AtomicOrdering::Relaxed) {
        130
    } else if execution.is_err() || failed > 0 {
        1
    } else {
        0
    };
    if let Err(e) = execution {
        lines.push(e.message);
    }
    lines.push(format!(
        "Confirmed deletions: {deleted}; failures: {failed}; empty objects left behind: {empty}."
    ));
    let mut out = tool_state(
        "delete-all",
        format!("Deleted {deleted} entries from {bucket}; {failed} failures."),
        lines,
        exit,
    );
    out["jobId"] = json!(id);
    out["deletedCount"] = json!(deleted);
    out["failedCount"] = json!(failed);
    out["emptyObjectsLeft"] = json!(empty);
    out["skippedRecoveryCount"] = json!(skipped);
    out["unknownOutcomeCount"] = json!(unknown);
    out["verifiedEmpty"] = json!(exit == 0);
    out["versioningState"] = json!(state);
    Ok(out)
}
pub(super) fn cancel(params: &Value) -> Value {
    let id = params["jobId"].as_str().unwrap_or("");
    let found = JOBS
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .get(id)
        .cloned();
    if let Some(job) = &found {
        job.store(true, AtomicOrdering::Relaxed);
    }
    json!({"jobId":id,"running":found.is_some(),"cancellable":false,"lastStatus":if found.is_some(){"Cancellation requested; waiting for in-flight request reconciliation."}else{"No active deletion with this job ID."},"outputLines":[],"exitCode":null})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_hosts_never_repaired() {
        for host in [
            "https://s3.amazonaws.com",
            "https://s3.eu-west-1.amazonaws.com",
            "https://s3.cn-north-1.amazonaws.com.cn",
        ] {
            assert!(!eligible(
                &json!({"endpointUrl":host,"endpointType":"s3Compatible"})
            ));
        }
        assert!(eligible(
            &json!({"endpointUrl":"http://localhost:9000","endpointType":"s3Compatible"})
        ));
    }
    #[test]
    fn auth_and_unknown_never_repaired() {
        for c in [
            "AccessDenied",
            "InvalidAccessKeyId",
            "SignatureDoesNotMatch",
            "ObjectLocked",
            "Unknown",
            "UnknownOutcome",
        ] {
            assert!(!stale_eligible(c));
        }
    }
}
