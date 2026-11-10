import SwiftUI

enum RootTab: Hashable {
    case shelf, files, settings
}

/// 底栏用系统 `TabView` —— 液态玻璃、长按气泡、滑动过渡、推页隐藏全由系统负责。
///
/// 曾经自绘过一版「左胶囊 + 右侧独立 ➕」的分裂布局，能做到但代价太大：
/// 系统的动效全部要手工模仿，而且永远差一截（长按气泡的折射是私有的）。
/// 后来逆向 LCSign 才发现那种分离是 `Tab(role: .search)` 的原生行为，
/// 但 `.search` 点下去会变成搜索栏，`.prominent`（纯分离）又要 iOS 27 SDK。
///
/// 「添加服务器」也不再占底栏的标签位 —— 一辈子只用一两次的入口不值得占常驻位置，
/// 现在收进「资源库」页右上角的 ＋（v2.5 起这个页签从「文件」改名「资源库」，
/// 页面本身也从目录平铺改成一排服务器卡片）。
struct RootTabView: View {
    @AppStorage("mangadock.tab.shelf") private var showShelf = true
    @AppStorage("mangadock.tab.files") private var showFiles = true

    /// Explicit selection, so the tab bar stays put across rebuilds.
    @State private var selection: RootTab = .shelf

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
                Tab("资源库", systemImage: "square.stack.3d.up.fill", value: RootTab.files) {
                    ResourceLibraryView()
                }
            }
            Tab("设置", systemImage: "gearshape.fill", value: RootTab.settings) {
                NavigationStack {
                    SettingsHomeView()
                }
            }
        }
        .onChange(of: showShelf) { _ in ensureSelectionVisible() }
        .onChange(of: showFiles) { _ in ensureSelectionVisible() }
        .onAppear { ensureSelectionVisible() }
    }

    private func ensureSelectionVisible() {
        if !visibleTabs.contains(selection) {
            selection = visibleTabs.first ?? .settings
        }
    }
}
