package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func testProfilePayload(endpoint string) map[string]interface{} {
	return map[string]interface{}{"endpointUrl": endpoint, "endpointType": "s3Compatible", "region": "us-east-1", "accessKey": "sentinel-access", "secretKey": "sentinel-secret", "sessionToken": "sentinel-token", "pathStyle": true, "maxAttempts": 1, "maxConcurrentRequests": 4}
}
func fixtureClient(t *testing.T, handler http.HandlerFunc) (profile, func()) {
	t.Helper()
	server := httptest.NewServer(handler)
	p, err := parseProfile(testProfilePayload(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	return p, server.Close
}
func xmlError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/xml")
	w.WriteHeader(status)
	fmt.Fprintf(w, "<Error><Code>%s</Code><Message>fixture</Message></Error>", code)
}

func TestBenchmarkCapabilityIsSupportedAcrossProviders(t *testing.T) {
	for _, provider := range []string{"s3Compatible", "awsS3", "azureBlob"} {
		t.Run(provider, func(t *testing.T) {
			result, err := handleRequest(request{Method: "getCapabilities", Params: map[string]interface{}{"profile": map[string]interface{}{"endpointType": provider}}})
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, item := range result["items"].([]map[string]interface{}) {
				if item["key"] == "benchmark" {
					found = true
					if item["state"] != "supported" {
						t.Fatalf("benchmark runner must be supported: %v", item)
					}
				}
				if provider == "s3Compatible" && item["key"] == "bucket.lifecycle" && item["state"] != "unknown" {
					t.Fatalf("service-dependent lifecycle support must remain unprobed: %v", item)
				}
			}
			if !found {
				t.Fatal("missing benchmark capability")
			}
		})
	}
}

func TestBenchmarkStateNeverStoresProfile(t *testing.T) {
	isolateBenchmarkTempDir(t)
	state := map[string]interface{}{"id": "bench-test", "status": "paused", "profile": testProfilePayload("http://localhost"), "config": map[string]interface{}{"bucketName": "test"}}
	if err := writeBenchmarkState(state); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(benchmarkStatePath("bench-test"))
	if err != nil {
		t.Fatal(err)
	}
	for _, sentinel := range []string{"sentinel-access", "sentinel-secret", "sentinel-token", "profile"} {
		if strings.Contains(string(data), sentinel) {
			t.Fatalf("sensitive profile persisted: %s", sentinel)
		}
	}
	public, _ := json.Marshal(benchmarkSnapshot(state))
	if strings.Contains(string(public), "sentinel") {
		t.Fatal("sensitive public response")
	}
	// Legacy profile contents are removed on read and are never reused.
	encoded, _ := json.Marshal(state)
	if err = os.WriteFile(benchmarkStatePath("bench-test"), encoded, 0600); err != nil {
		t.Fatal(err)
	}
	read, err := readBenchmarkState("bench-test")
	if err != nil {
		t.Fatal(err)
	}
	if read["profile"] != nil {
		t.Fatal("legacy credentials trusted")
	}
	data, _ = os.ReadFile(benchmarkStatePath("bench-test"))
	if strings.Contains(string(data), "sentinel") {
		t.Fatal("legacy credentials remain")
	}
}

func TestDeleteStaleRecoveryBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name, version, code    string
		compatible, finalFails bool
		wantPut, wantDeleted   bool
	}{{"never-enabled-stale", "", "InternalError", true, false, true, true}, {"final-delete-fails", "", "InternalError", true, true, true, false}, {"versioned", "Enabled", "InternalError", true, false, false, false}, {"suspended", "Suspended", "InternalError", true, false, false, false}, {"denied", "", "AccessDenied", true, false, false, false}, {"aws", "", "InternalError", false, false, false, false}} {
		t.Run(tc.name, func(t *testing.T) {
			var mu sync.Mutex
			puts := 0
			deletes := 0
			removed := false
			p, closeServer := fixtureClient(t, func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				w.Header().Set("Content-Type", "application/xml")
				switch {
				case r.URL.Query().Has("versioning"):
					fmt.Fprintf(w, "<VersioningConfiguration><Status>%s</Status></VersioningConfiguration>", tc.version)
				case r.URL.Query().Has("delete"):
					fmt.Fprintf(w, "<DeleteResult><Error><Key> key </Key><Code>%s</Code><Message>fixture</Message></Error></DeleteResult>", tc.code)
				case r.Method == "HEAD":
					if removed {
						w.WriteHeader(404)
					} else {
						w.Header().Set("ETag", "\"fixture\"")
					}
				case r.Method == "PUT":
					puts++
					body, _ := io.ReadAll(r.Body)
					if len(body) != 0 {
						t.Error("recovery PUT must be empty")
					}
					if r.Header.Get("If-Match") != "\"fixture\"" {
						t.Error("replacement lacks validator")
					}
					w.Header().Set("ETag", "\"empty\"")
				case r.Method == "DELETE":
					deletes++
					if puts > 0 && !tc.finalFails {
						removed = true
						w.WriteHeader(204)
					} else {
						xmlError(w, 500, "InternalError")
					}
				default:
					t.Errorf("unexpected %s %s", r.Method, r.URL)
				}
			})
			defer closeServer()
			client, ctx, err := buildClient(p)
			if err != nil {
				t.Fatal(err)
			}
			results := deleteBatchWithRecovery(ctx, client, "bucket", []types.ObjectIdentifier{{Key: aws.String(" key ")}}, tc.compatible && tc.version == "")
			if len(results) != 1 {
				t.Fatal(results)
			}
			if asBool(results[0]["deleted"]) != tc.wantDeleted {
				t.Fatalf("result: %#v", results)
			}
			if (puts > 0) != tc.wantPut {
				t.Fatalf("PUT count %d, expected enabled=%v", puts, tc.wantPut)
			}
			if tc.wantPut && deletes != 4 {
				t.Fatalf("expected three individual deletes followed by final delete; got %d", deletes)
			}
			if tc.finalFails && asString(results[0]["message"]) != "overwritten with an empty object; delete failed" {
				t.Fatal(results)
			}
		})
	}
}

func TestDeleteAllFailsClosedOnUnknownVersioning(t *testing.T) {
	var mutations atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			mutations.Add(1)
		}
		xmlError(w, 403, "AccessDenied")
	}))
	defer server.Close()
	result := runDeleteAll(map[string]interface{}{"profile": testProfilePayload(server.URL), "config": map[string]interface{}{"bucketName": "bucket"}})
	if asInt(result["exitCode"]) == 0 || mutations.Load() != 0 {
		t.Fatalf("unsafe result %v", result)
	}
}
func TestPartialInspectionPreservesOtherSections(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		switch {
		case r.URL.Query().Has("versioning"):
			fmt.Fprint(w, "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>")
		case r.URL.Query().Has("object-lock"):
			fmt.Fprint(w, "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Years>3</Years></DefaultRetention></Rule></ObjectLockConfiguration>")
		default:
			xmlError(w, 403, "AccessDenied")
		}
	}))
	defer server.Close()
	result, err := getBucketAdminState(map[string]interface{}{"profile": testProfilePayload(server.URL), "bucketName": "bucket"})
	if err != nil {
		t.Fatal(err)
	}
	if !asBool(result["versioningEnabled"]) || asString(result["objectLockRetentionUnit"]) != "years" || asInt(result["objectLockRetentionValue"]) != 3 || result["objectLockRetentionDays"] != nil {
		t.Fatalf("bad state %v", result)
	}
	if asString(asMap(asMap(result["sections"])["GetBucketPolicy"])["state"]) != "denied" {
		t.Fatalf("missing denied section %v", result)
	}
}
func TestAzureBlockSizingBoundaries(t *testing.T) {
	const mib = int64(1024 * 1024)
	for _, size := range []int64{0, 1, 16 * mib, 50000 * 16 * mib, 50000*16*mib + 1, 50000 * 4000 * mib} {
		block, err := azureBlockSizing(size, 16*mib)
		if err != nil {
			t.Fatal(err)
		}
		if (size+block-1)/block > 50000 || block > 4000*mib {
			t.Fatalf("size %d block %d", size, block)
		}
	}
	if _, err := azureBlockSizing(50000*4000*mib+1, 0); err == nil {
		t.Fatal("oversize accepted")
	}
}
func TestParallelPartsBoundedAndCancelled(t *testing.T) {
	var active, maxActive, completed atomic.Int32
	err := parallelParts(context.Background(), 20, 3, func(ctx context.Context, index int) error {
		current := active.Add(1)
		defer active.Add(-1)
		for {
			old := maxActive.Load()
			if current <= old || maxActive.CompareAndSwap(old, current) {
				break
			}
		}
		time.Sleep(time.Millisecond * 5)
		completed.Add(1)
		return nil
	})
	if err != nil || completed.Load() != 20 || maxActive.Load() > 3 || maxActive.Load() < 2 {
		t.Fatalf("workers: %d completed %d err %v", maxActive.Load(), completed.Load(), err)
	}
	if err = parallelParts(context.Background(), 100, 3, func(context.Context, int) error { return fmt.Errorf("fixture") }); err == nil {
		t.Fatal("worker failure lost")
	}
}
func TestAzureSASRetryAndRedaction(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("sig") != "secret-sas" {
			t.Error("missing SAS")
		}
		if r.Header.Get("Authorization") != "" {
			t.Error("SAS should not use Shared Key")
		}
		if attempts.Add(1) == 1 {
			w.WriteHeader(503)
			return
		}
		fmt.Fprint(w, "ready")
	}))
	defer server.Close()
	payload := testProfilePayload(server.URL)
	payload["endpointType"] = "azureBlob"
	payload["authMode"] = "azureSas"
	payload["azureSasToken"] = "sig=secret-sas&sp=r"
	payload["maxAttempts"] = 2
	p, err := parseProfile(payload)
	if err != nil {
		t.Fatal(err)
	}
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.do(ctx, "GET", "bucket", " key ", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	drainAndClose(resp.Body)
	if attempts.Load() != 2 {
		t.Fatal("read not retried")
	}
	if strings.Contains(redactedEndpoint(server.URL+"?sig=secret-sas"), "secret-sas") {
		t.Fatal("SAS exposed")
	}
}
func TestMultipartCopyUsesSourceIdentityAndRetainsMetadata(t *testing.T) {
	var partCount atomic.Int32
	var completed atomic.Bool
	var copiedBytes atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		switch {
		case r.Method == "HEAD":
			w.Header().Set("ETag", "\"source-etag\"")
			w.Header().Set("Content-Length", "5368709121")
			w.Header().Set("x-amz-meta-project", "one")
		case r.URL.Query().Has("tagging"):
			fmt.Fprint(w, "<Tagging><TagSet><Tag><Key>owner</Key><Value>team</Value></Tag></TagSet></Tagging>")
		case r.URL.Query().Has("uploads"):
			body, _ := io.ReadAll(r.Body)
			_ = body
			if r.Header.Get("x-amz-meta-project") != "one" || r.Header.Get("x-amz-tagging") != "owner=team" {
				t.Error("attributes lost")
			}
			fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>upload-one</UploadId></InitiateMultipartUploadResult>")
		case r.Method == "PUT" && r.URL.Query().Has("partNumber"):
			if r.Header.Get("x-amz-copy-source-if-match") != "\"source-etag\"" {
				t.Error("source condition lost")
			}
			if !strings.Contains(r.Header.Get("x-amz-copy-source"), "%20key%20") {
				t.Error("source key changed")
			}
			var start, end int64
			fmt.Sscanf(r.Header.Get("x-amz-copy-source-range"), "bytes=%d-%d", &start, &end)
			copiedBytes.Add(end - start + 1)
			partCount.Add(1)
			fmt.Fprint(w, "<CopyPartResult><ETag>part-etag</ETag></CopyPartResult>")
		case r.Method == "POST" && r.URL.Query().Has("uploadId"):
			completed.Store(true)
			fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>complete</ETag></CompleteMultipartUploadResult>")
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL)
		}
	}))
	defer server.Close()
	result, err := copyObject(map[string]interface{}{"profile": testProfilePayload(server.URL), "sourceBucketName": "source", "sourceKey": " key ", "destinationBucketName": "destination", "destinationKey": " key "})
	if err != nil {
		t.Fatal(err)
	}
	if !completed.Load() || partCount.Load() != 41 || copiedBytes.Load() != 5368709121 || asInt(result["successCount"]) != 1 {
		t.Fatalf("copy incorrect %v parts %d bytes %d", result, partCount.Load(), copiedBytes.Load())
	}
}
func TestBenchmarkRunsWithoutStatusPolls(t *testing.T) {
	isolateBenchmarkTempDir(t)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PUT" {
			t.Errorf("%s issued by write-only workload", r.Method)
		}
		requests.Add(1)
		io.Copy(io.Discard, r.Body)
		w.Header().Set("ETag", "\"fixture\"")
		w.WriteHeader(200)
	}))
	defer server.Close()
	params := map[string]interface{}{"profile": testProfilePayload(server.URL), "config": map[string]interface{}{"bucketName": "bucket", "testMode": "operation-count", "operationCount": 120, "concurrentThreads": 2, "workloadType": "write-only", "objectSizes": []interface{}{1}, "csvOutputPath": filepath.Join(t.TempDir(), "results.csv"), "jsonOutputPath": filepath.Join(t.TempDir(), "results.json"), "logFilePath": filepath.Join(t.TempDir(), "benchmark.log")}}
	result, err := startBenchmark(params)
	if err != nil {
		t.Fatal(err)
	}
	id := asString(result["id"])
	deadline := time.Now().Add(5 * time.Second)
	for requests.Load() < 120 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	status, err := getBenchmarkStatus(map[string]interface{}{"runId": id, "profile": params["profile"]})
	if err != nil {
		t.Fatal(err)
	}
	if requests.Load() < 120 || asInt(status["processedCount"]) != 120 {
		t.Fatalf("poll-dependent execution: %v requests=%d", status, requests.Load())
	}
	if status["status"] != "completed" || asInt(asMap(status["resultSummary"])["totalOperations"]) != 120 {
		t.Fatalf("terminal snapshot has stale results: %v", status)
	}
	assertCheckpointCounts(t, status, 120)
	data, _ := json.Marshal(status)
	if strings.Contains(string(data), "sentinel") {
		t.Fatal("benchmark credentials leaked")
	}
}

func TestBenchmarkClockUsesMonotonicElapsedAndStaysPrivate(t *testing.T) {
	isolateBenchmarkTempDir(t)
	state := map[string]interface{}{"id": "bench-clock", "activeElapsedSeconds": 0.0, "lastUpdatedAt": "2000-01-01T00:00:00Z", "_benchmarkClock": time.Now().Add(-500 * time.Millisecond)}
	for i := 0; i < 100; i++ {
		advanceBenchmarkClock(state)
	}
	elapsed := asFloat(state["activeElapsedSeconds"])
	if elapsed < 0.45 || elapsed > 1 {
		t.Fatalf("elapsed %.3f inflated by wall time or poll count", elapsed)
	}
	if err := writeBenchmarkState(state); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(benchmarkStatePath("bench-clock"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "_benchmarkClock") {
		t.Fatal("process clock serialized")
	}
	if _, ok := benchmarkSnapshot(state)["_benchmarkClock"]; ok {
		t.Fatal("process clock exposed")
	}
}

func TestBenchmarkWorkloadParity(t *testing.T) {
	for _, mode := range []string{"write-only", "read-only", "custom"} {
		t.Run(mode, func(t *testing.T) {
			config := map[string]interface{}{"workloadType": mode, "writePercent": 20, "readPercent": 70, "deletePercent": 10}
			counts := map[string]int{}
			for index := 0; index < 200; index++ {
				counts[benchmarkOperationForIndex(config, index)]++
			}
			expected := map[string]map[string]int{"write-only": {"PUT": 200}, "read-only": {"GET": 200}, "custom": {"PUT": 40, "GET": 140, "DELETE": 20}}[mode]
			if fmt.Sprint(counts) != fmt.Sprint(expected) {
				t.Fatalf("%s selected %v; expected %v", mode, counts, expected)
			}
		})
	}
	config := map[string]interface{}{"workloadType": "custom", "writePercent": 2, "readPercent": 1, "deletePercent": 0}
	for index, expected := range []string{"PUT", "PUT", "GET", "PUT", "PUT", "GET"} {
		if actual := benchmarkOperationForIndex(config, index); actual != expected {
			t.Fatalf("weighted custom slot %d = %s", index, actual)
		}
	}
}

func TestBenchmarkPureWritesExecuteEveryOperation(t *testing.T) {
	config := map[string]interface{}{"workloadType": "write-only", "testMode": "operation-count", "operationCount": 120, "objectSizes": []interface{}{16}, "objectCount": 120, "randomData": false}
	state := map[string]interface{}{"id": "pure-write", "config": config, "activeObjects": []map[string]interface{}{}, "history": []map[string]interface{}{}, "benchmarkPrefix": "test/"}
	var puts atomic.Int32
	executor := &benchmarkExecutor{put: func(key string, payload []byte) error {
		if len(payload) != 16 {
			return fmt.Errorf("incorrect PUT length")
		}
		puts.Add(1)
		return nil
	}, get: func(string) ([]byte, error) { return nil, fmt.Errorf("read issued in write-only workload") }, deleteOne: func(string) error { return fmt.Errorf("delete issued in write-only workload") }}
	if err := runBenchmarkBatch(state, executor, config, 120, 4, 120); err != nil {
		t.Fatal(err)
	}
	if puts.Load() != 120 || asInt(state["processedCount"]) != 120 {
		t.Fatalf("only %d PUTs completed", puts.Load())
	}
	summary := benchmarkSummaryFromState(state)
	if asInt(asMap(summary["operationsByType"])["PUT"]) != 120 {
		t.Fatalf("wrong counters: %v", summary)
	}
}
