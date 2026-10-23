import SwiftUI

/// 书架 tab: only what you explicitly added from 文件.
struct ShelfView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var mode: LayoutMode = .grid

    private let layoutKey = "shelf"

    var body: some View {
        NavigationStack {
            Group {
                if shelf.entries.isEmpty {
                    emptyState
                } else if mode == .grid {
                    gridContent
                } else {
                    listContent
                }
            }
            .navigationTitle("书架")
            .toolbar {
                if !shelf.entries.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            mode = (mode == .grid ? .list : .grid)
                            LayoutPreference.shared.setMode(mode, for: layoutKey)
                        } label: {
                            Image(systemName: mode == .grid ? "list.bullet" : "square.grid.2x2")
                        }
                    }
                }
            }
            .libraryNavigation()
            .onAppear { mode = LayoutPreference.shared.mode(for: layoutKey) }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundColor(.secondary)
            Text("书架还是空的")
                .font(.headline)
            Text("去「文件」标签找到漫画，长按选「加入书架」。\n书架只放你自己挑的，WebDAV 目录不会全倒进来。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: LibraryGrid.columns, spacing: 16) {
                ForEach(shelf.entries) { entry in
                    if let item = entry.item, let target = target(for: item) {
                        NavigationLink(value: target) {
                            CoverTile(item: item, shelfAction: .toggle)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            ForEach(shelf.entries) { entry in
                if let item = entry.item, let target = target(for: item) {
                    NavigationLink(value: target) {
                        ItemRow(item: item)
                    }
                    .contextMenu { ShelfMenu(item: item) }
                }
            }
            .onDelete { shelf.remove(at: $0) }
        }
    }

    /// A folder opens the chapter list; a single file goes straight to the reader.
    private func target(for item: WebDAVItem) -> NavTarget? {
        if item.isDirectory { return .series(item) }
        if item.isArchive || item.isPDF { return .comic(item) }
        return nil
    }
}
