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
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const gcsEndpointType = "googleCloudStorage"

func isGCSProfilePayload(p map[string]interface{}) bool {
	return strings.EqualFold(strings.TrimSpace(asString(p["endpointType"])), gcsEndpointType)
}

func validateEndpointType(value string) error {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "s3compatible", "awss3", "azureblob", "googlecloudstorage":
		return nil
	default:
		return &sidecarError{Code: "invalid_config", Message: "Unknown endpoint type."}
	}
}

type gcsRequestContextKey struct{}
type gcsRequestPrivacy struct{ session bool }

// Token responses and session locations are credentials. Do not inspect bodies
// for GCS diagnostics, including small upload bodies that could contain keys.
// Keep the S3/Azure diagnostic path unchanged.
func (rt loggingRoundTripper) roundTripGCS(req *http.Request) (*http.Response, error) {
	privacy := req.Context().Value(gcsRequestContextKey{}).(gcsRequestPrivacy)
	endpoint := redactedURL(req.URL)
	if privacy.session {
		endpoint = "[redacted GCS session]"
	}
	headers := func(h http.Header) string {
		clean := sanitizeHeaders(h)
		for name := range clean {
			// Service-defined headers may echo a session URI or credentials.
			// Only these non-secret protocol headers are useful for diagnostics.
			switch strings.ToLower(name) {
			case "content-type", "content-length", "content-range", "range":
			default:
				clean[name] = "[redacted]"
			}
		}
		return mustJSONString(clean)
	}
	if rt.diagnostics.EnableAPILogging {
		emitStructuredLog("API", "HttpSend", fmt.Sprintf("SEND %s %s HEADERS=%s BODY=[omitted GCS body]", req.Method, endpoint, headers(req.Header)), "api")
	}
	resp, err := rt.base.RoundTrip(req)
	if err != nil {
		if rt.diagnostics.EnableDebugLogging {
			emitStructuredLog("DEBUG", "HttpError", "GCS HTTP request failed.", "debug")
		}
		return nil, err
	}
	if rt.diagnostics.EnableAPILogging {
		emitStructuredLog("API", "HttpReceive", fmt.Sprintf("RECV %s %s STATUS=%d HEADERS=%s BODY=[omitted GCS body]", req.Method, endpoint, resp.StatusCode, headers(resp.Header)), "api")
	}
	return resp, nil
}

type gcsClient struct {
	base, tokenURI *url.URL
	email, project string
	key            *rsa.PrivateKey
	keySecrets     []string
	httpClient     *http.Client
	attempts       int
	tokenMu        sync.Mutex
	token          string
	expires        time.Time
}

var gcsClientCache = struct {
	sync.Mutex
	clients map[profile]*gcsClient
	order   []profile
}{clients: map[profile]*gcsClient{}}

func gcsInvalidKey() error {
	return &sidecarError{Code: "invalid_config", Message: "A valid RSA service-account key file with client_email, private_key, project_id and token_uri is required."}
}

func gcsURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil || u.Fragment != "" || u.RawQuery != "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Invalid Cloud Storage endpoint or token URI."}
	}
	return u, nil
}

func buildGCSClient(p profile) (*gcsClient, context.Context, error) {
	ctx := context.WithValue(context.Background(), gcsRequestContextKey{}, gcsRequestPrivacy{})
	gcsClientCache.Lock()
	defer gcsClientCache.Unlock()
	if c := gcsClientCache.clients[p]; c != nil {
		return c, ctx, nil
	}
	var account struct {
		Email   string `json:"client_email"`
		Key     string `json:"private_key"`
		Project string `json:"project_id"`
		Token   string `json:"token_uri"`
	}
	if json.Unmarshal([]byte(p.SecretKey), &account) != nil || account.Email == "" || account.Project == "" || account.Token == "" {
		return nil, ctx, gcsInvalidKey()
	}
	block, rest := pem.Decode([]byte(account.Key))
	if block == nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, ctx, gcsInvalidKey()
	}
	var key *rsa.PrivateKey
	switch block.Type {
	case "PRIVATE KEY":
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err == nil {
			key, _ = parsed.(*rsa.PrivateKey)
		}
	case "RSA PRIVATE KEY":
		key, _ = x509.ParsePKCS1PrivateKey(block.Bytes)
	}
	if key == nil || key.N.BitLen() < 2048 || key.Validate() != nil {
		return nil, ctx, gcsInvalidKey()
	}
	tokenURI, err := gcsURL(account.Token)
	if err != nil {
		return nil, ctx, gcsInvalidKey()
	}
	base, err := gcsURL(nonEmpty(p.EndpointURL, "https://storage.googleapis.com"))
	if err != nil {
		return nil, ctx, err
	}
	transport, err := profileTransport(p)
	if err != nil {
		return nil, ctx, err
	}
	httpClient := profileHTTPClient(p, transport)
	// 308 is part of the resumable protocol, never a redirect. Also prevent
	// bearer credentials being redirected to an unrelated origin.
	httpClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	c := &gcsClient{base: base, tokenURI: tokenURI, email: account.Email, project: account.Project, key: key, keySecrets: strings.Fields(account.Key), httpClient: httpClient, attempts: p.MaxAttempts}
	if len(gcsClientCache.order) >= 16 {
		oldest := gcsClientCache.order[0]
		gcsClientCache.order = gcsClientCache.order[1:]
		gcsClientCache.clients[oldest].httpClient.CloseIdleConnections()
		delete(gcsClientCache.clients, oldest)
	}
	gcsClientCache.order = append(gcsClientCache.order, p)
	gcsClientCache.clients[p] = c
	return c, ctx, nil
}

func (c *gcsClient) sign(data string) (string, error) {
	hash := sha256.Sum256([]byte(data))
	signature, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, hash[:])
	return base64.RawURLEncoding.EncodeToString(signature), err
}

func (c *gcsClient) accessToken(ctx context.Context, rejected string) (string, error) {
	if _, ok := ctx.Value(gcsRequestContextKey{}).(gcsRequestPrivacy); !ok {
		ctx = context.WithValue(ctx, gcsRequestContextKey{}, gcsRequestPrivacy{})
	}
	c.tokenMu.Lock()
	defer c.tokenMu.Unlock()
	if c.token != "" && time.Until(c.expires) > time.Minute && (rejected == "" || rejected != c.token) {
		return c.token, nil
	}
	now := time.Now().Unix()
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]interface{}{"iss": c.email, "scope": "https://www.googleapis.com/auth/devstorage.read_write", "aud": c.tokenURI.String(), "iat": now, "exp": now + 3600})
	unsigned := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	signature, err := c.sign(unsigned)
	if err != nil {
		return "", gcsInvalidKey()
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {unsigned + "." + signature}}.Encode()
	for attempt := 0; attempt < max(1, c.attempts); attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.tokenURI.String(), strings.NewReader(form))
		if err != nil {
			return "", gcsInvalidKey()
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		resp, err := c.httpClient.Do(req)
		if (err != nil || gcsTransient(resp.StatusCode)) && attempt+1 < max(1, c.attempts) {
			if resp != nil {
				drainAndClose(resp.Body)
			}
			if err = retryPause(ctx, min(attempt, 3)); err != nil {
				return "", gcsTransportError(err)
			}
			continue
		}
		if err != nil {
			return "", gcsTransportError(err)
		}
		if resp.StatusCode != http.StatusOK {
			defer resp.Body.Close()
			return "", c.responseError(resp, c.token)
		}
		var token struct {
			AccessToken string `json:"access_token"`
			ExpiresIn   int64  `json:"expires_in"`
		}
		err = gcsDecode(resp, &token)
		if err != nil {
			return "", err
		}
		if token.AccessToken == "" || token.ExpiresIn <= 0 {
			return "", &sidecarError{Code: "auth_failed", Message: "Invalid Cloud Storage token response.", Details: map[string]interface{}{"provider": "gcs", "httpStatus": 200}}
		}
		c.token, c.expires = token.AccessToken, time.Now().Add(time.Duration(min(token.ExpiresIn, int64(3600)))*time.Second)
		return c.token, nil
	}
	return "", &sidecarError{Code: "auth_failed", Message: "Cloud Storage token attempts exhausted."}
}

// Build escaped paths segment by segment: an object name is one JSON API path
// segment, even when it contains '/', '%', '+', '?' or Unicode.
func (c *gcsClient) urlFor(parts ...string) *url.URL {
	u := *c.base
	raw := strings.TrimRight(u.EscapedPath(), "/")
	for _, part := range parts {
		raw += "/" + gcsEscape(part)
	}
	u.Path, _ = url.PathUnescape(raw)
	u.RawPath, u.RawQuery, u.Fragment = raw, "", ""
	return &u
}

func gcsEscape(s string) string {
	return strings.ReplaceAll(url.QueryEscape(s), "+", "%20")
}

func (c *gcsClient) objectURL(bucket, key string) *url.URL {
	return c.urlFor("storage", "v1", "b", bucket, "o", key)
}

func gcsTransient(status int) bool {
	return status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504
}

// Mutation replay is explicit. Chunk PUTs are deliberately not replayed here:
// an interrupted chunk must first query the session's committed offset.
func (c *gcsClient) do(ctx context.Context, method string, u *url.URL, query url.Values, headers map[string]string, length int64, body func() io.Reader, retry bool) (*http.Response, error) {
	if _, ok := ctx.Value(gcsRequestContextKey{}).(gcsRequestPrivacy); !ok {
		ctx = context.WithValue(ctx, gcsRequestContextKey{}, gcsRequestPrivacy{})
	}
	target := *u
	merged := target.Query()
	for name, values := range query {
		merged[name] = values
	}
	target.RawQuery = merged.Encode()
	attempts := 1
	if retry {
		attempts = max(1, c.attempts)
	}
	refreshed := false
	for attempt := 0; ; {
		token, err := c.accessToken(ctx, "")
		if err != nil {
			return nil, err
		}
		var reader io.Reader
		if body != nil {
			reader = body()
		}
		req, err := http.NewRequestWithContext(ctx, method, target.String(), reader)
		if err != nil {
			return nil, &sidecarError{Code: "invalid_config", Message: "Invalid Cloud Storage request."}
		}
		req.ContentLength = length
		req.Header.Set("Authorization", "Bearer "+token)
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		resp, err := c.httpClient.Do(req)
		if err == nil && resp.StatusCode == 401 && !refreshed {
			drainAndClose(resp.Body)
			if _, err = c.accessToken(ctx, token); err != nil {
				return nil, err
			}
			refreshed = true
			continue
		}
		if (err != nil || gcsTransient(resp.StatusCode)) && attempt+1 < attempts {
			if resp != nil {
				drainAndClose(resp.Body)
			}
			if err = retryPause(ctx, min(attempt, 3)); err != nil {
				return nil, gcsTransportError(err)
			}
			attempt++
			continue
		}
		if err != nil {
			return nil, gcsTransportError(err)
		}
		privacy, _ := ctx.Value(gcsRequestContextKey{}).(gcsRequestPrivacy)
		if resp.StatusCode >= 300 && !(privacy.session && (resp.StatusCode == 308 || (method == http.MethodDelete && resp.StatusCode == 499))) {
			defer resp.Body.Close()
			return nil, c.responseError(resp, token)
		}
		return resp, nil
	}
}

func gcsTransportError(err error) error {
	code := "unknown"
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() || errors.Is(err, context.DeadlineExceeded) {
		code = "timeout"
	}
	if errors.Is(err, context.Canceled) {
		code = "cancelled"
	}
	return &sidecarError{Code: code, Message: "Cloud Storage HTTP request failed.", Details: map[string]interface{}{"provider": "gcs", "httpStatus": 0}}
}

func gcsResponseError(resp *http.Response) error {
	var parsed struct {
		Error struct {
			Errors []struct{ Reason string } `json:"errors"`
		} `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&parsed)
	reason := ""
	if len(parsed.Error.Errors) > 0 {
		// A service reason is an identifier, never free-form server text that
		// could echo credentials, a signed URL or a session URI.
		candidate := parsed.Error.Errors[0].Reason
		if len(candidate) <= 80 && strings.IndexFunc(candidate, func(r rune) bool {
			return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_')
		}) == -1 {
			reason = candidate
		}
	}
	code := "unknown"
	switch resp.StatusCode {
	case 401, 403:
		code = "auth_failed"
	case 404:
		code = "not_found"
	case 409, 412:
		code = "object_conflict"
	case 429:
		code = "throttled"
	case 408, 504:
		code = "timeout"
	}
	return &sidecarError{Code: code, Message: fmt.Sprintf("Cloud Storage request failed with HTTP %d.", resp.StatusCode), Details: map[string]interface{}{"provider": "gcs", "httpStatus": resp.StatusCode, "reason": reason}}
}

func (c *gcsClient) responseError(resp *http.Response, token string) error {
	err := gcsResponseError(resp).(*sidecarError)
	secrets := append(append([]string(nil), c.keySecrets...), token)
	err.Details["reason"] = redactEncryptionText(asString(err.Details["reason"]), secrets)
	return err
}

func gcsDecode(resp *http.Response, target interface{}) error {
	defer resp.Body.Close()
	if err := json.NewDecoder(io.LimitReader(resp.Body, 16*1024*1024)).Decode(target); err != nil {
		var timeout net.Error
		if errors.As(err, &timeout) && timeout.Timeout() || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return gcsTransportError(err)
		}
		return &sidecarError{Code: "invalid_response", Message: "Invalid Cloud Storage JSON response.", Details: map[string]interface{}{"provider": "gcs", "httpStatus": resp.StatusCode}}
	}
	return nil
}

func (c *gcsClient) json(ctx context.Context, method string, u *url.URL, query url.Values, payload, target interface{}) error {
	var data []byte
	if payload != nil {
		data, _ = json.Marshal(payload)
	}
	resp, err := c.do(ctx, method, u, query, map[string]string{"Content-Type": "application/json"}, int64(len(data)), func() io.Reader { return bytes.NewReader(data) }, method == http.MethodGet)
	if err != nil {
		return err
	}
	if target == nil {
		drainAndClose(resp.Body)
		return nil
	}
	return gcsDecode(resp, target)
}

type gcsObject struct {
	Name         string            `json:"name"`
	Generation   string            `json:"generation"`
	Size         string            `json:"size"`
	Updated      string            `json:"updated"`
	StorageClass string            `json:"storageClass"`
	ContentType  string            `json:"contentType"`
	ETag         string            `json:"etag"`
	Metadata     map[string]string `json:"metadata"`
}

func (c *gcsClient) metadata(ctx context.Context, bucket, key, generation string) (gcsObject, error) {
	var object gcsObject
	query := url.Values{}
	if generation != "" {
		query.Set("generation", generation)
	}
	err := c.json(ctx, http.MethodGet, c.objectURL(bucket, key), query, nil, &object)
	return object, err
}

func gcsBucketItem(bucket map[string]interface{}) map[string]interface{} {
	return map[string]interface{}{"name": bucket["name"], "region": bucket["location"], "createdAt": bucket["timeCreated"], "objectCountHint": 0, "versioningEnabled": asBool(asMap(bucket["versioning"])["enabled"])}
}

func gcsCapabilities() map[string]interface{} {
	items := []map[string]interface{}{}
	for _, key := range []string{"bucket.versioning", "object.copy_move", "object.clientEncryption"} {
		item := map[string]interface{}{"key": key, "label": key, "state": "supported", "implementationState": "supported", "reason": "Implemented by the native Cloud Storage adapter; permissions are checked per operation."}
		if key == "object.clientEncryption" {
			item["formats"] = []string{"age-v1"}
		}
		items = append(items, item)
	}
	for _, key := range []string{"bucket.lifecycle", "bucket.policy", "bucket.cors", "bucket.encryption", "bucket.tagging", "object.encryption.sse-s3", "object.encryption.sse-kms", "object.encryption.dsse-kms", "object.encryption.sse-c", "object.encryption.azure-scope", "object.encryption.azure-cpk", "object.resumable", "benchmark", "tools.bulk-delete", "tools", "storage.admin", "auth.awsProfiles"} {
		items = append(items, map[string]interface{}{"key": key, "label": key, "state": "unsupported", "implementationState": "unsupported", "reason": "Not implemented for native Cloud Storage profiles. Resumable upload sessions do not provide durable transfer checkpoints."})
	}
	return map[string]interface{}{"items": append(items, s3ConformanceCapability(false))}
}

func handleGCSRequest(method string, params map[string]interface{}) (result map[string]interface{}, err error) {
	defer protectClientEncryptionResult(params, &result, &err)
	if params["encryption"] != nil || params["sourceEncryption"] != nil {
		return nil, invalidEncryption()
	}
	if method == "getCapabilities" {
		return gcsCapabilities(), nil
	}
	switch method {
	case "testProfile", "listBuckets", "createBucket", "deleteBucket", "setBucketVersioning", "getBucketAdminState", "listObjects", "listObjectVersions", "getObjectDetails", "startUpload", "startDownload", "deleteObjects", "deleteObjectVersions", "copyObject", "moveObject", "createFolder", "generatePresignedUrl":
	default:
		return nil, &sidecarError{Code: "unsupported_feature", Message: "This method is not implemented for native Cloud Storage profiles."}
	}
	payload := asMap(params["profile"])
	p, err := parseProfile(payload)
	if err != nil {
		return nil, err
	}
	c, ctx, err := buildGCSClient(p)
	if err != nil {
		return nil, err
	}
	bucket := strings.TrimSpace(asString(params["bucketName"]))
	if method != "listBuckets" && method != "testProfile" && method != "copyObject" && method != "moveObject" && bucket == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name is required."}
	}
	switch method {
	case "listBuckets", "testProfile":
		items := []map[string]interface{}{}
		if p.KnownBucket != "" {
			var entry map[string]interface{}
			if err = c.json(ctx, http.MethodGet, c.urlFor("storage", "v1", "b", p.KnownBucket), nil, nil, &entry); err != nil {
				return nil, err
			}
			items = append(items, gcsBucketItem(entry))
		} else {
			seen := map[string]bool{}
			cursor := ""
			for {
				var page struct {
					Items []map[string]interface{} `json:"items"`
					Next  string                   `json:"nextPageToken"`
				}
				if err = c.json(ctx, http.MethodGet, c.urlFor("storage", "v1", "b"), url.Values{"project": {c.project}, "maxResults": {"1000"}, "pageToken": {cursor}}, nil, &page); err != nil {
					return nil, err
				}
				for _, entry := range page.Items {
					items = append(items, gcsBucketItem(entry))
				}
				if page.Next == "" {
					break
				}
				if seen[page.Next] {
					return nil, gcsRepeatedCursor()
				}
				seen[page.Next], cursor = true, page.Next
			}
		}
		if method == "testProfile" {
			return map[string]interface{}{"ok": true, "items": items, "bucketCount": len(items), "endpoint": c.base.Host}, nil
		}
		return map[string]interface{}{"items": items}, nil
	case "createBucket":
		body := map[string]interface{}{"name": bucket}
		if p.Region != "" {
			body["location"] = p.Region
		}
		var entry map[string]interface{}
		if err = c.json(ctx, http.MethodPost, c.urlFor("storage", "v1", "b"), url.Values{"project": {c.project}}, body, &entry); err != nil {
			return nil, err
		}
		return gcsBucketItem(entry), nil
	case "deleteBucket":
		err = c.json(ctx, http.MethodDelete, c.urlFor("storage", "v1", "b", bucket), nil, nil, nil)
		return map[string]interface{}{"deleted": err == nil, "bucketName": bucket}, err
	case "setBucketVersioning", "getBucketAdminState":
		var entry map[string]interface{}
		if method == "setBucketVersioning" {
			err = c.json(ctx, http.MethodPatch, c.urlFor("storage", "v1", "b", bucket), nil, map[string]interface{}{"versioning": map[string]interface{}{"enabled": asBool(params["enabled"])}}, &entry)
		} else {
			err = c.json(ctx, http.MethodGet, c.urlFor("storage", "v1", "b", bucket), nil, nil, &entry)
		}
		if err != nil {
			return nil, err
		}
		enabled := asBool(asMap(entry["versioning"])["enabled"])
		status := "Suspended"
		if enabled {
			status = "Enabled"
		}
		return map[string]interface{}{"bucketName": bucket, "versioningEnabled": enabled, "versioningStatus": status, "objectLockEnabled": false, "lifecycleEnabled": false, "policyAttached": false, "corsEnabled": false, "encryptionEnabled": false, "encryptionSummary": "Unsupported", "tags": map[string]string{}, "lifecycleRules": []interface{}{}, "lifecycleJson": `{"Rules":[]}`, "policyJson": "{}", "corsJson": "[]", "encryptionJson": "{}", "apiCalls": []interface{}{}}, nil
	case "listObjects", "listObjectVersions":
		return c.listObjects(ctx, p, bucket, params, method == "listObjectVersions")
	case "getObjectDetails":
		key := asString(params["key"])
		if key == "" {
			return nil, &sidecarError{Code: "invalid_config", Message: "Object key is required."}
		}
		object, err := c.metadata(ctx, bucket, key, asString(params["versionId"]))
		if err != nil {
			return nil, err
		}
		if object.Metadata == nil {
			object.Metadata = map[string]string{}
		}
		return map[string]interface{}{"key": key, "versionId": object.Generation, "metadata": object.Metadata, "headers": map[string]string{"Content-Length": object.Size, "Content-Type": object.ContentType, "ETag": object.ETag, "Last-Modified": object.Updated, "Storage-Class": object.StorageClass}, "tags": map[string]string{}, "debugEvents": []interface{}{}, "apiCalls": []interface{}{}, "debugLogExcerpt": []string{}, "rawDiagnostics": map[string]interface{}{"provider": "gcs", "bucketName": bucket}}, nil
	case "createFolder":
		key := asString(params["key"])
		if key == "" {
			return nil, &sidecarError{Code: "invalid_config", Message: "Folder key is required."}
		}
		if !strings.HasSuffix(key, "/") {
			key += "/"
		}
		resp, err := c.do(ctx, http.MethodPost, c.urlFor("upload", "storage", "v1", "b", bucket, "o"), url.Values{"uploadType": {"media"}, "name": {key}}, map[string]string{"Content-Type": "application/octet-stream"}, 0, nil, false)
		if err != nil {
			return nil, err
		}
		drainAndClose(resp.Body)
		return map[string]interface{}{"created": true, "key": key}, nil
	case "deleteObjects", "deleteObjectVersions":
		return c.deleteObjects(ctx, bucket, params, method == "deleteObjectVersions")
	case "copyObject", "moveObject":
		return c.copyObject(ctx, params, method == "moveObject")
	case "generatePresignedUrl":
		key := asString(params["key"])
		if key == "" {
			return nil, &sidecarError{Code: "invalid_config", Message: "Object key is required."}
		}
		return c.signedURL(bucket, key, asString(params["versionId"]), min(604800, maxInt(asInt(params["expirationSeconds"]), 1, 3600)), time.Now().UTC())
	case "startUpload":
		return c.startUpload(ctx, p, bucket, params)
	case "startDownload":
		return c.startDownload(ctx, p, bucket, params)
	}
	return nil, &sidecarError{Code: "unsupported_feature", Message: "Unsupported Cloud Storage method."}
}

func gcsRepeatedCursor() error {
	return &sidecarError{Code: "invalid_response", Message: "Cloud Storage returned a repeated listing cursor."}
}

func (c *gcsClient) listObjects(ctx context.Context, p profile, bucket string, params map[string]interface{}, versions bool) (map[string]interface{}, error) {
	prefix := asString(params["prefix"])
	key := asString(params["key"])
	if versions {
		prefix = key
		if prefix == "" {
			options := asMap(params["options"])
			if mode := asString(options["filterMode"]); mode == "" || mode == "prefix" {
				prefix = asString(options["filterValue"])
			}
		}
	}
	cursor := asString(asMap(params["cursor"])["value"])
	query := url.Values{"prefix": {prefix}, "maxResults": {"1000"}, "pageToken": {cursor}}
	if versions {
		query.Set("versions", "true")
	} else if !asBool(params["flat"]) {
		query.Set("delimiter", "/")
	}
	var page struct {
		Items    []gcsObject `json:"items"`
		Prefixes []string    `json:"prefixes"`
		Next     string      `json:"nextPageToken"`
	}
	if err := c.json(ctx, http.MethodGet, c.urlFor("storage", "v1", "b", bucket, "o"), query, nil, &page); err != nil {
		return nil, err
	}
	if page.Next != "" && page.Next == cursor {
		return nil, gcsRepeatedCursor()
	}
	items := []map[string]interface{}{}
	for _, folder := range page.Prefixes {
		items = append(items, map[string]interface{}{"key": folder, "name": strings.TrimPrefix(folder, prefix), "size": 0, "storageClass": "FOLDER", "modifiedAt": time.Now().UTC().Format(time.RFC3339), "isFolder": true, "metadataCount": 0, "etag": nil})
	}
	live := map[string]string{}
	for _, object := range page.Items {
		if versions && key != "" && key != object.Name {
			continue
		}
		size, err := strconv.ParseInt(object.Size, 10, 64)
		if err != nil || size < 0 {
			return nil, &sidecarError{Code: "invalid_response", Message: "Invalid Cloud Storage object size."}
		}
		if versions {
			generation, exists := live[object.Name]
			if !exists {
				current, err := c.metadata(ctx, bucket, object.Name, "")
				if err != nil && asString(mapError(err)["code"]) != "not_found" {
					return nil, err
				}
				generation = current.Generation
				live[object.Name] = generation
			}
			items = append(items, map[string]interface{}{"key": object.Name, "versionId": object.Generation, "modifiedAt": object.Updated, "latest": object.Generation == generation, "deleteMarker": false, "size": size, "storageClass": nonEmpty(object.StorageClass, "STANDARD")})
		} else {
			if !asBool(params["flat"]) && object.Name == prefix {
				continue
			}
			items = append(items, map[string]interface{}{"key": object.Name, "name": nonEmpty(strings.TrimPrefix(object.Name, prefix), object.Name), "size": size, "storageClass": nonEmpty(object.StorageClass, "STANDARD"), "modifiedAt": object.Updated, "isFolder": false, "etag": object.ETag, "metadataCount": len(object.Metadata)})
		}
	}
	next := map[string]interface{}{"value": page.Next, "hasMore": page.Next != ""}
	if versions {
		sort.Slice(items, func(i, j int) bool { return asString(items[i]["modifiedAt"]) > asString(items[j]["modifiedAt"]) })
		return map[string]interface{}{"items": items, "cursor": next, "totalCount": len(items), "versionCount": len(items), "deleteMarkerCount": 0}, nil
	}
	sort.Slice(items, func(i, j int) bool {
		if asBool(items[i]["isFolder"]) != asBool(items[j]["isFolder"]) {
			return asBool(items[i]["isFolder"])
		}
		return strings.ToLower(asString(items[i]["key"])) < strings.ToLower(asString(items[j]["key"]))
	})
	return map[string]interface{}{"items": items, "nextCursor": next, "profileRegion": p.Region}, nil
}

func (c *gcsClient) deleteObjects(ctx context.Context, bucket string, params map[string]interface{}, versions bool) (map[string]interface{}, error) {
	entries := []map[string]interface{}{}
	if versions {
		for _, entry := range asMapSlice(params["versions"]) {
			entries = append(entries, entry)
		}
	} else {
		for _, key := range asStringSlice(params["keys"]) {
			entries = append(entries, map[string]interface{}{"key": key})
		}
	}
	if len(entries) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Object deletion targets are required."}
	}
	for _, entry := range entries {
		if asString(entry["key"]) == "" || (versions && asString(entry["versionId"]) == "") {
			return nil, &sidecarError{Code: "invalid_config", Message: "Object key and exact version ID are required for version deletion."}
		}
	}
	success := 0
	failures := []map[string]interface{}{}
	for _, entry := range entries {
		query := url.Values{}
		if versions {
			query.Set("generation", asString(entry["versionId"]))
		}
		err := c.json(ctx, http.MethodDelete, c.objectURL(bucket, asString(entry["key"])), query, nil, nil)
		if err == nil || asString(mapError(err)["code"]) == "not_found" {
			success++
		} else {
			mapped := mapError(err)
			failures = append(failures, map[string]interface{}{"target": entry["key"], "versionId": entry["versionId"], "code": mapped["code"], "message": mapped["message"], "details": mapped["details"]})
		}
	}
	return map[string]interface{}{"successCount": success, "failureCount": len(failures), "failures": failures}, nil
}

func (c *gcsClient) copyObject(ctx context.Context, params map[string]interface{}, move bool) (map[string]interface{}, error) {
	srcBucket, srcKey := asString(params["sourceBucketName"]), asString(params["sourceKey"])
	dstBucket, dstKey := asString(params["destinationBucketName"]), asString(params["destinationKey"])
	if srcBucket == "" || srcKey == "" || dstBucket == "" || dstKey == "" || (srcBucket == dstBucket && srcKey == dstKey) {
		return nil, &sidecarError{Code: "invalid_config", Message: "Distinct copy source and destination are required."}
	}
	source, err := c.metadata(ctx, srcBucket, srcKey, asString(params["sourceVersionId"]))
	if err != nil {
		return nil, err
	}
	if source.Generation == "" {
		return nil, &sidecarError{Code: "invalid_response", Message: "Cloud Storage omitted the source generation."}
	}
	if asBool(params["requireEmptySource"]) && source.Size != "0" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Only empty markers can be copied into this vault."}
	}
	u := c.urlFor("storage", "v1", "b", srcBucket, "o", srcKey, "rewriteTo", "b", dstBucket, "o", dstKey)
	query := url.Values{"sourceGeneration": {source.Generation}, "ifSourceGenerationMatch": {source.Generation}}
	policy := asString(params["conflictPolicy"])
	if policy == "" {
		policy = "replace"
	}
	switch policy {
	case "replace", "overwrite":
	case "skip", "fail":
		_, existsErr := c.metadata(ctx, dstBucket, dstKey, "")
		var notFound *sidecarError
		if existsErr == nil {
			if policy == "fail" {
				return nil, &sidecarError{Code: "conflict", Message: "Destination object already exists."}
			}
			return map[string]interface{}{"successCount": 0, "failureCount": 0, "failures": []interface{}{}, "skipped": true, "bytesCopied": 0}, nil
		} else if !errors.As(existsErr, &notFound) || notFound.Details["httpStatus"] != http.StatusNotFound {
			return nil, existsErr
		}
		// The check above gives a clear answer; this makes it atomic, so a
		// destination created in between is never overwritten.
		query.Set("ifGenerationMatch", "0")
	default:
		return nil, &sidecarError{Code: "invalid_config", Message: "Copy conflict policy must be replace, skip, or fail."}
	}
	seen := map[string]bool{}
	var destination gcsObject
	for {
		var rewrite struct {
			Done     bool      `json:"done"`
			Token    string    `json:"rewriteToken"`
			Resource gcsObject `json:"resource"`
		}
		if err = c.json(ctx, http.MethodPost, u, query, map[string]interface{}{}, &rewrite); err != nil {
			return nil, err
		}
		if rewrite.Done {
			destination = rewrite.Resource
			break
		}
		if rewrite.Token == "" || seen[rewrite.Token] {
			return nil, &sidecarError{Code: "invalid_response", Message: "Cloud Storage returned a missing or repeated rewrite token."}
		}
		seen[rewrite.Token] = true
		query.Set("rewriteToken", rewrite.Token)
	}
	size, _ := strconv.ParseInt(source.Size, 10, 64)
	result := map[string]interface{}{"successCount": 1, "failureCount": 0, "failures": []interface{}{}, "sourceGeneration": source.Generation, "bytesCopied": size, "versionId": emptyToNil(destination.Generation), "strategy": "server-side rewrite"}
	if move {
		query := url.Values{"ifGenerationMatch": {source.Generation}}
		// For a live move, apply the precondition to the live object. Selecting
		// the old generation here would mask a concurrent live replacement in
		// a versioned bucket. An explicitly selected revision is deleted exactly.
		if asString(params["sourceVersionId"]) != "" {
			query.Set("generation", source.Generation)
		}
		err = c.json(ctx, http.MethodDelete, c.objectURL(srcBucket, srcKey), query, nil, nil)
		if err != nil {
			mapped := mapError(err)
			result["successCount"], result["failureCount"], result["copiedCount"], result["sourceRetained"] = 0, 1, 1, true
			result["failures"] = []map[string]interface{}{{"target": srcKey, "code": mapped["code"], "message": "Copy completed; source deletion failed. Source retained.", "details": mapped["details"]}}
		}
	}
	return result, nil
}

func (c *gcsClient) signedURL(bucket, key, generation string, expiry int, now time.Time) (map[string]interface{}, error) {
	u := c.urlFor(bucket, key)
	date := now.Format("20060102")
	scope := date + "/auto/storage/goog4_request"
	query := url.Values{"X-Goog-Algorithm": {"GOOG4-RSA-SHA256"}, "X-Goog-Credential": {c.email + "/" + scope}, "X-Goog-Date": {now.Format("20060102T150405Z")}, "X-Goog-Expires": {strconv.Itoa(expiry)}, "X-Goog-SignedHeaders": {"host"}}
	if generation != "" {
		query.Set("generation", generation)
	}
	canonicalQuery := strings.ReplaceAll(query.Encode(), "+", "%20")
	canonical := "GET\n" + u.EscapedPath() + "\n" + canonicalQuery + "\nhost:" + u.Host + "\n\nhost\nUNSIGNED-PAYLOAD"
	hash := sha256.Sum256([]byte(canonical))
	stringToSign := "GOOG4-RSA-SHA256\n" + query.Get("X-Goog-Date") + "\n" + scope + "\n" + hex.EncodeToString(hash[:])
	signature, err := c.sign(stringToSign)
	if err != nil {
		return nil, gcsInvalidKey()
	}
	signed, _ := base64.RawURLEncoding.DecodeString(signature)
	u.RawQuery = canonicalQuery + "&X-Goog-Signature=" + hex.EncodeToString(signed)
	return map[string]interface{}{"url": u.String()}, nil
}
