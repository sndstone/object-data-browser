package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

var encryptionTestKey = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xa7}, 32))
var encryptionSourceKey = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xb8}, 32))

func encryptionOption(mode, key string) interface{} {
	if mode == "absent" {
		return nil
	}
	result := map[string]interface{}{"mode": mode}
	switch mode {
	case "sse-c", "azure-cpk":
		result["customerKey"] = key
	case "sse-kms":
		result["kmsKeyId"] = "arn:fixture:key"
		result["kmsEncryptionContext"] = map[string]interface{}{"project": "fixture"}
		result["bucketKeyEnabled"] = false
	case "dsse-kms":
		result["kmsKeyId"] = "arn:fixture:key"
		result["kmsEncryptionContext"] = map[string]interface{}{"project": "fixture"}
	case "azure-scope":
		result["encryptionScope"] = "fixture-scope"
	}
	return result
}
func TestObjectEncryptionValidation(t *testing.T) {
	s3Profile := profile{EndpointURL: "https://example.invalid"}
	azureProfile := profile{EndpointURL: "https://example.invalid", EndpointType: "azureBlob"}
	for _, tc := range []struct {
		name  string
		value interface{}
	}{
		{"string", "sse-c"}, {"missing-mode", map[string]interface{}{}}, {"unknown", map[string]interface{}{"mode": "oops"}},
		{"extra-default", map[string]interface{}{"mode": "bucketDefault", "customerKey": encryptionTestKey}},
		{"extra-s3", map[string]interface{}{"mode": "sse-s3", "kmsKeyId": "key"}},
		{"dsse-bucket-key", map[string]interface{}{"mode": "dsse-kms", "bucketKeyEnabled": true}},
		{"bad-flag", map[string]interface{}{"mode": "sse-kms", "bucketKeyEnabled": "true"}},
		{"bad-context", map[string]interface{}{"mode": "sse-kms", "kmsEncryptionContext": map[string]interface{}{"x": 3}}},
		{"context-string", map[string]interface{}{"mode": "sse-kms", "kmsEncryptionContext": "secret"}},
		{"bad-kms-id", map[string]interface{}{"mode": "sse-kms", "kmsKeyId": false}},
		{"newline-kms-id", map[string]interface{}{"mode": "sse-kms", "kmsKeyId": "key\ninjection"}},
		{"missing-key", map[string]interface{}{"mode": "sse-c"}},
		{"key-type", map[string]interface{}{"mode": "sse-c", "customerKey": 32}},
		{"key-base64", map[string]interface{}{"mode": "sse-c", "customerKey": "%" + encryptionTestKey}},
		{"key-short", map[string]interface{}{"mode": "sse-c", "customerKey": base64.StdEncoding.EncodeToString(make([]byte, 31))}},
		{"key-long", map[string]interface{}{"mode": "sse-c", "customerKey": base64.StdEncoding.EncodeToString(make([]byte, 33))}},
		{"azure-on-s3", encryptionOption("azure-cpk", encryptionTestKey)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parseObjectEncryption(tc.value, s3Profile)
			if err == nil || mapError(err)["code"] != "invalid_config" || strings.Contains(err.Error(), encryptionTestKey) {
				t.Fatalf("unsafe validation result: %v", err)
			}
		})
	}
	for _, mode := range []string{"absent", "bucketDefault", "sse-s3", "sse-kms", "dsse-kms", "sse-c", "azure-scope", "azure-cpk"} {
		p := s3Profile
		if strings.HasPrefix(mode, "azure-") {
			p = azureProfile
		}
		if _, err := parseObjectEncryption(encryptionOption(mode, encryptionTestKey), p); err != nil {
			t.Fatalf("%s: %v", mode, err)
		}
		if mode != "absent" && mode != "bucketDefault" {
			other := azureProfile
			if isAzureProfile(p) {
				other = s3Profile
			}
			if _, err := parseObjectEncryption(encryptionOption(mode, encryptionTestKey), other); err == nil {
				t.Fatal("cross-provider mode accepted")
			}
		}
	}
	for _, mode := range []string{"sse-c", "azure-cpk"} {
		for _, endpoint := range []string{"http://localhost:99", "http://127.0.0.2", "http://[::1]", "https://remote.invalid", "http://remote.invalid", "http://localhost.evil.invalid", "ftp://localhost", "//localhost", "https://"} {
			p := profile{EndpointURL: endpoint}
			if mode == "azure-cpk" {
				p.EndpointType = "azureBlob"
			}
			_, err := parseObjectEncryption(encryptionOption(mode, encryptionTestKey), p)
			want := strings.Contains(endpoint, "remote.invalid") && !strings.HasPrefix(endpoint, "https:") || strings.Contains(endpoint, "evil") || strings.HasPrefix(endpoint, "ftp:") || strings.HasPrefix(endpoint, "//") || endpoint == "https://"
			if (err != nil) != want {
				t.Fatalf("%s %s: %v", mode, endpoint, err)
			}
		}
	}
	for _, raw := range []interface{}{encryptionOption("sse-s3", ""), encryptionOption("sse-kms", "")} {
		if _, err := parseRequestEncryption(map[string]interface{}{"sourceEncryption": raw}, s3Profile, true); err == nil {
			t.Fatal("non-customer source mode accepted")
		}
	}
	if _, err := parseObjectEncryption(map[string]interface{}{"mode": "azure-scope"}, azureProfile); err == nil {
		t.Fatal("missing scope accepted")
	}
	if _, err := parseRequestEncryption(map[string]interface{}{"sourceEncryption": encryptionOption("sse-c", encryptionTestKey)}, s3Profile, false); err == nil {
		t.Fatal("source option accepted outside copy")
	}
}

// Run the existing HTTP fixture pattern entirely in memory: localhost binds are
// prohibited in the worker sandbox. SDK serialization, signing and logging run.
type encryptionFixtureTransport struct{ handler http.HandlerFunc }

func (f encryptionFixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Body == nil {
		r.Body = http.NoBody
	}
	recorder := httptest.NewRecorder()
	f.handler(recorder, r)
	resp := recorder.Result()
	resp.Request = r
	if resp.ContentLength < 0 {
		resp.ContentLength = int64(recorder.Body.Len())
	}
	if r.Method == http.MethodHead {
		resp.Body = http.NoBody
	}
	return resp, nil
}
func encryptionFixture(t *testing.T, azure bool, handler http.HandlerFunc) map[string]interface{} {
	t.Helper()
	payload := testProfilePayload("http://localhost/" + strings.ReplaceAll(t.Name(), "/", "-"))
	payload["maxAttempts"] = 3
	payload["diagnostics"] = map[string]interface{}{"enableApiLogging": true, "enableDebugLogging": true}
	if azure {
		payload["endpointType"] = "azureBlob"
		payload["secretKey"] = "Zml4dHVyZQ=="
	}
	p, err := parseProfile(payload)
	if err != nil {
		t.Fatal(err)
	}
	transport := loggingRoundTripper{base: encryptionFixtureTransport{handler: handler}, diagnostics: p.Diagnostics}
	if azure {
		client, _, err := buildAzureClient(p)
		if err != nil {
			t.Fatal(err)
		}
		original := client.httpClient
		client.httpClient = &http.Client{Transport: transport}
		t.Cleanup(func() { client.httpClient.CloseIdleConnections(); client.httpClient = original })
	} else {
		client, _, err := buildClient(p)
		if err != nil {
			t.Fatal(err)
		}
		options := client.Options()
		options.HTTPClient = &http.Client{Transport: transport}
		s3ClientCache.Lock()
		s3ClientCache.clients[p] = s3.New(options)
		s3ClientCache.Unlock()
		t.Cleanup(func() { s3ClientCache.Lock(); s3ClientCache.clients[p] = client; s3ClientCache.Unlock() })
	}
	return payload
}
func expectedEncryptionHeaders(mode, key string, source bool) http.Header {
	h := http.Header{}
	switch mode {
	case "sse-s3":
		h.Set("x-amz-server-side-encryption", "AES256")
	case "sse-kms", "dsse-kms":
		algo := "aws:kms"
		if mode == "dsse-kms" {
			algo += ":dsse"
		}
		h.Set("x-amz-server-side-encryption", algo)
		h.Set("x-amz-server-side-encryption-aws-kms-key-id", "arn:fixture:key")
		h.Set("x-amz-server-side-encryption-context", base64.StdEncoding.EncodeToString([]byte(`{"project":"fixture"}`)))
		if mode == "sse-kms" {
			h.Set("x-amz-server-side-encryption-bucket-key-enabled", "false")
		}
	case "sse-c":
		prefix := "x-amz-"
		if source {
			prefix += "copy-source-"
		}
		prefix += "server-side-encryption-customer-"
		decoded, _ := base64.StdEncoding.DecodeString(key)
		hash := md5.Sum(decoded)
		h.Set(prefix+"algorithm", "AES256")
		h.Set(prefix+"key", key)
		h.Set(prefix+"key-MD5", base64.StdEncoding.EncodeToString(hash[:]))
	case "azure-cpk":
		decoded, _ := base64.StdEncoding.DecodeString(key)
		hash := sha256.Sum256(decoded)
		h.Set("x-ms-encryption-key", key)
		h.Set("x-ms-encryption-key-sha256", base64.StdEncoding.EncodeToString(hash[:]))
		h.Set("x-ms-encryption-algorithm", "AES256")
	case "azure-scope":
		h.Set("x-ms-encryption-scope", "fixture-scope")
	}
	return h
}
func assertEncryptionHeaders(t *testing.T, r *http.Request, want http.Header) {
	t.Helper()
	got := http.Header{}
	for k, v := range r.Header {
		lower := strings.ToLower(k)
		if strings.Contains(lower, "server-side-encryption") || strings.HasPrefix(lower, "x-ms-encryption-") {
			got[k] = v
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("%s %s encryption headers differ (values withheld)", r.Method, r.URL.Path)
	}
	// All encryption headers must be signed, rather than appended after signing.
	if strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-") {
		for name := range want {
			if !strings.Contains(r.Header.Get("Authorization"), strings.ToLower(name)) {
				t.Errorf("unsigned encryption header %s", name)
			}
		}
	}
}
func captureEncryptionOutput(t *testing.T, run func()) {
	t.Helper()
	output, err := os.CreateTemp(t.TempDir(), "output")
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = output, output
	defer func() { os.Stdout, os.Stderr = oldOut, oldErr }()
	run()
	os.Stdout, os.Stderr = oldOut, oldErr
	data, err := os.ReadFile(output.Name())
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{encryptionTestKey, encryptionSourceKey} {
		if bytes.Contains(data, []byte(key)) {
			t.Fatal("customer key leaked into logs or output")
		}
	}
}
func TestObjectEncryptionWriteHeaders(t *testing.T) {
	for _, mode := range []string{"absent", "bucketDefault", "sse-s3", "sse-kms", "dsse-kms", "sse-c", "azure-scope", "azure-cpk", "azure-absent", "azure-bucketDefault"} {
		t.Run(mode, func(t *testing.T) {
			azure := strings.HasPrefix(mode, "azure-")
			if mode == "azure-absent" {
				mode = "absent"
			}
			if mode == "azure-bucketDefault" {
				mode = "bucketDefault"
			}
			var mu sync.Mutex
			puts, parts, creates, commits := 0, 0, 0, 0
			payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
				want := expectedEncryptionHeaders(mode, encryptionTestKey, false)
				query := r.URL.Query()
				if !azure && (query.Has("partNumber") || query.Has("uploadId")) && mode != "sse-c" {
					want = http.Header{}
				}
				assertEncryptionHeaders(t, r, want)
				_, _ = io.Copy(io.Discard, r.Body)
				mu.Lock()
				defer mu.Unlock()
				w.Header().Set("Content-Type", "application/xml")
				w.Header().Set("ETag", `"fixture"`)
				switch {
				case query.Has("uploads"):
					creates++
					fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>")
				case query.Has("partNumber") || query.Get("comp") == "block":
					parts++
				case query.Has("uploadId"):
					commits++
					fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>fixture</ETag></CompleteMultipartUploadResult>")
				case query.Get("comp") == "blocklist":
					commits++
				default:
					puts++
				}
			})
			params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "encryption": encryptionOption(mode, encryptionTestKey), "key": "folder"}
			if mode == "absent" {
				delete(params, "encryption")
			}
			captureEncryptionOutput(t, func() {
				result, err := handleRequest(request{Method: "createFolder", Params: params})
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
				params["config"] = map[string]interface{}{"bucketName": "bucket", "objectCount": 2, "objectSizeBytes": 32}
				result, err = handleRequest(request{Method: "runPutTestData", Params: params})
				if azure && (mode == "absent" || mode == "bucketDefault") {
					if err == nil || mapError(err)["code"] != "unsupported_feature" {
						t.Fatalf("Azure default tool behavior changed: %v", err)
					}
				} else if err != nil || asInt(result["exitCode"]) != 0 {
					t.Fatalf("testdata failed: %v %v", result, err)
				}
				writeJSON(result)
				path := filepath.Join(t.TempDir(), "upload.bin")
				if err = os.WriteFile(path, []byte("contents"), 0600); err != nil {
					t.Fatal(err)
				}
				params["filePaths"] = []interface{}{path}
				params["multipartThresholdMiB"] = 1
				params["multipartChunkMiB"] = 5
				result, err = handleRequest(request{Method: "startUpload", Params: params})
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
				file, err := os.OpenFile(path, os.O_WRONLY, 0600)
				if err != nil {
					t.Fatal(err)
				}
				size := int64(6 * 1024 * 1024)
				if azure {
					size = azureSingleShotMaxBytes
				}
				err = file.Truncate(size)
				file.Close()
				if err != nil {
					t.Fatal(err)
				}
				result, err = handleRequest(request{Method: "startUpload", Params: params})
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
			})
			expectedPuts := 4
			if azure && (mode == "absent" || mode == "bucketDefault") {
				expectedPuts = 2
			}
			if puts != expectedPuts || commits != 1 || parts < 2 || (!azure && creates != 1) {
				t.Fatalf("requests missing: puts %d parts %d creates %d commits %d", puts, parts, creates, commits)
			}
		})
	}
}

func TestObjectEncryptionReadHeadersAndRetries(t *testing.T) {
	for _, mode := range []string{"absent", "bucketDefault", "sse-s3", "sse-kms", "dsse-kms", "sse-c", "azure-scope", "azure-cpk", "azure-absent", "azure-bucketDefault"} {
		t.Run(mode, func(t *testing.T) {
			azure := strings.HasPrefix(mode, "azure-")
			if mode == "azure-absent" {
				mode = "absent"
			}
			if mode == "azure-bucketDefault" {
				mode = "bucketDefault"
			}
			data := bytes.Repeat([]byte("d"), 2*1024*1024+3)
			var mu sync.Mutex
			gets := map[int]int{}
			heads := 0
			payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
				want := http.Header{}
				if mode == "sse-c" || mode == "azure-cpk" {
					want = expectedEncryptionHeaders(mode, encryptionTestKey, false)
				}
				if r.URL.Query().Has("tagging") {
					assertEncryptionHeaders(t, r, http.Header{})
					w.Header().Set("Content-Type", "application/xml")
					fmt.Fprint(w, "<Tagging><TagSet/></Tagging>")
					return
				}
				assertEncryptionHeaders(t, r, want)
				w.Header().Set("ETag", `"original"`)
				w.Header().Set("Content-Type", "application/octet-stream")
				w.Header().Set("Content-Length", fmt.Sprint(len(data)))
				for k, v := range expectedEncryptionHeaders(mode, encryptionTestKey, false) {
					if !encryptionSecretField(k) && !strings.HasSuffix(strings.ToLower(k), "context") {
						w.Header()[k] = v
					}
				}
				if azure && mode != "absent" && mode != "bucketDefault" {
					w.Header().Set("x-ms-server-encrypted", "true")
				}
				if r.Method == "HEAD" {
					mu.Lock()
					heads++
					mu.Unlock()
					return
				}
				start, end := 0, len(data)-1
				if r.Header.Get("Range") != "" {
					if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end); err != nil {
						t.Error(err)
					}
				}
				mu.Lock()
				gets[start]++
				attempt := gets[start]
				mu.Unlock()
				w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
				w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)))
				w.WriteHeader(206)
				if start == 1024*1024 && attempt == 1 {
					w.Write(data[start : start+5])
					return
				}
				w.Write(data[start : end+1])
			})
			destination := t.TempDir()
			params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "keys": []interface{}{"object.bin"}, "key": "object.bin", "destinationPath": destination, "multipartThresholdMiB": 1, "multipartChunkMiB": 1, "encryption": encryptionOption(mode, encryptionTestKey)}
			captureEncryptionOutput(t, func() {
				result, err := handleRequest(request{Method: "startDownload", Params: params})
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
				result, err = handleRequest(request{Method: "getObjectDetails", Params: params})
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
				reported := asMap(result["encryption"])
				if mode == "absent" || mode == "bucketDefault" {
					if len(reported) != 0 {
						t.Fatal("unexpected encryption report")
					}
				} else if reported["mode"] != mode {
					t.Fatalf("reported mode: %v", reported)
				}
			})
			actual, err := os.ReadFile(filepath.Join(destination, "object.bin"))
			if err != nil || !bytes.Equal(actual, data) {
				t.Fatal("download contents differ")
			}
			if heads != 2 || len(gets) != 3 || gets[1024*1024] != 2 {
				t.Fatalf("missing HEAD/range/retry requests: heads=%d gets=%v", heads, gets)
			}
		})
	}
}

func TestObjectEncryptionCopyAndMoveHeaders(t *testing.T) {
	for _, mode := range []string{"absent", "bucketDefault", "sse-s3", "sse-kms", "dsse-kms", "sse-c", "source-only"} {
		for _, multipart := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/multipart-%v", mode, multipart), func(t *testing.T) {
				var mu sync.Mutex
				heads, parts, copies, deletes := 0, 0, 0, 0
				sourceMode := "absent"
				if mode == "source-only" {
					mode = "absent"
					sourceMode = "sse-c"
				}
				if mode != "absent" && mode != "bucketDefault" {
					sourceMode = "sse-c"
				}
				payload := encryptionFixture(t, false, func(w http.ResponseWriter, r *http.Request) {
					mu.Lock()
					defer mu.Unlock()
					q := r.URL.Query()
					want := http.Header{}
					switch {
					case r.Method == "HEAD":
						heads++
						want = expectedEncryptionHeaders(sourceMode, encryptionSourceKey, false)
						w.Header().Set("ETag", `"original"`)
						size := int64(10)
						if multipart {
							size = 5*1024*1024*1024 + 1
						}
						w.Header().Set("Content-Length", fmt.Sprint(size))
					case q.Has("tagging"):
						fmt.Fprint(w, "<Tagging><TagSet/></Tagging>")
					case q.Has("uploads"):
						want = expectedEncryptionHeaders(mode, encryptionTestKey, false)
						fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>")
					case q.Has("partNumber"):
						parts++
						if mode == "sse-c" {
							want = expectedEncryptionHeaders(mode, encryptionTestKey, false)
						}
						setEncryptionHeaders(want, expectedEncryptionHeaders(sourceMode, encryptionSourceKey, true))
						fmt.Fprint(w, "<CopyPartResult><ETag>part</ETag></CopyPartResult>")
					case r.Method == "POST":
						if mode == "sse-c" {
							want = expectedEncryptionHeaders(mode, encryptionTestKey, false)
						}
						fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>done</ETag></CompleteMultipartUploadResult>")
					case r.Method == "DELETE":
						deletes++
					default:
						copies++
						want = expectedEncryptionHeaders(mode, encryptionTestKey, false)
						setEncryptionHeaders(want, expectedEncryptionHeaders(sourceMode, encryptionSourceKey, true))
						fmt.Fprint(w, "<CopyObjectResult><ETag>done</ETag></CopyObjectResult>")
					}
					assertEncryptionHeaders(t, r, want)
					_, _ = io.Copy(io.Discard, r.Body)
				})
				params := map[string]interface{}{"profile": payload, "sourceBucketName": "bucket", "sourceKey": "source", "destinationBucketName": "bucket", "destinationKey": "dest", "encryption": encryptionOption(mode, encryptionTestKey), "sourceEncryption": encryptionOption(sourceMode, encryptionSourceKey)}
				captureEncryptionOutput(t, func() {
					result, err := handleRequest(request{Method: "moveObject", Params: params})
					if err != nil {
						t.Fatal(err)
					}
					writeJSON(result)
				})
				if heads != 1 || deletes != 1 || (multipart && parts != 41) || (!multipart && copies != 1) {
					t.Fatalf("copy path missing: heads %d parts %d copies %d deletes %d", heads, parts, copies, deletes)
				}
			})
		}
	}
}
func TestAzureEncryptionCopy(t *testing.T) {
	for _, mode := range []string{"absent", "bucketDefault", "azure-scope", "azure-cpk"} {
		t.Run(mode, func(t *testing.T) {
			puts, heads := 0, 0
			payload := encryptionFixture(t, true, func(w http.ResponseWriter, r *http.Request) {
				want := expectedEncryptionHeaders(mode, encryptionTestKey, false)
				if r.Method == "HEAD" {
					heads++
					w.Header().Set("ETag", `"source"`)
					if heads == 1 {
						want = http.Header{}
					} else if mode != "azure-cpk" {
						want = http.Header{}
					}
				} else {
					puts++
				}
				assertEncryptionHeaders(t, r, want)
				w.Header().Set("x-ms-copy-id", "fixture")
				status := "success"
				if r.Method == "PUT" {
					status = "pending"
				}
				w.Header().Set("x-ms-copy-status", status)
			})
			params := map[string]interface{}{"profile": payload, "sourceBucketName": "bucket", "sourceKey": "source", "destinationBucketName": "bucket", "destinationKey": "dest", "encryption": encryptionOption(mode, encryptionTestKey)}
			captureEncryptionOutput(t, func() {
				result, err := azureCopyObject(params)
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
			})
			if puts != 1 || heads != 2 {
				t.Fatal("copy request missing")
			}
			params["sourceEncryption"] = encryptionOption("azure-cpk", encryptionSourceKey)
			_, err := azureCopyObject(params)
			if err == nil || mapError(err)["code"] != "unsupported_feature" || puts != 1 || heads != 2 {
				t.Fatal("CPK source must be rejected before provider requests")
			}
		})
	}
}

func TestObjectEncryptionPresignAndCapabilities(t *testing.T) {
	for _, provider := range []string{"s3Compatible", "azureBlob"} {
		payload := testProfilePayload("http://localhost")
		payload["endpointType"] = provider
		if provider == "azureBlob" {
			payload["secretKey"] = "Zml4dHVyZQ=="
		}
		params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "key": "key"}
		result, err := handleRequest(request{Method: "getCapabilities", Params: params})
		if err != nil {
			t.Fatal(err)
		}
		count := 0
		for _, item := range result["items"].([]map[string]interface{}) {
			if strings.HasPrefix(asString(item["key"]), "object.encryption.") {
				count++
				if item["state"] != "supported" {
					t.Fatal(item)
				}
			}
		}
		if count != 6 {
			t.Fatalf("capabilities=%d", count)
		}
		mode := "sse-c"
		if provider == "azureBlob" {
			mode = "azure-cpk"
		}
		params["encryption"] = encryptionOption(mode, encryptionTestKey)
		_, err = handleRequest(request{Method: "generatePresignedUrl", Params: params})
		if err == nil || mapError(err)["code"] != "unsupported_feature" {
			t.Fatalf("presign: %v", err)
		}
		params["encryption"] = map[string]interface{}{"mode": mode, "customerKey": "bad"}
		_, err = handleRequest(request{Method: "generatePresignedUrl", Params: params})
		if err == nil || mapError(err)["code"] != "invalid_config" {
			t.Fatalf("presign validation: %v", err)
		}
	}
}
func TestObjectEncryptionNormalisation(t *testing.T) {
	for _, tc := range []struct {
		head s3.HeadObjectOutput
		want map[string]interface{}
	}{
		{s3.HeadObjectOutput{}, nil},
		{s3.HeadObjectOutput{ServerSideEncryption: types.ServerSideEncryption("provider-specific")}, map[string]interface{}{"mode": "provider"}},
		{s3.HeadObjectOutput{ServerSideEncryption: types.ServerSideEncryptionAes256}, map[string]interface{}{"mode": "sse-s3"}},
		{s3.HeadObjectOutput{ServerSideEncryption: types.ServerSideEncryptionAwsKms, SSEKMSKeyId: aws.String("arn:key"), BucketKeyEnabled: aws.Bool(false)}, map[string]interface{}{"mode": "sse-kms", "kmsKeyId": "arn:key", "bucketKeyEnabled": false}},
		{s3.HeadObjectOutput{ServerSideEncryption: types.ServerSideEncryption("aws:kms:dsse")}, map[string]interface{}{"mode": "dsse-kms"}},
		{s3.HeadObjectOutput{SSECustomerAlgorithm: aws.String("AES256"), SSECustomerKeyMD5: aws.String("fingerprint")}, map[string]interface{}{"mode": "sse-c", "customerKeyMd5": "fingerprint"}},
	} {
		if got := s3ObjectEncryption(&tc.head); !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("%v != %v", got, tc.want)
		}
	}
	for _, tc := range []struct {
		headers map[string]string
		want    map[string]interface{}
	}{
		{nil, nil}, {map[string]string{"x-ms-server-encrypted": "true"}, map[string]interface{}{"mode": "provider", "serverEncrypted": true}},
		{map[string]string{"x-ms-encryption-scope": "scope", "x-ms-server-encrypted": "false"}, map[string]interface{}{"mode": "azure-scope", "encryptionScope": "scope", "serverEncrypted": false}},
		{map[string]string{"x-ms-encryption-key-sha256": "fingerprint", "x-ms-server-encrypted": "true"}, map[string]interface{}{"mode": "azure-cpk", "customerKeySha256": "fingerprint", "serverEncrypted": true}},
	} {
		h := http.Header{}
		for k, v := range tc.headers {
			h.Set(k, v)
		}
		if got := azureObjectEncryption(h); !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("%v != %v", got, tc.want)
		}
	}
}

func TestObjectEncryptionSecretHygiene(t *testing.T) {
	headers := http.Header{}
	for _, name := range []string{"x-amz-server-side-encryption-customer-key", "x-amz-copy-source-server-side-encryption-customer-key", "x-ms-encryption-key", "customerKey"} {
		headers.Set(name, encryptionTestKey)
	}
	data, _ := json.Marshal(sanitizeHeaders(headers))
	if bytes.Contains(data, []byte(encryptionTestKey)) {
		t.Fatal("header secret leaked")
	}
	body := `{"nested":[{"customerKey":"` + encryptionTestKey + `"}]}`
	if strings.Contains(summarizeHTTPBody("application/json", int64(len(body)), []byte(body)), encryptionTestKey) {
		t.Fatal("body secret leaked")
	}
	isolateBenchmarkTempDir(t)
	state := map[string]interface{}{"id": "encryption-secret", "status": "paused", "customerKey": encryptionTestKey, "config": map[string]interface{}{"options": []interface{}{map[string]interface{}{"customerKey": encryptionTestKey}}}}
	if err := writeBenchmarkState(state); err != nil {
		t.Fatal(err)
	}
	disk, err := os.ReadFile(benchmarkStatePath("encryption-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(disk, []byte(encryptionTestKey)) {
		t.Fatal("key persisted to checkpoint")
	}
	captureEncryptionOutput(t, func() {
		emitTransferEvent(map[string]interface{}{"customerKey": encryptionTestKey})
		writeJSON(response{OK: true, Result: map[string]interface{}{"options": []map[string]string{{"customerKey": encryptionTestKey}}}})
	})
	precision, _ := json.Marshal(redactEncryptionFields(&response{OK: true, Result: map[string]interface{}{"bytesTransferred": int64(9223372036854775807), "customerKey": encryptionTestKey}}))
	if !bytes.Contains(precision, []byte("9223372036854775807")) || bytes.Contains(precision, []byte(encryptionTestKey)) {
		t.Fatal("redaction changed numeric precision or leaked a key")
	}

}
func TestObjectEncryptionProviderErrors(t *testing.T) {
	for _, tc := range []struct {
		name, message, mode, method, hint string
		status                            int
	}{
		{"missing-key", "", "absent", "HEAD", "sse_c_key_required", 400},
		{"kms-denied", "KMS.AccessDeniedException: kms:Decrypt access denied", "sse-kms", "PUT", "kms_access_denied", 403},
		{"kms-disabled", "KMS.DisabledException", "sse-kms", "PUT", "kms_key_unavailable", 400},
		{"blocked", "SSE-C writes are blocked by bucket policy", "sse-c", "PUT", "sse_c_blocked", 403},
		{"generic-denied", "Access denied", "sse-c", "PUT", "", 403},
		{"mismatch", "The customer key does not match", "sse-c", "HEAD", "sse_c_key_mismatch", 400},
		{"policy", "Encryption required by policy", "sse-s3", "PUT", "encryption_required_by_policy", 403},
		{"unsupported", "Encryption is not supported", "sse-s3", "PUT", "unsupported_by_endpoint", 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			count := 0
			payload := encryptionFixture(t, false, func(w http.ResponseWriter, r *http.Request) {
				count++
				w.Header().Set("Content-Type", "application/xml")
				w.WriteHeader(tc.status)
				message := tc.message
				if tc.mode == "sse-c" {
					message += " " + encryptionTestKey
				}
				fmt.Fprintf(w, "<Error><Code>AccessDenied</Code><Message>%s</Message></Error>", message)
			})
			params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "key": "key", "encryption": encryptionOption(tc.mode, encryptionTestKey)}
			captureEncryptionOutput(t, func() {
				p, _ := parseProfile(payload)
				client, ctx, err := buildClient(p)
				if err != nil {
					t.Fatal(err)
				}
				client, err = encryptedS3Client(params, p, client, false)
				if err != nil {
					t.Fatal(err)
				}
				if tc.method == "HEAD" {
					_, err = client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String("bucket"), Key: aws.String("key")})
				} else {
					_, err = client.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String("bucket"), Key: aws.String("key"), Body: strings.NewReader("")})
				}
				if err == nil {
					t.Fatal("denial accepted")
				}
				mapped := mapError(err)
				writeJSON(mapped)
				fmt.Fprintln(os.Stderr, err.Error())
				hint := asString(asMap(mapped["details"])["encryptionHint"])
				// HEAD errors contain no XML message in the SDK. Its status still permits
				// the missing-key hint; mismatch is tested below with the provider text.
				if tc.name == "mismatch" {
					if hint != "" {
						t.Fatalf("ambiguous HEAD hint: %s", hint)
					}
				} else if hint != tc.hint {
					t.Fatalf("hint=%s want=%s", hint, tc.hint)
				}
				if tc.method != "HEAD" && mapped["code"] != "auth_failed" {
					t.Fatalf("error code changed: %v", mapped)
				}
			})
			if count != 1 {
				t.Fatalf("denied request retried %d times", count)
			}
		})
	}
	h := expectedEncryptionHeaders("sse-c", encryptionTestKey, false)
	if hint := encryptionHint("The customer key does not match", "GET", 400, h); hint != "sse_c_key_mismatch" {
		t.Fatal(hint)
	}
	for _, azure := range []bool{false, true} {
		t.Run(fmt.Sprintf("echo-secret/azure-%v", azure), func(t *testing.T) {
			mode := "sse-c"
			if azure {
				mode = "azure-cpk"
			}
			payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/xml")
				w.Header().Set("x-ms-encryption-key", encryptionTestKey)
				w.WriteHeader(403)
				fmt.Fprintf(w, "<Error><Code>AccessDenied</Code><Message>Denied key %s</Message></Error>", encryptionTestKey)
			})
			captureEncryptionOutput(t, func() {
				_, err := handleRequest(request{Method: "createFolder", Params: map[string]interface{}{"profile": payload, "bucketName": "bucket", "key": "folder", "encryption": encryptionOption(mode, encryptionTestKey)}})
				if err == nil {
					t.Fatal("denial accepted")
				}
				writeJSON(mapError(err))
				fmt.Fprintln(os.Stderr, err.Error())
			})
		})
	}
}
func TestBucketEncryptionRoundTripPreservesEveryRuleField(t *testing.T) {
	const configuration = `<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>arn:fixture:key</KMSMasterKeyID></ApplyServerSideEncryptionByDefault><BucketKeyEnabled>true</BucketKeyEnabled><BlockedEncryptionTypes><EncryptionType>SSE-C</EncryptionType></BlockedEncryptionTypes></Rule><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault><BucketKeyEnabled>false</BucketKeyEnabled><BlockedEncryptionTypes></BlockedEncryptionTypes></Rule></ServerSideEncryptionConfiguration>`
	type rule struct {
		Default struct {
			Algorithm string `xml:"SSEAlgorithm"`
			Key       string `xml:"KMSMasterKeyID"`
		} `xml:"ApplyServerSideEncryptionByDefault"`
		BucketKey bool `xml:"BucketKeyEnabled"`
		Blocked   *struct {
			Types []string `xml:"EncryptionType"`
		} `xml:"BlockedEncryptionTypes"`
	}
	type config struct {
		Rules []rule `xml:"Rule"`
	}
	var expected config
	if err := xml.Unmarshal([]byte(configuration), &expected); err != nil {
		t.Fatal(err)
	}
	writes := 0
	payload := encryptionFixture(t, false, func(w http.ResponseWriter, r *http.Request) {
		if !r.URL.Query().Has("encryption") {
			t.Errorf("unexpected bucket admin request: %s", r.URL)
			return
		}
		assertEncryptionHeaders(t, r, http.Header{})
		w.Header().Set("Content-Type", "application/xml")
		if r.Method == "PUT" {
			writes++
			body, err := io.ReadAll(r.Body)
			if err != nil {
				t.Error(err)
			}
			var actual config
			if err = xml.Unmarshal(body, &actual); err != nil {
				t.Error(err)
			}
			if !reflect.DeepEqual(actual, expected) {
				t.Errorf("rule fields changed: got %s", body)
			}
			return
		}
		fmt.Fprint(w, configuration)
	})
	params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "sections": []interface{}{"encryption"}}
	state, err := getBucketAdminState(params)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(asString(state["encryptionJson"]), "BlockedEncryptionTypes") {
		t.Fatal("blocked types missing from state")
	}
	params["encryptionJson"] = state["encryptionJson"]
	if _, err = putBucketEncryption(params); err != nil {
		t.Fatal(err)
	}
	if writes != 1 {
		t.Fatalf("writes=%d", writes)
	}
}
func TestObjectEncryptionIsRequestLocal(t *testing.T) {
	payload := encryptionFixture(t, false, func(w http.ResponseWriter, r *http.Request) {
		assertEncryptionHeaders(t, r, http.Header{})
		w.Header().Set("ETag", "fixture")
	})
	p, _ := parseProfile(payload)
	base, ctx, err := buildClient(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = encryptedS3Client(map[string]interface{}{"encryption": encryptionOption("sse-c", encryptionTestKey)}, p, base, false); err != nil {
		t.Fatal(err)
	}
	_, err = base.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String("bucket"), Key: aws.String("key"), Body: strings.NewReader("")})
	if err != nil {
		t.Fatal(err)
	}
	if ctx.Value(encryptionContextKey{}) != nil {
		t.Fatal("secret retained by base context")
	}
	for _, value := range []interface{}{nil, map[string]interface{}{"mode": "bucketDefault"}} {
		client, err := encryptedS3Client(map[string]interface{}{"encryption": value}, p, base, false)
		if err != nil {
			t.Fatal(err)
		}
		_, err = client.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String("bucket"), Key: aws.String("key"), Body: strings.NewReader("")})
		if err != nil {
			t.Fatal(err)
		}
	}
	if !errors.Is(encryptionProviderError(io.EOF, http.Header{}, "GET", 0), io.EOF) {
		t.Fatal("provider error chain lost")
	}
}

func TestObjectEncryptionValidationBeforeRequests(t *testing.T) {
	for _, azure := range []bool{false, true} {
		t.Run(fmt.Sprintf("azure-%v", azure), func(t *testing.T) {
			calls := 0
			payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) { calls++; t.Error("invalid encryption reached provider") })
			params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "key": "key", "sourceBucketName": "bucket", "sourceKey": "source", "destinationBucketName": "bucket", "destinationKey": "dest", "config": map[string]interface{}{"bucketName": "bucket"}, "encryption": map[string]interface{}{"mode": "sse-c", "customerKey": encryptionTestKey, "unexpected": encryptionTestKey}}
			for _, method := range []string{"startUpload", "startDownload", "createFolder", "runPutTestData", "getObjectDetails", "copyObject", "moveObject", "generatePresignedUrl"} {
				_, err := handleRequest(request{Method: method, Params: params})
				if err == nil || mapError(err)["code"] != "invalid_config" {
					t.Fatalf("%s invalid config: %v", method, err)
				}
				if strings.Contains(err.Error(), encryptionTestKey) {
					t.Fatal("validation error leaked key")
				}
			}
			if calls != 0 {
				t.Fatal("unexpected requests")
			}
		})
	}
}
func TestObjectEncryptionUploadPartRetries(t *testing.T) {
	for _, azure := range []bool{false, true} {
		t.Run(fmt.Sprintf("azure-%v", azure), func(t *testing.T) {
			mode := "sse-c"
			if azure {
				mode = "azure-cpk"
			}
			var mu sync.Mutex
			attempts := map[string]int{}
			commits := 0
			payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
				assertEncryptionHeaders(t, r, expectedEncryptionHeaders(mode, encryptionTestKey, false))
				_, _ = io.Copy(io.Discard, r.Body)
				q := r.URL.Query()
				mu.Lock()
				defer mu.Unlock()
				w.Header().Set("ETag", `"part"`)
				switch {
				case q.Has("uploads"):
					fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>")
				case q.Has("partNumber") || q.Get("comp") == "block":
					identity := q.Get("partNumber") + q.Get("blockid")
					attempts[identity]++
					if attempts[identity] == 1 {
						xmlError(w, 503, "SlowDown")
					}
				default:
					commits++
					if !azure {
						fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>done</ETag></CompleteMultipartUploadResult>")
					}
				}
			})
			path := filepath.Join(t.TempDir(), "parts.bin")
			file, err := os.Create(path)
			if err != nil {
				t.Fatal(err)
			}
			size := int64(6 * 1024 * 1024)
			if azure {
				size = azureSingleShotMaxBytes
			}
			err = file.Truncate(size)
			file.Close()
			if err != nil {
				t.Fatal(err)
			}
			captureEncryptionOutput(t, func() {
				result, err := handleRequest(request{Method: "startUpload", Params: map[string]interface{}{"profile": payload, "bucketName": "bucket", "filePaths": []interface{}{path}, "multipartThresholdMiB": 1, "multipartChunkMiB": 5, "encryption": encryptionOption(mode, encryptionTestKey)}})
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
			})
			if commits != 1 || len(attempts) < 2 {
				t.Fatalf("missing multipart requests: %v", attempts)
			}
			for _, count := range attempts {
				if count != 2 {
					t.Fatalf("part attempts=%d", count)
				}
			}
		})
	}
}
func TestObjectEncryptionSingleDownloads(t *testing.T) {
	for _, azure := range []bool{false, true} {
		t.Run(fmt.Sprintf("azure-%v", azure), func(t *testing.T) {
			mode := "sse-c"
			if azure {
				mode = "azure-cpk"
			}
			heads, gets := 0, 0
			payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
				assertEncryptionHeaders(t, r, expectedEncryptionHeaders(mode, encryptionTestKey, false))
				w.Header().Set("ETag", `"original"`)
				w.Header().Set("Content-Length", "5")
				w.Header().Set("Content-Type", "application/octet-stream")
				if r.Method == "HEAD" {
					heads++
					return
				}
				gets++
				if r.Header.Get("Range") != "" {
					t.Error("small download unexpectedly ranged")
				}
				fmt.Fprint(w, "hello")
			})
			destination := t.TempDir()
			captureEncryptionOutput(t, func() {
				result, err := handleRequest(request{Method: "startDownload", Params: map[string]interface{}{"profile": payload, "bucketName": "bucket", "keys": []interface{}{"small.bin"}, "destinationPath": destination, "encryption": encryptionOption(mode, encryptionTestKey)}})
				if err != nil {
					t.Fatal(err)
				}
				writeJSON(result)
			})
			actual, err := os.ReadFile(filepath.Join(destination, "small.bin"))
			if err != nil || string(actual) != "hello" || heads != 1 || gets != 1 {
				t.Fatalf("single download failed: %v heads=%d gets=%d", err, heads, gets)
			}
		})
	}
}
