package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
	"github.com/aws/smithy-go/logging"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

const (
	conformanceSDK     = "aws-sdk-go-v2 1.96.4" // service/s3 module in go.mod
	conformanceMaxRead = 32 << 20
	presignedRequestOp = "PresignedRequest"
)

type conformanceOperation func(context.Context, *s3.Client, map[string]interface{}, []byte) (map[string]interface{}, error)

func conformanceSDKOperation[Input, Output any](invoke func(*s3.Client, context.Context, *Input, ...func(*s3.Options)) (*Output, error)) conformanceOperation {
	return func(ctx context.Context, client *s3.Client, members map[string]interface{}, body []byte) (map[string]interface{}, error) {
		var input Input
		if err := decodeConformanceInput(members, &input); err != nil {
			return nil, err
		}
		switch value := any(&input).(type) {
		case *s3.PutObjectInput:
			value.Body = bytes.NewReader(body)
		case *s3.UploadPartInput:
			value.Body = bytes.NewReader(body)
		}
		observation := ctx.Value(conformanceObservationKey{}).(*conformanceObservation)
		started := time.Now()
		output, err := invoke(client, ctx, &input)
		if err != nil {
			observation.latencyMs = conformanceMilliseconds(started)
			return nil, err
		}
		var digest map[string]interface{}
		if object, ok := any(output).(*s3.GetObjectOutput); ok && object.Body != nil {
			length := int64(-1)
			if object.ContentLength != nil {
				length = *object.ContentLength
			}
			digest, err = conformanceDigest(object.Body, length, nil)
		}
		observation.latencyMs = conformanceMilliseconds(started)
		result := conformanceOutput(reflect.ValueOf(output)).(map[string]interface{})
		if digest != nil {
			result["Body"] = digest
		}
		return result, err
	}
}

var conformanceOperations = map[string]conformanceOperation{
	"AbortMultipartUpload":                        conformanceSDKOperation((*s3.Client).AbortMultipartUpload),
	"CompleteMultipartUpload":                     conformanceSDKOperation((*s3.Client).CompleteMultipartUpload),
	"CopyObject":                                  conformanceSDKOperation((*s3.Client).CopyObject),
	"CreateBucket":                                conformanceSDKOperation((*s3.Client).CreateBucket),
	"CreateMultipartUpload":                       conformanceSDKOperation((*s3.Client).CreateMultipartUpload),
	"DeleteBucket":                                conformanceSDKOperation((*s3.Client).DeleteBucket),
	"DeleteBucketAnalyticsConfiguration":          conformanceSDKOperation((*s3.Client).DeleteBucketAnalyticsConfiguration),
	"DeleteBucketCors":                            conformanceSDKOperation((*s3.Client).DeleteBucketCors),
	"DeleteBucketEncryption":                      conformanceSDKOperation((*s3.Client).DeleteBucketEncryption),
	"DeleteBucketIntelligentTieringConfiguration": conformanceSDKOperation((*s3.Client).DeleteBucketIntelligentTieringConfiguration),
	"DeleteBucketInventoryConfiguration":          conformanceSDKOperation((*s3.Client).DeleteBucketInventoryConfiguration),
	"DeleteBucketLifecycle":                       conformanceSDKOperation((*s3.Client).DeleteBucketLifecycle),
	"DeleteBucketMetricsConfiguration":            conformanceSDKOperation((*s3.Client).DeleteBucketMetricsConfiguration),
	"DeleteBucketOwnershipControls":               conformanceSDKOperation((*s3.Client).DeleteBucketOwnershipControls),
	"DeleteBucketPolicy":                          conformanceSDKOperation((*s3.Client).DeleteBucketPolicy),
	"DeleteBucketReplication":                     conformanceSDKOperation((*s3.Client).DeleteBucketReplication),
	"DeleteBucketTagging":                         conformanceSDKOperation((*s3.Client).DeleteBucketTagging),
	"DeleteBucketWebsite":                         conformanceSDKOperation((*s3.Client).DeleteBucketWebsite),
	"DeleteObject":                                conformanceSDKOperation((*s3.Client).DeleteObject),
	"DeleteObjectTagging":                         conformanceSDKOperation((*s3.Client).DeleteObjectTagging),
	"DeleteObjects":                               conformanceSDKOperation((*s3.Client).DeleteObjects),
	"DeletePublicAccessBlock":                     conformanceSDKOperation((*s3.Client).DeletePublicAccessBlock),
	"GetBucketAccelerateConfiguration":            conformanceSDKOperation((*s3.Client).GetBucketAccelerateConfiguration),
	"GetBucketAcl":                                conformanceSDKOperation((*s3.Client).GetBucketAcl),
	"GetBucketAnalyticsConfiguration":             conformanceSDKOperation((*s3.Client).GetBucketAnalyticsConfiguration),
	"GetBucketCors":                               conformanceSDKOperation((*s3.Client).GetBucketCors),
	"GetBucketEncryption":                         conformanceSDKOperation((*s3.Client).GetBucketEncryption),
	"GetBucketIntelligentTieringConfiguration":    conformanceSDKOperation((*s3.Client).GetBucketIntelligentTieringConfiguration),
	"GetBucketInventoryConfiguration":             conformanceSDKOperation((*s3.Client).GetBucketInventoryConfiguration),
	"GetBucketLifecycleConfiguration":             conformanceSDKOperation((*s3.Client).GetBucketLifecycleConfiguration),
	"GetBucketLocation":                           conformanceSDKOperation((*s3.Client).GetBucketLocation),
	"GetBucketLogging":                            conformanceSDKOperation((*s3.Client).GetBucketLogging),
	"GetBucketMetricsConfiguration":               conformanceSDKOperation((*s3.Client).GetBucketMetricsConfiguration),
	"GetBucketNotificationConfiguration":          conformanceSDKOperation((*s3.Client).GetBucketNotificationConfiguration),
	"GetBucketOwnershipControls":                  conformanceSDKOperation((*s3.Client).GetBucketOwnershipControls),
	"GetBucketPolicy":                             conformanceSDKOperation((*s3.Client).GetBucketPolicy),
	"GetBucketPolicyStatus":                       conformanceSDKOperation((*s3.Client).GetBucketPolicyStatus),
	"GetBucketReplication":                        conformanceSDKOperation((*s3.Client).GetBucketReplication),
	"GetBucketRequestPayment":                     conformanceSDKOperation((*s3.Client).GetBucketRequestPayment),
	"GetBucketTagging":                            conformanceSDKOperation((*s3.Client).GetBucketTagging),
	"GetBucketVersioning":                         conformanceSDKOperation((*s3.Client).GetBucketVersioning),
	"GetBucketWebsite":                            conformanceSDKOperation((*s3.Client).GetBucketWebsite),
	"GetObject":                                   conformanceSDKOperation((*s3.Client).GetObject),
	"GetObjectAcl":                                conformanceSDKOperation((*s3.Client).GetObjectAcl),
	"GetObjectAttributes":                         conformanceSDKOperation((*s3.Client).GetObjectAttributes),
	"GetObjectLegalHold":                          conformanceSDKOperation((*s3.Client).GetObjectLegalHold),
	"GetObjectLockConfiguration":                  conformanceSDKOperation((*s3.Client).GetObjectLockConfiguration),
	"GetObjectRetention":                          conformanceSDKOperation((*s3.Client).GetObjectRetention),
	"GetObjectTagging":                            conformanceSDKOperation((*s3.Client).GetObjectTagging),
	"GetPublicAccessBlock":                        conformanceSDKOperation((*s3.Client).GetPublicAccessBlock),
	"HeadBucket":                                  conformanceSDKOperation((*s3.Client).HeadBucket),
	"HeadObject":                                  conformanceSDKOperation((*s3.Client).HeadObject),
	"ListBucketAnalyticsConfigurations":           conformanceSDKOperation((*s3.Client).ListBucketAnalyticsConfigurations),
	"ListBucketIntelligentTieringConfigurations":  conformanceSDKOperation((*s3.Client).ListBucketIntelligentTieringConfigurations),
	"ListBucketInventoryConfigurations":           conformanceSDKOperation((*s3.Client).ListBucketInventoryConfigurations),
	"ListBucketMetricsConfigurations":             conformanceSDKOperation((*s3.Client).ListBucketMetricsConfigurations),
	"ListBuckets":                                 conformanceSDKOperation((*s3.Client).ListBuckets),
	"ListMultipartUploads":                        conformanceSDKOperation((*s3.Client).ListMultipartUploads),
	"ListObjectVersions":                          conformanceSDKOperation((*s3.Client).ListObjectVersions),
	"ListObjects":                                 conformanceSDKOperation((*s3.Client).ListObjects),
	"ListObjectsV2":                               conformanceSDKOperation((*s3.Client).ListObjectsV2),
	"ListParts":                                   conformanceSDKOperation((*s3.Client).ListParts),
	"PutBucketAccelerateConfiguration":            conformanceSDKOperation((*s3.Client).PutBucketAccelerateConfiguration),
	"PutBucketAcl":                                conformanceSDKOperation((*s3.Client).PutBucketAcl),
	"PutBucketAnalyticsConfiguration":             conformanceSDKOperation((*s3.Client).PutBucketAnalyticsConfiguration),
	"PutBucketCors":                               conformanceSDKOperation((*s3.Client).PutBucketCors),
	"PutBucketEncryption":                         conformanceSDKOperation((*s3.Client).PutBucketEncryption),
	"PutBucketIntelligentTieringConfiguration":    conformanceSDKOperation((*s3.Client).PutBucketIntelligentTieringConfiguration),
	"PutBucketInventoryConfiguration":             conformanceSDKOperation((*s3.Client).PutBucketInventoryConfiguration),
	"PutBucketLifecycleConfiguration":             conformanceSDKOperation((*s3.Client).PutBucketLifecycleConfiguration),
	"PutBucketMetricsConfiguration":               conformanceSDKOperation((*s3.Client).PutBucketMetricsConfiguration),
	"PutBucketNotificationConfiguration":          conformanceSDKOperation((*s3.Client).PutBucketNotificationConfiguration),
	"PutBucketOwnershipControls":                  conformanceSDKOperation((*s3.Client).PutBucketOwnershipControls),
	"PutBucketPolicy":                             conformanceSDKOperation((*s3.Client).PutBucketPolicy),
	"PutBucketRequestPayment":                     conformanceSDKOperation((*s3.Client).PutBucketRequestPayment),
	"PutBucketTagging":                            conformanceSDKOperation((*s3.Client).PutBucketTagging),
	"PutBucketVersioning":                         conformanceSDKOperation((*s3.Client).PutBucketVersioning),
	"PutBucketWebsite":                            conformanceSDKOperation((*s3.Client).PutBucketWebsite),
	"PutObject":                                   conformanceSDKOperation((*s3.Client).PutObject),
	"PutObjectAcl":                                conformanceSDKOperation((*s3.Client).PutObjectAcl),
	"PutObjectLegalHold":                          conformanceSDKOperation((*s3.Client).PutObjectLegalHold),
	"PutObjectLockConfiguration":                  conformanceSDKOperation((*s3.Client).PutObjectLockConfiguration),
	"PutObjectRetention":                          conformanceSDKOperation((*s3.Client).PutObjectRetention),
	"PutObjectTagging":                            conformanceSDKOperation((*s3.Client).PutObjectTagging),
	"PutPublicAccessBlock":                        conformanceSDKOperation((*s3.Client).PutPublicAccessBlock),
	"UploadPart":                                  conformanceSDKOperation((*s3.Client).UploadPart),
	"UploadPartCopy":                              conformanceSDKOperation((*s3.Client).UploadPartCopy),
}

func isS3ConformanceProfile(payload map[string]interface{}) bool {
	switch strings.ToLower(strings.TrimSpace(asString(payload["endpointType"]))) {
	case "s3compatible", "awss3":
		return true
	default:
		return false
	}
}

func s3ConformanceCapability(supported bool) map[string]interface{} {
	item := map[string]interface{}{"key": "conformance.s3", "label": "S3 API conformance", "state": "unsupported"}
	if !supported {
		item["reason"] = "S3 conformance requires an S3 profile."
		return item
	}
	ops := make([]string, 0, len(conformanceOperations)+1)
	for op := range conformanceOperations {
		ops = append(ops, op)
	}
	ops = append(ops, presignedRequestOp)
	slices.Sort(ops)
	item["state"] = "supported"
	item["version"] = 1
	item["sdk"] = conformanceSDK
	item["client"] = map[string]interface{}{
		"maxAttempts": 1, "requestChecksumCalculation": "when_required", "responseChecksumValidation": "when_required",
	}
	item["ops"] = ops
	return item
}

type conformanceClient struct {
	sdk       *s3.Client
	transport *http.Transport
}

var conformanceClients = struct {
	sync.Mutex
	clients map[profile]conformanceClient
	order   []profile
}{clients: make(map[profile]conformanceClient)}

func getConformanceClient(ctx context.Context, p profile) (conformanceClient, error) {
	conformanceClients.Lock()
	defer conformanceClients.Unlock()
	if client, ok := conformanceClients.clients[p]; ok {
		return client, nil
	}
	transport, err := profileTransport(p)
	if err != nil {
		return conformanceClient{}, err
	}
	transport.DisableCompression = true
	httpClient := &http.Client{
		Transport:     inactivityRoundTripper{base: transport, timeout: time.Duration(p.ReadTimeoutSeconds) * time.Second},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	sdk, err := newProfileS3Client(ctx, p, httpClient, func(options *s3.Options) {
		options.HTTPClient = conformanceTransport{httpClient.Transport}
		options.Retryer = aws.NopRetryer{}
		options.RetryMaxAttempts = 1
		options.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
		options.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
		options.ClientLogMode = 0
		options.Logger = logging.Nop{}
	})
	if err != nil {
		return conformanceClient{}, err
	}
	if len(conformanceClients.order) >= 16 {
		oldest := conformanceClients.order[0]
		conformanceClients.order = conformanceClients.order[1:]
		conformanceClients.clients[oldest].transport.CloseIdleConnections()
		delete(conformanceClients.clients, oldest)
	}
	client := conformanceClient{sdk: sdk, transport: transport}
	conformanceClients.clients[p] = client
	conformanceClients.order = append(conformanceClients.order, p)
	return client, nil
}

type conformanceObservationKey struct{}

type conformanceObservation struct {
	attempts     int
	latencyMs    float64
	requestID    string
	status       int
	headers      http.Header
	secrets      []string
	sentURL      *url.URL
	presignQuery url.Values
}

type conformanceTransport struct{ base http.RoundTripper }

func (o *conformanceObservation) rememberCredential(value string) {
	// Short emulator credentials can also be ordinary catalog data.
	if utf8.RuneCountInString(value) >= 16 {
		o.secrets = append(o.secrets, value, url.QueryEscape(value))
	}
}

// Serve as the SDK HTTP client directly. A net/http.Client can attempt to
// parse a redirect's Location before its CheckRedirect hook runs.
func (t conformanceTransport) Do(req *http.Request) (*http.Response, error) {
	observation, _ := req.Context().Value(conformanceObservationKey{}).(*conformanceObservation)
	if observation == nil {
		return t.base.RoundTrip(req)
	}
	observation.attempts++
	observation.sentURL = req.URL
	authorization := req.Header.Get("Authorization")
	_, signature, _ := strings.Cut(authorization, "Signature=")
	_, credential, _ := strings.Cut(authorization, "Credential=")
	accessKey, _, _ := strings.Cut(credential, "/")
	// Remove the full Authorization value before scrubbing any credential it contains.
	observation.secrets = slices.Insert(observation.secrets, 0, authorization, signature)
	observation.rememberCredential(accessKey)
	observation.rememberCredential(req.Header.Get("X-Amz-Security-Token"))
	observation.secrets = append(observation.secrets, encryptionSecrets(req.Header)...)
	observation.secrets = append(observation.secrets,
		req.Header.Get("X-Amz-Server-Side-Encryption-Customer-Key-Md5"),
		req.Header.Get("X-Amz-Copy-Source-Server-Side-Encryption-Customer-Key-Md5"),
	)
	query := req.URL.Query()
	if query.Has("X-Amz-Signature") {
		observation.presignQuery = query
		for _, key := range []string{"X-Amz-Credential", "X-Amz-Signature"} {
			if value := query.Get(key); value != "" {
				observation.secrets = append(observation.secrets, value, url.QueryEscape(value))
			}
		}
		observation.rememberCredential(query.Get("X-Amz-Security-Token"))
	}
	resp, err := t.base.RoundTrip(req)
	if resp != nil {
		observation.status = resp.StatusCode
		observation.headers = resp.Header.Clone()
	}
	return resp, err
}

func invalidConformanceRequest(message string) error {
	return &sidecarError{Code: "invalid_request", Message: message}
}

func decodeConformanceInput(value interface{}, target interface{}) error {
	data, err := json.Marshal(value)
	if err != nil {
		return invalidConformanceRequest("Invalid S3 conformance input.")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(target) != nil {
		return invalidConformanceRequest("An S3 conformance input member has an unknown name or invalid type.")
	}
	return nil
}

func containsConformanceCustomerKey(value interface{}) bool {
	switch value := value.(type) {
	case map[string]interface{}:
		for key, member := range value {
			name := strings.ToLower(key)
			if strings.HasPrefix(name, "ssecustomer") || strings.HasPrefix(name, "copysourcessecustomer") || containsConformanceCustomerKey(member) {
				return true
			}
		}
	case []interface{}:
		for _, member := range value {
			if containsConformanceCustomerKey(member) {
				return true
			}
		}
	}
	return false
}

func conformanceMembers(params map[string]interface{}, p profile, op string) (map[string]interface{}, requestEncryption, error) {
	var raw map[string]interface{}
	if input, provided := params["input"]; provided {
		var ok bool
		raw, ok = input.(map[string]interface{})
		if !ok || raw == nil {
			return nil, requestEncryption{}, invalidConformanceRequest("S3 conformance input must be an object.")
		}
	}
	if containsConformanceCustomerKey(raw) {
		return nil, requestEncryption{}, invalidConformanceRequest("Use the conformance encryption fields for SSE-C.")
	}
	members := make(map[string]interface{}, len(raw))
	for key, value := range raw {
		members[key] = value
	}
	copying := op == "CopyObject" || op == "UploadPartCopy"
	if rawSource, exists := members["CopySource"]; copying && exists {
		var source struct{ Bucket, Key, VersionId *string }
		if err := decodeConformanceInput(rawSource, &source); err != nil {
			return nil, requestEncryption{}, err
		}
		if source.Bucket == nil || source.Key == nil {
			return nil, requestEncryption{}, invalidConformanceRequest("CopySource requires Bucket and Key.")
		}
		members["CopySource"] = encodedS3CopySource(*source.Bucket, *source.Key, aws.ToString(source.VersionId))
	}
	if op == "ListParts" {
		// The Go SDK models this marker as a string, including in the output.
		if number, ok := members["PartNumberMarker"].(float64); ok {
			if number != float64(int32(number)) {
				return nil, requestEncryption{}, invalidConformanceRequest("PartNumberMarker must be an integer or string.")
			}
			members["PartNumberMarker"] = strconv.FormatInt(int64(number), 10)
		}
	}

	for _, field := range []string{"encryption", "sourceEncryption"} {
		if raw := params[field]; raw != nil && asString(asMap(raw)["mode"]) != "sse-c" {
			return nil, requestEncryption{}, invalidEncryption()
		}
	}
	encryption, err := parseRequestEncryption(params, p, copying)
	if err != nil {
		return nil, requestEncryption{}, err
	}
	if encryption.destination.customer() {
		switch op {
		case "PutObject", "GetObject", "HeadObject", "CopyObject", "CreateMultipartUpload",
			"UploadPart", "UploadPartCopy", "CompleteMultipartUpload", "GetObjectAttributes":
			addConformanceSSECustomer(members, "", encryption.destination)
		default:
			return nil, requestEncryption{}, invalidEncryption()
		}
	}
	if encryption.source.customer() {
		addConformanceSSECustomer(members, "CopySource", encryption.source)
	}
	return members, encryption, nil
}

func addConformanceSSECustomer(members map[string]interface{}, prefix string, encryption objectEncryption) {
	const header = "x-amz-server-side-encryption-customer-"
	members[prefix+"SSECustomerAlgorithm"] = encryption.headers.Get(header + "algorithm")
	members[prefix+"SSECustomerKey"] = encryption.headers.Get(header + "key")
	members[prefix+"SSECustomerKeyMD5"] = encryption.headers.Get(header + "key-md5")
}

func conformanceBody(raw interface{}) ([]byte, error) {
	if raw == nil {
		return nil, nil
	}
	body, ok := raw.(map[string]interface{})
	if !ok || len(body) != 1 {
		return nil, invalidConformanceRequest("Supply one S3 conformance body variant.")
	}
	if encoded, ok := body["base64"].(string); ok {
		const limit = 1 << 20
		if len(encoded) <= base64.StdEncoding.EncodedLen(limit) {
			if data, err := base64.StdEncoding.Strict().DecodeString(encoded); err == nil && len(data) <= limit {
				return data, nil
			}
		}
	} else if text, ok := body["text"].(string); ok {
		if len(text) <= 64<<10 {
			return []byte(text), nil
		}
	} else if body["generate"] != nil {
		var generated struct{ Size, Seed *int64 }
		if err := decodeConformanceInput(body["generate"], &generated); err == nil &&
			generated.Size != nil && *generated.Size >= 0 && *generated.Size <= 16<<20 &&
			generated.Seed != nil && *generated.Seed >= 0 && *generated.Seed <= 65535 {
			data := make([]byte, *generated.Size)
			for i := int64(0); i < *generated.Size; i++ {
				data[i] = byte((*generated.Seed*131 + i*7 + (i >> 10)) & 0xff)
			}
			return data, nil
		}
	}
	return nil, invalidConformanceRequest("Invalid S3 conformance body or body exceeds its size limit.")
}

func conformanceDigest(body io.ReadCloser, contentLength int64, sample io.Writer) (map[string]interface{}, error) {
	digest := sha256.New()
	reader := io.LimitReader(body, conformanceMaxRead)
	if sample != nil {
		reader = io.TeeReader(reader, sample)
	}
	n, readErr := io.Copy(digest, reader)
	if err := errors.Join(readErr, body.Close()); err != nil {
		return nil, err
	}
	result := map[string]interface{}{"length": n, "sha256": hex.EncodeToString(digest.Sum(nil))}
	// An unframed body at the limit may have more bytes. Do not read a
	// lookahead byte from the stream to distinguish that from exact length.
	if n == conformanceMaxRead && (contentLength < 0 || contentLength > n) {
		result["truncated"] = true
	}
	return result, nil
}

// Walk the SDK's exported members so omitted pointers stay absent and time
// values can be normalized without treating ordinary strings as dates.
func conformanceOutput(value reflect.Value) interface{} {
	switch value.Kind() {
	case reflect.Pointer, reflect.Interface:
		if !value.IsNil() {
			return conformanceOutput(value.Elem())
		}
	case reflect.Struct:
		if stamp, ok := value.Interface().(time.Time); ok {
			return stamp.UTC().Format(time.RFC3339Nano)
		}
		result := make(map[string]interface{})
		for i := range value.NumField() {
			field := value.Type().Field(i)
			if !field.IsExported() || field.Name == "ResultMetadata" || field.Name == "Body" || conformanceSecretField(field.Name) {
				continue
			}
			member := value.Field(i)
			if member.Kind() == reflect.String && member.Len() == 0 {
				continue // An unset enum is represented by its zero value.
			}
			if item := conformanceOutput(member); item != nil {
				result[field.Name] = item
			}
		}
		return result
	case reflect.Slice:
		if value.Len() > 0 {
			result := make([]interface{}, 0, value.Len())
			for i := range value.Len() {
				if item := conformanceOutput(value.Index(i)); item != nil {
					result = append(result, item)
				}
			}
			return result
		}
	case reflect.Map:
		// SDK object metadata is already reported through the capped headers.
	default:
		return value.Interface()
	}
	return nil
}

func conformanceSecretField(name string) bool {
	switch strings.ToLower(name) {
	case "authorization", "proxy-authorization", "secretkey", "secretaccesskey", "sessiontoken",
		"x-amz-security-token", "cookie", "set-cookie", "ssecustomerkey", "ssecustomerkeymd5",
		"copysourcessecustomerkey", "copysourcessecustomerkeymd5":
		return true
	}
	return encryptionSecretField(name)
}

var conformanceHeaderNames = strings.Fields(`
	etag content-type content-length content-range content-encoding content-disposition
	content-language cache-control expires last-modified date accept-ranges location
	x-amz-request-id x-amz-version-id x-amz-delete-marker x-amz-tagging-count
	x-amz-mp-parts-count x-amz-storage-class x-amz-expiration x-amz-replication-status
	x-amz-copy-source-version-id x-amz-bucket-region x-amz-website-redirect-location
	x-amz-missing-meta x-amz-restore x-amz-abort-date x-amz-abort-rule-id
	x-amz-server-side-encryption x-amz-server-side-encryption-aws-kms-key-id
	x-amz-server-side-encryption-bucket-key-enabled x-amz-server-side-encryption-customer-algorithm
	x-amz-object-lock-mode x-amz-object-lock-retain-until-date x-amz-object-lock-legal-hold
	access-control-allow-origin access-control-allow-methods access-control-expose-headers
`)

var conformanceURLWithQuery = regexp.MustCompile(`(?i)https?://[^\s<>"'?]*\?[^\s<>"']*`)
var conformanceCredentialQuery = regexp.MustCompile(`(?i)(\bx-amz-(?:signature|security-token|credential)=)[^\s<>"'&,]+`)
var conformanceSigningField = regexp.MustCompile(`(?i)(\b(?:(?:x-amz-(?:signature|security-token|credential)|signature)=|x-amz-security-token["']?\s*:\s*))(?:"[^"]*"|'[^']*'|[^\s<>"'&,]+)`)

func (o *conformanceObservation) clean(text string) string {
	text = conformanceURLWithQuery.ReplaceAllString(text, "[redacted]")
	return o.cleanFields(text)
}

func (o *conformanceObservation) cleanFields(text string) string {
	return conformanceSigningField.ReplaceAllString(o.cleanValues(text), "$1[redacted]")
}

func (o *conformanceObservation) cleanValues(text string) string {
	if o.sentURL != nil && o.sentURL.RawQuery != "" {
		text = strings.ReplaceAll(text, o.sentURL.String(), "[redacted]")
		text = strings.ReplaceAll(text, o.sentURL.RequestURI(), "[redacted]")
	}
	for name, values := range o.presignQuery {
		for _, value := range values {
			escaped := url.QueryEscape(value)
			text = strings.ReplaceAll(text, name+"="+escaped, name+"=[redacted]")
			text = strings.ReplaceAll(text, name+"="+value, name+"=[redacted]")
		}
	}
	text = conformanceCredentialQuery.ReplaceAllString(text, "${1}[redacted]")
	return redactEncryptionText(text, o.secrets)
}

func conformanceTextLimit(text string, characters int) string {
	for index := range text {
		if characters == 0 {
			return text[:index]
		}
		characters--
	}
	return text
}

func (o *conformanceObservation) responseHeaders() map[string]interface{} {
	result := make(map[string]interface{})
	add := func(name string) {
		if metaName, isMetadata := strings.CutPrefix(name, "x-amz-meta-"); isMetadata &&
			(o.cleanValues(metaName) != metaName || conformanceSecretField(metaName)) {
			return
		}
		if values := o.headers.Values(name); len(values) > 0 {
			cleaned := make([]string, 0, len(values))
			for _, value := range values {
				if name == "location" || name == "x-amz-website-redirect-location" {
					if path, _, hasQuery := strings.Cut(value, "?"); hasQuery {
						value = path + "?[query]"
					}
					cleaned = append(cleaned, o.cleanFields(value))
				} else {
					cleaned = append(cleaned, o.clean(value))
				}
			}
			result[name] = conformanceTextLimit(strings.Join(cleaned, ", "), 512)
		}
	}
	for _, name := range conformanceHeaderNames {
		add(name)
	}
	names := make([]string, 0, len(o.headers))
	for name := range o.headers {
		names = append(names, strings.ToLower(name))
	}
	slices.Sort(names)
	// Keep checksums ahead of custom metadata when both compete for the cap.
	for _, name := range names {
		if len(result) >= 48 {
			break
		}
		if strings.HasPrefix(name, "x-amz-checksum-") {
			add(name)
		}
	}
	metadata := 0
	for _, name := range names {
		if len(result) >= 48 || metadata >= 16 {
			break
		}
		if strings.HasPrefix(name, "x-amz-meta-") {
			before := len(result)
			add(name)
			metadata += len(result) - before
		}
	}
	return result
}

func s3ConformanceOp(params map[string]interface{}) (map[string]interface{}, error) {
	payload := asMap(params["profile"])
	if !isS3ConformanceProfile(payload) {
		return nil, &sidecarError{Code: "unsupported_feature", Message: "S3 conformance requires an S3 profile."}
	}
	op := asString(params["op"])
	invoke, supported := conformanceOperations[op]
	if op == presignedRequestOp {
		invoke, supported = conformancePresignedRequest, true
	}
	if !supported {
		return nil, &sidecarError{Code: "unsupported_feature", Message: "This S3 operation is outside the conformance allowlist."}
	}

	p, err := parseProfile(payload)
	if err != nil {
		return nil, err
	}
	endpoint, err := url.Parse(p.EndpointURL)
	if err != nil || endpoint.Hostname() == "" || endpoint.User != nil || (endpoint.Scheme != "http" && endpoint.Scheme != "https") {
		return nil, &sidecarError{Code: "invalid_config", Message: "S3 conformance requires a valid HTTP or HTTPS endpoint URL."}
	}
	members, encryption, err := conformanceMembers(params, p, op)
	if err != nil {
		return nil, err
	}
	if raw, supplied := params["body"]; supplied {
		if raw == nil {
			return nil, invalidConformanceRequest("S3 conformance body must be an object.")
		}
		if op != "PutObject" && op != "UploadPart" && !(op == presignedRequestOp && members["Method"] == http.MethodPut) {
			return nil, invalidConformanceRequest("This S3 operation does not accept a conformance body.")
		}
	}
	body, err := conformanceBody(params["body"])
	if err != nil {
		return nil, err
	}
	ctx := context.Background()
	client, err := getConformanceClient(ctx, p)
	if err != nil {
		var profileError *sidecarError
		if errors.As(err, &profileError) {
			return nil, profileError
		}
		return nil, &sidecarError{Code: "invalid_config", Message: "Could not configure the S3 conformance client."}
	}
	observation := &conformanceObservation{}
	for _, credential := range []string{p.AccessKey, p.SecretKey, p.SessionToken} {
		observation.rememberCredential(credential)
	}
	observation.secrets = append(observation.secrets, encryptionSecrets(encryption.destination.headers)...)
	observation.secrets = append(observation.secrets, encryptionSecrets(encryption.source.headers)...)
	ctx = context.WithValue(ctx, conformanceObservationKey{}, observation)
	output, err := invoke(ctx, client.sdk, members, body)
	var rpcError *sidecarError
	if errors.As(err, &rpcError) {
		return nil, rpcError
	}

	if output == nil {
		output = make(map[string]interface{})
	}
	cleanConformanceOutput(output, observation)
	outcome, code, message := observation.classify(err)
	return map[string]interface{}{
		"op": op, "outcome": outcome, "httpStatus": observation.status,
		"errorCode": emptyToNil(code), "errorMessage": emptyToNil(message),
		"headers": observation.responseHeaders(), "output": output,
		"latencyMs": observation.latencyMs, "attempts": observation.attempts,
		"requestId": emptyToNil(observation.clean(observation.requestID)),
	}, nil
}

func cleanConformanceOutput(value interface{}, observation *conformanceObservation) interface{} {
	switch item := value.(type) {
	case map[string]interface{}:
		for key, member := range item {
			switch key {
			case "ContinuationToken", "NextContinuationToken", "Marker", "NextMarker",
				"KeyMarker", "NextKeyMarker", "VersionIdMarker", "NextVersionIdMarker",
				"PartNumberMarker", "NextPartNumberMarker", "UploadId", "UploadIdMarker", "NextUploadIdMarker":
				// Cursors are opaque, even if they look like query strings. An
				// exact echo of this call's credential still needs redaction.
				if text, ok := member.(string); ok && text != "" && slices.Contains(observation.secrets, text) {
					item[key] = "[redacted]"
				}
				continue
			case "Presign":
				// Constructed locally from the URL's non-query components and query names.
				continue
			case "Location", "WebsiteRedirectLocation", "Message":
				if text, ok := member.(string); ok {
					item[key] = observation.clean(text)
					continue
				}
			}
			item[key] = cleanConformanceOutput(member, observation)
		}
	case []interface{}:
		for i, member := range item {
			item[i] = cleanConformanceOutput(member, observation)
		}
	case string:
		return observation.cleanValues(item)
	}
	return value
}

func (o *conformanceObservation) classify(err error) (outcome, code, message string) {
	o.requestID = o.headers.Get("X-Amz-Request-Id")
	if err == nil {
		return "service", "", ""
	}
	var responseError *awshttp.ResponseError
	if errors.As(err, &responseError) && o.requestID == "" {
		o.requestID = responseError.ServiceRequestID()
	}
	var apiError smithy.APIError
	if o.status > 0 && errors.As(err, &apiError) {
		return "service", o.clean(apiError.ErrorCode()), conformanceTextLimit(o.clean(apiError.ErrorMessage()), 256)
	}
	var paramsError smithy.InvalidParamsError
	var serializationError *smithy.SerializationError
	var sendError *smithyhttp.RequestSendError
	var urlError *url.Error
	var netError net.Error
	switch {
	case errors.As(err, &paramsError) || errors.As(err, &serializationError):
		return "sdk_validation", "", "The SDK rejected the S3 operation input."
	case errors.As(err, &sendError) || errors.As(err, &urlError) || errors.As(err, &netError) ||
		errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.ErrUnexpectedEOF):
		return "transport", "", "The HTTP request or response body transfer failed."
	case o.status >= 300:
		return "service", "", ""
	case o.status > 0:
		return "sdk_decode", "", "The SDK could not decode the S3 response."
	default:
		return "sdk_validation", "", "The SDK could not prepare the S3 operation."
	}
}

func conformanceMilliseconds(started time.Time) float64 {
	return float64(time.Since(started)) / float64(time.Millisecond)
}

func conformancePresignedRequest(ctx context.Context, client *s3.Client, members map[string]interface{}, body []byte) (map[string]interface{}, error) {
	var input struct {
		Method, Bucket, Key, VersionId, ContentType *string
		ExpiresIn, DelayMs                          int
	}
	if err := decodeConformanceInput(members, &input); err != nil {
		return nil, err
	}
	method := aws.ToString(input.Method)
	if (method != http.MethodGet && method != http.MethodPut) ||
		input.ExpiresIn < 1 || input.ExpiresIn > 3600 || input.DelayMs < 0 || input.DelayMs > 5000 ||
		(method == http.MethodGet && input.ContentType != nil) || (method == http.MethodPut && input.VersionId != nil) {
		return nil, invalidConformanceRequest("Invalid S3 conformance presign options.")
	}

	observation := ctx.Value(conformanceObservationKey{}).(*conformanceObservation)
	presigner := s3.NewPresignClient(client)
	options := func(o *s3.PresignOptions) { o.Expires = time.Duration(input.ExpiresIn) * time.Second }
	started := time.Now()
	defer func() { observation.latencyMs = conformanceMilliseconds(started) }()
	var signed *v4.PresignedHTTPRequest
	var err error
	switch method {
	case http.MethodGet:
		signed, err = presigner.PresignGetObject(ctx, &s3.GetObjectInput{
			Bucket: input.Bucket, Key: input.Key, VersionId: input.VersionId,
		}, options)
	case http.MethodPut:
		signed, err = presigner.PresignPutObject(ctx, &s3.PutObjectInput{
			Bucket: input.Bucket, Key: input.Key, ContentType: input.ContentType, Body: bytes.NewReader(body),
		}, options)
	}
	presignMs := conformanceMilliseconds(started)
	if err != nil {
		return nil, err
	}

	var payload io.Reader
	if method == http.MethodPut {
		payload = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, signed.Method, signed.URL, payload)
	if err != nil {
		return nil, err
	}
	req.Header = signed.SignedHeader.Clone()
	if req.Header.Get("User-Agent") == "" {
		req.Header["User-Agent"] = nil // Suppress net/http's default header.
	}
	query := req.URL.Query()
	queryKeys := make([]string, 0, len(query))
	for name := range query {
		queryKeys = append(queryKeys, name)
	}
	slices.Sort(queryKeys)
	time.Sleep(time.Duration(input.DelayMs) * time.Millisecond)
	// latencyMs covers the HTTP request only; PresignMs reports signing.
	started = time.Now()

	result := map[string]interface{}{"Presign": map[string]interface{}{
		"Method": signed.Method, "Scheme": req.URL.Scheme, "Host": req.URL.Host,
		"QueryKeys": queryKeys, "PresignMs": presignMs,
	}}
	resp, err := client.Options().HTTPClient.Do(req)
	if err != nil {
		return result, err
	}
	// Presigned requests use the SDK for signing. Their raw HTTP response
	// can still contain a standard S3 XML error document.
	var sample conformanceErrorSample
	var sampleWriter io.Writer
	if resp.StatusCode >= 300 {
		sampleWriter = &sample
	}
	digest, err := conformanceDigest(resp.Body, resp.ContentLength, sampleWriter)
	if err != nil {
		return result, err
	}
	result["Body"] = digest
	if sample.Len() == 0 {
		return result, nil
	}
	var serviceError struct {
		XMLName       xml.Name `xml:"Error"`
		Code, Message string
	}
	if xml.Unmarshal(sample.Bytes(), &serviceError) == nil && (serviceError.Code != "" || serviceError.Message != "") {
		return result, &smithy.GenericAPIError{Code: serviceError.Code, Message: serviceError.Message}
	}
	return result, nil
}

type conformanceErrorSample struct{ bytes.Buffer }

func (s *conformanceErrorSample) Write(data []byte) (int, error) {
	const limit = 64 << 10
	s.Buffer.Write(data[:min(len(data), limit-s.Len())])
	return len(data), nil
}
