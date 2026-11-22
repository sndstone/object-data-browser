use crate::client::{Client, Payload, Retry};
use crate::operations;
use crate::transfer_workers::run_bounded;
use crate::{encryption_headers, required_text, SidecarError, SidecarResult};
use bytes::Bytes;
use http::{HeaderMap, Method};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::time::Instant;
use uuid::Uuid;

static JOBS: OnceLock<Mutex<HashMap<String, Arc<AtomicBool>>>> = OnceLock::new();

struct Job {
    id: String,
    cancelled: Arc<AtomicBool>,
}

impl Job {
    fn start(params: &Value) -> Result<Self, SidecarError> {
        let id = params["jobId"]
            .as_str()
            .filter(|id| !id.is_empty())
            .map_or_else(|| format!("tool-{}", Uuid::new_v4()), str::to_owned);
        let cancelled = Arc::new(AtomicBool::new(false));
        let mut jobs = JOBS.get_or_init(Default::default).lock().unwrap();
        if jobs.contains_key(&id) {
            return Err(SidecarError::new(
                "conflict",
                "This tool job is already active.",
            ));
        }
        jobs.insert(id.clone(), cancelled.clone());
        Ok(Self { id, cancelled })
    }

    fn result(&self, label: &str, summary: String, lines: Vec<String>, code: i32) -> Value {
        json!({"jobId": self.id, "label":label, "lastStatus": summary, "outputLines":lines,
               "running":false, "cancellable":false, "exitCode":code})
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        JOBS.get_or_init(Default::default)
            .lock()
            .unwrap()
            .remove(&self.id);
    }
}

pub fn cancel(params: &Value) -> SidecarResult {
    let id = required_text(params, "jobId", "Tool job ID is required.")?;
    let job = JOBS
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .ok_or_else(|| SidecarError::new("invalid_config", "No active tool has this job ID."))?;
    job.store(true, Ordering::Relaxed);
    Ok(
        json!({"jobId":id,"running":true,"cancellable":false,"exitCode":null,
              "lastStatus":"Cancellation requested. Waiting for dispatched operations.","outputLines":[]}),
    )
}

fn checkpoint(cancelled: &AtomicBool) -> Result<(), SidecarError> {
    if cancelled.load(Ordering::Relaxed) {
        Err(SidecarError::new("cancelled", "Tool execution cancelled."))
    } else {
        Ok(())
    }
}

pub async fn put_test_data(params: Value) -> SidecarResult {
    let mut headers = encryption_headers(&params, true)?;
    let config = &params["config"];
    let bucket = required_text(config, "bucketName", "A bucket name is required.")?;
    let prefix = config["prefix"].as_str().unwrap_or("");
    let count = config["objectCount"].as_u64().unwrap_or_default();
    let versions = config["versions"].as_u64().unwrap_or(1);
    let size = config["objectSizeBytes"]
        .as_u64()
        .or_else(|| config["sizeBytes"].as_u64())
        .unwrap_or(4096);
    if count == 0
        || versions == 0
        || count.saturating_mul(versions) > 1_000_000
        || size > 512 * 1024 * 1024
    {
        return Err(SidecarError::new(
            "invalid_config",
            "Test data requires 1–1,000,000 writes and object sizes up to 512 MiB.",
        ));
    }
    if prefix.len() + "testdata-000000.bin".len() > 1024 {
        return Err(SidecarError::new(
            "invalid_config",
            "The generated test-data key exceeds the S3 byte limit.",
        ));
    }
    let client = Client::new(&params["profile"])?;
    let job = Job::start(&params)?;
    let workers = config["threads"].as_u64().unwrap_or(1).clamp(1, 16) as usize;
    let created = Arc::new(AtomicU64::new(0));
    let payload = Bytes::from(vec![b'A'; size as usize]);
    // A checksum enables PUT in a bucket that applies default retention.
    use base64::{engine::general_purpose::STANDARD, Engine};
    use md5::{Digest, Md5};
    headers.insert(
        "content-md5",
        crate::signing::header_value(&STANDARD.encode(Md5::digest(&payload)))?,
    );

    let next = Arc::new(AtomicU64::new(0));
    let failure = Arc::new(Mutex::new(None));
    let workers = workers.min(client.max_connections);
    run_bounded(
        workers as u64,
        workers,
        |_| {
            let client = client.clone();
            let bucket = bucket.clone();
            let prefix = prefix.to_owned();
            let next = next.clone();
            let created = created.clone();
            let cancelled = job.cancelled.clone();
            let failure = failure.clone();
            let headers = headers.clone();
            let payload = payload.clone();
            async move {
                while !cancelled.load(Ordering::Relaxed) && failure.lock().unwrap().is_none() {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    if index >= count {
                        break;
                    }
                    let key = format!("{prefix}testdata-{index:06}.bin");
                    for _ in 0..versions {
                        if cancelled.load(Ordering::Relaxed) || failure.lock().unwrap().is_some() {
                            return Ok(());
                        }
                        let result = async {
                            client
                                .send(
                                    Method::PUT,
                                    Some(&bucket),
                                    Some(&key),
                                    &[],
                                    headers.clone(),
                                    Payload::Bytes(payload.clone()),
                                    Retry::Rejected,
                                )
                                .await?
                                .bytes()
                                .await
                        }
                        .await;
                        if let Err(error) = result {
                            failure.lock().unwrap().get_or_insert(error);
                            return Ok(());
                        }
                        created.fetch_add(1, Ordering::Relaxed);
                    }
                }
                Ok(())
            }
        },
        |_| {},
    )
    .await?;
    let result = if let Some(error) = failure.lock().unwrap().take() {
        Err(error)
    } else {
        checkpoint(&job.cancelled)
    };
    let count = created.load(Ordering::Relaxed);
    let mut lines = vec![format!("Confirmed {count} test-data write(s).")];
    let (status, exit) = match result {
        Ok(()) => (format!("Created {count} test-data object version(s)."), 0),
        Err(error) => {
            lines.push(error.message);
            (
                "Test-data generation stopped.".into(),
                if error.code == "cancelled" { 130 } else { 1 },
            )
        }
    };
    Ok(job.result("put-testdata", status, lines, exit))
}

type Entry = (String, Option<String>);

struct DeleteJob<'a> {
    client: Client,
    bucket: String,
    prefix: &'a str,
    page_size: u64,
    batch_size: usize,
    attempts: u64,
    versioning: String,
    throttle: Throttle,
    cancelled: &'a AtomicBool,
    deleted: u64,
    failed: u64,
    unknown: u64,
    lines: Vec<String>,
}

impl DeleteJob<'_> {
    async fn drain_bucket(&mut self, profile: &Value) -> Result<(), SidecarError> {
        let mut previous_page = Vec::new();
        let mut acknowledged = HashSet::new();
        let mut repeats = 0;
        let versions = self.versioning != "never-enabled";
        loop {
            checkpoint(self.cancelled)?;
            self.throttle.wait().await;
            let page = operations::dispatch(
                if versions { "listObjectVersions" } else { "listObjects" },
                json!({"profile":profile,"bucketName":self.bucket,"prefix":self.prefix,"flat":true,
                       "maxKeys":self.page_size,"options":{"showVersions":true,"showDeleteMarkers":true}}),
            ).await?;
            let items = page["items"]
                .as_array()
                .ok_or_else(|| SidecarError::new("invalid_response", "S3 listing has no items."))?;
            let cursor = if versions {
                &page["cursor"]
            } else {
                &page["nextCursor"]
            };
            if items.is_empty() {
                if cursor["hasMore"] == true {
                    return Err(SidecarError::new(
                        "invalid_response",
                        "S3 returned an empty truncated listing.",
                    ));
                }
                self.deleted += acknowledged.len() as u64;
                return Ok(());
            }
            let entries: Vec<Entry> = items
                .iter()
                .map(|item| {
                    let key =
                        required_text(item, "key", "S3 listing did not identify the object key.")?;
                    if !key.starts_with(self.prefix) {
                        return Err(SidecarError::new(
                            "invalid_response",
                            "S3 listed an object outside the requested prefix.",
                        ));
                    }
                    let version = if versions {
                        Some(required_text(
                            item,
                            "versionId",
                            "Refusing key-only deletion because a version ID was missing.",
                        )?)
                    } else {
                        None
                    };
                    Ok((key, version))
                })
                .collect::<Result<_, SidecarError>>()?;
            let listed: HashSet<_> = entries.iter().cloned().collect();
            self.deleted += acknowledged.difference(&listed).count() as u64;
            acknowledged.retain(|item| listed.contains(item));
            if listed.len() == previous_page.len()
                && previous_page.iter().all(|item| listed.contains(item))
            {
                repeats += 1;
                if repeats >= self.attempts {
                    return Err(SidecarError::new("delete_failed", "The endpoint still lists the same keys after the bounded deletion attempts."));
                }
            } else {
                repeats = 0;
            }
            previous_page = entries;
            for batch in previous_page.chunks(self.batch_size) {
                checkpoint(self.cancelled)?;
                self.throttle.wait().await;
                checkpoint(self.cancelled)?;
                let refs: Vec<_> = batch
                    .iter()
                    .map(|(key, version)| (key.as_str(), version.as_deref()))
                    .collect();
                let outcomes = match operations::delete_batch(
                    &self.client,
                    &self.bucket,
                    &refs,
                    false,
                )
                .await
                {
                    Ok(outcomes) => outcomes,
                    Err(error) => {
                        self.unknown += batch.len() as u64;
                        return Err(error);
                    }
                };
                for outcome in outcomes {
                    if let Some(code) = outcome.code {
                        if code == "unknown_outcome" {
                            self.unknown += 1;
                        } else {
                            self.failed += 1;
                        }
                        if self.lines.len() < 32 {
                            self.lines.push(crate::secret_hygiene::text(&format!(
                                "{}: {code}",
                                outcome.key
                            )));
                        }
                    } else {
                        acknowledged.insert((outcome.key, outcome.version_id));
                    }
                }
                if self.failed != 0 || self.unknown != 0 {
                    return Err(SidecarError::new(
                        "delete_failed",
                        "S3 declined one or more deletions.",
                    ));
                }
            }
        }
    }
}

struct Throttle {
    interval: Duration,
    next: Instant,
}
impl Throttle {
    fn new(requests_per_second: f64) -> Self {
        let interval = if requests_per_second >= 1.0 {
            Duration::from_secs_f64(1.0 / requests_per_second)
        } else {
            Duration::ZERO
        };
        Self {
            interval,
            next: Instant::now(),
        }
    }
    async fn wait(&mut self) {
        if self.interval.is_zero() {
            return;
        }
        tokio::time::sleep_until(self.next).await;
        self.next = Instant::now() + self.interval;
    }
}

pub async fn delete_all(params: Value) -> SidecarResult {
    let config = &params["config"];
    let bucket = required_text(config, "bucketName", "A bucket name is required.")?;
    let client = Client::new(&params["profile"])?;
    let job = Job::start(&params)?;
    let versioning = client
        .send(
            Method::GET,
            Some(&bucket),
            None,
            &[("versioning", "")],
            HeaderMap::new(),
            Payload::Empty,
            Retry::Safe,
        )
        .await?
        .bytes()
        .await?;
    let versioning = operations::xml::parse(&versioning)?;
    if versioning.name != "VersioningConfiguration" {
        return Err(SidecarError::new(
            "invalid_response",
            "S3 returned an invalid versioning configuration.",
        ));
    }
    let versioning = versioning
        .text_of("Status")
        .unwrap_or("never-enabled")
        .trim()
        .to_owned();
    if !matches!(
        versioning.as_str(),
        "never-enabled" | "Enabled" | "Suspended"
    ) {
        return Err(SidecarError::new(
            "invalid_response",
            "S3 returned an unknown bucket versioning state.",
        ));
    }
    let mut run = DeleteJob {
        client,
        bucket,
        prefix: config["prefix"].as_str().unwrap_or(""),
        page_size: config["listMaxKeys"]
            .as_u64()
            .unwrap_or(1000)
            .clamp(1, 1000),
        batch_size: config["batchSize"].as_u64().unwrap_or(1000).clamp(1, 1000) as usize,
        attempts: config["maxRetries"].as_u64().unwrap_or(2).min(10) + 1,
        throttle: Throttle::new(config["maxRequestsPerSecond"].as_f64().unwrap_or_default()),
        cancelled: &job.cancelled,
        versioning,
        deleted: 0,
        failed: 0,
        unknown: 0,
        lines: Vec::new(),
    };
    let result = run.drain_bucket(&params["profile"]).await;
    let exit = match result {
        Ok(()) => 0,
        Err(error) => {
            run.lines.push(error.message);
            if error.code == "cancelled" {
                130
            } else {
                1
            }
        }
    };
    let mut report = job.result(
        "delete-all",
        format!(
            "Confirmed {} deletion(s); {} failures.",
            run.deleted, run.failed
        ),
        run.lines,
        exit,
    );
    report["verifiedEmpty"] = json!(exit == 0);
    report["deletedCount"] = json!(run.deleted);
    report["failedCount"] = json!(run.failed);
    report["unknownOutcomeCount"] = json!(run.unknown);
    report["versioningState"] = json!(run.versioning);
    report["emptyObjectsLeft"] = json!(0);
    report["skippedRecoveryCount"] = json!(0);
    Ok(report)
}
