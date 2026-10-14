//go:build windows

package main

import (
	"context"
	"net"
	"syscall"
	"unsafe"
)

const (
	dnsQueryBypassCache = 0x00000008 // DNS_QUERY_BYPASS_CACHE: ask the DNS servers, not the DNS Client cache
	dnsQueryNoMulticast = 0x00000800 // DNS_QUERY_NO_MULTICAST: no LLMNR or mDNS for a name that does not exist
	dnsFreeRecordList   = 1          // DnsFreeRecordList
	dnsErrNameError     = syscall.Errno(9003)
	dnsInfoNoRecords    = syscall.Errno(9501)
)

// lookupHost resolves a host name for the claim checks. The proxy must see the runner that Swarm has just replaced in the answer for
// tasks.<service>, and the Windows DNS Client service caches an answer for as long as its TTL, so the lookup of the Go net package (the
// system resolver, GetAddrInfoEx) can name a container that is gone and miss the one that took its place. DnsQuery with
// DNS_QUERY_BYPASS_CACHE asks the DNS servers of the container, which is what the Linux build does. A failure of the call itself falls
// back to the system resolver.
func lookupHost(ctx context.Context, host string) ([]string, error) {
	var addrs []string
	found := false
	for _, t := range []uint16{syscall.DNS_TYPE_A, syscall.DNS_TYPE_AAAA} {
		var rec *syscall.DNSRecord
		err := syscall.DnsQuery(host, t, dnsQueryBypassCache|dnsQueryNoMulticast, nil, &rec, nil)
		if err != nil {
			if errno, ok := err.(syscall.Errno); ok && (errno == dnsErrNameError || errno == dnsInfoNoRecords) {
				continue // no such name, or none of this type
			}
			return net.DefaultResolver.LookupHost(ctx, host)
		}
		for r := rec; r != nil; r = r.Next {
			if r.Type != t || r.Dw&3 != syscall.DnsSectionAnswer {
				continue
			}
			switch t {
			case syscall.DNS_TYPE_A:
				addrs = append(addrs, net.IP((*[4]byte)(unsafe.Pointer(&r.Data[0]))[:]).String())
			case syscall.DNS_TYPE_AAAA:
				addrs = append(addrs, net.IP((*[16]byte)(unsafe.Pointer(&r.Data[0]))[:]).String())
			}
			found = true
		}
		syscall.DnsRecordListFree(rec, dnsFreeRecordList)
	}
	if !found {
		return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
	}
	return addrs, nil
}
