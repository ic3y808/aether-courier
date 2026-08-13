import Testing
import Foundation
@testable import EmailKit

@Suite("IMAP tokenizer")
struct IMAPTokenizerTests {

    @Test("atoms, quoted strings and NIL")
    func basics() throws {
        var tok = IMAPTokenizer("UID 345 \"hello world\" NIL")
        let values = try tok.parseAll()
        #expect(values == [.atom("UID"), .atom("345"), .string("hello world"), .nilValue])
    }

    @Test("nested parenthesised lists")
    func nested() throws {
        var tok = IMAPTokenizer("(A (B C) D)")
        let values = try tok.parseAll()
        #expect(values == [.list([.atom("A"), .list([.atom("B"), .atom("C")]), .atom("D")])])
    }

    @Test("literal {n} payload is read exactly")
    func literal() throws {
        var tok = IMAPTokenizer("{5}\r\nHELLO WORLD")
        let values = try tok.parseAll()
        #expect(values == [.string("HELLO"), .atom("WORLD")])
    }

    @Test("escaped quotes inside quoted strings")
    func escapes() throws {
        var tok = IMAPTokenizer("\"a \\\"b\\\" c\"")
        let values = try tok.parseAll()
        #expect(values == [.string("a \"b\" c")])
    }
}

@Suite("IMAP response parsing")
struct IMAPResponseParserTests {

    @Test("tagged OK/NO/BAD")
    func tagged() {
        let ok = IMAPResponseParser.parseTagged("A0002 OK [READ-WRITE] SELECT completed")
        #expect(ok?.tag == "A0002")
        #expect(ok?.status == .ok)
        #expect(IMAPResponseParser.parseTagged("A0003 NO login failed")?.status == .no)
        #expect(IMAPResponseParser.parseTagged("* 12 EXISTS") == nil)  // untagged
    }

    @Test("untagged EXISTS / EXPUNGE / RECENT")
    func numericUntagged() {
        #expect(IMAPResponseParser.parseUntagged(Array("* 12 EXISTS".utf8)) == .exists(12))
        #expect(IMAPResponseParser.parseUntagged(Array("* 3 EXPUNGE".utf8)) == .expunge(3))
        #expect(IMAPResponseParser.parseUntagged(Array("* 1 RECENT".utf8)) == .recent(1))
    }

    @Test("UID SEARCH result")
    func search() {
        let u = IMAPResponseParser.parseUntagged(Array("* SEARCH 1 4 9 16".utf8))
        #expect(u == .search([1, 4, 9, 16]))
    }

    @Test("LIST response with special-use flag")
    func list() throws {
        let u = IMAPResponseParser.parseUntagged(Array("* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Messages\"".utf8))
        guard case .list(let folder)? = u else { Issue.record("not a list"); return }
        #expect(folder.path == "Sent Messages")
        #expect(folder.separator == "/")
        #expect(folder.role == .sent)
        #expect(folder.isSelectable == true)
    }

    @Test("LIST \\Noselect is non-selectable")
    func noselect() throws {
        let u = IMAPResponseParser.parseUntagged(Array("* LIST (\\Noselect) \".\" \"[Gmail]\"".utf8))
        guard case .list(let folder)? = u else { Issue.record("not a list"); return }
        #expect(folder.isSelectable == false)
    }

    @Test("FETCH envelope, flags, size, message-id")
    func fetch() throws {
        let line = "* 12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) RFC822.SIZE 2048 "
            + "INTERNALDATE \"17-Jul-2024 12:00:00 +0000\" "
            + "ENVELOPE (\"Wed, 17 Jul 2024 12:00:00 +0000\" \"Hello World\" "
            + "((\"Ada Lovelace\" NIL \"ada\" \"example.com\")) "
            + "((\"Ada Lovelace\" NIL \"ada\" \"example.com\")) "
            + "((\"Ada Lovelace\" NIL \"ada\" \"example.com\")) "
            + "((\"Bob\" NIL \"bob\" \"example.org\")) NIL NIL NIL \"<abc@example.com>\") "
            + "BODYSTRUCTURE (\"text\" \"plain\" NIL NIL NIL \"7bit\" 100 5))"
        guard case .fetch(let seq, let r)? = IMAPResponseParser.parseUntagged(Array(line.utf8)) else {
            Issue.record("not a fetch"); return
        }
        #expect(seq == 12)
        #expect(r.uid == 345)
        #expect(r.flags.contains(.seen))
        #expect(r.flags.contains(.flagged))
        #expect(r.size == 2048)
        #expect(r.envelope?.subject == "Hello World")
        #expect(r.envelope?.from.first?.address == "ada@example.com")
        #expect(r.envelope?.from.first?.name == "Ada Lovelace")
        #expect(r.envelope?.to.first?.address == "bob@example.org")
        #expect(r.envelope?.messageID == "<abc@example.com>")
        #expect(r.hasAttachments == false)
    }

    @Test("BODYSTRUCTURE with an attachment part is detected")
    func attachments() throws {
        let line = "* 5 FETCH (UID 9 BODYSTRUCTURE ((\"text\" \"plain\" NIL NIL NIL \"7bit\" 10 1)"
            + "(\"application\" \"pdf\" (\"name\" \"x.pdf\") NIL NIL \"base64\" 1234 NIL "
            + "(\"attachment\" (\"filename\" \"x.pdf\"))) \"mixed\"))"
        guard case .fetch(_, let r)? = IMAPResponseParser.parseUntagged(Array(line.utf8)) else {
            Issue.record("not a fetch"); return
        }
        #expect(r.hasAttachments == true)
    }

    @Test("FETCH with a literal-encoded subject")
    func fetchLiteral() throws {
        let line = "* 1 FETCH (UID 7 ENVELOPE (NIL {5}\r\nHello ((\"A\" NIL \"a\" \"b.com\")) "
            + "((\"A\" NIL \"a\" \"b.com\")) ((\"A\" NIL \"a\" \"b.com\")) NIL NIL NIL NIL NIL))"
        guard case .fetch(_, let r)? = IMAPResponseParser.parseUntagged(Array(line.utf8)) else {
            Issue.record("not a fetch"); return
        }
        #expect(r.envelope?.subject == "Hello")
    }

    @Test("encoded-word subject in an envelope is decoded")
    func encodedWordSubject() throws {
        let line = "* 1 FETCH (UID 7 ENVELOPE (NIL \"=?UTF-8?B?w6ljaG8=?=\" "
            + "((\"A\" NIL \"a\" \"b.com\")) ((\"A\" NIL \"a\" \"b.com\")) "
            + "((\"A\" NIL \"a\" \"b.com\")) NIL NIL NIL NIL NIL))"
        guard case .fetch(_, let r)? = IMAPResponseParser.parseUntagged(Array(line.utf8)) else {
            Issue.record("not a fetch"); return
        }
        #expect(r.envelope?.subject == "écho")
    }
}
