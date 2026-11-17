package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
)

// open must validate the range and source conditions on every attempt. Request
// setup failures already receive SDK/client retries; only interrupted bodies
// are replayed here. Callers commit progress only after a complete range.
func downloadRangeWithRetry(ctx context.Context, target io.WriterAt, start, length int64, attempts int, open func() (io.ReadCloser, error)) (int64, error) {
	attempts = max(1, attempts)
	buffer := make([]byte, min(int64(transferCopyBufferBytes), length+1))
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		body, err := open()
		if err != nil {
			return 0, err
		}
		copied, retry, err := copyDownloadRange(ctx, target, body, start, length, buffer)
		body.Close()
		if err == nil {
			return copied, nil
		}
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		if !retry || attempt+1 == attempts {
			return 0, err
		}
		if err = retryPause(ctx, min(attempt, 3)); err != nil {
			return 0, err
		}
	}
}

func copyDownloadRange(ctx context.Context, target io.WriterAt, body io.Reader, start, length int64, buffer []byte) (int64, bool, error) {
	var copied int64
	for {
		if err := ctx.Err(); err != nil {
			return copied, false, err
		}
		n, readErr := body.Read(buffer[:min(int64(len(buffer)), length-copied+1)])
		if int64(n) > length-copied {
			return copied, false, fmt.Errorf("download range length mismatch; partial file discarded")
		}
		if n > 0 {
			if err := ctx.Err(); err != nil {
				return copied, false, err
			}
			written, err := target.WriteAt(buffer[:n], start+copied)
			if err != nil {
				return copied, false, err
			}
			if written != n {
				return copied, false, io.ErrShortWrite
			}
			copied += int64(n)
		}
		if errors.Is(readErr, io.EOF) {
			if copied == length {
				return copied, false, nil
			}
			return copied, true, io.ErrUnexpectedEOF
		}
		if readErr != nil {
			var networkError net.Error
			retry := errors.Is(readErr, io.ErrUnexpectedEOF) || errors.As(readErr, &networkError)
			return copied, retry, readErr
		}
	}
}
