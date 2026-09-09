// SPDX-License-Identifier: LGPL-2.1-or-later
package main

import (
	"context"
	"fmt"
	"net"
)

func listenSpeedtest(ctx context.Context, address, algorithm string) (net.Listener, error) {
	var config net.ListenConfig
	switch algorithm {
	case "system":
		// Leave both the listener and accepted connections at the kernel choice.
	case "cubic":
		if err := configureTCPCongestion(&config, algorithm); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("invalid TCP congestion control %q: expected cubic or system", algorithm)
	}
	return config.Listen(ctx, "tcp", address)
}
