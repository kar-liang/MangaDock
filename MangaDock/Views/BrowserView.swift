import SwiftUI

struct BrowserView: View {
    let folder: WebDAVItem

    @EnvironmentObject private var store: AppStore
    @StateObject private var loader = FolderLoader()
    @State private var mode: LayoutMode = .grid

    private var folderKey: String { folder.url.absoluteString }

    var body: some View {
        Group {
            if mode == .grid { gridContent } else { listContent }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    mode = (mode == .grid ? .list : .grid)
                    LayoutPreference.shared.setMode(mode, for: folderKey)
                } label: {
                    Image(systemName: mode == .grid ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
        .task { await reload() }
        .onAppear { mode = LayoutPreference.shared.mode(for: folderKey) }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            if loader.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取…").foregroundColor(.secondary)
                }
            } else if let error = loader.errorMessage {
                ErrorStateView(message: error) { Task { await reload() } }
            } else {
                if loader.imageCount > 0 {
                    Section {
                        NavigationLink(value: NavTarget.comic(folder)) {
                            Label("阅读这个文件夹（\(loader.imageCount) 张图片）", systemImage: "book")
                        }
                    }
                }

                if loader.items.isEmpty {
                    Section { Text("这里没有漫画文件").foregroundColor(.secondary) }
                } else {
                    Section {
                        ForEach(loader.items) { item in
                            row(for: item)
                        }
                    }
                }
            }
        }
        .refreshable { await reload() }
    }

    // MARK: - Grid

    private var gridContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loader.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取…").foregroundColor(.secondary)
                    }
                } else if let error = loader.errorMessage {
                    ErrorStateView(message: error) { Task { await reload() } }
                } else {
                    if loader.imageCount > 0 {
                        NavigationLink(value: NavTarget.comic(folder)) {
                            Label("阅读这个文件夹（\(loader.imageCount) 张图片）", systemImage: "book")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                    }

                    if loader.items.isEmpty {
                        Text("这里没有漫画文件").foregroundColor(.secondary)
                    } else {
                        LazyVGrid(columns: LibraryGrid.columns, spacing: 16) {
                            ForEach(loader.items) { item in
                                gridCell(for: item)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await reload() }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func row(for item: WebDAVItem) -> some View {
        if let target = ItemTile.target(for: item) {
            NavigationLink(value: target) {
                ItemRow(item: item)
            }
        } else {
            ItemRow(item: item).opacity(0.55)
        }
    }

    @ViewBuilder
    private func gridCell(for item: WebDAVItem) -> some View {
        if let target = ItemTile.target(for: item) {
            NavigationLink(value: target) {
                CoverTile(item: item)
            }
            .buttonStyle(.plain)
        } else {
            CoverTile(item: item).opacity(0.5)
        }
    }

    private func reload() async {
        await loader.load(url: folder.requestURL, client: store.makeClient())
    }
}
