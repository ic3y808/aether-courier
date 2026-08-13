import Foundation

public struct SMTPReply: Equatable, Sendable {
    public let code: Int
    public let lines: [String]
    public var isPositive: Bool { (200..<400).contains(code) }
}

public enum SMTPClientError: Error, LocalizedError {
    case greetingFailed(String)
    case commandRejected(command: String, reply: SMTPReply)
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .greetingFailed(let s): return "SMTP greeting failed: \(s)"
        case .commandRejected(let c, let r): return "SMTP \(c) rejected (\(r.code)): \(r.lines.joined(separator: " "))"
        case .authenticationFailed(let s): return "SMTP authentication failed: \(s)"
        }
    }
}

/// SMTP submission client over a `MailTransport`. Supports AUTH LOGIN
/// (password / app-password) and AUTH XOAUTH2 (Gmail/Outlook). Message bytes
/// are dot-stuffed per RFC 5321 before DATA.
public actor SMTPClient {
    private let transport: MailTransport
    private let reader: LineReader
    private var advertised: Set<String> = []

    public init(transport: MailTransport) {
        self.transport = transport
        self.reader = LineReader(transport: transport)
    }

    public func connect(clientHostname: String = "aether-courier.local", useStartTLS: Bool = false) async throws {
        try await transport.connect()
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw SMTPClientError.greetingFailed(greeting.lines.joined()) }
        try await ehlo(clientHostname)
        if useStartTLS {
            try await startTLS()
            try await ehlo(clientHostname)   // re-EHLO over the encrypted channel
        }
    }

    /// Issues `STARTTLS` and upgrades the transport to TLS in place.
    public func startTLS() async throws {
        let reply = try await command("STARTTLS")
        guard reply.code == 220 else { throw SMTPClientError.commandRejected(command: "STARTTLS", reply: reply) }
        try await transport.startTLS()
    }

    public func ehlo(_ hostname: String) async throws {
        let reply = try await command("EHLO \(hostname)")
        guard reply.isPositive else { throw SMTPClientError.commandRejected(command: "EHLO", reply: reply) }
        // Capture advertised extensions/auth mechanisms.
        advertised = Set(reply.lines.map { $0.uppercased() })
    }

    public func authLogin(user: String, password: String) async throws {
        let start = try await command("AUTH LOGIN")
        guard start.code == 334 else { throw SMTPClientError.authenticationFailed(start.lines.joined()) }
        let u = try await command(Data(user.utf8).base64EncodedString())
        guard u.code == 334 else { throw SMTPClientError.authenticationFailed(u.lines.joined()) }
        let p = try await command(Data(password.utf8).base64EncodedString())
        guard p.code == 235 else { throw SMTPClientError.authenticationFailed(p.lines.joined()) }
    }

    public func authXOAUTH2(user: String, accessToken: String) async throws {
        let ir = OAuthPKCE.xoauth2String(user: user, accessToken: accessToken)
        let reply = try await command("AUTH XOAUTH2 \(ir)")
        if reply.code == 235 { return }
        // On failure the server sends 334 <base64 error>; ack with empty line.
        if reply.code == 334 {
            let follow = try await command("")
            if follow.code == 235 { return }
            throw SMTPClientError.authenticationFailed(follow.lines.joined())
        }
        throw SMTPClientError.authenticationFailed(reply.lines.joined())
    }

    /// Sends one message. `rawMessage` is the MIME output of `MIMEBuilder`.
    public func send(from: String, recipients: [String], rawMessage: [UInt8]) async throws {
        let mailFrom = try await command("MAIL FROM:<\(from)>")
        guard mailFrom.code == 250 else { throw SMTPClientError.commandRejected(command: "MAIL FROM", reply: mailFrom) }
        for rcpt in recipients {
            let r = try await command("RCPT TO:<\(rcpt)>")
            guard r.code == 250 || r.code == 251 else { throw SMTPClientError.commandRejected(command: "RCPT TO", reply: r) }
        }
        let data = try await command("DATA")
        guard data.code == 354 else { throw SMTPClientError.commandRejected(command: "DATA", reply: data) }
        try await transport.send(Self.dotStuff(rawMessage))
        try await transport.send("\r\n.\r\n")
        let done = try await readReply()
        guard done.code == 250 else { throw SMTPClientError.commandRejected(command: "DATA-end", reply: done) }
    }

    public func quit() async {
        _ = try? await command("QUIT")
        await transport.close()
    }

    public var supportsXOAUTH2: Bool {
        advertised.contains { $0.contains("XOAUTH2") }
    }

    // MARK: plumbing

    @discardableResult
    private func command(_ line: String) async throws -> SMTPReply {
        try await transport.send(line + "\r\n")
        return try await readReply()
    }

    /// Reads a (possibly multi-line) SMTP reply. Continuation lines use
    /// `NNN-text`; the final line uses `NNN text`.
    private func readReply() async throws -> SMTPReply {
        var lines: [String] = []
        var code = 0
        while true {
            let line = try await reader.readLine()
            guard line.count >= 3, let c = Int(line.prefix(3)) else {
                lines.append(line); continue
            }
            code = c
            let afterCode = line.dropFirst(3)
            lines.append(String(afterCode.dropFirst()))
            // A space (not hyphen) at index 3 marks the final line.
            if afterCode.first != "-" { break }
        }
        return SMTPReply(code: code, lines: lines)
    }

    /// RFC 5321 dot-stuffing: any line starting with '.' gets an extra '.'.
    static func dotStuff(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var atLineStart = true
        for b in bytes {
            if atLineStart && b == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(b)
            atLineStart = (b == 0x0A)
        }
        return out
    }
}
