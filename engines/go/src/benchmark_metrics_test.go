package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strings"
	"testing"
	"time"
)

func TestBenchmarkRatesUseActualActiveSeconds(t *testing.T) {
	for _, duration := range []float64{0.125, 1.25, 2.5} {
		t.Run(fmt.Sprint(duration), func(t *testing.T) {
			state := map[string]interface{}{
				"status": "completed", "activeElapsedSeconds": duration,
				"history": []map[string]interface{}{
					{"operation": "PUT", "operationCount": 2, "second": 1, "elapsedMs": 20.125, "bytesTransferred": 1000},
					{"operation": "DELETE", "operationCount": 3, "second": 1, "elapsedMs": 30.125},
					{"operation": "GET", "operationCount": 1, "second": int(math.Ceil(duration)), "elapsedMs": duration * 1000, "bytesTransferred": 1500},
				},
			}
			refreshBenchmarkSnapshot(state)
			summary := asMap(state["resultSummary"])
			details := asMap(summary["detailMetrics"])
			if got := asFloat(details["averageOpsPerSecond"]); got != roundFloat(6/duration) {
				t.Fatalf("%.3fs rate = %v, expected %v", duration, got, roundFloat(6/duration))
			}
			if asFloat(details["averageBytesPerSecond"]) != roundFloat(2500/duration) || asFloat(state["throughputOpsPerSecond"]) != roundFloat(6/duration) || asFloat(state["throughputBytesPerSecond"]) != roundFloat(2500/duration) {
				t.Fatalf("snapshot and summary must use cumulative active-time rates: %v", state)
			}
			windows := asMapSlice(summary["throughputSeries"])
			last := windows[len(windows)-1]
			windowSeconds := duration - float64(int(math.Ceil(duration))-1)
			if asFloat(last["windowSeconds"]) != windowSeconds || asFloat(last["opsPerSecond"]) != roundFloat(float64(asInt(last["operationCount"]))/windowSeconds) {
				t.Fatalf("partial final window was treated as a full second: %v", last)
			}
		})
	}
}

func TestBenchmarkHistoryPreservesMeasuredTimingAndMarksLegacyBuckets(t *testing.T) {
	stamp := "2026-10-02T12:34:56.123456789Z"
	state := map[string]interface{}{"activeElapsedSeconds": 3.0, "history": []map[string]interface{}{
		{"operation": "PUT", "second": 1, "elapsedMs": 0.0, "timestamp": stamp},
		{"operation": "GET", "second": 1, "elapsedMs": 125.123456, "timestamp": stamp, "timingSource": "monotonic-completion"},
		{"operation": "GET", "second": 2},
		{"operation": "DELETE", "second": 2},
	}}
	timeline := asMapSlice(benchmarkSummaryFromState(state)["latencyTimeline"])
	if asFloat(timeline[0]["elapsedMs"]) != 0 || timeline[0]["timingSource"] != "recorded-elapsed" || timeline[0]["timestamp"] != stamp {
		t.Fatalf("zero elapsed or original timestamp was overwritten: %v", timeline[0])
	}
	if asFloat(timeline[1]["elapsedMs"]) != 125.123456 || timeline[1]["timingSource"] != "monotonic-completion" {
		t.Fatalf("recorded completion precision was lost: %v", timeline[1])
	}
	for _, item := range timeline[2:] {
		if asFloat(item["elapsedMs"]) != 2000 || item["timingSource"] != "legacy-coarse" {
			t.Fatalf("legacy bucket fabricated a subsecond completion: %v", item)
		}
	}
}

func TestBenchmarkCompletionAnchorsToActiveClockBeforeBatchSetup(t *testing.T) {
	anchor := time.Now().Add(-175 * time.Millisecond)
	config := map[string]interface{}{"workloadType": "write-only", "testMode": "operation-count", "objectSizes": []interface{}{16}, "reducedLogging": true}
	state := map[string]interface{}{"id": "completion-clock", "config": config, "activeElapsedSeconds": 2.5, "_benchmarkClock": anchor}
	executor := &benchmarkExecutor{put: func(string, []byte) error { return nil }}
	if err := runBenchmarkBatch(state, executor, config, 1, 1, 1); err != nil {
		t.Fatal(err)
	}
	record := asMapSlice(state["history"])[0]
	completed, err := time.Parse(time.RFC3339Nano, asString(record["timestamp"]))
	if err != nil {
		t.Fatal(err)
	}
	expected := (2.5 + completed.Sub(anchor).Seconds()) * 1000
	if got := asFloat(record["elapsedMs"]); got < 2675 || math.Abs(got-expected) > 0.1 {
		t.Fatalf("completion %.9f did not include measured setup time; expected %.9f", got, expected)
	}
	if record["timingSource"] != "monotonic-completion" {
		t.Fatal("new history omitted its timing provenance")
	}
}

func TestBenchmarkActiveTimeExcludesPausedAndTerminalTime(t *testing.T) {
	start := time.Now()
	state := map[string]interface{}{"status": "running", "_benchmarkClock": start, "activeElapsedSeconds": 0.0}
	advanceBenchmarkClockAt(state, start.Add(125*time.Millisecond))
	state["status"] = "paused"
	advanceBenchmarkClockAt(state, start.Add(90*time.Second))
	if asFloat(state["activeElapsedSeconds"]) != 0.125 {
		t.Fatal("paused time was counted")
	}
	state["status"] = "running"
	advanceBenchmarkClockAt(state, start.Add(90*time.Second+250*time.Millisecond))
	state["status"] = "stopped"
	advanceBenchmarkClockAt(state, start.Add(time.Hour))
	if asFloat(state["activeElapsedSeconds"]) != 0.375 {
		t.Fatalf("resume or terminal time was incorrect: %v", state)
	}
}

func TestBenchmarkDurationOverrunIsNotClampedForRateReporting(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	state := checkpointTestState(t)
	t.Cleanup(func() { closeBenchmarkCSV(state) })
	asMap(state["config"])["testMode"] = "duration"
	asMap(state["config"])["durationSeconds"] = 1
	state["activeElapsedSeconds"] = 2.25
	checkpointTestAddResult(state)
	if _, err := materializeBenchmarkState(state); err != nil {
		t.Fatal(err)
	}
	if state["status"] != "completed" || asFloat(state["activeElapsedSeconds"]) < 2.25 {
		t.Fatalf("actual active duration was replaced by configured duration: %v", state)
	}
	if asFloat(state["throughputOpsPerSecond"]) != roundFloat(1/asFloat(state["activeElapsedSeconds"])) {
		t.Fatal("terminal throughput did not use measured overrun")
	}
}

func TestBenchmarkBoundedHistoryRetainsCumulativeMetricsAndFullCSVAfterRestart(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	state := checkpointTestState(t)
	asMap(state["config"])["reducedLogging"] = true
	state["errorCount"], state["retryCount"] = 3, 17
	const count = benchmarkHistoryLimit + 37
	key := "opaque,\"key\"\nwith newline"
	totalOps, totalBytes, failedChecksums, deleteOps := 0, 0, 0, 0
	appendRecord := func(target map[string]interface{}, index int) {
		operation, operationCount, transferred := "GET", 1, 32
		if index%7 == 0 {
			operation, operationCount, transferred = "DELETE", 3, 0
			deleteOps += operationCount
		}
		checksum := "validated_success"
		if index%17 == 0 {
			checksum = "validated_failure"
			failedChecksums += operationCount
		}
		latency := 1.0
		if index < 37 {
			latency = 100.0
		}
		applyBenchmarkResult(target, benchmarkOpPlan{operation: operation, key: key}, benchmarkOpResult{
			displayKey: key, sizeBytes: 32, bytesTransferred: transferred, operationCount: operationCount,
			latencyMs: latency, checksumState: checksum,
		}, float64(index+1)/1000)
		totalOps += operationCount
		totalBytes += transferred
	}
	for index := 0; index < count; index++ {
		appendRecord(state, index)
	}
	state["activeElapsedSeconds"] = float64(count)/1000 + 0.125
	state["status"] = "paused"
	if err := checkpointBenchmarkState(state, true); err != nil {
		t.Fatal(err)
	}
	closeBenchmarkCSV(state)
	csvPath := asString(asMap(state["config"])["csvOutputPath"])
	// Simulate a crash after uncheckpointed CSV output. Recovery must append to
	// the committed offset rather than duplicating rows or trusting a partial tail.
	file, err := os.OpenFile(csvPath, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = file.WriteString("uncheckpointed partial crash tail\n")
	file.Close()
	restored, err := readBenchmarkState(asString(state["id"]))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeBenchmarkCSV(restored) })
	if len(asMapSlice(restored["history"])) != benchmarkHistoryLimit || restored["status"] != "paused" {
		t.Fatal("bounded history or pause state was not recovered")
	}
	for index := count; index < count+5; index++ {
		appendRecord(restored, index)
	}
	restored["activeElapsedSeconds"] = float64(count+5)/1000 + 0.25
	restored["status"] = "completed"
	for index := 0; index < 2; index++ {
		if err = checkpointBenchmarkState(restored, true); err != nil {
			t.Fatal(err)
		}
	}
	summary := asMap(restored["resultSummary"])
	details := asMap(summary["detailMetrics"])
	if len(asMapSlice(restored["history"])) != benchmarkHistoryLimit || asInt(summary["totalOperations"]) != totalOps || asInt(summary["totalBytesTransferred"]) != totalBytes || asInt(restored["processedCount"]) != totalOps {
		t.Fatalf("cumulative totals shrank with history eviction: %v", details)
	}
	if asInt(asMap(summary["operationsByType"])["DELETE"]) != deleteOps || asInt(asMap(summary["checksumStats"])["validated_failure"]) != failedChecksums || asInt(details["retryCount"]) != 17 || asInt(details["errorCount"]) != 3+(count+4)/17+1 {
		t.Fatalf("restart lost cumulative operation/error/checksum counters: %v", summary)
	}
	if !asBool(details["historyTruncated"]) || details["latencyPercentileScope"] != "recent retained history" || asInt(details["totalHistoryCount"]) != count+5 {
		t.Fatalf("recent-history statistics were not identified: %v", details)
	}
	if asFloat(restored["averageLatencyMs"]) <= 1 || asFloat(asMap(summary["latencyPercentilesMs"])["p50"]) != 1 {
		t.Fatal("average latency must remain cumulative while percentiles use retained history")
	}
	if asFloat(details["averageOpsPerSecond"]) != roundFloat(float64(totalOps)/asFloat(restored["activeElapsedSeconds"])) {
		t.Fatal("bounded history changed cumulative throughput")
	}
	timeline := asMapSlice(summary["latencyTimeline"])
	if asInt(timeline[0]["sequence"]) != 43 || asInt(timeline[len(timeline)-1]["sequence"]) != count+5 {
		t.Fatal("retained history sequence restarted at one")
	}
	file, err = os.Open(csvPath)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := csv.NewReader(file).ReadAll()
	file.Close()
	if err != nil || len(rows) != count+6 {
		t.Fatalf("CSV lost/duplicated records across checkpoints: rows=%d, err=%v", len(rows), err)
	}
	if rows[1][8] != key || rows[len(rows)-1][11] != "monotonic-completion" {
		t.Fatal("streamed CSV lost exact keys or measured timing")
	}
	encoded, err := json.Marshal(benchmarkSnapshot(restored))
	if err != nil || strings.Contains(string(encoded), "_benchmark") || strings.Contains(string(encoded), "sentinel") {
		t.Fatal("runtime writer or credentials leaked into public state")
	}
}

func TestBenchmarkRecoveryRejectsTruncatedCSV(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	state := checkpointTestState(t)
	checkpointTestAddResult(state)
	if err := checkpointBenchmarkState(state, true); err != nil {
		t.Fatal(err)
	}
	closeBenchmarkCSV(state)
	if err := os.Truncate(asString(asMap(state["config"])["csvOutputPath"]), 3); err != nil {
		t.Fatal(err)
	}
	restored, err := readBenchmarkState(asString(state["id"]))
	if err != nil {
		t.Fatal(err)
	}
	if err = checkpointBenchmarkState(restored, true); err == nil || !strings.Contains(err.Error(), "shorter") {
		t.Fatalf("missing full CSV was silently reconstructed from partial history: %v", err)
	}
}

func TestBenchmarkLegacyUnboundedRecoveryUpgradesWithoutLosingCSV(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	state := checkpointTestState(t)
	const count = benchmarkHistoryLimit + 2
	history := make([]map[string]interface{}, count)
	for index := range history {
		history[index] = map[string]interface{}{
			"operation": "GET", "operationCount": 1, "second": index/1000 + 1,
			"latencyMs": 2.0, "bytesTransferred": 16, "checksumState": "validated_success", "key": fmt.Sprint(index),
		}
	}
	state["history"], state["processedCount"] = history, count
	state["activeElapsedSeconds"], state["status"] = 10.25, "paused"
	if err := writeBenchmarkState(state); err != nil {
		t.Fatal(err)
	}
	restored, err := readBenchmarkState(asString(state["id"]))
	if err != nil {
		t.Fatal(err)
	}
	if len(asMapSlice(restored["history"])) != benchmarkHistoryLimit || asInt(benchmarkCumulativeMetrics(restored)["operationCount"]) != count {
		t.Fatal("upgrading legacy recovery dropped cumulative results")
	}
	if err = checkpointBenchmarkState(restored, true); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(asString(asMap(restored["config"])["csvOutputPath"]))
	if err != nil {
		t.Fatal(err)
	}
	rows, err := csv.NewReader(file).ReadAll()
	file.Close()
	if err != nil || len(rows) != count+1 || rows[1][11] != "legacy-coarse" {
		t.Fatalf("legacy records were not fully archived before eviction: rows=%d, err=%v", len(rows), err)
	}
	// Repeated recovery must use cumulative counters rather than reseeding them
	// from the now-bounded history, and must preserve the full archive.
	again, err := readBenchmarkState(asString(state["id"]))
	if err != nil || asInt(benchmarkCumulativeMetrics(again)["recordCount"]) != count {
		t.Fatalf("second recovery changed cumulative counts: %v", err)
	}
}
