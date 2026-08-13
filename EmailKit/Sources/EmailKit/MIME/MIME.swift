import Foundation

/// MIME text utilities: RFC 2047 encoded-word decoding/encoding,
/// quoted-printable, and a crude HTML-to-text fallback. Kept pure and
/// standalone so header decoding is unit-testable.
public enum MIME {

    // MARK: RFC 2047 encoded words  =?charset?B?..?=  /  =?charset?Q?..?=

    /// Decodes any encoded-words embedded in a header value, leaving plain
    /// runs untouched. Adjacent encoded-words are concatenated per the RFC.
    public static func decodeWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var remainder = Substring(input)

        while let start = remainder.range(of: "=?") {
            // Emit the literal text before the encoded-word.
            result += remainder[remainder.startIndex..<start.lowerBound]
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.range(of: "?=") else {
                // No terminator — treat the rest as literal.
                result += remainder[start.lowerBound...]
                return result
            }
            let token = afterStart[afterStart.startIndex..<end.lowerBound]
            if let decoded = decodeSingleWord(String(token)) {
                result += decoded
            } else {
                result += "=?" + token + "?="
            }
            remainder = afterStart[end.upperBound...]
            // Whitespace strictly between two encoded-words is dropped.
            if remainder.hasPrefix(" "), remainder.dropFirst().hasPrefix("=?") {
                remainder = remainder.dropFirst()
            }
        }
        result += remainder
        return result
    }

    /// Decodes the inside of one `=?...?=` (the `charset?enc?text` portion).
    private static func decodeSingleWord(_ token: String) -> String? {
        let parts = token.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = String(parts[0])
        let encoding = parts[1].uppercased()
        let text = String(parts[2])
        let enc = ianaEncoding(charset)

        switch encoding {
        case "B":
            guard let data = Data(base64Encoded: padBase64(text)) else { return nil }
            return String(data: data, encoding: enc)
        case "Q":
            guard let data = decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " "), underscoreAsSpace: false) else { return nil }
            return String(data: data, encoding: enc)
        default:
            return nil
        }
    }

    /// Encodes a display-name phrase as a base64 encoded-word if it contains
    /// non-ASCII; otherwise returns it unchanged (quoting if it has specials).
    public static func encodePhraseIfNeeded(_ phrase: String) -> String {
        if phrase.allSatisfy({ $0.isASCII }) {
            if phrase.contains(where: { "()<>@,;:\\\".[]".contains($0) }) {
                return "\"\(phrase.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return phrase
        }
        let b64 = Data(phrase.utf8).base64EncodedString()
        return "=?UTF-8?B?\(b64)?="
    }

    // MARK: Quoted-printable

    /// Decodes quoted-printable text into bytes. When `underscoreAsSpace` is
    /// true (RFC 2047 Q-encoding), `_` maps to space.
    public static func decodeQuotedPrintable(_ input: String, underscoreAsSpace: Bool = false) -> Data? {
        var out = [UInt8]()
        let chars = Array(input.utf8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "=") {
                // Soft line break "=\r\n" or "=\n".
                if i + 1 < chars.count, chars[i + 1] == 0x0D || chars[i + 1] == 0x0A {
                    i += (i + 2 < chars.count && chars[i + 1] == 0x0D && chars[i + 2] == 0x0A) ? 3 : 2
                    continue
                }
                guard i + 2 < chars.count,
                      let hi = hexNibble(chars[i + 1]), let lo = hexNibble(chars[i + 2]) else {
                    out.append(c); i += 1; continue
                }
                out.append(hi << 4 | lo); i += 3
            } else if underscoreAsSpace && c == UInt8(ascii: "_") {
                out.append(UInt8(ascii: " ")); i += 1
            } else {
                out.append(c); i += 1
            }
        }
        return Data(out)
    }

    // MARK: HTML fallback

    /// Strips tags and decodes a handful of entities. This is a *fallback* for
    /// AI/preview text only — full HTML is rendered in a WebView in the app.
    public static func stripHTML(_ html: String) -> String {
        var text = html
        for (tag, repl) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("</p>", "\n\n"), ("</div>", "\n")] {
            text = text.replacingOccurrences(of: tag, with: repl, options: .caseInsensitive)
        }
        // Remove <style>/<script> blocks.
        for block in ["style", "script"] {
            while let open = text.range(of: "<\(block)", options: .caseInsensitive),
                  let close = text.range(of: "</\(block)>", options: .caseInsensitive, range: open.lowerBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        // Strip remaining tags.
        var result = ""
        var inTag = false
        for ch in text {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false }
            else if !inTag { result.append(ch) }
        }
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (e, r) in entities { result = result.replacingOccurrences(of: e, with: r) }
        return result
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: small helpers

    static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    static func padBase64(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: " ", with: "")
        let rem = clean.count % 4
        return rem == 0 ? clean : clean + String(repeating: "=", count: 4 - rem)
    }

    /// Maps a small set of common IANA charset labels to `String.Encoding`.
    static func ianaEncoding(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8":            return .utf8
        case "us-ascii", "ascii":        return .ascii
        case "iso-8859-1", "latin1":     return .isoLatin1
        case "iso-8859-2":               return .isoLatin2
        case "windows-1252", "cp1252":   return .windowsCP1252
        case "utf-16":                   return .utf16
        default:                         return .utf8
        }
    }
}
