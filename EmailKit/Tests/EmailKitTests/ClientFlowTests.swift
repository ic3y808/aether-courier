import Testing
import Foundation
@testable import EmailKit

@Suite("LineReader framing")
struct LineReaderTests {

    @Test("splits CRLF lines across arbitrary chunk boundaries")
    func lines() async throws {
        let t = ScriptedTransport(script: ["AB", "C\r\nDE", "F\r\n"])
        let reader = LineReader(transport: t)
        #expect(try await reader.readLine() == "ABC")
        #expect(try await reader.readLine() == "DEF")
    }

    @Test("readBytes returns an exact-length slice")
    func bytes() async throws {
        let t = ScriptedTransport(script: ["12345", "6789"])
        let reader = LineReader(transport: t)
        let five = try await reader.readBytes(5)
        #expect(String(decoding: five, as: UTF8.self) == "12345")
        let four = try await reader.readBytes(4)
        #expect(String(decoding: four, as: UTF8.self) == "6789")
    }
}

@Suite("IMAP client end-to-end (scripted)")
struct IMAPClientFlowTests {

    @Test("connect → login → select → search → fetch")
    func fullFlow() async throws {
        let fetch = "* 1 FETCH (UID 7 FLAGS () RFC822.SIZE 100 "
            + "ENVELOPE (\"Wed, 17 Jul 2024 12:00:00 +0000\" \"Hello\" "
            + "((\"Ada\" NIL \"ada\" \"example.com\")) "
            + "((\"Ada\" NIL \"ada\" \"example.com\")) "
            + "((\"Ada\" NIL \"ada\" \"example.com\")) "
            + "((\"Bob\" NIL \"bob\" \"example.org\")) NIL NIL NIL \"<m@x>\"))\r\n"
        let t = ScriptedTransport(script: [
            "* OK [CAPABILITY IMAP4rev1 IDLE] ready\r\n",
            "A0001 OK LOGIN completed\r\n",
            "* 3 EXISTS\r\n* OK [UIDVALIDITY 42] ok\r\n* OK [UIDNEXT 10] ok\r\nA0002 OK [READ-WRITE] done\r\n",
            "* SEARCH 7 8 9\r\nA0003 OK done\r\n",
            fetch + "A0004 OK done\r\n"
        ])
        let client = IMAPClient(transport: t)
        try await client.connect()
        try await client.login(user: "me@icloud.com", password: "app-pw")
        let status = try await client.select("INBOX")
        #expect(status.exists == 3)
        #expect(status.uidValidity == 42)
        #expect(status.uidNext == 10)

        let uids = try await client.uidSearch("ALL")
        #expect(uids == [7, 8, 9])

        let messages = try await client.fetchSummaries(uidSet: "7:9")
        #expect(messages.count == 1)
        #expect(messages.first?.uid == 7)
        #expect(messages.first?.subject == "Hello")
        #expect(messages.first?.from.first?.address == "ada@example.com")
        #expect(messages.first?.folderPath == "INBOX")

        // The client issued correctly-tagged commands.
        #expect(t.sentString.contains("A0001 LOGIN"))
        #expect(t.sentString.contains("A0002 SELECT \"INBOX\""))
        #expect(t.sentString.contains("A0003 UID SEARCH ALL"))
        #expect(t.sentString.contains("A0004 UID FETCH 7:9"))
    }

    @Test("AUTHENTICATE PLAIN success (base64 credentials)")
    func authPlain() async throws {
        let t = ScriptedTransport(script: [
            "* OK ready\r\n",
            "+ \r\n",                       // continuation request
            "A0001 OK authenticated\r\n"
        ])
        let client = IMAPClient(transport: t)
        try await client.connect()
        try await client.authenticatePlain(user: "me@icloud.com", password: "abcd-efgh-ijkl-mnop")
        #expect(t.sentString.contains("A0001 AUTHENTICATE PLAIN"))
        // The base64 of \0user\0pass must be present (no quoting of the password).
        let expected = Data("\u{00}me@icloud.com\u{00}abcd-efgh-ijkl-mnop".utf8).base64EncodedString()
        #expect(t.sentString.contains(expected))
    }

    @Test("AUTHENTICATE PLAIN failure surfaces authenticationFailed")
    func authPlainFails() async throws {
        let t = ScriptedTransport(script: [
            "* OK ready\r\n",
            "+ \r\n",
            "A0001 NO [AUTHENTICATIONFAILED] bad\r\n"
        ])
        let client = IMAPClient(transport: t)
        try await client.connect()
        await #expect(throws: IMAPClientError.self) {
            try await client.authenticatePlain(user: "x", password: "y")
        }
    }

    @Test("AUTHENTICATE XOAUTH2 success")
    func xoauth2() async throws {
        let t = ScriptedTransport(script: [
            "* OK ready\r\n",
            "A0001 OK authenticated\r\n"
        ])
        let client = IMAPClient(transport: t)
        try await client.connect()
        try await client.authenticateXOAUTH2(user: "u@gmail.com", accessToken: "TOK")
        #expect(t.sentString.contains("A0001 AUTHENTICATE XOAUTH2 "))
    }

    @Test("STARTTLS issues the command and upgrades the transport")
    func starttls() async throws {
        let t = ScriptedTransport(script: [
            "* OK ready\r\n",
            "A0001 OK begin TLS negotiation\r\n"
        ])
        let client = IMAPClient(transport: t)
        try await client.connect()
        try await client.startTLS()
        #expect(t.sentString.contains("A0001 STARTTLS"))
        #expect(t.didStartTLS == true)
    }

    @Test("login failure surfaces as authenticationFailed")
    func loginFails() async throws {
        let t = ScriptedTransport(script: [
            "* OK ready\r\n",
            "A0001 NO [AUTHENTICATIONFAILED] bad password\r\n"
        ])
        let client = IMAPClient(transport: t)
        try await client.connect()
        await #expect(throws: IMAPClientError.self) {
            try await client.login(user: "x", password: "y")
        }
    }
}

@Suite("SMTP client (scripted)")
struct SMTPClientFlowTests {

    @Test("connect → EHLO → AUTH LOGIN → send")
    func sendFlow() async throws {
        let t = ScriptedTransport(script: [
            "220 smtp.example.com ESMTP\r\n",
            "250-smtp.example.com\r\n250 AUTH LOGIN XOAUTH2\r\n",
            "334 VXNlcm5hbWU6\r\n",
            "334 UGFzc3dvcmQ6\r\n",
            "235 2.7.0 Accepted\r\n",
            "250 2.1.0 Ok\r\n",       // MAIL FROM
            "250 2.1.5 Ok\r\n",       // RCPT TO
            "354 End data with <CR><LF>.<CR><LF>\r\n",
            "250 2.0.0 Queued\r\n"    // end of DATA
        ])
        let client = SMTPClient(transport: t)
        try await client.connect()
        #expect(await client.supportsXOAUTH2 == true)
        try await client.authLogin(user: "ada@example.com", password: "secret")

        let msg = OutgoingMessage(
            from: MailAddress(address: "ada@example.com"),
            to: [MailAddress(address: "bob@example.org")],
            subject: "Hi", textBody: "Hello Bob"
        )
        let raw = MIMEBuilder.build(msg)
        try await client.send(from: "ada@example.com", recipients: ["bob@example.org"], rawMessage: raw)

        #expect(t.sentString.contains("EHLO"))
        #expect(t.sentString.contains("AUTH LOGIN"))
        #expect(t.sentString.contains("MAIL FROM:<ada@example.com>"))
        #expect(t.sentString.contains("RCPT TO:<bob@example.org>"))
        #expect(t.sentString.contains("\r\n.\r\n"))
    }

    @Test("dot-stuffing escapes leading-dot lines")
    func dotStuffing() {
        let input = Array("line one\r\n.hidden\r\nlast".utf8)
        let out = String(decoding: SMTPClient.dotStuff(input), as: UTF8.self)
        #expect(out == "line one\r\n..hidden\r\nlast")
    }
}
