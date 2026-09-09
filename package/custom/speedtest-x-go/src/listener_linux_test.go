// SPDX-License-Identifier: LGPL-2.1-or-later
//go:build linux

package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func socketCongestion(t *testing.T, socket syscall.Conn) string {
	t.Helper()
	raw, err := socket.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var name [16]byte // TCP_CA_NAME_MAX from the Linux socket API.
	length := uint32(len(name))
	var optionErr syscall.Errno
	if err := raw.Control(func(fd uintptr) {
		_, _, optionErr = syscall.Syscall6(syscall.SYS_GETSOCKOPT, fd,
			uintptr(syscall.IPPROTO_TCP), uintptr(syscall.TCP_CONGESTION),
			uintptr(unsafe.Pointer(&name[0])), uintptr(unsafe.Pointer(&length)), 0)
	}); err != nil {
		t.Fatal(err)
	}
	if optionErr != 0 {
		t.Fatal(optionErr)
	}
	return strings.TrimRight(string(name[:]), "\x00")
}

func TestListenerCongestionInheritedAndSystemUnchanged(t *testing.T) {
	before, err := os.ReadFile("/proc/sys/net/ipv4/tcp_congestion_control")
	if err != nil {
		t.Fatal(err)
	}
	for _, algorithm := range []string{"cubic", "system"} {
		t.Run(algorithm, func(t *testing.T) {
			listener, err := listenSpeedtest(context.Background(), "127.0.0.1:0", algorithm)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			tcpListener := listener.(*net.TCPListener)
			if err := tcpListener.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
				t.Fatal(err)
			}
			want := algorithm
			if algorithm == "system" {
				want = strings.TrimSpace(string(before))
			}
			if got := socketCongestion(t, tcpListener); got != want {
				t.Fatalf("listener algorithm=%q, want %q", got, want)
			}
			client, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			accepted, err := tcpListener.AcceptTCP()
			if err != nil {
				t.Fatal(err)
			}
			defer accepted.Close()
			if got := socketCongestion(t, accepted); got != want {
				t.Fatalf("accepted algorithm=%q, want %q", got, want)
			}
			if got := socketCongestion(t, client.(*net.TCPConn)); got != strings.TrimSpace(string(before)) {
				t.Fatalf("service unexpectedly changed client algorithm to %q", got)
			}
		})
	}
	after, err := os.ReadFile("/proc/sys/net/ipv4/tcp_congestion_control")
	if err != nil || string(after) != string(before) {
		t.Fatalf("system congestion default changed: before=%q after=%q err=%v", before, after, err)
	}
}

func TestListenerRejectsInvalidCongestion(t *testing.T) {
	for _, algorithm := range []string{"", "bbr", "CUBIC", "cubic ", "invalid"} {
		listener, err := listenSpeedtest(context.Background(), "127.0.0.1:0", algorithm)
		if listener != nil {
			listener.Close()
			t.Fatalf("invalid algorithm %q created a listener", algorithm)
		}
		if err == nil || !strings.Contains(err.Error(), "expected cubic or system") {
			t.Fatalf("invalid algorithm %q: err=%v", algorithm, err)
		}
	}
}

func TestListenerSocketOptionFailureDoesNotFallback(t *testing.T) {
	var config net.ListenConfig
	// Exercise a real kernel rejection below public argument validation.
	if err := configureTCPCongestion(&config, "no_such_cc"); err != nil {
		t.Fatal(err)
	}
	listener, err := config.Listen(context.Background(), "tcp", "127.0.0.1:0")
	if listener != nil {
		listener.Close()
		t.Fatal("failed congestion selection fell back to a working listener")
	}
	if err == nil || !strings.Contains(err.Error(), `set TCP_CONGESTION="no_such_cc"`) {
		t.Fatalf("missing useful socket-option error: %v", err)
	}
}

func TestConfiguredListenerHTTPShutdownClosesSockets(t *testing.T) {
	listener, err := listenSpeedtest(context.Background(), "127.0.0.1:0", "cubic")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	app := newServer(1, 12, 0)
	app.tcpCongestion = "cubic"
	server := &http.Server{Handler: testHandler(t, app)}
	defer server.Close()
	served := make(chan error, 1)
	go func() { served <- server.Serve(listener) }()
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	response, err := client.Get("http://" + listener.Addr().String() + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	body, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if readErr != nil || !strings.Contains(string(body), `"tcp_congestion":"cubic"`) {
		t.Fatalf("health metadata: body=%s err=%v", body, readErr)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-served:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("Serve returned %v", err)
		}
	case <-ctx.Done():
		t.Fatal("Serve did not exit after Shutdown")
	}
	connection, err := net.DialTimeout("tcp", listener.Addr().String(), 200*time.Millisecond)
	if err == nil {
		connection.Close()
		t.Fatal("listener still accepts connections after Shutdown")
	}
}
