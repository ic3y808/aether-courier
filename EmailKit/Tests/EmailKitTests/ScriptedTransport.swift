import Foundation
@testable import EmailKit

/// A deterministic in-memory `MailTransport` for protocol tests. It records
/// everything the client sends and replays a pre-scripted sequence of server
/// responses — no sockets, no network, no flakiness.
final class ScriptedTransport: MailTransport, @unchecked Sendable {
    /// Server-to-client byte chunks, dispensed in order by `receive()`.
    private var script: [[UInt8]]
    /// Client-to-server bytes captured for assertions.
    private(set) var sent: [UInt8] = []
    private(set) var didConnect = false
    private(set) var didStartTLS = false
    private(set) var closed = false
    private let lock = NSLock()

    init(script: [String]) {
        self.script = script.map { Array($0.utf8) }
    }
    init(scriptBytes: [[UInt8]]) {
        self.script = scriptBytes
    }

    /// The full transcript the client wrote, as a String.
    var sentString: String { String(decoding: sent, as: UTF8.self) }

    func connect() async throws {
        lock.withLock { didConnect = true }
    }

    func send(_ bytes: [UInt8]) async throws {
        lock.withLock { sent.append(contentsOf: bytes) }
    }

    func receive() async throws -> [UInt8] {
        lock.withLock {
            guard !script.isEmpty else { return [] }
            return script.removeFirst()
        }
    }

    func startTLS() async throws {
        lock.withLock { didStartTLS = true }
    }

    func close() async {
        lock.withLock { closed = true }
    }
}
