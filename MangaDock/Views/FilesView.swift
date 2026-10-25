import SwiftUI

/// 文件 tab: raw WebDAV browsing. Long-press anything to put it on the shelf.
struct FilesView: View {
    @EnvironmentObject private var store: AppStore

    @StateObject private var loader = FolderLoader()
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var mode: LayoutMode = .grid
    @State private var toast: String?

    private var folderKey: String { store.baseURL?.absoluteString ?? "files" }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .grid { gridContent } else { listContent }
            }
            .navigationTitle("文件")
            .libraryNavigation()
            .task { await reload() }
            .onAppear { mode = LayoutPreference.shared.mode(for: folderKey) }
            .onChange(of: shelf.lastMessage) { message in
                guard let message else { return }
                showToast(message)
            }
            .overlay(alignment: .top) { toastView }
        }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            Section {
                NavigationLink(destination: LocalLibraryView()) {
                    Label("本地文件", systemImage: "internaldrive")
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
                    Text("长按任意条目可以加入书架 · \(store.serverURL)")
                        .font(.caption2)
                }
            }
        }
        .refreshable { await reload() }
    }

    // MARK: - Grid

    private var gridContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink(destination: LocalLibraryView()) {
                    Label("本地文件", systemImage: "internaldrive")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)

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
            .contextMenu { ShelfMenu(item: item) }
        } else {
            ItemRow(item: item).opacity(0.55)
        }
    }

    @ViewBuilder
    private func gridCell(for item: WebDAVItem) -> some View {
        if let target = ItemTile.target(for: item) {
            NavigationLink(value: target) {
                CoverTile(item: item, shelfAction: .toggle)
            }
            .buttonStyle(.plain)
        } else {
            CoverTile(item: item).opacity(0.5)
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassPanel(cornerRadius: 16)
                .padding(.top, 6)
                .transition(.opacity)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }

    private func reload() async {
        await loader.load(url: store.baseURL, client: store.makeClient())
    }
}
