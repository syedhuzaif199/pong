#+build windows

package main

import "core:c"
import "core:net"
import win "core:sys/windows"

// Windows IPv6 sockets are IPv6-only by default. Clear IPV6_V6ONLY before
// binding so a single gameplay socket can receive both native IPv6 packets and
// IPv4 packets represented as IPv4-mapped IPv6 endpoints.
set_udp_dual_stack :: proc(socket: net.UDP_Socket) -> bool {
    v6_only: b32 = false
    result := win.setsockopt(
        win.SOCKET(net.Socket(socket)),
        win.IPPROTO_IPV6,
        win.IPV6_V6ONLY,
        &v6_only,
        c.int(size_of(v6_only)),
    )
    return result == 0
}
