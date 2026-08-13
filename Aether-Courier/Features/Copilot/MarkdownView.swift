import SwiftUI

/// A lightweight, dependency-free Markdown renderer for copilot replies. Parses
/// the common block constructs (headings, bullet/numbered lists, fenced code,
/// blockquotes, rules, paragraphs) into SwiftUI views, and uses Foundation's
/// `AttributedString(markdown:)` for inline styling (bold, italic, `code`,
/// links) within each block.
struct MarkdownView: View {
    let text: String
    private let blocks: [MDBlock]

    init(_ text: String) {
        self.text = text
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 2 : 0)

        case .paragraph(let content):
            inline(content).fixedSize(horizontal: false, vertical: true)

        case .bulleted(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).").foregroundStyle(.secondary).monospacedDigit()
                        inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))

        case .quote(let content):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                inline(content).foregroundStyle(.secondary).italic()
            }

        case .rule:
            Divider()
        }
    }

    /// Renders inline markdown (bold/italic/code/links) as a styled Text.
    private func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

// MARK: - Parser

enum MDBlock: Equatable {
    case heading(level: Int, String)
    case paragraph(String)
    case bulleted([String])
    case numbered([String])
    case code(String)
    case quote(String)
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var i = 0

        func isListItem(_ s: String) -> Bool { unorderedMarker(s) != nil }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if line.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // consume closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // Blank line — block separator.
            if line.isEmpty { i += 1; continue }

            // Horizontal rule.
            if line == "---" || line == "***" || line == "___" {
                blocks.append(.rule); i += 1; continue
            }

            // Heading.
            if let (level, content) = heading(line) {
                blocks.append(.heading(level: level, content)); i += 1; continue
            }

            // Blockquote (collect consecutive).
            if line.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }

            // Ordered list (collect consecutive).
            if orderedMarker(line) != nil {
                var items: [String] = []
                while i < lines.count, let content = orderedMarker(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(content); i += 1
                }
                blocks.append(.numbered(items)); continue
            }

            // Unordered list (collect consecutive).
            if isListItem(line) {
                var items: [String] = []
                while i < lines.count, let content = unorderedMarker(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(content); i += 1
                }
                blocks.append(.bulleted(items)); continue
            }

            // Paragraph (collect until blank / block boundary).
            var para: [String] = []
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l.hasPrefix("```") || l.hasPrefix(">") || heading(l) != nil
                    || isListItem(l) || orderedMarker(l) != nil || l == "---" { break }
                para.append(l); i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))) }
        }
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        let content = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return (level, content)
    }

    private static func unorderedMarker(_ line: String) -> String? {
        for m in ["- ", "* ", "+ "] where line.hasPrefix(m) {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private static func orderedMarker(_ line: String) -> String? {
        // "12. content"
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
