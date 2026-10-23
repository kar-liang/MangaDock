import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore

    @StateObject private var loader = FolderLoader()
    @State private var showSettings = false
    @AppStorage("mangadock.useGrid") private var useGrid = false

    var body: some View {
        NavigationStack {
            Group {
                if useGrid { gridContent } else { listContent }
            }
            .navigationTitle("漫画坞")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        useGrid.toggle()
                    } label: {
                        Image(systemName: useGrid ? "list.bullet" : "square.grid.2x2")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
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
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    ServerSettingsView(initialSetup: false)
                }
            }
        }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            if !store.recent.isEmpty {
                Section("继续阅读") {
                    ForEach(Array(store.recent.prefix(5))) { entry in
                        if let item = entry.item {
                            NavigationLink(value: NavTarget.comic(item)) {
                                HStack(spacing: 12) {
                                    Image(systemName: "book.fill")
                                        .foregroundColor(.orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).lineLimit(1)
                                        Text(entry.progressText)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.uturn.forward")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let snapshot = Array(store.recent.prefix(5))
                        for offset in offsets where offset < snapshot.count {
                            store.removeRecent(snapshot[offset])
                        }
                    }
                }
            }

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
            VStack(alignment: .leading, spacing: 18) {
                if !store.recent.isEmpty {
                    Text("继续阅读")
                        .font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(store.recent.prefix(8))) { entry in
                                if let item = entry.item {
                                    NavigationLink(value: NavTarget.comic(item)) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            CoverTile(item: item)
                                                .frame(width: 104)
                                            ProgressView(value: entry.readProgress)
                                                .tint(.orange)
                                                .frame(width: 104)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

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

private extension RecentEntry {
    var readProgress: Double {
        guard pageCount > 0 else { return 0 }
        return min(1, Double(page + 1) / Double(pageCount))
    }
}
