import SwiftUI
import EmailKit

/// The 4-pane shell: accounts sidebar │ message list │ reading pane │ Copilot
/// inspector. Matches the reference layout while using native macOS 26
/// `NavigationSplitView` + `.inspector` and Liquid Glass materials.
struct RootView: View {
    @Environment(CourierStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AccountsSidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } content: {
            MessageListView()
                // Wide enough that, when the sidebar is collapsed and this becomes
                // the leftmost pane, the traffic lights + toolbar icons still fit.
                .navigationSplitViewColumnWidth(min: 340, ideal: 390, max: 560)
        } detail: {
            ReadingPaneView()
        }
        .inspector(isPresented: $store.isCopilotVisible) {
            CopilotView()
                .inspectorColumnWidth(min: 260, ideal: 330, max: 460)
        }
        .tint(.aetherAccent)   // violet selection/accents app-wide
        .toolbar { toolbarContent }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)   // dark toolbar chrome across ALL columns (incl. the sidebar band)
        .sheet(isPresented: $store.isAddingAccount) { AddAccountSheet() }
        .sheet(isPresented: $store.isComposing) { ComposeView() }
        .overlay(alignment: .bottom) { bannerView }
        .onAppear { store.updateDockBadge() }
        .onChange(of: store.totalUnreadCount) { store.updateDockBadge() }
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if store.isAIWorking {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(LinearGradient.aetherAccent)
                    Text("AI working\(store.backgroundAITasks > 1 ? " (\(store.backgroundAITasks))" : "")…")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                }
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .help("The AI is running on your GPU — background email summaries / triage. Turn these off in Settings → Copilot.")
                .transition(.opacity)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.beginCompose() } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            Button { store.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isSyncing)
            Button { store.undoLast() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            Button { openWindow(id: "diagnostics") } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            // Copilot show/hide — standard right-inspector icon, in the group.
            Button { withAnimation { store.userSetCopilotVisible(!store.isCopilotVisible) } } label: {
                Label("Copilot", systemImage: "sidebar.trailing")
            }
            .help("Show/hide the Copilot (⌘J)")
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = store.banner {
            Text(banner)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.orange.opacity(0.5)))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { store.banner = nil }
                .task {
                    try? await Task.sleep(for: .seconds(6))
                    store.banner = nil
                }
        }
    }
}
