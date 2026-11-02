import SwiftUI

/// 文件 tab: raw WebDAV browsing. Long-press anything to put it on the shelf.
struct FilesView: View {
    @EnvironmentObject private var store: AppStore

    @StateObject private var loader = FolderLoader()
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var mode: LayoutMode = .grid
    @State private var toast: String?
    /// 当前看的是哪个账号。多账号之后这里存的是 profile id 而不是类型。
    @State private var activeAccountID: String?
    /// 「添加服务器」向导。原来占着底栏一个标签位，现在收到这里。
    @State private var showImport = false

    /// 全部账号（跨类型）。文件页的分段控件按这个列。
    private var accounts: [AppStore.AccountRef] { store.allAccounts }

    private var activeAccount: AppStore.AccountRef? {
        accounts.first { $0.id == activeAccountID } ?? accounts.first
    }

    private var folderKey: String {
        activeAccount?.id ?? "files"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if accounts.count > 1 {
                    Picker("来源", selection: Binding(
                        get: { activeAccount?.id ?? "" },
                        set: { id in
                            activeAccountID = id
                            if let account = accounts.first(where: { $0.id == id }) {
                                store.switchAccount(to: id, kind: account.kind)
                            }
                        }
                    )) {
                        ForEach(accounts) { account in
                            Text(account.title).tag(account.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }

                Group {
                    if mode == .grid { gridContent } else { listContent }
                }
            }
            .navigationTitle("文件")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加服务器")
                }
            }
            .sheet(isPresented: $showImport) {
                ImportFlowView {
                    // 存好一套配置后直接切过去看库，不用再手动点分段控件。
                    if let newID = store.activeAccountID(store.serverKind) {
                        activeAccountID = newID
                    }
                    Task { await reload() }
                }
            }
            .libraryNavigation()
            .task {
                // 默认跟着「当前激活的账号」；没设过就用第一个
                activeAccountID = store.activeAccountID(store.serverKind) ?? accounts.first?.id
                await reload()
            }
            .onAppear { mode = LayoutPreference.shared.mode(for: folderKey) }
            .onChange(of: activeAccountID) { _, _ in
                mode = LayoutPreference.shared.mode(for: folderKey)
                Task { await reload() }
            }
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
                NavigationLink(value: NavTarget.localLibrary) {
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
                Text(activeAccount?.title ?? "来源")
            } footer: {
                if !loader.isLoading && loader.errorMessage == nil {
                    Text("长按任意条目可以加入书架 · \(activeAccount?.title ?? "")")
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
                NavigationLink(value: NavTarget.localLibrary) {
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
                    Text(activeAccount?.title ?? "来源")
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
        guard let account = activeAccount, let root = store.rootURL(for: account) else { return }
        await loader.load(url: root, client: store.client(for: account))
    }
}
