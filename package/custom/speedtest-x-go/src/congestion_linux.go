// SPDX-License-Identifier: LGPL-2.1-or-later
//go:build linux

package main

import (
	"fmt"
	"net"
	"syscall"
)

func configureTCPCongestion(config *net.ListenConfig, algorithm string) error {
	// Linux carries an explicitly chosen listener algorithm into accepted
	// sockets. This changes this service's sending behavior only; client upload
	// congestion control and the system-wide default remain independent.
	config.Control = func(network, address string, connection syscall.RawConn) error {
		var optionErr error
		if err := connection.Control(func(fd uintptr) {
			optionErr = syscall.SetsockoptString(int(fd), syscall.IPPROTO_TCP, syscall.TCP_CONGESTION, algorithm)
		}); err != nil {
			return fmt.Errorf("access TCP listener socket: %w", err)
		}
		if optionErr != nil {
			return fmt.Errorf("set TCP_CONGESTION=%q on listener: %w", algorithm, optionErr)
		}
		return nil
	}
	return nil
}
