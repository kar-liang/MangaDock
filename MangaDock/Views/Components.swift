import SwiftUI

struct ItemRow: View {
    let item: WebDAVItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 17))
                .foregroundColor(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                if !item.isDirectory {
                    Text(sizeText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    private var iconName: String {
        if item.isDirectory { return "folder.fill" }
        if item.isArchive { return "book.closed.fill" }
        if item.isPDF { return "doc.richtext.fill" }
        if item.isImage { return "photo" }
        return "doc"
    }

    private var iconColor: Color {
        if item.isDirectory { return .accentColor }
        if item.isArchive { return .orange }
        if item.isPDF { return .red }
        return .secondary
    }

    private var sizeText: String {
        guard item.size > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: item.size)
    }
}

enum ItemTile {
    /// Directories navigate; archives, PDFs and image folders open the reader.
    static func target(for item: WebDAVItem) -> NavTarget? {
        if item.isDirectory { return .folder(item) }
        if item.isArchive || item.isPDF { return .comic(item) }
        return nil
    }
}

/// Context-menu entry that adds/removes an item from the bookshelf.
struct ShelfMenu: View {
    let item: WebDAVItem
    /// 「清除所有阅读记录」的确认弹窗要挂在 CoverBox 上 ——
    /// contextMenu 里的视图在菜单关闭后就没法再弹 dialog 了。
    var onClearHistory: (() -> Void)? = nil

    private var onShelf: Bool {
        ShelfStore.shared.contains(item)
    }

    var body: some View {
        Button {
            ShelfStore.shared.toggle(item)
        } label: {
            Label(onShelf ? "移出书架" : "加入书架",
                  systemImage: onShelf ? "minus.circle" : "plus.circle")
        }

        Button {
            PrivacyStore.shared.hide(item)
        } label: {
            Label("隐藏进隐私空间", systemImage: "lock")
        }

        if let onClearHistory {
            Button(role: .destructive) {
                onClearHistory()
            } label: {
                Label("清除所有阅读记录", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

struct LibraryNavigationModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: NavTarget.self) { target in
            switch target {
            case .folder(let item):
                BrowserView(folder: item).hidesRootBar()
            case .series(let item):
                SeriesView(folder: item).hidesRootBar()
            case .comic(let item):
                ReaderView(item: item).hidesRootBar()
            case .privateShelf:
                PrivateShelfView().hidesRootBar()
            case .localLibrary:
                LocalLibraryView().hidesRootBar()
            }
        }
    }
}

// MARK: - Root bar hiding

/// 推到二级页面时把根界面的自绘底栏收起来。
///
/// 系统 tab bar 只要 `hidesBottomBarWhenPushed` 就自动隐藏，**自绘底栏没有这个待遇** ——
/// 它挂在根视图上，导航栈压上来几层它都不知道。所以让每个二级页面自己上报。
struct RootBarHidingModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore

    func body(content: Content) -> some View {
        content
            .onAppear { store.immersiveDepth += 1 }
            .onDisappear { store.immersiveDepth = max(0, store.immersiveDepth - 1) }
    }
}

extension View {
    /// 一级页面用不到；凡是通过 `navigationDestination` 推出来的页面都套上。
    func hidesRootBar() -> some View { modifier(RootBarHidingModifier()) }
}

extension View {
    func libraryNavigation() -> some View {
        modifier(LibraryNavigationModifier())
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(.orange)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Liquid Glass helpers

extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular,
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// 底栏的圆按钮：用 `.clear` 而不是 `.regular` —— regular 的磨砂感太重，
    /// clear 才透得过去。`.interactive()` 让玻璃本身对手指有反应（按下去会形变）。
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.clear.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.clear.interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
