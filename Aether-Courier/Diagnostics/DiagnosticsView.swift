import SwiftUI
import AppKit

/// Live log viewer. Tails the CourierLog buffer so the user (and support) can
/// see exactly what succeeded or failed, with level filtering and one-click
/// access to the log file on disk.
struct DiagnosticsView: View {
    @State private var lines: [String] = []
    @State private var filter: LevelFilter = .all
    @State private var autoScroll = true
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all = "All", info = "INFO+", warn = "WARN+", error = "ERROR"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .onChange(of: lines.count) {
                    if autoScroll { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 380)
        .onAppear { lines = CourierLog.shared.recent() }
        .onReceive(timer) { _ in lines = CourierLog.shared.recent() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("Diagnostics", systemImage: "stethoscope").font(.headline)
            Picker("", selection: $filter) {
                ForEach(LevelFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Toggle("Auto-scroll", isOn: $autoScroll).toggleStyle(.checkbox)
            Spacer()
            Text("\(filtered.count) lines").font(.caption).foregroundStyle(.secondary)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([CourierLog.shared.fileURL]) }
            Button("Copy") { copyAll() }
            Button("Clear") { CourierLog.shared.clear(); lines = [] }
        }
        .padding(10)
    }

    private var filtered: [String] {
        switch filter {
        case .all:   return lines
        case .info:  return lines.filter { !$0.contains("[DEBUG]") }
        case .warn:  return lines.filter { $0.contains("[WARN]") || $0.contains("[ERROR]") }
        case .error: return lines.filter { $0.contains("[ERROR]") }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[ERROR]") { return .red }
        if line.contains("[WARN]") { return .orange }
        if line.contains("[DEBUG]") { return .secondary }
        return .primary
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filtered.joined(separator: "\n"), forType: .string)
    }
}
