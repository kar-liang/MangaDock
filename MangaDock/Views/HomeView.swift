import SwiftUI

/// 书架 tab: browse the WebDAV library.
struct HomeView: View {
    @EnvironmentObject private var store: AppStore

    @StateObject private var loader = FolderLoader()
    @State private var mode: LayoutMode = .grid

    private var folderKey: String { store.baseURL?.absoluteString ?? "root" }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .grid { gridContent } else { listContent }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        mode = (mode == .grid ? .list : .grid)
                        LayoutPreference.shared.setMode(mode, for: folderKey)
                    } label: {
                        Image(systemName: mode == .grid ? "list.bullet" : "square.grid.2x2")
                    }
                }
            }
            .navigationDestination(for: NavTarget.self) { target in
                switch target {
                case .folder(let item):
                    BrowserView(folder: item)
                case .comic(let item):
                    ReaderView(item: item)
                }
            }
            .task { await reload() }
            .onAppear { mode = LayoutPreference.shared.mode(for: folderKey) }
        }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            Section {
                if loader.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取目录…").foregroundColor(.secondary)
                    }
                } else if let error = loader.errorMessage {
                    ErrorStateView(message: error) {
                        Task { await reload() }
                    }
                } else if loader.items.isEmpty {
                    Text("这个目录是空的").foregroundColor(.secondary)
                }

                ForEach(loader.items) { item in
                    row(for: item)
                }
            } header: {
                Text(store.baseTitle)
            } footer: {
                if !loader.isLoading && loader.errorMessage == nil {
                    Text(store.serverURL).font(.caption2)
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
                        Text("正在读取目录…").foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if let error = loader.errorMessage {
                    ErrorStateView(message: error) {
                        Task { await reload() }
                    }
                } else if loader.items.isEmpty {
                    Text("这个目录是空的").foregroundColor(.secondary)
                } else {
                    Text(store.baseTitle)
                        .font(.subheadline.weight(.semibold))

                    LazyVGrid(columns: LibraryGrid.columns, spacing: 16) {
                        ForEach(loader.items) { item in
                            gridCell(for: item)
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await reload() }
    }

    // MARK: - Rows and cells

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
        await loader.load(url: store.baseURL, client: store.makeClient())
    }
}
