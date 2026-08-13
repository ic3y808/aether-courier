import Foundation
import Security

// Not surfaced as a Swift symbol in the macOS 26 SDK; value from SecureTransport.h.
private let errSSLServerAuthCompleted: OSStatus = -9841

// Secure Transport is formally deprecated in favour of Network.framework, but
// Network.framework cannot upgrade a live plaintext connection to TLS
// (STARTTLS). Secure Transport still ships and works on macOS 26, so it is the
// pragmatic, dependency-free way to support STARTTLS endpoints (Proton Mail
// Bridge on 127.0.0.1:1143/1025, and iCloud/Outlook SMTP submission on 587).
//
// The deprecation warnings are silenced here deliberately; the whole file is an
// isolated transport implementation behind the `MailTransport` protocol, so if
// a NIO-based replacement lands later, only this file changes.

/// A `MailTransport` that connects over a plaintext BSD socket and can upgrade
/// to TLS in place via STARTTLS. Handles `.startTLS` and `.plaintext`; for
/// `.implicitTLS`, TLS is negotiated immediately on connect.
public final class STARTTLSTransport: MailTransport, @unchecked Sendable {
    private let endpoint: ServerEndpoint
    private let queue: DispatchQueue
    private let box = SSLIOBox()
    private var sslContext: SSLContext?
    private var tlsActive = false
    private let connectTimeout: TimeInterval

    public init(endpoint: ServerEndpoint, connectTimeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.connectTimeout = connectTimeout
        self.queue = DispatchQueue(label: "com.aether.courier.starttls.\(endpoint.host)")
    }

    // MARK: connect

    public func connect() async throws {
        try await runOnQueue {
            try self.openSocket()
        }
        if endpoint.security == .implicitTLS {
            try await startTLS()
        }
    }

    private func openSocket() throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result)
        guard status == 0, let info = result else {
            throw MailTransportError.connectionFailed("DNS/getaddrinfo failed for \(endpoint.host)")
        }
        defer { freeaddrinfo(info) }

        var lastError = "no address"
        var node: UnsafeMutablePointer<addrinfo>? = info
        while let current = node {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                // Receive timeout long enough to hold an IMAP IDLE (servers
                // refresh every ~29 min); a shorter timeout was tearing IDLE
                // down and reconnecting every minute.
                var tv = timeval(tv_sec: 1740, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                    box.fd = fd
                    return
                }
                lastError = String(cString: strerror(errno))
                Darwin.close(fd)
            }
            node = current.pointee.ai_next
        }
        throw MailTransportError.connectionFailed("connect failed: \(lastError)")
    }

    // MARK: TLS upgrade

    public func startTLS() async throws {
        try await runOnQueue {
            guard self.box.fd >= 0 else { throw MailTransportError.notConnected }
            guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
                throw MailTransportError.tlsFailed("SSLCreateContext returned nil")
            }
            self.sslContext = ctx
            SSLSetIOFuncs(ctx, aetherSSLRead, aetherSSLWrite)
            SSLSetConnection(ctx, Unmanaged.passUnretained(self.box).toOpaque())
            _ = self.endpoint.host.withCString { SSLSetPeerDomainName(ctx, $0, strlen($0)) }
            // Break on server auth so we can accept a self-signed cert on a
            // loopback Bridge. Only loopback hosts are auto-accepted; any other
            // host must present a system-trusted certificate.
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)

            var status = SSLHandshake(ctx)
            while status == errSSLWouldBlock { status = SSLHandshake(ctx) }
            if status == errSSLServerAuthCompleted {
                try self.evaluateServerTrust(ctx)
                status = SSLHandshake(ctx)
                while status == errSSLWouldBlock || status == errSSLServerAuthCompleted {
                    if status == errSSLServerAuthCompleted { try self.evaluateServerTrust(ctx) }
                    status = SSLHandshake(ctx)
                }
            }
            guard status == noErr else {
                throw MailTransportError.tlsFailed("SSLHandshake status \(status)")
            }
            self.tlsActive = true
        }
    }

    /// Accepts the peer certificate for loopback (Proton Bridge, self-signed);
    /// otherwise requires the system trust evaluation to succeed.
    private func evaluateServerTrust(_ ctx: SSLContext) throws {
        let isLoopback = endpoint.host == "127.0.0.1" || endpoint.host == "::1" || endpoint.host == "localhost"
        if isLoopback { return }   // local Bridge — trust the loopback endpoint
        var trust: SecTrust?
        guard SSLCopyPeerTrust(ctx, &trust) == errSecSuccess, let trust else {
            throw MailTransportError.tlsFailed("no peer trust")
        }
        var error: CFError?
        if !SecTrustEvaluateWithError(trust, &error) {
            throw MailTransportError.tlsFailed("certificate not trusted: \(error?.localizedDescription ?? "unknown")")
        }
    }

    // MARK: I/O

    public func send(_ bytes: [UInt8]) async throws {
        try await runOnQueue {
            guard self.box.fd >= 0 else { throw MailTransportError.notConnected }
            if self.tlsActive, let ctx = self.sslContext {
                if bytes.isEmpty { return }
                var processed = 0
                let status = bytes.withUnsafeBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return noErr }
                    return SSLWrite(ctx, base, raw.count, &processed)
                }
                guard status == noErr else { throw MailTransportError.connectionFailed("SSLWrite \(status)") }
            } else {
                try self.rawWrite(bytes)
            }
        }
    }

    public func receive() async throws -> [UInt8] {
        try await runOnQueue {
            guard self.box.fd >= 0 else { throw MailTransportError.notConnected }
            if self.tlsActive, let ctx = self.sslContext {
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                var processed = 0
                let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return errSSLClosedAbort }
                    return SSLRead(ctx, base, raw.count, &processed)
                }
                if status == noErr || (status == errSSLWouldBlock && processed > 0) {
                    return Array(buffer[0..<processed])
                }
                if status == errSSLClosedGraceful || status == errSSLClosedNoNotify { return [] }
                throw MailTransportError.connectionFailed("SSLRead \(status)")
            } else {
                return try self.rawRead()
            }
        }
    }

    private func rawWrite(_ bytes: [UInt8]) throws {
        var total = 0
        try bytes.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            while total < bytes.count {
                let n = write(box.fd, ptr + total, bytes.count - total)
                if n > 0 { total += n }
                else { throw MailTransportError.connectionFailed("write errno \(errno)") }
            }
        }
    }

    private func rawRead() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        let n = buffer.withUnsafeMutableBytes { read(box.fd, $0.baseAddress, $0.count) }
        if n > 0 { return Array(buffer[0..<n]) }
        if n == 0 { return [] }
        throw MailTransportError.connectionFailed("read errno \(errno)")
    }

    public func close() async {
        try? await runOnQueue {
            if let ctx = self.sslContext { SSLClose(ctx) }
            self.sslContext = nil
            self.tlsActive = false
            if self.box.fd >= 0 { Darwin.close(self.box.fd); self.box.fd = -1 }
        }
    }

    // MARK: queue bridge

    /// Runs a blocking socket/TLS operation on the transport's serial queue and
    /// bridges it back into async/await.
    private func runOnQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}

/// Heap box holding the socket fd, passed to the C SSL I/O callbacks.
final class SSLIOBox: @unchecked Sendable {
    var fd: Int32 = -1
}

// MARK: - Secure Transport C I/O callbacks (must be top-level @convention(c))

private func aetherSSLRead(_ connection: SSLConnectionRef,
                           _ data: UnsafeMutableRawPointer,
                           _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let box = Unmanaged<SSLIOBox>.fromOpaque(connection).takeUnretainedValue()
    let requested = dataLength.pointee
    let ptr = data.assumingMemoryBound(to: UInt8.self)
    var total = 0
    while total < requested {
        let n = read(box.fd, ptr + total, requested - total)
        if n > 0 { total += n }
        else if n == 0 { dataLength.pointee = total; return errSSLClosedGraceful }
        else {
            if errno == EAGAIN || errno == EWOULDBLOCK { dataLength.pointee = total; return errSSLWouldBlock }
            dataLength.pointee = total; return errSSLClosedAbort
        }
    }
    dataLength.pointee = total
    return noErr
}

private func aetherSSLWrite(_ connection: SSLConnectionRef,
                            _ data: UnsafeRawPointer,
                            _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let box = Unmanaged<SSLIOBox>.fromOpaque(connection).takeUnretainedValue()
    let requested = dataLength.pointee
    let ptr = data.assumingMemoryBound(to: UInt8.self)
    var total = 0
    while total < requested {
        let n = write(box.fd, ptr + total, requested - total)
        if n > 0 { total += n }
        else {
            if errno == EAGAIN || errno == EWOULDBLOCK { dataLength.pointee = total; return errSSLWouldBlock }
            dataLength.pointee = total; return errSSLClosedAbort
        }
    }
    dataLength.pointee = total
    return noErr
}
