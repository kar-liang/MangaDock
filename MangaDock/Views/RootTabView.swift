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
/// 自动行为全得自己实现 —— 二级页面隐藏（`hidesRootBar()`）、长按气泡切页、
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

    /// 长按拖动中浮起的那个气泡对应哪个页面（松手才真正切）
    @State private var hoverTab: RootTab?
    /// 手指在胶囊里的横坐标，气泡跟着它走
    @State private var fingerX: CGFloat = 0
    /// 胶囊总宽（含内边距），把手指的 x 换算成第几个按钮要靠它
    @State private var capsuleWidth: CGFloat = 0

    @Namespace private var tabHighlight

    private let barHeight: CGFloat = 62
    /// 胶囊底边离屏幕物理底边的距离
    private let barBottomGap: CGFloat = 20
    /// 胶囊内边距（四周同值）
    private let capsuleInset: CGFloat = 5
    /// 胶囊圆角。铺满半圆（31）显得太圆，24 更接近原生的克制感
    private let capsuleRadius: CGFloat = 24
    private let bubbleSize: CGFloat = 74

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
        // ⚠️ 这里不能套 GeometryReader 再 overlay：GeometryReader 的 frame
        // 本来就在安全区里面，overlay 贴的是「安全区底边」，离屏幕底还差 34pt，
        // 再加 padding 只会更高（2.0.38 就是这么把底栏顶上去的）。
        // 正确做法是让容器真的忽略底部安全区，底栏才落得到屏幕底边。
        ZStack(alignment: .bottom) {
            ZStack {
                page(.shelf)
                page(.files)
                page(.settings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 底栏是浮层不占位，列表得自己留出这段，否则最后一行被压住。
            // 安全区已被忽略，所以这里直接给「底栏视觉总高」，不用再扣 34。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: barHidden ? 0 : barHeight + barBottomGap)
            }

            if !barHidden {
                bottomBar
                    .padding(.bottom, barBottomGap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
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
        .barGlass(RoundedRectangle(cornerRadius: capsuleRadius, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { capsuleWidth = $0 }
        // 长按浮起的气泡：原生 tab bar 长按时会把当前项放大成一枚玻璃气泡，
        // 跟着手指左右滑。这里复刻的就是它。
        .overlay(alignment: .bottom) {
            if let tab = hoverTab {
                bubble(for: tab)
                    .offset(x: bubbleOffsetX, y: -(barHeight + 14))
                    .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
            }
        }
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
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        // 高亮块不是原地消失再冒出来，是从上一个按钮一路滑过去。
                        // 拖动时它跟着手指走，靠的就是这块被反复插值。
                        .matchedGeometryEffect(id: "tabHighlight", in: tabHighlight)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .barGlass(Circle())
    }

    /// 长按时浮起的那枚玻璃气泡，内容就是当前悬停项的图标
    private func bubble(for tab: RootTab) -> some View {
        Image(systemName: tab.icon)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: bubbleSize, height: bubbleSize)
            .barGlass(Circle())
    }

    /// 气泡的横向位置（相对胶囊中心），夹在胶囊范围内，免得飘到 ➕ 底下或屏幕外
    private var bubbleOffsetX: CGFloat {
        let half = capsuleWidth / 2
        let margin = bubbleSize / 2 + capsuleInset
        guard half > margin else { return 0 }
        return min(max(fingerX - half, -half + margin), half - margin)
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
                fingerX = drag.location.x
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
