package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type ageVector struct {
	PlaintextLength               int64 `json:"plaintextLength"`
	Header, FileKey, PayloadNonce string
	HeaderLength                  int64
	ObjectLength                  int64
	ObjectSha256, PlaintextSha256 string
}

func ageVectors(t *testing.T) []ageVector {
	t.Helper()
	data, err := os.ReadFile("../../../contracts/vectors/age-stream.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct{ Cases []ageVector }
	if err = json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Cases) == 0 {
		t.Fatal("no vectors")
	}
	return v.Cases
}
func agePlaintext(n int64) []byte {
	p := make([]byte, n)
	for i := range p {
		p[i] = byte((i*31 + (i>>8)*7 + 3) & 255)
	}
	return p
}
func ageUploadParams(v ageVector) map[string]interface{} {
	return map[string]interface{}{"filePaths": []interface{}{"fixture"}, "clientEncryption": map[string]interface{}{"format": "age-v1", "header": v.Header, "payloadNonce": v.PayloadNonce, "fileKey": v.FileKey}}
}
func vectorObject(t *testing.T, v ageVector) ([]byte, *clientEncryption) {
	t.Helper()
	ce, err := parseClientEncryption(ageUploadParams(v), true)
	if err != nil {
		t.Fatal(err)
	}
	r, err := newAgeUploadReader(bytes.NewReader(agePlaintext(v.PlaintextLength)), nil, ce, v.PlaintextLength)
	if err != nil {
		t.Fatal(err)
	}
	object, err := io.ReadAll(io.NewSectionReader(r, 0, r.length))
	if err != nil {
		t.Fatal(err)
	}
	return object, ce
}
func openAgeObject(ce *clientEncryption, object []byte) ([]byte, error) {
	p, err := agePlaintextLength(ce.headerLength, int64(len(object)))
	if err != nil {
		return nil, err
	}
	aead, err := agePayloadCipher(ce.fileKey, object[ce.headerLength:ce.headerLength+16])
	if err != nil {
		return nil, err
	}
	var plain []byte
	for i := int64(0); i < ageChunks(p); i++ {
		start := ce.headerLength + 16 + i*ageSealedChunkSize
		end := min(start+ageSealedChunkSize, int64(len(object)))
		chunk, err := aead.Open(nil, ageChunkNonce(i, i == ageChunks(p)-1), object[start:end], nil)
		if err != nil {
			return nil, decryptionFailed(i)
		}
		plain = append(plain, chunk...)
	}
	return plain, nil
}
func TestAgeStreamVectors(t *testing.T) {
	for _, v := range ageVectors(t) {
		t.Run(fmt.Sprint(v.PlaintextLength), func(t *testing.T) {
			object, ce := vectorObject(t, v)
			hash := sha256.Sum256(object)
			if int64(len(object)) != v.ObjectLength || hex.EncodeToString(hash[:]) != v.ObjectSha256 {
				t.Fatal("ciphertext vector mismatch")
			}
			target, err := os.CreateTemp(t.TempDir(), "plaintext")
			if err != nil {
				t.Fatal(err)
			}
			defer target.Close()
			err = downloadAgePayload(context.Background(), target, ce, int64(len(object)), 4, 1, func(_ context.Context, start, length int64) (io.ReadCloser, error) {
				return io.NopCloser(bytes.NewReader(object[start : start+length])), nil
			}, func(int64, bool) {})
			if err != nil {
				t.Fatal(err)
			}
			downloaded, err := os.ReadFile(target.Name())
			if err != nil || !bytes.Equal(downloaded, agePlaintext(v.PlaintextLength)) {
				t.Fatal("production payload download differs")
			}
			plain, err := openAgeObject(ce, object)
			if err != nil {
				t.Fatal(err)
			}
			hash = sha256.Sum256(plain)
			if int64(len(plain)) != v.PlaintextLength || hex.EncodeToString(hash[:]) != v.PlaintextSha256 {
				t.Fatal("plaintext vector mismatch")
			}
		})
	}
}
func TestAgeStreamRejectsTampering(t *testing.T) {
	v := ageVectors(t)[6]
	object, ce := vectorObject(t, v)
	prefix := int(ce.headerLength + 16)
	check := func(t *testing.T, b []byte) {
		t.Helper()
		if _, err := openAgeObject(ce, b); err == nil {
			t.Fatal("tampered stream authenticated")
		}
	}
	for i := 0; i < int(ageChunks(v.PlaintextLength)); i++ {
		t.Run(fmt.Sprintf("bit-%d", i), func(t *testing.T) { b := bytes.Clone(object); b[prefix+i*int(ageSealedChunkSize)] ^= 1; check(t, b) })
	}
	t.Run("boundary-and-missing-final", func(t *testing.T) { check(t, object[:prefix+int(ageSealedChunkSize)]) })
	t.Run("mid-chunk", func(t *testing.T) { check(t, object[:len(object)-7]) })
	t.Run("extra-chunk", func(t *testing.T) {
		check(t, append(bytes.Clone(object), object[prefix:prefix+int(ageSealedChunkSize)]...))
	})
	t.Run("swapped-chunks", func(t *testing.T) {
		b := bytes.Clone(object)
		n := int(ageSealedChunkSize)
		copy(b[prefix:prefix+n], object[prefix+n:prefix+2*n])
		copy(b[prefix+n:prefix+2*n], object[prefix:prefix+n])
		check(t, b)
	})
}

func ageDownloadParams(v ageVector) map[string]interface{} {
	return map[string]interface{}{"format": "age-v1", "headerLength": v.HeaderLength, "fileKey": v.FileKey}
}

// Use the engine's loopback fixture transport, so SDK serialization, signing,
// retry and logging execute even in sandboxes that prohibit listening sockets.
func TestAgeClientEncryptionTransfers(t *testing.T) {
	testAgeClientEncryptionTransfers(t, false)
}

func TestClientEncryptionLoopbackTransfers(t *testing.T) {
	testAgeClientEncryptionTransfers(t, true)
}

func clientEncryptionTransferFixture(t *testing.T, azure, loopback bool, handler http.HandlerFunc) map[string]interface{} {
	t.Helper()
	if !loopback {
		return encryptionFixture(t, azure, handler)
	}
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	payload := testProfilePayload(server.URL)
	payload["maxAttempts"] = 3
	payload["diagnostics"] = map[string]interface{}{"enableApiLogging": true, "enableDebugLogging": true}
	if azure {
		payload["endpointType"] = "azureBlob"
		payload["secretKey"] = "Zml4dHVyZQ=="
	}
	return payload
}

func testAgeClientEncryptionTransfers(t *testing.T, loopback bool) {
	vectors := ageVectors(t)
	v := vectors[len(vectors)-1]
	expected, _ := vectorObject(t, v)
	plaintext := agePlaintext(v.PlaintextLength)
	for _, azure := range []bool{false, true} {
		for _, multipart := range []bool{false, true} {
			t.Run(fmt.Sprintf("azure-%v/multipart-%v", azure, multipart), func(t *testing.T) {
				var mu sync.Mutex
				var stored []byte
				parts := map[int][]byte{}
				attempts := map[int]int{}
				var order []int
				var commits int
				lastPart := make(chan struct{})
				mode := "sse-c"
				if azure {
					mode = "azure-cpk"
				}
				payload := clientEncryptionTransferFixture(t, azure, loopback, func(w http.ResponseWriter, r *http.Request) {
					assertEncryptionHeaders(t, r, expectedEncryptionHeaders(mode, encryptionTestKey, false))
					q := r.URL.Query()
					if r.Method == http.MethodHead {
						w.Header().Set("Content-Length", fmt.Sprint(len(stored)))
						w.Header().Set("ETag", `"ciphertext"`)
						return
					}
					if r.Method == http.MethodGet {
						if r.Header.Get("If-Match") != `"ciphertext"` {
							t.Error("missing source validator")
						}
						var start, end int
						if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end); err != nil {
							t.Error(err)
							w.WriteHeader(400)
							return
						}
						if start != int(v.HeaderLength) && (start-int(v.HeaderLength)-16)%int(ageSealedChunkSize) != 0 {
							t.Error("ciphertext request not chunk aligned")
						}
						w.Header().Set("ETag", `"ciphertext"`)
						w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(stored)))
						w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
						w.WriteHeader(http.StatusPartialContent)
						_, _ = w.Write(stored[start : end+1])
						return
					}
					body, err := io.ReadAll(r.Body)
					if err != nil {
						t.Error(err)
						w.WriteHeader(400)
						return
					}
					if r.ContentLength != int64(len(body)) {
						t.Errorf("provider content length %d != body length %d", r.ContentLength, len(body))
					}
					w.Header().Set("ETag", `"part"`)
					switch {
					case q.Has("uploads"):
						fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>")
					case q.Has("partNumber") || q.Get("comp") == "block":
						index, _ := strconv.Atoi(q.Get("partNumber"))
						if azure {
							id, _ := base64.StdEncoding.DecodeString(q.Get("blockid"))
							text := string(id)
							index, _ = strconv.Atoi(text[strings.LastIndex(text, "-")+1:])
							index++
						}
						mu.Lock()
						attempts[index]++
						attempt := attempts[index]
						if old, ok := parts[index]; ok && !bytes.Equal(old, body) {
							t.Error("retry ciphertext changed")
						}
						parts[index] = bytes.Clone(body)
						mu.Unlock()
						// Force later parts to finish first, and part 1 to be retried.
						if index == 1 && attempt == 1 {
							<-lastPart
							xmlError(w, 503, "SlowDown")
							return
						}
						mu.Lock()
						order = append(order, index)
						if index == 3 {
							close(lastPart)
						}
						mu.Unlock()
					case q.Get("comp") == "blocklist" || r.Method == http.MethodPost:
						mu.Lock()
						defer mu.Unlock()
						for i := 1; i <= len(parts); i++ {
							stored = append(stored, parts[i]...)
						}
						commits++
						if !azure {
							fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>done</ETag></CompleteMultipartUploadResult>")
						}
					default:
						stored = bytes.Clone(body)
						commits++
					}
				})
				source := filepath.Join(t.TempDir(), "object.age")
				if err := os.WriteFile(source, plaintext, 0600); err != nil {
					t.Fatal(err)
				}
				threshold := 32
				if multipart {
					threshold = 1
				}
				upload := ageUploadParams(v)
				upload["filePaths"] = []interface{}{source}
				upload["profile"] = payload
				upload["bucketName"] = "bucket"
				upload["multipartThresholdMiB"] = threshold
				upload["multipartChunkMiB"] = 5
				upload["encryption"] = encryptionOption(mode, encryptionTestKey)
				captureAgeOutput(t, v.FileKey, func() {
					result, err := handleRequest(request{Method: "startUpload", Params: upload})
					if err != nil {
						t.Fatal(err)
					}
					if result["totalBytes"] != v.ObjectLength || result["bytesTransferred"] != v.ObjectLength {
						t.Fatal("upload progress does not count ciphertext")
					}
					writeJSON(result)
				})
				if !bytes.Equal(stored, expected) || commits != 1 {
					t.Fatal("provider did not receive vector object")
				}
				if multipart && (len(parts) != 3 || attempts[1] != 2 || len(order) != 3 || order[0] == 1) {
					t.Fatalf("missing out-of-order retries: attempts=%v order=%v", attempts, order)
				}
				dest := t.TempDir()
				download := map[string]interface{}{"profile": payload, "bucketName": "bucket", "keys": []interface{}{"object.age"}, "destinationPath": dest, "multipartThresholdMiB": threshold, "clientEncryption": ageDownloadParams(v), "encryption": encryptionOption(mode, encryptionTestKey)}
				captureAgeOutput(t, v.FileKey, func() {
					result, err := handleRequest(request{Method: "startDownload", Params: download})
					if err != nil {
						t.Fatal(err)
					}
					if result["bytesTransferred"] != v.ObjectLength {
						t.Fatal("download progress does not count ciphertext")
					}
					writeJSON(result)
				})
				actual, err := os.ReadFile(filepath.Join(dest, "object"))
				if err != nil || !bytes.Equal(actual, plaintext) {
					t.Fatalf("published plaintext mismatch: %v", err)
				}
				// keepBoth must use the same authenticated publication path.
				download["conflictPolicy"] = "keepBoth"
				captureAgeOutput(t, v.FileKey, func() {
					if _, err := handleRequest(request{Method: "startDownload", Params: download}); err != nil {
						t.Fatal(err)
					}
				})
				entries, _ := os.ReadDir(dest)
				if len(entries) != 2 {
					t.Fatalf("keepBoth: %v", entries)
				}
				stored[int(v.HeaderLength)+16+int(ageSealedChunkSize)+7] ^= 1
				download["conflictPolicy"] = "replace"
				captureAgeOutput(t, v.FileKey, func() {
					_, err := handleRequest(request{Method: "startDownload", Params: download})
					if err == nil || mapError(err)["code"] != "decryption_failed" || asInt(asMap(mapError(err)["details"])["chunk"]) != 1 {
						t.Fatalf("wrong authentication failure: %v", err)
					}
					writeJSON(mapError(err))
				})
				actual, err = os.ReadFile(filepath.Join(dest, "object"))
				if err != nil || !bytes.Equal(actual, plaintext) {
					t.Fatal("failed authentication replaced published file")
				}
				entries, _ = os.ReadDir(dest)
				if len(entries) != 2 {
					t.Fatal("staged unauthenticated plaintext left on disk")
				}
				download["destinationPath"] = t.TempDir()
				captureAgeOutput(t, v.FileKey, func() {
					if _, err := handleRequest(request{Method: "startDownload", Params: download}); err == nil {
						t.Fatal("corruption accepted")
					}
				})
				entries, _ = os.ReadDir(asString(download["destinationPath"]))
				if len(entries) != 0 {
					t.Fatal("failed authentication published or retained staged file")
				}
			})
		}
	}
}

func captureAgeOutput(t *testing.T, key string, run func()) {
	t.Helper()
	out, err := os.CreateTemp(t.TempDir(), "age-output")
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	stdout, stderr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = out, out
	defer func() { os.Stdout, os.Stderr = stdout, stderr }()
	run()
	os.Stdout, os.Stderr = stdout, stderr
	data, err := os.ReadFile(out.Name())
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte(key)) {
		t.Fatal("file key leaked in captured log, trace, event or response")
	}
}

func TestAgeClientEncryptionValidation(t *testing.T) {
	v := ageVectors(t)[0]
	for _, upload := range []bool{false, true} {
		base := ageUploadParams(v)
		if !upload {
			base = map[string]interface{}{"keys": []interface{}{"object"}, "clientEncryption": ageDownloadParams(v)}
		}
		for _, mutation := range []string{"type", "format", "key-type", "key-length", "key-base64", "unknown-field", "empty-count", "multiple", "header-empty", "header-long", "header-base64", "nonce", "nonce-base64", "header-length-zero", "header-length-long", "header-length-fraction", "header-length-type"} {
			if upload && strings.HasPrefix(mutation, "header-length-") || !upload && (strings.HasPrefix(mutation, "header-") && !strings.HasPrefix(mutation, "header-length-") || strings.HasPrefix(mutation, "nonce")) {
				continue
			}
			t.Run(fmt.Sprintf("upload-%v/%s", upload, mutation), func(t *testing.T) {
				params := map[string]interface{}{}
				for k, value := range base {
					params[k] = value
				}
				config := map[string]interface{}{}
				for k, value := range asMap(base["clientEncryption"]) {
					config[k] = value
				}
				params["clientEncryption"] = config
				countKey := "keys"
				if upload {
					countKey = "filePaths"
				}
				switch mutation {
				case "type":
					params["clientEncryption"] = "age-v1"
				case "format":
					config["format"] = "unknown"
				case "key-type":
					config["fileKey"] = 17
				case "key-length":
					config["fileKey"] = base64.StdEncoding.EncodeToString(make([]byte, 32))
				case "key-base64":
					config["fileKey"] = "%%%"
				case "unknown-field":
					config["customerKey"] = v.FileKey
				case "empty-count":
					params[countKey] = []interface{}{}
				case "multiple":
					params[countKey] = []interface{}{"one", "two"}
				case "header-empty":
					config["header"] = ""
				case "header-long":
					config["header"] = base64.StdEncoding.EncodeToString(make([]byte, 65537))
				case "header-base64":
					config["header"] = "%%%"
				case "nonce":
					config["payloadNonce"] = base64.StdEncoding.EncodeToString(make([]byte, 15))
				case "nonce-base64":
					config["payloadNonce"] = "%%%"
				case "header-length-zero":
					config["headerLength"] = 0
				case "header-length-long":
					config["headerLength"] = 65537
				case "header-length-fraction":
					config["headerLength"] = 168.5
				case "header-length-type":
					config["headerLength"] = "168"
				}
				// Validate through the entry points: no provider or filesystem access is
				// possible with the deliberately absent profile and nonexistent paths.
				for _, azure := range []bool{false, true} {
					var err error
					if upload {
						if azure {
							_, err = azureStartUpload(params)
						} else {
							_, err = startUpload(params)
						}
					} else {
						if azure {
							_, err = azureStartDownload(params)
						} else {
							_, err = startDownload(params)
						}
					}
					if err == nil || mapError(err)["code"] != "invalid_config" {
						t.Fatalf("invalid configuration accepted: %v", err)
					}
				}
			})
		}
	}
}

func TestAgeLengthArithmetic(t *testing.T) {
	for _, h := range []int64{1, 168, 65536} {
		for _, p := range []int64{0, 1, 65535, 65536, 65537, 131072, 131073, 50000 * 1024 * 1024 * 1024} {
			c, err := ageObjectLength(h, p)
			if err != nil {
				t.Fatal(err)
			}
			got, err := agePlaintextLength(h, c)
			if err != nil || got != p {
				t.Fatalf("length roundtrip H=%d P=%d: %d %v", h, p, got, err)
			}
		}
	}
	for _, p := range []int64{-1, math.MaxInt64} {
		if _, err := ageObjectLength(168, p); err == nil {
			t.Fatal("impossible upload length accepted")
		}
	}
	for _, c := range []int64{-1, 0, 168 + 31, 168 + 16 + 65552 + 16} {
		if _, err := agePlaintextLength(168, c); err == nil || mapError(err)["code"] != "decryption_failed" {
			t.Fatalf("impossible object length accepted: %d", c)
		}
	}
	// The nonce is an 11-byte counter, not a little-endian or 32-bit index.
	nonce := ageChunkNonce(0x0102030405060708, true)
	if !bytes.Equal(nonce, []byte{0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 1}) {
		t.Fatal("wrong chunk nonce")
	}
}

type ageTrackingReader struct {
	data             []byte
	offsets, lengths []int64
}

func (r *ageTrackingReader) ReadAt(p []byte, off int64) (int, error) {
	r.offsets = append(r.offsets, off)
	r.lengths = append(r.lengths, int64(len(p)))
	return bytes.NewReader(r.data).ReadAt(p, off)
}
func TestAgeUploadCiphertextRangesAreBounded(t *testing.T) {
	v := ageVectors(t)[6]
	expected, ce := vectorObject(t, v)
	source := &ageTrackingReader{data: agePlaintext(v.PlaintextLength)}
	r, err := newAgeUploadReader(source, nil, ce, v.PlaintextLength)
	if err != nil {
		t.Fatal(err)
	}
	prefix := ce.headerLength + 16
	for _, part := range []struct{ offset, length int64 }{
		{0, prefix}, {prefix + ageSealedChunkSize - 7, 31}, {prefix + 2*ageSealedChunkSize + 13, 42}, {int64(len(expected)) - 11, 11},
	} {
		source.offsets = nil
		source.lengths = nil
		actual, err := io.ReadAll(io.NewSectionReader(r, part.offset, part.length))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(actual, expected[part.offset:part.offset+part.length]) {
			t.Fatal("ciphertext slice differs")
		}
		for i, offset := range source.offsets {
			index := offset / ageChunkSize
			start, end := prefix+index*ageSealedChunkSize, prefix+(index+1)*ageSealedChunkSize
			if offset%ageChunkSize != 0 || source.lengths[i] > ageChunkSize || start >= part.offset+part.length || end <= part.offset {
				t.Fatalf("read source chunk outside requested range: offset=%d", offset)
			}
		}
	}
	// The same misaligned range must produce identical bytes on replay.
	a := make([]byte, 131)
	b := make([]byte, 131)
	_, err = r.ReadAt(a, prefix+ageSealedChunkSize-7)
	if err != nil {
		t.Fatal(err)
	}
	_, err = r.ReadAt(b, prefix+ageSealedChunkSize-7)
	if err != nil || !bytes.Equal(a, b) {
		t.Fatal("range replay changed ciphertext")
	}
}

func TestAgeClientEncryptionCapability(t *testing.T) {
	for _, provider := range []string{"awsS3", "s3Compatible", "azureBlob"} {
		result, err := handleRequest(request{Method: "getCapabilities", Params: map[string]interface{}{"profile": map[string]interface{}{"endpointType": provider}}})
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, item := range result["items"].([]map[string]interface{}) {
			if item["key"] == "object.clientEncryption" {
				found = true
				if item["state"] != "supported" || item["implementationState"] != "supported" || !reflect.DeepEqual(item["formats"], []string{"age-v1"}) {
					t.Fatalf("wrong capability: %v", item)
				}
			}
		}
		if !found {
			t.Fatalf("missing capability for %s", provider)
		}
	}
}

func TestAgeClientEncryptionDefaultOff(t *testing.T) {
	for _, azure := range []bool{false, true} {
		for _, multipart := range []bool{false, true} {
			t.Run(fmt.Sprintf("azure-%v/multipart-%v", azure, multipart), func(t *testing.T) {
				plain := agePlaintext(6*1024*1024 + 17)
				var mu sync.Mutex
				var stored []byte
				parts := map[int][]byte{}
				var requests []string
				payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
					assertEncryptionHeaders(t, r, http.Header{})
					q := r.URL.Query()
					w.Header().Set("ETag", `"original"`)
					if r.Method == http.MethodHead {
						w.Header().Set("Content-Length", fmt.Sprint(len(stored)))
						mu.Lock()
						requests = append(requests, "HEAD")
						mu.Unlock()
						return
					}
					if r.Method == http.MethodGet {
						if r.Header.Get("If-Match") != `"original"` {
							t.Error("missing unencrypted validator")
						}
						start, end := 0, len(stored)-1
						if r.Header.Get("Range") != "" {
							_, _ = fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end)
							w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(stored)))
							w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
							w.WriteHeader(206)
						} else {
							w.Header().Set("Content-Length", fmt.Sprint(len(stored)))
						}
						mu.Lock()
						requests = append(requests, "GET "+r.Header.Get("Range"))
						mu.Unlock()
						_, _ = w.Write(stored[start : end+1])
						return
					}
					body, err := io.ReadAll(r.Body)
					if err != nil {
						t.Error(err)
					}
					mu.Lock()
					defer mu.Unlock()
					requests = append(requests, fmt.Sprintf("%s %s %d %x", r.Method, r.URL.RawQuery, r.ContentLength, sha256.Sum256(body)))
					switch {
					case q.Has("uploads"):
						fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>same-upload</UploadId></InitiateMultipartUploadResult>")
					case q.Has("partNumber"):
						index, _ := strconv.Atoi(q.Get("partNumber"))
						parts[index] = body
					case r.Method == http.MethodPost:
						stored = nil
						for i := 1; i <= len(parts); i++ {
							stored = append(stored, parts[i]...)
						}
						fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>done</ETag></CompleteMultipartUploadResult>")
					default:
						stored = body
					}
				})
				source := filepath.Join(t.TempDir(), "plain.bin")
				if err := os.WriteFile(source, plain, 0600); err != nil {
					t.Fatal(err)
				}
				var baseline []string
				for _, explicitNull := range []bool{false, true} {
					requests = nil
					threshold := 32
					if multipart {
						threshold = 1
					}
					params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "filePaths": []interface{}{source}, "multipartThresholdMiB": threshold, "multipartChunkMiB": 5}
					if explicitNull {
						params["clientEncryption"] = nil
					}
					captureEncryptionOutput(t, func() {
						if _, err := handleRequest(request{Method: "startUpload", Params: params}); err != nil {
							t.Fatal(err)
						}
					})
					if !bytes.Equal(stored, plain) {
						t.Fatal("unencrypted upload bytes changed")
					}
					params["keys"] = []interface{}{"plain.bin"}
					params["destinationPath"] = t.TempDir()
					captureEncryptionOutput(t, func() {
						if _, err := handleRequest(request{Method: "startDownload", Params: params}); err != nil {
							t.Fatal(err)
						}
					})
					got, err := os.ReadFile(filepath.Join(asString(params["destinationPath"]), "plain.bin"))
					if err != nil || !bytes.Equal(got, plain) {
						t.Fatal("unencrypted publication changed")
					}
					sort.Strings(requests)
					if explicitNull {
						if !reflect.DeepEqual(requests, baseline) {
							t.Fatal("null clientEncryption changed provider requests")
						}
					} else {
						baseline = append([]string{}, requests...)
					}
				}
			})
		}
	}
}

func TestAgeClientEncryptionSecretHygiene(t *testing.T) {
	v := ageVectors(t)[0]
	for _, azure := range []bool{false, true} {
		for _, failure := range []bool{false, true} {
			t.Run(fmt.Sprintf("azure-%v/failure-%v", azure, failure), func(t *testing.T) {
				payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
					_, _ = io.Copy(io.Discard, r.Body)
					w.Header().Set("X-Fixture-Echo", v.FileKey)
					w.Header().Set("Content-Type", "application/xml")
					if failure {
						w.WriteHeader(400)
						fmt.Fprintf(w, "<Error><Code>InvalidRequest</Code><Message>echo %s</Message></Error>", v.FileKey)
					} else {
						w.Header().Set("ETag", v.FileKey)
					}
				})
				source := filepath.Join(t.TempDir(), "empty")
				if err := os.WriteFile(source, nil, 0600); err != nil {
					t.Fatal(err)
				}
				params := ageUploadParams(v)
				params["profile"] = payload
				params["bucketName"] = "bucket"
				params["filePaths"] = []interface{}{source}
				// Exercise free-text job output and URL traces as well as structured fields.
				params["prefix"] = v.FileKey
				captureAgeOutput(t, v.FileKey, func() {
					result, err := handleRequest(request{Method: "startUpload", Params: params})
					if failure {
						if err == nil {
							t.Fatal("expected provider error")
						}
						fmt.Fprintln(os.Stderr, err)
						writeJSON(mapError(err))
					} else {
						if err != nil {
							t.Fatal(err)
						}
						writeJSON(result)
					}
					writeJSON(map[string]interface{}{"trace": []interface{}{map[string]interface{}{"clientEncryption": map[string]interface{}{"fileKey": v.FileKey}}}, "checkpoint": map[string]string{"fileKey": v.FileKey}, "manifest": struct {
						FileKey string `json:"fileKey"`
					}{v.FileKey}})
				})
			})
		}
	}
}

func TestAgeEncryptedDownloadRetriesAndValidators(t *testing.T) {
	v := ageVectors(t)[6]
	object, _ := vectorObject(t, v)
	for _, azure := range []bool{false, true} {
		for _, failure := range []string{"retry", "range", "etag", "impossible-length", "boundary", "mid-chunk", "extra", "swapped"} {
			t.Run(fmt.Sprintf("azure-%v/%s", azure, failure), func(t *testing.T) {
				stored := bytes.Clone(object)
				prefix := int(v.HeaderLength) + 16
				switch failure {
				case "impossible-length":
					stored = stored[:int(v.HeaderLength)+31]
				case "boundary":
					stored = stored[:prefix+int(ageSealedChunkSize)]
				case "mid-chunk":
					stored = stored[:len(stored)-7]
				case "extra":
					stored = append(stored, object[prefix:prefix+int(ageSealedChunkSize)]...)
				case "swapped":
					n := int(ageSealedChunkSize)
					copy(stored[prefix:prefix+n], object[prefix+n:prefix+2*n])
					copy(stored[prefix+n:prefix+2*n], object[prefix:prefix+n])
				}
				var mu sync.Mutex
				attempts := map[int]int{}
				payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("ETag", `"original"`)
					if r.Method == http.MethodHead {
						w.Header().Set("Content-Length", fmt.Sprint(len(stored)))
						return
					}
					if r.Header.Get("If-Match") != `"original"` {
						t.Error("retry lost If-Match")
					}
					if !azure && r.URL.Query().Get("versionId") != "fixture-version" {
						t.Error("retry lost version")
					}
					var start, end int
					_, _ = fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end)
					mu.Lock()
					attempts[start]++
					attempt := attempts[start]
					mu.Unlock()
					w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
					w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(stored)))
					if start == prefix {
						if failure == "range" {
							w.Header().Set("Content-Range", "bytes 0-1/2")
						}
						if failure == "etag" {
							w.Header().Set("ETag", `"changed"`)
						}
						if failure == "retry" && attempt == 1 {
							w.WriteHeader(206)
							_, _ = w.Write(bytes.Repeat([]byte{0xa7}, 100))
							return
						}
					}
					w.WriteHeader(206)
					_, _ = w.Write(stored[start : end+1])
				})
				dest := t.TempDir()
				params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "keys": []interface{}{"object"}, "destinationPath": dest, "versionId": "fixture-version", "clientEncryption": ageDownloadParams(v)}
				captureAgeOutput(t, v.FileKey, func() {
					result, err := handleRequest(request{Method: "startDownload", Params: params})
					if failure == "retry" {
						if err != nil {
							t.Fatal(err)
						}
						got, readErr := os.ReadFile(filepath.Join(dest, "object"))
						if readErr != nil || !bytes.Equal(got, agePlaintext(v.PlaintextLength)) {
							t.Fatal("body retry did not restore plaintext")
						}
						if attempts[prefix] != 2 || result["bytesTransferred"] != int64(len(stored)) {
							t.Fatal("retry progress or attempt count incorrect")
						}
					} else {
						if err == nil {
							t.Fatal("invalid encrypted download published")
						}
						if failure != "range" && failure != "etag" && mapError(err)["code"] != "decryption_failed" {
							t.Fatalf("wrong authentication error: %v", err)
						}
						entries, _ := os.ReadDir(dest)
						if len(entries) != 0 {
							t.Fatal("failed encrypted download left staged or published bytes")
						}
					}
				})
			})
		}
	}
}

func TestAgeUploadSourceChangeAborts(t *testing.T) {
	v := ageVectors(t)[0]
	for _, azure := range []bool{false, true} {
		t.Run(fmt.Sprintf("azure-%v", azure), func(t *testing.T) {
			source := filepath.Join(t.TempDir(), "changing.bin")
			if err := os.WriteFile(source, make([]byte, 6*1024*1024), 0600); err != nil {
				t.Fatal(err)
			}
			var mu sync.Mutex
			aborted, committed := 0, 0
			changed := false
			payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.Copy(io.Discard, r.Body)
				q := r.URL.Query()
				mu.Lock()
				defer mu.Unlock()
				switch {
				case q.Has("uploads"):
					fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>")
				case r.Method == http.MethodDelete:
					aborted++
				case q.Has("partNumber") || q.Get("comp") == "block":
					if !changed {
						changed = true
						when := time.Now().Add(time.Hour)
						if err := os.Chtimes(source, when, when); err != nil {
							t.Error(err)
						}
						xmlError(w, 503, "SlowDown")
						return
					}
					w.Header().Set("ETag", `"part"`)
				default:
					committed++
				}
			})
			params := ageUploadParams(v)
			params["profile"] = payload
			params["bucketName"] = "bucket"
			params["filePaths"] = []interface{}{source}
			params["multipartThresholdMiB"] = 1
			params["multipartChunkMiB"] = 5
			captureAgeOutput(t, v.FileKey, func() {
				_, err := handleRequest(request{Method: "startUpload", Params: params})
				if err == nil {
					t.Fatal("changed source accepted")
				}
			})
			if !changed || committed != 0 || !azure && aborted != 1 {
				t.Fatalf("changed upload committed or not aborted: changed=%v committed=%d aborted=%d", changed, committed, aborted)
			}
		})
	}
}

func TestAgeUploadSizingUsesCiphertextLength(t *testing.T) {
	v := ageVectors(t)[0]
	for _, azure := range []bool{false, true} {
		for _, plainSize := range []int64{1024*1024 - 1, 5*1024*1024 - 1} {
			t.Run(fmt.Sprintf("azure-%v/plain-%d", azure, plainSize), func(t *testing.T) {
				ciphertextSize, err := ageObjectLength(v.HeaderLength, plainSize)
				if err != nil {
					t.Fatal(err)
				}
				var mu sync.Mutex
				var lengths []int64
				committed := false
				payload := encryptionFixture(t, azure, func(w http.ResponseWriter, r *http.Request) {
					q := r.URL.Query()
					_, _ = io.Copy(io.Discard, r.Body)
					mu.Lock()
					defer mu.Unlock()
					switch {
					case q.Has("uploads"):
						fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>")
					case q.Has("partNumber") || q.Get("comp") == "block":
						lengths = append(lengths, r.ContentLength)
						w.Header().Set("ETag", `"part"`)
					case r.Method == http.MethodPost || q.Get("comp") == "blocklist":
						committed = true
						if !azure {
							fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>done</ETag></CompleteMultipartUploadResult>")
						}
					default:
						t.Error("plaintext size incorrectly selected single PUT")
					}
				})
				source := filepath.Join(t.TempDir(), "boundary.bin")
				if err := os.WriteFile(source, agePlaintext(plainSize), 0600); err != nil {
					t.Fatal(err)
				}
				params := ageUploadParams(v)
				params["profile"] = payload
				params["bucketName"] = "bucket"
				params["filePaths"] = []interface{}{source}
				params["multipartThresholdMiB"] = 1
				params["multipartChunkMiB"] = 5
				captureAgeOutput(t, v.FileKey, func() {
					result, err := handleRequest(request{Method: "startUpload", Params: params})
					if err != nil {
						t.Fatal(err)
					}
					wantParts := int((ciphertextSize + 5*1024*1024 - 1) / (5 * 1024 * 1024))
					if !committed || len(lengths) != wantParts || result["partsTotal"] != wantParts || result["totalBytes"] != ciphertextSize {
						t.Fatal("multipart sizing did not use ciphertext length")
					}
					sort.Slice(lengths, func(i, j int) bool { return lengths[i] < lengths[j] })
					if lengths[0] != ciphertextSize-int64(wantParts-1)*5*1024*1024 {
						t.Fatal("incorrect final ciphertext range")
					}
					if len(lengths) > 1 && lengths[1] != 5*1024*1024 {
						t.Fatal("nonuniform ciphertext part")
					}
				})
			})
		}
	}
}

func TestAgeDownloadPublishedNames(t *testing.T) {
	v := ageVectors(t)[1]
	ciphertext, _ := vectorObject(t, v)
	plaintext := agePlaintext(v.PlaintextLength)
	for _, provider := range []string{"s3", "azure", "gcs"} {
		for _, tc := range []struct {
			name, key, published, policy string
			encrypted, collision         bool
			supplied                     string
		}{
			{"supplied", "folder/token.age", "report.pdf", "", true, false, "report.pdf"},
			{"supplied-keepBoth", "token.age", "report (1).pdf", "keepBoth", true, true, "report.pdf"},
			{"supplied-replace", "token.age", "report.pdf", "replace", true, true, "report.pdf"},
			{"strip", "folder/report.pdf.age", "report.pdf", "", true, false, ""},
			{"empty-remainder", "folder/.age", ".age", "", true, false, ""},
			{"no-suffix", "folder/notes", "notes", "", true, false, ""},
			{"one-suffix", "folder/a.age.age", "a.age", "", true, false, ""},
			{"keepBoth", "folder/report.pdf.age", "report (1).pdf", "keepBoth", true, true, ""},
			{"replace", "folder/report.pdf.age", "report.pdf", "replace", true, true, ""},
			{"reserved-name", "folder/CON.age", "_CON", "", true, false, ""},
			{"normal", "folder/report.pdf.age", "report.pdf.age", "", false, false, ""},
		} {
			t.Run(provider+"/"+tc.name, func(t *testing.T) {
				stored := plaintext
				if tc.encrypted {
					stored = ciphertext
				}
				var payload map[string]interface{}
				if provider == "gcs" {
					f := newGCSFixtureWithTransport(t, true)
					f.objects[tc.key] = stored
					payload = f.params
				} else {
					payload = encryptionFixture(t, provider == "azure", func(w http.ResponseWriter, r *http.Request) {
						w.Header().Set("ETag", `"original"`)
						if r.Method == http.MethodHead {
							w.Header().Set("Content-Length", fmt.Sprint(len(stored)))
							return
						}
						if r.Method != http.MethodGet {
							t.Errorf("unexpected method %s", r.Method)
							w.WriteHeader(400)
							return
						}
						start, end := 0, len(stored)-1
						if r.Header.Get("Range") != "" {
							if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end); err != nil {
								t.Error(err)
								w.WriteHeader(400)
								return
							}
							w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(stored)))
							w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
							w.WriteHeader(http.StatusPartialContent)
						} else {
							w.Header().Set("Content-Length", fmt.Sprint(len(stored)))
						}
						_, _ = w.Write(stored[start : end+1])
					})
				}
				dir := t.TempDir()
				if tc.collision {
					if err := os.WriteFile(filepath.Join(dir, "report.pdf"), []byte("existing"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				params := map[string]interface{}{"profile": payload, "bucketName": "bucket", "keys": []interface{}{tc.key}, "destinationPath": dir, "conflictPolicy": tc.policy}
				if tc.encrypted {
					params["clientEncryption"] = ageDownloadParams(v)
					if tc.supplied != "" {
						params["clientEncryption"].(map[string]interface{})["fileName"] = tc.supplied
					}
				}
				captureAgeOutput(t, v.FileKey, func() {
					result, err := dispatchRequest(request{Method: "startDownload", Params: params})
					if err != nil {
						t.Fatal(err)
					}
					if tc.encrypted {
						want := fmt.Sprintf("Saved %s to %s.", tc.published, filepath.Join(dir, tc.published))
						if !strings.Contains(strings.Join(asStringSlice(result["outputLines"]), "\n"), want) {
							t.Fatalf("missing published name in output: %v", result["outputLines"])
						}
					}
				})
				got, err := os.ReadFile(filepath.Join(dir, tc.published))
				if err != nil || !bytes.Equal(got, plaintext) {
					t.Fatalf("published plaintext mismatch: %v", err)
				}
				wantCount := 1
				if tc.policy == "keepBoth" {
					wantCount++
					got, err = os.ReadFile(filepath.Join(dir, "report.pdf"))
					if err != nil || string(got) != "existing" {
						t.Fatal("keepBoth overwrote existing plaintext name")
					}
				}
				entries, err := os.ReadDir(dir)
				if err != nil || len(entries) != wantCount {
					t.Fatalf("unexpected published files: %v, %v", entries, err)
				}
			})
		}
	}
}

func TestAgeDownloadFileNameValidationAndRedaction(t *testing.T) {
	for _, name := range []interface{}{nil, 1, false, []interface{}{}, map[string]interface{}{}, "", ".", "..", "a/b", "a\\b", "a\x00b"} {
		params := map[string]interface{}{"keys": []interface{}{"token.age"}, "clientEncryption": ageDownloadParams(ageVectors(t)[0])}
		params["clientEncryption"].(map[string]interface{})["fileName"] = name
		for _, run := range []func(map[string]interface{}) (map[string]interface{}, error){startDownload, azureStartDownload} {
			if _, err := run(params); err == nil || mapError(err)["code"] != "invalid_config" {
				t.Fatalf("invalid name accepted before provider setup: %v", err)
			}
		}
	}
	params := map[string]interface{}{"clientEncryption": map[string]interface{}{"fileName": "hidden-name-sentinel.pdf"}}
	safe := redactEncryptionValues(redactEncryptionFields(params), clientEncryptionSecrets(params))
	if strings.Contains(fmt.Sprint(safe), "hidden-name-sentinel.pdf") {
		t.Fatal("hidden name leaked")
	}
}
