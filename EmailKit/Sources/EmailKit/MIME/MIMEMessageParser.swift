import Foundation

/// Parses a raw RFC822 message into a `MailBody` (plain text, HTML, and
/// attachments). Handles single-part bodies and `multipart/*` with nested
/// boundaries, decoding quoted-printable and base64 transfer encodings.
public enum MIMEMessageParser {

    public static func parse(_ raw: [UInt8]) -> MailBody {
        let (headers, body) = splitHeadersAndBody(raw)
        return parsePart(headers: headers, body: body)
    }

    public static func parse(_ raw: String) -> MailBody {
        parse(Array(raw.utf8))
    }

    /// Top-level headers only (lowercased keys), e.g. for `List-Unsubscribe`.
    public static func headers(_ raw: [UInt8]) -> [String: String] {
        splitHeadersAndBody(raw).0
    }

    // MARK: recursive part parsing

    private static func parsePart(headers: [String: String], body: [UInt8]) -> MailBody {
        let contentType = headers["content-type"] ?? "text/plain"
        let (mimeType, params) = parseContentType(contentType)

        if mimeType.hasPrefix("multipart/"), let boundary = params["boundary"] {
            var result = MailBody()
            let parts = splitMultipart(body, boundary: boundary)
            for part in parts {
                let (ph, pb) = splitHeadersAndBody(part)
                let child = parsePart(headers: ph, body: pb)
                if result.plainText == nil, let t = child.plainText { result.plainText = t }
                if result.html == nil, let h = child.html { result.html = h }
                result.attachments.append(contentsOf: child.attachments)
            }
            return result
        }

        // Leaf part.
        let encoding = (headers["content-transfer-encoding"] ?? "7bit").lowercased()
        let disposition = headers["content-disposition"] ?? ""
        let decoded = decodeTransfer(body, encoding: encoding)

        if disposition.lowercased().contains("attachment") || (mimeType != "text/plain" && mimeType != "text/html") {
            let filename = params["name"] ?? parseDispositionFilename(disposition) ?? "attachment"
            let att = MailAttachment(filename: MIME.decodeWords(filename), mimeType: mimeType,
                                     sizeBytes: decoded.count, data: Data(decoded))
            return MailBody(attachments: [att])
        }

        let charset = params["charset"] ?? "utf-8"
        let text = String(data: Data(decoded), encoding: MIME.ianaEncoding(charset)) ?? String(decoding: decoded, as: UTF8.self)
        if mimeType == "text/html" {
            return MailBody(html: text)
        }
        return MailBody(plainText: text)
    }

    // MARK: header/body splitting

    /// Splits at the first blank line into a lowercased header map and the body
    /// bytes. Unfolds continuation header lines.
    static func splitHeadersAndBody(_ raw: [UInt8]) -> ([String: String], [UInt8]) {
        // Find CRLFCRLF or LFLF.
        var idx = 0
        var bodyStart = raw.count
        var headerEnd = raw.count
        while idx < raw.count {
            if raw[idx] == 0x0A {
                // blank line if next is also newline (allowing CR)
                var j = idx + 1
                if j < raw.count && raw[j] == 0x0D { j += 1 }
                if j < raw.count && raw[j] == 0x0A {
                    headerEnd = idx
                    bodyStart = j + 1
                    break
                }
                if idx + 1 < raw.count && raw[idx + 1] == 0x0A {
                    headerEnd = idx; bodyStart = idx + 2; break
                }
            }
            idx += 1
        }
        let headerBytes = Array(raw[0..<min(headerEnd, raw.count)])
        let bodyBytes = bodyStart <= raw.count ? Array(raw[bodyStart...]) : []
        return (parseHeaders(headerBytes), bodyBytes)
    }

    static func parseHeaders(_ bytes: [UInt8]) -> [String: String] {
        // Normalise CRLF/CR to LF FIRST. In Swift, "\r\n" is a single extended
        // grapheme cluster, so `split(separator: "\n")` would NOT split
        // CRLF-terminated header lines and every header would merge into one.
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""
        func flush() {
            if let name = currentName {
                headers[name.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.first == " " || l.first == "\t" {
                currentValue += " " + l.trimmingCharacters(in: .whitespaces)
            } else if let colon = l.firstIndex(of: ":") {
                flush()
                currentName = String(l[l.startIndex..<colon])
                currentValue = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return headers
    }

    // MARK: multipart

    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [[UInt8]] = []
        var current: [UInt8] = []
        var lineStart = 0
        var i = 0
        func lineMatchesDelimiter(_ range: Range<Int>) -> Bool {
            let lineLen = range.count
            guard lineLen >= delimiter.count else { return false }
            for k in 0..<delimiter.count where body[range.lowerBound + k] != delimiter[k] { return false }
            return true
        }
        var started = false
        while i <= body.count {
            let atEnd = i == body.count
            if atEnd || body[i] == 0x0A {
                var end = i
                if end > lineStart && body[end - 1] == 0x0D { end -= 1 }
                let range = lineStart..<end
                if lineMatchesDelimiter(range) {
                    if started {
                        // Trim a trailing CRLF that belongs to the boundary.
                        var part = current
                        if part.last == 0x0A { part.removeLast() }
                        if part.last == 0x0D { part.removeLast() }
                        parts.append(part)
                    }
                    started = true
                    current = []
                    // Closing boundary "--boundary--" ends parsing.
                    if end - range.lowerBound >= delimiter.count + 2,
                       body[range.lowerBound + delimiter.count] == UInt8(ascii: "-"),
                       body[range.lowerBound + delimiter.count + 1] == UInt8(ascii: "-") {
                        break
                    }
                } else if started {
                    current.append(contentsOf: body[lineStart..<i])
                    if !atEnd { current.append(0x0A) }
                }
                lineStart = i + 1
            }
            i += 1
        }
        return parts
    }

    // MARK: transfer decoding

    static func decodeTransfer(_ body: [UInt8], encoding: String) -> [UInt8] {
        switch encoding {
        case "base64":
            let str = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            return [UInt8](Data(base64Encoded: MIME.padBase64(str)) ?? Data())
        case "quoted-printable":
            return [UInt8](MIME.decodeQuotedPrintable(String(decoding: body, as: UTF8.self)) ?? Data())
        default:
            return body
        }
    }

    // MARK: content-type

    static func parseContentType(_ value: String) -> (type: String, params: [String: String]) {
        let segments = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = segments.first else { return ("text/plain", [:]) }
        var params: [String: String] = [:]
        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let key = seg[seg.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = seg[seg.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return (first.lowercased(), params)
    }

    static func parseDispositionFilename(_ disposition: String) -> String? {
        let (_, params) = parseContentType(disposition)
        return params["filename"]
    }
}
