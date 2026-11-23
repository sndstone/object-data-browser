package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestConformanceBodyVectors(t *testing.T) {
	data, err := os.ReadFile("../../../contracts/vectors/s3-conformance-body.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			Size, Seed        int64
			SHA256, First8Hex string
		}
	}
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	if len(vectors.Cases) == 0 {
		t.Fatal("missing conformance body vectors")
	}
	for _, v := range vectors.Cases {
		t.Run(fmt.Sprintf("%d_%d", v.Size, v.Seed), func(t *testing.T) {
			body, err := conformanceBody(map[string]interface{}{"generate": map[string]interface{}{"size": v.Size, "seed": v.Seed}})
			if err != nil {
				t.Fatal(err)
			}
			if len(body) != int(v.Size) || fmt.Sprintf("%x", sha256.Sum256(body)) != v.SHA256 ||
				hex.EncodeToString(body[:min(8, len(body))]) != v.First8Hex {
				t.Error("body does not match the conformance vector")
			}
		})
	}
	for _, input := range []interface{}{
		[]interface{}{},
		map[string]interface{}{"text": strings.Repeat("é", (64<<10)/2+1)},
		map[string]interface{}{"base64": base64.StdEncoding.EncodeToString(make([]byte, (1<<20)+1))},
		map[string]interface{}{"base64": "/////"},
		map[string]interface{}{"generate": map[string]interface{}{"size": 16<<20 + 1, "seed": 7}},
		map[string]interface{}{"generate": map[string]interface{}{"size": 5, "seed": 65536}},
		map[string]interface{}{"generate": map[string]interface{}{"size": -1, "seed": 7}},
		map[string]interface{}{"generate": map[string]interface{}{"size": 3}},
		map[string]interface{}{"text": "a", "base64": "Yg=="},
	} {
		_, err := conformanceBody(input)
		assertConformanceRPCError(t, err, "invalid_request")
	}
}

func conformanceTestProfile(endpoint string) map[string]interface{} {
	return map[string]interface{}{
		"endpointType": "s3Compatible", "endpointUrl": endpoint, "pathStyle": true,
		"accessKey": "fixture-access-key", "secretKey": "fixture-secret-key", "sessionToken": "fixture-session-token",
		"diagnostics": map[string]interface{}{"enableApiLogging": true, "enableDebugLogging": true},
	}
}

func callConformance(t *testing.T, p map[string]interface{}, op string, input, extra map[string]interface{}) map[string]interface{} {
	t.Helper()
	params := map[string]interface{}{"profile": p, "op": op, "input": input}
	for name, value := range extra {
		params[name] = value
	}
	result, err := dispatchRequest(request{Method: "s3ConformanceOp", Params: params})
	if err != nil {
		t.Fatal(err)
	}
	if result["op"] != op || result["latencyMs"].(float64) <= 0 {
		t.Fatal("conformance operation or measured latency missing")
	}
	return result
}

func assertConformanceRPCError(t *testing.T, err error, want string) {
	t.Helper()
	var rpcError *sidecarError
	if !errors.As(err, &rpcError) || rpcError.Code != want {
		t.Errorf("expected RPC error %s", want)
	}
}

func assertConformanceOutcome(t *testing.T, result map[string]interface{}, outcome string, status, attempts int) {
	t.Helper()
	if result["outcome"] != outcome || result["httpStatus"] != status || result["attempts"] != attempts {
		t.Fatalf("outcome/status/attempts = %v/%v/%v, want %s/%d/%d",
			result["outcome"], result["httpStatus"], result["attempts"], outcome, status, attempts)
	}
}

func TestConformancePutGetAndServiceErrors(t *testing.T) {
	const contents = "héllo S3"
	var sends atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sends.Add(1)
		w.Header().Set("X-Amz-Request-Id", "example-request")
		w.Header().Set("X-Extra-Fixture", "private")
		w.Header().Set("Authorization", r.Header.Get("Authorization"))
		w.Header().Set("X-Amz-Security-Token", r.Header.Get("X-Amz-Security-Token"))
		switch r.URL.Path {
		case "/bucket/key":
			w.Header().Set("ETag", `"abc"`)
			if r.Method == http.MethodPut {
				body, err := io.ReadAll(r.Body)
				if err != nil || string(body) != contents || r.Header.Get("Content-Type") != "text/plain" {
					t.Error("PUT body or content type did not match fixture")
				}
				for name := range r.Header {
					if strings.HasPrefix(strings.ToLower(name), "x-amz-checksum-") {
						t.Error("SDK added an optional checksum")
					}
				}
				return
			}
			w.Header().Set("Content-Range", "bytes 0-8/9")
			w.Header().Add("X-Amz-Meta-Example", "alpha")
			w.Header().Add("X-Amz-Meta-Example", "beta")
			w.WriteHeader(http.StatusPartialContent)
			fmt.Fprint(w, contents)
		case "/bucket/missing":
			w.Header().Set("X-Amz-Delete-Marker", "true")
			w.WriteHeader(http.StatusNotFound)
			if r.Method != http.MethodHead {
				fmt.Fprint(w, `<Error><Code>NoSuchKey</Code><Message>Object missing</Message></Error>`)
			}
		case "/bucket/unchanged":
			w.WriteHeader(http.StatusNotModified)
		case "/bucket/redirect":
			w.Header().Set("Location", "https://example.test/bucket/key?X-Amz-Signature=private")
			w.Header().Set("X-Amz-Website-Redirect-Location", "/relative?private=value")
			w.WriteHeader(http.StatusTemporaryRedirect)
		case "/bucket/bad-redirect":
			w.Header().Set("Location", "%")
			w.WriteHeader(http.StatusTemporaryRedirect)
		case "/bucket/busy":
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprint(w, `<Error><Code>SlowDown</Code><Message>Retry later</Message></Error>`)
		default:
			t.Errorf("unexpected request path %s", r.URL.Path)
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer server.Close()
	profile := conformanceTestProfile(server.URL)
	profile["endpointType"] = "awsS3" // AWS profiles must also disable optional checksums.
	input := map[string]interface{}{"Bucket": "bucket", "Key": "key", "ContentType": "text/plain"}
	put := callConformance(t, profile, "PutObject", input, map[string]interface{}{"body": map[string]interface{}{"text": contents}})
	assertConformanceOutcome(t, put, "service", 200, 1)
	delete(input, "ContentType")
	got := callConformance(t, profile, "GetObject", input, nil)
	assertConformanceOutcome(t, got, "service", 206, 1)
	body := asMap(asMap(got["output"])["Body"])
	if body["length"] != int64(len(contents)) || body["sha256"] != fmt.Sprintf("%x", sha256.Sum256([]byte(contents))) {
		t.Fatal("GET body digest mismatch")
	}
	headers := asMap(got["headers"])
	if headers["etag"] != `"abc"` || headers["content-range"] != "bytes 0-8/9" ||
		headers["x-amz-meta-example"] != "alpha, beta" || got["requestId"] != "example-request" {
		t.Fatal("GET headers or request ID mismatch")
	}
	for _, name := range []string{"ETag", "x-extra-fixture", "authorization", "x-amz-security-token"} {
		if _, found := headers[name]; found {
			t.Errorf("unexpected header %s", name)
		}
	}
	input["Key"] = "missing"
	missing := callConformance(t, profile, "GetObject", input, nil)
	assertConformanceOutcome(t, missing, "service", 404, 1)
	if missing["errorCode"] != "NoSuchKey" || missing["errorMessage"] != "Object missing" ||
		asMap(missing["headers"])["x-amz-delete-marker"] != "true" {
		t.Error("GET 404 lost its parsed error or delete-marker header")
	}
	assertConformanceOutcome(t, callConformance(t, profile, "HeadObject", input, nil), "service", 404, 1)
	input["Key"] = "unchanged"
	assertConformanceOutcome(t, callConformance(t, profile, "GetObject", input, nil), "service", 304, 1)
	input["Key"] = "redirect"
	redirect := callConformance(t, profile, "GetObject", input, nil)
	assertConformanceOutcome(t, redirect, "service", 307, 1)
	headers = asMap(redirect["headers"])
	if headers["location"] != "https://example.test/bucket/key?[query]" ||
		headers["x-amz-website-redirect-location"] != "/relative?[query]" {
		t.Error("redirect headers did not preserve the path and redact the query")
	}
	input["Key"] = "bad-redirect"
	assertConformanceOutcome(t, callConformance(t, profile, "GetObject", input, nil), "service", 307, 1)
	input["Key"] = "busy"
	assertConformanceOutcome(t, callConformance(t, profile, "GetObject", input, nil), "service", 503, 1)
	delete(input, "Key")
	assertConformanceOutcome(t, callConformance(t, profile, "GetObject", input, nil), "sdk_validation", 0, 0)
	if sends.Load() != 8 {
		t.Errorf("server received %d requests, want 8", sends.Load())
	}
}

func TestConformanceProjectionsAndCopySource(t *testing.T) {
	const token = "opaque+cursor%=/X-Amz-Signature=not-a-signature"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		query := r.URL.Query()
		switch {
		case query.Get("list-type") == "2":
			if query.Get("continuation-token") != token {
				t.Error("continuation token changed on input")
			}
			fmt.Fprintf(w, `<ListBucketResult><IsTruncated>true</IsTruncated><KeyCount>1</KeyCount><MaxKeys>1</MaxKeys><ContinuationToken>%s</ContinuationToken><NextContinuationToken>%s</NextContinuationToken><Contents><Key>entry</Key><Size>19</Size><ETag>"e"</ETag><LastModified>2026-01-02T03:04:05+02:00</LastModified><StorageClass>STANDARD</StorageClass></Contents><CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes></ListBucketResult>`, token, token)
		case query.Has("delete"):
			fmt.Fprint(w, `<DeleteResult><Deleted><Key>removed</Key><VersionId>null</VersionId><DeleteMarker>true</DeleteMarker><DeleteMarkerVersionId>id</DeleteMarkerVersionId></Deleted><Error><Key>denied</Key><Code>AccessDenied</Code><Message>Denied</Message></Error></DeleteResult>`)
		case r.Method == http.MethodPut:
			if r.Header.Get("X-Amz-Copy-Source") != "source/folder/a%2B%20%25%C3%A9?versionId=v%2B+1" {
				t.Error("copy source was not escaped exactly once")
			}
			fmt.Fprint(w, `<CopyObjectResult><ETag>"copy"</ETag><LastModified>2026-01-02T01:04:05Z</LastModified></CopyObjectResult>`)
		default:
			fmt.Fprint(w, `<not-valid-xml>`)
		}
	}))
	defer server.Close()
	profile := conformanceTestProfile(server.URL)
	listed := callConformance(t, profile, "ListObjectsV2", map[string]interface{}{"Bucket": "bucket", "ContinuationToken": token}, nil)
	assertConformanceOutcome(t, listed, "service", 200, 1)
	// Exercise the RPC writer's redaction path too.
	safe := asMap(redactEncryptionFields(listed))
	output := asMap(safe["output"])
	object := asMap(output["Contents"].([]interface{})[0])
	if output["ContinuationToken"] != token || output["NextContinuationToken"] != token ||
		output["IsTruncated"] != true || output["KeyCount"] != int32(1) || object["Key"] != "entry" ||
		object["Size"] != int64(19) || object["LastModified"] != "2026-01-02T01:04:05Z" ||
		asMap(output["CommonPrefixes"].([]interface{})[0])["Prefix"] != "dir/" {
		t.Error("ListObjectsV2 projection mismatch")
	}
	if _, ok := output["ResultMetadata"]; ok {
		t.Error("SDK response metadata leaked into output")
	}

	deleted := callConformance(t, profile, "DeleteObjects", map[string]interface{}{
		"Bucket": "bucket", "Delete": map[string]interface{}{"Objects": []map[string]interface{}{{"Key": "removed"}, {"Key": "denied"}}},
	}, nil)
	assertConformanceOutcome(t, deleted, "service", 200, 1)
	output = asMap(deleted["output"])
	item := asMap(output["Deleted"].([]interface{})[0])
	failed := asMap(output["Errors"].([]interface{})[0])
	if item["VersionId"] != "null" || item["DeleteMarker"] != true || item["DeleteMarkerVersionId"] != "id" ||
		failed["Key"] != "denied" || failed["Code"] != "AccessDenied" || failed["Message"] != "Denied" {
		t.Error("DeleteObjects projection mismatch")
	}
	if _, ok := failed["VersionId"]; ok {
		t.Error("absent version ID was included")
	}

	copied := callConformance(t, profile, "CopyObject", map[string]interface{}{
		"Bucket": "bucket", "Key": "target",
		"CopySource": map[string]interface{}{"Bucket": "source", "Key": "folder/a+ %é", "VersionId": "v+ 1"},
	}, nil)
	assertConformanceOutcome(t, copied, "service", 200, 1)
	copy := asMap(asMap(copied["output"])["CopyObjectResult"])
	if copy["ETag"] != `"copy"` || copy["LastModified"] != "2026-01-02T01:04:05Z" {
		t.Error("CopyObject projection mismatch")
	}
	assertConformanceOutcome(t, callConformance(t, profile, "ListObjects", map[string]interface{}{"Bucket": "bucket"}, nil), "sdk_decode", 200, 1)
}

func TestConformancePresignedRequest(t *testing.T) {
	const putBody = "signed payload"
	var sends atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sends.Add(1)
		q := r.URL.Query()
		if q.Get("X-Amz-Expires") != "59" || q.Get("X-Amz-Signature") == "" || q.Get("X-Amz-Security-Token") == "" {
			t.Error("missing SigV4 query values")
		}
		if r.Header.Get("Accept-Encoding") != "" {
			t.Error("presigned HTTP transport added content negotiation")
		}
		switch r.Method {
		case http.MethodGet:
			if q.Get("versionId") != "1" {
				t.Error("presigned GET lost its version ID")
			}
		case http.MethodPut:
			data, err := io.ReadAll(r.Body)
			if err != nil || string(data) != putBody || r.Header.Get("Content-Type") != "text/x-test" ||
				!slices.Contains(strings.Split(q.Get("X-Amz-SignedHeaders"), ";"), "content-type") {
				t.Error("presigned PUT did not send a signed content type and the body")
			}
		}
		// A service or proxy could echo the entire original request URI.
		w.Header().Set("Location", "http://"+r.Host+r.URL.RequestURI())
		w.Header().Set("X-Amz-Meta-Test", q.Get("X-Amz-Signature"))
		if r.Method == http.MethodGet {
			w.Header().Set("ETag", "\"part-1\"")
			w.Header().Set("X-Amz-Version-Id", "1")
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprintf(w, `<Error><Code>AccessDenied</Code><Message>expired: %s</Message></Error>`, q.Get("X-Amz-Signature"))
			return
		}
		w.WriteHeader(http.StatusTemporaryRedirect)
		fmt.Fprint(w, "redirect")
	}))
	defer server.Close()

	p := conformanceTestProfile(server.URL)
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		input := map[string]interface{}{"Method": method, "Bucket": "bucket", "Key": "key", "ExpiresIn": 59, "DelayMs": 15}
		var extra map[string]interface{}
		if method == http.MethodGet {
			input["VersionId"] = "1"
		} else {
			input["ContentType"] = "text/x-test"
			extra = map[string]interface{}{"body": map[string]interface{}{"text": putBody}}
		}
		callStarted := time.Now()
		result := callConformance(t, p, presignedRequestOp, input, extra)
		callMs := float64(time.Since(callStarted)) / float64(time.Millisecond)
		if callMs < 15 || result["latencyMs"].(float64) > callMs-14 {
			t.Error("DelayMs must be applied before the request and excluded from latencyMs")
		}
		if method == http.MethodGet {
			assertConformanceOutcome(t, result, "service", 403, 1)
			if result["errorCode"] != "AccessDenied" || result["errorMessage"] != "expired: [redacted]" {
				t.Error("presigned GET lost its redacted XML error")
			}
		} else {
			assertConformanceOutcome(t, result, "service", 307, 1)
			if asMap(asMap(result["output"])["Body"])["length"] != int64(len("redirect")) {
				t.Error("presigned PUT response digest length mismatch")
			}
		}
		output := asMap(result["output"])
		presign := asMap(output["Presign"])
		keys := presign["QueryKeys"].([]string)
		if presign["Method"] != method || presign["Scheme"] != "http" || presign["Host"] != strings.TrimPrefix(server.URL, "http://") ||
			presign["PresignMs"].(float64) <= 0 || !slices.IsSorted(keys) || !slices.Contains(keys, "X-Amz-Signature") ||
			result["latencyMs"].(float64) < 0 || asMap(output["Body"])["sha256"] == nil {
			t.Error("presign projection, delay, or body digest mismatch")
		}
		wire, err := json.Marshal(redactEncryptionFields(result))
		if err != nil {
			t.Fatal(err)
		}
		for _, prohibited := range []string{"X-Amz-Signature=", "versionId=1", "fixture-session-token", "fixture-access-key", "fixture-secret-key"} {
			if strings.Contains(string(wire), prohibited) {
				t.Error("a signed URL or query value escaped into the result")
			}
		}
		headers := asMap(result["headers"])
		if headers["x-amz-meta-test"] != "[redacted]" {
			t.Error("a reflected signature escaped into an allowed header")
		}
		if headers["location"] != server.URL+"/bucket/key?[query]" {
			t.Error("reflected signed Location did not preserve only the path and query marker")
		}
		if method == http.MethodGet && (headers["etag"] != "\"part-1\"" || headers["x-amz-version-id"] != "1") {
			t.Error("presigned GET scrubbed the short version ID from response data")
		}
	}
	if sends.Load() != 2 {
		t.Errorf("presigned endpoint received %d requests, want 2", sends.Load())
	}
}

func TestConformanceCapabilitiesAndRequestErrors(t *testing.T) {
	for _, provider := range []string{"s3Compatible", "awsS3", "azureBlob", "googleCloudStorage"} {
		p := conformanceTestProfile("http://127.0.0.1:1")
		p["endpointType"] = provider
		params := map[string]interface{}{"profile": p, "input": map[string]interface{}{}}
		result, err := handleRequest(request{Method: "getCapabilities", Params: params})
		if err != nil {
			t.Fatal(err)
		}
		items := result["items"].([]map[string]interface{})
		index := slices.IndexFunc(items, func(item map[string]interface{}) bool { return item["key"] == "conformance.s3" })
		if index < 0 {
			t.Fatalf("conformance capability missing for %s", provider)
		}
		if provider == "s3Compatible" || provider == "awsS3" {
			item := items[index]
			if item["state"] != "supported" || item["version"] != 1 || item["sdk"] != conformanceSDK || len(item["ops"].([]string)) != 88 {
				t.Errorf("invalid conformance capability for %s", provider)
			}
		} else {
			if items[index]["state"] != "unsupported" {
				t.Errorf("conformance should be unsupported for %s", provider)
			}
			params["op"] = "HeadBucket"
			_, err := handleRequest(request{Method: "s3ConformanceOp", Params: params})
			assertConformanceRPCError(t, err, "unsupported_feature")
		}
	}
	params := map[string]interface{}{
		"profile": conformanceTestProfile("http://127.0.0.1:1"),
		"op":      "NotAnS3Operation", "input": map[string]interface{}{},
	}
	_, err := handleRequest(request{Method: "s3ConformanceOp", Params: params})
	assertConformanceRPCError(t, err, "unsupported_feature")
	params["op"] = "GetObject"
	params["input"] = map[string]interface{}{"SSECustomerKey": "must be rejected"}
	_, err = handleRequest(request{Method: "s3ConformanceOp", Params: params})
	assertConformanceRPCError(t, err, "invalid_request")
}

func TestConformanceTransportAndSecretRedaction(t *testing.T) {
	const secret = "fixture-secret-key"
	p := conformanceTestProfile("http://127.0.0.1:1")
	p["connectTimeoutSeconds"] = 1
	input := map[string]interface{}{"Bucket": "bucket", "Key": "key"}
	assertConformanceOutcome(t, callConformance(t, p, "GetObject", input, nil), "transport", 0, 1)

	key := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("z", 32)))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		const sse = "X-Amz-Server-Side-Encryption-Customer-"
		if r.Header.Get(sse+"Algorithm") != "AES256" || r.Header.Get(sse+"Key") != key || r.Header.Get(sse+"Key-Md5") == "" {
			t.Error("SDK did not send SSE-C algorithm, key, and digest")
		}
		w.Header().Set(sse+"Key", key)
		w.Header().Set(sse+"Algorithm", "AES256")
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprintf(w, `<Error><Code>AccessDenied</Code><Message>%s %s %s %s %s</Message></Error>`,
			key, secret, r.Header.Get("X-Amz-Security-Token"), r.Header.Get("Authorization"), strings.Repeat("é", 300))
	}))
	defer server.Close()
	p["endpointUrl"] = server.URL
	result := callConformance(t, p, "GetObjectAttributes", map[string]interface{}{
		"Bucket": "bucket", "Key": "key", "ObjectAttributes": []string{"ETag", "ObjectSize"},
	}, map[string]interface{}{"encryption": map[string]interface{}{"mode": "sse-c", "customerKey": key}})
	assertConformanceOutcome(t, result, "service", 403, 1)
	message := result["errorMessage"].(string)
	if !strings.HasPrefix(message, "[redacted] [redacted] [redacted] [redacted] ") ||
		len([]rune(message)) != 256 || asMap(result["headers"])["x-amz-server-side-encryption-customer-algorithm"] != "AES256" {
		t.Error("SSE-C response redaction or error message limit failed")
	}
	p["endpointUrl"] = "http://192.0.2.1"
	_, err := s3ConformanceOp(map[string]interface{}{"profile": p, "op": "GetObject", "input": input,
		"encryption": map[string]interface{}{"mode": "sse-c", "customerKey": key}})
	assertConformanceRPCError(t, err, "invalid_config")
}

func TestConformanceShortCredentialsPreserveTagsAndCORS(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		switch query := r.URL.Query(); {
		case query.Has("tagging"):
			fmt.Fprint(w, `<Tagging><TagSet><Tag><Key>sample</Key><Value>test</Value></Tag></TagSet></Tagging>`)
		case query.Has("cors"):
			w.Header().Set("Access-Control-Allow-Origin", "https://example.test")
			fmt.Fprint(w, `<CORSConfiguration><CORSRule><AllowedOrigin>https://example.test</AllowedOrigin><AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>`)
		case r.URL.Path == "/bucket/key":
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprintf(w, `<Error><Code>AccessDenied</Code><Message>%s x-amz-security-token: test Signature=hidden X-Amz-Signature=private HTTPS://example.test/key?private=value</Message></Error>`, r.Header.Get("Authorization"))
		default:
			t.Errorf("unexpected request path %s", r.URL.Path)
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer server.Close()
	p := conformanceTestProfile(server.URL)
	p["accessKey"], p["secretKey"], p["sessionToken"] = "test", "test", "test"

	tags := callConformance(t, p, "GetObjectTagging", map[string]interface{}{"Bucket": "bucket", "Key": "key"}, nil)
	assertConformanceOutcome(t, tags, "service", 200, 1)
	tag := asMap(asMap(tags["output"])["TagSet"].([]interface{})[0])
	if tag["Value"] != "test" {
		t.Error("short profile credentials changed the tag value")
	}

	cors := callConformance(t, p, "GetBucketCors", map[string]interface{}{"Bucket": "bucket"}, nil)
	assertConformanceOutcome(t, cors, "service", 200, 1)
	rule := asMap(asMap(cors["output"])["CORSRules"].([]interface{})[0])
	if rule["AllowedOrigins"].([]interface{})[0] != "https://example.test" ||
		asMap(cors["headers"])["access-control-allow-origin"] != "https://example.test" {
		t.Error("short profile credentials changed the CORS origin")
	}

	denied := callConformance(t, p, "GetObject", map[string]interface{}{"Bucket": "bucket", "Key": "key"}, nil)
	assertConformanceOutcome(t, denied, "service", 403, 1)
	if denied["errorMessage"] != "[redacted] x-amz-security-token: [redacted] Signature=[redacted] X-Amz-Signature=[redacted] [redacted]" {
		t.Error("diagnostic text exposed authentication material")
	}
}

type conformanceZeroReader struct{}

func (conformanceZeroReader) Read(buf []byte) (int, error) {
	clear(buf)
	return len(buf), nil
}

func TestConformanceDigestStopsAtLimit(t *testing.T) {
	body := io.LimitReader(conformanceZeroReader{}, conformanceMaxRead+5)
	digest, err := conformanceDigest(io.NopCloser(body), conformanceMaxRead+5, nil)
	if err != nil || digest["truncated"] != true || digest["length"] != int64(conformanceMaxRead) || body.(*io.LimitedReader).N != 5 {
		t.Fatal("digest did not stop at the body limit")
	}
}

func TestConformanceHeaderCaps(t *testing.T) {
	observation := conformanceObservation{headers: make(http.Header)}
	observation.headers.Set("Content-Disposition", strings.Repeat("é", 513))
	for i := range 20 {
		observation.headers.Set(fmt.Sprintf("x-amz-meta-fixture-%02d", i), "sample")
	}
	headers := observation.responseHeaders()
	if len(headers) != 17 || len([]rune(headers["content-disposition"].(string))) != 512 {
		t.Fatal("metadata count or header value length limit failed")
	}
	for i := range 50 {
		observation.headers.Set(fmt.Sprintf("x-amz-checksum-fixture-%02d", i), "sample")
	}
	headers = observation.responseHeaders()
	if len(headers) != 48 || headers["x-amz-checksum-fixture-00"] != "sample" {
		t.Fatal("total header count limit dropped expected checksums")
	}
}
