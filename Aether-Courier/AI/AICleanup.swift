import Foundation

/// Cleans raw local-LLM replies the way the Aether hub used to do server-side, so a
/// locally-run model (Ollama / LM Studio) reads as cleanly in the public build as it
/// did through the backend. Reasoning models (DeepSeek-R1, Qwen/QwQ, etc.) emit
/// `<think>…</think>` blocks and "Thought:/Plan:" meta-commentary; the hub stripped
/// those from the output. Prompts are already identical either way (the backend
/// forwarded chat requests unchanged) — this only tidies the *reply*. Model-agnostic
/// and safe on already-clean text.
enum AICleanup {

    static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text

        func rx(_ pattern: String) {
            s = s.replacingOccurrences(of: pattern, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }

        // 1. Reasoning blocks: <think>/<thinking>/<thought>/<reasoning>/<analysis>/<details> … </…>
        rx(#"(?s)<(think|thinking|thought|reasoning|analysis|details)>.*?</\1>"#)
        // Unclosed reasoning block (model was cut off mid-thought) — drop tag to end.
        rx(#"(?s)<(think|thinking|thought|reasoning|analysis)>.*$"#)

        // 2. Leading bracketed thought intros: "[thought process …]" / "(thinking …)".
        rx(#"(?s)^\s*[\(\[]\s*(this will be a short thought process|thought process|thinking process)[\s\S]*?[\)\]]\s*"#)

        // 3. If the model prefixed its reasoning and then an explicit answer header,
        //    keep only what follows the header.
        if let r = s.range(of: #"(?im)^[ \t]*(?:\*{0,2}|#{1,3}[ \t]*)(Final Response|Final Answer|Response|Answer|Output)[ \t]*:?[ \t]*\*{0,2}[ \t]*$"#,
                           options: .regularExpression) {
            s = String(s[r.upperBound...])
        }

        // 4. Strip leading Thought:/Thinking:/Plan: lines.
        rx(#"(?im)^[ \t]*(?:\*{0,2}|#{1,3}[ \t]*)(Thought|Thinking|Plan)[ \t]*:.*(?:\n|$)"#)

        // 5. Drop leading meta-commentary lines until the real answer starts.
        s = stripLeadingMeta(s)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let metaPrefixes: [String] = [
        "the user", "i should", "i need to", "i must", "i will", "i'll ", "i'm going to",
        "since the user", "based on the", "analyzing", "let's ", "let me ",
        "we should", "we need to", "my goal is", "to respond", "to address the",
        "to answer", "thinking process", "thought:", "thinking:", "plan:",
        "here is a ", "here's a "
    ]

    /// Removes only *leading* lines that clearly read as meta-cognition, stopping at
    /// the first real line. Length-capped so genuine email content (which can
    /// legitimately begin "The user asked…") isn't eaten.
    private static func stripLeadingMeta(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var drop = 0
        while drop < lines.count {
            let low = lines[drop].trimmingCharacters(in: .whitespaces).lowercased()
            if low.isEmpty { drop += 1; continue }
            if low.count < 160 && metaPrefixes.contains(where: { low.hasPrefix($0) }) {
                drop += 1
            } else {
                break
            }
        }
        if drop > 0 { lines.removeFirst(min(drop, lines.count)) }
        return lines.joined(separator: "\n")
    }
}
