package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"testing"
	"time"
)

func transferTestHTTPClient(t *testing.T, provider, endpoint string) interface {
	Do(*http.Request) (*http.Response, error)
} {
	t.Helper()
	payload := testProfilePayload(endpoint)
	payload["endpointType"] = provider
	payload["connectTimeoutSeconds"] = 1
	payload["readTimeoutSeconds"] = 1
	if provider == "azureBlob" {
		payload["secretKey"] = "Zml4dHVyZQ=="
	}
	p, err := parseProfile(payload)
	if err != nil {
		t.Fatal(err)
	}
	if provider == "azureBlob" {
		client, _, err := buildAzureClient(p)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(client.httpClient.CloseIdleConnections)
		return client.httpClient
	}
	client, _, err := buildClient(p)
	if err != nil {
		t.Fatal(err)
	}
	httpClient := client.Options().HTTPClient.(*http.Client)
	t.Cleanup(httpClient.CloseIdleConnections)
	return httpClient
}

type pacedUpload struct {
	remaining int
	interval  time.Duration
}

func (body *pacedUpload) Read(p []byte) (int, error) {
	if body.remaining == 0 {
		return 0, io.EOF
	}
	time.Sleep(body.interval)
	n := min(len(p), body.remaining, 1024)
	clear(p[:n])
	body.remaining -= n
	return n, nil
}

func TestTransferHTTPAllowsSteadyBodiesBeyondOldDeadline(t *testing.T) {
	for _, provider := range []string{"s3Compatible", "azureBlob"} {
		for _, direction := range []string{"upload", "download"} {
			t.Run(provider+"/"+direction, func(t *testing.T) {
				const size = 20 * 1024
				const interval = 125 * time.Millisecond
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if direction == "upload" {
						n, err := io.Copy(io.Discard, r.Body)
						if err != nil || n != size {
							t.Errorf("upload: %d bytes, %v", n, err)
						}
						w.WriteHeader(http.StatusNoContent)
						return
					}
					w.Header().Set("Content-Length", fmt.Sprint(size))
					for i := 0; i < 20; i++ {
						if _, err := w.Write(make([]byte, 1024)); err != nil {
							return
						}
						w.(http.Flusher).Flush()
						time.Sleep(interval)
					}
				}))
				defer server.Close()
				client := transferTestHTTPClient(t, provider, server.URL)
				method := http.MethodGet
				var body io.Reader
				if direction == "upload" {
					method = http.MethodPut
					body = &pacedUpload{remaining: size, interval: interval}
				}
				req, err := http.NewRequest(method, server.URL, body)
				if err != nil {
					t.Fatal(err)
				}
				if body != nil {
					req.ContentLength = size
				}
				started := time.Now()
				resp, err := client.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				defer resp.Body.Close()
				n, err := io.Copy(io.Discard, resp.Body)
				if err != nil || (direction == "download" && n != size) {
					t.Fatalf("body: %d bytes, %v", n, err)
				}
				if elapsed := time.Since(started); elapsed <= 2*time.Second {
					t.Fatalf("fixture did not exceed old connect + read deadline: %v", elapsed)
				}
			})
		}
	}
}

func TestTransferHTTPStallAndCancellation(t *testing.T) {
	for _, provider := range []string{"s3Compatible", "azureBlob"} {
		for _, cancelRequest := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/cancel=%v", provider, cancelRequest), func(t *testing.T) {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Length", "2")
					_, _ = w.Write([]byte("a"))
					w.(http.Flusher).Flush()
					<-r.Context().Done()
				}))
				defer server.Close()
				client := transferTestHTTPClient(t, provider, server.URL)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				req, _ := http.NewRequestWithContext(ctx, http.MethodGet, server.URL, nil)
				resp, err := client.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				defer resp.Body.Close()
				if _, err = io.ReadFull(resp.Body, make([]byte, 1)); err != nil {
					t.Fatal(err)
				}
				started := time.Now()
				if cancelRequest {
					cancel()
				}
				_, err = io.ReadAll(resp.Body)
				elapsed := time.Since(started)
				if cancelRequest {
					if !errors.Is(err, context.Canceled) || elapsed > 500*time.Millisecond {
						t.Fatalf("cancellation was not prompt: %v after %v", err, elapsed)
					}
				} else if !errors.Is(err, errBodyStalled) || elapsed < 800*time.Millisecond || elapsed > 1500*time.Millisecond {
					t.Fatalf("stall deadline: %v after %v", err, elapsed)
				}
			})
		}
	}
}

func TestTransferHTTPBoundsTLSAndResponseHeaders(t *testing.T) {
	p := profile{ConnectTimeoutSeconds: 1, ReadTimeoutSeconds: 2, VerifyTLS: true}
	transport, err := profileTransport(p)
	if err != nil {
		t.Fatal(err)
	}
	defer transport.CloseIdleConnections()
	client := profileHTTPClient(p, transport)
	if client.Timeout != 0 || transport.TLSHandshakeTimeout != time.Second || transport.ResponseHeaderTimeout != 2*time.Second {
		t.Fatalf("unexpected deadlines: client=%v TLS=%v headers=%v", client.Timeout, transport.TLSHandshakeTimeout, transport.ResponseHeaderTimeout)
	}
	if _, ok := client.Transport.(loggingRoundTripper); !ok {
		t.Fatal("logging transport lost")
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		<-r.Context().Done()
	}))
	defer server.Close()
	transport.ResponseHeaderTimeout = 100 * time.Millisecond
	started := time.Now()
	_, err = client.Post(server.URL, "application/octet-stream", bytes.NewReader([]byte("body")))
	if err == nil || time.Since(started) > time.Second {
		t.Fatalf("response headers were not bounded: %v", err)
	}
}

func TestTransferHTTPStalledUpload(t *testing.T) {
	for _, provider := range []string{"s3Compatible", "azureBlob"} {
		t.Run(provider, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.Copy(io.Discard, r.Body)
			}))
			defer server.Close()
			client := transferTestHTTPClient(t, provider, server.URL)
			reader, writer := io.Pipe()
			defer reader.Close()
			defer writer.Close()
			go func() { _, _ = writer.Write([]byte("a")) }()
			req, _ := http.NewRequest(http.MethodPut, server.URL, reader)
			req.ContentLength = 2
			started := time.Now()
			resp, err := client.Do(req)
			if resp != nil {
				resp.Body.Close()
			}
			if !errors.Is(err, errBodyStalled) || time.Since(started) > 1500*time.Millisecond {
				t.Fatalf("stalled upload did not fail promptly: %v after %v", err, time.Since(started))
			}
		})
	}
}

type inactivityTestTransport func(*http.Request) (*http.Response, error)

func (rt inactivityTestTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	return rt(req)
}

type contextBlockedBody struct{ ctx context.Context }

func (body contextBlockedBody) Read([]byte) (int, error) {
	<-body.ctx.Done()
	return 0, body.ctx.Err()
}
func (contextBlockedBody) Close() error { return nil }

func TestTransferInactivityTracksBodiesAndReleasesContext(t *testing.T) {
	for _, stalled := range []bool{false, true} {
		t.Run(fmt.Sprint(stalled), func(t *testing.T) {
			var transferCtx context.Context
			base := inactivityTestTransport(func(req *http.Request) (*http.Response, error) {
				transferCtx = req.Context()
				httptrace.ContextClientTrace(req.Context()).GotConn(httptrace.GotConnInfo{})
				defer req.Body.Close()
				if _, err := io.Copy(io.Discard, req.Body); err != nil {
					return nil, err
				}
				var body io.ReadCloser = io.NopCloser(&pacedUpload{remaining: 8 * 1024, interval: 10 * time.Millisecond})
				if stalled {
					body = contextBlockedBody{req.Context()}
				}
				return &http.Response{StatusCode: 200, Body: body, Header: http.Header{}, Request: req}, nil
			})
			client := &http.Client{Transport: inactivityRoundTripper{base: base, timeout: 50 * time.Millisecond}}
			started := time.Now()
			resp, err := client.Post("http://fixture", "application/octet-stream", &pacedUpload{remaining: 8 * 1024, interval: 10 * time.Millisecond})
			if err != nil {
				t.Fatal(err)
			}
			_, err = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if stalled && !errors.Is(err, errBodyStalled) {
				t.Fatalf("stalled read returned %v", err)
			} else if !stalled && err != nil {
				t.Fatal(err)
			}
			if elapsed := time.Since(started); elapsed <= 100*time.Millisecond || elapsed > time.Second {
				t.Fatalf("unexpected transfer duration: %v", elapsed)
			}
			if transferCtx.Err() == nil {
				t.Fatal("response close did not release the request context")
			}
		})
	}
}

func TestTransferInactivityUnblocksStalledUploadSource(t *testing.T) {
	for _, cancelRequest := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelRequest), func(t *testing.T) {
			base := inactivityTestTransport(func(req *http.Request) (*http.Response, error) {
				httptrace.ContextClientTrace(req.Context()).GotConn(httptrace.GotConnInfo{})
				_, err := io.Copy(io.Discard, req.Body)
				return nil, err
			})
			client := &http.Client{Transport: inactivityRoundTripper{base: base, timeout: 50 * time.Millisecond}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			reader, writer := io.Pipe()
			defer reader.Close()
			defer writer.Close()
			req, _ := http.NewRequestWithContext(ctx, http.MethodPut, "http://fixture", reader)
			completed := make(chan error, 1)
			go func() { _, err := client.Do(req); completed <- err }()
			if _, err := writer.Write([]byte("a")); err != nil {
				t.Fatal(err)
			}
			if cancelRequest {
				cancel()
			}
			select {
			case err := <-completed:
				wantErr := error(errBodyStalled)
				if cancelRequest {
					wantErr = context.Canceled
				}
				if !errors.Is(err, wantErr) {
					t.Fatalf("stalled upload source: %v", err)
				}
			case <-time.After(500 * time.Millisecond):
				t.Fatal("pending request body read was not interrupted")
			}
		})
	}
}
