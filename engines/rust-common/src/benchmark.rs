use super::*;
use crate::benchmark_backend::{self, Client};
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering as AtomicOrdering;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;
use uuid::Uuid;

#[derive(Clone)]
pub(super) enum BenchmarkTaskKind {
    Put { key: String, size_bytes: usize },
    Get { key: String, size_bytes: usize },
    DeleteSingle { key: String, size_bytes: usize },
    DeleteMulti { keys: Vec<String> },
}

#[derive(Clone)]
pub(super) struct BenchmarkTask {
    order: usize,
    pub(super) kind: BenchmarkTaskKind,
}

pub(super) struct DeleteOutcome {
    pub key: String,
    pub code: Option<String>,
    pub message: Option<String>,
}

struct BenchmarkTaskResult {
    order: usize,
    operation: &'static str,
    key: String,
    size_bytes: usize,
    bytes_transferred: i64,
    checksum_state: String,
    checksum: Option<String>,
    latency_ms: f64,
    operation_count: i64,
    elapsed_ms: f64,
    completed_at: String,
    upserted_object: Option<(String, usize)>,
    removed_keys: Vec<String>,
    log_line: Option<String>,
}

pub(super) async fn start_benchmark(params: Value) -> SidecarResult {
    if !params.get("profile").map(Value::is_object).unwrap_or(false) {
        return Err(SidecarError::new(
            "invalid_config",
            "Profile configuration is required for benchmark runs.",
        ));
    }
    benchmark_runtime::validate(&params["config"])?;
    let run_id = format!("bench-{}", short_uuid());
    let config = secret_hygiene::value(params["config"].clone());
    let config_map =
        benchmark_config_with_run_dir(&config.as_object().cloned().unwrap_or_default(), &run_id);
    let state = json!({
        "id": run_id,
        "profileId": params["profile"]["id"],
        "config": Value::Object(config_map.clone()),
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
    append_benchmark_log(
        &mut state,
        &format!("Benchmark target bucket: {}.", benchmark_bucket),
    );
    benchmark_backend::validate_profile(&params["profile"])?;
    let generation = Uuid::new_v4().to_string();
    state["workerGeneration"] = json!(generation);
    let result = public_benchmark_state(&state);
    let live = {
        let mut registry = LIVE_BENCHMARKS
            .get_or_init(Default::default)
            .lock()
            .unwrap();
        if registry.len() >= 4 {
            return Err(SidecarError::new(
                "invalid_config",
                "Stop an existing benchmark before starting another (maximum four live runs).",
            ));
        }
        write_benchmark_state(&state)?;
        let live = Arc::new(BenchmarkOwner::new(state));
        registry.insert(run_id, live.clone());
        live
    };
    spawn_benchmark_worker(live, generation, params["profile"].clone());
    Ok(result)
}

struct BenchmarkControl {
    published: Value,
    pending: Option<&'static str>,
}

pub(super) struct BenchmarkOwner {
    pub(super) state: tokio::sync::Mutex<Value>,
    control: Mutex<BenchmarkControl>,
}

impl BenchmarkOwner {
    pub(super) fn new(state: Value) -> Self {
        Self {
            control: Mutex::new(BenchmarkControl {
                published: public_benchmark_state(&state),
                pending: None,
            }),
            state: tokio::sync::Mutex::new(state),
        }
    }

    // Never acquire the execution lock here: a network batch may own it.
    fn acknowledge(&self, action: Option<&'static str>) -> Value {
        let mut control = self.control.lock().unwrap();
        if control.published["status"] == "running" && control.pending != Some("stopped") {
            if let Some(action) = action {
                // Resume while still running cancels a pending pause.
                control.pending = if action == "running" {
                    None
                } else {
                    Some(action)
                };
            }
        }
        let mut snapshot = control.published.clone();
        if let Some(pending) = control.pending {
            snapshot["controlPending"] = json!(pending);
        }
        snapshot
    }

    fn publish(&self, state: &Value) {
        self.control.lock().unwrap().published = public_benchmark_state(state);
    }

    fn settle_controls(&self, state: &mut Value) -> Result<(), SidecarError> {
        let mut control = self.control.lock().unwrap();
        if let Some(action) = control.pending.take() {
            if state["status"] == "running" {
                apply_benchmark_control(state, action)?;
            }
            control.published = public_benchmark_state(state);
        }
        Ok(())
    }
}

pub(super) type LiveBenchmark = Arc<BenchmarkOwner>;
pub(super) static LIVE_BENCHMARKS: OnceLock<Mutex<BTreeMap<String, LiveBenchmark>>> =
    OnceLock::new();

pub(super) fn public_benchmark_state(state: &Value) -> Value {
    let mut result = state.clone();
    if let Some(map) = result.as_object_mut() {
        map.remove("profile");
        map.remove("workerGeneration");
        map.remove("_lastPersistUnixMs");
    }
    secret_hygiene::value(result)
}

pub(super) async fn live_benchmark(params: &Value) -> Result<LiveBenchmark, SidecarError> {
    let id = required_text(params, "runId", "Benchmark run ID is required.")?;
    let registry = LIVE_BENCHMARKS.get_or_init(Default::default);
    if let Some(state) = registry.lock().unwrap().get(&id).cloned() {
        return Ok(state);
    }
    let mut state = read_benchmark_state(id.clone())?;
    if state["status"] == "running" {
        state["status"] = json!("paused");
        append_benchmark_log(
            &mut state,
            "Engine restarted; resume with the owning endpoint credentials.",
        );
    }
    let paused = state["status"] == "paused";
    let live = Arc::new(BenchmarkOwner::new(state));
    if paused {
        let mut registry = registry.lock().unwrap();
        if registry.len() >= 4 {
            return Err(SidecarError::new(
                "invalid_config",
                "Maximum four live benchmark runs.",
            ));
        }
        registry.insert(id, live.clone());
    }
    Ok(live)
}

fn spawn_benchmark_worker(live: LiveBenchmark, generation: String, profile: Value) {
    let secrets = secret_hygiene::SECRETS
        .try_with(Clone::clone)
        .unwrap_or_default();
    tokio::spawn(secret_hygiene::SECRETS.scope(secrets, async move {
        let resources = {
            let state = live.state.lock().await;
            Arc::new(benchmark_runtime::Resources::new(&state["config"]))
        };
        loop {
            {
                let mut state = live.state.lock().await;
                if let Err(error) = live.settle_controls(&mut state) {
                    state["status"] = json!("failed");
                    append_benchmark_log(
                        &mut state,
                        &format!("Benchmark control failed: {}", error.message),
                    );
                    live.publish(&state);
                }
                if state["status"] != "running" || state["workerGeneration"] != generation {
                    break;
                }
                match materialize_benchmark_state(state.clone(), &profile, resources.clone(), &live)
                    .await
                {
                    Ok(next) => *state = next,
                    Err(error) => {
                        state["status"] = json!("failed");
                        append_benchmark_log(
                            &mut state,
                            &format!("Benchmark failed: {}", error.message),
                        );
                        let _ = write_benchmark_state(&state);
                    }
                }
                if let Err(error) = live.settle_controls(&mut state) {
                    state["status"] = json!("failed");
                    append_benchmark_log(
                        &mut state,
                        &format!("Benchmark control failed: {}", error.message),
                    );
                }
                live.publish(&state);
                if state["status"] != "running" {
                    break;
                }
            }
            tokio::task::yield_now().await;
        }
        let state = live.state.lock().await;
        // A resume may already have installed a new worker generation.
        if state["status"] != "running"
            && (state["workerGeneration"] == generation || state["workerGeneration"].is_null())
        {
            if state["status"] != "paused" {
                let id = state["id"].as_str().unwrap_or_default();
                LIVE_BENCHMARKS
                    .get_or_init(Default::default)
                    .lock()
                    .unwrap()
                    .remove(id);
            }
            live.publish(&state);
        }
    }));
}

pub(super) async fn get_benchmark_status(params: Value) -> SidecarResult {
    let live = live_benchmark(&params).await?;
    Ok(live.acknowledge(None))
}

pub(super) async fn pause_benchmark(params: Value) -> SidecarResult {
    let live = live_benchmark(&params).await?;
    let mut state = match live.state.try_lock() {
        Ok(state) => state,
        Err(_) => {
            let snapshot = live.acknowledge(Some("paused"));
            if snapshot["status"] == "running" {
                return Ok(snapshot);
            }
            live.state.lock().await
        }
    };
    live.settle_controls(&mut state)?;
    if state["status"] == "running" {
        apply_benchmark_control(&mut state, "paused")?;
    }
    live.publish(&state);
    Ok(public_benchmark_state(&state))
}

pub(super) async fn resume_benchmark(params: Value) -> SidecarResult {
    let live = live_benchmark(&params).await?;
    let snapshot = live.acknowledge(Some("running"));
    if snapshot["status"] == "running" {
        return Ok(snapshot);
    }
    let generation = Uuid::new_v4().to_string();
    let result;
    {
        let mut state = live.state.lock().await;
        if state["status"] != "paused" {
            return Ok(public_benchmark_state(&state));
        }
        benchmark_backend::validate_profile(&params["profile"])?;
        if state["profileId"].as_str().is_some() && state["profileId"] != params["profile"]["id"] {
            return Err(SidecarError::new(
                "invalid_config",
                "Resume requires the original endpoint profile.",
            ));
        }
        state["status"] = json!("running");
        state["lastUpdatedAt"] = json!(now_iso());
        state["workerGeneration"] = json!(generation);
        append_benchmark_log(&mut state, "Benchmark resumed by user.");
        write_benchmark_state(&state)?;
        result = public_benchmark_state(&state);
        live.publish(&state);
    }
    spawn_benchmark_worker(live, generation, params["profile"].clone());
    Ok(result)
}

pub(super) async fn stop_benchmark(params: Value) -> SidecarResult {
    let live = live_benchmark(&params).await?;
    let mut state = match live.state.try_lock() {
        Ok(state) => state,
        Err(_) => {
            let snapshot = live.acknowledge(Some("stopped"));
            if snapshot["status"] == "running" {
                return Ok(snapshot);
            }
            live.state.lock().await
        }
    };
    live.settle_controls(&mut state)?;
    apply_benchmark_control(&mut state, "stopped")?;
    live.publish(&state);
    LIVE_BENCHMARKS
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .remove(state["id"].as_str().unwrap_or_default());
    Ok(public_benchmark_state(&state))
}

fn apply_benchmark_control(state: &mut Value, action: &str) -> Result<(), SidecarError> {
    if state["status"] == "running" {
        refresh_benchmark_snapshot(state);
    }
    state["status"] = json!(action);
    state["workerGeneration"] = Value::Null;
    if action == "stopped" {
        state["completedAt"] = json!(now_iso());
        state["resultSummary"] = benchmark_summary_from_state(state);
    }
    append_benchmark_log(state, &format!("Benchmark {action} by user."));
    persist_benchmark_outputs(state)?;
    write_benchmark_state(state)
}

pub(super) async fn export_benchmark_results(params: Value) -> SidecarResult {
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

fn runtime_dir() -> Result<PathBuf, SidecarError> {
    let path = std::env::temp_dir().join(benchmark_backend::RUNTIME_NAME);
    fs::create_dir_all(&path)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    Ok(path)
}

pub(super) fn benchmark_state_path(run_id: &str) -> Result<PathBuf, SidecarError> {
    if run_id.is_empty()
        || run_id.len() > 128
        || !run_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
    {
        return Err(SidecarError::new(
            "invalid_config",
            "Invalid benchmark run ID.",
        ));
    }
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
    let state: Value = serde_json::from_str(&contents)
        .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    let clean = public_benchmark_state(&state);
    if clean != state {
        write_benchmark_state(&clean)?;
    }
    Ok(clean)
}

pub(super) fn write_benchmark_state(state: &Value) -> Result<(), SidecarError> {
    let path = benchmark_state_path(state["id"].as_str().unwrap_or_default())?;
    let output = serde_json::to_string(&public_benchmark_state(state))
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
    state["averageLatencyMs"] = json!(round1(
        state["totalLatencyMs"].as_f64().unwrap_or(0.0)
            / state["totalRecordCount"].as_f64().unwrap_or(1.0).max(1.0)
    ));
    let active_elapsed = state["activeElapsedSeconds"].as_f64().unwrap_or(0.0);
    let processed_count = state["processedCount"].as_i64().unwrap_or(0);
    state["throughputOpsPerSecond"] = Value::from(if active_elapsed <= 0.0 {
        0.0
    } else {
        round1(processed_count as f64 / active_elapsed)
    });
}

async fn materialize_benchmark_state(
    mut state: Value,
    profile: &Value,
    resources: Arc<benchmark_runtime::Resources>,
    owner: &BenchmarkOwner,
) -> SidecarResult {
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
        .clamp(1, 64)
        .min(
            config
                .get("maxPoolConnections")
                .and_then(Value::as_u64)
                .unwrap_or(10)
                .max(1),
        ) as usize;
    let test_mode = config
        .get("testMode")
        .and_then(Value::as_str)
        .unwrap_or("duration");
    let duration_complete =
        test_mode != "operation-count" && active_elapsed >= duration_seconds as f64;
    let operation_complete = test_mode == "operation-count"
        && state["processedCount"].as_u64().unwrap_or(0) as usize >= operation_count;
    if state.get("totalRecordCount").is_none() {
        state["processedCount"] = json!(0);
        for record in state["history"].as_array().cloned().unwrap_or_default() {
            accumulate_benchmark_record(&mut state, &record);
        }
    }
    let call_started = Instant::now();
    let call_base_elapsed_ms = active_elapsed * 1000.0;
    let execution_budget_seconds =
        ((now - last_updated).num_milliseconds().max(0) as f64 / 1000.0).clamp(0.25, 1.5);
    if !duration_complete && !operation_complete && parallelism > 0 {
        let profile = benchmark_profile_value(profile, &config);
        let client = benchmark_backend::build(&profile, resources.metrics.clone()).await?;
        let previous_errors = resources.metrics.errors.load(AtomicOrdering::Relaxed);
        let previous_retries = resources.metrics.retries.load(AtomicOrdering::Relaxed);
        while call_started.elapsed().as_secs_f64() < execution_budget_seconds {
            // Pause/stop acknowledge immediately; already dispatched work settles
            // before applying the control, with no additional batch dispatched.
            if owner.control.lock().unwrap().pending.is_some() {
                break;
            }
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
                resources.clone(),
            )
            .await
            {
                Ok((results, failure)) => {
                    apply_benchmark_batch_results(&mut state, results, &resources)?;
                    if let Some(error) = failure {
                        state["status"] = json!("failed");
                        state["completedAt"] = json!(now_iso());
                        if resources.metrics.errors.load(AtomicOrdering::Relaxed) == previous_errors
                        {
                            resources
                                .metrics
                                .errors
                                .fetch_add(1, AtomicOrdering::Relaxed);
                        }
                        append_benchmark_log(
                            &mut state,
                            &format!("Benchmark failed: {}", error.message),
                        );
                        break;
                    }
                }
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
        state["errorCount"] = json!(
            state["errorCount"].as_u64().unwrap_or(0)
                + resources
                    .metrics
                    .errors
                    .load(AtomicOrdering::Relaxed)
                    .saturating_sub(previous_errors)
        );
        state["retryCount"] = json!(
            state["retryCount"].as_u64().unwrap_or(0)
                + resources
                    .metrics
                    .retries
                    .load(AtomicOrdering::Relaxed)
                    .saturating_sub(previous_retries)
        );
    }
    state["activeElapsedSeconds"] = json!(active_elapsed + call_started.elapsed().as_secs_f64());
    state["lastUpdatedAt"] = json!(now_iso());
    state["cacheBytes"] = json!(resources.cache_bytes());
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
    resources.flush_records()?;
    let now_ms = Utc::now().timestamp_millis();
    if state["status"] != "running"
        || now_ms - state["_lastPersistUnixMs"].as_i64().unwrap_or(0) >= 1000
    {
        persist_benchmark_outputs(&state)?;
        write_benchmark_state(&state)?;
        state["_lastPersistUnixMs"] = json!(now_ms);
    }
    Ok(state)
}

pub(super) fn persist_benchmark_outputs(state: &Value) -> Result<(), SidecarError> {
    let state = secret_hygiene::value(state.clone());
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
    if !Path::new(csv_path).exists() {
        fs::write(csv_path, csv.join("\n") + "\n")
            .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?;
    }
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

/// Redirects output artifacts into a per-run folder named after the run id so
/// repeated Start presses never overwrite an earlier run's results.
fn benchmark_config_with_run_dir(config: &Map<String, Value>, run_id: &str) -> Map<String, Value> {
    let mut updated = config.clone();
    for (key, default_name) in [
        ("csvOutputPath", "benchmark-results.csv"),
        ("jsonOutputPath", "benchmark-results.json"),
        ("logFilePath", "benchmark.log"),
    ] {
        let raw = updated
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(default_name);
        let path = Path::new(raw);
        let parent = path.parent().unwrap_or_else(|| Path::new(""));
        if parent.file_name().and_then(|name| name.to_str()) != Some(run_id) {
            let file_name = path.file_name().unwrap_or_default();
            let nested = parent.join(run_id).join(file_name);
            updated.insert(
                key.to_string(),
                Value::String(nested.to_string_lossy().to_string()),
            );
        }
    }
    updated
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

fn benchmark_profile_value(profile_value: &Value, config: &Map<String, Value>) -> Value {
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
    let pool_limit = Value::from(
        config
            .get("maxPoolConnections")
            .and_then(Value::as_u64)
            .unwrap_or(10),
    );
    merged.insert("maxPoolConnections".to_owned(), pool_limit.clone());
    merged.insert("maxConcurrentRequests".to_owned(), pool_limit);
    Value::Object(merged)
}

fn append_benchmark_log(state: &mut Value, line: &str) {
    let mut lines: Vec<Value> = state["liveLog"].as_array().cloned().unwrap_or_default();
    lines.push(Value::String(secret_hygiene::text(line)));
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

pub(super) fn benchmark_payload(
    run_id: &str,
    key: &str,
    size: usize,
    random_data: bool,
) -> Vec<u8> {
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

pub(super) fn benchmark_operation_mix(config: &Map<String, Value>) -> Vec<(&'static str, usize)> {
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

pub(super) fn plan_benchmark_batch(
    state: &mut Value,
    task_count: usize,
    remaining_operations: usize,
) -> Vec<BenchmarkTask> {
    let config = state["config"].as_object().cloned().unwrap_or_default();
    let sizes = benchmark_size_list(&config);
    let object_limit = config
        .get("objectCount")
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .max(1) as usize;
    let mut available = state["activeObjects"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut active_count = available.len();
    let mut next_object = state["nextObjectIndex"].as_u64().unwrap_or(0);
    let mut next_size = state["nextSizeIndex"].as_u64().unwrap_or(0) as usize;
    let mut next_active = state["nextActiveIndex"].as_u64().unwrap_or(0) as usize;
    let mut scheduled = 0;
    let mut tasks = vec![];
    for order in 0..task_count {
        if scheduled >= remaining_operations {
            break;
        }
        let mut operation = benchmark_operation_for_slot(
            &config,
            state["processedCount"].as_u64().unwrap_or(0) as usize + scheduled,
        );
        // Reserve keys across the batch so a GET never races a scheduled PUT/DELETE.
        if matches!(operation, "GET" | "DELETE") && available.is_empty() {
            if active_count >= object_limit {
                break;
            }
            operation = "PUT";
        }
        let size = sizes[next_size % sizes.len()];
        next_size += 1;
        let kind = match operation {
            "PUT" => {
                let key = if active_count >= object_limit {
                    if available.is_empty() {
                        break;
                    }
                    let target = available.remove(next_active % available.len());
                    next_active += 1;
                    target["key"].as_str().unwrap_or_default().to_string()
                } else {
                    let key = format!(
                        "{}obj-{next_object:06}-{size}.bin",
                        state["benchmarkPrefix"].as_str().unwrap_or_default()
                    );
                    next_object += 1;
                    active_count += 1;
                    key
                };
                scheduled += 1;
                BenchmarkTaskKind::Put {
                    key,
                    size_bytes: size,
                }
            }
            "GET" => {
                let target = available.remove(next_active % available.len());
                next_active += 1;
                scheduled += 1;
                BenchmarkTaskKind::Get {
                    key: target["key"].as_str().unwrap_or_default().to_string(),
                    size_bytes: target["sizeBytes"].as_u64().unwrap_or(size as u64) as usize,
                }
            }
            _ => {
                let count = benchmark_delete_batch_size(&config, available.len())
                    .min(remaining_operations - scheduled);
                if count <= 1 || benchmark_delete_mode(&config) != "multi-object-post" {
                    let target = available.remove(next_active % available.len());
                    next_active += 1;
                    active_count = active_count.saturating_sub(1);
                    scheduled += 1;
                    BenchmarkTaskKind::DeleteSingle {
                        key: target["key"].as_str().unwrap_or_default().to_string(),
                        size_bytes: target["sizeBytes"].as_u64().unwrap_or(size as u64) as usize,
                    }
                } else {
                    let mut keys = vec![];
                    for _ in 0..count {
                        let target = available.remove(next_active % available.len());
                        next_active += 1;
                        keys.push(target["key"].as_str().unwrap_or_default().to_string());
                    }
                    active_count = active_count.saturating_sub(count);
                    scheduled += count;
                    BenchmarkTaskKind::DeleteMulti { keys }
                }
            }
        };
        tasks.push(BenchmarkTask { order, kind });
    }
    state["nextSizeIndex"] = json!(next_size);
    state["nextActiveIndex"] = json!(next_active);
    state["nextObjectIndex"] = json!(next_object);
    tasks
}

async fn execute_benchmark_batch(
    tasks: &[BenchmarkTask],
    client: &Client,
    state: &Value,
    call_started: Instant,
    call_base_elapsed_ms: f64,
    resources: Arc<benchmark_runtime::Resources>,
) -> Result<(Vec<BenchmarkTaskResult>, Option<SidecarError>), SidecarError> {
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
    let checksum_algorithm = config
        .get("checksumAlgorithm")
        .and_then(Value::as_str)
        .unwrap_or("sha256")
        .to_string();
    let mut join_set = tokio::task::JoinSet::new();
    for task in tasks.iter().cloned() {
        let task_client = client.clone();
        let task_bucket = bucket_name.clone();
        let task_run_id = run_id.clone();
        let checksum_algorithm = checksum_algorithm.clone();
        let resources = resources.clone();
        let secrets = secret_hygiene::SECRETS
            .try_with(Clone::clone)
            .unwrap_or_default();
        join_set.spawn(secret_hygiene::SECRETS.scope(secrets, async move {
            execute_benchmark_task(
                task,
                task_client,
                task_bucket,
                task_run_id,
                random_data,
                validate_checksum,
                checksum_algorithm,
                call_started,
                call_base_elapsed_ms,
                resources,
            )
            .await
        }));
    }
    let mut results = Vec::new();
    let mut failure = None;
    while let Some(joined) = join_set.join_next().await {
        match joined {
            Ok(Ok(result)) => results.push(result),
            Ok(Err(error)) => {
                if failure.is_none() {
                    failure = Some(error);
                }
            }
            Err(error) => {
                if failure.is_none() {
                    failure = Some(SidecarError::new("engine_unavailable", error.to_string()));
                }
            }
        }
    }
    results.sort_by(|left, right| {
        left.elapsed_ms
            .partial_cmp(&right.elapsed_ms)
            .unwrap_or(Ordering::Equal)
            .then(left.order.cmp(&right.order))
    });
    Ok((results, failure))
}

async fn execute_benchmark_task(
    task: BenchmarkTask,
    client: Client,
    bucket_name: String,
    run_id: String,
    random_data: bool,
    validate_checksum: bool,
    checksum_algorithm: String,
    call_started: Instant,
    call_base_elapsed_ms: f64,
    resources: Arc<benchmark_runtime::Resources>,
) -> Result<BenchmarkTaskResult, SidecarError> {
    let started = Instant::now();
    match task.kind {
        BenchmarkTaskKind::Put { key, size_bytes } => {
            let payload = resources
                .payload(&run_id, &key, size_bytes, random_data)
                .await?;
            benchmark_backend::put(&client, &bucket_name, &key, &payload, size_bytes).await?;
            Ok(BenchmarkTaskResult {
                completed_at: now_iso(),
                checksum: None,
                order: task.order,
                operation: "PUT",
                key: key.clone(),
                size_bytes,
                bytes_transferred: size_bytes as i64,
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
            let mut body = match benchmark_backend::get(&client, &bucket_name, &key).await {
                Ok(body) => body,
                Err(mapped) => {
                    if is_missing_benchmark_key(&mapped) {
                        return Ok(BenchmarkTaskResult {
                            completed_at: now_iso(),
                            checksum: None,
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
            let pattern = validate_checksum
                .then(|| benchmark_runtime::pattern(&run_id, &key, size_bytes, random_data));
            let mut expected = Vec::new();
            let mut received = 0;
            let mut actual_hash = validate_checksum
                .then(|| benchmark_runtime::SelectedDigest::new(&checksum_algorithm));
            let mut expected_hash = validate_checksum
                .then(|| benchmark_runtime::SelectedDigest::new(&checksum_algorithm));
            while let Some(bytes) = body.next_chunk().await? {
                if let Some(pattern) = &pattern {
                    expected.resize(bytes.len(), 0);
                    benchmark_runtime::fill(&mut expected, pattern, received);
                    actual_hash.as_mut().unwrap().update(&bytes);
                    expected_hash.as_mut().unwrap().update(&expected);
                }
                received += bytes.len();
            }
            let checksum = actual_hash.map(benchmark_runtime::SelectedDigest::finish);
            let valid = received == size_bytes
                && checksum == expected_hash.map(benchmark_runtime::SelectedDigest::finish);
            Ok(BenchmarkTaskResult {
                completed_at: now_iso(),
                checksum,
                order: task.order,
                operation: "GET",
                key,
                size_bytes,
                bytes_transferred: received as i64,
                checksum_state: if validate_checksum {
                    if valid {
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
            match benchmark_backend::delete_single(&client, &bucket_name, &key).await {
                Ok(()) => {}
                Err(mapped) => {
                    if is_missing_benchmark_key(&mapped) {
                        return Ok(BenchmarkTaskResult {
                            completed_at: now_iso(),
                            checksum: None,
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
                completed_at: now_iso(),
                checksum: None,
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
            let outcomes = benchmark_backend::delete_multi(&client, &bucket_name, &keys).await?;
            let mut deleted_keys = Vec::new();
            let mut missing_keys = Vec::new();
            let mut fatal_errors = Vec::new();
            for item in outcomes {
                let target = item.key.as_str();
                let Some(code) = item.code else {
                    if !target.is_empty() {
                        deleted_keys.push(item.key);
                    }
                    continue;
                };
                let code = code.to_ascii_lowercase();
                let message = item.message.unwrap_or_default();
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
                        code.as_str()
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
                completed_at: now_iso(),
                checksum: None,
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

fn apply_benchmark_batch_results(
    state: &mut Value,
    results: Vec<BenchmarkTaskResult>,
    resources: &benchmark_runtime::Resources,
) -> Result<(), SidecarError> {
    let reduced_logging = state["config"]["reducedLogging"].as_bool().unwrap_or(false);
    let mut active_objects = state["activeObjects"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut history = match state["history"].take() {
        Value::Array(items) => items,
        _ => Vec::new(),
    };
    let mut completed_records = Vec::new();
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
        let record = json!({
            "timestamp": result.completed_at,
            "second": second,
            "elapsedMs": round1(result.elapsed_ms),
            "operation": result.operation,
            "key": result.key,
            "sizeBytes": result.size_bytes,
            "latencyMs": round1(result.latency_ms),
            "bytesTransferred": result.bytes_transferred,
            "success": true,
            "checksumState": result.checksum_state,
            "checksum": result.checksum,
            "checksumAlgorithm": state["config"]["checksumAlgorithm"].as_str().unwrap_or("sha256"),
            "operationCount": result.operation_count,
        });
        accumulate_benchmark_record(state, &record);
        completed_records.push(record);
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
    append_benchmark_csv(state, &completed_records, resources)?;
    history.extend(completed_records);
    if history.len() > benchmark_runtime::HISTORY_LIMIT {
        history.drain(..history.len() - benchmark_runtime::HISTORY_LIMIT);
    }
    state["history"] = Value::Array(history);
    state["activeObjects"] = Value::Array(active_objects);
    Ok(())
}

fn accumulate_benchmark_record(state: &mut Value, record: &Value) {
    let count = benchmark_operation_count(record);
    state["processedCount"] = json!(state["processedCount"].as_i64().unwrap_or(0) + count);
    state["totalRecordCount"] = json!(state["totalRecordCount"].as_u64().unwrap_or(0) + 1);
    state["totalBytes"] = json!(
        state["totalBytes"].as_u64().unwrap_or(0)
            + record["bytesTransferred"].as_u64().unwrap_or(0)
    );
    state["totalLatencyMs"] = json!(
        state["totalLatencyMs"].as_f64().unwrap_or(0.0)
            + record["latencyMs"].as_f64().unwrap_or(0.0)
    );
    for (field, key_field) in [
        ("totalOperationsByType", "operation"),
        ("totalChecksumStats", "checksumState"),
    ] {
        let key = record[key_field].as_str().unwrap_or("");
        state[field][key] = json!(state[field][key].as_i64().unwrap_or(0) + count);
    }
    let second = record["second"].as_u64().unwrap_or(1).to_string();
    let operation = record["operation"].as_str().unwrap_or("");
    let window = &mut state["throughputWindows"][&second];
    window["operationsCount"] = json!(window["operationsCount"].as_i64().unwrap_or(0) + count);
    window["bytes"] = json!(
        window["bytes"].as_u64().unwrap_or(0) + record["bytesTransferred"].as_u64().unwrap_or(0)
    );
    window["latencyMs"] = json!(
        window["latencyMs"].as_f64().unwrap_or(0.0) + record["latencyMs"].as_f64().unwrap_or(0.0)
    );
    window["records"] = json!(window["records"].as_u64().unwrap_or(0) + 1);
    window["operations"][operation] =
        json!(window["operations"][operation].as_i64().unwrap_or(0) + count);
    let windows = state["throughputWindows"].as_object_mut().unwrap();
    if windows.len() > 3600 {
        let oldest = windows
            .keys()
            .min_by_key(|k| k.parse::<u64>().unwrap_or(0))
            .unwrap()
            .clone();
        windows.remove(&oldest);
    }
    if record["checksumState"] == "validated_failure" {
        state["errorCount"] = json!(state["errorCount"].as_u64().unwrap_or(0) + 1);
    }
}

fn append_benchmark_csv(
    state: &Value,
    records: &[Value],
    resources: &benchmark_runtime::Resources,
) -> Result<(), SidecarError> {
    let path = Path::new(
        state["config"]["csvOutputPath"]
            .as_str()
            .unwrap_or("benchmark-results.csv"),
    );
    let result = (|| -> io::Result<()> {
        let mut writer = resources.csv.lock().unwrap();
        if writer.is_none() {
            if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                fs::create_dir_all(parent)?;
            }
            let header = !path.exists();
            let mut output = io::BufWriter::new(
                fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)?,
            );
            if header {
                writeln!(output, "second,operation,operationCount,latencyMs,sizeBytes,bytesTransferred,success,checksumState,key,elapsedMs")?;
            }
            *writer = Some(output);
        }
        let output = writer.as_mut().unwrap();
        for record in records {
            let key = record["key"].as_str().unwrap_or("").replace('"', "\"\"");
            writeln!(
                output,
                "{},{},{},{},{},{},true,{},\"{}\",{}",
                record["second"],
                record["operation"].as_str().unwrap_or(""),
                benchmark_operation_count(record),
                record["latencyMs"],
                record["sizeBytes"],
                record["bytesTransferred"],
                record["checksumState"].as_str().unwrap_or("not_used"),
                key,
                record["elapsedMs"]
            )?;
        }
        Ok(())
    })();
    result.map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))
}

pub(super) fn benchmark_summary_from_state(state: &Value) -> Value {
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
    let throughput_series: Vec<Value> = ((window_count - 3599).max(1)..=window_count)
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
            let exact = &state["throughputWindows"][second.to_string()];
            if exact.is_object() {
                ops_per_second = exact["operationsCount"].as_i64().unwrap_or(0);
                bytes_per_second = exact["bytes"].as_i64().unwrap_or(0);
                operations = exact["operations"].as_object().cloned().unwrap_or_default();
            }
            json!({
                "second": second,
                "label": format!("{second}s"),
                "opsPerSecond": ops_per_second,
                "bytesPerSecond": bytes_per_second,
                "averageLatencyMs": if exact.is_object() { round1(exact["latencyMs"].as_f64().unwrap_or(0.0) / exact["records"].as_f64().unwrap_or(1.0).max(1.0)) } else { round1(mean_f64(&window_latencies)) },
                "p95LatencyMs": round1(percentile(&window_latencies, 95.0)),
                "operations": operations,
            })
        })
        .collect();
    let latency_timeline: Vec<Value> = history
        .iter()
        .enumerate()
        .map(|(index, record)| {
            let elapsed_ms = record["elapsedMs"].as_f64().unwrap_or(0.0).max(0.0);
            let second = ((elapsed_ms / 1000.0).floor() as i64).max(0) + 1;
            let plotted_elapsed_ms = elapsed_ms;
            json!({
                "sequence": state["totalRecordCount"].as_u64().unwrap_or(0).saturating_sub(history.len() as u64) + index as u64 + 1,
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
        "totalOperations": state["processedCount"].as_u64().unwrap_or(0),
        "operationsByType": state.get("totalOperationsByType").cloned().unwrap_or(Value::Object(operations_by_type)),
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
        "checksumStats": state.get("totalChecksumStats").cloned().unwrap_or(Value::Object(checksum_stats.clone())),
        "detailMetrics": {
            "checksumAlgorithm": state["config"]["checksumAlgorithm"].as_str().unwrap_or("sha256"),
            "sampleCount": sample_count,
            "sampleWindowSeconds": 1,
            "averageOpsPerSecond": round1(state["processedCount"].as_f64().unwrap_or(0.0) / state["activeElapsedSeconds"].as_f64().unwrap_or(0.0).max(0.000001)),
            "peakOpsPerSecond": peak_ops,
            "averageBytesPerSecond": round1(state["totalBytes"].as_f64().unwrap_or(0.0) / state["activeElapsedSeconds"].as_f64().unwrap_or(0.0).max(0.000001)),
            "peakBytesPerSecond": peak_bytes,
            "averageObjectSizeBytes": average_object_size,
            "checksumValidated": state["totalChecksumStats"]["validated_success"].as_u64().unwrap_or(0),
            "errorCount": state["errorCount"].as_u64().unwrap_or(0),
            "retryCount": state["retryCount"].as_u64().unwrap_or(0),
            "historyLimit": benchmark_runtime::HISTORY_LIMIT,
            "historyRecordsRetained": history.len(),
            "historyTruncated": state["totalRecordCount"].as_u64().unwrap_or(0) > history.len() as u64,
            "latencyStatisticsScope": "retained-recent-requests",
            "cacheBytes": state["cacheBytes"].as_u64().unwrap_or(0),
            "connectionLimitScope": "in-flight-benchmark-requests",
            "sdkConnectionPoolLimitSupported": benchmark_backend::POOL_LIMIT_SUPPORTED,
        },
    })
}
