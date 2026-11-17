package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const gcsSpecialName = "folder/a space /%#?+日本語.txt"
const gcsSpecialEscapedName = "folder%2Fa%20space%20%2F%25%23%3F%2B%E6%97%A5%E6%9C%AC%E8%AA%9E.txt"

type gcsFixtureRequest struct {
	method, path string
	query        url.Values
	header       http.Header
	body         []byte
}

type gcsFixture struct {
	t      *testing.T
	server *httptest.Server
	key    *rsa.PrivateKey
	pem    string
	params map[string]interface{}
	mu     sync.Mutex

	requests                             []gcsFixtureRequest
	objects                              map[string][]byte
	generation                           string
	tokens, refreshes, probes, cancelled int
	rewriteCalls, chunks                 int
	sessionData                          []byte
	sessionSize                          int64
	sessionName                          string
	versioning                           bool
	refreshOnce, conflict, repeatedPage  bool
	replaceDuringRewrite                 bool
	rejectAuth                           bool
	failChunk, failAlways, badOffset     bool
	badRange, shortRange, longRange      bool
	failRangeOnce                        bool
	rangeAttempts                        map[string]int
	mutateSource                         func()
}

func newGCSFixture(t *testing.T) *gcsFixture {
	return newGCSFixtureWithTransport(t, false)
}

// Socket-free adapter checks complement the real HTTP fixtures, including in
// environments that cannot bind localhost. Interrupted TCP bodies are covered
// by the real server tests above, not simulated by this transport.
type gcsFixtureTransport struct{ fixture *gcsFixture }

func (rt gcsFixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if err := r.Context().Err(); err != nil {
		return nil, err
	}
	if r.Body == nil {
		r.Body = http.NoBody
	}
	defer r.Body.Close()
	recorder := httptest.NewRecorder()
	rt.fixture.serveHTTP(recorder, r)
	if recorder.Header().Get("X-Fixture-Interrupted") != "" {
		return nil, io.ErrUnexpectedEOF
	}
	return recorder.Result(), nil
}

func newGCSFixtureWithTransport(t *testing.T, inProcess bool) *gcsFixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	f := &gcsFixture{t: t, key: key, pem: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), objects: map[string][]byte{gcsSpecialName: []byte("hello GCS")}, generation: "17", rangeAttempts: map[string]int{}}
	if inProcess {
		f.server = &httptest.Server{URL: "https://gcs.fixture.invalid"}
	} else {
		f.server = httptest.NewServer(http.HandlerFunc(f.serveHTTP))
		t.Cleanup(f.server.Close)
	}
	account, _ := json.Marshal(map[string]string{"client_email": "fixture@example.iam.gserviceaccount.com", "private_key": f.pem, "project_id": "fixture-project", "token_uri": f.server.URL + "/token"})
	f.params = map[string]interface{}{"endpointType": gcsEndpointType, "endpointUrl": f.server.URL, "secretKey": string(account), "accessKey": "ignored@example.com", "region": "EU", "maxAttempts": 3, "maxConcurrentRequests": 2}
	if inProcess {
		f.params["diagnostics"] = map[string]interface{}{"enableApiLogging": true, "enableDebugLogging": true}
		p, _ := parseProfile(f.params)
		c, _, err := buildGCSClient(p)
		if err != nil {
			t.Fatal(err)
		}
		c.httpClient.CloseIdleConnections()
		c.httpClient.Transport = loggingRoundTripper{base: gcsFixtureTransport{fixture: f}, diagnostics: diagnosticsConfig{EnableAPILogging: true, EnableDebugLogging: true}}
	}
	t.Cleanup(func() {
		p, err := parseProfile(f.params)
		if err == nil {
			gcsClientCache.Lock()
			if c := gcsClientCache.clients[p]; c != nil {
				c.httpClient.CloseIdleConnections()
			}
			gcsClientCache.Unlock()
		}
	})
	return f
}

func (f *gcsFixture) call(method string, extra map[string]interface{}) (map[string]interface{}, error) {
	params := map[string]interface{}{"profile": f.params, "bucketName": "bucket"}
	for k, v := range extra {
		params[k] = v
	}
	return dispatchRequest(request{Method: method, Params: params})
}

func (f *gcsFixture) mustCall(method string, extra map[string]interface{}) map[string]interface{} {
	f.t.Helper()
	result, err := f.call(method, extra)
	if err != nil {
		f.t.Fatalf("%s: %v", method, err)
	}
	return result
}

func gcsTestJSON(w http.ResponseWriter, value interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func (f *gcsFixture) metadata(name, generation string) map[string]interface{} {
	if generation == "" {
		generation = f.generation
	}
	return map[string]interface{}{"name": name, "generation": generation, "size": fmt.Sprint(len(f.objects[name])), "contentType": "text/plain", "storageClass": "STANDARD", "etag": "fixture-etag", "updated": "2026-11-15T12:00:00Z", "metadata": map[string]string{"custom": "value"}}
}

func (f *gcsFixture) serveHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	query := r.URL.Query()
	entry := gcsFixtureRequest{method: r.Method, path: r.URL.EscapedPath(), query: query, header: r.Header.Clone()}
	// A failed chunk is only partly read before the connection is cut. The
	// server commits a prefix so replaying the original offset would fail.
	if r.URL.Path != "/session/private-session-secret" || r.Method != http.MethodPut || strings.HasPrefix(r.Header.Get("Content-Range"), "bytes */") || !f.failChunk || f.chunks > 0 {
		entry.body, _ = io.ReadAll(r.Body)
	}
	f.requests = append(f.requests, entry)
	if r.URL.Path == "/token" {
		f.tokens++
		values, err := url.ParseQuery(string(entry.body))
		if err != nil || values.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
			f.t.Error("invalid JWT grant")
		}
		parts := strings.Split(values.Get("assertion"), ".")
		if len(parts) != 3 {
			f.t.Error("missing JWT assertion")
			w.WriteHeader(400)
			return
		}
		header, _ := base64.RawURLEncoding.DecodeString(parts[0])
		claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var h, c map[string]interface{}
		_ = json.Unmarshal(header, &h)
		_ = json.Unmarshal(claims, &c)
		hash := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
		if h["alg"] != "RS256" || h["typ"] != "JWT" || c["iss"] != "fixture@example.iam.gserviceaccount.com" || c["aud"] != f.server.URL+"/token" || c["scope"] != "https://www.googleapis.com/auth/devstorage.read_write" || asFloat(c["exp"])-asFloat(c["iat"]) != 3600 || rsa.VerifyPKCS1v15(&f.key.PublicKey, crypto.SHA256, hash[:], sig) != nil {
			f.t.Error("invalid JWT claims or RS256 signature")
		}
		gcsTestJSON(w, map[string]interface{}{"access_token": fmt.Sprintf("fixture-access-token-secret-%d", f.tokens), "expires_in": 3600, "token_type": "Bearer"})
		return
	}
	if r.Header.Get("Authorization") != fmt.Sprintf("Bearer fixture-access-token-secret-%d", f.tokens) || f.tokens == 0 {
		f.t.Error("missing or stale bearer token")
		w.WriteHeader(403)
		return
	}
	if f.rejectAuth || (f.refreshOnce && f.refreshes == 0) {
		f.refreshes++
		w.WriteHeader(401)
		gcsTestJSON(w, map[string]interface{}{"error": map[string]interface{}{"message": "fixture-access-token-secret-1"}})
		return
	}
	if r.URL.Path == "/session/private-session-secret" {
		switch r.Method {
		case http.MethodDelete:
			f.cancelled++
			w.WriteHeader(499)
		case http.MethodPut:
			if strings.HasPrefix(r.Header.Get("Content-Range"), "bytes */") {
				f.probes++
				if r.Header.Get("Content-Range") != fmt.Sprintf("bytes */%d", f.sessionSize) || r.ContentLength != 0 {
					f.t.Error("invalid status probe")
				}
				f.sessionStatus(w)
				return
			}
			var start, end, total int64
			_, err := fmt.Sscanf(r.Header.Get("Content-Range"), "bytes %d-%d/%d", &start, &end, &total)
			if err != nil || start != int64(len(f.sessionData)) || total != f.sessionSize || end-start+1 != r.ContentLength || (end+1 != total && r.ContentLength%gcsChunkAlignment != 0) {
				f.t.Errorf("bad upload chunk range %q at offset %d", r.Header.Get("Content-Range"), len(f.sessionData))
				w.WriteHeader(400)
				return
			}
			f.chunks++
			if f.failAlways {
				w.WriteHeader(503)
				return
			}
			if f.failChunk && f.chunks == 1 {
				partial := make([]byte, gcsChunkAlignment)
				if _, err := io.ReadFull(r.Body, partial); err != nil {
					f.t.Error(err)
				}
				f.sessionData = append(f.sessionData, partial...)
				hijacker, ok := w.(http.Hijacker)
				if !ok {
					// The in-process transport exposes the same failed-response
					// condition after committing the prefix, without a TCP socket.
					w.Header().Set("X-Fixture-Interrupted", "true")
					return
				}
				conn, _, err := hijacker.Hijack()
				if err != nil {
					f.t.Error(err)
				} else {
					_ = conn.Close()
				}
				return
			}
			f.sessionData = append(f.sessionData, entry.body...)
			if f.mutateSource != nil {
				f.mutateSource()
				f.mutateSource = nil
			}
			f.sessionStatus(w)
		default:
			f.t.Errorf("unexpected session method %s", r.Method)
		}
		return
	}
	if r.URL.Path == "/storage/v1/b" {
		if query.Get("project") != "fixture-project" {
			f.t.Error("missing key-file project")
		}
		if r.Method == http.MethodPost {
			var body map[string]interface{}
			_ = json.Unmarshal(entry.body, &body)
			if body["name"] != "bucket" || body["location"] != "EU" {
				f.t.Errorf("invalid bucket body: %v", body)
			}
			gcsTestJSON(w, map[string]interface{}{"name": "bucket", "location": "EU", "timeCreated": "2026-11-15T12:00:00Z"})
			return
		}
		if query.Get("maxResults") != "1000" {
			f.t.Error("unbounded bucket page")
		}
		if query.Get("pageToken") == "" || f.repeatedPage {
			gcsTestJSON(w, map[string]interface{}{"items": []interface{}{}, "nextPageToken": "bucket-next"})
		} else {
			if query.Get("pageToken") != "bucket-next" {
				f.t.Error("wrong bucket cursor")
			}
			gcsTestJSON(w, map[string]interface{}{"items": []interface{}{map[string]interface{}{"name": "bucket", "location": "EU", "versioning": map[string]bool{"enabled": true}}}})
		}
		return
	}
	if r.URL.Path == "/storage/v1/b/bucket" {
		if r.Method == http.MethodDelete {
			w.WriteHeader(204)
			return
		}
		if r.Method == http.MethodPatch {
			var body struct{ Versioning struct{ Enabled bool } }
			_ = json.Unmarshal(entry.body, &body)
			f.versioning = body.Versioning.Enabled
		}
		gcsTestJSON(w, map[string]interface{}{"name": "bucket", "location": "EU", "versioning": map[string]bool{"enabled": f.versioning}})
		return
	}
	if r.URL.Path == "/storage/v1/b/bucket/o" {
		if query.Get("maxResults") != "1000" {
			f.t.Error("unbounded object page")
		}
		if query.Get("pageToken") == "" || f.repeatedPage {
			gcsTestJSON(w, map[string]interface{}{"nextPageToken": "object-next"})
			return
		}
		if query.Get("pageToken") != "object-next" {
			f.t.Error("wrong object cursor")
		}
		if query.Get("versions") == "true" {
			gcsTestJSON(w, map[string]interface{}{"items": []interface{}{f.metadata(gcsSpecialName, "999"), f.metadata(gcsSpecialName, f.generation)}})
		} else {
			gcsTestJSON(w, map[string]interface{}{"items": []interface{}{f.metadata(gcsSpecialName, "")}, "prefixes": []string{"folder/"}})
		}
		return
	}
	if strings.HasPrefix(r.URL.Path, "/upload/storage/v1/b/bucket/o") {
		name := query.Get("name")
		if r.Method != http.MethodPost || r.Header.Get("Content-Type") == "" {
			f.t.Error("invalid upload initiation")
		}
		if query.Get("uploadType") == "resumable" {
			f.sessionSize, _ = strconv.ParseInt(r.Header.Get("X-Upload-Content-Length"), 10, 64)
			f.sessionName = name
			if string(entry.body) != "{}" || r.Header.Get("X-Upload-Content-Type") != "application/octet-stream" {
				f.t.Error("invalid resumable initiation body/headers")
			}
			w.Header().Set("Location", f.server.URL+"/session/private-session-secret?upload_id=session-secret-query")
			gcsTestJSON(w, map[string]interface{}{})
		} else if query.Get("uploadType") == "media" {
			f.objects[name] = entry.body
			gcsTestJSON(w, f.metadata(name, ""))
		} else {
			f.t.Error("unexpected uploadType")
			w.WriteHeader(400)
		}
		return
	}
	if strings.Contains(r.URL.Path, "/rewriteTo/") {
		f.rewriteCalls++
		expected := "/storage/v1/b/bucket/o/" + gcsEscape(gcsSpecialName) + "/rewriteTo/b/target/o/" + gcsEscape("copied "+gcsSpecialName)
		if entry.path != expected || query.Get("sourceGeneration") != "17" || query.Get("ifSourceGenerationMatch") != "17" || r.Method != http.MethodPost || string(entry.body) != "{}" {
			f.t.Errorf("invalid rewrite request: %s %v", entry.path, query)
		}
		if query.Get("rewriteToken") == "" {
			gcsTestJSON(w, map[string]interface{}{"done": false, "rewriteToken": "rewrite-next"})
		} else {
			if query.Get("rewriteToken") != "rewrite-next" {
				f.t.Error("wrong rewrite token")
			}
			if f.replaceDuringRewrite {
				f.generation = "18"
			}
			gcsTestJSON(w, map[string]interface{}{"done": true})
		}
		return
	}
	if strings.HasPrefix(r.URL.Path, "/storage/v1/b/bucket/o/") {
		name := strings.TrimPrefix(r.URL.Path, "/storage/v1/b/bucket/o/")
		if entry.path != "/storage/v1/b/bucket/o/"+gcsEscape(name) {
			f.t.Errorf("object is not a single escaped path segment: %s", entry.path)
		}
		if r.Method == http.MethodDelete {
			if f.conflict || (query.Get("ifGenerationMatch") != "" && query.Get("generation") == "" && query.Get("ifGenerationMatch") != f.generation) {
				w.WriteHeader(412)
				gcsTestJSON(w, map[string]interface{}{"error": map[string]interface{}{"errors": []interface{}{map[string]string{"reason": "conditionNotMet"}}, "message": f.pem}})
				return
			}
			w.WriteHeader(204)
			return
		}
		if _, exists := f.objects[name]; !exists {
			w.WriteHeader(404)
			return
		}
		if query.Get("alt") != "media" {
			gcsTestJSON(w, f.metadata(name, query.Get("generation")))
			return
		}
		if query.Get("generation") != f.generation || r.Header.Get("Accept-Encoding") != "identity" {
			f.t.Error("media read lost generation or identity encoding")
		}
		var start, end int
		if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end); err != nil {
			f.t.Error("missing range")
			w.WriteHeader(400)
			return
		}
		f.rangeAttempts[r.Header.Get("Range")]++
		data := f.objects[name]
		w.Header().Set("Content-Length", fmt.Sprint(end-start+1))
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)))
		if f.badRange {
			w.Header().Set("Content-Range", "bytes 1-2/3")
		}
		if f.longRange {
			w.Header().Set("Content-Length", fmt.Sprint(end-start+2))
		}
		w.WriteHeader(206)
		if f.shortRange || (f.failRangeOnce && f.rangeAttempts[r.Header.Get("Range")] == 1) {
			_, _ = w.Write(data[start : start+(end-start+1)/2])
			return
		}
		_, _ = w.Write(data[start : end+1])
		return
	}
	f.t.Errorf("unexpected GCS request: %s %s", r.Method, r.URL)
	w.WriteHeader(404)
}

func (f *gcsFixture) sessionStatus(w http.ResponseWriter) {
	if f.badOffset {
		w.Header().Set("Range", "bytes=5-7")
		w.WriteHeader(308)
		return
	}
	if int64(len(f.sessionData)) == f.sessionSize {
		f.objects[f.sessionName] = append([]byte(nil), f.sessionData...)
		gcsTestJSON(w, f.metadata(f.sessionName, ""))
		return
	}
	if len(f.sessionData) > 0 {
		w.Header().Set("Range", fmt.Sprintf("bytes=0-%d", len(f.sessionData)-1))
	}
	w.WriteHeader(308)
}

func TestGCSBucketsAuthRefreshAndPagination(t *testing.T) {
	f := newGCSFixture(t)
	f.refreshOnce = true
	result := f.mustCall("testProfile", nil)
	if !asBool(result["ok"]) || asInt(result["bucketCount"]) != 1 || f.tokens != 2 {
		t.Fatalf("profile/auth: %v tokens=%d", result, f.tokens)
	}
	if got := f.mustCall("listBuckets", nil); len(got["items"].([]map[string]interface{})) != 1 || f.tokens != 2 {
		t.Fatalf("bucket paging/token cache: %v tokens=%d", got, f.tokens)
	}
	p, _ := parseProfile(f.params)
	c, _, _ := buildGCSClient(p)
	c.tokenMu.Lock()
	c.expires = time.Now().Add(30 * time.Second)
	c.tokenMu.Unlock()
	f.mustCall("listBuckets", nil)
	if f.tokens != 3 {
		t.Fatalf("near-expiry token not refreshed: %d", f.tokens)
	}
	f.mustCall("createBucket", nil)
	if got := f.mustCall("setBucketVersioning", map[string]interface{}{"enabled": true}); !asBool(got["versioningEnabled"]) {
		t.Fatal(got)
	}
	if got := f.mustCall("getBucketAdminState", nil); got["versioningStatus"] != "Enabled" {
		t.Fatal(got)
	}
	if got := f.mustCall("setBucketVersioning", map[string]interface{}{"enabled": false}); asBool(got["versioningEnabled"]) {
		t.Fatal(got)
	}
	f.mustCall("deleteBucket", nil)
	before := len(f.requests)
	f.params["knownBucket"] = "bucket"
	f.mustCall("listBuckets", nil)
	f.mustCall("testProfile", nil)
	for _, r := range f.requests[before:] {
		if r.path != "/token" && r.path != "/storage/v1/b/bucket" {
			t.Fatalf("known bucket performed project-wide listing: %+v", r)
		}
	}
}

func TestGCSObjectMethodsAndOpaqueVersions(t *testing.T) {
	f := newGCSFixture(t)
	for _, method := range []string{"listObjects", "listObjectVersions"} {
		t.Run(method, func(t *testing.T) {
			params := map[string]interface{}{"key": gcsSpecialName, "prefix": "folder/"}
			first := f.mustCall(method, params)
			cursorKey := "nextCursor"
			if method == "listObjectVersions" {
				cursorKey = "cursor"
			}
			if len(first["items"].([]map[string]interface{})) != 0 || !asBool(asMap(first[cursorKey])["hasMore"]) {
				t.Fatalf("empty page lost continuation: %v", first)
			}
			params["cursor"] = first[cursorKey]
			next := f.mustCall(method, params)
			if asBool(asMap(next[cursorKey])["hasMore"]) {
				t.Fatal(next)
			}
			items := next["items"].([]map[string]interface{})
			if len(items) != 2 {
				t.Fatal(items)
			}
			if method == "listObjectVersions" {
				latest := map[string]bool{}
				for _, item := range items {
					latest[asString(item["versionId"])] = asBool(item["latest"])
					if asBool(item["deleteMarker"]) {
						t.Fatal("GCS fabricated a delete marker")
					}
				}
				if !reflect.DeepEqual(latest, map[string]bool{"999": false, "17": true}) || next["deleteMarkerCount"] != 0 {
					t.Fatalf("generation IDs treated as ordered: %v", next)
				}
			} else if items[0]["key"] != "folder/" || items[1]["key"] != gcsSpecialName {
				t.Fatal(items)
			}
		})
	}
	details := f.mustCall("getObjectDetails", map[string]interface{}{"key": gcsSpecialName, "versionId": "999"})
	if details["versionId"] != "999" || asStringMap(details["metadata"])["custom"] != "value" || asStringMap(details["headers"])["Content-Type"] != "text/plain" {
		t.Fatal(details)
	}
	if f.requests[len(f.requests)-1].query.Get("generation") != "999" {
		t.Fatal("details omitted generation selector")
	}
	folder := f.mustCall("createFolder", map[string]interface{}{"key": gcsSpecialName})
	if folder["key"] != gcsSpecialName+"/" || len(f.objects[gcsSpecialName+"/"]) != 0 {
		t.Fatal(folder)
	}
	deleted := f.mustCall("deleteObjects", map[string]interface{}{"keys": []interface{}{gcsSpecialName}})
	if deleted["successCount"] != 1 {
		t.Fatal(deleted)
	}
	deleted = f.mustCall("deleteObjectVersions", map[string]interface{}{"versions": []interface{}{map[string]interface{}{"key": gcsSpecialName, "versionId": "999"}}})
	if deleted["successCount"] != 1 || f.requests[len(f.requests)-1].query.Get("generation") != "999" {
		t.Fatal(deleted)
	}
}

func TestGCSRepeatedCursors(t *testing.T) {
	for _, method := range []string{"listBuckets", "listObjects", "listObjectVersions"} {
		t.Run(method, func(t *testing.T) {
			f := newGCSFixture(t)
			f.repeatedPage = true
			cursor := "object-next"
			_, err := f.call(method, map[string]interface{}{"cursor": map[string]interface{}{"value": cursor}})
			if err == nil || mapError(err)["code"] != "invalid_response" {
				t.Fatalf("repeated cursor: %v", err)
			}
		})
	}
}

func TestGCSRewriteAndConditionalMove(t *testing.T) {
	for _, method := range []string{"copyObject", "moveObject"} {
		for _, conflict := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/conflict=%v", method, conflict), func(t *testing.T) {
				f := newGCSFixture(t)
				f.conflict = conflict
				result := f.mustCall(method, map[string]interface{}{"sourceBucketName": "bucket", "sourceKey": gcsSpecialName, "destinationBucketName": "target", "destinationKey": "copied " + gcsSpecialName})
				if f.rewriteCalls != 2 {
					t.Fatalf("rewrite did not loop: %d", f.rewriteCalls)
				}
				last := f.requests[len(f.requests)-1]
				if method == "moveObject" {
					if last.method != http.MethodDelete || last.query.Get("generation") != "" || last.query.Get("ifGenerationMatch") != "17" {
						t.Fatalf("unsafe move delete: %+v", last)
					}
					if conflict {
						failure := result["failures"].([]map[string]interface{})[0]
						if !asBool(result["sourceRetained"]) || result["copiedCount"] != 1 || failure["code"] != "object_conflict" || asInt(asMap(failure["details"])["httpStatus"]) != 412 {
							t.Fatal(result)
						}
					}
				} else if last.method == http.MethodDelete {
					t.Fatal("copy deleted source")
				}
			})
		}
	}
}

func TestGCSV4SignedURLVerifiesWithPublicKey(t *testing.T) {
	f := newGCSFixtureWithTransport(t, true)
	result := f.mustCall("generatePresignedUrl", map[string]interface{}{"key": gcsSpecialName, "expirationSeconds": 99999999, "versionId": "999"})
	u, err := url.Parse(asString(result["url"]))
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if q.Get("X-Goog-Algorithm") != "GOOG4-RSA-SHA256" || q.Get("X-Goog-Expires") != "604800" || q.Get("X-Goog-SignedHeaders") != "host" || q.Get("generation") != "999" || u.EscapedPath() != "/bucket/"+gcsSpecialEscapedName {
		t.Fatalf("invalid signed URL fields: %v", q)
	}
	signature, err := hex.DecodeString(q.Get("X-Goog-Signature"))
	if err != nil {
		t.Fatal(err)
	}
	q.Del("X-Goog-Signature")
	canonical := "GET\n" + u.EscapedPath() + "\n" + strings.ReplaceAll(q.Encode(), "+", "%20") + "\nhost:" + u.Host + "\n\nhost\nUNSIGNED-PAYLOAD"
	requestHash := sha256.Sum256([]byte(canonical))
	scope := strings.SplitN(q.Get("X-Goog-Credential"), "/", 2)
	if len(scope) != 2 || scope[0] != "fixture@example.iam.gserviceaccount.com" || !strings.HasSuffix(scope[1], "/auto/storage/goog4_request") {
		t.Fatal("invalid credential scope")
	}
	toSign := "GOOG4-RSA-SHA256\n" + q.Get("X-Goog-Date") + "\n" + scope[1] + "\n" + hex.EncodeToString(requestHash[:])
	digest := sha256.Sum256([]byte(toSign))
	if err = rsa.VerifyPKCS1v15(&f.key.PublicKey, crypto.SHA256, digest[:], signature); err != nil {
		t.Fatalf("V4 signature verification failed: %v", err)
	}
	if len(f.requests) != 0 {
		t.Fatal("local URL signing contacted the network")
	}
}

func TestGCSCapabilitiesIsolationAndInvalidConfig(t *testing.T) {
	f := newGCSFixtureWithTransport(t, true)
	capabilities := f.mustCall("getCapabilities", nil)["items"].([]map[string]interface{})
	states := map[string]string{}
	for _, item := range capabilities {
		states[asString(item["key"])] = asString(item["state"])
		if item["state"] == "unsupported" && asString(item["reason"]) == "" {
			t.Fatal("unsupported capability omitted reason")
		}
	}
	for _, key := range []string{"bucket.versioning", "object.copy_move", "object.clientEncryption"} {
		if states[key] != "supported" {
			t.Fatalf("missing capability %s", key)
		}
	}
	for _, key := range []string{"bucket.lifecycle", "bucket.policy", "bucket.cors", "bucket.encryption", "bucket.tagging", "object.encryption.sse-s3", "object.encryption.sse-kms", "object.encryption.dsse-kms", "object.encryption.sse-c", "object.encryption.azure-scope", "object.encryption.azure-cpk", "benchmark", "tools.bulk-delete", "storage.admin"} {
		if states[key] != "unsupported" {
			t.Fatalf("incorrect capability %s: %s", key, states[key])
		}
	}
	for _, method := range []string{"putBucketLifecycle", "deleteBucketLifecycle", "putBucketPolicy", "deleteBucketPolicy", "putBucketCors", "deleteBucketCors", "putBucketEncryption", "deleteBucketEncryption", "putBucketTagging", "deleteBucketTagging", "runPutTestData", "runDeleteAll", "startBenchmark", "getBenchmarkStatus", "pauseBenchmark", "resumeBenchmark", "stopBenchmark", "exportBenchmarkResults", "storageAction", "cancelToolExecution", "cancelTransfer", "pauseTransfer", "resumeTransfer"} {
		_, err := f.call(method, nil)
		if err == nil || mapError(err)["code"] != "unsupported_feature" {
			t.Fatalf("%s escaped into S3: %v", method, err)
		}
	}
	for _, field := range []string{"encryption", "sourceEncryption"} {
		_, err := f.call("getObjectDetails", map[string]interface{}{field: map[string]interface{}{"mode": "bucketDefault"}, "key": gcsSpecialName})
		if err == nil || mapError(err)["code"] != "invalid_config" {
			t.Fatalf("accepted GCS object encryption: %v", err)
		}
	}
	for _, method := range []string{"listBuckets", "getCapabilities", "startBenchmark"} {
		_, err := dispatchRequest(request{Method: method, Params: map[string]interface{}{"profile": map[string]interface{}{"endpointType": "madeUpProvider"}}})
		if err == nil || mapError(err)["code"] != "invalid_config" {
			t.Fatalf("unknown provider reached S3: %v", err)
		}
	}
	for _, value := range []string{"broken KEYSECRET", `{"client_email":"KEYSECRET"}`, strings.Replace(asString(f.params["secretKey"]), "PRIVATE KEY", "BROKEN KEYSECRET", -1)} {
		f.params["secretKey"] = value
		_, err := f.call("listBuckets", nil)
		if err == nil || mapError(err)["code"] != "invalid_config" || strings.Contains(mustJSONString(mapError(err)), "KEYSECRET") {
			t.Fatalf("malformed key was accepted or echoed: %v", err)
		}
	}
	if len(f.requests) != 0 {
		t.Fatal("invalid/unsupported request contacted provider")
	}
	profile, err := parseProfile(map[string]interface{}{"endpointType": gcsEndpointType, "secretKey": "invalid"})
	if err != nil || profile.Region != "" {
		t.Fatalf("GCS default URL/empty region not accepted: %+v %v", profile, err)
	}
}

func TestGCSErrorMapping(t *testing.T) {
	for status, code := range map[int]string{401: "auth_failed", 403: "auth_failed", 404: "not_found", 409: "object_conflict", 412: "object_conflict", 429: "throttled", 408: "timeout", 504: "timeout"} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			resp := &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(`{"error":{"message":"sensitive server text","errors":[{"reason":"conditionNotMet"}]}}`))}
			mapped := mapError(gcsResponseError(resp))
			details := asMap(mapped["details"])
			if mapped["code"] != code || details["provider"] != "gcs" || details["httpStatus"] != status || details["reason"] != "conditionNotMet" || strings.Contains(mustJSONString(mapped), "sensitive") {
				t.Fatal(mapped)
			}
		})
	}
	if got := mapError(gcsTransportError(errBodyStalled))["code"]; got != "timeout" {
		t.Fatalf("timeout mapped to %v", got)
	}
	for _, err := range []error{errBodyStalled, context.DeadlineExceeded, context.Canceled} {
		response := &http.Response{StatusCode: 200, Body: gcsErrorBody{err}}
		var target map[string]interface{}
		if got := gcsDecode(response, &target); got == nil || mapError(got)["code"] != mapError(gcsTransportError(err))["code"] {
			t.Fatalf("JSON body timeout/cancellation was lost: %v", got)
		}
	}
	wrapped := &url.Error{Op: "PUT", URL: "https://example.invalid/private-session-secret", Err: fmt.Errorf("session-secret-query")}
	if strings.Contains(mustJSONString(mapError(gcsTransportError(wrapped))), "secret") {
		t.Fatal("HTTP transport error leaked session credentials")
	}
}

type gcsErrorBody struct{ err error }

func (b gcsErrorBody) Read([]byte) (int, error) { return 0, b.err }
func (b gcsErrorBody) Close() error             { return nil }

func TestGCSPathEncodingAndDefaultEndpoint(t *testing.T) {
	base, _ := url.Parse("https://gcs.fixture.invalid/base")
	c := &gcsClient{base: base}
	for name, escaped := range map[string]string{"a b": "a%20b", "a/b": "a%2Fb", "a%b": "a%25b", "a#b": "a%23b", "a?b": "a%3Fb", "a+b": "a%2Bb", "日本語": "%E6%97%A5%E6%9C%AC%E8%AA%9E", gcsSpecialName: gcsSpecialEscapedName} {
		u := c.objectURL("bucket", name)
		if u.EscapedPath() != "/base/storage/v1/b/bucket/o/"+escaped || u.RawQuery != "" || u.Fragment != "" {
			t.Fatalf("incorrect object path encoding: %s", u)
		}
	}
	f := newGCSFixtureWithTransport(t, true)
	f.params["endpointUrl"], f.params["accessKey"], f.params["region"] = "", "", ""
	p, err := parseProfile(f.params)
	if err != nil {
		t.Fatal(err)
	}
	client, _, err := buildGCSClient(p)
	if err != nil || client.base.String() != "https://storage.googleapis.com" || client.email != "fixture@example.iam.gserviceaccount.com" || p.Region != "" {
		t.Fatalf("default endpoint/key-file identity: %v", err)
	}
	if _, err := parseProfile(map[string]interface{}{"endpointType": "unknown"}); err == nil || mapError(err)["code"] != "invalid_config" {
		t.Fatal("unknown profile type was accepted by the parser")
	}
}

func TestGCSRefreshOnlyOnce(t *testing.T) {
	f := newGCSFixture(t)
	p, _ := parseProfile(f.params)
	c, ctx, _ := buildGCSClient(p)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(401) }))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	_, err := c.do(ctx, http.MethodGet, u, nil, nil, 0, nil, true)
	if err == nil || mapError(err)["code"] != "auth_failed" || f.tokens != 2 {
		t.Fatalf("401 refresh count: tokens=%d err=%v", f.tokens, err)
	}
}

func TestGCSStreamingUploadsAndOffsetRecovery(t *testing.T) {
	testGCSStreamingUploadsAndOffsetRecovery(t, false)
}

func testGCSStreamingUploadsAndOffsetRecovery(t *testing.T, inProcess bool) {
	for _, size := range []int{0, 23, 1024 * 1024, 2*1024*1024 + 57} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			f := newGCSFixtureWithTransport(t, inProcess)
			f.failChunk = size > 1024*1024
			dir := t.TempDir()
			path := filepath.Join(dir, "source.bin")
			data := agePlaintext(int64(size))
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			result, err, events := captureDownloadEvents(t, func() (map[string]interface{}, error) {
				return f.call("startUpload", map[string]interface{}{"filePaths": []interface{}{path}, "prefix": "prefix/", "objectKeyByPath": map[string]interface{}{path: gcsSpecialName}, "multipartThresholdMiB": 1, "multipartChunkMiB": 1})
			})
			if err != nil {
				t.Fatal(err)
			}
			if result["status"] != "completed" || asInt(result["bytesTransferred"]) != size || asInt(result["itemsCompleted"]) != 1 || !bytes.Equal(f.objects["prefix/"+gcsSpecialName], data) {
				t.Fatalf("upload result/body: %v", result)
			}
			var previous int
			for _, event := range events {
				value := asInt(event["bytesTransferred"])
				if value < previous || value > size {
					t.Fatalf("non-monotonic/double-counted progress: %v", events)
				}
				previous = value
			}
			if size >= 1024*1024 && (f.chunks == 0 || f.cancelled != 0) {
				t.Fatalf("resumable threshold/cancellation: chunks=%d cancelled=%d", f.chunks, f.cancelled)
			}
			if f.failChunk {
				if f.probes != 1 {
					t.Fatalf("failed chunk was not probed exactly once: %d", f.probes)
				}
				found := false
				for _, request := range f.requests {
					if strings.HasPrefix(request.header.Get("Content-Range"), fmt.Sprintf("bytes %d-", gcsChunkAlignment)) {
						found = true
					}
				}
				if !found {
					t.Fatal("upload did not resume at service-reported partial offset")
				}
			} else if size < 1024*1024 && f.chunks != 0 {
				t.Fatal("small upload opened a resumable session")
			}
		})
	}
}

func TestGCSResumableFailureCancellationAndSourceIdentity(t *testing.T) {
	testGCSResumableFailureCancellationAndSourceIdentity(t, false)
}

func testGCSResumableFailureCancellationAndSourceIdentity(t *testing.T, inProcess bool) {
	for _, failure := range []string{"retry-budget", "offset", "source-replaced", "source-edited"} {
		t.Run(failure, func(t *testing.T) {
			f := newGCSFixtureWithTransport(t, inProcess)
			path := filepath.Join(t.TempDir(), "source")
			if err := os.WriteFile(path, agePlaintext(2*1024*1024+7), 0o600); err != nil {
				t.Fatal(err)
			}
			switch failure {
			case "retry-budget":
				f.failAlways = true
			case "offset":
				f.badOffset = true
			case "source-replaced":
				f.mutateSource = func() {
					replacement := path + ".replacement"
					if err := os.WriteFile(replacement, agePlaintext(2*1024*1024+7), 0o600); err != nil {
						t.Error(err)
					}
					if err := os.Rename(replacement, path); err != nil {
						t.Error(err)
					}
				}
			case "source-edited":
				f.mutateSource = func() {
					if err := os.WriteFile(path, []byte("changed"), 0o600); err != nil {
						t.Error(err)
					}
				}
			}
			_, err, _ := captureDownloadEvents(t, func() (map[string]interface{}, error) {
				return f.call("startUpload", map[string]interface{}{"filePaths": []interface{}{path}, "multipartThresholdMiB": 1, "multipartChunkMiB": 1})
			})
			if err == nil || f.cancelled != 1 {
				t.Fatalf("failed session not cancelled: cancelled=%d err=%v", f.cancelled, err)
			}
			if strings.HasPrefix(failure, "source-") && mapError(err)["code"] != "object_conflict" {
				t.Fatalf("source identity violation: %v", err)
			}
			if failure == "retry-budget" && (f.chunks != 3 || f.probes != 2) {
				t.Fatalf("wrong retry budget: chunks=%d probes=%d", f.chunks, f.probes)
			}
		})
	}
}

func TestGCSUploadSizingBoundaries(t *testing.T) {
	for requested, expected := range map[int64]int64{-1: 8 * 1024 * 1024, 0: 8 * 1024 * 1024, 1: gcsChunkAlignment, gcsChunkAlignment: gcsChunkAlignment, gcsChunkAlignment + 1: 2 * gcsChunkAlignment, 5 * 1024 * 1024 * 1024: 5 * 1024 * 1024 * 1024} {
		if got, err := gcsChunkSize(requested); err != nil || got != expected {
			t.Fatalf("chunk(%d)=%d,%v; want %d", requested, got, err, expected)
		}
	}
	if _, err := gcsChunkSize(5*1024*1024*1024 + 1); err == nil {
		t.Fatal("oversized chunk accepted")
	}
}

func TestGCSRangedDownloadsRetryAndAtomicPublication(t *testing.T) {
	testGCSRangedDownloadsRetryAndAtomicPublication(t, false)
}

func testGCSRangedDownloadsRetryAndAtomicPublication(t *testing.T, inProcess bool) {
	for _, size := range []int{0, 17, 2*1024*1024 + 31} {
		for _, policy := range []string{"keepBoth", "replace"} {
			t.Run(fmt.Sprintf("%d/%s", size, policy), func(t *testing.T) {
				f := newGCSFixtureWithTransport(t, inProcess)
				data := agePlaintext(int64(size))
				f.objects["object.bin"] = data
				f.failRangeOnce = true
				dir := t.TempDir()
				if err := os.WriteFile(filepath.Join(dir, "object.bin"), []byte("original"), 0o600); err != nil {
					t.Fatal(err)
				}
				result, err, events := captureDownloadEvents(t, func() (map[string]interface{}, error) {
					return f.call("startDownload", map[string]interface{}{"keys": []interface{}{"object.bin"}, "destinationPath": dir, "conflictPolicy": policy, "multipartThresholdMiB": 1, "multipartChunkMiB": 1})
				})
				if err != nil || result["status"] != "completed" || asInt(result["bytesTransferred"]) != size {
					t.Fatalf("download: %v %v", result, err)
				}
				name := "object.bin"
				if policy == "keepBoth" {
					name = "object (1).bin"
					original, _ := os.ReadFile(filepath.Join(dir, "object.bin"))
					if string(original) != "original" {
						t.Fatal("keepBoth replaced original")
					}
				}
				got, err := os.ReadFile(filepath.Join(dir, name))
				if err != nil || !bytes.Equal(got, data) {
					t.Fatalf("published bytes: %v", err)
				}
				for _, count := range f.rangeAttempts {
					if count != 2 {
						t.Fatalf("interrupted range attempts=%d", count)
					}
				}
				previous := 0
				for _, event := range events {
					value := asInt(event["bytesTransferred"])
					if value < previous || value > size {
						t.Fatalf("retried bytes counted twice: %v", events)
					}
					previous = value
				}
				entries, _ := os.ReadDir(dir)
				for _, entry := range entries {
					if strings.HasPrefix(entry.Name(), ".odb-") {
						t.Fatal("temporary download left behind")
					}
				}
			})
		}
	}
}

func TestGCSDownloadRejectsInvalidRangesWithoutPublishing(t *testing.T) {
	testGCSDownloadRejectsInvalidRangesWithoutPublishing(t, false)
}

func testGCSDownloadRejectsInvalidRangesWithoutPublishing(t *testing.T, inProcess bool) {
	for _, failure := range []string{"range", "short", "long"} {
		t.Run(failure, func(t *testing.T) {
			f := newGCSFixtureWithTransport(t, inProcess)
			f.badRange, f.shortRange, f.longRange = failure == "range", failure == "short", failure == "long"
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "original"), []byte("keep"), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err, _ := captureDownloadEvents(t, func() (map[string]interface{}, error) {
				return f.call("startDownload", map[string]interface{}{"keys": []interface{}{gcsSpecialName}, "destinationPath": dir, "conflictPolicy": "replace"})
			})
			if err == nil {
				t.Fatal("invalid range was accepted")
			}
			entries, _ := os.ReadDir(dir)
			if len(entries) != 1 || entries[0].Name() != "original" {
				t.Fatalf("failed download was published or leaked a temporary: %v", entries)
			}
		})
	}
}

func TestGCSClientEncryptionUsesExistingAgeFormat(t *testing.T) {
	testGCSClientEncryptionUsesExistingAgeFormat(t, false)
}

func testGCSClientEncryptionUsesExistingAgeFormat(t *testing.T, inProcess bool) {
	f := newGCSFixtureWithTransport(t, inProcess)
	v := ageVectors(t)[1]
	data := agePlaintext(v.PlaintextLength)
	path := filepath.Join(t.TempDir(), "plain.bin")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	params := ageUploadParams(v)
	params["filePaths"] = []interface{}{path}
	captureAgeOutput(t, v.FileKey, func() {
		f.mustCall("startUpload", params)
	})
	object := f.objects["plain.bin"]
	hash := sha256.Sum256(object)
	if hex.EncodeToString(hash[:]) != v.ObjectSha256 {
		t.Fatal("GCS did not preserve age ciphertext format")
	}
	dir := t.TempDir()
	captureAgeOutput(t, v.FileKey, func() {
		f.mustCall("startDownload", map[string]interface{}{"keys": []interface{}{"plain.bin"}, "destinationPath": dir, "clientEncryption": ageDownloadParams(v)})
	})
	got, err := os.ReadFile(filepath.Join(dir, "plain.bin"))
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("client encrypted round trip: %v", err)
	}
}

func TestGCSCredentialsSessionsAndSignedURLsAreAbsentFromLogs(t *testing.T) {
	testGCSCredentialsSessionsAndSignedURLsAreAbsentFromLogs(t, false)
}

func testGCSCredentialsSessionsAndSignedURLsAreAbsentFromLogs(t *testing.T, inProcess bool) {
	f := newGCSFixtureWithTransport(t, inProcess)
	f.params["diagnostics"] = map[string]interface{}{"enableApiLogging": true, "enableDebugLogging": true}
	f.failChunk = true
	path := filepath.Join(t.TempDir(), "source")
	if err := os.WriteFile(path, agePlaintext(2*1024*1024+7), 0o600); err != nil {
		t.Fatal(err)
	}
	output, err := os.CreateTemp(t.TempDir(), "gcs-output")
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	stdout, stderr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = output, output
	defer func() { os.Stdout, os.Stderr = stdout, stderr }()
	f.mustCall("startUpload", map[string]interface{}{"filePaths": []interface{}{path}, "multipartThresholdMiB": 1, "multipartChunkMiB": 1})
	f.conflict = true
	writeJSON(f.mustCall("deleteObjects", map[string]interface{}{"keys": []interface{}{gcsSpecialName}}))
	signed := f.mustCall("generatePresignedUrl", map[string]interface{}{"key": gcsSpecialName})
	// Session diagnostics must redact the full path as well as its query.
	p, _ := parseProfile(f.params)
	c, ctx, _ := buildGCSClient(p)
	ctx = context.WithValue(ctx, gcsRequestContextKey{}, gcsRequestPrivacy{session: true})
	session, _ := url.Parse(f.server.URL + "/session/private-session-secret?upload_id=session-secret-query")
	c.httpClient.CloseIdleConnections()
	// Log the URL through the same privacy-aware diagnostics as live requests.
	response, e := c.do(ctx, http.MethodDelete, session, nil, nil, 0, nil, false)
	if response != nil {
		drainAndClose(response.Body)
	}
	if e != nil {
		writeJSON(mapError(e))
	}
	os.Stdout, os.Stderr = stdout, stderr
	logs, err := os.ReadFile(output.Name())
	if err != nil {
		t.Fatal(err)
	}
	keyFragment := strings.Split(f.pem, "\n")[1]
	for _, secret := range []string{keyFragment, "fixture-access-token-secret-1", "private-session-secret", "session-secret-query", asString(signed["url"])} {
		if bytes.Contains(logs, []byte(secret)) {
			t.Fatalf("secret appeared in captured output: %q", secret[:min(16, len(secret))])
		}
	}
	if !bytes.Contains(logs, []byte("HttpSend")) || !bytes.Contains(logs, []byte("HttpReceive")) {
		t.Fatal("fixture did not exercise API logging")
	}
}

func TestGCSCancellationPropagatesAndCancelsSession(t *testing.T) {
	testGCSCancellationPropagatesAndCancelsSession(t, false)
}

func testGCSCancellationPropagatesAndCancelsSession(t *testing.T, inProcess bool) {
	f := newGCSFixtureWithTransport(t, inProcess)
	p, _ := parseProfile(f.params)
	c, ctx, _ := buildGCSClient(p)
	ctx, cancel := context.WithCancel(ctx)
	data := agePlaintext(2 * 1024 * 1024)
	err := c.uploadResumable(ctx, "bucket", "cancelled", bytes.NewReader(data), int64(len(data)), 1024*1024, func() error { return nil }, func(int64) { cancel() })
	if err == nil || f.cancelled != 1 || f.chunks != 1 {
		t.Fatalf("cancel: err=%v sessions cancelled=%d chunks=%d", err, f.cancelled, f.chunks)
	}
}

func TestGCSInProcessTransfers(t *testing.T) {
	for name, run := range map[string]func(*testing.T, bool){
		"upload":            testGCSStreamingUploadsAndOffsetRecovery,
		"upload-failure":    testGCSResumableFailureCancellationAndSourceIdentity,
		"download":          testGCSRangedDownloadsRetryAndAtomicPublication,
		"download-failure":  testGCSDownloadRejectsInvalidRangesWithoutPublishing,
		"client-encryption": testGCSClientEncryptionUsesExistingAgeFormat,
		"privacy":           testGCSCredentialsSessionsAndSignedURLsAreAbsentFromLogs,
		"cancellation":      testGCSCancellationPropagatesAndCancelsSession,
	} {
		t.Run(name, func(t *testing.T) { run(t, true) })
	}
}

func TestGCSInProcessContract(t *testing.T) {
	f := newGCSFixtureWithTransport(t, true)
	f.refreshOnce = true
	if got := f.mustCall("testProfile", nil); !asBool(got["ok"]) || f.tokens != 2 {
		t.Fatalf("auth/profile: %v tokens=%d", got, f.tokens)
	}
	f.mustCall("listBuckets", nil)
	if f.tokens != 2 {
		t.Fatal("cached token not reused")
	}
	f.mustCall("createBucket", nil)
	f.mustCall("setBucketVersioning", map[string]interface{}{"enabled": true})
	if got := f.mustCall("getBucketAdminState", nil); !asBool(got["versioningEnabled"]) {
		t.Fatal(got)
	}
	for _, method := range []string{"listObjects", "listObjectVersions"} {
		first := f.mustCall(method, map[string]interface{}{"key": gcsSpecialName})
		cursor := "nextCursor"
		if method == "listObjectVersions" {
			cursor = "cursor"
		}
		page := f.mustCall(method, map[string]interface{}{"key": gcsSpecialName, "cursor": first[cursor]})
		if len(page["items"].([]map[string]interface{})) != 2 {
			t.Fatal(page)
		}
	}
	f.mustCall("getObjectDetails", map[string]interface{}{"key": gcsSpecialName, "versionId": "999"})
	f.mustCall("createFolder", map[string]interface{}{"key": gcsSpecialName})
	f.mustCall("deleteObjects", map[string]interface{}{"keys": []interface{}{gcsSpecialName}})
	f.mustCall("deleteObjectVersions", map[string]interface{}{"versions": []interface{}{map[string]interface{}{"key": gcsSpecialName, "versionId": "999"}}})
	copyParams := map[string]interface{}{"sourceBucketName": "bucket", "sourceKey": gcsSpecialName, "destinationBucketName": "target", "destinationKey": "copied " + gcsSpecialName}
	f.mustCall("copyObject", copyParams)
	f.mustCall("moveObject", copyParams)
	f.conflict = true
	if moved := f.mustCall("moveObject", copyParams); !asBool(moved["sourceRetained"]) {
		t.Fatal("conditional move did not preserve source")
	}
	f.conflict = false
	dir := t.TempDir()
	for _, size := range []int64{0, 15, 2*1024*1024 + 31} {
		data := agePlaintext(size)
		path := filepath.Join(dir, fmt.Sprintf("source-%d.bin", size))
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		upload := f.mustCall("startUpload", map[string]interface{}{"filePaths": []interface{}{path}, "multipartThresholdMiB": 1, "multipartChunkMiB": 1})
		if asInt(upload["bytesTransferred"]) != int(size) || !bytes.Equal(f.objects[filepath.Base(path)], data) {
			t.Fatal("in-process upload differs from source")
		}
		f.failRangeOnce = true
		destination := t.TempDir()
		f.mustCall("startDownload", map[string]interface{}{"keys": []interface{}{filepath.Base(path)}, "destinationPath": destination, "multipartThresholdMiB": 1, "multipartChunkMiB": 1})
		got, err := os.ReadFile(filepath.Join(destination, filepath.Base(path)))
		if err != nil || !bytes.Equal(got, data) {
			t.Fatalf("in-process download differs: %v", err)
		}
	}
	f.mustCall("deleteBucket", nil)
	f.repeatedPage = true
	for _, method := range []string{"listBuckets", "listObjects", "listObjectVersions"} {
		_, err := f.call(method, map[string]interface{}{"cursor": map[string]interface{}{"value": "object-next"}})
		if err == nil || mapError(err)["code"] != "invalid_response" {
			t.Fatalf("repeated cursor accepted by %s: %v", method, err)
		}
	}
}

func TestGCSInProcessConditionalLiveAndVersionMoves(t *testing.T) {
	for _, explicitRevision := range []bool{false, true} {
		t.Run(fmt.Sprintf("explicitRevision=%v", explicitRevision), func(t *testing.T) {
			f := newGCSFixtureWithTransport(t, true)
			f.replaceDuringRewrite = true
			params := map[string]interface{}{"sourceBucketName": "bucket", "sourceKey": gcsSpecialName, "destinationBucketName": "target", "destinationKey": "copied " + gcsSpecialName}
			if explicitRevision {
				params["sourceVersionId"] = "17"
			}
			result := f.mustCall("moveObject", params)
			last := f.requests[len(f.requests)-1]
			if last.method != http.MethodDelete || last.query.Get("ifGenerationMatch") != "17" {
				t.Fatal("move did not condition deletion on copied generation")
			}
			if explicitRevision {
				if last.query.Get("generation") != "17" || result["successCount"] != 1 {
					t.Fatal("exact version move did not select the copied revision")
				}
			} else {
				if last.query.Get("generation") != "" || !asBool(result["sourceRetained"]) || result["failures"].([]map[string]interface{})[0]["code"] != "object_conflict" {
					t.Fatal("live move masked replacement by selecting the old revision")
				}
			}
		})
	}
}

func TestGCSInProcessTokenRefreshLimit(t *testing.T) {
	f := newGCSFixtureWithTransport(t, true)
	f.rejectAuth = true
	_, err := f.call("listBuckets", nil)
	if err == nil || mapError(err)["code"] != "auth_failed" || f.tokens != 2 || f.refreshes != 2 {
		t.Fatalf("401 was refreshed more than once: err=%v tokens=%d requests=%d", err, f.tokens, f.refreshes)
	}
}
