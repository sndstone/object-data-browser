package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const gcsChunkAlignment = int64(256 * 1024)

func gcsChunkSize(requested int64) (int64, error) {
	if requested <= 0 {
		requested = 8 * 1024 * 1024
	}
	if requested > 5*1024*1024*1024 {
		return 0, &sidecarError{Code: "invalid_config", Message: "Cloud Storage upload chunks must not exceed 5 GiB."}
	}
	return ((requested + gcsChunkAlignment - 1) / gcsChunkAlignment) * gcsChunkAlignment, nil
}

// The shared gate and job shape apply to both directions. Progress counts only
// acknowledged upload bytes or completely validated download ranges.
type gcsTransferProgress struct {
	mu                      sync.Mutex
	id, label, direction    string
	current                 string
	total, completed, chunk int64
	items, done, parts      int
	gate                    *transferProgressGate
	params                  map[string]interface{}
}

func newGCSTransferProgress(params map[string]interface{}, direction, bucket string, items int, total, chunk int64) *gcsTransferProgress {
	return &gcsTransferProgress{id: fmt.Sprintf("%s-%d", direction, time.Now().UnixNano()), label: fmt.Sprintf("%s %d item(s): %s", direction, items, bucket), direction: direction, total: total, chunk: chunk, items: items, gate: newTransferProgressGate(params), params: params}
}

func (p *gcsTransferProgress) job(status string) map[string]interface{} {
	return buildTransferJob(p.id, p.label, p.direction, progressFraction(p.completed, p.total), status, p.completed, p.total, "Cloud Storage", p.current, p.items, p.done, p.chunk, p.parts, nil, false, false, false, []string{})
}

func (p *gcsTransferProgress) emit(status string, force bool) {
	if !p.gate.ready(force) {
		return
	}
	job := p.job(status)
	job = redactEncryptionValues(redactEncryptionFields(job), clientEncryptionSecrets(p.params)).(map[string]interface{})
	emitTransferEvent(job)
}

func (c *gcsClient) startUpload(ctx context.Context, p profile, bucket string, params map[string]interface{}) (map[string]interface{}, error) {
	ce, err := parseClientEncryption(params, true)
	if err != nil {
		return nil, err
	}
	paths := asStringSlice(params["filePaths"])
	if len(paths) == 0 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Upload file paths are required."}
	}
	threshold := int64(maxInt(asInt(params["multipartThresholdMiB"]), 1, 32)) * 1024 * 1024
	chunk, err := gcsChunkSize(int64(asInt(params["multipartChunkMiB"])) * 1024 * 1024)
	if err != nil {
		return nil, err
	}
	sources := map[string]os.FileInfo{}
	sizes := map[string]int64{}
	var total int64
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, &sidecarError{Code: "invalid_config", Message: "Upload source must be a regular file."}
		}
		size := info.Size()
		if ce != nil {
			size, err = ageObjectLength(ce.headerLength, size)
			if err != nil {
				return nil, err
			}
		}
		if size > 5*1024*1024*1024*1024 {
			return nil, &sidecarError{Code: "invalid_config", Message: "Cloud Storage objects must not exceed 5 TiB."}
		}
		sources[path], sizes[path] = info, size
		total += size
	}
	progress := newGCSTransferProgress(params, "upload", bucket, len(paths), total, chunk)
	progress.emit("queued", true)
	keys := asStringMap(params["objectKeyByPath"])
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return nil, gcsTransportError(err)
		}
		err = func() error {
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			defer file.Close()
			verify := func() error { return verifyUploadSource(file, path, sources[path]) }
			if err = verify(); err != nil {
				return err
			}
			var source io.ReaderAt = file
			if ce != nil {
				source, err = newAgeUploadReader(file, verify, ce, sources[path].Size())
				if err != nil {
					return err
				}
			}
			key := keys[path]
			if strings.TrimSpace(key) == "" {
				key = filepath.Base(path)
			}
			key = asString(params["prefix"]) + key
			progress.current = filepath.Base(path)
			size := sizes[path]
			if size < threshold {
				resp, err := c.do(ctx, http.MethodPost, c.urlFor("upload", "storage", "v1", "b", bucket, "o"), url.Values{"uploadType": {"media"}, "name": {key}}, map[string]string{"Content-Type": "application/octet-stream"}, size, func() io.Reader { return io.NewSectionReader(source, 0, size) }, false)
				if err != nil {
					return err
				}
				drainAndClose(resp.Body)
				progress.completed += size
			} else {
				before := progress.completed
				err = c.uploadResumable(ctx, bucket, key, source, size, chunk, verify, func(offset int64) {
					progress.completed = before + offset
					progress.parts++
					progress.emit("running", false)
				})
				if err != nil {
					return err
				}
			}
			return verify()
		}()
		if err != nil {
			return nil, err
		}
		progress.done++
		progress.emit("running", false)
	}
	job := progress.job("completed")
	job["progress"] = 1.0
	return job, nil
}

func gcsResumeOffset(resp *http.Response, total int64) (int64, error) {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return total, nil
	}
	value := resp.Header.Get("Range")
	if value == "" {
		return 0, nil
	}
	if !strings.HasPrefix(value, "bytes=0-") {
		return 0, &sidecarError{Code: "invalid_response", Message: "Invalid Cloud Storage resumable offset."}
	}
	end, err := strconv.ParseInt(strings.TrimPrefix(value, "bytes=0-"), 10, 64)
	if err != nil || end < 0 || end >= total {
		return 0, &sidecarError{Code: "invalid_response", Message: "Invalid Cloud Storage resumable offset."}
	}
	return end + 1, nil
}

func (c *gcsClient) uploadResumable(ctx context.Context, bucket, key string, source io.ReaderAt, size, chunk int64, verify func() error, progress func(int64)) (err error) {
	resp, err := c.do(ctx, http.MethodPost, c.urlFor("upload", "storage", "v1", "b", bucket, "o"), url.Values{"uploadType": {"resumable"}, "name": {key}}, map[string]string{"Content-Type": "application/json", "X-Upload-Content-Length": strconv.FormatInt(size, 10), "X-Upload-Content-Type": "application/octet-stream"}, 2, func() io.Reader { return strings.NewReader("{}") }, false)
	if err != nil {
		return err
	}
	location := resp.Header.Get("Location")
	drainAndClose(resp.Body)
	session, parseErr := url.Parse(location)
	if parseErr != nil || location == "" {
		return &sidecarError{Code: "invalid_response", Message: "Cloud Storage omitted a valid upload session."}
	}
	session = c.base.ResolveReference(session)
	if session.Host == "" || session.User != nil || (session.Scheme != "http" && session.Scheme != "https") || session.Fragment != "" {
		return &sidecarError{Code: "invalid_response", Message: "Cloud Storage returned an invalid upload session."}
	}
	ctx = context.WithValue(ctx, gcsRequestContextKey{}, gcsRequestPrivacy{session: true})
	complete := false
	defer func() {
		if !complete {
			// Failure/cancellation must not prevent best-effort session cleanup.
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			defer cancel()
			response, _ := c.do(cleanup, http.MethodDelete, session, nil, nil, 0, nil, false)
			if response != nil {
				drainAndClose(response.Body)
			}
		}
	}()
	var offset int64
	failures := 0
	for offset < size {
		if err = verify(); err != nil {
			return err
		}
		start := offset
		length := min(chunk, size-start)
		headers := map[string]string{"Content-Type": "application/octet-stream", "Content-Range": fmt.Sprintf("bytes %d-%d/%d", start, start+length-1, size)}
		response, chunkErr := c.do(ctx, http.MethodPut, session, nil, headers, length, func() io.Reader { return io.NewSectionReader(source, start, length) }, false)
		if chunkErr != nil {
			mapped := mapError(chunkErr)
			status := asInt(asMap(mapped["details"])["httpStatus"])
			if status != 0 && !gcsTransient(status) {
				return chunkErr
			}
			failures++
			if failures >= max(1, c.attempts) {
				return chunkErr
			}
			if err = retryPause(ctx, min(failures-1, 3)); err != nil {
				return gcsTransportError(err)
			}
			// A lost response can mean bytes were committed. Ask before replay.
			response, err = c.do(ctx, http.MethodPut, session, nil, map[string]string{"Content-Range": fmt.Sprintf("bytes */%d", size)}, 0, nil, true)
			if err != nil {
				return err
			}
		}
		next, offsetErr := gcsResumeOffset(response, size)
		final := response.StatusCode >= 200 && response.StatusCode < 300
		drainAndClose(response.Body)
		if offsetErr != nil {
			return offsetErr
		}
		if next < start || next > start+length || (next == size && !final) {
			return &sidecarError{Code: "invalid_response", Message: "Cloud Storage returned an inconsistent upload offset."}
		}
		if err = verify(); err != nil {
			return err
		}
		if chunkErr == nil && next < start+length {
			failures++
			if failures >= max(1, c.attempts) {
				return &sidecarError{Code: "invalid_response", Message: "Cloud Storage upload made insufficient progress."}
			}
		} else if chunkErr == nil {
			failures = 0
		}
		offset = next
		progress(offset)
		if final {
			complete = true
			return nil
		}
	}
	return &sidecarError{Code: "invalid_response", Message: "Cloud Storage did not confirm upload completion."}
}

func (c *gcsClient) startDownload(ctx context.Context, p profile, bucket string, params map[string]interface{}) (map[string]interface{}, error) {
	ce, err := parseClientEncryption(params, false)
	if err != nil {
		return nil, err
	}
	keys := asStringSlice(params["keys"])
	directory := strings.TrimSpace(asString(params["destinationPath"]))
	if len(keys) == 0 || directory == "" {
		return nil, &sidecarError{Code: "invalid_config", Message: "Download keys and destination path are required."}
	}
	threshold := int64(maxInt(asInt(params["multipartThresholdMiB"]), 1, 32)) * 1024 * 1024
	chunk := int64(maxInt(asInt(params["multipartChunkMiB"]), 1, 8)) * 1024 * 1024
	objects := map[string]gcsObject{}
	sizes := map[string]int64{}
	var total int64
	var outputLines []string
	for _, key := range keys {
		if key == "" {
			return nil, &sidecarError{Code: "invalid_config", Message: "Download object key is required."}
		}
		object, err := c.metadata(ctx, bucket, key, asString(params["versionId"]))
		if err != nil {
			return nil, err
		}
		size, err := strconv.ParseInt(object.Size, 10, 64)
		if err != nil || size < 0 || object.Generation == "" {
			return nil, &sidecarError{Code: "invalid_response", Message: "Invalid Cloud Storage download metadata."}
		}
		if ce != nil {
			if _, err = agePlaintextLength(ce.headerLength, size); err != nil {
				return nil, err
			}
		}
		objects[key], sizes[key] = object, size
		total += size
	}
	if err = os.MkdirAll(directory, 0o755); err != nil {
		return nil, err
	}
	destination, err := newDownloadDestination(directory)
	if err != nil {
		return nil, err
	}
	progress := newGCSTransferProgress(params, "download", bucket, len(keys), total, chunk)
	progress.emit("queued", true)
	for _, key := range keys {
		progress.current = key
		size := sizes[key]
		err = func() error {
			file, err := os.CreateTemp(directory, ".odb-*.part")
			if err != nil {
				return err
			}
			temporary := file.Name()
			defer os.Remove(temporary)
			defer file.Close()
			open := func(ctx context.Context, start, length int64) (io.ReadCloser, error) {
				resp, err := c.do(ctx, http.MethodGet, c.objectURL(bucket, key), url.Values{"alt": {"media"}, "generation": {objects[key].Generation}}, map[string]string{"Range": fmt.Sprintf("bytes=%d-%d", start, start+length-1), "Accept-Encoding": "identity"}, 0, nil, true)
				if err != nil {
					return nil, err
				}
				if resp.StatusCode != http.StatusPartialContent || resp.Header.Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", start, start+length-1, size) || (resp.ContentLength >= 0 && resp.ContentLength != length) {
					resp.Body.Close()
					return nil, &sidecarError{Code: "invalid_response", Message: "Cloud Storage download range mismatch; partial file discarded."}
				}
				return resp.Body, nil
			}
			workers := 1
			if size >= threshold {
				workers = transferConcurrency(p)
			}
			addProgress := func(copied int64, part bool) {
				progress.mu.Lock()
				defer progress.mu.Unlock()
				progress.completed += copied
				if part {
					progress.parts++
				}
				progress.emit("running", false)
			}
			if ce != nil {
				err = downloadAgePayload(ctx, file, ce, size, workers, p.MaxAttempts, open, addProgress)
			} else {
				err = parallelParts(ctx, int((size+chunk-1)/chunk), workers, func(ctx context.Context, index int) error {
					start := int64(index) * chunk
					length := min(chunk, size-start)
					copied, err := downloadRangeWithRetry(ctx, file, start, length, p.MaxAttempts, func() (io.ReadCloser, error) { return open(ctx, start, length) })
					if err == nil {
						addProgress(copied, true)
					}
					return err
				})
			}
			if err != nil {
				return err
			}
			if err = ctx.Err(); err != nil {
				return gcsTransportError(err)
			}
			if err = file.Sync(); err != nil {
				return err
			}
			if err = file.Close(); err != nil {
				return err
			}
			finalPath, err := destination.publish(temporary, ce.downloadName(key), asString(params["conflictPolicy"]))
			if err == nil && ce != nil {
				outputLines = append(outputLines, fmt.Sprintf("Saved %s to %s.", filepath.Base(finalPath), finalPath))
			}
			return err
		}()
		if err != nil {
			return nil, err
		}
		progress.done++
	}
	job := progress.job("completed")
	job["progress"] = 1.0
	if ce != nil {
		job["outputLines"] = outputLines
	}
	return job, nil
}
