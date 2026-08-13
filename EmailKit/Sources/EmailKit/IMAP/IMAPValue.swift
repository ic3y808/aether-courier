import Foundation

/// A parsed IMAP data item. IMAP responses are a LISP-like grammar of atoms,
/// quoted/literal strings, NIL, and nested parenthesised lists; representing
/// them as this recursive value makes ENVELOPE/FLAGS/BODYSTRUCTURE
/// interpretation straightforward and unit-testable.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)      // unquoted token: numbers, keywords, flags (\Seen)
    case string(String)    // quoted string or literal payload
    case nilValue          // the NIL token
    case list([IMAPValue]) // ( ... )

    /// String content for atom/string; nil for NIL and lists.
    public var stringValue: String? {
        switch self {
        case .atom(let s), .string(let s): return s
        case .nilValue, .list: return nil
        }
    }

    public var listValue: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    public var intValue: Int? {
        guard let s = stringValue else { return nil }
        return Int(s)
    }

    /// Depth-first search for any atom/string equal (case-insensitively) to
    /// `needle`. Used for the BODYSTRUCTURE "attachment" heuristic.
    public func contains(caseInsensitive needle: String) -> Bool {
        switch self {
        case .atom(let s), .string(let s):
            return s.caseInsensitiveCompare(needle) == .orderedSame
        case .nilValue:
            return false
        case .list(let items):
            return items.contains { $0.contains(caseInsensitive: needle) }
        }
    }
}

/// Tokenizes an assembled IMAP response fragment (with literals already inlined
/// as `{n}CRLF<n bytes>`) into `IMAPValue`s. Operates on bytes so literal byte
/// counts are exact even for multi-byte UTF-8 payloads.
public struct IMAPTokenizer {
    private let bytes: [UInt8]
    private var i: Int = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ string: String) { self.bytes = Array(string.utf8) }

    /// Parses the entire input as a sequence of top-level values.
    public mutating func parseAll() throws -> [IMAPValue] {
        var out: [IMAPValue] = []
        skipSpaces()
        while i < bytes.count {
            out.append(try parseValue())
            skipSpaces()
        }
        return out
    }

    /// Parses one value (atom / string / list / NIL).
    public mutating func parseValue() throws -> IMAPValue {
        skipSpaces()
        guard i < bytes.count else { throw IMAPParseError.unexpectedEnd }
        let c = bytes[i]
        switch c {
        case UInt8(ascii: "("):
            return try parseList()
        case UInt8(ascii: "\""):
            return .string(try parseQuoted())
        case UInt8(ascii: "{"):
            return .string(try parseLiteral())
        default:
            let atom = parseAtom()
            if atom.caseInsensitiveCompare("NIL") == .orderedSame {
                return .nilValue
            }
            return .atom(atom)
        }
    }

    private mutating func parseList() throws -> IMAPValue {
        i += 1 // consume '('
        var items: [IMAPValue] = []
        skipSpaces()
        while i < bytes.count && bytes[i] != UInt8(ascii: ")") {
            items.append(try parseValue())
            skipSpaces()
        }
        guard i < bytes.count else { throw IMAPParseError.unbalancedParens }
        i += 1 // consume ')'
        return .list(items)
    }

    private mutating func parseQuoted() throws -> String {
        i += 1 // consume opening quote
        var out: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\\"), i + 1 < bytes.count {
                out.append(bytes[i + 1]); i += 2; continue
            }
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            out.append(c); i += 1
        }
        throw IMAPParseError.unterminatedString
    }

    private mutating func parseLiteral() throws -> String {
        i += 1 // consume '{'
        var digits: [UInt8] = []
        while i < bytes.count && bytes[i] != UInt8(ascii: "}") { digits.append(bytes[i]); i += 1 }
        guard i < bytes.count else { throw IMAPParseError.badLiteral }
        i += 1 // consume '}'
        guard let count = Int(String(decoding: digits, as: UTF8.self)) else { throw IMAPParseError.badLiteral }
        // Skip the CRLF (or lone LF) that follows the literal header.
        if i < bytes.count && bytes[i] == 0x0D { i += 1 }
        if i < bytes.count && bytes[i] == 0x0A { i += 1 }
        guard i + count <= bytes.count else { throw IMAPParseError.badLiteral }
        let slice = Array(bytes[i..<(i + count)])
        i += count
        return String(decoding: slice, as: UTF8.self)
    }

    private mutating func parseAtom() -> String {
        var out: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: " ") || c == UInt8(ascii: "(") || c == UInt8(ascii: ")")
                || c == UInt8(ascii: "\"") || c == UInt8(ascii: "{")
                || c == 0x0D || c == 0x0A {
                break
            }
            out.append(c); i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func skipSpaces() {
        while i < bytes.count && (bytes[i] == UInt8(ascii: " ") || bytes[i] == 0x0D || bytes[i] == 0x0A) {
            i += 1
        }
    }
}

public enum IMAPParseError: Error, Equatable {
    case unexpectedEnd
    case unbalancedParens
    case unterminatedString
    case badLiteral
    case malformedResponse(String)
}
