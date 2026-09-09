// SPDX-License-Identifier: LGPL-2.1-or-later
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type uploadTestClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *uploadTestClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *uploadTestClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func sessionTestServer() (*server, *uploadTestClock) {
	s := newServer(4, 12, 0)
	c := &uploadTestClock{t: time.Unix(1700000000, 0)}
	s.uploadSessions.now = c.now
	return s, c
}

func sessionRequest(h http.Handler, method, target, owner string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	r := httptest.NewRequest(method, target, nil)
	r.RemoteAddr = net.JoinHostPort(owner, "40000")
	h.ServeHTTP(w, r)
	return w
}

func decodeUploadSession(t *testing.T, body io.Reader) uploadSessionSnapshot {
	t.Helper()
	var value uploadSessionSnapshot
	if err := json.NewDecoder(body).Decode(&value); err != nil {
		t.Fatal(err)
	}
	if !validUploadSessionID(value.ID) {
		t.Fatalf("invalid session ID %q", value.ID)
	}
	return value
}

func TestUploadSessionFixedWindowAndDelayedObservation(t *testing.T) {
	s, clock := sessionTestServer()
	item, status := s.uploadSessions.create("192.0.2.10", time.Second, 2*time.Second)
	if status != 200 {
		t.Fatal(status)
	}
	if got := item.snapshot(); got.State != "waiting" || got.Bytes != 0 || got.ElapsedMS != 0 || got.RemainingMS != 3000 {
		t.Fatalf("waiting: %+v", got)
	}
	clock.advance(9 * time.Second) // creation time is NOT the measurement start
	item.addBytes(101)             // first body bytes start warmup and are excluded
	if got := item.snapshot(); got.State != "warmup" || got.Bytes != 0 || got.RemainingMS != 3000 {
		t.Fatalf("warmup: %+v", got)
	}
	clock.advance(time.Second - time.Nanosecond)
	item.addBytes(103)
	clock.advance(time.Nanosecond)
	item.addBytes(107) // start inclusive
	if got := item.snapshot(); got.State != "measuring" || got.Bytes != 107 || got.ElapsedMS != 0 || got.RemainingMS != 2000 {
		t.Fatalf("start edge: %+v", got)
	}
	clock.advance(2*time.Second - time.Nanosecond)
	item.addBytes(109)
	clock.advance(time.Nanosecond)
	item.addBytes(113) // end exclusive
	final := item.snapshot()
	if final.State != "done" || final.Bytes != 216 || final.ElapsedMS != 2000 || final.RemainingMS != 0 {
		t.Fatalf("end edge: %+v", final)
	}
	clock.advance(3 * time.Second) // delayed browser status/ACK, unchanged denominator
	item.addBytes(1000000)
	if got := item.snapshot(); got != final {
		t.Fatalf("tail affected final result: before=%+v after=%+v", final, got)
	}
}

func TestUploadSessionConcurrentStreamsAndDelete(t *testing.T) {
	s, _ := sessionTestServer()
	item, status := s.uploadSessions.create("192.0.2.1", 0, time.Second)
	if status != 200 {
		t.Fatal(status)
	}
	var wg sync.WaitGroup
	for stream := 0; stream < 8; stream++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				item.addBytes(131072)
				_ = item.snapshot()
			}
		}()
	}
	wg.Wait()
	if got := item.snapshot(); got.Bytes != 8*1000*131072 || got.State != "measuring" {
		t.Fatalf("concurrent count: %+v", got)
	}
	if code := s.uploadSessions.remove(item.id, "192.0.2.2"); code != 403 {
		t.Fatal(code)
	}
	before := item.snapshot().Bytes
	if code := s.uploadSessions.remove(item.id, "192.0.2.1"); code != 204 {
		t.Fatal(code)
	}
	item.addBytes(99)
	if item.snapshot().Bytes != before {
		t.Fatal("deleted session accepted more bytes")
	}
	if code := s.uploadSessions.remove(item.id, "192.0.2.1"); code != 204 {
		t.Fatal("delete is not idempotent")
	}
}

func TestUploadSessionLimitsAndTTL(t *testing.T) {
	s, clock := sessionTestServer()
	a, _ := s.uploadSessions.create("192.0.2.1", 0, time.Second)
	s.uploadSessions.create("192.0.2.1", 0, time.Second)
	if _, status := s.uploadSessions.create("192.0.2.1", 0, time.Second); status != 429 {
		t.Fatal("per-IP quota not enforced", status)
	}
	clock.advance(uploadSessionWaitTTL)
	if _, status := s.uploadSessions.lookup(a.id, a.owner); status != 404 {
		t.Fatal("waiting session did not expire", status)
	}
	a, _ = s.uploadSessions.create("192.0.2.1", 0, time.Second)
	a.addBytes(5)
	clock.advance(time.Second + uploadSessionDoneTTL - time.Nanosecond)
	if _, status := s.uploadSessions.lookup(a.id, a.owner); status != 200 {
		t.Fatal("finished result expired too early", status)
	}
	clock.advance(time.Nanosecond)
	if _, status := s.uploadSessions.lookup(a.id, a.owner); status != 404 {
		t.Fatal("finished session did not expire", status)
	}
	for i := 0; i < uploadSessionMaxTotal; i++ {
		if _, status := s.uploadSessions.create(fmt.Sprintf("192.0.2.%d", i+1), 0, time.Second); status != 200 {
			t.Fatalf("session %d: %d", i, status)
		}
	}
	if _, status := s.uploadSessions.create("198.51.100.1", 0, time.Second); status != 429 {
		t.Fatal("global quota not enforced", status)
	}
}

func TestUploadSessionControlValidationOwnerAndSlots(t *testing.T) {
	s, _ := sessionTestServer()
	h := testHandler(t, s)
	for _, query := range []string{
		"?warmup_ms=-1", "?warmup_ms=5001", "?warmup_ms=1&warmup_ms=2",
		"?duration_ms=999", "?duration_ms=120001", "?duration_ms=1e4",
		"?duration_ms=+1000", "?duration_ms=", "?id=",
	} {
		w := sessionRequest(h, http.MethodPost, "/backend/upload-session"+query, "192.0.2.1")
		if w.Code != 400 {
			t.Fatalf("%s: %d %s", query, w.Code, w.Body)
		}
	}
	for i := 0; i < cap(s.slots); i++ {
		s.slots <- struct{}{}
	}
	w := sessionRequest(h, http.MethodPost, "/backend/upload-session?warmup_ms=0&duration_ms=1000", "192.0.2.1")
	if w.Code != 200 {
		t.Fatalf("control depends on transfer slots: %d %s", w.Code, w.Body)
	}
	value := decodeUploadSession(t, w.Body)
	target := "/backend/upload-session?id=" + value.ID
	if got := sessionRequest(h, http.MethodGet, target, "192.0.2.2"); got.Code != 404 {
		t.Fatal("foreign owner queried session", got.Code)
	}
	if got := sessionRequest(h, http.MethodDelete, target, "192.0.2.2"); got.Code != 403 {
		t.Fatal("foreign owner deleted session", got.Code)
	}
	if got := sessionRequest(h, http.MethodGet, target, "192.0.2.1"); got.Code != 200 {
		t.Fatal("same owner cannot read session", got.Code)
	}
	for range 2 {
		if got := sessionRequest(h, http.MethodDelete, target, "192.0.2.1"); got.Code != 204 {
			t.Fatal("delete/duplicate delete failed", got.Code)
		}
	}
	if got := sessionRequest(h, http.MethodOptions, "/backend/upload-session", "192.0.2.1"); got.Code != 204 || !strings.Contains(got.Header().Get("Access-Control-Allow-Methods"), "DELETE") {
		t.Fatal("control preflight missing DELETE")
	}
}

type uploadTimedRead struct {
	clock *uploadTestClock
	step  int
}

func (r *uploadTimedRead) Read(p []byte) (int, error) {
	r.step++
	switch r.step {
	case 1:
		return copy(p, "warmup"), nil
	case 2:
		r.clock.advance(time.Second)
		return copy(p, "received"), io.ErrUnexpectedEOF
	default:
		return 0, io.EOF
	}
}
func (r *uploadTimedRead) Close() error { return nil }

func TestUploadSessionPartialReadCountsButNeverCompleteACK(t *testing.T) {
	s, clock := sessionTestServer()
	item, _ := s.uploadSessions.create("192.0.2.1", time.Second, time.Second)
	r := httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1&session="+item.id, nil)
	r.RemoteAddr = "192.0.2.1:9000"
	r.Body = &uploadTimedRead{clock: clock}
	r.ContentLength = 999
	w := httptest.NewRecorder()
	testHandler(t, s).ServeHTTP(w, r)
	if w.Code != 400 || strings.Contains(w.Body.String(), `"bytes"`) {
		t.Fatalf("truncated body was ACKed: %d %s", w.Code, w.Body)
	}
	if got := item.snapshot(); got.Bytes != 8 || got.State != "measuring" {
		t.Fatalf("actual partial bytes lost: %+v", got)
	}
	for _, bad := range []string{"", "a", strings.Repeat("f", 32), item.id + "&session=" + item.id} {
		r = httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1&session="+bad, strings.NewReader("payload"))
		r.RemoteAddr = "192.0.2.1:9000"
		w = httptest.NewRecorder()
		testHandler(t, s).ServeHTTP(w, r)
		if w.Code != 400 && w.Code != 404 {
			t.Fatalf("invalid/unknown session accepted: %d %s", w.Code, w.Body)
		}
	}
}

func TestUploadSessionRealHTTPAckAbortAndFrozenResult(t *testing.T) {
	s, clock := sessionTestServer()
	ts := httptest.NewServer(testHandler(t, s))
	defer ts.Close()
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Post(ts.URL+"/backend/upload-session?warmup_ms=0&duration_ms=1000", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	value := decodeUploadSession(t, resp.Body)
	resp.Body.Close()
	resp, err = client.Post(ts.URL+"/backend/empty.php?ack=1&session="+value.ID, "application/octet-stream", strings.NewReader(strings.Repeat("x", 10000)))
	if err != nil {
		t.Fatal(err)
	}
	var ack struct {
		Bytes       int64                 `json:"bytes"`
		Measurement uploadSessionSnapshot `json:"measurement"`
	}
	if err = json.NewDecoder(resp.Body).Decode(&ack); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if ack.Bytes != 10000 || ack.Measurement.Bytes != 10000 || ack.Measurement.ID != value.ID {
		t.Fatalf("real ACK: %+v", ack)
	}
	conn, err := net.DialTimeout("tcp", ts.Listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	_, err = fmt.Fprintf(conn, "POST /backend/empty.php?ack=1&session=%s HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n%s", value.ID, strings.Repeat("z", 1024))
	if err != nil {
		t.Fatal(err)
	}
	conn.(*net.TCPConn).CloseWrite()
	partial, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, partial.Body)
	partial.Body.Close()
	if partial.StatusCode != 400 {
		t.Fatal("partial request did not fail", partial.StatusCode)
	}
	item, status := s.uploadSessions.lookup(value.ID, "127.0.0.1")
	if status != 200 || item.snapshot().Bytes != 11024 {
		t.Fatalf("aborted TCP bytes lost: %d %+v", status, item.snapshot())
	}
	clock.advance(time.Second)
	final := item.snapshot()
	clock.advance(2 * time.Second)
	resp, err = client.Get(ts.URL + "/backend/upload-session?id=" + value.ID)
	if err != nil {
		t.Fatal(err)
	}
	got := decodeUploadSession(t, resp.Body)
	resp.Body.Close()
	if got != final || got.State != "done" || got.ElapsedMS != 1000 || got.Bytes != 11024 {
		t.Fatalf("delayed status changed fixed window: %+v vs %+v", got, final)
	}
	if len(s.slots) != 0 {
		t.Fatal("aborted/complete upload leaked transfer slots")
	}
}
