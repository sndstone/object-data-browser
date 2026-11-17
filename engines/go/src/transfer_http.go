package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptrace"
	"sync"
	"time"
)

type bodyStallError struct{}

func (bodyStallError) Error() string   { return "HTTP body transfer stalled" }
func (bodyStallError) Timeout() bool   { return true }
func (bodyStallError) Temporary() bool { return true }

var errBodyStalled = bodyStallError{}

func profileHTTPClient(p profile, transport *http.Transport) *http.Client {
	return &http.Client{Transport: loggingRoundTripper{
		base:        inactivityRoundTripper{base: transport, timeout: time.Duration(p.ReadTimeoutSeconds) * time.Second},
		diagnostics: p.Diagnostics,
	}}
}

// The timer belongs to one request, so concurrent requests (including HTTP/2
// streams) cannot refresh each other's deadline or cancel each other.
type inactivityRoundTripper struct {
	base    http.RoundTripper
	timeout time.Duration
}

func (rt inactivityRoundTripper) CloseIdleConnections() {
	if closer, ok := rt.base.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

func (rt inactivityRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	ctx, cancel := context.WithCancelCause(request.Context())
	activity := &bodyActivity{timeout: rt.timeout, cancel: cancel}
	// Connection establishment and TLS have their own transport deadlines. Start
	// the inactivity window only once a connection is available to this request.
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{GotConn: func(httptrace.GotConnInfo) { activity.touch() }})
	req := request.Clone(ctx)
	if req.Body != nil && req.Body != http.NoBody {
		req.Body = activityRequestBody(req.Body, activity, ctx)
	}
	if req.GetBody != nil {
		getBody := req.GetBody
		req.GetBody = func() (io.ReadCloser, error) {
			body, err := getBody()
			if err != nil {
				return nil, err
			}
			return activityRequestBody(body, activity, ctx), nil
		}
	}
	response, err := rt.base.RoundTrip(req)
	if err != nil {
		cause := context.Cause(ctx)
		activity.finish()
		if cause != nil {
			return nil, cause
		}
		return nil, err
	}
	if response.Body == nil || response.Body == http.NoBody {
		activity.finish()
	} else {
		activity.touch()
		response.Body = &activityBody{ReadCloser: response.Body, activity: activity, ctx: ctx, response: true}
	}
	return response, nil
}

type bodyActivity struct {
	mu      sync.Mutex
	timeout time.Duration
	last    time.Time
	timer   *time.Timer
	stopped bool
	cancel  context.CancelCauseFunc
}

func (a *bodyActivity) touch() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.stopped {
		return
	}
	a.last = time.Now()
	if a.timer == nil {
		a.timer = time.AfterFunc(a.timeout, a.expire)
	}
}

func (a *bodyActivity) expire() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.stopped {
		return
	}
	if remaining := a.timeout - time.Since(a.last); remaining > 0 {
		a.timer.Reset(remaining)
		return
	}
	a.stopped = true
	a.cancel(errBodyStalled)
}

func (a *bodyActivity) finish() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.stopped = true
	if a.timer != nil {
		a.timer.Stop()
	}
	a.cancel(nil)
}

type activityBody struct {
	io.ReadCloser
	activity  *bodyActivity
	ctx       context.Context
	response  bool
	closeOnce sync.Once
	closeErr  error
}

func activityRequestBody(body io.ReadCloser, activity *bodyActivity, ctx context.Context) *activityBody {
	wrapped := &activityBody{ReadCloser: body, activity: activity, ctx: ctx}
	// Canceling the transport also has to unblock a pending source Read, not
	// just socket I/O. Request bodies must support concurrent Close and Read.
	context.AfterFunc(ctx, func() { wrapped.Close() })
	return wrapped
}

func (body *activityBody) Read(p []byte) (int, error) {
	n, err := body.ReadCloser.Read(p)
	if n > 0 {
		body.activity.touch()
	}
	if errors.Is(context.Cause(body.ctx), errBodyStalled) {
		err = errBodyStalled
	}
	if body.response && err != nil {
		body.activity.finish()
	}
	return n, err
}

func (body *activityBody) Close() error {
	body.closeOnce.Do(func() {
		if body.response {
			body.activity.finish()
		}
		body.closeErr = body.ReadCloser.Close()
	})
	return body.closeErr
}
