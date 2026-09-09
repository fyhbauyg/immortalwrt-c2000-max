// SPDX-License-Identifier: LGPL-2.1-or-later
package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func deadlineRequest(id, owner string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1&session="+id, nil)
	r.RemoteAddr = net.JoinHostPort(owner, "41000")
	return r
}

func TestUploadSessionRequestDeadlineBoundsAndOwnership(t *testing.T) {
	s, clock := sessionTestServer()
	item, _ := s.uploadSessions.create("192.0.2.1", 2*time.Second, 30*time.Second)
	r := deadlineRequest(item.id, item.owner)
	if got := s.uploadRequestTimeout(r); got != 62*time.Second {
		t.Fatalf("waiting window bound=%s, want 62s", got)
	}
	clock.advance(10 * time.Second)
	if got := s.uploadRequestTimeout(r); got != 52*time.Second {
		t.Fatalf("elapsed first-byte wait was not deducted: %s", got)
	}
	item.addBytes(1)
	if got := s.uploadRequestTimeout(r); got != 37*time.Second {
		t.Fatalf("started window plus grace=%s, want 37s", got)
	}
	clock.advance(8 * time.Second)
	if got := s.uploadRequestTimeout(r); got != streamTimeout {
		t.Fatalf("legacy minimum changed for almost complete window: %s", got)
	}
	for name, req := range map[string]*http.Request{
		"ordinary":  httptest.NewRequest(http.MethodPost, "/backend/empty.php?ack=1", nil),
		"foreign":   deadlineRequest(item.id, "192.0.2.2"),
		"unknown":   deadlineRequest(strings.Repeat("f", 32), item.owner),
		"invalid":   deadlineRequest("invalid", item.owner),
		"duplicate": deadlineRequest(item.id+"&session="+item.id, item.owner),
		"get":       httptest.NewRequest(http.MethodGet, "/backend/empty.php?session="+item.id, nil),
	} {
		if got := s.uploadRequestTimeout(req); got != streamTimeout {
			t.Errorf("%s changed legacy timeout: %s", name, got)
		}
	}
	max, _ := s.uploadSessions.create("192.0.2.2", 5*time.Second, 120*time.Second)
	if got := s.uploadRequestTimeout(deadlineRequest(max.id, max.owner)); got != 155*time.Second {
		t.Fatalf("maximum API window not bounded at 155s: %s", got)
	}
	clock.advance(uploadSessionWaitTTL)
	if got := s.uploadRequestTimeout(deadlineRequest(max.id, max.owner)); got != streamTimeout {
		t.Fatalf("expired session extended request: %s", got)
	}
}

type sessionDeadlineRecorder struct {
	*httptest.ResponseRecorder
	read, write time.Time
}

func (w *sessionDeadlineRecorder) SetReadDeadline(t time.Time) error  { w.read = t; return nil }
func (w *sessionDeadlineRecorder) SetWriteDeadline(t time.Time) error { w.write = t; return nil }

func TestUploadSessionContextAndSocketDeadlinesAgree(t *testing.T) {
	s, _ := sessionTestServer()
	item, _ := s.uploadSessions.create("192.0.2.1", 2*time.Second, 30*time.Second)
	w := &sessionDeadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
	before := time.Now()
	s.withSlot(func(w http.ResponseWriter, r *http.Request) {
		deadline, ok := r.Context().Deadline()
		if !ok || deadline.Sub(before) < 61*time.Second || deadline.Sub(before) > 63*time.Second {
			t.Fatalf("wrong context deadline: %v, %v", deadline, ok)
		}
		if !deadline.Equal(w.(*sessionDeadlineRecorder).read) || !deadline.Add(time.Second).Equal(w.(*sessionDeadlineRecorder).write) {
			t.Fatal("context/read/write deadlines diverged")
		}
	})(w, deadlineRequest(item.id, item.owner))
	if len(s.slots) != 0 {
		t.Fatal("deadline setup leaked a transfer slot")
	}
}

// Real sockets prove that the per-request extension overrides the server's
// shorter ReadTimeout and WriteTimeout, not merely the context deadline.
func TestUploadSessionSlowBodyOverridesServerTimeouts(t *testing.T) {
	s := newServer(4, 12, 0)
	s.requestTimeout = 40 * time.Millisecond
	item, _ := s.uploadSessions.create("127.0.0.1", 0, time.Second)
	ts := httptest.NewUnstartedServer(testHandler(t, s))
	ts.Config.ReadTimeout = 40 * time.Millisecond
	ts.Config.WriteTimeout = 50 * time.Millisecond
	ts.Start()
	defer ts.Close()
	conn, err := net.DialTimeout("tcp", ts.Listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err = conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	_, err = fmt.Fprintf(conn, "POST /backend/empty.php?ack=1&session=%s HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nConnection: close\r\n\r\na", item.id)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(120 * time.Millisecond)
	if _, err = io.WriteString(conn, "b"); err != nil {
		t.Fatal(err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"bytes":2`) {
		t.Fatalf("progressing session body failed: %d %s", resp.StatusCode, body)
	}
	if len(s.slots) != 0 {
		t.Fatal("slow session upload leaked slot")
	}
}
