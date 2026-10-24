import SwiftUI

enum RootTab: Hashable {
    case shelf, files, history, settings
}

/// Bottom tab bar: 书架 / 文件 / 记录 / 设置.
/// On iOS 26 the system renders the tab bar (and every toolbar) in Liquid Glass
/// automatically — no custom chrome needed for the bar itself.
struct RootTabView: View {
    @EnvironmentObject private var store: AppStore

    @AppStorage("mangadock.tab.shelf") private var showShelf = true
    @AppStorage("mangadock.tab.files") private var showFiles = true
    @AppStorage("mangadock.tab.history") private var showHistory = false

    /// Explicit selection, so the tab bar stays put across rebuilds.
    @State private var selection: RootTab = .shelf

    private var visibleTabs: [RootTab] {
        var tabs: [RootTab] = []
        if showShelf { tabs.append(.shelf) }
        if showFiles { tabs.append(.files) }
        if showHistory { tabs.append(.history) }
        tabs.append(.settings)
        return tabs
    }

    var body: some View {
        TabView(selection: $selection) {
            if showShelf {
                Tab("书架", systemImage: "books.vertical.fill", value: RootTab.shelf) {
                    ShelfView()
                }
            }
            if showFiles {
                Tab("文件", systemImage: "folder.fill", value: RootTab.files) {
                    FilesView()
                }
            }
            if showHistory {
                Tab("记录", systemImage: "clock.fill", value: RootTab.history) {
                    HistoryView()
                }
            }
            Tab("设置", systemImage: "gearshape.fill", value: RootTab.settings) {
                NavigationStack {
                    ServerSettingsView(initialSetup: false)
                }
            }
        }
        .onChange(of: showShelf) { _ in ensureSelectionVisible() }
        .onChange(of: showFiles) { _ in ensureSelectionVisible() }
        .onChange(of: showHistory) { _ in ensureSelectionVisible() }
        .onAppear { ensureSelectionVisible() }
    }

    private func ensureSelectionVisible() {
        if !visibleTabs.contains(selection) {
            selection = visibleTabs.first ?? .settings
        }
    }
}
