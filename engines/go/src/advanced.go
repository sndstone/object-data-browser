package main

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func redactedURL(u *url.URL) string {
	copy := *u
	copy.RawQuery = ""
	copy.User = nil
	return copy.String()
}
func redactedEndpoint(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return "configured endpoint"
	}
	return redactedURL(u)
}
func loadBenchmarkState(params map[string]interface{}) (map[string]interface{}, error) {
	state, err := readBenchmarkState(asString(params["runId"]))
	if err != nil {
		return nil, err
	}
	if p := asMap(params["profile"]); len(p) > 0 {
		state["profile"] = p
	}
	return state, nil
}

func retryableDelete(code string) bool {
	switch code {
	case "InternalError", "InternalFailure", "ServiceUnavailable", "SlowDown", "RequestTimeout", "RequestTimeoutException", "OperationAborted", "503", "500":
		return true
	}
	return false
}
func missingObject(err error) bool {
	code := awsErrorCode(err)
	return code == "NoSuchKey" || code == "NotFound" || code == "404" || code == "NoSuchVersion"
}
func retryPause(ctx context.Context, attempt int) error {
	timer := time.NewTimer(time.Duration(100*(1<<attempt)) * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// Recovery never infers versioning state from a failed version listing. A bucket
// with any history of versioning is excluded from the destructive empty-PUT path.
func deleteAllAdvanced(params map[string]interface{}) map[string]interface{} {
	const label = "delete-all"
	config := asMap(params["config"])
	bucket := strings.TrimSpace(asString(config["bucketName"]))
	if bucket == "" {
		return toolFailure(label, fmt.Errorf("bucket name is required"))
	}
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return toolFailure(label, err)
	}
	client, ctx, err := buildClient(p)
	if err != nil {
		return toolFailure(label, err)
	}
	versioning, err := client.GetBucketVersioning(ctx, &s3.GetBucketVersioningInput{Bucket: aws.String(bucket)})
	if err != nil {
		return toolFailure(label, fmt.Errorf("cannot establish bucket versioning; no objects were changed: %w", err))
	}
	status := string(versioning.Status)
	if status != "" && status != "Enabled" && status != "Suspended" {
		return toolFailure(label, fmt.Errorf("unknown bucket versioning state; no objects were changed"))
	}
	neverVersioned := status == ""
	endpoint, _ := url.Parse(p.EndpointURL)
	awsHost := endpoint != nil && (strings.HasSuffix(strings.ToLower(endpoint.Hostname()), ".amazonaws.com") || strings.HasSuffix(strings.ToLower(endpoint.Hostname()), ".amazonaws.com.cn"))
	recoverStale := p.EndpointType == "s3Compatible" && neverVersioned && !awsHost
	pageSize := maxInt(asInt(config["listMaxKeys"]), 1, 1000)
	if pageSize > 1000 {
		pageSize = 1000
	}
	batchSize := maxInt(asInt(config["batchSize"]), 1, 1000)
	if batchSize > 1000 {
		batchSize = 1000
	}
	outcomes := []map[string]interface{}{}
	deleted, failed, listed := 0, 0, 0
	lines := []string{fmt.Sprintf("Bucket: %s", bucket), fmt.Sprintf("Versioning: %s", nonEmpty(status, "never-enabled"))}
	workers := maxInt(asInt(config["maxWorkers"]), 1, 4)
	if workers > 16 {
		workers = 16
	}
	semaphore := make(chan struct{}, workers)
	var pendingBatches sync.WaitGroup
	var resultMu sync.Mutex
	process := func(items []types.ObjectIdentifier) {
		for offset := 0; offset < len(items); offset += batchSize {
			end := offset + batchSize
			if end > len(items) {
				end = len(items)
			}
			semaphore <- struct{}{}
			pendingBatches.Add(1)
			go func(batch []types.ObjectIdentifier) {
				defer pendingBatches.Done()
				defer func() { <-semaphore }()
				results := deleteBatchWithRecovery(ctx, client, bucket, batch, recoverStale)
				resultMu.Lock()
				defer resultMu.Unlock()
				for _, result := range results {
					listed++
					if asBool(result["deleted"]) {
						deleted++
					} else {
						failed++
					}
					if len(outcomes) < 1000 {
						outcomes = append(outcomes, result)
					}
					if asBool(result["overwrittenWithEmptyObject"]) {
						lines = append(lines, fmt.Sprintf("%q: %s", asString(result["key"]), asString(result["message"])))
					}
				}
			}(append([]types.ObjectIdentifier{}, items[offset:end]...))
			if delay := asInt(config["deletionDelayMs"]); delay > 0 {
				time.Sleep(time.Duration(delay) * time.Millisecond)
			}
		}
	}
	var token, keyMarker, versionMarker *string
	for {
		items := []types.ObjectIdentifier{}
		truncated := false
		if neverVersioned {
			out, listErr := client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: aws.String(bucket), MaxKeys: aws.Int32(int32(pageSize)), ContinuationToken: token})
			if listErr != nil {
				err = listErr
				break
			}
			for _, o := range out.Contents {
				items = append(items, types.ObjectIdentifier{Key: o.Key})
			}
			truncated = aws.ToBool(out.IsTruncated)
			if truncated && (aws.ToString(out.NextContinuationToken) == "" || aws.ToString(out.NextContinuationToken) == aws.ToString(token)) {
				err = fmt.Errorf("object listing cursor did not advance")
				break
			}
			token = out.NextContinuationToken
		} else {
			out, listErr := client.ListObjectVersions(ctx, &s3.ListObjectVersionsInput{Bucket: aws.String(bucket), MaxKeys: aws.Int32(int32(pageSize)), KeyMarker: keyMarker, VersionIdMarker: versionMarker})
			if listErr != nil {
				err = listErr
				break
			}
			for _, v := range out.Versions {
				items = append(items, types.ObjectIdentifier{Key: v.Key, VersionId: v.VersionId})
			}
			for _, v := range out.DeleteMarkers {
				items = append(items, types.ObjectIdentifier{Key: v.Key, VersionId: v.VersionId})
			}
			truncated = aws.ToBool(out.IsTruncated)
			if truncated && ((aws.ToString(out.NextKeyMarker) == "" && aws.ToString(out.NextVersionIdMarker) == "") || (aws.ToString(out.NextKeyMarker) == aws.ToString(keyMarker) && aws.ToString(out.NextVersionIdMarker) == aws.ToString(versionMarker))) {
				err = fmt.Errorf("version listing cursor did not advance")
				break
			}
			keyMarker = out.NextKeyMarker
			versionMarker = out.NextVersionIdMarker
		}
		process(items)
		if !truncated {
			break
		}
	}
	pendingBatches.Wait()
	if err != nil {
		failed++
		lines = append(lines, "Listing failed: "+err.Error())
	}
	lines = append(lines, fmt.Sprintf("Listed: %d; deleted: %d; failures: %d", listed, deleted, failed))
	exitCode := 0
	if failed > 0 {
		exitCode = 1
	}
	result := toolState(label, fmt.Sprintf("Deleted %d object/version(s) from %s; %d failure(s).", deleted, bucket, failed), lines, exitCode)
	result["successCount"] = deleted
	result["failureCount"] = failed
	result["listedCount"] = listed
	result["outcomes"] = outcomes
	result["outcomesTruncated"] = listed > len(outcomes)
	result["versioningStatus"] = nonEmpty(status, "Disabled")
	return result
}

func deleteBatchWithRecovery(ctx context.Context, client *s3.Client, bucket string, items []types.ObjectIdentifier, recoverStale bool) []map[string]interface{} {
	pending := append([]types.ObjectIdentifier{}, items...)
	results := []map[string]interface{}{}
	codes := map[string]string{}
	identity := func(item types.ObjectIdentifier) string {
		return aws.ToString(item.Key) + "\x00" + aws.ToString(item.VersionId)
	}
	for attempt := 0; attempt < 3 && len(pending) > 0; attempt++ {
		out, err := client.DeleteObjects(ctx, &s3.DeleteObjectsInput{Bucket: aws.String(bucket), Delete: &types.Delete{Objects: pending, Quiet: aws.Bool(false)}})
		if err != nil {
			code := awsErrorCode(err)
			for _, item := range pending {
				codes[identity(item)] = code
			}
			if !retryableDelete(code) {
				break
			}
		} else {
			errorCodes := map[string]string{}
			confirmed := map[string]bool{}
			for _, e := range out.Errors {
				errorCodes[aws.ToString(e.Key)+"\x00"+aws.ToString(e.VersionId)] = aws.ToString(e.Code)
			}
			for _, d := range out.Deleted {
				confirmed[aws.ToString(d.Key)+"\x00"+aws.ToString(d.VersionId)] = true
			}
			next := []types.ObjectIdentifier{}
			for _, item := range pending {
				id := identity(item)
				code := errorCodes[id]
				if (code == "" && confirmed[id]) || code == "NoSuchKey" || code == "NoSuchVersion" {
					if !recoverStale {
						results = append(results, deleteOutcome(item, true, "batch-delete", "", false))
						continue
					}
					_, headErr := client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: item.Key})
					if missingObject(headErr) {
						results = append(results, deleteOutcome(item, true, "batch-delete", "", false))
						continue
					}
					if headErr != nil {
						code = awsErrorCode(headErr)
						if code == "" {
							code = "Unknown"
						}
					} else {
						code = "StillPresent"
					}
				} else if code == "" {
					code = "UnknownOutcome"
				}
				codes[id] = code
				next = append(next, item)
			}
			pending = next
		}
		if attempt < 2 && len(pending) > 0 {
			if retryPause(ctx, attempt) != nil {
				break
			}
		}
	}
	for _, item := range pending {
		code := codes[identity(item)]
		// Only explicit transient failures or a confirmed remaining object qualify.
		// Permission, retention, transport ambiguity and unknown service codes fail closed.
		eligible := retryableDelete(code) || code == "StillPresent"
		if !eligible {
			results = append(results, deleteOutcome(item, false, "batch-delete", nonEmpty(code, "UnknownOutcome"), false))
			continue
		}
		deleted := false
		var lastErr error
		for attempt := 0; attempt < 3; attempt++ {
			_, lastErr = client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: item.Key, VersionId: item.VersionId})
			if lastErr == nil || missingObject(lastErr) {
				if !recoverStale {
					deleted = true
					break
				}
				_, headErr := client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: item.Key})
				if missingObject(headErr) {
					deleted = true
					break
				}
				lastErr = headErr
				if headErr != nil {
					break
				}
			} else if !retryableDelete(awsErrorCode(lastErr)) {
				break
			}
			if attempt < 2 {
				if err := retryPause(ctx, attempt); err != nil {
					lastErr = err
					break
				}
			}
		}
		if deleted {
			results = append(results, deleteOutcome(item, true, "individual-delete", "", false))
			continue
		}
		if !recoverStale || item.VersionId != nil || ctx.Err() != nil || (lastErr != nil && !retryableDelete(awsErrorCode(lastErr))) {
			results = append(results, deleteOutcome(item, false, "individual-delete", fmt.Sprintf("delete failed: %v", lastErr), false))
			continue
		}
		head, headErr := client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: item.Key})
		if missingObject(headErr) {
			results = append(results, deleteOutcome(item, true, "individual-delete", "", false))
			continue
		}
		if headErr != nil || head.ETag == nil || head.ObjectLockMode != "" || head.ObjectLockLegalHoldStatus == types.ObjectLockLegalHoldStatusOn {
			results = append(results, deleteOutcome(item, false, "individual-delete", "cannot safely replace remaining object", false))
			continue
		}
		// Recheck immediately before overwrite, to catch versioning changes during a long job.
		versioning, versionErr := client.GetBucketVersioning(ctx, &s3.GetBucketVersioningInput{Bucket: aws.String(bucket)})
		if versionErr != nil || versioning.Status != "" {
			results = append(results, deleteOutcome(item, false, "individual-delete", "versioning could not be reconfirmed as never enabled", false))
			continue
		}
		put, putErr := client.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(bucket), Key: item.Key, Body: bytes.NewReader(nil), ContentLength: aws.Int64(0), IfMatch: head.ETag})
		if putErr != nil {
			results = append(results, deleteOutcome(item, false, "empty-put", putErr.Error(), false))
			continue
		}
		if put.ETag == nil {
			results = append(results, deleteOutcome(item, false, "empty-put-delete", "overwritten with an empty object; delete failed: missing replacement validator", true))
			continue
		}
		_, finalErr := client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: item.Key, IfMatch: put.ETag})
		if finalErr == nil {
			_, finalErr = client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: item.Key})
			if finalErr == nil {
				finalErr = fmt.Errorf("object remains after final delete")
			} else if missingObject(finalErr) {
				finalErr = nil
			}
		}
		message := "stale metadata recovered"
		if finalErr != nil {
			message = "overwritten with an empty object; delete failed"
		}
		results = append(results, deleteOutcome(item, finalErr == nil, "empty-put-delete", message, true))
	}
	return results
}
func deleteOutcome(item types.ObjectIdentifier, deleted bool, stage, message string, empty bool) map[string]interface{} {
	return map[string]interface{}{"key": aws.ToString(item.Key), "versionId": emptyToNil(aws.ToString(item.VersionId)), "deleted": deleted, "stage": stage, "message": message, "overwrittenWithEmptyObject": empty}
}

func copyObjectAdvanced(params map[string]interface{}) (map[string]interface{}, error) {
	p, err := parseProfile(asMap(params["profile"]))
	if err != nil {
		return nil, err
	}
	sourceBucket := asString(params["sourceBucketName"])
	sourceKey := asString(params["sourceKey"])
	destinationBucket := asString(params["destinationBucketName"])
	destinationKey := asString(params["destinationKey"])
	if sourceBucket == "" || sourceKey == "" || destinationBucket == "" || destinationKey == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Copy source and destination are required."}
	}
	if sourceBucket == destinationBucket && sourceKey == destinationKey {
		return nil, &sidecarError{Code: "invalid_config", Message: "Source and destination must differ."}
	}
	client, ctx, err := buildClient(p)
	if err != nil {
		return nil, err
	}
	head, err := client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(sourceBucket), Key: aws.String(sourceKey), VersionId: stringPtr(asString(params["sourceVersionId"]))})
	if err != nil {
		return nil, err
	}
	if head.ETag == nil {
		return nil, &sidecarError{Code: "unsupported_feature", Message: "Source has no validator; a consistent copy cannot be guaranteed."}
	}
	version := nonEmpty(asString(params["sourceVersionId"]), aws.ToString(head.VersionId))
	source := url.PathEscape(sourceBucket + "/" + sourceKey)
	if version != "" {
		source += "?versionId=" + url.QueryEscape(version)
	}
	size := aws.ToInt64(head.ContentLength)
	strategy := "server-side copy"
	var destinationVersion *string
	if size <= 5*1024*1024*1024 {
		out, copyErr := client.CopyObject(ctx, &s3.CopyObjectInput{Bucket: aws.String(destinationBucket), Key: aws.String(destinationKey), CopySource: aws.String(source), CopySourceIfMatch: head.ETag})
		if copyErr != nil {
			return nil, copyErr
		}
		destinationVersion = out.VersionId
	} else {
		strategy = "multipart server-side copy"
		partBytes := int64(128 * 1024 * 1024)
		if minimum := (size + 9999) / 10000; minimum > partBytes {
			partBytes = minimum
		}
		if partBytes > 5*1024*1024*1024 {
			return nil, &sidecarError{Code: "invalid_config", Message: "Object exceeds multipart copy limits."}
		}
		tags, tagErr := client.GetObjectTagging(ctx, &s3.GetObjectTaggingInput{Bucket: aws.String(sourceBucket), Key: aws.String(sourceKey), VersionId: stringPtr(version)})
		if tagErr != nil {
			return nil, tagErr
		}
		values := url.Values{}
		for _, tag := range tags.TagSet {
			values.Set(aws.ToString(tag.Key), aws.ToString(tag.Value))
		}
		created, createErr := client.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{Bucket: aws.String(destinationBucket), Key: aws.String(destinationKey), Metadata: head.Metadata, ContentType: head.ContentType, ContentEncoding: head.ContentEncoding, ContentLanguage: head.ContentLanguage, ContentDisposition: head.ContentDisposition, CacheControl: head.CacheControl, Expires: head.Expires, StorageClass: head.StorageClass, Tagging: stringPtr(values.Encode())})
		if createErr != nil {
			return nil, createErr
		}
		committed := false
		defer func() {
			if !committed {
				_, _ = client.AbortMultipartUpload(ctx, &s3.AbortMultipartUploadInput{Bucket: aws.String(destinationBucket), Key: aws.String(destinationKey), UploadId: created.UploadId})
			}
		}()
		count := int((size + partBytes - 1) / partBytes)
		parts := make([]types.CompletedPart, count)
		partErr := parallelParts(ctx, count, transferConcurrency(p), func(workerCtx context.Context, index int) error {
			offset := int64(index) * partBytes
			end := minInt64(offset+partBytes, size) - 1
			number := int32(index + 1)
			part, err := client.UploadPartCopy(workerCtx, &s3.UploadPartCopyInput{Bucket: aws.String(destinationBucket), Key: aws.String(destinationKey), UploadId: created.UploadId, PartNumber: aws.Int32(number), CopySource: aws.String(source), CopySourceIfMatch: head.ETag, CopySourceRange: aws.String(fmt.Sprintf("bytes=%d-%d", offset, end))})
			if err != nil {
				return err
			}
			if part.CopyPartResult == nil || part.CopyPartResult.ETag == nil {
				return fmt.Errorf("copy part returned no ETag")
			}
			parts[index] = types.CompletedPart{PartNumber: aws.Int32(number), ETag: part.CopyPartResult.ETag}
			return nil
		})
		if partErr != nil {
			return nil, partErr
		}

		completed, completeErr := client.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{Bucket: aws.String(destinationBucket), Key: aws.String(destinationKey), UploadId: created.UploadId, MultipartUpload: &types.CompletedMultipartUpload{Parts: parts}})
		if completeErr != nil {
			return nil, completeErr
		}
		committed = true
		destinationVersion = completed.VersionId
	}
	return map[string]interface{}{"successCount": 1, "failureCount": 0, "failures": []interface{}{}, "bytesCopied": size, "versionId": emptyToNil(aws.ToString(destinationVersion)), "sourceETag": aws.ToString(head.ETag), "strategy": strategy}, nil
}

// Azure block counts are provider-specific; the last block may be short.
func azureBlockSizing(size, requested int64) (int64, error) {
	const mib = int64(1024 * 1024)
	const maximum = 4000 * mib
	if size < 0 || size > 50000*maximum {
		return 0, &sidecarError{Code: "invalid_config", Message: "Blob exceeds Azure's 50,000-block limit."}
	}
	block := requested
	if block < 1*mib {
		block = 16 * mib
	}
	if block > 128*mib {
		block = 128 * mib
	}
	minimum := (size + 49999) / 50000
	if minimum > block {
		block = ((minimum + mib - 1) / mib) * mib
	}
	if block > maximum {
		return 0, &sidecarError{Code: "invalid_config", Message: "Azure block exceeds the 4,000 MiB service limit."}
	}
	return block, nil
}
func parallelParts(ctx context.Context, count, workers int, work func(context.Context, int) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	var mu sync.Mutex
	var firstErr error
	jobs := make(chan int)
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for index := range jobs {
				if ctx.Err() != nil {
					continue
				}
				if err := work(ctx, index); err != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					mu.Unlock()
					cancel()
				}
			}
		}()
	}
send:
	for index := 0; index < count; index++ {
		select {
		case jobs <- index:
		case <-ctx.Done():
			break send
		}
	}
	close(jobs)
	wg.Wait()
	if firstErr != nil {
		return firstErr
	}
	return ctx.Err()
}

type offsetFileWriter struct {
	file   *os.File
	offset int64
}

func (w *offsetFileWriter) Write(p []byte) (int, error) {
	n, err := w.file.WriteAt(p, w.offset)
	w.offset += int64(n)
	return n, err
}
