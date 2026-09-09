// SPDX-License-Identifier: LGPL-2.1-or-later
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testHandler(t *testing.T, s *server) http.Handler {
	t.Helper()
	h, err := s.handler()
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func requireAck(t *testing.T, recorder *httptest.ResponseRecorder, want int64) {
	t.Helper()
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d, body=%q", recorder.Code, recorder.Body.String())
	}
	var ack struct {
		Bytes int64 `json:"bytes"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &ack); err != nil {
		t.Fatalf("invalid ACK: %v (%q)", err, recorder.Body.String())
	}
	if ack.Bytes != want {
		t.Fatalf("ACK bytes=%d, want %d", ack.Bytes, want)
	}
	if !strings.HasPrefix(recorder.Header().Get("Content-Type"), "application/json") {
		t.Fatal("ACK lacks JSON content type")
	}
}

func TestUploadACKAndLegacy(t *testing.T) {
	s := newServer(4, 12, 0)
	h := testHandler(t, s)
	for _, size := range []int{0, 1, uploadBufferBytes - 1, uploadBufferBytes + 17, 1 << 20} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			body := bytes.Repeat([]byte{0xab}, size)
			for _, query := range []string{"?ack=1", "", "?ack=0"} {
				recorder := httptest.NewRecorder()
				h.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/backend/empty.php"+query, bytes.NewReader(body)))
				if query == "?ack=1" {
					requireAck(t, recorder, int64(size))
				} else if recorder.Code != http.StatusOK || recorder.Body.Len() != 0 {
					t.Fatalf("legacy response changed: status=%d, body=%q", recorder.Code, recorder.Body.String())
				}
			}
		})
	}
}

type syntheticBody struct {
	remaining int64
	err       error
	maxRead   int
}

func (b *syntheticBody) Read(p []byte) (int, error) {
	if len(p) > b.maxRead {
		b.maxRead = len(p)
	}
	if b.remaining == 0 {
		if b.err != nil {
			return 0, b.err
		}
		return 0, io.EOF
	}
	n := len(p)
	if int64(n) > b.remaining {
		n = int(b.remaining)
	}
	b.remaining -= int64(n)
	return n, nil
}
func (*syntheticBody) Close() error                     { return nil }
func (*syntheticBody) WriteTo(io.Writer) (int64, error) { panic("unexpected WriterTo bypass") }

func TestUploadUsesProvided128KiBBuffer(t *testing.T) {
	if _, ok := any(discardSink{}).(io.ReaderFrom); ok {
		t.Fatal("discard sink must not bypass CopyBuffer's supplied buffer")
	}
	s := newServer(1, 12, 0)
	body := &syntheticBody{remaining: 3*uploadBufferBytes + 1}
	r := httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1", nil)
	r.Body, r.ContentLength = body, body.remaining
	recorder := httptest.NewRecorder()
	s.empty(recorder, r)
	requireAck(t, recorder, 3*uploadBufferBytes+1)
	if body.maxRead != uploadBufferBytes {
		t.Fatalf("body read buffer=%d; want %d", body.maxRead, uploadBufferBytes)
	}
}

func TestUploadFailuresNeverACK(t *testing.T) {
	s := newServer(1, 12, 0)
	for _, tc := range []struct {
		name                     string
		bodyBytes, contentLength int64
		err                      error
		cancel                   bool
		status                   int
	}{
		{"declared oversize", 0, maxUploadBody + 1, nil, false, 413},
		{"unknown length oversize", maxUploadBody + 1, -1, nil, false, 413},
		{"unexpected EOF", 3, 10, io.ErrUnexpectedEOF, false, 400},
		{"short content length", 3, 10, nil, false, 400},
		{"invalid body", 3, -1, errors.New("broken body"), false, 400},
		{"cancelled", 3, 3, nil, true, 408},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, query := range []string{"?ack=1", ""} {
				r := httptest.NewRequest(http.MethodPost, "/backend/empty.php"+query, nil)
				r.Body = &syntheticBody{remaining: tc.bodyBytes, err: tc.err}
				r.ContentLength = tc.contentLength
				if tc.cancel {
					ctx, cancel := context.WithCancel(r.Context())
					cancel()
					r = r.WithContext(ctx)
				}
				recorder := httptest.NewRecorder()
				s.empty(recorder, r)
				if recorder.Code != tc.status || strings.Contains(recorder.Body.String(), `"bytes"`) {
					t.Fatalf("status=%d body=%q; want error %d without ACK", recorder.Code, recorder.Body.String(), tc.status)
				}
			}
		})
	}
	// The exact upload limit is accepted without allocating a 256 MiB body.
	r := httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1", nil)
	r.Body = &syntheticBody{remaining: maxUploadBody}
	r.ContentLength = -1
	recorder := httptest.NewRecorder()
	s.empty(recorder, r)
	requireAck(t, recorder, maxUploadBody)
}

type gatedBody struct {
	entered chan struct{}
	release <-chan struct{}
	first   bool
}

func (b *gatedBody) Read(p []byte) (int, error) {
	if !b.first {
		b.first = true
		copy(p, "abc")
		return 3, nil
	}
	close(b.entered)
	<-b.release
	return 0, io.EOF
}
func (*gatedBody) Close() error { return nil }

type observedWriter struct {
	header http.Header
	writes atomic.Int32
	status int
	body   bytes.Buffer
}

func (w *observedWriter) Header() http.Header    { return w.header }
func (w *observedWriter) WriteHeader(status int) { w.writes.Add(1); w.status = status }
func (w *observedWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	w.writes.Add(1)
	return w.body.Write(p)
}

func TestACKWaitsForEOFAndRejectsLateCancellation(t *testing.T) {
	for _, cancelBeforeEOF := range []bool{false, true} {
		s := newServer(1, 12, 0)
		release := make(chan struct{})
		body := &gatedBody{entered: make(chan struct{}), release: release}
		r := httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1", nil)
		r.Body, r.ContentLength = body, -1
		ctx, cancel := context.WithCancel(r.Context())
		w := &observedWriter{header: make(http.Header)}
		done := make(chan struct{})
		go func() { s.empty(w, r.WithContext(ctx)); close(done) }()
		<-body.entered
		if w.writes.Load() != 0 {
			t.Fatal("response sent before upload EOF")
		}
		if cancelBeforeEOF {
			cancel()
		}
		close(release)
		<-done
		cancel()
		if cancelBeforeEOF {
			if w.status != 408 || strings.Contains(w.body.String(), `"bytes"`) {
				t.Fatalf("cancelled upload ACKed: %d %s", w.status, &w.body)
			}
		} else if w.status != 200 || strings.TrimSpace(w.body.String()) != `{"bytes":3}` {
			t.Fatalf("complete upload not ACKed: %d %s", w.status, &w.body)
		}
	}
}

func TestConcurrentSlotsBusyAndRelease(t *testing.T) {
	s := newServer(1, 12, 0)
	h := testHandler(t, s)
	release := make(chan struct{})
	var done sync.WaitGroup
	recorders := make([]*httptest.ResponseRecorder, cap(s.slots))
	for i := range recorders {
		body := &gatedBody{entered: make(chan struct{}), release: release}
		r := httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1", nil)
		r.Body, r.ContentLength = body, -1
		recorder := httptest.NewRecorder()
		recorders[i] = recorder
		done.Add(1)
		go func() { defer done.Done(); h.ServeHTTP(recorder, r) }()
		<-body.entered
	}
	busy := httptest.NewRecorder()
	h.ServeHTTP(busy, httptest.NewRequest(http.MethodGet, "/backend/empty.php", nil))
	if busy.Code != 503 || !strings.Contains(busy.Header().Get("Cache-Control"), "no-store") {
		t.Fatalf("busy response=%d %v", busy.Code, busy.Header())
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cancelled := httptest.NewRecorder()
	h.ServeHTTP(cancelled, httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1", nil).WithContext(ctx))
	if cancelled.Code != 408 {
		t.Fatalf("cancelled response=%d", cancelled.Code)
	}
	health := httptest.NewRecorder()
	h.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if !strings.Contains(health.Body.String(), `"active_streams":12`) {
		t.Fatal(health.Body.String())
	}
	close(release)
	done.Wait()
	for _, recorder := range recorders {
		requireAck(t, recorder, 3)
	}
	if len(s.slots) != 0 {
		t.Fatalf("leaked slots=%d", len(s.slots))
	}
	ping := httptest.NewRecorder()
	h.ServeHTTP(ping, httptest.NewRequest(http.MethodGet, "/backend/empty.php", nil))
	if ping.Code != 200 || ping.Body.Len() != 0 {
		t.Fatal("empty ping compatibility lost")
	}
}

type partialWriter struct {
	header http.Header
	calls  int
	n      int
	err    error
	cancel context.CancelFunc
}

func (w *partialWriter) Header() http.Header { return w.header }
func (*partialWriter) WriteHeader(int)       {}
func (w *partialWriter) Write(p []byte) (int, error) {
	w.calls++
	if w.cancel != nil {
		w.cancel()
		return len(p), nil
	}
	return w.n, w.err
}

func TestDownloadShortWriteFailureAndCancellation(t *testing.T) {
	s := newServer(2, 12, 0)
	for _, tc := range []struct {
		name   string
		n      int
		err    error
		cancel bool
	}{
		{"short", 19, nil, false}, {"write error", 0, io.ErrClosedPipe, false}, {"cancel", 0, nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			w := &partialWriter{header: make(http.Header), n: tc.n, err: tc.err}
			if tc.cancel {
				w.cancel = cancel
			}
			s.download(w, httptest.NewRequest(http.MethodGet, "/backend/garbage.php?ckSize=2", nil).WithContext(ctx))
			if w.calls != 1 {
				t.Fatalf("continued after short/error/cancelled write: calls=%d", w.calls)
			}
		})
	}
	for _, query := range []string{"?ckSize=9999", "?ckSize=2"} {
		recorder := httptest.NewRecorder()
		s.download(recorder, httptest.NewRequest(http.MethodGet, "/backend/garbage.php"+query, nil))
		if recorder.Body.Len() != 2<<20 || recorder.Header().Get("Content-Length") != "2097152" {
			t.Fatal("download bound/length mismatch")
		}
		if !bytes.Equal(recorder.Body.Bytes()[:downloadBufferBytes], s.payload) {
			t.Fatal("download changed shared payload")
		}
	}
}

func TestMethodsHealthAndNonCachingAssets(t *testing.T) {
	s := newServer(75, 24, 0)
	h := testHandler(t, s)
	for _, method := range []string{http.MethodPut, http.MethodDelete, http.MethodPatch, "INVALID"} {
		recorder := httptest.NewRecorder()
		h.ServeHTTP(recorder, httptest.NewRequest(method, "/backend/empty.php", nil))
		if recorder.Code != 405 {
			t.Fatalf("%s returned %d", method, recorder.Code)
		}
	}
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodOptions} {
		recorder := httptest.NewRecorder()
		h.ServeHTTP(recorder, httptest.NewRequest(method, "/backend/empty.php", nil))
		want := 200
		if method == http.MethodOptions {
			want = 204
		}
		if recorder.Code != want || recorder.Body.Len() != 0 {
			t.Fatalf("%s changed: %d %s", method, recorder.Code, recorder.Body.String())
		}
	}
	for _, path := range []string{"/", "/index.html", "/results.html", "/speedtest.js", "/speedtest_worker.js", "/style.css", "/healthz"} {
		recorder := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.Header.Set("If-Modified-Since", "Wed, 09 Sep 2037 00:00:00 GMT")
		h.ServeHTTP(recorder, r)
		if !strings.Contains(recorder.Header().Get("Cache-Control"), "no-store") || recorder.Header().Get("Pragma") != "no-cache" {
			t.Fatalf("cacheable asset %s: %v", path, recorder.Header())
		}
		if path == "/index.html" { // FileServer's canonical redirect is also no-store.
			if recorder.Code != 301 {
				t.Fatalf("index redirect=%d", recorder.Code)
			}
		} else if recorder.Code != 200 {
			t.Fatalf("asset %s status=%d", path, recorder.Code)
		}
		if path == "/healthz" {
			var data map[string]any
			if err := json.Unmarshal(recorder.Body.Bytes(), &data); err != nil {
				t.Fatal(err)
			}
			if data["version"] != "1.2.0" || data["protocol"] != float64(3) || data["upload_session"] != true || data["max_download_mib"] != float64(75) || data["max_streams"] != float64(24) || data["tcp_congestion"] != "system" {
				t.Fatalf("capabilities=%v", data)
			}
		}
	}
}

func realServer(t *testing.T, s *server, completed chan<- struct{}) *httptest.Server {
	t.Helper()
	h := testHandler(t, s)
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.ServeHTTP(w, r)
		if completed != nil {
			completed <- struct{}{}
		}
	}))
	// Mirror main: the next keepalive request resets prior stream deadlines.
	srv.Config.ReadHeaderTimeout = time.Second
	srv.Config.ReadTimeout = streamTimeout
	srv.Config.WriteTimeout = streamTimeout + time.Second
	srv.Start()
	t.Cleanup(srv.Close)
	return srv
}

func connect(t *testing.T, srv *httptest.Server) *net.TCPConn {
	t.Helper()
	conn, err := net.DialTimeout("tcp", srv.Listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	tcp := conn.(*net.TCPConn)
	if err := tcp.SetDeadline(time.Now().Add(4 * time.Second)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tcp.Close() })
	return tcp
}

func TestRealHTTPUploadTruncationAndReadDeadline(t *testing.T) {
	for _, truncate := range []bool{true, false} {
		t.Run(fmt.Sprintf("truncated=%v", truncate), func(t *testing.T) {
			s := newServer(1, 12, 0)
			s.requestTimeout = 100 * time.Millisecond
			done := make(chan struct{}, 1)
			srv := realServer(t, s, done)
			conn := connect(t, srv)
			_, err := fmt.Fprint(conn, "POST /backend/empty.php?ack=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000\r\n\r\nabc")
			if err != nil {
				t.Fatal(err)
			}
			if truncate {
				if err := conn.CloseWrite(); err != nil {
					t.Fatal(err)
				}
			}
			response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodPost})
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			want := 408
			if truncate {
				want = 400
			}
			body, err := io.ReadAll(response.Body)
			if err != nil {
				t.Fatal(err)
			}
			if response.StatusCode != want || bytes.Contains(body, []byte(`"bytes"`)) {
				t.Fatalf("response=%d %s", response.StatusCode, body)
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("upload slot did not terminate")
			}
			if len(s.slots) != 0 {
				t.Fatal("upload slot leaked")
			}
		})
	}
}

func TestRealHTTPSlowDownloadAndDisconnectReleaseSlot(t *testing.T) {
	for _, disconnect := range []bool{false, true} {
		t.Run(fmt.Sprintf("disconnect=%v", disconnect), func(t *testing.T) {
			s := newServer(1024, 12, 0)
			s.requestTimeout = 100 * time.Millisecond
			done := make(chan struct{}, 1)
			srv := realServer(t, s, done)
			conn := connect(t, srv)
			if err := conn.SetReadBuffer(4096); err != nil {
				t.Fatal(err)
			}
			if _, err := fmt.Fprint(conn, "GET /backend/garbage.php?ckSize=1024 HTTP/1.1\r\nHost: localhost\r\n\r\n"); err != nil {
				t.Fatal(err)
			}
			response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodGet})
			if err != nil {
				t.Fatal(err)
			}
			if response.StatusCode != 200 {
				t.Fatal(response.StatusCode)
			}
			// Deliberately stop reading: writes must be bounded even without a
			// client cancellation. No 1 GiB response is allocated in this test.
			if disconnect {
				_ = conn.Close()
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("blocked download held stream slot")
			}
			if len(s.slots) != 0 {
				t.Fatal("download slot leaked")
			}
			_ = conn.Close()
			_ = response.Body.Close()
		})
	}
}

func TestRealHTTPKeepaliveAfterPriorRequestDeadline(t *testing.T) {
	s := newServer(1, 12, 0)
	s.requestTimeout = 100 * time.Millisecond
	srv := realServer(t, s, nil)
	conn := connect(t, srv)
	reader := bufio.NewReader(conn)
	for i := 0; i < 2; i++ {
		if _, err := fmt.Fprint(conn, "POST /backend/empty.php?ack=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc"); err != nil {
			t.Fatal(err)
		}
		response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodPost})
		if err != nil {
			t.Fatalf("keepalive request %d: %v", i, err)
		}
		body, err := io.ReadAll(response.Body)
		_ = response.Body.Close()
		if err != nil || response.StatusCode != 200 || strings.TrimSpace(string(body)) != `{"bytes":3}` {
			t.Fatalf("keepalive response %d: %d %s %v", i, response.StatusCode, body, err)
		}
		if i == 0 {
			time.Sleep(200 * time.Millisecond)
		}
	}
}
