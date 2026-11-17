package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
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
)

func captureDownloadEvents(t *testing.T, run func() (map[string]interface{}, error)) (map[string]interface{}, error, []map[string]interface{}) {
	t.Helper()
	output, err := os.CreateTemp(t.TempDir(), "transfer-events")
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	original := os.Stdout
	os.Stdout = output
	defer func() { os.Stdout = original }()
	result, runErr := run()
	os.Stdout = original
	if _, err = output.Seek(0, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	var events []map[string]interface{}
	decoder := json.NewDecoder(output)
	for {
		var event map[string]interface{}
		if err = decoder.Decode(&event); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		if event["event"] == "transferProgress" {
			events = append(events, asMap(event["job"]))
		}
	}
	return result, runErr, events
}

func TestRangeDownloadRetriesInterruptedBodies(t *testing.T) {
	for _, provider := range []string{"s3Compatible", "azureBlob"} {
		for _, failure := range []string{"once", "always", "conflict", "etag", "range", "one-attempt"} {
			t.Run(provider+"/"+failure, func(t *testing.T) {
				const chunk = 1024 * 1024
				data := benchmarkPayload("retry", "range.bin", 2*chunk+57, true)
				var mu sync.Mutex
				requests := map[int]int{}
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Length", fmt.Sprint(len(data)))
					w.Header().Set("ETag", `"original"`)
					if provider == "s3Compatible" && r.URL.Query().Get("versionId") != "fixture-version" {
						t.Error("request lost version validator")
					}
					if r.Method == http.MethodHead {
						return
					}
					if r.Header.Get("If-Match") != `"original"` {
						t.Error("retry lost If-Match validator")
					}
					var start, end int
					if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end); err != nil {
						t.Error(err)
						w.WriteHeader(400)
						return
					}
					mu.Lock()
					requests[start]++
					attempt := requests[start]
					mu.Unlock()
					if start == chunk && (attempt == 1 || failure == "always" || failure == "one-attempt") {
						// Deliberately corrupt the failed attempt's prefix as well as
						// cutting the connection, to verify retry starts at the offset.
						conn, buffered, err := w.(http.Hijacker).Hijack()
						if err != nil {
							t.Error(err)
							return
						}
						defer conn.Close()
						fmt.Fprintf(buffered, "HTTP/1.1 206 Partial Content\r\nContent-Length: %d\r\nContent-Range: bytes %d-%d/%d\r\nETag: \"original\"\r\n\r\n", end-start+1, start, end, len(data))
						_, _ = buffered.Write(bytes.Repeat([]byte("x"), (end-start+1)/2))
						_ = buffered.Flush()
						return
					}
					w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
					w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)))
					if start == chunk {
						switch failure {
						case "conflict":
							w.Header().Del("Content-Length")
							xmlError(w, http.StatusPreconditionFailed, "ConditionNotMet")
							return
						case "etag":
							w.Header().Set("ETag", `"changed"`)
						case "range":
							w.Header().Set("Content-Range", "bytes 0-1/2")
						}
					}
					w.WriteHeader(http.StatusPartialContent)
					_, _ = w.Write(data[start : end+1])
				}))
				defer server.Close()
				payload := testProfilePayload(server.URL)
				payload["endpointType"] = provider
				payload["maxAttempts"] = 3
				if failure == "one-attempt" {
					payload["maxAttempts"] = 1
				}
				if provider == "azureBlob" {
					payload["secretKey"] = "Zml4dHVyZQ=="
				}
				destination := t.TempDir()
				target := filepath.Join(destination, "range.bin")
				if err := os.WriteFile(target, []byte("LOCAL"), 0600); err != nil {
					t.Fatal(err)
				}
				started := time.Now()
				result, err, events := captureDownloadEvents(t, func() (map[string]interface{}, error) {
					return handleRequest(request{Method: "startDownload", Params: map[string]interface{}{
						"profile": payload, "bucketName": "bucket", "keys": []interface{}{"range.bin"}, "versionId": "fixture-version",
						"destinationPath": destination, "multipartThresholdMiB": 1, "multipartChunkMiB": 1, "conflictPolicy": "replace",
					}})
				})
				if time.Since(started) > 3*time.Second {
					t.Fatal("range retries did not terminate promptly")
				}
				wantAttempts := 2
				if failure == "always" {
					wantAttempts = 3
				} else if failure == "one-attempt" {
					wantAttempts = 1
				}
				if requests[chunk] != wantAttempts {
					t.Fatalf("retry count=%v; error=%v", requests, err)
				}
				for offset, count := range requests {
					if offset != chunk && count != 1 {
						t.Fatalf("healthy range repeated: %v", requests)
					}
				}
				actual, readErr := os.ReadFile(target)
				if readErr != nil {
					t.Fatal(readErr)
				}
				if failure == "once" {
					if err != nil || !bytes.Equal(actual, data) {
						t.Fatalf("retry did not restore complete object: %v", err)
					}
					if result["bytesTransferred"] != int64(len(data)) || result["partsCompleted"] != 3 {
						t.Fatalf("failed attempt counted as progress: %v", result)
					}
				} else if err == nil || string(actual) != "LOCAL" {
					t.Fatalf("failed download published: %v", err)
				}
				for _, event := range events {
					if asFloat(event["bytesTransferred"]) > float64(len(data)) || asInt(event["partsCompleted"]) > 3 {
						t.Fatalf("retry double-counted progress: %v", event)
					}
				}
				files, readErr := os.ReadDir(destination)
				if readErr != nil || len(files) != 1 || files[0].Name() != "range.bin" {
					t.Fatalf("staged file left behind: %v, %v", files, readErr)
				}
			})
		}
	}
}

type failedRangeWriter struct{ err error }

func (w failedRangeWriter) WriteAt([]byte, int64) (int, error) { return 0, w.err }

type failingRangeBody struct {
	read  func([]byte) (int, error)
	close func()
}

func (body failingRangeBody) Read(p []byte) (int, error) { return body.read(p) }
func (body failingRangeBody) Close() error               { body.close(); return nil }

func TestRangeRetryDoesNotRetryDiskErrorsOrCancellation(t *testing.T) {
	for _, cancelRead := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelRead), func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var opens, closes atomic.Int32
			// A local error must remain terminal even if it implements net.Error.
			diskErr := errBodyStalled
			_, err := downloadRangeWithRetry(ctx, failedRangeWriter{diskErr}, 0, 3, 3, func() (io.ReadCloser, error) {
				opens.Add(1)
				return failingRangeBody{read: func(p []byte) (int, error) {
					if cancelRead {
						cancel()
						return 0, context.Canceled
					}
					return copy(p, "abc"), nil
				}, close: func() { closes.Add(1) }}, nil
			})
			wantErr := error(diskErr)
			if cancelRead {
				wantErr = context.Canceled
			}
			if !errors.Is(err, wantErr) || opens.Load() != 1 || closes.Load() != 1 {
				t.Fatalf("non-retryable failure retried: %v opens=%d closes=%d", err, opens.Load(), closes.Load())
			}
		})
	}
}

func TestRangeRetryCancellationInterruptsBackoff(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var opens int
	_, err := downloadRangeWithRetry(ctx, failedRangeWriter{io.ErrClosedPipe}, 0, 3, 5, func() (io.ReadCloser, error) {
		opens++
		return failingRangeBody{read: func([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }, close: func() { time.AfterFunc(10*time.Millisecond, cancel) }}, nil
	})
	if !errors.Is(err, context.Canceled) || opens != 1 {
		t.Fatalf("cancellation retried: %v, opens=%d", err, opens)
	}
}

func TestRangeRetryRewritesOnlyFailedRange(t *testing.T) {
	for _, shortEOF := range []bool{false, true} {
		t.Run(fmt.Sprint(shortEOF), func(t *testing.T) {
			file, err := os.CreateTemp(t.TempDir(), "range")
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			if _, err = file.WriteString("before:.......:after"); err != nil {
				t.Fatal(err)
			}
			var opens, closes int
			copied, err := downloadRangeWithRetry(context.Background(), file, 7, 7, 3, func() (io.ReadCloser, error) {
				opens++
				reader := io.Reader(strings.NewReader("correct"))
				if opens == 1 {
					reader = strings.NewReader("bad")
					if !shortEOF {
						reader = io.MultiReader(reader, failingRangeBody{read: func([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }})
					}
				}
				return failingRangeBody{read: reader.Read, close: func() { closes++ }}, nil
			})
			if err != nil || copied != 7 || opens != 2 || closes != 2 {
				t.Fatalf("range retry: copied=%d opens=%d closes=%d error=%v", copied, opens, closes, err)
			}
			actual := make([]byte, 20)
			n, err := file.ReadAt(actual, 0)
			if err != nil && !errors.Is(err, io.EOF) {
				t.Fatal(err)
			}
			if string(actual[:n]) != "before:correct:after" {
				t.Fatalf("range retry overwrote adjacent data: %q", actual[:n])
			}
		})
	}
}

func TestAzureDownloadCoalescesProgress(t *testing.T) {
	for _, ranged := range []bool{false, true} {
		t.Run(fmt.Sprint(ranged), func(t *testing.T) {
			const size = 4 * 1024 * 1024
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Length", fmt.Sprint(size))
				w.Header().Set("ETag", `"original"`)
				if r.Method == http.MethodHead {
					return
				}
				start, end := 0, size-1
				if ranged {
					if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end); err != nil {
						t.Error(err)
					}
					w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
					w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
					w.WriteHeader(http.StatusPartialContent)
				}
				for remaining := end - start + 1; remaining > 0; {
					n := min(remaining, 16*1024)
					_, _ = io.WriteString(w, strings.Repeat("a", n))
					w.(http.Flusher).Flush()
					remaining -= n
				}
			}))
			defer server.Close()
			payload := testProfilePayload(server.URL)
			payload["endpointType"] = "azureBlob"
			payload["secretKey"] = "Zml4dHVyZQ=="
			threshold := 32
			if ranged {
				threshold = 1
			}
			result, err, events := captureDownloadEvents(t, func() (map[string]interface{}, error) {
				return azureStartDownload(map[string]interface{}{
					"profile": payload, "bucketName": "bucket", "keys": []interface{}{"range.bin"}, "destinationPath": t.TempDir(),
					"multipartThresholdMiB": threshold, "multipartChunkMiB": 1, "progressIntervalMs": 2000,
				})
			})
			if err != nil {
				t.Fatal(err)
			}
			if len(events) != 2 || events[0]["status"] != "queued" || events[1]["status"] != "running" {
				t.Fatalf("progress was not coalesced: %d events", len(events))
			}
			if result["status"] != "completed" || result["bytesTransferred"] != int64(size) {
				t.Fatalf("terminal result lost: %v", result)
			}
		})
	}
}
