// SPDX-License-Identifier: LGPL-2.1-or-later
//go:build !linux

package main

import (
	"fmt"
	"net"
)

func configureTCPCongestion(_ *net.ListenConfig, algorithm string) error {
	return fmt.Errorf("TCP congestion control %q requires Linux; select system on this platform", algorithm)
}
