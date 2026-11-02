import SwiftUI
import UIKit

enum RootTab: Hashable {
    case shelf, files, settings

    var title: String {
        switch self {
        case .shelf: return "书架"
        case .files: return "文件"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .shelf: return "books.vertical.fill"
        case .files: return "folder.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// 根界面：左侧胶囊装页面按钮，右侧独立一个 ➕ 开导入向导。
///
/// 为什么不用 TabView：系统的 tab bar 只能排成一行等宽项，做不出
/// 「三个挤在左边胶囊里、➕ 单独漂在右边」这种分裂布局。所以底栏整个自绘，
/// 页面容器也自己管 —— 代价是 `.toolbar(.hidden, for: .tabBar)` 对自绘底栏无效，
/// 阅读器得靠 `store.readerDepth` 上报，见 ReaderView。
struct RootTabView: View {
    @EnvironmentObject private var store: AppStore

    @AppStorage("mangadock.tab.shelf") private var showShelf = true
    @AppStorage("mangadock.tab.files") private var showFiles = true

    @State private var selection: RootTab = .shelf
    /// 选中高亮块在几个按钮之间滑动用的命名空间
    @Namespace private var tabHighlight
    /// 访问过的页面。首次进入才构建，之后一直留在层级里 ——
    /// 切走再切回来，滚动位置和目录缓存都还在（跟 TabView 的行为对齐）。
    @State private var mounted: Set<RootTab> = [.shelf]
    @State private var showImport = false
    /// 弹窗前停在哪个页面，关闭后回到那儿
    @State private var pendingTab: RootTab = .shelf
    /// 这次弹窗里真的存了一套配置吗？存了就直接跳到「文件」看库
    @State private var didAddServer = false

    private var visibleTabs: [RootTab] {
        var tabs: [RootTab] = []
        if showShelf { tabs.append(.shelf) }
        if showFiles { tabs.append(.files) }
        tabs.append(.settings)
        return tabs
    }

    /// 阅读器全屏时底栏让位
    private var barHidden: Bool { store.readerDepth > 0 }

    var body: some View {
        ZStack {
            page(.shelf)
            page(.files)
            page(.settings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !barHidden {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: barHidden)
        .sheet(isPresented: $showImport, onDismiss: {
            let target: RootTab = didAddServer ? .files : pendingTab
            didAddServer = false
            select(visibleTabs.contains(target) ? target : (visibleTabs.first ?? .settings))
        }) {
            ImportFlowView {
                didAddServer = true
            }
        }
        .onChange(of: showShelf) { ensureSelectionVisible() }
        .onChange(of: showFiles) { ensureSelectionVisible() }
        .onAppear { ensureSelectionVisible() }
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(_ tab: RootTab) -> some View {
        if mounted.contains(tab), visibleTabs.contains(tab) {
            content(for: tab)
                .opacity(selection == tab ? 1 : 0)
                .allowsHitTesting(selection == tab)
                .accessibilityHidden(selection != tab)
                .zIndex(selection == tab ? 1 : 0)
        }
    }

    @ViewBuilder
    private func content(for tab: RootTab) -> some View {
        switch tab {
        case .shelf:
            ShelfView()
        case .files:
            FilesView()
        case .settings:
            NavigationStack {
                SettingsHomeView()
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(5)
            .glassCapsule()
            // 高亮块滑动的弹簧：跟系统 tab bar 的手感对齐（略带回弹、不拖泥带水）
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: selection)

            addButton
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ tab: RootTab) -> some View {
        let active = selection == tab
        return Button {
            select(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 21)
                Text(tab.title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        // 这一句就是「原生那种滑动」：高亮块不是简单地在旧位置消失、
                        // 新位置冒出来，而是从上一个按钮一路滑过去。
                        .matchedGeometryEffect(id: "tabHighlight", in: tabHighlight)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pendingTab = selection
            showImport = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 62, height: 62)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加服务器")
        .glassCircle()
    }

    // MARK: - Selection

    private func select(_ tab: RootTab) {
        mounted.insert(tab)
        guard selection != tab else { return }
        // 系统 tab bar 点击会有一记轻触感，自绘的得自己补
        UISelectionFeedbackGenerator().selectionChanged()
        selection = tab
        pendingTab = tab
    }

    private func ensureSelectionVisible() {
        if !visibleTabs.contains(selection) {
            select(visibleTabs.first ?? .settings)
        }
    }
}
