#+build linux

package main

import "core:c"
import "core:net"
import "core:os"
import posix "core:sys/posix"

// core:net.enumerate_interfaces() is currently stubbed on Linux in the Odin
// toolchain used by this project. Use libc getifaddrs only for selecting a
// local IPv4 address to show/copy; LAN discovery itself does not depend on
// this helper because clients learn the host IPv4 address from the UDP reply.
Linux_Ifaddrs :: struct {
    next:    ^Linux_Ifaddrs,
    name:    cstring,
    flags:   c.uint,
    addr:    ^posix.sockaddr,
    netmask: ^posix.sockaddr,
    dstaddr: ^posix.sockaddr,
    data:    rawptr,
}

foreign import linux_libc "system:c"
foreign linux_libc {
    getifaddrs  :: proc(ifap: ^^Linux_Ifaddrs) -> c.int ---
    freeifaddrs :: proc(ifp: ^Linux_Ifaddrs) ---
}

LINUX_IFF_UP       :: c.uint(0x1)
LINUX_IFF_LOOPBACK :: c.uint(0x8)

linux_default_route_interface :: proc() -> string {
    data, err := os.read_entire_file_from_path("/proc/net/route", context.temp_allocator)
    if err != nil { return "" }

    line_start := 0
    for line_start < len(data) {
        line_end := line_start
        for line_end < len(data) && data[line_end] != '\n' { line_end += 1 }
        line := data[line_start:line_end]

        iface_field := linux_proc_ipv6_field(line, 0)
        destination := linux_proc_ipv6_field(line, 1)
        if len(iface_field) > 0 && string(destination) == "00000000" {
            return string(iface_field)
        }

        line_start = line_end + 1
    }
    return ""
}

find_preferred_discovery_ip4_linux :: proc() -> (result: net.IP4_Address, ok: bool) {
    head: ^Linux_Ifaddrs
    if getifaddrs(&head) != 0 || head == nil { return }
    defer freeifaddrs(head)

    preferred_interface := linux_default_route_interface()

    // Prefer the interface that owns the IPv4 default route so Docker/VM/VPN
    // adapters do not become the address shown by COPY INVITE. Fall back to
    // any active non-loopback IPv4 interface if no default route is available.
    for pass in 0..<2 {
        for iface := head; iface != nil; iface = iface.next {
            if iface.addr == nil || iface.name == nil { continue }
            if (iface.flags & LINUX_IFF_UP) == 0 { continue }
            if (iface.flags & LINUX_IFF_LOOPBACK) != 0 { continue }
            if iface.addr.sa_family != .INET { continue }

            if pass == 0 {
                if len(preferred_interface) == 0 || string(iface.name) != preferred_interface {
                    continue
                }
            }

            addr := cast(^posix.sockaddr_in)iface.addr
            bytes := transmute([4]u8)addr.sin_addr.s_addr
            candidate := net.IP4_Address(bytes)
            if is_usable_discovery_ip4(candidate) {
                return candidate, true
            }
        }
    }
    return
}
