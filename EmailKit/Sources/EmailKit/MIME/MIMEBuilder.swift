import Foundation

/// A message the user is composing/sending.
public struct OutgoingMessage: Sendable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var attachments: [MailAttachment]
    public var inReplyTo: String?
    public var references: [String]

    public init(
        from: MailAddress,
        to: [MailAddress],
        cc: [MailAddress] = [],
        bcc: [MailAddress] = [],
        subject: String,
        textBody: String,
        htmlBody: String? = nil,
        attachments: [MailAttachment] = [],
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// The RCPT TO set (to + cc + bcc) an SMTP client must deliver to.
    public var envelopeRecipients: [String] {
        (to + cc + bcc).map(\.address)
    }
}

/// Serialises an `OutgoingMessage` into RFC 5322 / MIME wire bytes.
public enum MIMEBuilder {

    public static func build(_ message: OutgoingMessage, date: Date = Date(), messageID: String? = nil) -> [UInt8] {
        var out = ""
        let boundaryMixed = "=_aether_mixed_\(UUID().uuidString)"
        let boundaryAlt = "=_aether_alt_\(UUID().uuidString)"

        func header(_ name: String, _ value: String) { out += "\(name): \(value)\r\n" }

        header("From", message.from.rfc5322)
        header("To", message.to.map(\.rfc5322).joined(separator: ", "))
        if !message.cc.isEmpty { header("Cc", message.cc.map(\.rfc5322).joined(separator: ", ")) }
        header("Subject", encodeHeaderText(message.subject))
        header("Date", rfc2822String(date))
        header("Message-ID", messageID ?? "<\(UUID().uuidString)@aether.courier>")
        if let inReplyTo = message.inReplyTo { header("In-Reply-To", inReplyTo) }
        if !message.references.isEmpty { header("References", message.references.joined(separator: " ")) }
        header("MIME-Version", "1.0")

        let hasAttachments = !message.attachments.isEmpty
        let hasHTML = message.htmlBody != nil

        if hasAttachments {
            header("Content-Type", "multipart/mixed; boundary=\"\(boundaryMixed)\"")
            out += "\r\n"
            out += "--\(boundaryMixed)\r\n"
            appendBodyPart(&out, message: message, altBoundary: boundaryAlt, hasHTML: hasHTML)
            for att in message.attachments {
                out += "--\(boundaryMixed)\r\n"
                appendAttachment(&out, att)
            }
            out += "--\(boundaryMixed)--\r\n"
        } else {
            appendBodyPartInline(&out, message: message, altBoundary: boundaryAlt, hasHTML: hasHTML)
        }

        return Array(out.utf8)
    }

    // MARK: parts

    private static func appendBodyPartInline(_ out: inout String, message: OutgoingMessage, altBoundary: String, hasHTML: Bool) {
        if hasHTML {
            out += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            appendAlternative(&out, message: message, altBoundary: altBoundary)
        } else {
            out += "Content-Type: text/plain; charset=UTF-8\r\n"
            out += "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
            out += encodeQuotedPrintable(message.textBody)
            out += "\r\n"
        }
    }

    private static func appendBodyPart(_ out: inout String, message: OutgoingMessage, altBoundary: String, hasHTML: Bool) {
        if hasHTML {
            out += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            appendAlternative(&out, message: message, altBoundary: altBoundary)
        } else {
            out += "Content-Type: text/plain; charset=UTF-8\r\n"
            out += "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
            out += encodeQuotedPrintable(message.textBody)
            out += "\r\n"
        }
    }

    private static func appendAlternative(_ out: inout String, message: OutgoingMessage, altBoundary: String) {
        out += "--\(altBoundary)\r\n"
        out += "Content-Type: text/plain; charset=UTF-8\r\n"
        out += "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
        out += encodeQuotedPrintable(message.textBody) + "\r\n"
        out += "--\(altBoundary)\r\n"
        out += "Content-Type: text/html; charset=UTF-8\r\n"
        out += "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
        out += encodeQuotedPrintable(message.htmlBody ?? "") + "\r\n"
        out += "--\(altBoundary)--\r\n"
    }

    private static func appendAttachment(_ out: inout String, _ att: MailAttachment) {
        out += "Content-Type: \(att.mimeType); name=\"\(att.filename)\"\r\n"
        out += "Content-Transfer-Encoding: base64\r\n"
        out += "Content-Disposition: attachment; filename=\"\(att.filename)\"\r\n\r\n"
        let b64 = (att.data ?? Data()).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
        out += b64 + "\r\n"
    }

    // MARK: encoders

    /// Encodes body text as quoted-printable with soft line wrapping.
    public static func encodeQuotedPrintable(_ text: String) -> String {
        var out = ""
        var lineLen = 0
        func emit(_ s: String) {
            for scalar in s.unicodeScalars {
                if lineLen >= 75 { out += "=\r\n"; lineLen = 0 }
                out.unicodeScalars.append(scalar)
                lineLen += 1
            }
        }
        for byte in text.replacingOccurrences(of: "\r\n", with: "\n").utf8 {
            if byte == UInt8(ascii: "\n") { out += "\r\n"; lineLen = 0; continue }
            let printable = (byte >= 0x20 && byte <= 0x7E && byte != UInt8(ascii: "="))
            if printable {
                emit(String(UnicodeScalar(byte)))
            } else {
                emit(String(format: "=%02X", byte))
            }
        }
        return out
    }

    /// Encodes a header value with an encoded-word only if it has non-ASCII.
    public static func encodeHeaderText(_ text: String) -> String {
        if text.allSatisfy({ $0.isASCII }) { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    private static let rfc2822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    public static func rfc2822String(_ date: Date) -> String {
        rfc2822Formatter.string(from: date)
    }
}
