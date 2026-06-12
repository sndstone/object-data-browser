package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

var supportedMethods = []string{
	"health", "getCapabilities", "testProfile", "listBuckets",
	"createBucket", "deleteBucket", "setBucketVersioning",
	"putBucketLifecycle", "deleteBucketLifecycle", "putBucketPolicy",
	"deleteBucketPolicy", "putBucketCors", "deleteBucketCors",
	"putBucketEncryption", "deleteBucketEncryption", "putBucketTagging",
	"deleteBucketTagging", "listObjects", "getBucketAdminState",
	"listObjectVersions", "getObjectDetails", "createFolder",
	"copyObject", "moveObject", "deleteObjects", "deleteObjectVersions",
	"startUpload", "startDownload", "pauseTransfer", "resumeTransfer",
	"cancelTransfer", "generatePresignedUrl", "runPutTestData",
	"runDeleteAll", "cancelToolExecution", "startBenchmark",
	"getBenchmarkStatus", "pauseBenchmark", "resumeBenchmark",
	"stopBenchmark", "exportBenchmarkResults",
}

type request struct {
	RequestID string                 `json:"requestId"`
	Method    string                 `json:"method"`
	Params    map[string]interface{} `json:"params"`
}

type response struct {
	RequestID string      `json:"requestId"`
	OK        bool        `json:"ok"`
	Result    interface{} `json:"result,omitempty"`
	Error     interface{} `json:"error,omitempty"`
}

type sidecarError struct {
	Code    string                 `json:"code"`
	Message string                 `json:"message"`
	Details map[string]interface{} `json:"details,omitempty"`
}

func (e *sidecarError) Error() string {
	return e.Message
}

type profile struct {
	EndpointURL           string
	EndpointType          string
	Region                string
	AccessKey             string
	SecretKey             string
	SessionToken          string
	PathStyle             bool
	VerifyTLS             bool
	ConnectTimeoutSeconds int
	ReadTimeoutSeconds    int
	MaxAttempts           int
	MaxPoolConnections    int
	Diagnostics           diagnosticsConfig
}

type diagnosticsConfig struct {
	EnableAPILogging   bool
	EnableDebugLogging bool
}

func parseDiagnostics(payload map[string]interface{}) diagnosticsConfig {
	raw := asMap(payload["diagnostics"])
	return diagnosticsConfig{
		EnableAPILogging:   asBool(raw["enableApiLogging"]),
		EnableDebugLogging: asBool(raw["enableDebugLogging"]),
	}
}

func emitStructuredLog(level, category, message, source string) {
	payload, err := json.Marshal(map[string]interface{}{
		"level":    level,
		"category": category,
		"message":  message,
		"source":   source,
	})
	if err != nil {
		return
	}
	fmt.Fprintln(os.Stderr, "S3_BROWSER_LOG "+string(payload))
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var req request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}
		if req.Params == nil {
			req.Params = map[string]interface{}{}
		}

		result, err := handleRequest(req)
		if err != nil {
			mapped := mapError(err)
			writeJSON(response{
				RequestID: req.RequestID,
				OK:        false,
				Error:     mapped,
			})
			continue
		}

		writeJSON(response{
			RequestID: req.RequestID,
			OK:        true,
			Result:    result,
		})
	}
}

func writeJSON(value response) {
	out, _ := json.Marshal(value)
	fmt.Println(string(out))
}

func handleRequest(req request) (map[string]interface{}, error) {
	if isAzureProfilePayload(asMap(req.Params["profile"])) {
		if handled, result, err := handleAzureRequest(req.Method, req.Params); handled {
			return result, err
		}
	}
	switch req.Method {
	case "health":
		return map[string]interface{}{
			"engine":        "go",
			"version":       "2.1.0",
			"available":     true,
			"methods":       supportedMethods,
			"nativeSdk":     "aws-sdk-go-v2",
			"endpointTypes": []string{"s3Compatible", "awsS3", "azureBlob"},
		}, nil
	case "getCapabilities":
		return map[string]interface{}{
			"items": []map[string]interface{}{
				{"key": "bucket.lifecycle", "label": "Lifecycle policy CRUD", "state": "supported"},
				{"key": "bucket.policy", "label": "Bucket policy CRUD", "state": "supported"},
				{"key": "bucket.cors", "label": "Bucket CORS CRUD", "state": "supported"},
				{"key": "bucket.encryption", "label": "Bucket encryption", "state": "supported"},
				{"key": "bucket.tagging", "label": "Bucket tagging", "state": "supported"},
				{"key": "bucket.versioning", "label": "Bucket versioning", "state": "supported"},
				{"key": "object.copy_move", "label": "Copy, move, rename", "state": "supported"},
				{"key": "object.resumable", "label": "Resumable transfer jobs", "state": "unknown", "reason": "Desktop host currently uses one request per sidecar process."},
				{"key": "tools.bulk-delete", "label": "Delete-all maintenance tool", "state": "supported"},
				{"key": "benchmark", "label": "Integrated benchmark mode", "state": "supported"},
			},
		}, nil
	case "testProfile":
		return testProfile(asMap(req.Params["profile"]))
	case "listBuckets":
		return listBuckets(asMap(req.Params["profile"]))
	case "createBucket":
		return createBucket(req.Params)
	case "deleteBucket":
		return deleteBucket(req.Params)
	case "setBucketVersioning":
		return setBucketVersioning(req.Params)
	case "putBucketLifecycle":
		return putBucketLifecycle(req.Params)
	case "deleteBucketLifecycle":
		return deleteBucketLifecycle(req.Params)
	case "putBucketPolicy":
		return putBucketPolicy(req.Params)
	case "deleteBucketPolicy":
		return deleteBucketPolicy(req.Params)
	case "putBucketCors":
		return putBucketCors(req.Params)
	case "deleteBucketCors":
		return deleteBucketCors(req.Params)
	case "putBucketEncryption":
		return putBucketEncryption(req.Params)
	case "deleteBucketEncryption":
		return deleteBucketEncryption(req.Params)
	case "putBucketTagging":
		return putBucketTagging(req.Params)
	case "deleteBucketTagging":
		return deleteBucketTagging(req.Params)
	case "listObjects":
		return listObjects(req.Params)
	case "getBucketAdminState":
		return getBucketAdminState(req.Params)
	case "listObjectVersions":
		return listObjectVersions(req.Params)
	case "getObjectDetails":
		return getObjectDetails(req.Params)
	case "createFolder":
		return createFolder(req.Params)
	case "copyObject":
		return copyObject(req.Params)
	case "moveObject":
		return moveObject(req.Params)
	case "deleteObjects":
		return deleteObjects(req.Params)
	case "deleteObjectVersions":
		return deleteObjectVersions(req.Params)
	case "startUpload":
		return startUpload(req.Params)
	case "startDownload":
		return startDownload(req.Params)
	case "pauseTransfer":
		return transferControl(req.Params, "paused"), nil
	case "resumeTransfer":
		return transferControl(req.Params, "running"), nil
	case "cancelTransfer":
		return transferControl(req.Params, "cancelled"), nil
	case "generatePresignedUrl":
		return generatePresignedURL(req.Params)
	case "runPutTestData":
		return runPutTestData(req.Params), nil
	case "runDeleteAll":
		return runDeleteAll(req.Params), nil
	case "cancelToolExecution":
		return cancelToolExecution(req.Params), nil
	case "startBenchmark":
		return startBenchmark(req.Params)
	case "getBenchmarkStatus":
		return getBenchmarkStatus(req.Params)
	case "pauseBenchmark":
		return pauseBenchmark(req.Params)
	case "resumeBenchmark":
		return resumeBenchmark(req.Params)
	case "stopBenchmark":
		return stopBenchmark(req.Params)
	case "exportBenchmarkResults":
		return exportBenchmarkResults(req.Params)
	default:
		return nil, &sidecarError{
			Code:    "unsupported_feature",
			Message: fmt.Sprintf("Method %s is not implemented in the Go engine.", req.Method),
		}
	}
}

func parseProfile(payload map[string]interface{}) (profile, error) {
	endpointURL := strings.TrimSpace(asString(payload["endpointUrl"]))
	endpointType := strings.TrimSpace(asString(payload["endpointType"]))
	accessKey := strings.TrimSpace(asString(payload["accessKey"]))
	secretKey := strings.TrimSpace(asString(payload["secretKey"]))
	region := strings.TrimSpace(asString(payload["region"]))
	if region == "" {
		region = "us-east-1"
	}
	if endpointURL == "" && !isAzureProfilePayload(payload) {
		return profile{}, &sidecarError{Code: "invalid_config", Message: "Endpoint URL is required."}
	}
	if accessKey == "" || secretKey == "" {
		return profile{}, &sidecarError{Code: "invalid_config", Message: "Access key and secret key are required."}
	}
	return profile{
		EndpointURL:           endpointURL,
		EndpointType:          endpointType,
		Region:                region,
		AccessKey:             accessKey,
		SecretKey:             secretKey,
		SessionToken:          strings.TrimSpace(asString(payload["sessionToken"])),
		PathStyle:             asBool(payload["pathStyle"]),
		VerifyTLS:             !payloadHasFalse(payload["verifyTls"]),
		ConnectTimeoutSeconds: maxInt(asInt(payload["connectTimeoutSeconds"]), 1, 5),
		ReadTimeoutSeconds:    maxInt(asInt(payload["readTimeoutSeconds"]), 1, 60),
		MaxAttempts:           maxInt(asInt(payload["maxAttempts"]), 1, 5),
		MaxPoolConnections:    maxInt(asInt(payload["maxConcurrentRequests"]), 1, 10),
		Diagnostics:           parseDiagnostics(payload),
	}, nil
}

func buildClient(p profile) (*s3.Client, context.Context, error) {
	ctx := context.Background()
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

	cfg, err := config.LoadDefaultConfig(
		ctx,
		config.WithRegion(p.Region),
		config.WithHTTPClient(httpClient),
		config.WithRetryMaxAttempts(p.MaxAttempts),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			p.AccessKey,
			p.SecretKey,
			p.SessionToken,
		)),
	)
	if err != nil {
		return nil, ctx, err
	}

	client := s3.NewFromConfig(cfg, func(options *s3.Options) {
		options.UsePathStyle = p.PathStyle
		options.BaseEndpoint = aws.String(p.EndpointURL)
	})

	return client, ctx, nil
}

type loggingRoundTripper struct {
	base        http.RoundTripper
	diagnostics diagnosticsConfig
}

func (rt loggingRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	if rt.diagnostics.EnableAPILogging {
		requestBody := summarizeHTTPBody(
			request.Header.Get("Content-Type"),
			request.ContentLength,
			readRequestBody(request),
		)
		emitStructuredLog(
			"API",
			"HttpSend",
			fmt.Sprintf(
				"SEND %s %s HEADERS=%s BODY=%s",
				request.Method,
				request.URL.String(),
				mustJSONString(sanitizeHeaders(request.Header)),
				requestBody,
			),
			"api",
		)
	}
	response, err := rt.base.RoundTrip(request)
	if err != nil {
		if rt.diagnostics.EnableDebugLogging {
			emitStructuredLog("DEBUG", "HttpError", err.Error(), "debug")
		}
		return nil, err
	}
	if rt.diagnostics.EnableAPILogging {
		responseBody := summarizeHTTPBody(
			response.Header.Get("Content-Type"),
			response.ContentLength,
			readResponseBody(response),
		)
		emitStructuredLog(
			"API",
			"HttpReceive",
			fmt.Sprintf(
				"RECV %s %s STATUS=%d HEADERS=%s BODY=%s",
				request.Method,
				request.URL.String(),
				response.StatusCode,
				mustJSONString(sanitizeHeaders(response.Header)),
				responseBody,
			),
			"api",
		)
	}
	return response, nil
}

func readRequestBody(request *http.Request) []byte {
	if request.Body == nil {
		return nil
	}
	body, err := io.ReadAll(request.Body)
	if err != nil {
		return nil
	}
	request.Body = io.NopCloser(bytes.NewReader(body))
	return body
}

func readResponseBody(response *http.Response) []byte {
	if response.Body == nil || response.ContentLength > 1024*256 {
		return nil
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return nil
	}
	response.Body = io.NopCloser(bytes.NewReader(body))
	return body
}

func sanitizeHeaders(headers http.Header) map[string]string {
	sanitized := map[string]string{}
	for key, values := range headers {
		lower := strings.ToLower(key)
		if strings.Contains(lower, "authorization") ||
			strings.Contains(lower, "security-token") ||
			strings.Contains(lower, "access-key") ||
			strings.Contains(lower, "secret") ||
			strings.Contains(lower, "token") {
			sanitized[key] = "[redacted]"
			continue
		}
		sanitized[key] = strings.Join(values, ", ")
	}
	return sanitized
}

func summarizeHTTPBody(contentType string, contentLength int64, body []byte) string {
	if len(body) == 0 {
		return "null"
	}
	if contentLength > 1024*256 {
		return "[omitted large body]"
	}
	lowerType := strings.ToLower(contentType)
	if strings.Contains(lowerType, "octet-stream") ||
		strings.Contains(lowerType, "application/x-www-form-urlencoded") {
		return "[omitted binary body]"
	}
	if !utf8.Valid(body) {
		return "[omitted binary body]"
	}
	text := strings.TrimSpace(string(body))
	if text == "" {
		return "null"
	}
	if len(text) > 16000 {
		text = text[:16000] + "...(truncated)"
	}
	return text
}

func mustJSONString(value interface{}) string {
	data, err := json.Marshal(value)
	if err != nil {
		return "{}"
	}
	return string(data)
}

func testProfile(profilePayload map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(profilePayload)
	if err != nil {
		return nil, err
	}
	client, ctx, err := buildClient(p)
	if err != nil {
		return nil, err
	}
	output, err := client.ListBuckets(ctx, &s3.ListBucketsInput{})
	if err != nil {
		return nil, err
	}
	host := p.EndpointURL
	if parsed, parseErr := url.Parse(p.EndpointURL); parseErr == nil && parsed.Host != "" {
		host = parsed.Host
	}
	return map[string]interface{}{
		"ok":          true,
		"bucketCount": len(output.Buckets),
		"endpoint":    host,
	}, nil
}

func listBuckets(profilePayload map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(profilePayload)
	if err != nil {
		return nil, err
	}
	client, ctx, err := buildClient(p)
	if err != nil {
		return nil, err
	}
	output, err := client.ListBuckets(ctx, &s3.ListBucketsInput{})
	if err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0, len(output.Buckets))
	for _, bucket := range output.Buckets {
		items = append(items, map[string]interface{}{
			"name":              aws.ToString(bucket.Name),
			"region":            p.Region,
			"objectCountHint":   0,
			"versioningEnabled": false,
			"createdAt":         serializeTime(bucket.CreationDate),
		})
	}
	return map[string]interface{}{"items": items}, nil
}

func createBucket(params map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return nil, err
	}
	bucketName := strings.TrimSpace(asString(params["bucketName"]))
	enableVersioning := asBool(params["enableVersioning"])
	enableObjectLock := asBool(params["enableObjectLock"])
	if bucketName == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name is required."}
	}

	client, ctx, err := buildClient(p)
	if err != nil {
		return nil, err
	}

	input := &s3.CreateBucketInput{
		Bucket: aws.String(bucketName),
	}
	if p.Region != "us-east-1" {
		input.CreateBucketConfiguration = &types.CreateBucketConfiguration{
			LocationConstraint: types.BucketLocationConstraint(p.Region),
		}
	}
	if enableObjectLock {
		input.ObjectLockEnabledForBucket = aws.Bool(true)
	}
	if _, err = client.CreateBucket(ctx, input); err != nil {
		return nil, err
	}
	if enableVersioning {
		if _, err = client.PutBucketVersioning(ctx, &s3.PutBucketVersioningInput{
			Bucket: aws.String(bucketName),
			VersioningConfiguration: &types.VersioningConfiguration{
				Status: types.BucketVersioningStatusEnabled,
			},
		}); err != nil {
			return nil, err
		}
	}
	return map[string]interface{}{
		"name":              bucketName,
		"region":            p.Region,
		"objectCountHint":   0,
		"versioningEnabled": enableVersioning,
		"createdAt":         serializeTimePtr(time.Now().UTC()),
	}, nil
}

func deleteBucket(params map[string]interface{}) (map[string]interface{}, error) {
	p, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	_ = p
	if _, err = client.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: aws.String(bucketName)}); err != nil {
		return nil, err
	}
	return map[string]interface{}{"deleted": true, "bucketName": bucketName}, nil
}

func setBucketVersioning(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	status := types.BucketVersioningStatusSuspended
	if asBool(params["enabled"]) {
		status = types.BucketVersioningStatusEnabled
	}
	if _, err = client.PutBucketVersioning(ctx, &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucketName),
		VersioningConfiguration: &types.VersioningConfiguration{
			Status: status,
		},
	}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func listObjects(params map[string]interface{}) (map[string]interface{}, error) {
	p, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	prefix := asString(params["prefix"])
	flat := asBool(params["flat"])
	var continuation *string
	if cursor := asMap(params["cursor"]); cursor != nil {
		value := strings.TrimSpace(asString(cursor["value"]))
		if value != "" {
			continuation = aws.String(value)
		}
	}

	input := &s3.ListObjectsV2Input{
		Bucket:  aws.String(bucketName),
		Prefix:  aws.String(prefix),
		MaxKeys: aws.Int32(1000),
	}
	if !flat {
		input.Delimiter = aws.String("/")
	}
	if continuation != nil {
		input.ContinuationToken = continuation
	}
	output, err := client.ListObjectsV2(ctx, input)
	if err != nil {
		return nil, err
	}

	items := make([]map[string]interface{}, 0, len(output.CommonPrefixes)+len(output.Contents))
	for _, commonPrefix := range output.CommonPrefixes {
		folderPrefix := aws.ToString(commonPrefix.Prefix)
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
	for _, object := range output.Contents {
		key := aws.ToString(object.Key)
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
			"size":          object.Size,
			"storageClass":  string(object.StorageClass),
			"modifiedAt":    serializeTime(object.LastModified),
			"isFolder":      false,
			"etag":          trimQuotes(aws.ToString(object.ETag)),
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

	return map[string]interface{}{
		"items": items,
		"nextCursor": map[string]interface{}{
			"value":   aws.ToString(output.NextContinuationToken),
			"hasMore": output.IsTruncated,
		},
		"profileRegion": p.Region,
	}, nil
}

func getBucketAdminState(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}

	apiCalls := make([]map[string]interface{}, 0, 7)
	versioningOut, err := callAPI(ctx, client, &apiCalls, "GetBucketVersioning", func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetBucketVersioning(ctx, &s3.GetBucketVersioningInput{Bucket: aws.String(bucketName)})
	})
	if err != nil {
		return nil, err
	}

	encryptionOut, err := optionalAPI(ctx, client, &apiCalls, "GetBucketEncryption", missingBucketConfigCodes(), func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetBucketEncryption(ctx, &s3.GetBucketEncryptionInput{Bucket: aws.String(bucketName)})
	})
	if err != nil {
		return nil, err
	}
	lifecycleOut, err := optionalAPI(ctx, client, &apiCalls, "GetBucketLifecycleConfiguration", missingBucketConfigCodes(), func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetBucketLifecycleConfiguration(ctx, &s3.GetBucketLifecycleConfigurationInput{Bucket: aws.String(bucketName)})
	})
	if err != nil {
		return nil, err
	}
	policyOut, err := optionalAPI(ctx, client, &apiCalls, "GetBucketPolicy", missingBucketConfigCodes(), func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetBucketPolicy(ctx, &s3.GetBucketPolicyInput{Bucket: aws.String(bucketName)})
	})
	if err != nil {
		return nil, err
	}
	corsOut, err := optionalAPI(ctx, client, &apiCalls, "GetBucketCors", missingBucketConfigCodes(), func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetBucketCors(ctx, &s3.GetBucketCorsInput{Bucket: aws.String(bucketName)})
	})
	if err != nil {
		return nil, err
	}
	taggingOut, err := optionalAPI(ctx, client, &apiCalls, "GetBucketTagging", missingBucketConfigCodes(), func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetBucketTagging(ctx, &s3.GetBucketTaggingInput{Bucket: aws.String(bucketName)})
	})
	if err != nil {
		return nil, err
	}
	lockOut, err := optionalAPI(ctx, client, &apiCalls, "GetObjectLockConfiguration", missingBucketConfigCodes(), func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetObjectLockConfiguration(ctx, &s3.GetObjectLockConfigurationInput{Bucket: aws.String(bucketName)})
	})
	if err != nil {
		return nil, err
	}

	versioning := versioningOut.(*s3.GetBucketVersioningOutput)
	var encryption *s3.GetBucketEncryptionOutput
	if encryptionOut != nil {
		encryption = encryptionOut.(*s3.GetBucketEncryptionOutput)
	}
	var lifecycle *s3.GetBucketLifecycleConfigurationOutput
	if lifecycleOut != nil {
		lifecycle = lifecycleOut.(*s3.GetBucketLifecycleConfigurationOutput)
	}
	var policy *s3.GetBucketPolicyOutput
	if policyOut != nil {
		policy = policyOut.(*s3.GetBucketPolicyOutput)
	}
	var cors *s3.GetBucketCorsOutput
	if corsOut != nil {
		cors = corsOut.(*s3.GetBucketCorsOutput)
	}
	var tagging *s3.GetBucketTaggingOutput
	if taggingOut != nil {
		tagging = taggingOut.(*s3.GetBucketTaggingOutput)
	}
	var lockConfig *s3.GetObjectLockConfigurationOutput
	if lockOut != nil {
		lockConfig = lockOut.(*s3.GetObjectLockConfigurationOutput)
	}

	lifecycleRules := make([]map[string]interface{}, 0)
	if lifecycle != nil {
		for _, rule := range lifecycle.Rules {
			lifecycleRules = append(lifecycleRules, lifecycleRuleToMap(rule))
		}
	}

	encryptionSummary := "Not configured"
	if encryption != nil && encryption.ServerSideEncryptionConfiguration != nil && len(encryption.ServerSideEncryptionConfiguration.Rules) > 0 {
		applyDefault := encryption.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault
		algo := string(applyDefault.SSEAlgorithm)
		if applyDefault.KMSMasterKeyID != nil && aws.ToString(applyDefault.KMSMasterKeyID) != "" {
			encryptionSummary = fmt.Sprintf("%s (%s)", algo, aws.ToString(applyDefault.KMSMasterKeyID))
		} else {
			encryptionSummary = algo
		}
	}

	tags := map[string]string{}
	if tagging != nil {
		for _, tag := range tagging.TagSet {
			tags[aws.ToString(tag.Key)] = aws.ToString(tag.Value)
		}
	}

	objectLockMode := ""
	objectLockRetention := interface{}(nil)
	if lockConfig != nil && lockConfig.ObjectLockConfiguration != nil && lockConfig.ObjectLockConfiguration.Rule != nil && lockConfig.ObjectLockConfiguration.Rule.DefaultRetention != nil {
		objectLockMode = string(lockConfig.ObjectLockConfiguration.Rule.DefaultRetention.Mode)
		if lockConfig.ObjectLockConfiguration.Rule.DefaultRetention.Days != nil {
			objectLockRetention = aws.ToInt32(lockConfig.ObjectLockConfiguration.Rule.DefaultRetention.Days)
		} else if lockConfig.ObjectLockConfiguration.Rule.DefaultRetention.Years != nil {
			objectLockRetention = aws.ToInt32(lockConfig.ObjectLockConfiguration.Rule.DefaultRetention.Years)
		}
	}

	policyJSON := "{}"
	if policy != nil && policy.Policy != nil && aws.ToString(policy.Policy) != "" {
		policyJSON = aws.ToString(policy.Policy)
	}
	corsJSON := "[]"
	if cors != nil {
		corsJSON = mustJSON(cors.CORSRules)
	}
	encryptionJSON := "{}"
	if encryption != nil && encryption.ServerSideEncryptionConfiguration != nil {
		encryptionJSON = mustJSON(encryption.ServerSideEncryptionConfiguration)
	}
	lifecycleJSON := `{"Rules":[]}`
	if lifecycle != nil {
		lifecycleJSON = mustJSON(map[string]interface{}{"Rules": lifecycle.Rules})
	}

	return map[string]interface{}{
		"bucketName":              bucketName,
		"versioningEnabled":       versioning.Status == types.BucketVersioningStatusEnabled,
		"versioningStatus":        string(versioning.Status),
		"objectLockEnabled":       lockConfig != nil && lockConfig.ObjectLockConfiguration != nil,
		"lifecycleEnabled":        len(lifecycleRules) > 0,
		"policyAttached":          policy != nil && policy.Policy != nil && aws.ToString(policy.Policy) != "",
		"corsEnabled":             cors != nil && len(cors.CORSRules) > 0,
		"encryptionEnabled":       encryption != nil && encryption.ServerSideEncryptionConfiguration != nil && len(encryption.ServerSideEncryptionConfiguration.Rules) > 0,
		"encryptionSummary":       encryptionSummary,
		"objectLockMode":          emptyToNil(objectLockMode),
		"objectLockRetentionDays": objectLockRetention,
		"tags":                    tags,
		"lifecycleRules":          lifecycleRules,
		"lifecycleJson":           lifecycleJSON,
		"policyJson":              policyJSON,
		"corsJson":                corsJSON,
		"encryptionJson":          encryptionJSON,
		"apiCalls":                apiCalls,
	}, nil
}

func putBucketLifecycle(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	lifecycleJSON := strings.TrimSpace(asString(params["lifecycleJson"]))
	if lifecycleJSON == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and lifecycle JSON are required."}
	}
	var configPayload struct {
		Rules []types.LifecycleRule `json:"Rules"`
	}
	if err = json.Unmarshal([]byte(lifecycleJSON), &configPayload); err != nil {
		return nil, &sidecarError{Code: "invalid_config", Message: "Lifecycle JSON could not be parsed.", Details: map[string]interface{}{"reason": err.Error()}}
	}
	if _, err = client.PutBucketLifecycleConfiguration(ctx, &s3.PutBucketLifecycleConfigurationInput{
		Bucket: aws.String(bucketName),
		LifecycleConfiguration: &types.BucketLifecycleConfiguration{
			Rules: configPayload.Rules,
		},
	}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func deleteBucketLifecycle(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	if _, err = client.DeleteBucketLifecycle(ctx, &s3.DeleteBucketLifecycleInput{Bucket: aws.String(bucketName)}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func putBucketPolicy(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	policyJSON := strings.TrimSpace(asString(params["policyJson"]))
	if policyJSON == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and policy JSON are required."}
	}
	if _, err = client.PutBucketPolicy(ctx, &s3.PutBucketPolicyInput{Bucket: aws.String(bucketName), Policy: aws.String(policyJSON)}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func deleteBucketPolicy(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	if _, err = client.DeleteBucketPolicy(ctx, &s3.DeleteBucketPolicyInput{Bucket: aws.String(bucketName)}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func putBucketCors(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	corsJSON := strings.TrimSpace(asString(params["corsJson"]))
	if corsJSON == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and CORS JSON are required."}
	}
	var rules []types.CORSRule
	if err = json.Unmarshal([]byte(corsJSON), &rules); err != nil {
		return nil, &sidecarError{Code: "invalid_config", Message: "CORS JSON could not be parsed.", Details: map[string]interface{}{"reason": err.Error()}}
	}
	if _, err = client.PutBucketCors(ctx, &s3.PutBucketCorsInput{
		Bucket: aws.String(bucketName),
		CORSConfiguration: &types.CORSConfiguration{
			CORSRules: rules,
		},
	}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func deleteBucketCors(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	if _, err = client.DeleteBucketCors(ctx, &s3.DeleteBucketCorsInput{Bucket: aws.String(bucketName)}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func putBucketEncryption(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	encryptionJSON := strings.TrimSpace(asString(params["encryptionJson"]))
	if encryptionJSON == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and encryption JSON are required."}
	}
	var configPayload types.ServerSideEncryptionConfiguration
	if err = json.Unmarshal([]byte(encryptionJSON), &configPayload); err != nil {
		return nil, &sidecarError{Code: "invalid_config", Message: "Encryption JSON could not be parsed.", Details: map[string]interface{}{"reason": err.Error()}}
	}
	if _, err = client.PutBucketEncryption(ctx, &s3.PutBucketEncryptionInput{
		Bucket:                            aws.String(bucketName),
		ServerSideEncryptionConfiguration: &configPayload,
	}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func deleteBucketEncryption(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	if _, err = client.DeleteBucketEncryption(ctx, &s3.DeleteBucketEncryptionInput{Bucket: aws.String(bucketName)}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func putBucketTagging(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	tagsMap := asMap(params["tags"])
	if tagsMap == nil {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and tags are required."}
	}
	tagSet := make([]types.Tag, 0, len(tagsMap))
	for key, value := range tagsMap {
		tagSet = append(tagSet, types.Tag{Key: aws.String(key), Value: aws.String(asString(value))})
	}
	if _, err = client.PutBucketTagging(ctx, &s3.PutBucketTaggingInput{
		Bucket:  aws.String(bucketName),
		Tagging: &types.Tagging{TagSet: tagSet},
	}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func deleteBucketTagging(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	if _, err = client.DeleteBucketTagging(ctx, &s3.DeleteBucketTaggingInput{Bucket: aws.String(bucketName)}); err != nil {
		return nil, err
	}
	return getBucketAdminState(params)
}

func listObjectVersions(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	key := strings.TrimSpace(asString(params["key"]))
	options := asMap(params["options"])
	filterValue := ""
	filterMode := "prefix"
	if options != nil {
		filterValue = strings.TrimSpace(asString(options["filterValue"]))
		if value := strings.TrimSpace(asString(options["filterMode"])); value != "" {
			filterMode = value
		}
	}
	effectivePrefix := key
	if effectivePrefix == "" {
		if filterMode == "prefix" {
			effectivePrefix = filterValue
		}
	}
	output, err := client.ListObjectVersions(ctx, &s3.ListObjectVersionsInput{
		Bucket:  aws.String(bucketName),
		Prefix:  aws.String(effectivePrefix),
		MaxKeys: aws.Int32(1000),
	})
	if err != nil {
		return nil, err
	}

	items := make([]map[string]interface{}, 0, len(output.Versions)+len(output.DeleteMarkers))
	for _, version := range output.Versions {
		versionKey := aws.ToString(version.Key)
		if key != "" && versionKey != key {
			continue
		}
		items = append(items, map[string]interface{}{
			"key":          versionKey,
			"versionId":    aws.ToString(version.VersionId),
			"modifiedAt":   serializeTime(version.LastModified),
			"latest":       version.IsLatest,
			"deleteMarker": false,
			"size":         version.Size,
			"storageClass": string(version.StorageClass),
		})
	}
	for _, marker := range output.DeleteMarkers {
		markerKey := aws.ToString(marker.Key)
		if key != "" && markerKey != key {
			continue
		}
		items = append(items, map[string]interface{}{
			"key":          markerKey,
			"versionId":    aws.ToString(marker.VersionId),
			"modifiedAt":   serializeTime(marker.LastModified),
			"latest":       marker.IsLatest,
			"deleteMarker": true,
			"size":         0,
			"storageClass": "DELETE_MARKER",
		})
	}
	sort.Slice(items, func(i, j int) bool {
		return asString(items[i]["modifiedAt"]) > asString(items[j]["modifiedAt"])
	})
	versionCount := 0
	deleteMarkerCount := 0
	for _, item := range items {
		if asBool(item["deleteMarker"]) {
			deleteMarkerCount++
		} else {
			versionCount++
		}
	}
	return map[string]interface{}{
		"items":             items,
		"cursor":            map[string]interface{}{"value": nil, "hasMore": false},
		"totalCount":        len(items),
		"versionCount":      versionCount,
		"deleteMarkerCount": deleteMarkerCount,
	}, nil
}

func getObjectDetails(params map[string]interface{}) (map[string]interface{}, error) {
	p, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	key := strings.TrimSpace(asString(params["key"]))
	if key == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and object key are required for object inspection."}
	}

	apiCalls := make([]map[string]interface{}, 0, 2)
	debugEvents := []map[string]interface{}{
		{
			"timestamp": serializeTimePtr(time.Now().UTC()),
			"level":     "DEBUG",
			"message":   fmt.Sprintf("Fetching object diagnostics for %s/%s.", bucketName, key),
		},
	}

	headAny, err := callAPI(ctx, client, &apiCalls, "HeadObject", func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucketName), Key: aws.String(key)})
	})
	if err != nil {
		return nil, err
	}
	tagAny, err := optionalAPI(ctx, client, &apiCalls, "GetObjectTagging", missingBucketConfigCodes(), func(ctx context.Context, client *s3.Client) (interface{}, error) {
		return client.GetObjectTagging(ctx, &s3.GetObjectTaggingInput{Bucket: aws.String(bucketName), Key: aws.String(key)})
	})
	if err != nil {
		return nil, err
	}
	head := headAny.(*s3.HeadObjectOutput)
	metadata := map[string]string{}
	for key, value := range head.Metadata {
		metadata[key] = value
	}
	headers := map[string]string{
		"ETag":           trimQuotesString(aws.ToString(head.ETag)),
		"Content-Length": fmt.Sprintf("%d", aws.ToInt64(head.ContentLength)),
		"Content-Type":   aws.ToString(head.ContentType),
		"Last-Modified":  serializeTime(head.LastModified),
		"Storage-Class":  string(head.StorageClass),
		"Cache-Control":  aws.ToString(head.CacheControl),
	}
	for key, value := range headers {
		if strings.TrimSpace(value) == "" {
			delete(headers, key)
		}
	}
	tags := map[string]string{}
	if tagAny != nil {
		for _, tag := range tagAny.(*s3.GetObjectTaggingOutput).TagSet {
			tags[aws.ToString(tag.Key)] = aws.ToString(tag.Value)
		}
	}
	debugEvents = append(debugEvents, map[string]interface{}{
		"timestamp": serializeTimePtr(time.Now().UTC()),
		"level":     "INFO",
		"message":   fmt.Sprintf("Loaded metadata and %d tag(s) for %s.", len(tags), key),
	})
	return map[string]interface{}{
		"key":         key,
		"metadata":    metadata,
		"headers":     headers,
		"tags":        tags,
		"debugEvents": debugEvents,
		"apiCalls":    apiCalls,
		"debugLogExcerpt": []string{
			fmt.Sprintf("Resolved endpoint %s.", p.EndpointURL),
			fmt.Sprintf("Completed HEAD and tagging diagnostics for %s/%s.", bucketName, key),
		},
		"rawDiagnostics": map[string]interface{}{
			"bucketName":  bucketName,
			"engineState": "healthy",
		},
	}, nil
}

func createFolder(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
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
	if _, err = client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String(key),
		Body:   bytes.NewReader(nil),
	}); err != nil {
		return nil, err
	}
	return map[string]interface{}{"created": true, "key": key}, nil
}

func copyObject(params map[string]interface{}) (map[string]interface{}, error) {
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
	client, ctx, err := buildClient(p)
	if err != nil {
		return nil, err
	}
	copySource := url.PathEscape(sourceBucket + "/" + sourceKey)
	if _, err = client.CopyObject(ctx, &s3.CopyObjectInput{
		Bucket:     aws.String(destinationBucket),
		Key:        aws.String(destinationKey),
		CopySource: aws.String(copySource),
	}); err != nil {
		return nil, err
	}
	return map[string]interface{}{"successCount": 1, "failureCount": 0, "failures": []interface{}{}}, nil
}

func moveObject(params map[string]interface{}) (map[string]interface{}, error) {
	result, err := copyObject(params)
	if err != nil {
		return nil, err
	}
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return nil, err
	}
	client, ctx, err := buildClient(p)
	if err != nil {
		return nil, err
	}
	if _, err = client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(strings.TrimSpace(asString(params["sourceBucketName"]))),
		Key:    aws.String(strings.TrimSpace(asString(params["sourceKey"]))),
	}); err != nil {
		return nil, err
	}
	return result, nil
}

func deleteObjects(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	keys := asStringSlice(params["keys"])
	if len(keys) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and keys are required."}
	}
	identifiers := make([]types.ObjectIdentifier, 0, len(keys))
	for _, key := range keys {
		identifiers = append(identifiers, types.ObjectIdentifier{Key: aws.String(key)})
	}
	output, err := client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
		Bucket: aws.String(bucketName),
		Delete: &types.Delete{Objects: identifiers, Quiet: aws.Bool(false)},
	})
	if err != nil {
		return nil, err
	}
	failures := make([]map[string]interface{}, 0, len(output.Errors))
	for _, item := range output.Errors {
		failures = append(failures, map[string]interface{}{
			"target":  aws.ToString(item.Key),
			"code":    nonEmpty(aws.ToString(item.Code), "unknown"),
			"message": nonEmpty(aws.ToString(item.Message), "Unknown delete error."),
		})
	}
	return map[string]interface{}{
		"successCount": len(output.Deleted),
		"failureCount": len(output.Errors),
		"failures":     failures,
	}, nil
}

func deleteObjectVersions(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	versionItems, ok := params["versions"].([]interface{})
	if !ok || len(versionItems) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and versions are required."}
	}
	identifiers := make([]types.ObjectIdentifier, 0, len(versionItems))
	for _, item := range versionItems {
		version := asMap(item)
		identifiers = append(identifiers, types.ObjectIdentifier{
			Key:       aws.String(asString(version["key"])),
			VersionId: stringPtr(asString(version["versionId"])),
		})
	}
	output, err := client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
		Bucket: aws.String(bucketName),
		Delete: &types.Delete{Objects: identifiers, Quiet: aws.Bool(false)},
	})
	if err != nil {
		return nil, err
	}
	failures := make([]map[string]interface{}, 0, len(output.Errors))
	for _, item := range output.Errors {
		failures = append(failures, map[string]interface{}{
			"target":    aws.ToString(item.Key),
			"versionId": emptyToNil(aws.ToString(item.VersionId)),
			"code":      nonEmpty(aws.ToString(item.Code), "unknown"),
			"message":   nonEmpty(aws.ToString(item.Message), "Unknown delete error."),
		})
	}
	return map[string]interface{}{
		"successCount": len(output.Deleted),
		"failureCount": len(output.Errors),
		"failures":     failures,
	}, nil
}

func startUpload(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	prefix := strings.TrimSpace(asString(params["prefix"]))
	filePaths := asStringSlice(params["filePaths"])
	objectKeyByPath := asStringMap(params["objectKeyByPath"])
	if len(filePaths) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and file paths are required."}
	}
	thresholdBytes := int64(maxInt(asInt(params["multipartThresholdMiB"]), 1, 32)) * 1024 * 1024
	chunkBytes := int64(maxInt(asInt(params["multipartChunkMiB"]), 1, 8)) * 1024 * 1024
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
			createOutput, createErr := client.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{
				Bucket: aws.String(bucketName),
				Key:    aws.String(targetKey),
			})
			if createErr != nil {
				handle.Close()
				return nil, createErr
			}
			completed := make([]types.CompletedPart, 0)
			partNumber := int32(1)
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
				partOutput, uploadErr := client.UploadPart(ctx, &s3.UploadPartInput{
					Bucket:     aws.String(bucketName),
					Key:        aws.String(targetKey),
					UploadId:   createOutput.UploadId,
					PartNumber: aws.Int32(partNumber),
					Body:       bytes.NewReader(chunk),
				})
				if uploadErr != nil {
					handle.Close()
					return nil, uploadErr
				}
				completed = append(completed, types.CompletedPart{
					ETag:       partOutput.ETag,
					PartNumber: aws.Int32(partNumber),
				})
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
			_, err = client.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{
				Bucket:   aws.String(bucketName),
				Key:      aws.String(targetKey),
				UploadId: createOutput.UploadId,
				MultipartUpload: &types.CompletedMultipartUpload{
					Parts: completed,
				},
			})
		} else {
			_, err = client.PutObject(ctx, &s3.PutObjectInput{
				Bucket: aws.String(bucketName),
				Key:    aws.String(targetKey),
				Body:   handle,
			})
			bytesTransferred += info.Size()
		}
		handle.Close()
		if err != nil {
			return nil, err
		}
		itemsCompleted++
		outputLines = append(outputLines, fmt.Sprintf("Finished uploading %s.", info.Name()))
		emitTransferEvent(buildTransferJob(jobID, label, "upload", progressFraction(bytesTransferred, totalBytes), "running", bytesTransferred, totalBytes, transferStrategyLabel("upload", usesMultipart), info.Name(), len(filePaths), itemsCompleted, partSize, partDone, partCount, true, false, true, append([]string{}, outputLines...)))
	}
	outputLines = append(outputLines, fmt.Sprintf("Uploaded %d file(s) into %s.", len(filePaths), bucketName))
	return buildTransferJob(jobID, label, "upload", 1, "completed", bytesTransferred, totalBytes, transferStrategyLabel("upload", usesMultipart), filepath.Base(filePaths[len(filePaths)-1]), len(filePaths), itemsCompleted, partSize, partDone, partCount, false, false, false, outputLines), nil
}

func startDownload(params map[string]interface{}) (map[string]interface{}, error) {
	_, bucketName, client, ctx, err := bucketClient(params)
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
		headOutput, headErr := client.HeadObject(ctx, &s3.HeadObjectInput{
			Bucket: aws.String(bucketName),
			Key:    aws.String(key),
		})
		if headErr != nil {
			return nil, headErr
		}
		size := aws.ToInt64(headOutput.ContentLength)
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
				output, getErr := client.GetObject(ctx, &s3.GetObjectInput{
					Bucket: aws.String(bucketName),
					Key:    aws.String(key),
					Range:  aws.String(rangeHeader),
				})
				if getErr != nil {
					handle.Close()
					return nil, getErr
				}
				copied, copyErr := io.Copy(handle, output.Body)
				output.Body.Close()
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
			output, getErr := client.GetObject(ctx, &s3.GetObjectInput{
				Bucket: aws.String(bucketName),
				Key:    aws.String(key),
			})
			if getErr != nil {
				handle.Close()
				return nil, getErr
			}
			buffer := make([]byte, minInt64(chunkBytes, 1024*1024))
			for {
				readBytes, readErr := output.Body.Read(buffer)
				if readBytes > 0 {
					if _, writeErr := handle.Write(buffer[:readBytes]); writeErr != nil {
						output.Body.Close()
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
					output.Body.Close()
					handle.Close()
					return nil, readErr
				}
			}
			output.Body.Close()
		}
		handle.Close()
		itemsCompleted++
		outputLines = append(outputLines, fmt.Sprintf("Finished downloading %s.", key))
	}
	outputLines = append(outputLines, fmt.Sprintf("Downloaded %d object(s) into %s.", len(keys), destinationPath))
	return buildTransferJob(jobID, label, "download", 1, "completed", bytesTransferred, totalBytes, transferStrategyLabel("download", usesMultipart), keys[len(keys)-1], len(keys), itemsCompleted, partSize, partDone, partCount, false, false, false, outputLines), nil
}

func generatePresignedURL(params map[string]interface{}) (map[string]interface{}, error) {
	p, bucketName, client, _, err := bucketClient(params)
	if err != nil {
		return nil, err
	}
	key := strings.TrimSpace(asString(params["key"]))
	expiration := maxInt(asInt(params["expirationSeconds"]), 1, 3600)
	if key == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Bucket name and object key are required to generate a presigned URL."}
	}
	presignClient := s3.NewPresignClient(client)
	output, err := presignClient.PresignGetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String(key),
	}, func(options *s3.PresignOptions) {
		options.Expires = time.Duration(expiration) * time.Second
	})
	if err != nil {
		return nil, err
	}
	_ = p
	return map[string]interface{}{"url": output.URL}, nil
}

func buildTransferJob(jobID, label, direction string, progress float64, status string, bytesTransferred, totalBytes int64, strategyLabel, currentItemLabel string, itemCount, itemsCompleted int, partSize, partsCompleted, partsTotal interface{}, canPause, canResume, canCancel bool, outputLines []string) map[string]interface{} {
	return map[string]interface{}{
		"id":               jobID,
		"label":            label,
		"direction":        direction,
		"progress":         progress,
		"status":           status,
		"bytesTransferred": bytesTransferred,
		"totalBytes":       totalBytes,
		"strategyLabel":    emptyToNil(strategyLabel),
		"currentItemLabel": emptyToNil(currentItemLabel),
		"itemCount":        itemCount,
		"itemsCompleted":   itemsCompleted,
		"partSizeBytes":    partSize,
		"partsCompleted":   partsCompleted,
		"partsTotal":       partsTotal,
		"canPause":         canPause,
		"canResume":        canResume,
		"canCancel":        canCancel,
		"outputLines":      outputLines,
	}
}

func transferControl(params map[string]interface{}, action string) map[string]interface{} {
	jobID := strings.TrimSpace(asString(params["jobId"]))
	if jobID == "" {
		jobID = fmt.Sprintf("transfer-%d", time.Now().UnixNano())
	}
	progress := 0.0
	if action == "cancelled" {
		progress = 1.0
	}
	return buildTransferJob(jobID, "Transfer "+action, "transfer", progress, action, 0, 0, "", "", 0, 0, nil, nil, nil, false, false, false, []string{fmt.Sprintf("Transfer %s.", action)})
}

func emitTransferEvent(job map[string]interface{}) {
	payload, err := json.Marshal(map[string]interface{}{
		"event": "transferProgress",
		"job":   job,
	})
	if err != nil {
		return
	}
	fmt.Println(string(payload))
}

func transferStrategyLabel(direction string, usesMultipart bool) string {
	if usesMultipart {
		return "Multipart " + direction
	}
	return "Single-part " + direction
}

func progressFraction(bytesTransferred, totalBytes int64) float64 {
	if totalBytes <= 0 {
		return 1
	}
	return float64(bytesTransferred) / float64(totalBytes)
}

func minInt64(left, right int64) int64 {
	if left < right {
		return left
	}
	return right
}

func runPutTestData(params map[string]interface{}) map[string]interface{} {
	config := asMap(params["config"])
	return map[string]interface{}{
		"label":       "put-testdata.py",
		"running":     false,
		"lastStatus":  fmt.Sprintf("Prepared %d object(s) with %d version(s) each for %s.", asInt(config["objectCount"]), asInt(config["versions"]), asString(config["bucketName"])),
		"jobId":       fmt.Sprintf("tool-%d", time.Now().UnixNano()),
		"cancellable": false,
		"outputLines": []string{
			fmt.Sprintf("Bucket: %s", asString(config["bucketName"])),
			fmt.Sprintf("Prefix: %s", asString(config["prefix"])),
			fmt.Sprintf("Threads: %d", asInt(config["threads"])),
		},
		"exitCode": 0,
	}
}

func runDeleteAll(params map[string]interface{}) map[string]interface{} {
	config := asMap(params["config"])
	return map[string]interface{}{
		"label":       "delete-all.py",
		"running":     false,
		"lastStatus":  fmt.Sprintf("Prepared delete-all sweep for %s.", asString(config["bucketName"])),
		"jobId":       fmt.Sprintf("tool-%d", time.Now().UnixNano()),
		"cancellable": false,
		"outputLines": []string{
			fmt.Sprintf("Batch size: %d", asInt(config["batchSize"])),
			fmt.Sprintf("Workers: %d", asInt(config["maxWorkers"])),
		},
		"exitCode": 0,
	}
}

func cancelToolExecution(params map[string]interface{}) map[string]interface{} {
	jobID := strings.TrimSpace(asString(params["jobId"]))
	return map[string]interface{}{
		"label":       nonEmpty(jobID, "tool"),
		"running":     false,
		"lastStatus":  fmt.Sprintf("Cancelled tool execution %s.", jobID),
		"jobId":       jobID,
		"cancellable": false,
		"outputLines": []string{fmt.Sprintf("Tool execution %s cancelled.", jobID)},
		"exitCode":    130,
	}
}

func runtimeDir() string {
	path := filepath.Join(os.TempDir(), "object-data-browser-go-engine")
	_ = os.MkdirAll(path, 0o755)
	return path
}

func benchmarkStatePath(runID string) string {
	return filepath.Join(runtimeDir(), "benchmark-"+runID+".json")
}

func benchmarkRatios(workloadType string) []struct {
	name  string
	ratio int
} {
	switch workloadType {
	case "write-heavy":
		return []struct {
			name  string
			ratio int
		}{
			{name: "PUT", ratio: 60},
			{name: "GET", ratio: 30},
			{name: "DELETE", ratio: 10},
		}
	case "read-heavy":
		return []struct {
			name  string
			ratio int
		}{
			{name: "PUT", ratio: 25},
			{name: "GET", ratio: 65},
			{name: "DELETE", ratio: 10},
		}
	case "delete":
		return []struct {
			name  string
			ratio int
		}{
			{name: "PUT", ratio: 0},
			{name: "GET", ratio: 0},
			{name: "DELETE", ratio: 100},
		}
	default:
		return []struct {
			name  string
			ratio int
		}{
			{name: "PUT", ratio: 34},
			{name: "GET", ratio: 33},
			{name: "DELETE", ratio: 33},
		}
	}
}

func benchmarkProfile(profilePayload, config map[string]interface{}) (profile, error) {
	merged := map[string]interface{}{}
	for key, value := range profilePayload {
		merged[key] = value
	}
	merged["connectTimeoutSeconds"] = maxInt(asInt(config["connectTimeoutSeconds"]), 1, asInt(profilePayload["connectTimeoutSeconds"]))
	merged["readTimeoutSeconds"] = maxInt(asInt(config["readTimeoutSeconds"]), 1, asInt(profilePayload["readTimeoutSeconds"]))
	merged["maxAttempts"] = maxInt(asInt(config["maxAttempts"]), 1, asInt(profilePayload["maxAttempts"]))
	merged["maxConcurrentRequests"] = maxInt(asInt(config["maxPoolConnections"]), 1, asInt(profilePayload["maxConcurrentRequests"]))
	return parseProfile(merged)
}

func appendBenchmarkLog(state map[string]interface{}, line string) {
	log := asStringSlice(state["liveLog"])
	log = append(log, line)
	if len(log) > 60 {
		log = log[len(log)-60:]
	}
	state["liveLog"] = log
}

func benchmarkSizeList(config map[string]interface{}) []int {
	items := asInterfaceSlice(config["objectSizes"])
	if len(items) == 0 {
		return []int{4096}
	}
	sizes := make([]int, 0, len(items))
	for _, item := range items {
		size := asInt(item)
		if size > 0 {
			sizes = append(sizes, size)
		}
	}
	if len(sizes) == 0 {
		return []int{4096}
	}
	return sizes
}

func benchmarkBasePrefix(config map[string]interface{}, runID string) string {
	prefix := strings.TrimSpace(asString(config["prefix"]))
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return prefix + runID + "/"
}

func benchmarkPayload(runID, key string, size int, randomData bool) []byte {
	if size <= 0 {
		return []byte{}
	}
	if !randomData {
		return bytes.Repeat([]byte("A"), size)
	}
	seed := []byte(runID + ":" + key + fmt.Sprintf(":%d", size))
	if len(seed) == 0 {
		seed = []byte("s3-benchmark")
	}
	patternLength := len(seed) * 8
	if patternLength < 64 {
		patternLength = 64
	}
	if patternLength > 4096 {
		patternLength = 4096
	}
	pattern := make([]byte, patternLength)
	for index := range pattern {
		pattern[index] = byte((int(seed[index%len(seed)]) + (index * 17)) % 256)
	}
	repeats := (size / len(pattern)) + 1
	return bytes.Repeat(pattern, repeats)[:size]
}

func isMissingBenchmarkKeyErr(err error) bool {
	var sideErr *sidecarError
	if errors.As(err, &sideErr) && sideErr.Code == "not_found" {
		return true
	}
	code := awsErrorCode(err)
	message := strings.ToLower(err.Error())
	return code == "NoSuchKey" || code == "NotFound" || code == "404" || strings.Contains(message, "does not exist")
}

func benchmarkOperationCount(record map[string]interface{}) int {
	return maxInt(asInt(record["operationCount"]), 1, 1)
}

func benchmarkTimelineLabel(elapsedSeconds float64) string {
	if elapsedSeconds >= 100 {
		return fmt.Sprintf("%.0fs", elapsedSeconds)
	}
	if elapsedSeconds >= 10 {
		return fmt.Sprintf("%.1fs", elapsedSeconds)
	}
	return fmt.Sprintf("%.2fs", elapsedSeconds)
}

func benchmarkDeleteMode(config map[string]interface{}) string {
	if asString(config["deleteMode"]) == "multi-object-post" {
		return "multi-object-post"
	}
	return "single"
}

func benchmarkDeleteBatchSize(config map[string]interface{}, activeCount int) int {
	if benchmarkDeleteMode(config) != "multi-object-post" {
		return 1
	}
	size := maxInt(asInt(config["concurrentThreads"]), 2, 1)
	if size > 1000 {
		size = 1000
	}
	if size > activeCount {
		size = activeCount
	}
	if size < 1 {
		size = 1
	}
	return size
}

func benchmarkPercentile(values []float64, percentile float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sortedValues := append([]float64(nil), values...)
	sort.Float64s(sortedValues)
	if len(sortedValues) == 1 {
		return sortedValues[0]
	}
	rank := (float64(len(sortedValues)-1) * percentile) / 100
	lower := int(rank)
	upper := lower + 1
	if upper >= len(sortedValues) {
		upper = len(sortedValues) - 1
	}
	weight := rank - float64(lower)
	return sortedValues[lower] + ((sortedValues[upper] - sortedValues[lower]) * weight)
}

func benchmarkLatencyPercentiles(values []float64) map[string]interface{} {
	return map[string]interface{}{
		"p50":  roundFloat(benchmarkPercentile(values, 50)),
		"p75":  roundFloat(benchmarkPercentile(values, 75)),
		"p90":  roundFloat(benchmarkPercentile(values, 90)),
		"p95":  roundFloat(benchmarkPercentile(values, 95)),
		"p99":  roundFloat(benchmarkPercentile(values, 99)),
		"p999": roundFloat(benchmarkPercentile(values, 99.9)),
	}
}

func benchmarkSummaryFromState(state map[string]interface{}) map[string]interface{} {
	history := asMapSlice(state["history"])
	operationsByType := map[string]interface{}{}
	latencies := make([]float64, 0, len(history))
	checksumStats := map[string]interface{}{
		"validated_success": 0,
		"validated_failure": 0,
		"not_used":          0,
	}
	windows := map[int][]map[string]interface{}{}
	sizeLatency := map[int][]float64{}
	for _, record := range history {
		operation := strings.ToUpper(asString(record["operation"]))
		operationCount := benchmarkOperationCount(record)
		operationsByType[operation] = asInt(operationsByType[operation]) + operationCount
		latency := asFloat(record["latencyMs"])
		latencies = append(latencies, latency)
		checksumKey := asString(record["checksumState"])
		if checksumKey == "" {
			checksumKey = "not_used"
		}
		checksumStats[checksumKey] = asInt(checksumStats[checksumKey]) + operationCount
		second := max(asInt(record["second"]), 1)
		windows[second] = append(windows[second], record)
		sizeBytes := asInt(record["sizeBytes"])
		if sizeBytes > 0 {
			sizeLatency[sizeBytes] = append(sizeLatency[sizeBytes], latency)
		}
	}
	windowKeys := make([]int, 0, len(windows))
	for second := range windows {
		windowKeys = append(windowKeys, second)
	}
	sort.Ints(windowKeys)
	throughputSeries := make([]map[string]interface{}, 0, len(windowKeys))
	averageOps := 0.0
	averageBytes := 0.0
	peakOps := 0
	peakBytes := 0
	for _, second := range windowKeys {
		records := windows[second]
		perOperation := map[string]interface{}{}
		windowLatencies := make([]float64, 0, len(records))
		bytesPerSecond := 0
		for _, record := range records {
			operation := strings.ToUpper(asString(record["operation"]))
			perOperation[operation] = asInt(perOperation[operation]) + benchmarkOperationCount(record)
			windowLatencies = append(windowLatencies, asFloat(record["latencyMs"]))
			bytesPerSecond += asInt(record["bytesTransferred"])
		}
		opsPerSecond := 0
		for _, record := range records {
			opsPerSecond += benchmarkOperationCount(record)
		}
		averageOps += float64(opsPerSecond)
		averageBytes += float64(bytesPerSecond)
		if opsPerSecond > peakOps {
			peakOps = opsPerSecond
		}
		if bytesPerSecond > peakBytes {
			peakBytes = bytesPerSecond
		}
		throughputSeries = append(throughputSeries, map[string]interface{}{
			"second":           second,
			"label":            fmt.Sprintf("%ds", second),
			"opsPerSecond":     opsPerSecond,
			"bytesPerSecond":   bytesPerSecond,
			"averageLatencyMs": roundFloat(meanFloat(windowLatencies)),
			"p95LatencyMs":     roundFloat(benchmarkPercentile(windowLatencies, 95)),
			"operations":       perOperation,
		})
	}
	secondPositions := map[int]int{}
	latencyTimeline := make([]map[string]interface{}, 0, len(history))
	for index, record := range history {
		second := max(asInt(record["second"]), 1)
		position := secondPositions[second] + 1
		secondPositions[second] = position
		elapsedMs := asFloat(record["elapsedMs"])
		if elapsedMs <= 0 {
			elapsedSeconds := float64(second-1) + (float64(position) / float64(len(windows[second])+1))
			elapsedMs = elapsedSeconds * 1000
		}
		latencyTimeline = append(latencyTimeline, map[string]interface{}{
			"sequence":         index + 1,
			"operation":        strings.ToUpper(asString(record["operation"])),
			"second":           second,
			"elapsedMs":        roundFloat(elapsedMs),
			"label":            benchmarkTimelineLabel(elapsedMs / 1000),
			"latencyMs":        roundFloat(asFloat(record["latencyMs"])),
			"sizeBytes":        asInt(record["sizeBytes"]),
			"bytesTransferred": asInt(record["bytesTransferred"]),
			"operationCount":   benchmarkOperationCount(record),
			"success":          asBool(record["success"]) || record["success"] == nil,
			"key":              asString(record["key"]),
		})
	}
	sizeKeys := make([]int, 0, len(sizeLatency))
	for sizeBytes := range sizeLatency {
		sizeKeys = append(sizeKeys, sizeBytes)
	}
	sort.Ints(sizeKeys)
	sizeLatencyBuckets := make([]map[string]interface{}, 0, len(sizeKeys))
	for _, sizeBytes := range sizeKeys {
		values := sizeLatency[sizeBytes]
		sizeLatencyBuckets = append(sizeLatencyBuckets, map[string]interface{}{
			"sizeBytes":    sizeBytes,
			"count":        len(values),
			"avgLatencyMs": roundFloat(meanFloat(values)),
			"p50LatencyMs": roundFloat(benchmarkPercentile(values, 50)),
			"p95LatencyMs": roundFloat(benchmarkPercentile(values, 95)),
			"p99LatencyMs": roundFloat(benchmarkPercentile(values, 99)),
		})
	}
	sizes := benchmarkSizeList(asMap(state["config"]))
	averageObjectSize := 0
	for _, size := range sizes {
		averageObjectSize += size
	}
	if len(sizes) > 0 {
		averageObjectSize /= len(sizes)
	}
	sampleCount := len(throughputSeries)
	if sampleCount == 0 {
		sampleCount = 1
	}
	return map[string]interface{}{
		"totalOperations": func() int {
			total := 0
			for _, record := range history {
				total += benchmarkOperationCount(record)
			}
			return total
		}(),
		"operationsByType":     operationsByType,
		"latencyPercentilesMs": benchmarkLatencyPercentiles(latencies),
		"throughputSeries":     throughputSeries,
		"latencyTimeline":      latencyTimeline,
		"sizeLatencyBuckets":   sizeLatencyBuckets,
		"checksumStats":        checksumStats,
		"detailMetrics": map[string]interface{}{
			"sampleCount":            sampleCount,
			"sampleWindowSeconds":    1,
			"averageOpsPerSecond":    roundFloat(averageOps / float64(sampleCount)),
			"peakOpsPerSecond":       peakOps,
			"averageBytesPerSecond":  roundFloat(averageBytes / float64(sampleCount)),
			"peakBytesPerSecond":     peakBytes,
			"averageObjectSizeBytes": averageObjectSize,
			"checksumValidated":      asInt(checksumStats["validated_success"]),
			"errorCount":             0,
			"retryCount":             0,
			"runMode":                asString(asMap(state["config"])["testMode"]),
			"workloadType":           asString(asMap(state["config"])["workloadType"]),
		},
	}
}

func readBenchmarkState(runID string) (map[string]interface{}, error) {
	data, err := os.ReadFile(benchmarkStatePath(runID))
	if err != nil {
		return nil, &sidecarError{Code: "invalid_config", Message: fmt.Sprintf("Benchmark run %s was not found.", runID)}
	}
	var state map[string]interface{}
	if err = json.Unmarshal(data, &state); err != nil {
		return nil, err
	}
	return state, nil
}

func writeBenchmarkState(state map[string]interface{}) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return os.WriteFile(benchmarkStatePath(asString(state["id"])), data, 0o644)
}

func refreshBenchmarkSnapshot(state map[string]interface{}) {
	status := asString(state["status"])
	if status != "completed" && status != "stopped" && status != "failed" {
		lastUpdated, err := time.Parse(time.RFC3339, nonEmpty(asString(state["lastUpdatedAt"]), asString(state["startedAt"])))
		if err != nil {
			lastUpdated = time.Now().UTC()
		}
		now := time.Now().UTC()
		state["activeElapsedSeconds"] = asFloat(state["activeElapsedSeconds"]) + now.Sub(lastUpdated).Seconds()
		state["lastUpdatedAt"] = serializeTimePtr(now)
	}
	state["resultSummary"] = benchmarkSummaryFromState(state)
	history := asMapSlice(state["history"])
	latencies := make([]float64, 0, len(history))
	for _, record := range history {
		latencies = append(latencies, asFloat(record["latencyMs"]))
	}
	state["averageLatencyMs"] = roundFloat(meanFloat(latencies))
	throughputSeries := asMapSlice(asMap(state["resultSummary"])["throughputSeries"])
	if len(throughputSeries) > 0 {
		state["throughputOpsPerSecond"] = asFloat(throughputSeries[len(throughputSeries)-1]["opsPerSecond"])
	} else {
		state["throughputOpsPerSecond"] = 0
	}
}

func materializeBenchmarkState(state map[string]interface{}) (map[string]interface{}, error) {
	status := asString(state["status"])
	if status == "paused" || status == "completed" || status == "stopped" || status == "failed" {
		return state, nil
	}
	config := asMap(state["config"])
	lastUpdated, err := time.Parse(time.RFC3339, nonEmpty(asString(state["lastUpdatedAt"]), asString(state["startedAt"])))
	if err != nil {
		lastUpdated = time.Now().UTC()
	}
	now := time.Now().UTC()
	activeElapsed := asFloat(state["activeElapsedSeconds"]) + now.Sub(lastUpdated).Seconds()
	state["activeElapsedSeconds"] = activeElapsed
	state["lastUpdatedAt"] = serializeTimePtr(now)
	if asBool(config["debugMode"]) {
		emitStructuredLog(
			"DEBUG",
			"BenchmarkTrace",
			fmt.Sprintf(
				"Benchmark tick status=%s elapsed=%.2fs processed=%d",
				asString(state["status"]),
				activeElapsed,
				asInt(state["processedCount"]),
			),
			"debug",
		)
	}
	durationSeconds := maxInt(asInt(config["durationSeconds"]), 1, 60)
	operationCount := maxInt(asInt(config["operationCount"]), 1, 1000)
	threads := maxInt(asInt(config["concurrentThreads"]), 1, 1)
	processedCount := asInt(state["processedCount"])
	durationComplete := asString(config["testMode"]) != "operation-count" && activeElapsed >= float64(durationSeconds)
	operationComplete := asString(config["testMode"]) == "operation-count" && processedCount >= operationCount
	effectiveElapsed := activeElapsed
	if durationComplete {
		effectiveElapsed = float64(durationSeconds)
		state["activeElapsedSeconds"] = effectiveElapsed
	}
	rateTarget := int(effectiveElapsed * float64(threads) * 8)
	if processedCount == 0 && rateTarget == 0 && !durationComplete && !operationComplete {
		rateTarget = 1
	}
	targetProcessed := rateTarget
	if asString(config["testMode"]) == "operation-count" && targetProcessed > operationCount {
		targetProcessed = operationCount
	}
	deficit := targetProcessed - processedCount
	if deficit < 0 {
		deficit = 0
	}
	batchSize := deficit
	if durationComplete || operationComplete {
		batchSize = 0
	}
	batchCap := threads * 32
	if batchCap < 32 {
		batchCap = 32
	}
	if batchCap > 8192 {
		batchCap = 8192
	}
	if batchSize > batchCap {
		batchSize = batchCap
	}
	if batchSize == 0 && processedCount == 0 && !durationComplete && !operationComplete {
		batchSize = 1
	}
	if batchSize > 0 {
		p, profileErr := benchmarkProfile(asMap(state["profile"]), config)
		if profileErr != nil {
			return nil, profileErr
		}
		executor, executorErr := buildBenchmarkExecutor(p, asString(config["bucketName"]))
		if executorErr != nil {
			return nil, executorErr
		}
		if batchErr := runBenchmarkBatch(state, executor, config, batchSize, threads, operationCount); batchErr != nil {
			mapped := mapError(batchErr)
			state["status"] = "failed"
			state["completedAt"] = serializeTimePtr(time.Now().UTC())
			appendBenchmarkLog(state, "Benchmark failed: "+asString(mapped["message"]))
		}
	}
	refreshBenchmarkSnapshot(state)
	if asString(state["status"]) == "running" {
		completed := false
		if asString(config["testMode"]) == "operation-count" {
			completed = asInt(state["processedCount"]) >= operationCount
		} else {
			completed = asFloat(state["activeElapsedSeconds"]) >= float64(durationSeconds)
		}
		if completed {
			state["status"] = "completed"
			state["completedAt"] = serializeTimePtr(time.Now().UTC())
			appendBenchmarkLog(state, fmt.Sprintf("Benchmark completed after %d request(s).", asInt(state["processedCount"])))
		}
	}
	if err = persistBenchmarkOutputs(state); err != nil {
		return nil, err
	}
	if err = writeBenchmarkState(state); err != nil {
		return nil, err
	}
	return state, nil
}

func startBenchmark(params map[string]interface{}) (map[string]interface{}, error) {
	config := asMap(params["config"])
	profilePayload := asMap(params["profile"])
	if len(profilePayload) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Profile configuration is required for benchmark runs."}
	}
	runID := fmt.Sprintf("bench-%d", time.Now().UnixNano())
	state := map[string]interface{}{
		"id":                     runID,
		"profile":                profilePayload,
		"config":                 config,
		"status":                 "running",
		"processedCount":         0,
		"startedAt":              serializeTimePtr(time.Now().UTC()),
		"completedAt":            nil,
		"lastUpdatedAt":          serializeTimePtr(time.Now().UTC()),
		"activeElapsedSeconds":   0.0,
		"averageLatencyMs":       0,
		"throughputOpsPerSecond": 0,
		"liveLog":                []string{"Benchmark scheduled."},
		"resultSummary":          nil,
		"history":                []map[string]interface{}{},
		"activeObjects":          []map[string]interface{}{},
		"nextObjectIndex":        0,
		"nextActiveIndex":        0,
		"nextSizeIndex":          0,
		"benchmarkPrefix":        benchmarkBasePrefix(config, runID),
	}
	appendBenchmarkLog(state, fmt.Sprintf("Benchmark target bucket: %s via %s.", asString(config["bucketName"]), asString(profilePayload["endpointUrl"])))
	if err := writeBenchmarkState(state); err != nil {
		return nil, err
	}
	return materializeBenchmarkState(state)
}

func getBenchmarkStatus(params map[string]interface{}) (map[string]interface{}, error) {
	state, err := readBenchmarkState(strings.TrimSpace(asString(params["runId"])))
	if err != nil {
		return nil, err
	}
	return materializeBenchmarkState(state)
}

func pauseBenchmark(params map[string]interface{}) (map[string]interface{}, error) {
	state, err := readBenchmarkState(strings.TrimSpace(asString(params["runId"])))
	if err != nil {
		return nil, err
	}
	refreshBenchmarkSnapshot(state)
	state["status"] = "paused"
	appendBenchmarkLog(state, "Benchmark paused by user.")
	if err = writeBenchmarkState(state); err != nil {
		return nil, err
	}
	if err = persistBenchmarkOutputs(state); err != nil {
		return nil, err
	}
	return state, nil
}

func resumeBenchmark(params map[string]interface{}) (map[string]interface{}, error) {
	state, err := readBenchmarkState(strings.TrimSpace(asString(params["runId"])))
	if err != nil {
		return nil, err
	}
	state["status"] = "running"
	state["lastUpdatedAt"] = serializeTimePtr(time.Now().UTC())
	appendBenchmarkLog(state, "Benchmark resumed by user.")
	if err = writeBenchmarkState(state); err != nil {
		return nil, err
	}
	return materializeBenchmarkState(state)
}

func stopBenchmark(params map[string]interface{}) (map[string]interface{}, error) {
	state, err := readBenchmarkState(strings.TrimSpace(asString(params["runId"])))
	if err != nil {
		return nil, err
	}
	refreshBenchmarkSnapshot(state)
	state["status"] = "stopped"
	state["completedAt"] = serializeTimePtr(time.Now().UTC())
	state["resultSummary"] = benchmarkSummaryFromState(state)
	appendBenchmarkLog(state, "Benchmark stopped by user.")
	if err = writeBenchmarkState(state); err != nil {
		return nil, err
	}
	if err = persistBenchmarkOutputs(state); err != nil {
		return nil, err
	}
	return state, nil
}

func exportBenchmarkResults(params map[string]interface{}) (map[string]interface{}, error) {
	state, err := getBenchmarkStatus(params)
	if err != nil {
		return nil, err
	}
	config := asMap(state["config"])
	formatName := strings.ToLower(strings.TrimSpace(asString(params["format"])))
	if formatName == "" {
		formatName = "csv"
	}
	path := asString(config["csvOutputPath"])
	if formatName == "json" {
		path = asString(config["jsonOutputPath"])
	}
	return map[string]interface{}{
		"format":  formatName,
		"path":    path,
		"summary": state["resultSummary"],
	}, nil
}

type benchmarkExecutor struct {
	put         func(key string, payload []byte) error
	get         func(key string) ([]byte, error)
	deleteOne   func(key string) error
	deleteBatch func(keys []string) (deleted map[string]bool, missing map[string]bool, fatalErrors []string, err error)
}

func buildBenchmarkExecutor(p profile, bucketName string) (*benchmarkExecutor, error) {
	if isAzureProfile(p) {
		return buildAzureBenchmarkExecutor(p, bucketName)
	}
	return buildS3BenchmarkExecutor(p, bucketName)
}

func buildS3BenchmarkExecutor(p profile, bucketName string) (*benchmarkExecutor, error) {
	client, ctx, err := buildClient(p)
	if err != nil {
		return nil, err
	}
	return &benchmarkExecutor{
		put: func(key string, payload []byte) error {
			_, putErr := client.PutObject(ctx, &s3.PutObjectInput{
				Bucket: aws.String(bucketName),
				Key:    aws.String(key),
				Body:   bytes.NewReader(payload),
			})
			return putErr
		},
		get: func(key string) ([]byte, error) {
			output, getErr := client.GetObject(ctx, &s3.GetObjectInput{
				Bucket: aws.String(bucketName),
				Key:    aws.String(key),
			})
			if getErr != nil {
				return nil, getErr
			}
			defer output.Body.Close()
			return io.ReadAll(output.Body)
		},
		deleteOne: func(key string) error {
			_, deleteErr := client.DeleteObject(ctx, &s3.DeleteObjectInput{
				Bucket: aws.String(bucketName),
				Key:    aws.String(key),
			})
			return deleteErr
		},
		deleteBatch: func(keys []string) (map[string]bool, map[string]bool, []string, error) {
			identifiers := make([]types.ObjectIdentifier, 0, len(keys))
			for _, selectedKey := range keys {
				identifiers = append(identifiers, types.ObjectIdentifier{Key: aws.String(selectedKey)})
			}
			output, deleteErr := client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
				Bucket: aws.String(bucketName),
				Delete: &types.Delete{Objects: identifiers, Quiet: aws.Bool(false)},
			})
			if deleteErr != nil {
				return nil, nil, nil, deleteErr
			}
			deletedKeys := map[string]bool{}
			for _, item := range output.Deleted {
				target := strings.TrimSpace(aws.ToString(item.Key))
				if target != "" {
					deletedKeys[target] = true
				}
			}
			missingKeys := map[string]bool{}
			fatalErrors := make([]string, 0, len(output.Errors))
			for _, item := range output.Errors {
				target := strings.TrimSpace(aws.ToString(item.Key))
				code := strings.ToLower(strings.TrimSpace(aws.ToString(item.Code)))
				message := strings.TrimSpace(aws.ToString(item.Message))
				if code == "nosuchkey" || code == "notfound" || code == "404" || strings.Contains(strings.ToLower(message), "does not exist") {
					if target != "" {
						missingKeys[target] = true
					}
					continue
				}
				fatalErrors = append(fatalErrors, fmt.Sprintf("%s: %s", nonEmpty(target, "(unknown)"), nonEmpty(message, aws.ToString(item.Code))))
			}
			return deletedKeys, missingKeys, fatalErrors, nil
		},
	}, nil
}

type benchmarkOpPlan struct {
	operation   string
	key         string
	sizeBytes   int
	multiDelete bool
	batchKeys   []string
}

type benchmarkOpResult struct {
	displayKey       string
	sizeBytes        int
	latencyMs        float64
	bytesTransferred int
	checksumState    string
	operationCount   int
	retry            bool
	logLine          string
}

func benchmarkPlanExpectedCount(plan benchmarkOpPlan) int {
	if plan.multiDelete {
		return len(plan.batchKeys)
	}
	return 1
}

func removeBenchmarkActiveObject(state map[string]interface{}, key string) {
	activeObjects := asMapSlice(state["activeObjects"])
	filtered := make([]map[string]interface{}, 0, len(activeObjects))
	for _, item := range activeObjects {
		if asString(item["key"]) != key {
			filtered = append(filtered, item)
		}
	}
	state["activeObjects"] = filtered
}

// planBenchmarkOperation selects the next operation and reserves the object
// pool slots it needs. The caller must hold the benchmark state mutex.
func planBenchmarkOperation(state map[string]interface{}, plannedCount int, supportsBatchDelete bool) benchmarkOpPlan {
	config := asMap(state["config"])
	activeObjects := asMapSlice(state["activeObjects"])
	slot := plannedCount % 100
	operation := "PUT"
	cumulative := 0
	for _, ratio := range benchmarkRatios(asString(config["workloadType"])) {
		cumulative += ratio.ratio
		if slot < cumulative {
			operation = ratio.name
			break
		}
	}
	if (operation == "GET" || operation == "DELETE") && len(activeObjects) == 0 {
		operation = "PUT"
	}
	sizes := benchmarkSizeList(config)
	nextSizeIndex := asInt(state["nextSizeIndex"])
	sizeBytes := sizes[nextSizeIndex%len(sizes)]
	state["nextSizeIndex"] = nextSizeIndex + 1
	objectLimit := maxInt(asInt(config["objectCount"]), 1, len(sizes))
	nextActiveIndex := asInt(state["nextActiveIndex"])
	plan := benchmarkOpPlan{operation: operation, sizeBytes: sizeBytes}
	switch operation {
	case "PUT":
		if len(activeObjects) >= objectLimit && len(activeObjects) > 0 {
			plan.key = asString(activeObjects[nextActiveIndex%len(activeObjects)]["key"])
			state["nextActiveIndex"] = nextActiveIndex + 1
		} else {
			nextObjectIndex := asInt(state["nextObjectIndex"])
			plan.key = fmt.Sprintf("%sobj-%06d-%d.bin", asString(state["benchmarkPrefix"]), nextObjectIndex, sizeBytes)
			state["nextObjectIndex"] = nextObjectIndex + 1
		}
	case "GET":
		target := activeObjects[nextActiveIndex%len(activeObjects)]
		plan.key = asString(target["key"])
		plan.sizeBytes = asInt(target["sizeBytes"])
		state["nextActiveIndex"] = nextActiveIndex + 1
	default:
		deleteBatchSize := benchmarkDeleteBatchSize(config, len(activeObjects))
		if !supportsBatchDelete {
			deleteBatchSize = 1
		}
		selected := make([]map[string]interface{}, 0, deleteBatchSize)
		selectedKeys := map[string]bool{}
		for offset := 0; offset < deleteBatchSize; offset++ {
			item := activeObjects[(nextActiveIndex+offset)%len(activeObjects)]
			selected = append(selected, item)
			selectedKeys[asString(item["key"])] = true
			plan.batchKeys = append(plan.batchKeys, asString(item["key"]))
		}
		state["nextActiveIndex"] = nextActiveIndex + deleteBatchSize
		filtered := make([]map[string]interface{}, 0, len(activeObjects))
		for _, item := range activeObjects {
			if !selectedKeys[asString(item["key"])] {
				filtered = append(filtered, item)
			}
		}
		state["activeObjects"] = filtered
		plan.multiDelete = supportsBatchDelete && benchmarkDeleteMode(config) == "multi-object-post" && len(plan.batchKeys) > 1
		plan.key = asString(selected[0]["key"])
		plan.sizeBytes = asInt(selected[0]["sizeBytes"])
		if plan.multiDelete {
			plan.sizeBytes = 0
		}
	}
	return plan
}

// executeBenchmarkOperation performs the network call for a planned operation.
// It must be called without holding the benchmark state mutex.
func executeBenchmarkOperation(executor *benchmarkExecutor, runID string, config map[string]interface{}, plan benchmarkOpPlan) (benchmarkOpResult, error) {
	result := benchmarkOpResult{
		displayKey:     plan.key,
		sizeBytes:      plan.sizeBytes,
		checksumState:  "not_used",
		operationCount: 1,
	}
	switch plan.operation {
	case "PUT":
		payload := benchmarkPayload(runID, plan.key, plan.sizeBytes, asBool(config["randomData"]))
		started := time.Now()
		if err := executor.put(plan.key, payload); err != nil {
			return result, err
		}
		result.latencyMs = float64(time.Since(started).Milliseconds())
		result.bytesTransferred = len(payload)
	case "GET":
		started := time.Now()
		body, err := executor.get(plan.key)
		if err != nil {
			return result, err
		}
		result.latencyMs = float64(time.Since(started).Milliseconds())
		result.bytesTransferred = len(body)
		if asBool(config["validateChecksum"]) {
			expected := benchmarkPayload(runID, plan.key, plan.sizeBytes, asBool(config["randomData"]))
			if bytes.Equal(body, expected) {
				result.checksumState = "validated_success"
			} else {
				result.checksumState = "validated_failure"
			}
		}
	default:
		started := time.Now()
		if plan.multiDelete {
			deletedKeys, missingKeys, fatalErrors, err := executor.deleteBatch(plan.batchKeys)
			if err != nil {
				return result, err
			}
			result.latencyMs = float64(time.Since(started).Milliseconds())
			if len(fatalErrors) > 0 {
				return result, &sidecarError{Code: "delete_failed", Message: strings.Join(fatalErrors, "; ")}
			}
			if len(missingKeys) > 0 {
				result.logLine = fmt.Sprintf("Skipped %d missing benchmark object(s) during multi-delete POST.", len(missingKeys))
			}
			result.operationCount = len(deletedKeys)
			if result.operationCount == 0 {
				result.retry = true
				return result, nil
			}
			display := ""
			for _, selectedKey := range plan.batchKeys {
				if deletedKeys[selectedKey] {
					display = selectedKey
					break
				}
			}
			if display == "" {
				for deletedKey := range deletedKeys {
					display = deletedKey
					break
				}
			}
			if result.operationCount > 1 {
				display = fmt.Sprintf("%s (+%d more)", display, result.operationCount-1)
			}
			result.displayKey = display
			result.sizeBytes = 0
		} else {
			if err := executor.deleteOne(plan.key); err != nil {
				return result, err
			}
			result.latencyMs = float64(time.Since(started).Milliseconds())
		}
	}
	return result, nil
}

// applyBenchmarkResult records a completed operation. The caller must hold
// the benchmark state mutex.
func applyBenchmarkResult(state map[string]interface{}, plan benchmarkOpPlan, result benchmarkOpResult, elapsedSeconds float64) {
	history := asMapSlice(state["history"])
	second := int(elapsedSeconds) + 1
	history = append(history, map[string]interface{}{
		"timestamp":        serializeTimePtr(time.Now().UTC()),
		"second":           second,
		"elapsedMs":        roundFloat(elapsedSeconds * 1000),
		"operation":        plan.operation,
		"key":              result.displayKey,
		"sizeBytes":        result.sizeBytes,
		"latencyMs":        roundFloat(result.latencyMs),
		"bytesTransferred": result.bytesTransferred,
		"success":          true,
		"checksumState":    result.checksumState,
		"operationCount":   result.operationCount,
	})
	state["history"] = history
	if plan.operation == "PUT" {
		activeObjects := asMapSlice(state["activeObjects"])
		updated := false
		for _, item := range activeObjects {
			if asString(item["key"]) == plan.key {
				item["sizeBytes"] = plan.sizeBytes
				updated = true
				break
			}
		}
		if !updated {
			state["activeObjects"] = append(activeObjects, map[string]interface{}{"key": plan.key, "sizeBytes": plan.sizeBytes})
		}
	}
	state["processedCount"] = asInt(state["processedCount"]) + result.operationCount
	if plan.operation == "DELETE" && result.operationCount > 1 {
		appendBenchmarkLog(state, fmt.Sprintf("DELETE POST removed %d object(s) in %.1f ms.", result.operationCount, roundFloat(result.latencyMs)))
	} else {
		appendBenchmarkLog(state, fmt.Sprintf("%s %s completed in %.1f ms.", plan.operation, result.displayKey, roundFloat(result.latencyMs)))
	}
}

// runBenchmarkBatch executes one tick's worth of operations using a worker
// pool of up to config.concurrentThreads goroutines sharing one client.
func runBenchmarkBatch(state map[string]interface{}, executor *benchmarkExecutor, config map[string]interface{}, batchSize, threads, operationCount int) error {
	workers := threads
	if workers > batchSize {
		workers = batchSize
	}
	if workers < 1 {
		workers = 1
	}
	operationMode := asString(config["testMode"]) == "operation-count"
	runID := asString(state["id"])
	baseElapsed := asFloat(state["activeElapsedSeconds"])
	tickStart := time.Now()
	supportsBatchDelete := executor.deleteBatch != nil

	var mu sync.Mutex
	remaining := batchSize
	plannedCount := asInt(state["processedCount"])
	var failure error
	var wg sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				mu.Lock()
				if failure != nil || remaining <= 0 || (operationMode && plannedCount >= operationCount) {
					mu.Unlock()
					return
				}
				remaining--
				plan := planBenchmarkOperation(state, plannedCount, supportsBatchDelete)
				expected := benchmarkPlanExpectedCount(plan)
				plannedCount += expected
				mu.Unlock()

				result, err := executeBenchmarkOperation(executor, runID, config, plan)
				if err != nil {
					if isMissingBenchmarkKeyErr(err) && plan.operation != "PUT" && !plan.multiDelete {
						mu.Lock()
						if plan.operation == "GET" {
							removeBenchmarkActiveObject(state, plan.key)
						}
						appendBenchmarkLog(state, fmt.Sprintf("Skipped missing benchmark object %s; rotating to the next object.", plan.key))
						remaining++
						plannedCount -= expected
						mu.Unlock()
						continue
					}
					mu.Lock()
					if failure == nil {
						failure = err
					}
					mu.Unlock()
					return
				}
				elapsedSeconds := baseElapsed + time.Since(tickStart).Seconds()
				mu.Lock()
				if result.logLine != "" {
					appendBenchmarkLog(state, result.logLine)
				}
				if result.retry {
					remaining++
					plannedCount -= expected
					mu.Unlock()
					continue
				}
				plannedCount += result.operationCount - expected
				applyBenchmarkResult(state, plan, result, elapsedSeconds)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	return failure
}

func persistBenchmarkOutputs(state map[string]interface{}) error {
	config := asMap(state["config"])
	csvPath := asString(config["csvOutputPath"])
	jsonPath := asString(config["jsonOutputPath"])
	logPath := asString(config["logFilePath"])
	for _, path := range []string{csvPath, jsonPath, logPath} {
		if path == "" {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
	}
	lines := []string{"second,operation,operationCount,latencyMs,sizeBytes,bytesTransferred,success,checksumState,key"}
	for _, record := range asMapSlice(state["history"]) {
		lines = append(lines, fmt.Sprintf(
			"%d,%s,%d,%.1f,%d,%d,true,%s,%s",
			asInt(record["second"]),
			asString(record["operation"]),
			benchmarkOperationCount(record),
			asFloat(record["latencyMs"]),
			asInt(record["sizeBytes"]),
			asInt(record["bytesTransferred"]),
			asString(record["checksumState"]),
			asString(record["key"]),
		))
	}
	if csvPath != "" {
		if err := os.WriteFile(csvPath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
			return err
		}
	}
	if jsonPath != "" {
		if err := os.WriteFile(jsonPath, []byte(mustJSON(state["resultSummary"])), 0o644); err != nil {
			return err
		}
	}
	if logPath != "" {
		if err := os.WriteFile(logPath, []byte(strings.Join(asStringSlice(state["liveLog"]), "\n")), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func bucketClient(params map[string]interface{}) (profile, string, *s3.Client, context.Context, error) {
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return profile{}, "", nil, nil, err
	}
	bucketName := strings.TrimSpace(asString(params["bucketName"]))
	if bucketName == "" {
		return profile{}, "", nil, nil, &sidecarError{Code: "invalid_config", Message: "Bucket name is required."}
	}
	client, ctx, err := buildClient(p)
	if err != nil {
		return profile{}, "", nil, nil, err
	}
	return p, bucketName, client, ctx, nil
}

func callAPI(ctx context.Context, client *s3.Client, apiCalls *[]map[string]interface{}, operation string, fn func(context.Context, *s3.Client) (interface{}, error)) (interface{}, error) {
	started := time.Now()
	result, err := fn(ctx, client)
	status := "ERROR"
	if err == nil {
		status = "200"
	}
	*apiCalls = append(*apiCalls, map[string]interface{}{
		"timestamp": serializeTimePtr(time.Now().UTC()),
		"operation": operation,
		"status":    status,
		"latencyMs": int(time.Since(started).Milliseconds()),
	})
	return result, err
}

func optionalAPI(ctx context.Context, client *s3.Client, apiCalls *[]map[string]interface{}, operation string, allowedCodes map[string]struct{}, fn func(context.Context, *s3.Client) (interface{}, error)) (interface{}, error) {
	result, err := callAPI(ctx, client, apiCalls, operation, fn)
	if err == nil {
		return result, nil
	}
	if code := awsErrorCode(err); code != "" {
		if _, ok := allowedCodes[code]; ok {
			return nil, nil
		}
	}
	return nil, err
}

func missingBucketConfigCodes() map[string]struct{} {
	return map[string]struct{}{
		"NoSuchLifecycleConfiguration":                   {},
		"NoSuchBucketPolicy":                             {},
		"NoSuchCORSConfiguration":                        {},
		"NoSuchBucket":                                   {},
		"NoSuchTagSet":                                   {},
		"ObjectLockConfigurationNotFoundError":           {},
		"NoSuchObjectLockConfiguration":                  {},
		"ServerSideEncryptionConfigurationNotFoundError": {},
		"MethodNotAllowed":                               {},
		"NotImplemented":                                 {},
		"XNotImplemented":                                {},
	}
}

func lifecycleRuleToMap(rule types.LifecycleRule) map[string]interface{} {
	transitionStorageClass := ""
	transitionDays := interface{}(nil)
	if len(rule.Transitions) > 0 {
		transitionStorageClass = string(rule.Transitions[0].StorageClass)
		if rule.Transitions[0].Days != nil {
			transitionDays = aws.ToInt32(rule.Transitions[0].Days)
		}
	}
	nonCurrentStorageClass := ""
	nonCurrentDays := interface{}(nil)
	if len(rule.NoncurrentVersionTransitions) > 0 {
		nonCurrentStorageClass = string(rule.NoncurrentVersionTransitions[0].StorageClass)
		if rule.NoncurrentVersionTransitions[0].NoncurrentDays != nil {
			nonCurrentDays = aws.ToInt32(rule.NoncurrentVersionTransitions[0].NoncurrentDays)
		}
	}
	var expirationDays interface{}
	var deleteExpiredMarker bool
	if rule.Expiration != nil {
		if rule.Expiration.Days != nil {
			expirationDays = aws.ToInt32(rule.Expiration.Days)
		}
		deleteExpiredMarker = aws.ToBool(rule.Expiration.ExpiredObjectDeleteMarker)
	}
	var nonCurrentExpirationDays interface{}
	if rule.NoncurrentVersionExpiration != nil && rule.NoncurrentVersionExpiration.NoncurrentDays != nil {
		nonCurrentExpirationDays = aws.ToInt32(rule.NoncurrentVersionExpiration.NoncurrentDays)
	}
	var abortDays interface{}
	if rule.AbortIncompleteMultipartUpload != nil && rule.AbortIncompleteMultipartUpload.DaysAfterInitiation != nil {
		abortDays = aws.ToInt32(rule.AbortIncompleteMultipartUpload.DaysAfterInitiation)
	}
	prefix := ""
	if rule.Filter != nil && rule.Filter.Prefix != nil {
		prefix = aws.ToString(rule.Filter.Prefix)
	}
	return map[string]interface{}{
		"id":                                 nonEmpty(aws.ToString(rule.ID), "rule"),
		"enabled":                            rule.Status == types.ExpirationStatusEnabled,
		"prefix":                             prefix,
		"expirationDays":                     expirationDays,
		"deleteExpiredObjectDeleteMarkers":   deleteExpiredMarker,
		"transitionStorageClass":             emptyToNil(transitionStorageClass),
		"transitionDays":                     transitionDays,
		"nonCurrentExpirationDays":           nonCurrentExpirationDays,
		"nonCurrentTransitionStorageClass":   emptyToNil(nonCurrentStorageClass),
		"nonCurrentTransitionDays":           nonCurrentDays,
		"abortIncompleteMultipartUploadDays": abortDays,
	}
}

func mapError(err error) map[string]interface{} {
	var sideErr *sidecarError
	if errors.As(err, &sideErr) {
		return map[string]interface{}{
			"code":    sideErr.Code,
			"message": sideErr.Message,
			"details": sideErr.Details,
		}
	}

	var apiError smithy.APIError
	if errors.As(err, &apiError) {
		code := apiError.ErrorCode()
		message := apiError.ErrorMessage()
		switch code {
		case "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch":
			return map[string]interface{}{"code": "auth_failed", "message": message, "details": map[string]interface{}{"awsCode": code}}
		case "RequestTimeout":
			return map[string]interface{}{"code": "timeout", "message": message, "details": map[string]interface{}{"awsCode": code}}
		case "SlowDown":
			return map[string]interface{}{"code": "throttled", "message": message, "details": map[string]interface{}{"awsCode": code}}
		default:
			return map[string]interface{}{"code": "unknown", "message": message, "details": map[string]interface{}{"awsCode": code}}
		}
	}

	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		if strings.Contains(strings.ToLower(urlErr.Error()), "tls") || strings.Contains(strings.ToLower(urlErr.Error()), "certificate") {
			return map[string]interface{}{"code": "tls_error", "message": urlErr.Error()}
		}
		if timeoutErr, ok := urlErr.Err.(interface{ Timeout() bool }); ok && timeoutErr.Timeout() {
			return map[string]interface{}{"code": "timeout", "message": urlErr.Error()}
		}
	}

	if timeoutErr, ok := err.(interface{ Timeout() bool }); ok && timeoutErr.Timeout() {
		return map[string]interface{}{"code": "timeout", "message": err.Error()}
	}
	return map[string]interface{}{"code": "unknown", "message": err.Error()}
}

func awsErrorCode(err error) string {
	var apiError smithy.APIError
	if errors.As(err, &apiError) {
		return apiError.ErrorCode()
	}
	return ""
}

func asMap(value interface{}) map[string]interface{} {
	if value == nil {
		return nil
	}
	if typed, ok := value.(map[string]interface{}); ok {
		return typed
	}
	if typed, ok := value.(map[interface{}]interface{}); ok {
		converted := make(map[string]interface{}, len(typed))
		for key, item := range typed {
			converted[fmt.Sprint(key)] = item
		}
		return converted
	}
	return nil
}

func asMapSlice(value interface{}) []map[string]interface{} {
	items, ok := value.([]interface{})
	if !ok {
		if typed, ok := value.([]map[string]interface{}); ok {
			return typed
		}
		return nil
	}
	result := make([]map[string]interface{}, 0, len(items))
	for _, item := range items {
		if converted := asMap(item); len(converted) > 0 {
			result = append(result, converted)
		}
	}
	return result
}

func asString(value interface{}) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case fmt.Stringer:
		return typed.String()
	default:
		return fmt.Sprint(value)
	}
}

func asFloat(value interface{}) float64 {
	switch typed := value.(type) {
	case float64:
		return typed
	case float32:
		return float64(typed)
	case int:
		return float64(typed)
	case int32:
		return float64(typed)
	case int64:
		return float64(typed)
	case json.Number:
		number, _ := typed.Float64()
		return number
	case string:
		var parsed float64
		fmt.Sscanf(strings.TrimSpace(typed), "%f", &parsed)
		return parsed
	default:
		return 0
	}
}

func asBool(value interface{}) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		return strings.EqualFold(strings.TrimSpace(typed), "true")
	default:
		return false
	}
}

func payloadHasFalse(value interface{}) bool {
	if value == nil {
		return false
	}
	return !asBool(value)
}

func asInt(value interface{}) int {
	switch typed := value.(type) {
	case int:
		return typed
	case int32:
		return int(typed)
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	case json.Number:
		number, _ := typed.Int64()
		return int(number)
	case string:
		var parsed int
		fmt.Sscanf(strings.TrimSpace(typed), "%d", &parsed)
		return parsed
	default:
		return 0
	}
}

func asStringSlice(value interface{}) []string {
	items, ok := value.([]interface{})
	if !ok {
		if typed, ok := value.([]string); ok {
			return typed
		}
		return nil
	}
	result := make([]string, 0, len(items))
	for _, item := range items {
		text := strings.TrimSpace(asString(item))
		if text != "" {
			result = append(result, text)
		}
	}
	return result
}

func asStringMap(value interface{}) map[string]string {
	result := map[string]string{}
	raw, ok := value.(map[string]interface{})
	if !ok {
		if typed, ok := value.(map[string]string); ok {
			return typed
		}
		return result
	}
	for key, item := range raw {
		text := strings.TrimSpace(asString(item))
		if text != "" {
			result[key] = text
		}
	}
	return result
}

func asInterfaceSlice(value interface{}) []interface{} {
	switch typed := value.(type) {
	case []interface{}:
		return typed
	case []string:
		result := make([]interface{}, 0, len(typed))
		for _, item := range typed {
			result = append(result, item)
		}
		return result
	default:
		return nil
	}
}

func maxInt(value, minimum, fallback int) int {
	if value == 0 {
		value = fallback
	}
	if value < minimum {
		return minimum
	}
	return value
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func meanFloat(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	total := 0.0
	for _, value := range values {
		total += value
	}
	return total / float64(len(values))
}

func roundFloat(value float64) float64 {
	return float64(int((value*10)+0.5)) / 10
}

func serializeTime(value *time.Time) string {
	if value == nil || value.IsZero() {
		return time.Unix(0, 0).UTC().Format(time.RFC3339)
	}
	return value.UTC().Format(time.RFC3339)
}

func serializeTimePtr(value time.Time) string {
	return value.UTC().Format(time.RFC3339)
}

func mustJSON(value interface{}) string {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return "{}"
	}
	return string(data)
}

func nonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func emptyToNil(value string) interface{} {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return value
}

func trimQuotes(value string) interface{} {
	trimmed := strings.Trim(strings.TrimSpace(value), "\"")
	if trimmed == "" {
		return nil
	}
	return trimmed
}

func trimQuotesString(value string) string {
	return strings.Trim(strings.TrimSpace(value), "\"")
}

func stringPtr(value string) *string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return aws.String(value)
}
