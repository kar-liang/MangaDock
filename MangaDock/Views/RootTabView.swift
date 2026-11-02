import SwiftUI

enum RootTab: Hashable {
    case shelf, files, settings, add
}

/// 底栏用系统 `TabView` —— 液态玻璃、长按气泡、滑动过渡、推页隐藏全由系统负责。
///
/// 曾经自绘过一版「左胶囊 + 右侧独立 ➕」的分裂布局，能做到但代价太大：
/// 系统的动效全部要手工模仿，而且永远差一截（长按气泡的折射是私有的）。
/// 后来逆向 LCSign 才发现那种分离是 `Tab(role: .search)` 的原生行为，
/// 但 `.search` 点下去会变成搜索栏，`.prominent`（纯分离）又要 iOS 27 SDK。
/// 所以干脆回原生：➕ 作为最后一个 tab，排在整排的最右边。
struct RootTabView: View {
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
            Tab("设置", systemImage: "gearshape.fill", value: RootTab.settings) {
                NavigationStack {
                    SettingsHomeView()
                }
            }
            // ➕ 排在最后 = 视觉上的最右边。iOS 的 TabView 没法在中间插非 tab 按钮，
            // 所以它是个空 tab —— 选中即弹窗，弹窗关掉再切回原来的位置。
            Tab(value: RootTab.add) {
                Color.clear
            } label: {
                Label("添加", systemImage: "plus.circle.fill")
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
