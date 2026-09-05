#+build linux, darwin

package main

import "core:c"
import "core:net"
import posix "core:sys/posix"

// Force a predictable dual-stack socket on POSIX too instead of depending on
// the operating system's IPV6_V6ONLY default.
set_udp_dual_stack :: proc(socket: net.UDP_Socket) -> bool {
    v6_only: c.int = 0
    result := posix.setsockopt(
        posix.FD(net.Socket(socket)),
        c.int(posix.Protocol.IPV6),
        posix.Sock_Option(posix.IPV6_V6ONLY),
        &v6_only,
        posix.socklen_t(size_of(v6_only)),
    )
    return result == .OK
}
