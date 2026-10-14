//go:build !windows

package main

import (
	"context"
	"net"
)

// lookupHost resolves a host name. A static Linux build uses Go's own resolver, which asks the DNS server of the container on every
// call and caches nothing, so a runner that Swarm has just replaced shows up in the answer for tasks.<service> at once.
func lookupHost(ctx context.Context, host string) ([]string, error) {
	return net.DefaultResolver.LookupHost(ctx, host)
}
