import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// =========================================================================
// MARK: - MCPSocket
//
// Minimal cross-platform TCP listener + connection for the in-process MCP
// server. Localhost only. No third-party dependencies: POSIX sockets on
// macOS/Linux, Winsock2 on Windows. Timeouts use SO_RCVTIMEO/SO_SNDTIMEO
// (DWORD milliseconds on Winsock, timeval elsewhere) so reads fail fast
// instead of blocking the handler thread forever.
// =========================================================================

enum MCPSocketError: Error, Sendable {
    case startupFailed(String)
    case bindFailed(String)
    case acceptFailed(String)
    case readTimeout
    case writeFailed(String)
    case closed
    case tooLarge
}

/// One accepted TCP connection. Close after each HTTP response (no keep-alive).
final class MCPTCPConnection: @unchecked Sendable {
    #if os(Windows)
    private var sock: SOCKET
    private var closedFlag = false
    init(sock: SOCKET) { self.sock = sock }

    func readExactly(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        var buf = [CChar](repeating: 0, count: min(count, 65536))
        while out.count < count {
            let want = min(buf.count, count - out.count)
            let got = buf.withUnsafeMutableBufferPointer { ptr -> CInt in
                recv(sock, ptr.baseAddress, CInt(want), 0)
            }
            if got == 0 { throw MCPSocketError.closed }
            if got == SOCKET_ERROR {
                let err = WSAGetLastError()
                throw err == WSAETIMEDOUT ? MCPSocketError.readTimeout
                    : MCPSocketError.writeFailed("recv: \(err)")
            }
            out.append(contentsOf: buf.prefix(Int(got)).map { UInt8(bitPattern: $0) })
        }
        return out
    }

    func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            let cptr = base.assumingMemoryBound(to: CChar.self)
            while sent < data.count {
                let got = send(sock, cptr.advanced(by: sent), CInt(data.count - sent), 0)
                if got == SOCKET_ERROR {
                    throw MCPSocketError.writeFailed("send: \(WSAGetLastError())")
                }
                sent += Int(got)
            }
        }
    }

    func close() {
        if !closedFlag {
            closedFlag = true
            _ = closesocket(sock)
        }
    }
    #else
    private var fd: CInt
    private var closedFlag = false
    init(fd: CInt) { self.fd = fd }

    func readExactly(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: min(count, 65536))
        while out.count < count {
            let want = min(buf.count, count - out.count)
            let got = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fd, ptr.baseAddress, want, 0)
            }
            if got == 0 { throw MCPSocketError.closed }
            if got < 0 {
                throw (errno == EAGAIN || errno == EWOULDBLOCK)
                    ? MCPSocketError.readTimeout
                    : MCPSocketError.writeFailed("recv errno: \(errno)")
            }
            out.append(contentsOf: buf.prefix(got))
        }
        return out
    }

    func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            while sent < data.count {
                let got = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if got <= 0 { throw MCPSocketError.writeFailed("send errno: \(errno)") }
                sent += got
            }
        }
    }

    func close() {
        if !closedFlag {
            closedFlag = true
            _ = close(fd)
        }
    }
    #endif
}

/// Localhost TCP listener for one MCP port.
final class MCPTCPListener: @unchecked Sendable {
    #if os(Windows)
    private var sock: SOCKET = INVALID_SOCKET
    #else
    private var fd: CInt = -1
    #endif
    private let ioTimeoutMs = 30_000

    init(port: UInt16) throws {
        #if os(Windows)
        var wsa = WSADATA()
        guard WSAStartup(0x0202, &wsa) == 0 else {
            throw MCPSocketError.startupFailed("WSAStartup: \(WSAGetLastError())")
        }
        // Protocol 0 selects the default (TCP) for SOCK_STREAM.
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s != INVALID_SOCKET else {
            WSACleanup()
            throw MCPSocketError.startupFailed("socket: \(WSAGetLastError())")
        }
        sock = s
        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = USHORT(port.bigEndian)
        var loopback = in_addr()
        _ = inet_pton(AF_INET, "127.0.0.1", &loopback)
        addr.sin_addr = loopback
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, CInt(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = WSAGetLastError()
            close()
            throw MCPSocketError.bindFailed("bind 127.0.0.1:\(port): \(err)")
        }
        guard listen(sock, 8) == 0 else {
            let err = WSAGetLastError()
            close()
            throw MCPSocketError.bindFailed("listen: \(err)")
        }
        var ms: DWORD = DWORD(ioTimeoutMs)
        withUnsafePointer(to: &ms) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, $0, CInt(MemoryLayout<DWORD>.size))
            }
        }
        withUnsafePointer(to: &ms) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, $0, CInt(MemoryLayout<DWORD>.size))
            }
        }
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.startupFailed("socket errno: \(errno)") }
        self.fd = fd
        var one: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<CInt>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close()
            throw MCPSocketError.bindFailed("bind 127.0.0.1:\(port) errno: \(err)")
        }
        guard listen(fd, 8) == 0 else {
            let err = errno
            close()
            throw MCPSocketError.bindFailed("listen errno: \(err)")
        }
        var tv = timeval(
            tv_sec: ioTimeoutMs / 1000, tv_usec: (ioTimeoutMs % 1000) * 1000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    /// Named acceptConnection: a method named accept shadows the global
    /// accept() inside its own body on every platform.
    func acceptConnection() throws -> MCPTCPConnection {
        #if os(Windows)
        let c = accept(sock, nil, nil)
        guard c != INVALID_SOCKET else { throw MCPSocketError.acceptFailed("accept") }
        var ms: DWORD = DWORD(ioTimeoutMs)
        withUnsafePointer(to: &ms) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, $0, CInt(MemoryLayout<DWORD>.size))
            }
        }
        return MCPTCPConnection(sock: c)
        #else
        var peer = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(fd, $0, &len)
            }
        }
        guard c >= 0 else { throw MCPSocketError.acceptFailed("accept errno: \(errno)") }
        var tv = timeval(
            tv_sec: ioTimeoutMs / 1000, tv_usec: (ioTimeoutMs % 1000) * 1000)
        _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return MCPTCPConnection(fd: c)
        #endif
    }

    func close() {
        #if os(Windows)
        if sock != INVALID_SOCKET {
            _ = closesocket(sock)
            sock = INVALID_SOCKET
            WSACleanup()
        }
        #else
        if fd >= 0 {
            _ = close(fd)
            fd = -1
        }
        #endif
    }
}
