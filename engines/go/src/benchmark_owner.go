package main

import (
	"encoding/json"
	"math"
	"runtime"
	"strings"
	"sync"
	"time"
)

type benchmarkOwner struct {
	mu    sync.Mutex
	state map[string]interface{}
}

var benchmarkOwners = struct {
	sync.Mutex
	items map[string]*benchmarkOwner
}{items: map[string]*benchmarkOwner{}}

func benchmarkSafeState(state map[string]interface{}) map[string]interface{} {
	safe := make(map[string]interface{}, len(state))
	for key, value := range state {
		if key != "profile" && !strings.HasPrefix(key, "_benchmark") {
			safe[key] = value
		}
	}
	return safe
}

func benchmarkSnapshot(state map[string]interface{}) map[string]interface{} {
	data, _ := json.Marshal(benchmarkSafeState(state))
	var cloned map[string]interface{}
	_ = json.Unmarshal(data, &cloned)
	return cloned
}

const benchmarkCheckpointInterval = 250 * time.Millisecond

// The owning worker/control holds its mutex. Operation history and counters
// advance continuously; the expensive derived summary and disk artifacts are
// checkpointed at most four times a second, unless a complete flush is required.
func checkpointBenchmarkState(state map[string]interface{}, force bool) error {
	if status := asString(state["status"]); status != "running" && status != "" {
		defer closeBenchmarkCSV(state)
	}
	if previous, ok := state["_benchmarkCheckpoint"].(time.Time); !force && ok && time.Since(previous) < benchmarkCheckpointInterval {
		return nil
	}
	refreshBenchmarkSnapshot(state)
	outputErr := persistBenchmarkOutputs(state)
	// Keep recoverable state current even if an optional output path fails.
	stateErr := writeBenchmarkState(state)
	if outputErr != nil {
		return outputErr
	}
	if stateErr != nil {
		return stateErr
	}
	state["_benchmarkCheckpoint"] = time.Now()
	return nil
}

func registerBenchmarkOwner(state map[string]interface{}) map[string]interface{} {
	state["_benchmarkClock"] = time.Now()
	owner := &benchmarkOwner{state: state}
	snapshot := benchmarkSnapshot(state)
	benchmarkOwners.Lock()
	// Completed states remain on disk; retain at most 32 process-owned run objects.
	if len(benchmarkOwners.items) >= 32 {
		for id, item := range benchmarkOwners.items {
			item.mu.Lock()
			status := asString(item.state["status"])
			item.mu.Unlock()
			if status == "completed" || status == "stopped" || status == "failed" {
				delete(benchmarkOwners.items, id)
				break
			}
		}
	}
	benchmarkOwners.items[asString(state["id"])] = owner
	benchmarkOwners.Unlock()
	go func() {
		for {
			owner.mu.Lock()
			status := asString(state["status"])
			if status == "completed" || status == "stopped" || status == "failed" {
				closeBenchmarkCSV(state)
				delete(state, "profile")
				delete(state, "_benchmarkPayloadStore")
				delete(state, "_benchmarkCounters")
				owner.mu.Unlock()
				return
			}
			if status != "paused" {
				if _, err := materializeBenchmarkState(state); err != nil {
					advanceBenchmarkClock(state)
					state["status"] = "failed"
					state["completedAt"] = serializeTimePtr(time.Now().UTC())
					appendBenchmarkLog(state, "Benchmark failed: "+err.Error())
					_ = checkpointBenchmarkState(state, true)
				}
			}
			owner.mu.Unlock()
			if status == "paused" {
				time.Sleep(100 * time.Millisecond)
			} else {
				runtime.Gosched()
			}
		}
	}()
	return snapshot
}
func benchmarkOwnedControl(params map[string]interface{}, action string) (map[string]interface{}, error) {
	id := asString(params["runId"])
	benchmarkOwners.Lock()
	owner := benchmarkOwners.items[id]
	benchmarkOwners.Unlock()
	if owner == nil {
		state, err := loadBenchmarkState(params)
		if err != nil {
			return nil, err
		}
		status := asString(state["status"])
		if status == "running" {
			state["status"] = "paused"
			appendBenchmarkLog(state, "Owning engine exited. Resume with securely supplied credentials to continue.")
		}
		if action == "running" {
			if len(asMap(params["profile"])) == 0 {
				return nil, &sidecarError{Code: "invalid_config", Message: "Secure profile reauthorization is required to resume this benchmark."}
			}
			state["status"] = "running"
			state["lastUpdatedAt"] = serializeTimePtr(time.Now().UTC())
			state["_benchmarkClock"] = time.Now()
			if err = checkpointBenchmarkState(state, true); err != nil {
				return nil, err
			}
			return registerBenchmarkOwner(state), nil
		}
		if action == "stopped" {
			state["status"] = "stopped"
			state["completedAt"] = serializeTimePtr(time.Now().UTC())
		}
		defer closeBenchmarkCSV(state)
		if err = checkpointBenchmarkState(state, true); err != nil {
			return nil, err
		}
		return benchmarkSnapshot(state), nil
	}
	owner.mu.Lock()
	defer owner.mu.Unlock()
	state := owner.state
	status := asString(state["status"])
	if action != "status" && action != "export" && status != "completed" && status != "stopped" && status != "failed" {
		if status == "running" {
			advanceBenchmarkClock(state)
		}
		if p := asMap(params["profile"]); len(p) > 0 {
			state["profile"] = p
		}
		state["status"] = action
		state["lastUpdatedAt"] = serializeTimePtr(time.Now().UTC())
		state["_benchmarkClock"] = time.Now()
		appendBenchmarkLog(state, "Benchmark "+action+" by user.")
		if action == "stopped" {
			state["completedAt"] = serializeTimePtr(time.Now().UTC())
		}
		if err := checkpointBenchmarkState(state, true); err != nil {
			return nil, err
		}
	}
	if action == "export" {
		if status == "running" {
			advanceBenchmarkClock(state)
		}
		if err := checkpointBenchmarkState(state, true); err != nil {
			return nil, err
		}
	}
	return benchmarkSnapshot(state), nil
}

// Keep duration independent of wall-clock adjustments and status polling.
func advanceBenchmarkClock(state map[string]interface{}) {
	advanceBenchmarkClockAt(state, time.Now())
}

func advanceBenchmarkClockAt(state map[string]interface{}, now time.Time) {
	status := asString(state["status"])
	if previous, ok := state["_benchmarkClock"].(time.Time); ok && (status == "running" || status == "") {
		state["activeElapsedSeconds"] = asFloat(state["activeElapsedSeconds"]) + math.Max(now.Sub(previous).Seconds(), 0)
	}
	state["_benchmarkClock"] = now
	state["lastUpdatedAt"] = serializeTimePtr(now)
}
