import SwiftUI

/// 一台服务器自己的浏览页（从资源库的卡片点进来）。
///
/// 以前这就是「文件」页本身，多源靠顶部分段控件切；现在每台服务器一个页面，
/// 页标题就是服务器名，来源不会串。目录条目照旧长按加入书架。
struct AccountBrowserView: View {
    let account: AppStore.AccountRef

    @EnvironmentObject private var store: AppStore
    @StateObject private var loader = FolderLoader()
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var mode: LayoutMode = .grid
    @State private var toast: String?
    @State private var showEdit = false

    private var folderKey: String { account.id }

    var body: some View {
        Group {
            if mode == .grid { gridContent } else { listContent }
        }
        .navigationTitle(account.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("显示方式", selection: $mode) {
                        Label("网格", systemImage: "square.grid.2x2").tag(LayoutMode.grid)
                        Label("列表", systemImage: "list.bullet").tag(LayoutMode.list)
                    }
                    .pickerStyle(.inline)
                    Button {
                        showEdit = true
                    } label: {
                        Label("编辑服务器", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            AddServerView(kind: account.kind, editing: account) { _ in
                Task { await reload() }
            }
        }
        .task { await reload() }
        .onAppear { mode = LayoutPreference.shared.mode(for: folderKey) }
        .onChange(of: mode) { _, newValue in
            LayoutPreference.shared.setMode(newValue, for: folderKey)
        }
        .onChange(of: shelf.lastMessage) { _, message in
            guard let message else { return }
            showToast(message)
        }
        .overlay(alignment: .top) { toastView }
    }

    // MARK: - 列表

    private var listContent: some View {
        List {
            if loader.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取目录…").foregroundColor(.secondary)
                }
            } else if let error = loader.errorMessage {
                ErrorStateView(message: error) { Task { await reload() } }
            } else if loader.items.isEmpty {
                Text("这个目录是空的").foregroundColor(.secondary)
            }

            ForEach(loader.items) { item in
                row(for: item)
            }
        }
        .listStyle(.plain)
        .refreshable { await reload() }
    }

    // MARK: - 网格

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
                    ErrorStateView(message: error) { Task { await reload() } }
                } else if loader.items.isEmpty {
                    Text("这个目录是空的").foregroundColor(.secondary)
                } else {
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

    // MARK: - 条目

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
        guard let root = store.rootURL(for: account) else {
            return
        }
        await loader.load(url: root, client: store.client(for: account))
    }
}
