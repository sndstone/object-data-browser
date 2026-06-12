package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	azureAPIVersion          = "2021-12-02"
	azureSingleShotMaxBytes  = int64(64) * 1024 * 1024
	azureBlockSizeBytes      = int64(16) * 1024 * 1024
	azureDeleteConcurrency   = 16
	azureCopyPollAttempts    = 20
	azureCopyPollInterval    = 250 * time.Millisecond
	azureEndpointTypeLiteral = "azureBlob"
)

func isAzureProfilePayload(payload map[string]interface{}) bool {
	return strings.EqualFold(strings.TrimSpace(asString(payload["endpointType"])), azureEndpointTypeLiteral)
}

func isAzureProfile(p profile) bool {
	return strings.EqualFold(strings.TrimSpace(p.EndpointType), azureEndpointTypeLiteral)
}

type azureClient struct {
	account    string
	key        []byte
	base       *url.URL
	httpClient *http.Client
}

func buildAzureClient(p profile) (*azureClient, context.Context, error) {
	ctx := context.Background()
	key, err := base64.StdEncoding.DecodeString(p.SecretKey)
	if err != nil {
		return nil, ctx, &sidecarError{Code: "invalid_config", Message: "Azure account access key must be valid base64."}
	}
	endpoint := strings.TrimRight(strings.TrimSpace(p.EndpointURL), "/")
	if endpoint == "" {
		endpoint = fmt.Sprintf("https://%s.blob.core.windows.net", p.AccessKey)
	}
	base, err := url.Parse(endpoint)
	if err != nil || base.Host == "" {
		return nil, ctx, &sidecarError{Code: "invalid_config", Message: "Azure Blob endpoint URL is invalid."}
	}
	baseTransport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout: time.Duration(p.ConnectTimeoutSeconds) * time.Second,
		}).DialContext,
		MaxIdleConns:        p.MaxPoolConnections,
		MaxIdleConnsPerHost: p.MaxPoolConnections,
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: !p.VerifyTLS},
	}
	httpClient := &http.Client{
		Timeout:   time.Duration(p.ConnectTimeoutSeconds+p.ReadTimeoutSeconds) * time.Second,
		Transport: loggingRoundTripper{base: baseTransport, diagnostics: p.Diagnostics},
	}
	return &azureClient{
		account:    p.AccessKey,
		key:        key,
		base:       base,
		httpClient: httpClient,
	}, ctx, nil
}

func (c *azureClient) urlFor(container, key string) *url.URL {
	u := *c.base
	path := strings.TrimSuffix(c.base.Path, "/")
	if container != "" {
		path += "/" + container
		if key != "" {
			path += "/" + key
		}
	}
	if path == "" {
		path = "/"
	}
	u.Path = path
	u.RawPath = ""
	u.RawQuery = ""
	u.Fragment = ""
	return &u
}

func (c *azureClient) sign(req *http.Request, query url.Values) {
	req.Header.Set("x-ms-version", azureAPIVersion)
	req.Header.Set("x-ms-date", time.Now().UTC().Format(http.TimeFormat))

	contentLength := ""
	if req.ContentLength > 0 {
		contentLength = strconv.FormatInt(req.ContentLength, 10)
	}

	msHeaders := make([]string, 0, len(req.Header))
	for name, values := range req.Header {
		lower := strings.ToLower(name)
		if strings.HasPrefix(lower, "x-ms-") {
			msHeaders = append(msHeaders, lower+":"+strings.Join(values, ","))
		}
	}
	sort.Strings(msHeaders)
	canonicalHeaders := ""
	for _, header := range msHeaders {
		canonicalHeaders += header + "\n"
	}

	resource := "/" + c.account + req.URL.EscapedPath()
	if len(query) > 0 {
		lowered := map[string][]string{}
		for name, values := range query {
			lower := strings.ToLower(name)
			lowered[lower] = append(lowered[lower], values...)
		}
		names := make([]string, 0, len(lowered))
		for name := range lowered {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			values := append([]string(nil), lowered[name]...)
			sort.Strings(values)
			resource += "\n" + name + ":" + strings.Join(values, ",")
		}
	}

	stringToSign := strings.Join([]string{
		req.Method,
		req.Header.Get("Content-Encoding"),
		req.Header.Get("Content-Language"),
		contentLength,
		req.Header.Get("Content-MD5"),
		req.Header.Get("Content-Type"),
		"", // Date is empty because x-ms-date is set.
		req.Header.Get("If-Modified-Since"),
		req.Header.Get("If-Match"),
		req.Header.Get("If-None-Match"),
		req.Header.Get("If-Unmodified-Since"),
		req.Header.Get("Range"),
	}, "\n") + "\n" + canonicalHeaders + resource

	mac := hmac.New(sha256.New, c.key)
	mac.Write([]byte(stringToSign))
	signature := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	req.Header.Set("Authorization", fmt.Sprintf("SharedKey %s:%s", c.account, signature))
}

func (c *azureClient) do(ctx context.Context, method, container, key string, query url.Values, headers map[string]string, body []byte) (*http.Response, error) {
	u := c.urlFor(container, key)
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}
	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return nil, err
	}
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	c.sign(req, query)
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		return nil, azureResponseError(resp)
	}
	return resp, nil
}

func azureResponseError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	body = bytes.TrimPrefix(body, []byte("\xef\xbb\xbf"))
	var parsed struct {
		Code    string `xml:"Code"`
		Message string `xml:"Message"`
	}
	_ = xml.Unmarshal(body, &parsed)
	code := nonEmpty(strings.TrimSpace(parsed.Code), strings.TrimSpace(resp.Header.Get("x-ms-error-code")))
	message := strings.TrimSpace(parsed.Message)
	if index := strings.Index(message, "\n"); index > 0 {
		message = message[:index]
	}
	if message == "" {
		message = fmt.Sprintf("Azure Blob request failed with HTTP %d.", resp.StatusCode)
	}
	sidecarCode := "unknown"
	switch {
	case resp.StatusCode == 401 || resp.StatusCode == 403 || code == "AuthenticationFailed" || code == "AuthorizationFailure":
		sidecarCode = "auth_failed"
	case resp.StatusCode == 404:
		sidecarCode = "not_found"
	case resp.StatusCode == 503 || code == "ServerBusy":
		sidecarCode = "throttled"
	case code == "OperationTimedOut":
		sidecarCode = "timeout"
	}
	return &sidecarError{
		Code:    sidecarCode,
		Message: message,
		Details: map[string]interface{}{"azureCode": code, "httpStatus": resp.StatusCode},
	}
}

func isAzureNotFound(err error) bool {
	var sideErr *sidecarError
	return errors.As(err, &sideErr) && sideErr.Code == "not_found"
}

func drainAndClose(body io.ReadCloser) {
	if body == nil {
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(body, 1024*1024))
	_ = body.Close()
}

func decodeAzureXML(resp *http.Response, target interface{}) error {
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	return xml.Unmarshal(data, target)
}

func azureTimeToRFC3339(value string) string {
	parsed, err := http.ParseTime(strings.TrimSpace(value))
	if err != nil {
		return time.Unix(0, 0).UTC().Format(time.RFC3339)
	}
	return parsed.UTC().Format(time.RFC3339)
}

type azureContainerEntry struct {
	Name       string `xml:"Name"`
	Properties struct {
		LastModified string `xml:"Last-Modified"`
	} `xml:"Properties"`
}

type azureListContainersResult struct {
	Containers []azureContainerEntry `xml:"Containers>Container"`
	NextMarker string                `xml:"NextMarker"`
}

type azureBlobProperties struct {
	LastModified  string `xml:"Last-Modified"`
	ContentLength int64  `xml:"Content-Length"`
	Etag          string `xml:"Etag"`
	ContentType   string `xml:"Content-Type"`
	AccessTier    string `xml:"AccessTier"`
}

type azureBlobEntry struct {
	Name       string              `xml:"Name"`
	Properties azureBlobProperties `xml:"Properties"`
}

type azureBlobPrefixEntry struct {
	Name string `xml:"Name"`
}

type azureListBlobsResult struct {
	Blobs        []azureBlobEntry       `xml:"Blobs>Blob"`
	BlobPrefixes []azureBlobPrefixEntry `xml:"Blobs>BlobPrefix"`
	NextMarker   string                 `xml:"NextMarker"`
}

func (c *azureClient) listContainersPage(ctx context.Context, marker string, maxResults int) (*azureListContainersResult, error) {
	query := url.Values{"comp": []string{"list"}}
	if marker != "" {
		query.Set("marker", marker)
	}
	if maxResults > 0 {
		query.Set("maxresults", strconv.Itoa(maxResults))
	}
	resp, err := c.do(ctx, http.MethodGet, "", "", query, nil, nil)
	if err != nil {
		return nil, err
	}
	var result azureListContainersResult
	if err = decodeAzureXML(resp, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func (c *azureClient) putBlob(ctx context.Context, container, key string, payload []byte, extraHeaders map[string]string) error {
	headers := map[string]string{"x-ms-blob-type": "BlockBlob"}
	for name, value := range extraHeaders {
		headers[name] = value
	}
	resp, err := c.do(ctx, http.MethodPut, container, key, nil, headers, payload)
	if err != nil {
		return err
	}
	drainAndClose(resp.Body)
	return nil
}

func (c *azureClient) getBlobAll(ctx context.Context, container, key string) ([]byte, error) {
	resp, err := c.do(ctx, http.MethodGet, container, key, nil, nil, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}

func (c *azureClient) deleteBlob(ctx context.Context, container, key string) error {
	resp, err := c.do(ctx, http.MethodDelete, container, key, nil, nil, nil)
	if err != nil {
		return err
	}
	drainAndClose(resp.Body)
	return nil
}

func azureBucketClient(params map[string]interface{}) (profile, string, *azureClient, context.Context, error) {
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return profile{}, "", nil, nil, err
	}
	bucketName := strings.TrimSpace(asString(params["bucketName"]))
	if bucketName == "" {
		return profile{}, "", nil, nil, &sidecarError{Code: "invalid_config", Message: "Bucket name is required."}
	}
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		return profile{}, "", nil, nil, err
	}
	return p, bucketName, client, ctx, nil
}

func azureUnsupported(method string) error {
	return &sidecarError{
		Code:    "unsupported_feature",
		Message: fmt.Sprintf("Method %s is not supported for Azure Blob profiles.", method),
	}
}

func handleAzureRequest(method string, params map[string]interface{}) (bool, map[string]interface{}, error) {
	switch method {
	case "testProfile":
		result, err := azureTestProfile(asMap(params["profile"]))
		return true, result, err
	case "listBuckets":
		result, err := azureListBuckets(asMap(params["profile"]))
		return true, result, err
	case "createBucket":
		result, err := azureCreateBucket(params)
		return true, result, err
	case "deleteBucket":
		result, err := azureDeleteBucket(params)
		return true, result, err
	case "listObjects":
		result, err := azureListObjects(params)
		return true, result, err
	case "getBucketAdminState":
		result, err := azureGetBucketAdminState(params)
		return true, result, err
	case "getObjectDetails":
		result, err := azureGetObjectDetails(params)
		return true, result, err
	case "createFolder":
		result, err := azureCreateFolder(params)
		return true, result, err
	case "copyObject":
		result, err := azureCopyObject(params)
		return true, result, err
	case "moveObject":
		result, err := azureMoveObject(params)
		return true, result, err
	case "deleteObjects":
		result, err := azureDeleteObjects(params)
		return true, result, err
	case "startUpload":
		result, err := azureStartUpload(params)
		return true, result, err
	case "startDownload":
		result, err := azureStartDownload(params)
		return true, result, err
	case "setBucketVersioning", "putBucketLifecycle", "deleteBucketLifecycle",
		"putBucketPolicy", "deleteBucketPolicy", "putBucketCors", "deleteBucketCors",
		"putBucketEncryption", "deleteBucketEncryption", "putBucketTagging",
		"deleteBucketTagging", "listObjectVersions", "deleteObjectVersions",
		"generatePresignedUrl":
		return true, nil, azureUnsupported(method)
	default:
		return false, nil, nil
	}
}

func azureTestProfile(profilePayload map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(profilePayload)
	if err != nil {
		return nil, err
	}
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		return nil, err
	}
	page, err := client.listContainersPage(ctx, "", 1)
	if err != nil {
		return nil, err
	}
	return map[string]interface{}{
		"ok":          true,
		"bucketCount": len(page.Containers),
		"endpoint":    client.base.Host,
	}, nil
}

func azureListBuckets(profilePayload map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(profilePayload)
	if err != nil {
		return nil, err
	}
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0)
	marker := ""
	for {
		page, pageErr := client.listContainersPage(ctx, marker, 0)
		if pageErr != nil {
			return nil, pageErr
		}
		for _, container := range page.Containers {
			items = append(items, map[string]interface{}{
				"name":              container.Name,
				"region":            p.Region,
				"objectCountHint":   0,
				"versioningEnabled": false,
				"createdAt":         azureTimeToRFC3339(container.Properties.LastModified),
			})
		}
		marker = strings.TrimSpace(page.NextMarker)
		if marker == "" {
			break
		}
	}
	return map[string]interface{}{"items": items}, nil
}

func azureCreateBucket(params map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return nil, err
	}
	bucketName := strings.TrimSpace(asString(params["bucketName"]))
	if bucketName == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name is required."}
	}
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		return nil, err
	}
	resp, err := client.do(ctx, http.MethodPut, bucketName, "", url.Values{"restype": []string{"container"}}, nil, nil)
	if err != nil {
		return nil, err
	}
	drainAndClose(resp.Body)
	return map[string]interface{}{
		"name":              bucketName,
		"region":            p.Region,
		"objectCountHint":   0,
		"versioningEnabled": false,
		"createdAt":         serializeTimePtr(time.Now().UTC()),
	}, nil
}

func azureDeleteBucket(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	resp, err := client.do(ctx, http.MethodDelete, bucketName, "", url.Values{"restype": []string{"container"}}, nil, nil)
	if err != nil {
		return nil, err
	}
	drainAndClose(resp.Body)
	return map[string]interface{}{"deleted": true, "bucketName": bucketName}, nil
}

func azureListObjects(params map[string]interface{}) (map[string]interface{}, error) {
	p, bucketName, client, ctx, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	prefix := asString(params["prefix"])
	flat := asBool(params["flat"])
	marker := ""
	if cursor := asMap(params["cursor"]); cursor != nil {
		marker = strings.TrimSpace(asString(cursor["value"]))
	}

	query := url.Values{
		"restype":    []string{"container"},
		"comp":       []string{"list"},
		"maxresults": []string{"1000"},
	}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	if !flat {
		query.Set("delimiter", "/")
	}
	if marker != "" {
		query.Set("marker", marker)
	}
	resp, err := client.do(ctx, http.MethodGet, bucketName, "", query, nil, nil)
	if err != nil {
		return nil, err
	}
	var listing azureListBlobsResult
	if err = decodeAzureXML(resp, &listing); err != nil {
		return nil, err
	}

	items := make([]map[string]interface{}, 0, len(listing.BlobPrefixes)+len(listing.Blobs))
	for _, blobPrefix := range listing.BlobPrefixes {
		folderPrefix := blobPrefix.Name
		folderName := folderPrefix
		if strings.HasPrefix(folderPrefix, prefix) {
			folderName = folderPrefix[len(prefix):]
		}
		items = append(items, map[string]interface{}{
			"key":           folderPrefix,
			"name":          nonEmpty(folderName, folderPrefix),
			"size":          0,
			"storageClass":  "FOLDER",
			"modifiedAt":    serializeTimePtr(time.Now().UTC()),
			"isFolder":      true,
			"etag":          nil,
			"metadataCount": 0,
		})
	}
	for _, blob := range listing.Blobs {
		key := blob.Name
		if !flat && key == prefix {
			continue
		}
		name := key
		if prefix != "" && strings.HasPrefix(key, prefix) {
			name = key[len(prefix):]
		}
		items = append(items, map[string]interface{}{
			"key":           key,
			"name":          nonEmpty(name, key),
			"size":          blob.Properties.ContentLength,
			"storageClass":  nonEmpty(blob.Properties.AccessTier, "STANDARD"),
			"modifiedAt":    azureTimeToRFC3339(blob.Properties.LastModified),
			"isFolder":      false,
			"etag":          trimQuotes(blob.Properties.Etag),
			"metadataCount": 0,
		})
	}
	sort.Slice(items, func(i, j int) bool {
		leftFolder := asBool(items[i]["isFolder"])
		rightFolder := asBool(items[j]["isFolder"])
		if leftFolder != rightFolder {
			return leftFolder
		}
		return strings.ToLower(asString(items[i]["key"])) < strings.ToLower(asString(items[j]["key"]))
	})

	nextMarker := strings.TrimSpace(listing.NextMarker)
	return map[string]interface{}{
		"items": items,
		"nextCursor": map[string]interface{}{
			"value":   nextMarker,
			"hasMore": nextMarker != "",
		},
		"profileRegion": p.Region,
	}, nil
}

func azureGetBucketAdminState(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, _, _, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	return map[string]interface{}{
		"bucketName":              bucketName,
		"versioningEnabled":       false,
		"versioningStatus":        "",
		"objectLockEnabled":       false,
		"lifecycleEnabled":        false,
		"policyAttached":          false,
		"corsEnabled":             false,
		"encryptionEnabled":       false,
		"encryptionSummary":       "Not configured",
		"objectLockMode":          nil,
		"objectLockRetentionDays": nil,
		"tags":                    map[string]string{},
		"lifecycleRules":          []map[string]interface{}{},
		"lifecycleJson":           `{"Rules":[]}`,
		"policyJson":              "{}",
		"corsJson":                "[]",
		"encryptionJson":          "{}",
		"apiCalls":                []map[string]interface{}{},
	}, nil
}

func azureGetObjectDetails(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	key := strings.TrimSpace(asString(params["key"]))
	if key == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and object key are required for object inspection."}
	}

	apiCalls := make([]map[string]interface{}, 0, 1)
	debugEvents := []map[string]interface{}{
		{
			"timestamp": serializeTimePtr(time.Now().UTC()),
			"level":     "DEBUG",
			"message":   fmt.Sprintf("Fetching object diagnostics for %s/%s.", bucketName, key),
		},
	}

	started := time.Now()
	resp, headErr := client.do(ctx, http.MethodHead, bucketName, key, nil, nil, nil)
	status := "ERROR"
	if headErr == nil {
		status = "200"
	}
	apiCalls = append(apiCalls, map[string]interface{}{
		"timestamp": serializeTimePtr(time.Now().UTC()),
		"operation": "GetBlobProperties",
		"status":    status,
		"latencyMs": int(time.Since(started).Milliseconds()),
	})
	if headErr != nil {
		return nil, headErr
	}
	drainAndClose(resp.Body)

	metadata := map[string]string{}
	for name, values := range resp.Header {
		lower := strings.ToLower(name)
		if strings.HasPrefix(lower, "x-ms-meta-") && len(values) > 0 {
			metadata[lower[len("x-ms-meta-"):]] = values[0]
		}
	}
	headers := map[string]string{
		"ETag":           trimQuotesString(resp.Header.Get("ETag")),
		"Content-Length": resp.Header.Get("Content-Length"),
		"Content-Type":   resp.Header.Get("Content-Type"),
		"Storage-Class":  resp.Header.Get("x-ms-access-tier"),
		"Cache-Control":  resp.Header.Get("Cache-Control"),
	}
	if lastModified := strings.TrimSpace(resp.Header.Get("Last-Modified")); lastModified != "" {
		headers["Last-Modified"] = azureTimeToRFC3339(lastModified)
	}
	for name, value := range headers {
		if strings.TrimSpace(value) == "" {
			delete(headers, name)
		}
	}
	debugEvents = append(debugEvents, map[string]interface{}{
		"timestamp": serializeTimePtr(time.Now().UTC()),
		"level":     "INFO",
		"message":   fmt.Sprintf("Loaded metadata and %d tag(s) for %s.", 0, key),
	})
	return map[string]interface{}{
		"key":         key,
		"metadata":    metadata,
		"headers":     headers,
		"tags":        map[string]string{},
		"debugEvents": debugEvents,
		"apiCalls":    apiCalls,
		"debugLogExcerpt": []string{
			fmt.Sprintf("Resolved endpoint %s.", client.base.String()),
			fmt.Sprintf("Completed HEAD diagnostics for %s/%s.", bucketName, key),
		},
		"rawDiagnostics": map[string]interface{}{
			"bucketName":  bucketName,
			"engineState": "healthy",
		},
	}, nil
}

func azureCreateFolder(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	key := strings.TrimSpace(asString(params["key"]))
	if key == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and key are required to create a folder."}
	}
	if !strings.HasSuffix(key, "/") {
		key += "/"
	}
	if err = client.putBlob(ctx, bucketName, key, nil, nil); err != nil {
		return nil, err
	}
	return map[string]interface{}{"created": true, "key": key}, nil
}

func azureCopyObject(params map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return nil, err
	}
	sourceBucket := strings.TrimSpace(asString(params["sourceBucketName"]))
	sourceKey := strings.TrimSpace(asString(params["sourceKey"]))
	destinationBucket := strings.TrimSpace(asString(params["destinationBucketName"]))
	destinationKey := strings.TrimSpace(asString(params["destinationKey"]))
	if sourceBucket == "" || sourceKey == "" || destinationBucket == "" || destinationKey == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Copy source and destination are required."}
	}
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		return nil, err
	}
	sourceURL := client.urlFor(sourceBucket, sourceKey).String()
	resp, err := client.do(ctx, http.MethodPut, destinationBucket, destinationKey, nil, map[string]string{
		"x-ms-copy-source": sourceURL,
	}, nil)
	if err != nil {
		return nil, err
	}
	copyStatus := strings.ToLower(strings.TrimSpace(resp.Header.Get("x-ms-copy-status")))
	drainAndClose(resp.Body)
	for attempt := 0; copyStatus == "pending" && attempt < azureCopyPollAttempts; attempt++ {
		time.Sleep(azureCopyPollInterval)
		head, headErr := client.do(ctx, http.MethodHead, destinationBucket, destinationKey, nil, nil, nil)
		if headErr != nil {
			return nil, headErr
		}
		copyStatus = strings.ToLower(strings.TrimSpace(head.Header.Get("x-ms-copy-status")))
		drainAndClose(head.Body)
	}
	if copyStatus == "failed" || copyStatus == "aborted" {
		return nil, &sidecarError{
			Code:    "unknown",
			Message: fmt.Sprintf("Azure blob copy finished with status %q.", copyStatus),
		}
	}
	return map[string]interface{}{"successCount": 1, "failureCount": 0, "failures": []interface{}{}}, nil
}

func azureMoveObject(params map[string]interface{}) (map[string]interface{}, error) {
	result, err := azureCopyObject(params)
	if err != nil {
		return nil, err
	}
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return nil, err
	}
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		return nil, err
	}
	if err = client.deleteBlob(
		ctx,
		strings.TrimSpace(asString(params["sourceBucketName"])),
		strings.TrimSpace(asString(params["sourceKey"])),
	); err != nil {
		return nil, err
	}
	return result, nil
}

func azureDeleteObjects(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	keys := asStringSlice(params["keys"])
	if len(keys) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and keys are required."}
	}
	var mu sync.Mutex
	successCount := 0
	failures := make([]map[string]interface{}, 0)
	semaphore := make(chan struct{}, azureDeleteConcurrency)
	var wg sync.WaitGroup
	for _, key := range keys {
		wg.Add(1)
		semaphore <- struct{}{}
		go func(key string) {
			defer wg.Done()
			defer func() { <-semaphore }()
			deleteErr := client.deleteBlob(ctx, bucketName, key)
			mu.Lock()
			defer mu.Unlock()
			if deleteErr == nil || isAzureNotFound(deleteErr) {
				successCount++
				return
			}
			code := "unknown"
			message := deleteErr.Error()
			var sideErr *sidecarError
			if errors.As(deleteErr, &sideErr) {
				message = sideErr.Message
				if azureCode := asString(sideErr.Details["azureCode"]); azureCode != "" {
					code = azureCode
				} else {
					code = sideErr.Code
				}
			}
			failures = append(failures, map[string]interface{}{
				"target":  key,
				"code":    nonEmpty(code, "unknown"),
				"message": nonEmpty(message, "Unknown delete error."),
			})
		}(key)
	}
	wg.Wait()
	return map[string]interface{}{
		"successCount": successCount,
		"failureCount": len(failures),
		"failures":     failures,
	}, nil
}

func azureStartUpload(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	prefix := strings.TrimSpace(asString(params["prefix"]))
	filePaths := asStringSlice(params["filePaths"])
	objectKeyByPath := asStringMap(params["objectKeyByPath"])
	if len(filePaths) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and file paths are required."}
	}
	thresholdBytes := azureSingleShotMaxBytes
	chunkBytes := azureBlockSizeBytes
	totalBytes := int64(0)
	partsTotal := 0
	usesMultipart := false
	for _, filePath := range filePaths {
		info, statErr := os.Stat(filePath)
		if statErr != nil {
			return nil, statErr
		}
		totalBytes += info.Size()
		if info.Size() >= thresholdBytes {
			usesMultipart = true
			partsTotal += int((info.Size() + chunkBytes - 1) / chunkBytes)
		}
	}
	jobID := fmt.Sprintf("upload-%d", time.Now().UnixNano())
	label := fmt.Sprintf("Upload %d file(s) to %s", len(filePaths), bucketName)
	outputLines := []string{fmt.Sprintf("Queued %d file(s) for upload to %s.", len(filePaths), bucketName)}
	bytesTransferred := int64(0)
	itemsCompleted := 0
	partsCompleted := 0
	partSize := interface{}(nil)
	partCount := interface{}(nil)
	partDone := interface{}(nil)
	if partsTotal > 0 {
		partSize = chunkBytes
		partCount = partsTotal
		partDone = 0
	}
	emitTransferEvent(buildTransferJob(jobID, label, "upload", 0, "queued", bytesTransferred, totalBytes, transferStrategyLabel("upload", usesMultipart), filepath.Base(filePaths[0]), len(filePaths), itemsCompleted, partSize, partDone, partCount, true, false, true, append([]string{}, outputLines...)))
	for _, filePath := range filePaths {
		handle, openErr := os.Open(filePath)
		if openErr != nil {
			return nil, openErr
		}
		info, statErr := handle.Stat()
		if statErr != nil {
			handle.Close()
			return nil, statErr
		}
		targetKey := filepath.Base(filePath)
		if mappedKey, ok := objectKeyByPath[filePath]; ok && strings.TrimSpace(mappedKey) != "" {
			targetKey = strings.TrimLeft(strings.ReplaceAll(mappedKey, "\\", "/"), "/")
		}
		if prefix != "" {
			targetKey = prefix + targetKey
		}
		outputLines = append(outputLines, fmt.Sprintf("Uploading %s (%d bytes) to %s.", info.Name(), info.Size(), targetKey))
		if info.Size() >= thresholdBytes {
			blockIDs := make([]string, 0, int((info.Size()+chunkBytes-1)/chunkBytes))
			partNumber := 1
			for {
				chunk := make([]byte, chunkBytes)
				readBytes, readErr := io.ReadFull(handle, chunk)
				if readErr != nil && !errors.Is(readErr, io.EOF) && !errors.Is(readErr, io.ErrUnexpectedEOF) {
					handle.Close()
					return nil, readErr
				}
				if readBytes == 0 {
					break
				}
				chunk = chunk[:readBytes]
				blockID := base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("block-%08d", partNumber)))
				query := url.Values{
					"comp":    []string{"block"},
					"blockid": []string{blockID},
				}
				resp, blockErr := client.do(ctx, http.MethodPut, bucketName, targetKey, query, nil, chunk)
				if blockErr != nil {
					handle.Close()
					return nil, blockErr
				}
				drainAndClose(resp.Body)
				blockIDs = append(blockIDs, blockID)
				bytesTransferred += int64(readBytes)
				partsCompleted++
				partDone = partsCompleted
				outputLines = append(outputLines, fmt.Sprintf("Uploaded part %d for %s.", partNumber, info.Name()))
				emitTransferEvent(buildTransferJob(jobID, label, "upload", progressFraction(bytesTransferred, totalBytes), "running", bytesTransferred, totalBytes, transferStrategyLabel("upload", usesMultipart), info.Name(), len(filePaths), itemsCompleted, partSize, partDone, partCount, true, false, true, append([]string{}, outputLines...)))
				partNumber++
				if errors.Is(readErr, io.EOF) || errors.Is(readErr, io.ErrUnexpectedEOF) {
					break
				}
			}
			blockListXML := &strings.Builder{}
			blockListXML.WriteString(`<?xml version="1.0" encoding="utf-8"?><BlockList>`)
			for _, blockID := range blockIDs {
				blockListXML.WriteString("<Latest>" + blockID + "</Latest>")
			}
			blockListXML.WriteString("</BlockList>")
			resp, commitErr := client.do(ctx, http.MethodPut, bucketName, targetKey, url.Values{"comp": []string{"blocklist"}}, map[string]string{
				"Content-Type": "application/xml",
			}, []byte(blockListXML.String()))
			if commitErr != nil {
				handle.Close()
				return nil, commitErr
			}
			drainAndClose(resp.Body)
		} else {
			data, readErr := io.ReadAll(handle)
			if readErr != nil {
				handle.Close()
				return nil, readErr
			}
			if err = client.putBlob(ctx, bucketName, targetKey, data, nil); err != nil {
				handle.Close()
				return nil, err
			}
			bytesTransferred += info.Size()
		}
		handle.Close()
		itemsCompleted++
		outputLines = append(outputLines, fmt.Sprintf("Finished uploading %s.", info.Name()))
		emitTransferEvent(buildTransferJob(jobID, label, "upload", progressFraction(bytesTransferred, totalBytes), "running", bytesTransferred, totalBytes, transferStrategyLabel("upload", usesMultipart), info.Name(), len(filePaths), itemsCompleted, partSize, partDone, partCount, true, false, true, append([]string{}, outputLines...)))
	}
	outputLines = append(outputLines, fmt.Sprintf("Uploaded %d file(s) into %s.", len(filePaths), bucketName))
	return buildTransferJob(jobID, label, "upload", 1, "completed", bytesTransferred, totalBytes, transferStrategyLabel("upload", usesMultipart), filepath.Base(filePaths[len(filePaths)-1]), len(filePaths), itemsCompleted, partSize, partDone, partCount, false, false, false, outputLines), nil
}

func azureStartDownload(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := azureBucketClient(params)
	if err != nil {
		return nil, err
	}
	keys := asStringSlice(params["keys"])
	destinationPath := strings.TrimSpace(asString(params["destinationPath"]))
	if len(keys) == 0 || destinationPath == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket, keys, and destination path are required."}
	}
	thresholdBytes := int64(maxInt(asInt(params["multipartThresholdMiB"]), 1, 32)) * 1024 * 1024
	chunkBytes := int64(maxInt(asInt(params["multipartChunkMiB"]), 1, 8)) * 1024 * 1024
	if err = os.MkdirAll(destinationPath, 0o755); err != nil {
		return nil, err
	}
	totalBytes := int64(0)
	partsTotal := 0
	usesMultipart := false
	objectSizes := make(map[string]int64, len(keys))
	for _, key := range keys {
		head, headErr := client.do(ctx, http.MethodHead, bucketName, key, nil, nil, nil)
		if headErr != nil {
			return nil, headErr
		}
		size, _ := strconv.ParseInt(head.Header.Get("Content-Length"), 10, 64)
		drainAndClose(head.Body)
		objectSizes[key] = size
		totalBytes += size
		if size >= thresholdBytes {
			usesMultipart = true
			partsTotal += int((size + chunkBytes - 1) / chunkBytes)
		}
	}
	jobID := fmt.Sprintf("download-%d", time.Now().UnixNano())
	label := fmt.Sprintf("Download %d object(s) from %s", len(keys), bucketName)
	outputLines := []string{fmt.Sprintf("Queued %d object(s) for download to %s.", len(keys), destinationPath)}
	bytesTransferred := int64(0)
	itemsCompleted := 0
	partsCompleted := 0
	partSize := interface{}(nil)
	partCount := interface{}(nil)
	partDone := interface{}(nil)
	if partsTotal > 0 {
		partSize = chunkBytes
		partCount = partsTotal
		partDone = 0
	}
	emitTransferEvent(buildTransferJob(jobID, label, "download", 0, "queued", bytesTransferred, totalBytes, transferStrategyLabel("download", usesMultipart), keys[0], len(keys), itemsCompleted, partSize, partDone, partCount, true, false, true, append([]string{}, outputLines...)))
	for _, key := range keys {
		size := objectSizes[key]
		target := filepath.Join(destinationPath, filepath.Base(key))
		handle, createErr := os.Create(target)
		if createErr != nil {
			return nil, createErr
		}
		outputLines = append(outputLines, fmt.Sprintf("Downloading %s (%d bytes) to %s.", key, size, target))
		if size >= thresholdBytes {
			for start := int64(0); start < size; start += chunkBytes {
				end := start + chunkBytes - 1
				if end >= size {
					end = size - 1
				}
				rangeHeader := fmt.Sprintf("bytes=%d-%d", start, end)
				resp, getErr := client.do(ctx, http.MethodGet, bucketName, key, nil, map[string]string{"Range": rangeHeader}, nil)
				if getErr != nil {
					handle.Close()
					return nil, getErr
				}
				copied, copyErr := io.Copy(handle, resp.Body)
				resp.Body.Close()
				if copyErr != nil {
					handle.Close()
					return nil, copyErr
				}
				bytesTransferred += copied
				partsCompleted++
				partDone = partsCompleted
				outputLines = append(outputLines, fmt.Sprintf("Downloaded byte range %d-%d for %s.", start, end, key))
				emitTransferEvent(buildTransferJob(jobID, label, "download", progressFraction(bytesTransferred, totalBytes), "running", bytesTransferred, totalBytes, transferStrategyLabel("download", usesMultipart), key, len(keys), itemsCompleted, partSize, partDone, partCount, true, false, true, append([]string{}, outputLines...)))
			}
		} else {
			resp, getErr := client.do(ctx, http.MethodGet, bucketName, key, nil, nil, nil)
			if getErr != nil {
				handle.Close()
				return nil, getErr
			}
			buffer := make([]byte, minInt64(chunkBytes, 1024*1024))
			for {
				readBytes, readErr := resp.Body.Read(buffer)
				if readBytes > 0 {
					if _, writeErr := handle.Write(buffer[:readBytes]); writeErr != nil {
						resp.Body.Close()
						handle.Close()
						return nil, writeErr
					}
					bytesTransferred += int64(readBytes)
					emitTransferEvent(buildTransferJob(jobID, label, "download", progressFraction(bytesTransferred, totalBytes), "running", bytesTransferred, totalBytes, transferStrategyLabel("download", usesMultipart), key, len(keys), itemsCompleted, partSize, partDone, partCount, true, false, true, append([]string{}, outputLines...)))
				}
				if errors.Is(readErr, io.EOF) {
					break
				}
				if readErr != nil {
					resp.Body.Close()
					handle.Close()
					return nil, readErr
				}
			}
			resp.Body.Close()
		}
		handle.Close()
		itemsCompleted++
		outputLines = append(outputLines, fmt.Sprintf("Finished downloading %s.", key))
	}
	outputLines = append(outputLines, fmt.Sprintf("Downloaded %d object(s) into %s.", len(keys), destinationPath))
	return buildTransferJob(jobID, label, "download", 1, "completed", bytesTransferred, totalBytes, transferStrategyLabel("download", usesMultipart), keys[len(keys)-1], len(keys), itemsCompleted, partSize, partDone, partCount, false, false, false, outputLines), nil
}

func buildAzureBenchmarkExecutor(p profile, bucketName string) (*benchmarkExecutor, error) {
	client, ctx, err := buildAzureClient(p)
	if err != nil {
		return nil, err
	}
	return &benchmarkExecutor{
		put: func(key string, payload []byte) error {
			return client.putBlob(ctx, bucketName, key, payload, nil)
		},
		get: func(key string) ([]byte, error) {
			return client.getBlobAll(ctx, bucketName, key)
		},
		deleteOne: func(key string) error {
			return client.deleteBlob(ctx, bucketName, key)
		},
		deleteBatch: nil,
	}, nil
}
