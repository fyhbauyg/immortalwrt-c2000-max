// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Lightweight Go backend compatible with the LibreSpeed/Speedtest-X Web UI.
// The bundled Speedtest-X assets retain their original license and notices.
package main

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	version                        = "1.2.0"
	protocolVersion                = 3
	defaultDownloadMiB             = 50
	maxUploadBody                  = 256 << 20
	downloadBufferBytes            = 256 << 10
	uploadBufferBytes              = 128 << 10
	streamTimeout                  = 30 * time.Second
	uploadSessionMaxRequestTimeout = 155 * time.Second
)

//go:embed web/*
var embeddedWeb embed.FS

type result struct {
	Key       string    `json:"key"`
	IP        string    `json:"ip"`
	ISP       string    `json:"isp"`
	Address   string    `json:"addr"`
	Download  string    `json:"download"`
	Upload    string    `json:"upload"`
	Ping      string    `json:"ping"`
	Jitter    string    `json:"jitter"`
	UpdatedAt time.Time `json:"updated_at"`
}

type history struct {
	mu      sync.RWMutex
	limit   int
	results []result
}

func (h *history) update(item result) {
	if h.limit <= 0 {
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	for i := range h.results {
		if h.results[i].Key == item.Key {
			h.results[i] = item
			return
		}
	}

	h.results = append([]result{item}, h.results...)
	if len(h.results) > h.limit {
		h.results = h.results[:h.limit]
	}
}

func (h *history) snapshot() []result {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]result, len(h.results))
	copy(out, h.results)
	return out
}

type server struct {
	maxDownloadMiB int64
	slots          chan struct{}
	payload        []byte
	history        *history
	uploadBuffers  sync.Pool
	uploadSessions *uploadSessionStore
	requestTimeout time.Duration
	tcpCongestion  string
}

func newServer(maxDownloadMiB, maxClients, historyLimit int) *server {
	if maxDownloadMiB < 1 {
		maxDownloadMiB = defaultDownloadMiB
	}
	if maxDownloadMiB > 1024 {
		maxDownloadMiB = 1024
	}
	if maxClients < 12 {
		maxClients = 12
	}
	if maxClients > 128 {
		maxClients = 128
	}
	if historyLimit < 0 {
		historyLimit = 0
	}
	if historyLimit > 1000 {
		historyLimit = 1000
	}

	payload := make([]byte, downloadBufferBytes)
	if _, err := rand.Read(payload); err != nil {
		for i := range payload {
			payload[i] = byte((i*131 + 17) & 0xff)
		}
	}

	s := &server{
		maxDownloadMiB: int64(maxDownloadMiB),
		slots:          make(chan struct{}, maxClients),
		payload:        payload,
		history:        &history{limit: historyLimit},
		requestTimeout: streamTimeout,
		tcpCongestion:  "system",
		uploadSessions: newUploadSessionStore(),
	}
	s.uploadBuffers.New = func() any {
		buffer := make([]byte, uploadBufferBytes)
		return &buffer
	}
	return s
}

func noCache(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Expires", "0")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
}

// A fixed-window upload may legitimately keep one body open longer than the
// legacy 30-second request limit. Only an existing session owned by this peer
// can extend the limit. The same bound is applied to context and socket I/O.
func (s *server) uploadRequestTimeout(r *http.Request) time.Duration {
	timeout := s.requestTimeout
	if r.Method != http.MethodPost || r.URL.Path != "/backend/empty.php" {
		return timeout
	}
	ids := r.URL.Query()["session"]
	if len(ids) != 1 || !validUploadSessionID(ids[0]) {
		return timeout
	}
	item, status := s.uploadSessions.lookup(ids[0], clientIP(r))
	if status != http.StatusOK {
		return timeout // empty() preserves the normal validation/error response
	}
	item.mu.Lock()
	defer item.mu.Unlock()
	now := item.now()
	if item.closed || !now.Before(item.expiryLocked()) {
		return timeout
	}
	var remaining time.Duration
	if item.started.IsZero() {
		// The first body byte starts the clock; its wait is itself bounded.
		remaining = item.expiryLocked().Sub(now) + item.warmup + item.duration
	} else {
		remaining = item.started.Add(item.warmup+item.duration).Sub(now) + 5*time.Second
	}
	if remaining > uploadSessionMaxRequestTimeout {
		remaining = uploadSessionMaxRequestTimeout
	}
	if remaining > timeout {
		return remaining
	}
	return timeout
}

func (s *server) withSlot(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		noCache(w)
		if r.Context().Err() != nil {
			http.Error(w, "request cancelled", http.StatusRequestTimeout)
			return
		}
		select {
		case s.slots <- struct{}{}:
			defer func() { <-s.slots }()
			ctx, cancel := context.WithTimeout(r.Context(), s.uploadRequestTimeout(r))
			defer cancel()
			deadline, _ := ctx.Deadline()
			controller := http.NewResponseController(w)
			// A context check alone cannot interrupt a blocked socket Read/Write.
			// Keep the write deadline in force through net/http's final flush.
			// Server Read/WriteTimeout resets deadlines for the next request.
			if err := controller.SetReadDeadline(deadline); err != nil && !errors.Is(err, http.ErrNotSupported) {
				http.Error(w, "cannot bound request", http.StatusInternalServerError)
				return
			}
			writeDeadline := deadline
			if r.Method == http.MethodPost {
				// Allow a bounded error response after a timed-out upload read.
				writeDeadline = deadline.Add(time.Second)
			}
			if err := controller.SetWriteDeadline(writeDeadline); err != nil && !errors.Is(err, http.ErrNotSupported) {
				http.Error(w, "cannot bound response", http.StatusInternalServerError)
				return
			}
			next(w, r.WithContext(ctx))
		case <-r.Context().Done():
			http.Error(w, "request cancelled", http.StatusRequestTimeout)
			return
		default:
			http.Error(w, "speed-test server busy", http.StatusServiceUnavailable)
		}
	}
}

func (s *server) download(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	sizeMiB := int64(defaultDownloadMiB)
	if value := r.URL.Query().Get("ckSize"); value != "" {
		if parsed, err := strconv.ParseInt(value, 10, 64); err == nil {
			sizeMiB = parsed
		}
	}
	if sizeMiB < 1 {
		sizeMiB = 1
	}
	if sizeMiB > s.maxDownloadMiB {
		sizeMiB = s.maxDownloadMiB
	}
	remaining := sizeMiB << 20

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(remaining, 10))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method == http.MethodHead {
		return
	}

	for remaining > 0 {
		if r.Context().Err() != nil {
			return
		}
		chunk := int64(len(s.payload))
		if remaining < chunk {
			chunk = remaining
		}
		n, err := w.Write(s.payload[:chunk])
		if err != nil || n != int(chunk) {
			// A short or failed write is not a completed chunk. Leaving the
			// advertised Content-Length incomplete makes the client reject it.
			return
		}
		remaining -= int64(n)
	}
}

// Unlike io.Discard, this sink has no ReaderFrom fast path that silently
// substitutes its own buffer for the 128 KiB buffer supplied to CopyBuffer.
type discardSink struct{}

func (discardSink) Write(p []byte) (int, error) { return len(p), nil }

// Hide WriterTo on the source as well, and stop between body reads on cancel.
type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	n, err := r.r.Read(p)
	// net/http may cancel the request context while reporting a truncated
	// Content-Length body. Preserve the concrete read error (400), instead
	// of replacing it with context.Canceled (408).
	if err != nil && err != io.EOF {
		return n, err
	}
	if cancelled := r.ctx.Err(); cancelled != nil {
		return n, cancelled
	}
	return n, err
}

func (s *server) empty(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, HEAD, POST, OPTIONS")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.ContentLength > maxUploadBody {
		http.Error(w, "upload too large", http.StatusRequestEntityTooLarge)
		return
	}
	var session *uploadSession
	if values, present := r.URL.Query()["session"]; present {
		if len(values) != 1 || !validUploadSessionID(values[0]) {
			http.Error(w, "invalid upload session", http.StatusBadRequest)
			return
		}
		var status int
		session, status = s.uploadSessions.lookup(values[0], clientIP(r))
		if status != http.StatusOK {
			http.Error(w, "upload session unavailable", status)
			return
		}
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBody)
	buffer := s.uploadBuffers.Get().(*[]byte)
	defer s.uploadBuffers.Put(buffer)
	var source io.Reader = contextReader{r.Context(), r.Body}
	if session != nil {
		// Count n even when the same Read reports EOF/cancellation/truncation.
		// Such partial body data reached the receiver; it is not a complete ACK.
		source = uploadSessionReader{reader: source, session: session}
	}
	n, err := io.CopyBuffer(discardSink{}, source, *buffer)
	if err == nil && r.ContentLength >= 0 && n != r.ContentLength {
		err = io.ErrUnexpectedEOF
	}
	if err == nil {
		err = r.Context().Err()
	}
	if err != nil {
		status := http.StatusBadRequest
		var tooLarge *http.MaxBytesError
		var networkError net.Error
		switch {
		case errors.As(err, &tooLarge):
			status = http.StatusRequestEntityTooLarge
		case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
			status = http.StatusRequestTimeout
		case errors.As(err, &networkError) && networkError.Timeout():
			status = http.StatusRequestTimeout
		}
		http.Error(w, "upload not completed", status)
		return
	}
	if r.URL.Query().Get("ack") == "1" {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		var snapshot *uploadSessionSnapshot
		if session != nil {
			value := session.snapshot()
			snapshot = &value
		}
		_ = json.NewEncoder(w).Encode(struct {
			Bytes       int64                  `json:"bytes"`
			Measurement *uploadSessionSnapshot `json:"measurement,omitempty"`
		}{Bytes: n, Measurement: snapshot})
		return
	}
	w.WriteHeader(http.StatusOK)
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return strings.Trim(r.RemoteAddr, "[]")
}

func (s *server) getIP(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	ip := clientIP(r)
	if r.URL.Query().Get("isp") == "true" {
		fmt.Fprintf(w, "%s - LAN - C2000-MAX", ip)
		return
	}
	io.WriteString(w, ip)
}

func safeField(value string, max int) string {
	value = strings.TrimSpace(value)
	if len(value) > max {
		value = value[:max]
	}
	return value
}

func (s *server) report(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", http.StatusBadRequest)
		return
	}
	key := safeField(r.FormValue("key"), 160)
	if key == "" {
		key = strconv.FormatInt(time.Now().UnixNano(), 10) + "_" + clientIP(r)
	}
	item := result{
		Key:       key,
		IP:        safeField(r.FormValue("ip"), 96),
		ISP:       safeField(r.FormValue("isp"), 96),
		Address:   safeField(r.FormValue("addr"), 128),
		Download:  safeField(r.FormValue("dspeed"), 32),
		Upload:    safeField(r.FormValue("uspeed"), 32),
		Ping:      safeField(r.FormValue("ping"), 32),
		Jitter:    safeField(r.FormValue("jitter"), 32),
		UpdatedAt: time.Now(),
	}
	if item.IP == "" {
		item.IP = clientIP(r)
	}
	s.history.update(item)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	io.WriteString(w, "{\"ok\":true}")
}

func (s *server) results(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(s.history.snapshot())
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	noCache(w)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(struct {
		OK             bool   `json:"ok"`
		Version        string `json:"version"`
		Protocol       int    `json:"protocol"`
		ActiveStreams  int    `json:"active_streams"`
		MaxDownloadMiB int64  `json:"max_download_mib"`
		MaxStreams     int    `json:"max_streams"`
		TCPCongestion  string `json:"tcp_congestion"`
		UploadSession  bool   `json:"upload_session"`
	}{true, version, protocolVersion, len(s.slots), s.maxDownloadMiB, cap(s.slots), s.tcpCongestion, true})
}

func (s *server) handler() (http.Handler, error) {
	webRoot, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		return nil, err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/backend/garbage.php", s.withSlot(s.download))
	mux.HandleFunc("/backend/empty.php", s.withSlot(s.empty))
	mux.HandleFunc("/backend/upload-session", s.uploadSessionControl)
	mux.HandleFunc("/backend/getIP.php", s.getIP)
	mux.HandleFunc("/backend/report.php", s.report)
	mux.HandleFunc("/backend/results-api.php", s.results)
	mux.HandleFunc("/healthz", s.health)
	mux.Handle("/", http.FileServer(http.FS(webRoot)))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// HTML and worker JS must match this backend's ACK protocol too.
		noCache(w)
		mux.ServeHTTP(w, r)
	}), nil
}

func main() {
	var (
		listen         = flag.String("listen", "0.0.0.0:9001", "HTTP listen address")
		tcpCongestion  = flag.String("tcp-congestion", "cubic", "TCP congestion control for this service only: cubic or system")
		maxDownloadMiB = flag.Int("max-download-mb", defaultDownloadMiB, "maximum download response size in MiB")
		maxClients     = flag.Int("max-clients", 24, "maximum simultaneous upload/download streams")
		historyLimit   = flag.Int("history-limit", 100, "maximum in-memory result records; zero disables history")
		showVersion    = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	app := newServer(*maxDownloadMiB, *maxClients, *historyLimit)
	handler, err := app.handler()
	if err != nil {
		log.Fatal(err)
	}

	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       streamTimeout,
		WriteTimeout:      streamTimeout + time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	listener, err := listenSpeedtest(ctx, *listen, *tcpCongestion)
	if err != nil {
		log.Fatalf("cannot start Speedtest-X listener: %v; use -tcp-congestion system to inherit the kernel default", err)
	}
	defer listener.Close()
	app.tcpCongestion = *tcpCongestion
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("Speedtest-X Go %s listening on %s (TCP congestion: %s, service sockets only)", version, listener.Addr(), *tcpCongestion)
	err = httpServer.Serve(listener)
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
