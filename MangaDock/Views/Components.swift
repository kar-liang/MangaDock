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
                BrowserView(folder: item)
            case .series(let item):
                SeriesView(folder: item)
            case .comic(let item):
                ReaderView(item: item)
            case .privateShelf:
                PrivateShelfView()
            case .localLibrary:
                LocalLibraryView()
            }
        }
    }
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

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}
