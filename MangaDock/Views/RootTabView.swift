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
/// 「三个挤在左边胶囊里、➕ 单独漂在右边」这种分裂布局。代价是系统和底栏相关的
/// 自动行为全得自己实现 —— 二级页面隐藏（`hidesRootBar()`）、长按滑动切页、
/// 选中块的液态玻璃过渡，都在这个文件里。
struct RootTabView: View {
    @EnvironmentObject private var store: AppStore

    @AppStorage("mangadock.tab.shelf") private var showShelf = true
    @AppStorage("mangadock.tab.files") private var showFiles = true

    @State private var selection: RootTab = .shelf
    /// 访问过的页面。首次进入才构建，之后一直留在层级里 ——
    /// 切走再切回来，滚动位置和目录缓存都还在（跟 TabView 的行为对齐）。
    @State private var mounted: Set<RootTab> = [.shelf]
    @State private var showImport = false
    /// 弹窗前停在哪个页面，关闭后回到那儿
    @State private var pendingTab: RootTab = .shelf
    /// 这次弹窗里真的存了一套配置吗？存了就直接跳到「文件」看库
    @State private var didAddServer = false

    /// 长按拖动中高亮块停在哪（松手才真正切页面）
    @State private var hoverTab: RootTab?
    /// 胶囊总宽（含内边距），把手指的 x 换算成第几个按钮要靠它
    @State private var capsuleWidth: CGFloat = 0

    @Namespace private var tabHighlight

    private let barHeight: CGFloat = 62
    /// 胶囊底边离屏幕物理底边的距离。
    /// 原来挂在 safeAreaInset 里，等于「安全区 34 + 6」= 40pt，看着悬在半空。
    /// 20pt 刚好压到 home indicator 上沿，跟系统 tab bar 的位置感一致。
    private let barBottomGap: CGFloat = 20
    /// 胶囊内边距（四周同值）
    private let capsuleInset: CGFloat = 5

    private var visibleTabs: [RootTab] {
        var tabs: [RootTab] = []
        if showShelf { tabs.append(.shelf) }
        if showFiles { tabs.append(.files) }
        tabs.append(.settings)
        return tabs
    }

    /// 二级页面压上来时让位
    private var barHidden: Bool { store.immersiveDepth > 0 }

    /// 高亮块跟着谁走：拖动中跟手指，否则跟选中项
    private var highlightTab: RootTab { hoverTab ?? selection }

    var body: some View {
        GeometryReader { proxy in
            // 底栏是 overlay（会贴到屏幕物理底边），列表的避让得
            // 自己补：从「底栏视觉总高」里扣掉系统已经给的安全区。
            let reserve = max(0, barHeight + barBottomGap - proxy.safeAreaInsets.bottom)

            ZStack {
                page(.shelf)
                page(.files)
                page(.settings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: barHidden ? 0 : reserve)
            }
            .overlay(alignment: .bottom) {
                if !barHidden {
                    bottomBar
                        .padding(.bottom, barBottomGap)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: barHidden)
        }
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
            tabCluster
            addButton
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    private var tabCluster: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(capsuleInset)
        .glassCapsule()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { capsuleWidth = $0 }
        // 系统 tab bar 长按后可以左右滑动切页，自绘的得自己接
        .simultaneousGesture(scrubGesture)
        .animation(highlightAnimation, value: highlightTab)
    }

    private func tabButton(_ tab: RootTab) -> some View {
        let active = highlightTab == tab
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
                        // 高亮块不是原地消失再冒出来，是从上一个按钮一路滑过去。
                        // 拖动时它跟着手指走，靠的就是这块被反复插值。
                        .matchedGeometryEffect(id: "tabHighlight", in: tabHighlight)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
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
                .frame(width: barHeight, height: barHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加服务器")
        .glassCircle()
    }

    /// 拖动时用短弹簧（跟手），松手后用长一点的（有回弹）
    private var highlightAnimation: Animation {
        hoverTab == nil
            ? .spring(response: 0.34, dampingFraction: 0.86)
            : .interactiveSpring(response: 0.16, dampingFraction: 0.9)
    }

    // MARK: - Long-press scrub

    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.16)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let next = tab(atX: drag.location.x)
                if next != hoverTab {
                    UISelectionFeedbackGenerator().selectionChanged()
                    hoverTab = next
                }
            }
            .onEnded { _ in
                if let target = hoverTab { select(target) }
                hoverTab = nil
            }
    }

    private func tab(atX x: CGFloat) -> RootTab? {
        let tabs = visibleTabs
        let inner = capsuleWidth - capsuleInset * 2
        guard !tabs.isEmpty, inner > 0 else { return nil }
        let step = inner / CGFloat(tabs.count)
        let index = Int(((x - capsuleInset) / step).rounded(.down))
        return tabs[min(max(0, index), tabs.count - 1)]
    }

    // MARK: - Selection

    private func select(_ tab: RootTab) {
        mounted.insert(tab)
        // 兜底：万一某次 push/pop 的 onDisappear 漏了，计数会卡住让底栏再也不出现。
        // 能点到 tab 就说明已经在根界面了，清零安全。
        if store.immersiveDepth != 0 { store.immersiveDepth = 0 }
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
