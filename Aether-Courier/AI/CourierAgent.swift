import Foundation
import EmailKit
import AppKit
import Vision
import PDFKit

/// Per-request agent state: maps short handles (m1, m2…) to concrete messages so
/// the model can reference them across tool calls.
final class AgentRun {
    private(set) var handles: [String: MailMessage] = [:]
    private var counter = 0
    @discardableResult
    func register(_ message: MailMessage) -> String {
        counter += 1
        let handle = "m\(counter)"
        handles[handle] = message
        return handle
    }
    func message(_ handle: String) -> MailMessage? { handles[handle] }
}

@MainActor
extension CourierStore {

    /// Runs a free-form copilot request as an **agent**: the model can call tools
    /// to read and organize mail. Safety model:
    /// • Organizing actions (read/star/archive/move) run autonomously — reversible.
    /// • Trash = move to the Trash folder (recoverable); never a permanent delete.
    /// • Sending is never autonomous — reply/compose open a prefilled draft you
    ///   review and Send yourself.
    /// • Unsubscribe surfaces the List-Unsubscribe link and opens it in your browser.
    func runAgent(_ userPrompt: String) {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logInfo("Agent: runAgent '\(trimmed.prefix(60))'", category: "agent")
        deferBackgroundWork()   // the agent may need IMAP — keep the warmer out of its way
        copilotTurns.append(CopilotTurn(role: .user, text: trimmed))
        copilotBusy = true
        copilotTask = Task {
            await agentLoop(trimmed)
            if Task.isCancelled { return }
            copilotBusy = false
            copilotTask = nil
        }
    }

    private func agentLoop(_ userPrompt: String) async {
        let run = AgentRun()
        var systemPrompt = Self.agentSystemPrompt()
        if let openMsg = selectedMessage {
            let openHandle = run.register(openMsg)
            let sender = openMsg.from.first?.address ?? "unknown"
            var openContext = "\n\nNote: The user currently has an email open in the viewer: handle '\(openHandle)' from sender '\(sender)' with subject \"\(openMsg.subject)\"."
            if let atts = openBody?.attachments, !atts.isEmpty {
                let names = atts.map(\.filename).joined(separator: ", ")
                openContext += " It has attachment(s): [\(names)]. Call get_attachment_text or inspect_attachment_image directly on handle '\(openHandle)' if asked to inspect or summarize attachments."
            }
            systemPrompt += openContext
        }
        systemPrompt += "\n\n" + settings.aiAutonomy.directive   // user-set: cautious ↔ aggressive
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]
        let tools = Self.toolSchemas()
        let model = await ai.currentModel
        logInfo("Agent: model=\(model), \(tools.count) tools — entering loop", category: "agent")
        var nudges = 0

        for round in 0..<12 {
            if Task.isCancelled { return }
            let body: [String: Any] = ["model": model, "messages": messages, "tools": tools, "stream": false]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                copilotTurns.append(CopilotTurn(role: .assistant, text: "⚠️ Could not build the request.")); return
            }
            logInfo("Agent: round \(round) → POST (\(bodyData.count) bytes)", category: "agent")
            let respData: Data
            do { respData = try await ai.postChat(bodyData) }
            catch {
                if Task.isCancelled { return }   // user hit stop — no error bubble
                logError("Agent: round \(round) POST failed — \(error.localizedDescription)", category: "agent")
                copilotTurns.append(CopilotTurn(role: .assistant, text: "⚠️ \(error.localizedDescription)")); return
            }
            logInfo("Agent: round \(round) ← \(respData.count) bytes", category: "agent")
            guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let assistantMsg = choices.first?["message"] as? [String: Any] else {
                copilotTurns.append(CopilotTurn(role: .assistant, text: "⚠️ Unexpected AI response.")); return
            }
            messages.append(sanitize(assistantMsg))

            // Fast path: native OpenAI tool_calls (if the model supports them).
            if let toolCalls = assistantMsg["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                for call in toolCalls {
                    let id = call["id"] as? String ?? UUID().uuidString
                    let fn = call["function"] as? [String: Any]
                    let name = fn?["name"] as? String ?? ""
                    let argString = (fn?["arguments"] as? String) ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(argString.utf8))) as? [String: Any] ?? [:]
                    let (summary, result) = await executeTool(name: name, args: args, run: run)
                    if !summary.isEmpty { copilotTurns.append(CopilotTurn(role: .assistant, text: "🔧 " + summary)) }
                    messages.append(["role": "tool", "tool_call_id": id, "name": name, "content": result])
                }
                continue
            }

            // Portable path: the model emits ONE JSON action per turn.
            let content = assistantMsg["content"] as? String ?? ""
            if let obj = extractJSON(content) {
                let toolName = (obj["tool"] as? String) ?? (obj["name"] as? String) ?? (obj["function"] as? String) ?? (obj["action"] as? String)
                if let toolName, obj["final"] == nil {
                    let args = (obj["args"] as? [String: Any]) ?? (obj["arguments"] as? [String: Any]) ?? (obj["parameters"] as? [String: Any]) ?? (obj["action_input"] as? [String: Any]) ?? [:]
                    let (summary, result) = await executeTool(name: toolName, args: args, run: run)
                    if !summary.isEmpty { copilotTurns.append(CopilotTurn(role: .assistant, text: "🔧 " + summary)) }
                    messages.append(["role": "user",
                                     "content": "TOOL RESULT [\(toolName)]: \(result)\nEmit your next JSON action, or {\"final\":\"…\"} when done."])
                    continue
                }
            }
            let finalText = extractFinalText(content) ?? content
            var cleaned = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("{") && (cleaned.contains("\"tool\"") || cleaned.contains("\"name\"") || cleaned.contains("\"final\"")) {
                if let f = extractFinalText(cleaned) {
                    cleaned = f
                }
            }
            if cleaned.hasPrefix("{\"final\":") || cleaned.hasPrefix("{\"final\" :") {
                if let firstQuote = cleaned.range(of: ":\"")?.upperBound {
                    cleaned = String(cleaned[firstQuote...])
                    if cleaned.hasSuffix("\"}") {
                        cleaned.removeLast(2)
                    } else if cleaned.hasSuffix("}") {
                        cleaned.removeLast(1)
                    }
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // Some models emit a placeholder like "..." instead of continuing —
            // nudge them back onto the protocol rather than dead-ending.
            let looksEmpty = cleaned.isEmpty || cleaned.allSatisfy { $0 == "." || $0 == "…" || $0.isWhitespace }
            if looksEmpty && nudges < 3 {
                nudges += 1
                messages.append(["role": "user",
                                 "content": "You didn't emit a valid action. If there's more to do, reply with ONE {\"tool\":...} action. If you're done, reply with {\"final\":\"<short summary>\"}. Do not reply with \"...\"."])
                continue
            }
            let final = AICleanup.sanitize(cleaned)   // strip reasoning/meta the hub used to
            if !final.isEmpty { copilotTurns.append(CopilotTurn(role: .assistant, text: final)) }
            return
        }
    }

    private func sanitize(_ msg: [String: Any]) -> [String: Any] {
        var copy: [String: Any] = [:]
        copy["role"] = msg["role"]
        if let c = msg["content"] as? String { copy["content"] = c }
        if let tc = msg["tool_calls"] { copy["tool_calls"] = tc }
        return copy
    }

    // MARK: - Tool dispatch

    private func executeTool(name: String, args: [String: Any], run: AgentRun) async -> (summary: String, result: String) {
        switch name {
        case "list_messages":            return listMessages(args, run)
        case "find_messages":            return findMessages(args, run)
        case "get_body":                 return await getBodyTool(args, run)
        case "mark_read":                return markReadTool(args, run)
        case "star":                     return starTool(args, run)
        case "archive":                  return archiveTool(args, run)
        case "trash":                    return trashTool(args, run)
        case "mark_spam":                return markSpamTool(args, run)
        case "block_sender":             return blockSenderTool(args, run)
        case "move_to_folder":           return moveTool(args, run)
        case "sort_into_folders":        return sortIntoFoldersTool()
        case "empty_trash":              return await emptyTrashTool()
        case "empty_spam", "empty_junk": return await emptySpamTool()
        case "draft_reply":              return draftReplyTool(args, run)
        case "draft_email":              return draftEmailTool(args)
        case "create_calendar_event":    return createEventTool(args)
        case "find_unsubscribe":         return await unsubscribeTool(args, run)
        case "list_attachments":         return await listAttachmentsTool(args, run)
        case "get_attachment_text":      return await getAttachmentTextTool(args, run)
        case "inspect_attachment_image": return await inspectAttachmentImageTool(args, run)
        case "save_attachment":          return await saveAttachmentTool(args, run)
        default: return ("", errJSON("unknown tool: \(name)"))
        }
    }

    private func resolve(_ args: [String: Any], _ run: AgentRun) -> [MailMessage] {
        var handles: [String] = []
        if let arr = args["handles"] as? [String] { handles = arr }
        else if let one = args["handle"] as? String { handles = [one] }
        let found = handles.compactMap { run.message($0) }
        if !found.isEmpty { return found }

        // If an explicit address argument was provided (e.g. for block_sender),
        // match messages by sender address rather than guessing the open viewer message.
        if let addr = (args["address"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !addr.isEmpty {
            let matches = accounts.flatMap { acc in
                inboxMessages(for: acc.id).filter { m in
                    m.from.contains { $0.address.lowercased() == addr }
                }
            }
            if !matches.isEmpty { return matches }
        }

        // If handles explicitly asked for open/current, OR if handles was empty with no address provided,
        // use the initial message registered in this agent run (m1), NOT whatever selectedMessage mutated to.
        if handles.contains("open") || handles.contains("current") || (handles.isEmpty && args["address"] == nil) {
            if let initial = run.handles["m1"] {
                return [initial]
            }
        }
        return []
    }

    private func listMessages(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let scope = (args["scope"] as? String) ?? "unread"
        let limit = (args["limit"] as? Int) ?? 40
        var pool = accounts.flatMap { acc in inboxMessages(for: acc.id).map { (acc, $0) } }
        if scope == "unread" { pool = pool.filter { $0.1.isUnread } }
        let picked = pool.sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }.prefix(limit)
        return ("Listed \(picked.count) \(scope) messages.", messageListText(Array(picked), run))
    }

    private func findMessages(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let fromSub = ((args["from_contains"] as? String) ?? "").lowercased()
        let subjSub = ((args["subject_contains"] as? String) ?? "").lowercased()
        let unreadOnly = (args["unread_only"] as? Bool) ?? false

        var pool = accounts.flatMap { acc in inboxMessages(for: acc.id).map { (acc, $0) } }
        if unreadOnly { pool = pool.filter { $0.1.isUnread } }
        if !fromSub.isEmpty {
            pool = pool.filter { _, m in
                m.from.contains { $0.shortLabel.lowercased().contains(fromSub) || $0.address.lowercased().contains(fromSub) }
            }
        }
        if !subjSub.isEmpty {
            pool = pool.filter { _, m in m.subject.lowercased().contains(subjSub) }
        }
        let matches = pool.sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }
        return ("Found \(matches.count) matching message(s).", messageListText(Array(matches.prefix(40)), run))
    }

    private func messageListText(_ items: [(MailAccount, MailMessage)], _ run: AgentRun) -> String {
        guard !items.isEmpty else { return jsonString(["messages": []]) }
        var list: [[String: String]] = []
        for (acc, m) in items {
            let h = run.register(m)
            list.append([
                "handle": h,
                "account": acc.displayName,
                "from": m.from.first?.shortLabel ?? "unknown",
                "address": m.from.first?.address ?? "",
                "subject": m.subject,
                "unread": m.isUnread ? "true" : "false",
                "starred": m.flags.contains(.flagged) ? "true" : "false"
            ])
        }
        return jsonString(["messages": list])
    }

    private func getBodyTool(_ args: [String: Any], _ run: AgentRun) async -> (String, String) {
        guard let m = resolve(args, run).first, let acc = account(for: m) else { return ("", errJSON("message not found")) }
        let body: MailBody?
        if m.id == selectedMessageID, let open = openBody { body = open }
        else { body = try? await mailService.fetchBody(acc, folderPath: m.folderPath, uid: m.uid) }
        let text = body?.bestText ?? "(empty body)"
        var attNames: [String] = []
        if let atts = body?.attachments, !atts.isEmpty {
            attNames = atts.map { "\($0.filename) (\($0.mimeType), \(ByteCountFormatter.string(fromByteCount: Int64($0.sizeBytes), countStyle: .file)))" }
        }
        return ("Read body of “\(m.subject)”.", jsonString([
            "subject": m.subject,
            "from": m.from.first?.address ?? "",
            "attachments": attNames,
            "body": String(text.prefix(4000))
        ]))
    }

    private func markReadTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let msgs = resolve(args, run)
        let unread = (args["unread"] as? Bool) ?? false
        for m in msgs { setRead(m, !unread) }
        return ("Marked \(msgs.count) message(s) as \(unread ? "unread" : "read").", okJSON(msgs.count))
    }

    private func starTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let msgs = resolve(args, run)
        for m in msgs { toggleFlagged(m) }
        return ("Toggled star for \(msgs.count) message(s).", okJSON(msgs.count))
    }

    private func archiveTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let msgs = resolve(args, run)
        moveMessages(msgs, toRole: .archive)
        return ("Archived \(msgs.count) message(s).", okJSON(msgs.count))
    }

    private func trashTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let msgs = resolve(args, run)
        moveMessages(msgs, toRole: .trash)
        return ("Moved \(msgs.count) message(s) to Trash.", okJSON(msgs.count))
    }

    private func markSpamTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let msgs = resolve(args, run)
        moveMessages(msgs, toRole: .junk)   // move only — does NOT block the sender
        return ("Moved \(msgs.count) message(s) to Junk.", okJSON(msgs.count))
    }

    private func blockSenderTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        var addrs: [String] = []
        if let a = args["address"] as? String, !a.isEmpty {
            addrs.append(a.trimmingCharacters(in: .whitespaces).lowercased())
        }
        let msgs = resolve(args, run)
        for m in msgs { addrs.append(contentsOf: m.from.map(\.address)) }
        let clean = Array(Set(addrs.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })).filter { !$0.isEmpty }
        guard !clean.isEmpty else { return ("", errJSON("no sender address specified")) }
        for addr in clean { blockSender(addr) }

        let toJunk = !msgs.isEmpty ? msgs : accounts.flatMap { acc in
            inboxMessages(for: acc.id).filter { m in
                m.from.contains { clean.contains($0.address.lowercased()) }
            }
        }
        if !toJunk.isEmpty {
            moveMessages(toJunk, toRole: .junk)
        }
        return ("Blocked \(clean.joined(separator: ", ")) — moving current and future mail to Junk.", okJSON(clean.count))
    }

    private func moveTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        let msgs = resolve(args, run)
        guard let roleStr = args["folder"] as? String else { return ("", errJSON("folder role required")) }
        let role = folderRole(roleStr)
        moveMessages(msgs, toRole: role)
        return ("Moved \(msgs.count) message(s) to \(role.rawValue).", okJSON(msgs.count))
    }

    private func sortIntoFoldersTool() -> (String, String) {
        let summary = autoSortInboxesIntoFolders()
        return (summary, jsonString(["result": summary]))
    }

    private func emptyTrashTool() async -> (String, String) {
        let summary = await performEmpty(role: .trash)
        return (summary, jsonString(["result": summary]))
    }

    private func emptySpamTool() async -> (String, String) {
        let summary = await performEmpty(role: .junk)
        return (summary, jsonString(["result": summary]))
    }

    private func draftReplyTool(_ args: [String: Any], _ run: AgentRun) -> (String, String) {
        guard let m = resolve(args, run).first, let acc = account(for: m) else { return ("", errJSON("message not found")) }
        let subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
        composeDraft = ComposeDraft(accountID: acc.id, to: m.from.map(\.address).joined(separator: ", "),
                                    subject: subject, body: (args["body"] as? String) ?? "", inReplyTo: m.messageID)
        isComposing = true
        return ("Opened a reply draft to \(m.from.first?.shortLabel ?? "sender") — review and Send.", okJSON(1))
    }

    private func draftEmailTool(_ args: [String: Any]) -> (String, String) {
        guard let acc = accounts.first else { return ("", errJSON("no account")) }
        composeDraft = ComposeDraft(accountID: acc.id, to: (args["to"] as? String) ?? "",
                                    subject: (args["subject"] as? String) ?? "", body: (args["body"] as? String) ?? "")
        isComposing = true
        return ("Opened a draft email to \((args["to"] as? String) ?? "") — review and Send.", okJSON(1))
    }

    private func createEventTool(_ args: [String: Any]) -> (String, String) {
        let title = (args["title"] as? String) ?? "Event"
        guard let start = parseDate(args["start"]) else { return ("", errJSON("invalid start date (use ISO 8601)")) }
        let end = parseDate(args["end"]) ?? start.addingTimeInterval(3600)
        let ok = calendar.createEvent(title: title, start: start, end: end, notes: args["notes"] as? String)
        return (ok ? "Created calendar event “\(title)”." : "Couldn't create the event (grant calendar access).",
                okJSON(ok ? 1 : 0))
    }

    private func unsubscribeTool(_ args: [String: Any], _ run: AgentRun) async -> (String, String) {
        guard let m = resolve(args, run).first, let acc = account(for: m) else {
            return ("", errJSON("No message specified or open in viewer."))
        }
        var unsubscribeHeader: String? = nil
        do {
            unsubscribeHeader = try await mailService.fetchHeader(acc, folderPath: m.folderPath, uid: m.uid, name: "List-Unsubscribe")
        } catch {}

        var targetURL: URL? = nil
        var mailtoAddress: String? = nil

        // 1. Try parsing header
        if let header = unsubscribeHeader {
            let rawLinks = header.components(separatedBy: ",")
            for raw in rawLinks {
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
                if cleaned.lowercased().hasPrefix("http://") || cleaned.lowercased().hasPrefix("https://") {
                    if let u = URL(string: cleaned) { targetURL = u; break }
                } else if cleaned.lowercased().hasPrefix("mailto:") {
                    mailtoAddress = cleaned
                }
            }
        }

        // 2. Search message body text if header didn't give an HTTP link
        if targetURL == nil {
            let bodyText: String
            if m.id == selectedMessageID, let open = openBody { bodyText = open.bestText }
            else { bodyText = (try? await mailService.fetchBody(acc, folderPath: m.folderPath, uid: m.uid))?.bestText ?? "" }

            let pattern = "(https?://[\\w\\.\\-\\?%&=/#+]+)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let nsText = bodyText as NSString
                let matches = regex.matches(in: bodyText, range: NSRange(location: 0, length: nsText.length))
                for match in matches {
                    let urlStr = nsText.substring(with: match.range)
                    let lower = urlStr.lowercased()
                    if lower.contains("unsubscribe") || lower.contains("optout") || lower.contains("opt-out") {
                        if let u = URL(string: urlStr) {
                            targetURL = u
                            break
                        }
                    }
                }
            }
        }

        if let url = targetURL {
            let opened = NSWorkspace.shared.open(url)
            let msg = opened ? "Found unsubscribe link for “\(m.subject)” and opened it in your browser (\(url.absoluteString))." : "Found unsubscribe link for “\(m.subject)”: \(url.absoluteString)."
            return (msg, jsonString(["status": "opened", "url": url.absoluteString, "list_unsubscribe": unsubscribeHeader ?? ""]))
        } else if let mailto = mailtoAddress {
            return ("Found mailto unsubscribe option for “\(m.subject)”: \(mailto).", jsonString(["status": "mailto", "mailto": mailto, "list_unsubscribe": unsubscribeHeader ?? ""]))
        } else {
            let sender = m.from.first?.address ?? "the sender"
            return ("No List-Unsubscribe header or unsubscribe link found in “\(m.subject)”. You can block this sender (\(sender)) if you wish to stop receiving emails from them.", jsonString(["status": "not_found"]))
        }
    }

    private func listAttachmentsTool(_ args: [String: Any], _ run: AgentRun) async -> (String, String) {
        guard let m = resolve(args, run).first, let acc = account(for: m) else { return ("", errJSON("message not found")) }
        let body: MailBody?
        if m.id == selectedMessageID, let open = openBody { body = open }
        else { body = try? await mailService.fetchBody(acc, folderPath: m.folderPath, uid: m.uid) }
        guard let body, !body.attachments.isEmpty else {
            return ("No attachments found on “\(m.subject)”.", jsonString(["attachments": []]))
        }
        let list: [[String: Any]] = body.attachments.enumerated().map { idx, att in
            let ext = (att.filename as NSString).pathExtension.lowercased()
            let isImage = att.mimeType.lowercased().hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
            let isText = att.mimeType.lowercased().hasPrefix("text/") || ["txt", "csv", "json", "md", "log", "xml", "html", "swift", "py", "js"].contains(ext)
            return [
                "index": idx,
                "filename": att.filename,
                "mime_type": att.mimeType,
                "size_bytes": att.sizeBytes,
                "size": ByteCountFormatter.string(fromByteCount: Int64(att.sizeBytes), countStyle: .file),
                "is_image": isImage,
                "is_text": isText
            ]
        }
        return ("Found \(body.attachments.count) attachment(s) on “\(m.subject)”.", jsonString(["attachments": list]))
    }

    private func getAttachmentTextTool(_ args: [String: Any], _ run: AgentRun) async -> (String, String) {
        guard let m = resolve(args, run).first, let acc = account(for: m) else { return ("", errJSON("message not found")) }
        let body: MailBody?
        if m.id == selectedMessageID, let open = openBody { body = open }
        else { body = try? await mailService.fetchBody(acc, folderPath: m.folderPath, uid: m.uid) }
        guard let body, !body.attachments.isEmpty else { return ("", errJSON("No attachments found on message.")) }

        let targetFilename = (args["filename"] as? String)?.lowercased()
        let targetIndex = args["index"] as? Int

        let att: MailAttachment?
        if let idx = targetIndex, idx >= 0, idx < body.attachments.count {
            att = body.attachments[idx]
        } else if let name = targetFilename {
            att = body.attachments.first { $0.filename.lowercased().contains(name) }
        } else {
            att = body.attachments.first
        }

        guard let att else { return ("", errJSON("Attachment not found.")) }
        guard let data = att.data, !data.isEmpty else {
            return ("Attachment “\(att.filename)” has no inline data.", jsonString(["filename": att.filename, "text": ""]))
        }

        // PDF text extraction via PDFKit
        let isPDF = att.mimeType.lowercased().contains("pdf") || (att.filename as NSString).pathExtension.lowercased() == "pdf"
        if isPDF {
            if let pdfDoc = PDFDocument(data: data), let pdfText = pdfDoc.string, !pdfText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ("Extracted text from PDF “\(att.filename)”.", jsonString(["filename": att.filename, "text": String(pdfText.prefix(8000))]))
            }
        }

        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            return ("Read text of attachment “\(att.filename)”.", jsonString(["filename": att.filename, "text": String(text.prefix(6000))]))
        }
        let printable = data.compactMap { (32...126).contains($0) ? String(UnicodeScalar($0)) : nil }.joined()
        return ("Extracted text from “\(att.filename)”.", jsonString(["filename": att.filename, "text": String(printable.prefix(3000))]))
    }

    private func inspectAttachmentImageTool(_ args: [String: Any], _ run: AgentRun) async -> (String, String) {
        guard let m = resolve(args, run).first, let acc = account(for: m) else { return ("", errJSON("message not found")) }
        let body: MailBody?
        if m.id == selectedMessageID, let open = openBody { body = open }
        else { body = try? await mailService.fetchBody(acc, folderPath: m.folderPath, uid: m.uid) }
        guard let body, !body.attachments.isEmpty else { return ("", errJSON("No attachments found.")) }

        let targetFilename = (args["filename"] as? String)?.lowercased()
        let att = body.attachments.first { a in
            let ext = (a.filename as NSString).pathExtension.lowercased()
            let isImg = a.mimeType.lowercased().hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
            if let name = targetFilename { return isImg && a.filename.lowercased().contains(name) }
            return isImg
        }

        guard let att, let data = att.data, !data.isEmpty else { return ("", errJSON("Image attachment not found or has no data.")) }

        let ocrText = performOCR(on: data)
        let sizeMB = String(format: "%.2f MB", Double(att.sizeBytes) / 1048576.0)
        let summary = "Inspected image “\(att.filename)” (\(sizeMB)). \(ocrText.isEmpty ? "No OCR text detected." : "OCR text extracted (\(ocrText.count) chars).")"
        return (summary, jsonString([
            "filename": att.filename,
            "mime_type": att.mimeType,
            "size_bytes": att.sizeBytes,
            "ocr_text": ocrText
        ]))
    }

    private func saveAttachmentTool(_ args: [String: Any], _ run: AgentRun) async -> (String, String) {
        guard let m = resolve(args, run).first, let acc = account(for: m) else { return ("", errJSON("message not found")) }
        let body: MailBody?
        if m.id == selectedMessageID, let open = openBody { body = open }
        else { body = try? await mailService.fetchBody(acc, folderPath: m.folderPath, uid: m.uid) }
        guard let body, !body.attachments.isEmpty else { return ("", errJSON("No attachments found.")) }

        let targetFilename = (args["filename"] as? String)?.lowercased()
        let att: MailAttachment?
        if let name = targetFilename { att = body.attachments.first { $0.filename.lowercased().contains(name) } }
        else { att = body.attachments.first }

        guard let att, let data = att.data else { return ("", errJSON("Attachment file or data not found.")) }

        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let saveURL = downloadsDir.appendingPathComponent(att.filename)
        do {
            try data.write(to: saveURL)
            NSWorkspace.shared.selectFile(saveURL.path, inFileViewerRootedAtPath: downloadsDir.path)
            return ("Saved “\(att.filename)” to Downloads folder.", jsonString(["filename": att.filename, "path": saveURL.path]))
        } catch {
            return ("", errJSON("Could not save attachment: \(error.localizedDescription)"))
        }
    }

    private func performOCR(on imageData: Data) -> String {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let results = request.results else { return "" }
            return results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            return ""
        }
    }

    // MARK: - helpers

    private func folderRole(_ s: String) -> FolderRole {
        switch s.lowercased() {
        case "junk", "spam": return .junk
        case "trash", "deleted": return .trash
        case "archive": return .archive
        case "sent": return .sent
        case "drafts": return .drafts
        default: return .inbox
        }
    }

    private func parseDate(_ val: Any?) -> Date? {
        guard let s = val as? String else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.date(from: s)
    }

    private func extractJSON(_ text: String) -> [String: Any]? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let sub = String(chars[start...i])
                    if let data = sub.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return json
                    }
                    // Try parsing after escaping unescaped control characters inside string literals
                    let sanitized = sanitizeJSONControlCharacters(sub)
                    if let data = sanitized.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return json
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private func extractFinalText(_ text: String) -> String? {
        if let json = extractJSON(text), json["tool"] == nil, json["name"] == nil, json["action"] == nil {
            if let finalVal = json["final"] as? String, !finalVal.isEmpty {
                return finalVal
            }
            var parts: [String] = []
            let primaryKeys = ["text", "content", "summary", "response", "answer"]
            for key in primaryKeys {
                if let val = json[key] as? String, !val.isEmpty {
                    parts.append(val)
                }
            }
            let secondaryKeys = ["next", "followup", "details", "explanation", "result"]
            for key in secondaryKeys {
                if let val = json[key] as? String, !val.isEmpty {
                    parts.append(val)
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n\n")
            }
            let allStringValues = json.compactMap { key, val -> String? in
                if key != "tool", key != "name", key != "action", let s = val as? String, !s.isEmpty {
                    return s
                }
                return nil
            }
            if !allStringValues.isEmpty {
                return allStringValues.joined(separator: "\n\n")
            }
        }

        for key in ["final", "text", "content", "summary", "response", "answer"] {
            let pattern = "\"\(key)\"\\s*:\\s*\"([\\s\\S]*)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsText = text as NSString
                if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
                    var extracted = nsText.substring(with: match.range(at: 1))
                    extracted = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                    if extracted.hasSuffix("}") {
                        extracted.removeLast()
                        extracted = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if extracted.hasSuffix("\"") {
                        extracted.removeLast()
                    }
                    return extracted.replacingOccurrences(of: "\\\"", with: "\"")
                                    .replacingOccurrences(of: "\\n", with: "\n")
                                    .replacingOccurrences(of: "\\\\", with: "\\")
                }
            }
        }
        return nil
    }

    private func sanitizeJSONControlCharacters(_ jsonString: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        for char in jsonString {
            if inString {
                if escaped {
                    escaped = false
                    result.append(char)
                } else if char == "\\" {
                    escaped = true
                    result.append(char)
                } else if char == "\"" {
                    inString = false
                    result.append(char)
                } else if char == "\n" {
                    result.append("\\n")
                } else if char == "\r" {
                    result.append("\\r")
                } else if char == "\t" {
                    result.append("\\t")
                } else {
                    result.append(char)
                }
            } else {
                if char == "\"" {
                    inString = true
                }
                result.append(char)
            }
        }
        return result
    }

    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    private func okJSON(_ count: Int) -> String { "{\"ok\":true,\"count\":\(count)}" }
    private func errJSON(_ message: String) -> String { jsonString(["error": message]) }

    // MARK: - prompt + schemas

    private static func agentSystemPrompt() -> String {
        """
        You are the AI copilot inside Aether Courier, a macOS email app, acting as an assistant for the user's mailboxes.

        You act by emitting EXACTLY ONE JSON object per reply and NOTHING else — no prose, no code fences, outside the JSON.
        • To use a tool:  {"tool":"<name>","args":{ ... }}
        • When finished:  {"final":"<your concise Markdown answer>"}
        After each tool call you receive a line starting with "TOOL RESULT"; then emit your next JSON.

        TOOLS:
        - find_messages {"from_contains":"google","subject_contains":"security","unread_only":false} — BEST when the user names a sender or topic; matching is done in-app and returns the exact handles. Prefer this.
        - list_messages {"scope":"unread"|"inbox","limit":40} — browse messages when no specific filter applies.
        - get_body {"handle":"m1"} — read one message's full text and lists attachment filenames/metadata.
        - mark_read {"handles":["m1","m2"],"read":true|false}
        - star {"handles":["m1"],"starred":true|false} — starring means "mark for review".
        - archive {"handles":["m1"]}
        - trash {"handles":["m1"]} — moves to Trash (recoverable).
        - mark_spam {"handles":["m1"]} — moves messages to the Junk folder. Does NOT block the sender. Only call block_sender (or the Report-as-Spam flow) when the user explicitly says something is spam and wants the sender blocked.
        - block_sender {"handle":"m1"} or {"address":"x@y.com"} — future + current mail from them goes to Junk.
        - move_to_folder {"handles":["m1"],"folder":"inbox|archive|junk|trash|sent|drafts"}
        - sort_into_folders {} — go through every inbox and move each message into an EXISTING user folder whose name matches the sender's company/service (e.g. mail from github.com → a "GitHub" folder). Messages with no matching folder are left untouched. Use this when the user asks to "sort", "organize", "file", or "tidy" their inboxes into folders. It needs no handles — it scans all inboxes itself.
        - empty_trash {} — PERMANENTLY deletes every message in every account's Trash folder. Irreversible. Call it ONLY when the user explicitly asks to "empty trash" / "empty the bin" / "permanently delete trash". It needs no handles — it operates on the Trash folders directly (find_messages/list_messages only see inboxes, so use this tool, not those, for Trash).
        - empty_spam {} — PERMANENTLY deletes every message in every account's Junk/Spam folder. Irreversible. Call it ONLY when the user explicitly asks to "empty spam" / "empty junk" / "clear the spam folder". It needs no handles.
        - draft_reply {"handle":"m1","body":"..."} — opens a reply draft for the user to review & send.
        - draft_email {"to":"a@b.com","subject":"...","body":"..."} — opens a draft for the user to review & send.
        - create_calendar_event {"title":"...","start":"2026-08-01T15:00:00Z","end":"...","notes":"..."}
        - find_unsubscribe {"handle":"m1"} — finds and opens the List-Unsubscribe header or link in default browser. Omit handle to default to open email.
        - list_attachments {"handle":"m1"} — list attachments/files/images on a message (filename, mime type, size).
        - get_attachment_text {"handle":"m1","filename":"..."} — read text/CSV/code/data content from an attached file or PDF.
        - inspect_attachment_image {"handle":"m1","filename":"..."} — inspect an attached image and extract printed/written text via macOS Vision OCR.
        - save_attachment {"handle":"m1","filename":"..."} — saves an attached file to ~/Downloads folder.

        RULES:
        • DIRECT ATTACHMENT EXECUTION: When asked to inspect or summarize an attachment (or answer a question about an open email's attachment), call get_attachment_text or inspect_attachment_image directly in round 1 using handle 'm1'. Do NOT call list_attachments, find_messages, get_body, or mark_read first when handle 'm1' is open.
        • NO UNREQUESTED ACTIONS: NEVER call mark_read, mark_spam, trash, or archive when asked to summarize or read an attachment. Only mutate message state if explicitly requested by the user.
        • IMMEDIATE SUMMARY: Once you receive the TOOL RESULT from get_attachment_text or inspect_attachment_image, emit {"final":"<your clear Markdown summary of the attachment>"} immediately. Do NOT run further tool calls after receiving the attachment text.
        • You CANNOT send mail — draft_reply/draft_email only open a draft the user sends. Say you drafted it.
        • trash moves to the Trash folder (recoverable). The only permanent deletes are empty_trash and empty_spam — call them solely when the user explicitly asks to empty the Trash or the Junk/Spam folder.
        • For unsubscribe, call find_unsubscribe — it fetches the link and opens it in the browser for the user.
        • Keep the final answer short and in Markdown.

        EXAMPLE — "summarize whats in the attachment?":
        {"tool":"get_attachment_text","args":{"handle":"m1"}}
        [TOOL RESULT: {"filename":"AppleCare_Coverage.pdf","text":"..."}]
        {"final":"### AppleCare+ Proof of Coverage Summary\n- **Plan:** AppleCare+ for Mac\n- **Term:** 3 Years..."}

        EXAMPLE — "delete all the Google security alert emails":
        {"tool":"find_messages","args":{"from_contains":"google","subject_contains":"security"}}
        …the result lists matching handles (m3, m7, m9). Then:
        {"tool":"trash","args":{"handles":["m3","m7","m9"]}}
        {"final":"Moved 3 Google security-alert emails to Trash (recoverable)."}

        NEVER reply with "..." or empty text — every reply is a single JSON action or {"final":...}. Never call the same list/find tool twice. When the user names a sender or topic, use find_messages.

        Begin now with your first JSON action.
        """
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description,
                      "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    private static func handlesParam(_ desc: String = "Message handles from list_messages, e.g. [\"m1\",\"m3\"].") -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": desc]
    }

    static func toolSchemas() -> [[String: Any]] {
        [
            tool("list_messages", "List messages for context and get their handles.",
                 ["scope": ["type": "string", "enum": ["unread", "inbox"], "description": "unread = only unread inbox mail; inbox = all inbox mail"],
                  "limit": ["type": "integer", "description": "max messages (default 40)"]]),
            tool("find_messages", "Find inbox messages by sender/subject keywords (matching done in-app). Returns the matching handles — prefer this over list_messages when the user names a sender or topic.",
                 ["from_contains": ["type": "string", "description": "substring of sender name/address, e.g. \"google\""],
                  "subject_contains": ["type": "string", "description": "substring of subject, e.g. \"security\""],
                  "unread_only": ["type": "boolean"]]),
            tool("get_body", "Read the full text body and list attachment filenames/metadata for one message.",
                 ["handle": ["type": "string", "description": "a message handle"]], required: ["handle"]),
            tool("mark_read", "Mark messages read or unread.",
                 ["handles": handlesParam(), "read": ["type": "boolean", "description": "true=read, false=unread"]],
                 required: ["handles", "read"]),
            tool("star", "Star (flag) or unstar messages — use starring to 'mark for review'.",
                 ["handles": handlesParam(), "starred": ["type": "boolean"]], required: ["handles", "starred"]),
            tool("archive", "Archive messages (move to the Archive folder).",
                 ["handles": handlesParam()], required: ["handles"]),
            tool("trash", "Move messages to Trash (recoverable).",
                 ["handles": handlesParam()], required: ["handles"]),
            tool("mark_spam", "Mark messages as spam (move them to the Junk folder).",
                 ["handles": handlesParam()], required: ["handles"]),
            tool("block_sender", "Block a sender so their current and future mail auto-moves to Junk. Give a handle or an address.",
                 ["handle": ["type": "string"], "address": ["type": "string"]]),
            tool("move_to_folder", "Move messages to a folder by role.",
                 ["handles": handlesParam(),
                  "folder": ["type": "string", "enum": ["inbox", "archive", "junk", "trash", "sent", "drafts"]]],
                 required: ["handles", "folder"]),
            tool("sort_into_folders", "Go through every inbox and move each message into an existing user folder whose name matches the sender's company/service. Messages with no matching folder are left untouched. Takes no arguments — it scans all inboxes itself.",
                 [:]),
            tool("empty_trash", "PERMANENTLY delete every message in every account's Trash folder. Irreversible. Only call when the user explicitly asks to empty the Trash. Takes no arguments.",
                 [:]),
            tool("empty_spam", "PERMANENTLY delete every message in every account's Junk/Spam folder. Irreversible. Only call when the user explicitly asks to empty Junk/Spam. Takes no arguments.",
                 [:]),
            tool("draft_reply", "Open a prefilled REPLY draft for the user to review and send.",
                 ["handle": ["type": "string"], "body": ["type": "string", "description": "the reply text"]],
                 required: ["handle", "body"]),
            tool("draft_email", "Open a prefilled NEW email draft for the user to review and send.",
                 ["to": ["type": "string"], "subject": ["type": "string"], "body": ["type": "string"]],
                 required: ["to", "subject", "body"]),
            tool("create_calendar_event", "Create a calendar event.",
                 ["title": ["type": "string"], "start": ["type": "string", "description": "ISO-8601"],
                  "end": ["type": "string", "description": "ISO-8601 (optional; default +1h)"],
                  "notes": ["type": "string"]], required: ["title", "start"]),
            tool("find_unsubscribe", "Get and open the List-Unsubscribe link for a message in your browser. Defaults to currently open email if handle is omitted.",
                 ["handle": ["type": "string"]], required: []),
            tool("list_attachments", "List attachments, files, and images on a message.",
                 ["handle": ["type": "string"]], required: []),
            tool("get_attachment_text", "Read text/CSV/PDF/code/data content from an attached file.",
                 ["handle": ["type": "string"], "filename": ["type": "string"], "index": ["type": "integer"]]),
            tool("inspect_attachment_image", "Inspect an attached image and extract printed/written text using native macOS Vision OCR.",
                 ["handle": ["type": "string"], "filename": ["type": "string"]]),
            tool("save_attachment", "Save an attached file to the user's Downloads folder (~/Downloads).",
                 ["handle": ["type": "string"], "filename": ["type": "string"]])
        ]
    }
}

private extension String {
    func lastIndexOf(of target: String) -> String.Index? {
        guard let range = self.range(of: target, options: .backwards) else { return nil }
        return range.lowerBound
    }
}


