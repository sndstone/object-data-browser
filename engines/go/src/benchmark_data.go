package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"fmt"
	"hash"
	"hash/crc32"
	"io"
	"os"
	"strings"
	"sync"
	"sync/atomic"
)

const transferCopyBufferBytes = 1024 * 1024

func copyTransferRange(dst io.Writer, src io.Reader) (int64, error) {
	return io.CopyBuffer(dst, src, make([]byte, transferCopyBufferBytes))
}

type benchmarkCounters struct{ retries atomic.Int64 }
type benchmarkAttemptKey struct{}
type benchmarkAttemptCounter struct {
	metrics  *benchmarkCounters
	attempts atomic.Int64
}

func benchmarkRequestContext(ctx context.Context, metrics *benchmarkCounters) context.Context {
	return context.WithValue(ctx, benchmarkAttemptKey{}, &benchmarkAttemptCounter{metrics: metrics})
}

// Called by the shared HTTP transport: captures SDK retries even when a request
// ultimately fails and therefore has no response metadata to inspect.
func recordBenchmarkAttempt(ctx context.Context) {
	if counter, ok := ctx.Value(benchmarkAttemptKey{}).(*benchmarkAttemptCounter); ok && counter.metrics != nil {
		if counter.attempts.Add(1) > 1 {
			counter.metrics.retries.Add(1)
		}
	}
}

type benchmarkPayloadStore struct {
	mu           sync.Mutex
	inMemory     bool
	budget, used int64
	cache        map[string][]byte
}

func newBenchmarkPayloadStore(config map[string]interface{}) (*benchmarkPayloadStore, error) {
	if _, err := benchmarkHasher(config); err != nil {
		return nil, err
	}
	mb := asInt(config["dataCacheMb"])
	if mb < 0 || mb > 512 {
		return nil, &sidecarError{Code: "invalid_config", Message: "Benchmark data cache must be between 0 and 512 MiB."}
	}
	return &benchmarkPayloadStore{inMemory: !payloadHasFalse(config["inMemoryData"]), budget: int64(mb) * 1024 * 1024, cache: map[string][]byte{}}, nil
}

func benchmarkHasher(config map[string]interface{}) (hash.Hash, error) {
	switch strings.ToLower(asString(config["checksumAlgorithm"])) {
	case "", "sha256", "sha-256":
		return sha256.New(), nil
	case "md5":
		return md5.New(), nil
	case "sha1", "sha-1":
		return sha1.New(), nil
	case "crc32":
		return crc32.NewIEEE(), nil
	case "crc32c":
		return crc32.New(crc32.MakeTable(crc32.Castagnoli)), nil
	default:
		return nil, &sidecarError{Code: "invalid_config", Message: "Unsupported benchmark checksum algorithm."}
	}
}

type benchmarkPatternReader struct {
	pattern      []byte
	size, offset int64
}

func newBenchmarkPatternReader(runID, key string, size int, random bool) *benchmarkPatternReader {
	pattern := []byte("A")
	if random {
		seed := []byte(fmt.Sprintf("%s:%s:%d", runID, key, size))
		length := min(4096, max(64, len(seed)*8))
		pattern = make([]byte, length)
		for index := range pattern {
			pattern[index] = byte((int(seed[index%len(seed)]) + index*17) % 256)
		}
	}
	return &benchmarkPatternReader{pattern: pattern, size: int64(size)}
}

func (r *benchmarkPatternReader) Read(p []byte) (int, error) {
	if r.offset >= r.size {
		return 0, io.EOF
	}
	length := int(min(int64(len(p)), r.size-r.offset))
	if length == 0 {
		return 0, nil
	}
	p = p[:length]
	phase := int(r.offset % int64(len(r.pattern)))
	filled := copy(p, r.pattern[phase:])
	if filled < length {
		filled += copy(p[filled:], r.pattern[:phase])
	}
	for filled < length {
		filled += copy(p[filled:], p[:filled])
	}
	r.offset += int64(length)
	return length, nil
}

func (r *benchmarkPatternReader) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
	case io.SeekCurrent:
		offset += r.offset
	case io.SeekEnd:
		offset += r.size
	default:
		return r.offset, fmt.Errorf("invalid seek origin")
	}
	if offset < 0 {
		return r.offset, fmt.Errorf("negative payload offset")
	}
	r.offset = offset
	return offset, nil
}

func (s *benchmarkPayloadStore) open(runID, key string, size int, random bool) (io.ReadSeeker, func(), error) {
	reader := newBenchmarkPatternReader(runID, key, size, random)
	if !s.inMemory {
		file, err := os.CreateTemp(runtimeDir(), ".benchmark-payload-*")
		if err != nil {
			return nil, nil, err
		}
		cleanup := func() { file.Close(); os.Remove(file.Name()) }
		if _, err = copyTransferRange(file, reader); err == nil {
			_, err = file.Seek(0, io.SeekStart)
		}
		if err != nil {
			cleanup()
			return nil, nil, err
		}
		return file, cleanup, nil
	}
	cacheKey := fmt.Sprintf("%d", size)
	if random {
		cacheKey = runID + ":" + key + ":" + cacheKey
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if payload, ok := s.cache[cacheKey]; ok {
		return bytes.NewReader(payload), func() {}, nil
	}
	if size > 0 && int64(size) <= s.budget-s.used {
		payload := make([]byte, size)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return nil, nil, err
		}
		s.cache[cacheKey] = payload
		s.used += int64(size)
		return bytes.NewReader(payload), func() {}, nil
	}
	// No whole-object allocation when the cache is disabled, full, or smaller
	// than this object. The seekable generator supports SDK signing/retries.
	return reader, func() {}, nil
}

func benchmarkReadResult(body io.Reader, runID string, config map[string]interface{}, plan benchmarkOpPlan) (int, string, error) {
	hash, err := benchmarkHasher(config)
	if err != nil {
		return 0, "not_used", err
	}
	validate := asBool(config["validateChecksum"])
	var target io.Writer = io.Discard
	if validate {
		target = hash
	}
	count, err := copyTransferRange(target, io.LimitReader(body, int64(plan.sizeBytes)+1))
	if err != nil {
		return int(count), "not_used", err
	}
	if count != int64(plan.sizeBytes) {
		return int(count), "not_used", fmt.Errorf("benchmark read length mismatch: received %d, expected %d", count, plan.sizeBytes)
	}
	if !validate {
		return int(count), "not_used", nil
	}
	expected, _ := benchmarkHasher(config)
	if _, err = copyTransferRange(expected, newBenchmarkPatternReader(runID, plan.key, plan.sizeBytes, asBool(config["randomData"]))); err != nil {
		return int(count), "not_used", err
	}
	if !bytes.Equal(hash.Sum(nil), expected.Sum(nil)) {
		return int(count), "validated_failure", nil
	}
	return int(count), "validated_success", nil
}
