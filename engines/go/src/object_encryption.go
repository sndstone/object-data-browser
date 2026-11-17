package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"reflect"
	"strings"

	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go/middleware"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

// Secrets stay in request-local headers/context, never in a cached client or job.
func encryptionSecretField(name string) bool {
	switch strings.ToLower(name) {
	case "filename", "filekey", "customerkey", "x-amz-server-side-encryption-customer-key", "x-amz-copy-source-server-side-encryption-customer-key", "x-ms-encryption-key":
		return true
	}
	return false
}
func redactEncryptionFields(value interface{}) interface{} {
	switch v := value.(type) {
	case map[string]interface{}:
		out := make(map[string]interface{}, len(v))
		for k, item := range v {
			if encryptionSecretField(k) {
				out[k] = "[redacted]"
			} else {
				out[k] = redactEncryptionFields(item)
			}
		}
		return out
	case map[string]string:
		out := make(map[string]string, len(v))
		for k, item := range v {
			if encryptionSecretField(k) {
				out[k] = "[redacted]"
			} else {
				out[k] = item
			}
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(v))
		for i, item := range v {
			out[i] = redactEncryptionFields(item)
		}
		return out
	}
	kind := reflect.Invalid
	if value != nil {
		kind = reflect.TypeOf(value).Kind()
	}
	if kind == reflect.Struct || kind == reflect.Map || kind == reflect.Slice || kind == reflect.Array || kind == reflect.Pointer {
		data, err := json.Marshal(value)
		var decoded interface{}
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		if err == nil && decoder.Decode(&decoded) == nil {
			return redactEncryptionFields(decoded)
		}
	}
	return value
}

type objectEncryption struct {
	mode    string
	headers http.Header
}
type requestEncryption struct {
	destination, source objectEncryption
	secrets             []string
}

func invalidEncryption() error {
	return &sidecarError{Code: "invalid_config", Message: "Invalid object encryption configuration for this mode, provider or endpoint."}
}

// Validate both optional objects once, before performing any provider operation.
func parseRequestEncryption(params map[string]interface{}, p profile, copySource bool) (requestEncryption, error) {
	var result requestEncryption
	var err error
	result.destination, err = parseObjectEncryption(params["encryption"], p)
	if err != nil {
		return result, err
	}
	result.source, err = parseObjectEncryption(params["sourceEncryption"], p)
	if err != nil {
		return result, err
	}
	if result.source.mode != "" && (!copySource || !result.source.customer()) {
		return result, invalidEncryption()
	}
	return result, nil
}
func parseObjectEncryption(raw interface{}, p profile) (objectEncryption, error) {
	result := objectEncryption{headers: make(http.Header)}
	if raw == nil {
		return result, nil
	}
	value, ok := raw.(map[string]interface{})
	if !ok {
		return result, invalidEncryption()
	}
	mode, ok := value["mode"].(string)
	if !ok {
		return result, invalidEncryption()
	}
	allowed := map[string]bool{"mode": true}
	switch mode {
	case "bucketDefault", "sse-s3":
	case "sse-kms", "dsse-kms":
		allowed["kmsKeyId"] = true
		allowed["kmsEncryptionContext"] = true
		if mode == "sse-kms" {
			allowed["bucketKeyEnabled"] = true
		}
	case "sse-c", "azure-cpk":
		allowed["customerKey"] = true
	case "azure-scope":
		allowed["encryptionScope"] = true
	default:
		return result, invalidEncryption()
	}
	for name := range value {
		if !allowed[name] {
			return result, invalidEncryption()
		}
	}
	if mode == "bucketDefault" {
		return result, nil
	}
	if strings.HasPrefix(mode, "azure-") != isAzureProfile(p) {
		return result, invalidEncryption()
	}
	result.mode = mode
	switch mode {
	case "sse-s3":
		result.headers.Set("x-amz-server-side-encryption", "AES256")
	case "sse-kms", "dsse-kms":
		algorithm := "aws:kms"
		if mode == "dsse-kms" {
			algorithm = "aws:kms:dsse"
		}
		result.headers.Set("x-amz-server-side-encryption", algorithm)
		if raw, exists := value["kmsKeyId"]; exists {
			v, ok := raw.(string)
			if !ok || strings.ContainsAny(v, "\r\n") {
				return result, invalidEncryption()
			}
			result.headers.Set("x-amz-server-side-encryption-aws-kms-key-id", v)
		}
		if raw, exists := value["bucketKeyEnabled"]; exists {
			v, ok := raw.(bool)
			if !ok {
				return result, invalidEncryption()
			}
			flag := "false"
			if v {
				flag = "true"
			}
			result.headers.Set("x-amz-server-side-encryption-bucket-key-enabled", flag)
		}
		if raw, exists := value["kmsEncryptionContext"]; exists {
			context := map[string]string{}
			switch v := raw.(type) {
			case map[string]interface{}:
				for k, item := range v {
					text, ok := item.(string)
					if !ok {
						return result, invalidEncryption()
					}
					context[k] = text
				}
			case map[string]string:
				context = v
			default:
				return result, invalidEncryption()
			}
			encoded, _ := json.Marshal(context)
			result.headers.Set("x-amz-server-side-encryption-context", base64.StdEncoding.EncodeToString(encoded))
		}
	case "sse-c", "azure-cpk":
		u, err := url.Parse(p.EndpointURL)
		if p.EndpointURL != "" && (err != nil || u.Host == "" || (u.Scheme != "https" && !(u.Scheme == "http" && loopbackEncryptionHost(u.Hostname())))) {
			return result, invalidEncryption()
		}
		key, ok := value["customerKey"].(string)
		if !ok {
			return result, invalidEncryption()
		}
		decoded, err := base64.StdEncoding.Strict().DecodeString(key)
		if err != nil || len(decoded) != 32 {
			return result, invalidEncryption()
		}
		// Use canonical base64, preventing newline-bearing header values.
		key = base64.StdEncoding.EncodeToString(decoded)
		if mode == "sse-c" {
			hash := md5.Sum(decoded)
			result.headers.Set("x-amz-server-side-encryption-customer-algorithm", "AES256")
			result.headers.Set("x-amz-server-side-encryption-customer-key", key)
			result.headers.Set("x-amz-server-side-encryption-customer-key-MD5", base64.StdEncoding.EncodeToString(hash[:]))
		} else {
			hash := sha256.Sum256(decoded)
			result.headers.Set("x-ms-encryption-key", key)
			result.headers.Set("x-ms-encryption-key-sha256", base64.StdEncoding.EncodeToString(hash[:]))
			result.headers.Set("x-ms-encryption-algorithm", "AES256")
		}
	case "azure-scope":
		scope, ok := value["encryptionScope"].(string)
		if !ok || strings.TrimSpace(scope) == "" || strings.ContainsAny(scope, "\r\n") {
			return result, invalidEncryption()
		}
		result.headers.Set("x-ms-encryption-scope", scope)
	}
	return result, nil
}
func loopbackEncryptionHost(host string) bool {
	ip := net.ParseIP(host)
	return strings.EqualFold(host, "localhost") || (ip != nil && ip.IsLoopback())
}
func (e objectEncryption) customer() bool { return e.mode == "sse-c" || e.mode == "azure-cpk" }
func setEncryptionHeaders(target, source http.Header) {
	for name, values := range source {
		target[name] = append([]string(nil), values...)
	}
}

type encryptionContextKey struct{}

func encryptionSecrets(headers http.Header) []string {
	var secrets []string
	for name, values := range headers {
		if encryptionSecretField(name) && !strings.EqualFold(name, "filename") {
			secrets = append(secrets, values...)
		}
	}
	return secrets
}
func redactEncryptionText(text string, secrets []string) string {
	for _, key := range secrets {
		if key != "" {
			text = strings.ReplaceAll(text, key, "[redacted]")
		}
	}
	return text
}

func redactEncryptionValues(value interface{}, secrets []string) interface{} {
	switch v := value.(type) {
	case string:
		return redactEncryptionText(v, secrets)
	case map[string]interface{}:
		for name, item := range v {
			v[name] = redactEncryptionValues(item, secrets)
		}
	case []interface{}:
		for i, item := range v {
			v[i] = redactEncryptionValues(item, secrets)
		}
	}
	return value
}

type encryptionFailure struct {
	cause   error
	secrets []string
	hint    string
}

func (e *encryptionFailure) Error() string { return redactEncryptionText(e.cause.Error(), e.secrets) }
func (e *encryptionFailure) Unwrap() error { return e.cause }
func encryptionProviderError(err error, headers http.Header, method string, status int, additionalSecrets ...string) error {
	if err == nil {
		return nil
	}
	hint := encryptionHint(err.Error(), method, status, headers)
	return &encryptionFailure{cause: err, secrets: append(encryptionSecrets(headers), additionalSecrets...), hint: hint}
}
func encryptionHint(message, method string, status int, headers http.Header) string {
	lower := strings.ToLower(message)
	switch {
	case (strings.Contains(lower, "kms.") || strings.Contains(lower, "kms:")) && (strings.Contains(lower, "disabled") || strings.Contains(lower, "notfound") || strings.Contains(lower, "unavailable") || strings.Contains(lower, "invalidstate")):
		return "kms_key_unavailable"
	case (strings.Contains(lower, "kms.") || strings.Contains(lower, "kms:")) && (strings.Contains(lower, "access") || strings.Contains(lower, "denied") || strings.Contains(lower, "not authorized")):
		return "kms_access_denied"
	case (strings.Contains(lower, "sse-c") || strings.Contains(lower, "sse_c") || strings.Contains(lower, "customer")) && (strings.Contains(lower, "blocked") || strings.Contains(lower, "disabled") || strings.Contains(lower, "not allowed")):
		return "sse_c_blocked"
	case (strings.Contains(lower, "customer") || strings.Contains(lower, "sse-c")) && (strings.Contains(lower, "mismatch") || strings.Contains(lower, "does not match")):
		return "sse_c_key_mismatch"
	case (method == "HEAD" || method == "GET") && status == 400 && headers.Get("x-ms-version") == "" && headers.Get("x-amz-server-side-encryption-customer-key") == "":
		return "sse_c_key_required"
	case strings.Contains(lower, "encryption") && (strings.Contains(lower, "required by") || strings.Contains(lower, "must specify")):
		return "encryption_required_by_policy"
	case strings.Contains(lower, "encryption") && (strings.Contains(lower, "not implemented") || strings.Contains(lower, "not supported")):
		return "unsupported_by_endpoint"
	}
	return ""
}

func encryptedS3Client(params map[string]interface{}, p profile, client *s3.Client, copying bool) (*s3.Client, error) {
	config, err := parseRequestEncryption(params, p, copying)
	if err != nil {
		return nil, err
	}
	config.secrets = clientEncryptionSecrets(params)
	return s3ClientWithEncryption(client, config, copying), nil
}

func s3ClientWithEncryption(client *s3.Client, config requestEncryption, copying bool) *s3.Client {
	secrets := append(encryptionSecrets(config.destination.headers), encryptionSecrets(config.source.headers)...)
	secrets = append(secrets, config.secrets...)
	options := client.Options()
	options.APIOptions = append(options.APIOptions, func(stack *middleware.Stack) error {
		return stack.Build.Add(middleware.BuildMiddlewareFunc("ObjectBrowserEncryption", func(ctx context.Context, in middleware.BuildInput, next middleware.BuildHandler) (middleware.BuildOutput, middleware.Metadata, error) {
			request := in.Request.(*smithyhttp.Request)
			op := middleware.GetOperationName(ctx)
			switch op {
			case "PutObject", "CreateMultipartUpload", "CopyObject":
				setEncryptionHeaders(request.Header, config.destination.headers)
			case "UploadPart", "UploadPartCopy", "CompleteMultipartUpload":
				if config.destination.customer() {
					setEncryptionHeaders(request.Header, config.destination.headers)
				}
			case "HeadObject", "GetObject":
				read := config.destination
				if copying {
					read = config.source
				}
				if read.customer() {
					setEncryptionHeaders(request.Header, read.headers)
				}
			}
			if op == "CopyObject" || op == "UploadPartCopy" {
				for name, values := range config.source.headers {
					request.Header[strings.Replace(name, "X-Amz-", "X-Amz-Copy-Source-", 1)] = append([]string(nil), values...)
				}
			}
			ctx = context.WithValue(ctx, encryptionContextKey{}, secrets)
			out, metadata, err := next.HandleBuild(ctx, in)
			if err != nil {
				status := 0
				var response *smithyhttp.ResponseError
				if errors.As(err, &response) {
					status = response.HTTPStatusCode()
				}
				err = encryptionProviderError(err, request.Header, request.Method, status, secrets...)
			}
			return out, metadata, err
		}), middleware.After)
	})
	return s3.New(options)
}

func encryptionCapabilities(items []map[string]interface{}) []map[string]interface{} {
	for _, mode := range []string{"sse-s3", "sse-kms", "dsse-kms", "sse-c", "azure-scope", "azure-cpk"} {
		key := "object.encryption." + mode
		items = append(items, map[string]interface{}{"key": key, "label": key, "state": "supported", "implementationState": "supported"})
	}
	return append(items, map[string]interface{}{"key": "object.clientEncryption", "label": "object.clientEncryption", "state": "supported", "implementationState": "supported", "formats": []string{"age-v1"}})
}
func s3ObjectEncryption(head *s3.HeadObjectOutput) map[string]interface{} {
	mode := map[string]string{"AES256": "sse-s3", "aws:kms": "sse-kms", "aws:kms:dsse": "dsse-kms"}[string(head.ServerSideEncryption)]
	if string(head.ServerSideEncryption) != "" && mode == "" {
		mode = "provider"
	}
	if head.SSECustomerAlgorithm != nil && *head.SSECustomerAlgorithm != "" {
		mode = "sse-c"
	}
	if mode == "" {
		return nil
	}
	result := map[string]interface{}{"mode": mode}
	if head.SSEKMSKeyId != nil {
		result["kmsKeyId"] = *head.SSEKMSKeyId
	}
	if head.BucketKeyEnabled != nil {
		result["bucketKeyEnabled"] = *head.BucketKeyEnabled
	}
	if head.SSECustomerKeyMD5 != nil {
		result["customerKeyMd5"] = *head.SSECustomerKeyMD5
	}
	return result
}
func azureObjectEncryption(headers http.Header) map[string]interface{} {
	result := map[string]interface{}{}
	if flag := headers.Get("x-ms-server-encrypted"); flag != "" {
		result["mode"] = "provider"
		result["serverEncrypted"] = strings.EqualFold(flag, "true")
	}
	if scope := headers.Get("x-ms-encryption-scope"); scope != "" {
		result["mode"] = "azure-scope"
		result["encryptionScope"] = scope
	}
	if hash := headers.Get("x-ms-encryption-key-sha256"); hash != "" {
		result["mode"] = "azure-cpk"
		result["customerKeySha256"] = hash
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

type azureEncryptionContextKey struct{}

func encryptedAzureContext(params map[string]interface{}, p profile, ctx context.Context, copying bool) (context.Context, error) {
	config, err := parseRequestEncryption(params, p, copying)
	if err != nil {
		return ctx, err
	}
	if copying && config.source.customer() {
		return ctx, &sidecarError{Code: "unsupported_feature", Message: "Azure customer-key copy sources require a relay path, which this engine does not implement."}
	}
	ctx = context.WithValue(ctx, encryptionContextKey{}, clientEncryptionSecrets(params))
	return context.WithValue(ctx, azureEncryptionContextKey{}, config.destination), nil
}
