import Foundation

/// Buffers bytes pulled from a `MailTransport` and hands back complete
/// CRLF-terminated lines, plus exact-length reads for IMAP literals (`{123}`).
/// Text-protocol clients (IMAP, SMTP) drive their parse loop through this.
public actor LineReader {
    private let transport: MailTransport
    private var buffer: [UInt8] = []

    public init(transport: MailTransport) {
        self.transport = transport
    }

    /// Reads one line, returned WITHOUT the trailing CRLF. Throws
    /// `MailTransportError.closed` if the stream ends before a line completes.
    public func readLine() async throws -> String {
        while true {
            if let line = try takeLine() { return line }
            let chunk = try await transport.receive()
            if chunk.isEmpty { throw MailTransportError.closed }
            buffer.append(contentsOf: chunk)
        }
    }

    /// Reads exactly `count` bytes (used for IMAP literal payloads).
    public func readBytes(_ count: Int) async throws -> [UInt8] {
        while buffer.count < count {
            let chunk = try await transport.receive()
            if chunk.isEmpty { throw MailTransportError.closed }
            buffer.append(contentsOf: chunk)
        }
        let out = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return out
    }

    /// Pulls a complete line out of the buffer if one is present.
    private func takeLine() throws -> String? {
        guard let lf = buffer.firstIndex(of: 0x0A) else { return nil }
        // Drop a preceding CR if present.
        let end = (lf > 0 && buffer[lf - 1] == 0x0D) ? lf - 1 : lf
        let lineBytes = Array(buffer[0..<end])
        buffer.removeFirst(lf + 1)
        // IMAP/SMTP are ASCII with UTF-8 in some header contexts; decode
        // leniently so a stray non-UTF-8 byte never stalls the reader.
        return String(decoding: lineBytes, as: UTF8.self)
    }
}
