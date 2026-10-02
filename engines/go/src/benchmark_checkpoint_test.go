package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func checkpointTestState(t *testing.T) map[string]interface{} {
	t.Helper()
	dir := t.TempDir()
	return map[string]interface{}{
		"id": strings.ReplaceAll(t.Name(), "/", "-"), "status": "running", "profile": testProfilePayload("http://localhost"),
		"processedCount": 0, "history": []map[string]interface{}{},
		"_benchmarkClock": time.Now(), "_benchmarkCheckpoint": time.Now(),
		"config": map[string]interface{}{
			"testMode": "operation-count", "operationCount": 2,
			"csvOutputPath":  filepath.Join(dir, "results.csv"),
			"jsonOutputPath": filepath.Join(dir, "results.json"),
			"logFilePath":    filepath.Join(dir, "benchmark.log"),
		},
	}
}

func checkpointTestAddResult(state map[string]interface{}) {
	applyBenchmarkResult(state,
		benchmarkOpPlan{operation: "PUT", key: "key", sizeBytes: 16},
		benchmarkOpResult{displayKey: "key", sizeBytes: 16, bytesTransferred: 16, operationCount: 1, latencyMs: 1, checksumState: "not_used"}, 0.1)
}

func assertCheckpointCounts(t *testing.T, state map[string]interface{}, expected int) {
	t.Helper()
	data, err := os.ReadFile(benchmarkStatePath(asString(state["id"])))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "sentinel") || strings.Contains(string(data), "_benchmark") || strings.Contains(string(data), `"profile"`) {
		t.Fatal("private benchmark state was persisted")
	}
	var disk map[string]interface{}
	if err := json.Unmarshal(data, &disk); err != nil {
		t.Fatal(err)
	}
	if asInt(disk["processedCount"]) != expected || asInt(asMap(disk["resultSummary"])["totalOperations"]) != expected {
		t.Fatalf("disk counts disagree with %d: %v", expected, disk)
	}
	info, err := os.Stat(benchmarkStatePath(asString(state["id"])))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("state must remain private: %v, %v", info, err)
	}
	config := asMap(state["config"])
	data, err = os.ReadFile(asString(config["jsonOutputPath"]))
	if err != nil {
		t.Fatal(err)
	}
	var summary map[string]interface{}
	if err := json.Unmarshal(data, &summary); err != nil {
		t.Fatal(err)
	}
	if asInt(summary["totalOperations"]) != expected {
		t.Fatalf("JSON output has stale counters: %v", summary)
	}
	data, err = os.ReadFile(asString(config["csvOutputPath"]))
	if err != nil {
		t.Fatal(err)
	}
	if rows := strings.Count(string(data), "\n") - 1; rows != expected {
		t.Fatalf("CSV contains %d operations; expected %d", rows, expected)
	}
	public, err := json.Marshal(benchmarkSnapshot(state))
	if err != nil || strings.Contains(string(public), "_benchmark") || strings.Contains(string(public), "sentinel") {
		t.Fatalf("public snapshot contains process-only or secret data: %s, %v", public, err)
	}
}

func TestBenchmarkCheckpointThrottlesWritesWithoutLosingFinalCounts(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	state := checkpointTestState(t)
	if err := checkpointBenchmarkState(state, true); err != nil {
		t.Fatal(err)
	}
	checkpointTestAddResult(state)
	// A future marker avoids wall-clock timing assumptions in the suppressed path.
	state["_benchmarkCheckpoint"] = time.Now().Add(time.Hour)
	for index := 0; index < 100; index++ {
		if err := checkpointBenchmarkState(state, false); err != nil {
			t.Fatal(err)
		}
	}
	if asInt(state["processedCount"]) != 1 || asInt(asMap(state["resultSummary"])["totalOperations"]) != 0 {
		t.Fatal("live counters must advance without rebuilding the checkpoint summary")
	}
	assertCheckpointCounts(t, state, 0)
	state["_benchmarkCheckpoint"] = time.Now().Add(-benchmarkCheckpointInterval - time.Millisecond)
	if err := checkpointBenchmarkState(state, false); err != nil {
		t.Fatal(err)
	}
	assertCheckpointCounts(t, state, 1)

	checkpointTestAddResult(state)
	state["_benchmarkCheckpoint"] = time.Now().Add(time.Hour)
	// The operation limit is already met; materialization must complete and flush
	// both operations even though the next periodic checkpoint is not due.
	if _, err := materializeBenchmarkState(state); err != nil {
		t.Fatal(err)
	}
	if state["status"] != "completed" {
		t.Fatalf("terminal status missing: %v", state["status"])
	}
	assertCheckpointCounts(t, state, 2)
}

func TestBenchmarkControlsFlushPendingResults(t *testing.T) {
	for _, action := range []string{"status", "paused", "stopped", "export"} {
		t.Run(action, func(t *testing.T) {
			t.Setenv("TMPDIR", t.TempDir())
			state := checkpointTestState(t)
			if err := checkpointBenchmarkState(state, true); err != nil {
				t.Fatal(err)
			}
			checkpointTestAddResult(state)
			state["_benchmarkCheckpoint"] = time.Now().Add(time.Hour)
			id := asString(state["id"])
			// Register only the owner, so controls operate on a deterministic pending
			// result without an unrelated worker completing more storage operations.
			benchmarkOwners.Lock()
			benchmarkOwners.items[id] = &benchmarkOwner{state: state}
			benchmarkOwners.Unlock()
			t.Cleanup(func() {
				benchmarkOwners.Lock()
				delete(benchmarkOwners.items, id)
				benchmarkOwners.Unlock()
			})
			params := map[string]interface{}{"runId": id, "format": "json"}
			var result map[string]interface{}
			var err error
			if action == "export" {
				result, err = exportBenchmarkResults(params)
			} else {
				result, err = benchmarkOwnedControl(params, action)
			}
			if err != nil {
				t.Fatal(err)
			}
			if action == "status" {
				if asInt(result["processedCount"]) != 1 {
					t.Fatal("status must expose the current operation count")
				}
				assertCheckpointCounts(t, state, 0)
			} else {
				assertCheckpointCounts(t, state, 1)
				if action == "export" && asInt(asMap(result["summary"])["totalOperations"]) != 1 {
					t.Fatal("export returned a stale summary")
				}
			}
			if (action == "status" || action == "export") && state["status"] != "running" {
				t.Fatalf("read action changed run status: %v", state["status"])
			}
		})
	}
}

func TestBenchmarkCheckpointFailureKeepsRecoveryStateCurrent(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	state := checkpointTestState(t)
	checkpointTestAddResult(state)
	// Writing a JSON output over a directory must fail, while the separate
	// private state file still records the complete recoverable result.
	asMap(state["config"])["jsonOutputPath"] = t.TempDir()
	state["status"] = "failed"
	if err := checkpointBenchmarkState(state, true); err == nil {
		t.Fatal("output failure was hidden")
	}
	disk, err := readBenchmarkState(asString(state["id"]))
	if err != nil {
		t.Fatal(err)
	}
	if disk["status"] != "failed" || asInt(disk["processedCount"]) != 1 || asInt(asMap(disk["resultSummary"])["totalOperations"]) != 1 {
		t.Fatalf("failed checkpoint lost completed operations: %v", disk)
	}
}
