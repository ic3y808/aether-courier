import Foundation

/// A bidirectional byte stream to a mail server. IMAP and SMTP clients are
/// written entirely against this protocol so their line-protocol logic can be
/// exercised deterministically against an in-memory scripted transport in
/// tests — no live server, no flakiness.
public protocol MailTransport: Sendable {
    /// Opens the connection (and completes the TLS handshake for implicit-TLS
    /// endpoints) before returning.
    func connect() async throws

    /// Writes raw bytes to the server.
    func send(_ bytes: [UInt8]) async throws

    /// Returns the next available chunk of bytes from the server. An empty
    /// array signals a clean end-of-stream (server closed the connection).
    func receive() async throws -> [UInt8]

    /// Upgrades a plaintext connection to TLS in place (STARTTLS). Throws
    /// `MailTransportError.starttlsUnsupported` on transports that cannot do an
    /// in-place upgrade (the Network.framework transport — see M2 notes).
    func startTLS() async throws

    /// Tears the connection down. Idempotent.
    func close() async
}

public extension MailTransport {
    /// Convenience for sending a string (commands are ASCII/UTF-8).
    func send(_ string: String) async throws {
        try await send(Array(string.utf8))
    }
}

public enum MailTransportError: Error, LocalizedError, Equatable {
    case notConnected
    case connectionFailed(String)
    case tlsFailed(String)
    case timedOut
    case closed
    case starttlsUnsupported

    public var errorDescription: String? {
        switch self {
        case .notConnected:       return "The transport is not connected."
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .tlsFailed(let m):    return "TLS handshake failed: \(m)"
        case .timedOut:            return "The connection timed out."
        case .closed:              return "The connection was closed by the server."
        case .starttlsUnsupported:
            return "STARTTLS in-place upgrade is not supported by this transport. Use an implicit-TLS port, or the NIO transport (M2)."
        }
    }
}
