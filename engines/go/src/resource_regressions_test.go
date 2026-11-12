package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestVersionListingContinuesWithBothMarkers(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "application/xml")
		if r.URL.Query().Get("version-id-marker") == "v1000" {
			if r.URL.Query().Get("key-marker") != "folder/key +" {
				t.Error("key marker lost or escaped twice")
			}
			fmt.Fprint(w, `<ListVersionsResult><IsTruncated>false</IsTruncated><DeleteMarker><Key>folder/key +</Key><VersionId>v1001</VersionId><IsLatest>false</IsLatest><LastModified>2026-01-01T00:00:00Z</LastModified></DeleteMarker></ListVersionsResult>`)
			return
		}
		fmt.Fprint(w, `<ListVersionsResult><IsTruncated>true</IsTruncated><NextKeyMarker>folder/key +</NextKeyMarker><NextVersionIdMarker>v1000</NextVersionIdMarker>`)
		for i := 0; i < 1000; i++ {
			fmt.Fprintf(w, `<Version><Key>folder/key +</Key><VersionId>v%d</VersionId><IsLatest>false</IsLatest><LastModified>2026-01-01T00:00:00Z</LastModified><Size>1</Size></Version>`, i)
		}
		fmt.Fprint(w, `</ListVersionsResult>`)
	}))
	defer server.Close()
	params := map[string]interface{}{"profile": testProfilePayload(server.URL), "bucketName": "bucket", "key": "folder/key +"}
	first, err := listObjectVersions(params)
	if err != nil {
		t.Fatal(err)
	}
	if len(first["items"].([]map[string]interface{})) != 1000 || !asBool(asMap(first["cursor"])["hasMore"]) {
		t.Fatalf("first page: %v", first["cursor"])
	}
	params["cursor"] = first["cursor"]
	second, err := listObjectVersions(params)
	if err != nil {
		t.Fatal(err)
	}
	items := second["items"].([]map[string]interface{})
	if len(items) != 1 || items[0]["versionId"] != "v1001" || asBool(asMap(second["cursor"])["hasMore"]) || requests.Load() != 2 {
		t.Fatalf("continuation failed: %v", second)
	}
}

func TestVersionListingRejectsMissingAndRepeatedMarkers(t *testing.T) {
	for _, markers := range [][4]string{{"", "", "", ""}, {"key", "v", "key", "v"}} {
		if _, err := encodeVersionCursor(true, markers[0], markers[1], markers[2], markers[3]); err == nil {
			t.Fatal("nonadvancing cursor accepted")
		}
	}
	if _, _, err := decodeVersionCursor(map[string]interface{}{"value": `{"keyMarker":42}`}); err == nil {
		t.Fatal("invalid cursor accepted")
	}
}

func TestDownloadAtomicPublicationDoesNotReplaceRacingTarget(t *testing.T) {
	directory := t.TempDir()
	destination, err := newDownloadDestination(directory)
	if err != nil {
		t.Fatal(err)
	}
	// Another process creates the target after our single directory scan.
	if err = os.WriteFile(filepath.Join(directory, "report.txt"), []byte("LOCAL"), 0600); err != nil {
		t.Fatal(err)
	}
	target, err := destination.publish(stageDownload(t, directory), "report.txt", "keepBoth")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(target) != "report (1).txt" {
		t.Fatalf("wrong target: %s", target)
	}
	second, err := destination.publish(stageDownload(t, directory), "report.txt", "keepBoth")
	if err != nil || filepath.Base(second) != "report (2).txt" {
		t.Fatalf("batch index not updated: %s %v", second, err)
	}
	data, err := os.ReadFile(filepath.Join(directory, "report.txt"))
	if err != nil || string(data) != "LOCAL" {
		t.Fatal("racing file was replaced")
	}
}

func TestUploadSourceRevalidationRejectsSameSizeEditAndReplacement(t *testing.T) {
	for _, replace := range []bool{false, true} {
		t.Run(fmt.Sprint(replace), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "source")
			if err := os.WriteFile(path, []byte("ORIGINAL"), 0600); err != nil {
				t.Fatal(err)
			}
			prepared, _ := os.Stat(path)
			handle, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer handle.Close()
			if err = verifyUploadSource(handle, path, prepared); err != nil {
				t.Fatal(err)
			}
			if replace {
				if err = os.Rename(path, path+".old"); err != nil {
					t.Fatal(err)
				}
			}
			if err = os.WriteFile(path, []byte("MODIFIED"), 0600); err != nil {
				t.Fatal(err)
			}
			changed := prepared.ModTime().Add(time.Second)
			if err = os.Chtimes(path, changed, changed); err != nil {
				t.Fatal(err)
			}
			if err = verifyUploadSource(handle, path, prepared); err == nil {
				t.Fatal("changed source accepted")
			}
		})
	}
}

func TestMultipartSourceMutationAbortsBeforeCompletion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "source.bin")
	if err := os.WriteFile(path, []byte(strings.Repeat("a", 6*1024*1024)), 0600); err != nil {
		t.Fatal(err)
	}
	var completed, aborted atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		switch {
		case r.Method == http.MethodPost && r.URL.Query().Has("uploads"):
			fmt.Fprint(w, `<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>`)
		case r.Method == http.MethodPut:
			_, _ = io.Copy(io.Discard, r.Body)
			info, _ := os.Stat(path)
			changed := info.ModTime().Add(time.Second)
			_ = os.Chtimes(path, changed, changed)
			w.Header().Set("ETag", `"part"`)
		case r.Method == http.MethodDelete:
			aborted.Add(1)
			w.WriteHeader(204)
		case r.Method == http.MethodPost:
			completed.Add(1)
			fmt.Fprint(w, `<CompleteMultipartUploadResult/>`)
		default:
			t.Errorf("unexpected method: %s", r.Method)
		}
	}))
	defer server.Close()
	_, err := startUpload(map[string]interface{}{"profile": testProfilePayload(server.URL), "bucketName": "bucket", "filePaths": []interface{}{path}, "multipartThresholdMiB": 1, "multipartChunkMiB": 5})
	if err == nil || completed.Load() != 0 || aborted.Load() != 1 {
		t.Fatalf("source mutation cleanup: error=%v complete=%d abort=%d", err, completed.Load(), aborted.Load())
	}
}

func TestProgressGateCoalescesAndForcesFinalUpdate(t *testing.T) {
	gate := newTransferProgressGate(map[string]interface{}{"progressIntervalMs": 2000})
	if !gate.ready(false) {
		t.Fatal("initial progress suppressed")
	}
	for i := 0; i < 1000; i++ {
		if gate.ready(false) {
			t.Fatal("unbounded intermediate progress")
		}
	}
	if !gate.ready(true) {
		t.Fatal("forced update suppressed")
	}
}

func TestBusyBenchmarkControlsAcknowledgeWithoutExecutionLock(t *testing.T) {
	isolateBenchmarkTempDir(t)
	state := checkpointTestState(t)
	owner := &benchmarkOwner{state: state}
	owner.publish()
	id := asString(state["id"])
	benchmarkOwners.Lock()
	benchmarkOwners.items[id] = owner
	benchmarkOwners.Unlock()
	t.Cleanup(func() { benchmarkOwners.Lock(); delete(benchmarkOwners.items, id); benchmarkOwners.Unlock() })
	owner.mu.Lock() // A dispatched network batch owns mutable state.
	for _, action := range []string{"status", "paused", "stopped"} {
		done := make(chan map[string]interface{}, 1)
		go func(action string) {
			snapshot, err := benchmarkOwnedControl(map[string]interface{}{"runId": id}, action)
			if err != nil {
				t.Error(err)
			}
			done <- snapshot
		}(action)
		select {
		case snapshot := <-done:
			if snapshot["status"] != "running" {
				t.Fatal("in-flight result misreported as settled")
			}
			if action != "status" && snapshot["controlPending"] != action {
				t.Fatal("control request not acknowledged")
			}
		case <-time.After(time.Second):
			owner.mu.Unlock()
			t.Fatal("control blocked behind execution")
		}
	}
	if err := owner.applyPending(); err != nil {
		owner.mu.Unlock()
		t.Fatal(err)
	}
	if state["status"] != "stopped" {
		t.Fatal("stop not applied at safe boundary")
	}
	owner.mu.Unlock()
}

func TestBenchmarkStopAcknowledgesWhileRequestIsBlockedAndAccountsCommit(t *testing.T) {
	isolateBenchmarkTempDir(t)
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case entered <- struct{}{}:
		default:
		}
		<-release
		w.Header().Set("ETag", `"fixture"`)
	}))
	defer server.Close()
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	outputDir := t.TempDir()
	result, err := startBenchmark(map[string]interface{}{"profile": testProfilePayload(server.URL), "config": map[string]interface{}{"csvOutputPath": filepath.Join(outputDir, "results.csv"), "jsonOutputPath": filepath.Join(outputDir, "results.json"), "logFilePath": filepath.Join(outputDir, "benchmark.log"), "bucketName": "bucket", "testMode": "operation-count", "operationCount": 100, "concurrentThreads": 1, "workloadType": "write-only", "objectSizes": []interface{}{32}}})
	if err != nil {
		t.Fatal(err)
	}
	id := asString(result["id"])
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("benchmark did not dispatch")
	}
	ack := make(chan map[string]interface{}, 1)
	go func() {
		response, controlErr := benchmarkOwnedControl(map[string]interface{}{"runId": id}, "stopped")
		if controlErr != nil {
			t.Error(controlErr)
		}
		ack <- response
	}()
	select {
	case response := <-ack:
		if response["controlPending"] != "stopped" || response["status"] != "running" {
			t.Fatalf("untruthful acknowledgement: %v", response)
		}
	case <-time.After(time.Second):
		t.Fatal("stop blocked behind network request")
	}
	close(release)
	released = true
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		status, statusErr := benchmarkOwnedControl(map[string]interface{}{"runId": id}, "status")
		if statusErr != nil {
			t.Fatal(statusErr)
		}
		if status["status"] == "stopped" {
			if asInt(status["processedCount"]) != 1 || requests.Load() != 1 {
				t.Fatalf("committed request lost or new work dispatched: %v requests=%d", status, requests.Load())
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("stop did not settle after request finished")
}
