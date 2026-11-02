import SwiftUI

enum RootTab: Hashable {
    case shelf, files, add, settings
}

/// Bottom tab bar: 书架 / 文件 / ➕ / 设置.
/// On iOS 26 the system renders the tab bar (and every toolbar) in Liquid Glass
/// automatically — no custom chrome needed for the bar itself.
struct RootTabView: View {
    @EnvironmentObject private var store: AppStore

    @AppStorage("mangadock.tab.shelf") private var showShelf = true
    @AppStorage("mangadock.tab.files") private var showFiles = true

    /// Explicit selection, so the tab bar stays put across rebuilds.
    @State private var selection: RootTab = .shelf
    /// ➕ 只是个入口，不承载页面：选中就弹导入向导
    @State private var showImport = false
    /// 弹窗前停在哪个 tab，关闭后回到那儿
    @State private var lastTab: RootTab = .shelf
    /// 这次弹窗里真的存了一套配置吗？存了就直接跳到「文件」看库
    @State private var didAddServer = false

    private var visibleTabs: [RootTab] {
        var tabs: [RootTab] = []
        if showShelf { tabs.append(.shelf) }
        if showFiles { tabs.append(.files) }
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
            // ➕ 放在最后一项之前：iOS 的 TabView 没法真的在中间插一个非 tab 按钮，
            // 所以它是个空 tab —— 选中即弹窗，弹窗关掉再切回原来的位置。
            Tab(value: RootTab.add) {
                Color.clear
            } label: {
                Label("添加", systemImage: "plus.circle.fill")
            }
            Tab("设置", systemImage: "gearshape.fill", value: RootTab.settings) {
                NavigationStack {
                    SettingsHomeView()
                }
            }
        }
        .sheet(isPresented: $showImport, onDismiss: {
            let target: RootTab = didAddServer ? .files : lastTab
            didAddServer = false
            selection = visibleTabs.contains(target) ? target : (visibleTabs.first ?? .settings)
        }) {
            ImportFlowView {
                didAddServer = true
            }
        }
        .onChange(of: selection) { _, newValue in
            if newValue == .add {
                showImport = true
            } else {
                lastTab = newValue
            }
        }
        .onChange(of: showShelf) { _ in ensureSelectionVisible() }
        .onChange(of: showFiles) { _ in ensureSelectionVisible() }
        .onAppear { ensureSelectionVisible() }
    }

    private func ensureSelectionVisible() {
        // ➕ 不在 visibleTabs 里，但它是合法停留位置（弹窗期间），别踢走
        if selection == .add { return }
        if !visibleTabs.contains(selection) {
            selection = visibleTabs.first ?? .settings
        }
    }
}
