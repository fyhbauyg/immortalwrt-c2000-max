// SPDX-License-Identifier: LGPL-2.1-or-later
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"
)

const (
	uploadSessionMaxTotal = 32
	uploadSessionMaxPerIP = 2
	uploadSessionWaitTTL  = 30 * time.Second
	uploadSessionDoneTTL  = 10 * time.Second
)

// A session measures only bytes actually returned by the server's body Read.
// Monotonic time is shared by all streams and is never supplied by the browser.
// Read completion time decides which side of a window boundary receives a
// chunk. Thus the boundary uncertainty is at most one 128 KiB read per stream
// per edge, not an entire Blob or the browser/OS send-buffer contents.
// Final ACK delivery and tail drain do not extend the measurement window.
type uploadSession struct {
	mu       sync.Mutex
	id       string
	owner    string
	created  time.Time
	started  time.Time
	warmup   time.Duration
	duration time.Duration
	bytes    int64
	closed   bool
	now      func() time.Time
}

type uploadSessionSnapshot struct {
	ID          string  `json:"id"`
	State       string  `json:"state"`
	Bytes       int64   `json:"bytes"`
	ElapsedMS   float64 `json:"elapsed_ms"`
	RemainingMS int64   `json:"remaining_ms"`
	WarmupMS    int64   `json:"warmup_ms"`
	DurationMS  int64   `json:"duration_ms"`
}

func (s *uploadSession) expiryLocked() time.Time {
	if s.started.IsZero() {
		return s.created.Add(uploadSessionWaitTTL)
	}
	return s.started.Add(s.warmup + s.duration + uploadSessionDoneTTL)
}

func (s *uploadSession) expired(now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed || !now.Before(s.expiryLocked())
}

func (s *uploadSession) addBytes(n int) {
	if n <= 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if s.closed || !now.Before(s.expiryLocked()) {
		return
	}
	if s.started.IsZero() {
		s.started = now
	}
	start := s.started.Add(s.warmup)
	end := start.Add(s.duration)
	if !now.Before(start) && now.Before(end) {
		s.bytes += int64(n)
	}
}

func durationCeilMS(d time.Duration) int64 {
	if d <= 0 {
		return 0
	}
	return int64((d + time.Millisecond - 1) / time.Millisecond)
}

func (s *uploadSession) snapshot() uploadSessionSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	value := uploadSessionSnapshot{
		ID: s.id, State: "waiting", Bytes: s.bytes,
		WarmupMS: s.warmup.Milliseconds(), DurationMS: s.duration.Milliseconds(),
		RemainingMS: durationCeilMS(s.warmup + s.duration),
	}
	if s.started.IsZero() {
		return value
	}
	start := s.started.Add(s.warmup)
	end := start.Add(s.duration)
	value.RemainingMS = durationCeilMS(end.Sub(now))
	switch {
	case now.Before(start):
		value.State = "warmup"
	case now.Before(end):
		value.State = "measuring"
		value.ElapsedMS = float64(now.Sub(start)) / float64(time.Millisecond)
	default:
		value.State = "done"
		value.ElapsedMS = float64(s.duration) / float64(time.Millisecond)
	}
	return value
}

type uploadSessionReader struct {
	reader  io.Reader
	session *uploadSession
}

func (r uploadSessionReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	r.session.addBytes(n)
	return n, err
}

type uploadSessionStore struct {
	mu       sync.Mutex
	sessions map[string]*uploadSession
	now      func() time.Time
}

func newUploadSessionStore() *uploadSessionStore {
	return &uploadSessionStore{sessions: make(map[string]*uploadSession), now: time.Now}
}

func validUploadSessionID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// Called under the store lock. No timer/goroutine or per-packet store lock is
// needed: creation, control access and new POSTs reclaim expired sessions.
func (s *uploadSessionStore) pruneLocked(now time.Time) {
	for id, item := range s.sessions {
		if item.expired(now) {
			delete(s.sessions, id)
		}
	}
}

func (s *uploadSessionStore) create(owner string, warmup, duration time.Duration) (*uploadSession, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.pruneLocked(now)
	if len(s.sessions) >= uploadSessionMaxTotal {
		return nil, http.StatusTooManyRequests
	}
	count := 0
	for _, item := range s.sessions {
		if item.owner == owner {
			count++
		}
	}
	if count >= uploadSessionMaxPerIP {
		return nil, http.StatusTooManyRequests
	}
	for attempts := 0; attempts < 3; attempts++ {
		var token [16]byte
		if _, err := rand.Read(token[:]); err != nil {
			return nil, http.StatusInternalServerError
		}
		id := hex.EncodeToString(token[:])
		if _, found := s.sessions[id]; found {
			continue
		}
		item := &uploadSession{id: id, owner: owner, created: now, warmup: warmup, duration: duration, now: s.now}
		s.sessions[id] = item
		return item, http.StatusOK
	}
	return nil, http.StatusInternalServerError
}

func (s *uploadSessionStore) lookup(id, owner string) (*uploadSession, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(s.now())
	item := s.sessions[id]
	if item == nil || item.owner != owner {
		return nil, http.StatusNotFound
	}
	return item, http.StatusOK
}

func (s *uploadSessionStore) remove(id, owner string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(s.now())
	item := s.sessions[id]
	if item == nil {
		return http.StatusNoContent
	}
	if item.owner != owner {
		return http.StatusForbidden
	}
	item.mu.Lock()
	item.closed = true
	item.mu.Unlock()
	delete(s.sessions, id)
	return http.StatusNoContent
}

func uploadMilliseconds(q url.Values, key string, fallback, max, min int64) (time.Duration, bool) {
	values, present := q[key]
	if !present {
		return time.Duration(fallback) * time.Millisecond, true
	}
	if len(values) != 1 || values[0] == "" {
		return 0, false
	}
	for _, c := range values[0] {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(values[0], 10, 64)
	if err != nil || n < min || n > max {
		return 0, false
	}
	return time.Duration(n) * time.Millisecond, true
}

func (s *server) uploadSessionControl(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	w.Header().Set("Allow", "GET, POST, DELETE, OPTIONS")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	q := r.URL.Query()
	if r.Method == http.MethodPost {
		if _, present := q["id"]; present || r.ContentLength != 0 {
			http.Error(w, "session creation expects query parameters and no body", http.StatusBadRequest)
			return
		}
		warmup, okWarmup := uploadMilliseconds(q, "warmup_ms", 1000, 5000, 0)
		duration, okDuration := uploadMilliseconds(q, "duration_ms", 15000, 120000, 1000)
		if !okWarmup || !okDuration {
			http.Error(w, "invalid upload window", http.StatusBadRequest)
			return
		}
		item, status := s.uploadSessions.create(clientIP(r), warmup, duration)
		if status != http.StatusOK {
			http.Error(w, "upload session limit or creation failure", status)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(item.snapshot())
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	ids := q["id"]
	if len(ids) != 1 || !validUploadSessionID(ids[0]) {
		http.Error(w, "invalid upload session", http.StatusBadRequest)
		return
	}
	if r.Method == http.MethodDelete {
		status := s.uploadSessions.remove(ids[0], clientIP(r))
		if status != http.StatusNoContent {
			http.Error(w, "upload session unavailable", status)
			return
		}
		w.WriteHeader(status)
		return
	}
	item, status := s.uploadSessions.lookup(ids[0], clientIP(r))
	if status != http.StatusOK {
		http.Error(w, "upload session unavailable", status)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(item.snapshot())
}
