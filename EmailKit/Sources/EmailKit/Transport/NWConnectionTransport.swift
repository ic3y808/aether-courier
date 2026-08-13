import Foundation
import Network

/// `MailTransport` backed by Apple's Network.framework. Handles implicit-TLS
/// (IMAPS 993 / SMTPS 465) and plaintext connections. In-place STARTTLS is not
/// supported by NWConnection (see `startTLS()`).
public final class NWConnectionTransport: MailTransport, @unchecked Sendable {
    private let endpoint: ServerEndpoint
    private let queue: DispatchQueue
    private let connectTimeout: TimeInterval
    private var connection: NWConnection?
    private let lock = NSLock()

    public init(endpoint: ServerEndpoint, connectTimeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.connectTimeout = connectTimeout
        self.queue = DispatchQueue(label: "com.aether.courier.transport.\(endpoint.host)")
    }

    public func connect() async throws {
        let params: NWParameters
        switch endpoint.security {
        case .implicitTLS:
            let tls = NWProtocolTLS.Options()
            // Enforce the server name for certificate validation (SNI + hostname
            // check). Network.framework validates the chain against the system
            // trust store by default.
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.host)
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        case .plaintext:
            params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        case .startTLS:
            // A STARTTLS endpoint starts life in plaintext; the upgrade would
            // happen after the protocol greeting. NWConnection cannot upgrade
            // in place, so we surface that clearly rather than silently sending
            // credentials over cleartext.
            throw MailTransportError.starttlsUnsupported
        }

        let host = NWEndpoint.Host(endpoint.host)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw MailTransportError.connectionFailed("invalid port \(endpoint.port)")
        }
        let conn = NWConnection(host: host, port: port, using: params)
        lock.withLock { self.connection = conn }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = ResumeGuard()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.tryResume() { cont.resume() }
                case .failed(let err):
                    if resumed.tryResume() { cont.resume(throwing: MailTransportError.connectionFailed(err.localizedDescription)) }
                case .cancelled:
                    if resumed.tryResume() { cont.resume(throwing: MailTransportError.closed) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + connectTimeout) {
                if resumed.tryResume() {
                    conn.cancel()
                    cont.resume(throwing: MailTransportError.timedOut)
                }
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let conn = lock.withLock({ connection }) else { throw MailTransportError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: MailTransportError.connectionFailed(error.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    public func receive() async throws -> [UInt8] {
        guard let conn = lock.withLock({ connection }) else { throw MailTransportError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: MailTransportError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: [UInt8](data))
                } else if isComplete {
                    cont.resume(returning: [])
                } else {
                    cont.resume(returning: [])
                }
            }
        }
    }

    public func startTLS() async throws {
        // Not supported by NWConnection. The connection would have to be torn
        // down and rebuilt with TLS, which loses the negotiated session — the
        // proper fix is a NIO/Security-backed transport (M2).
        throw MailTransportError.starttlsUnsupported
    }

    public func close() async {
        let conn = lock.withLock { () -> NWConnection? in
            let c = connection
            connection = nil
            return c
        }
        conn?.cancel()
    }
}

/// Single-shot continuation guard so a continuation is never resumed twice
/// (state handler + timeout can both fire).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
