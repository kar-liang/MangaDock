import SwiftUI

/// 文件 tab: raw WebDAV browsing. Long-press anything to put it on the shelf.
struct FilesView: View {
    @EnvironmentObject private var store: AppStore

    @StateObject private var loader = FolderLoader()
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var mode: LayoutMode = .grid
    @State private var toast: String?
    /// 两套都配了时，用分段控件切换看哪一套
    @State private var activeKind: ServerKind = .webdav

    private var folderKey: String {
        store.baseURL(for: activeKind)?.absoluteString ?? "files"
    }

    /// 每套自己的显示名称（不能用 store.serverDisplayName，那只反映当前激活那套）
    private func sourceTitle(_ kind: ServerKind) -> String {
        let name = store.savedProfile(kind).displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return store.baseURL(for: kind)?.host ?? kind.title
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.configuredKinds.count > 1 {
                    Picker("来源", selection: $activeKind) {
                        ForEach(store.configuredKinds) { kind in
                            Text(kind.title).tag(kind)
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
            .libraryNavigation()
            .task {
                // 默认跟着「当前激活的源」；只配了一套就选那一套
                if store.isReady(store.serverKind) {
                    activeKind = store.serverKind
                } else if let first = store.configuredKinds.first {
                    activeKind = first
                }
                await reload()
            }
            .onAppear { mode = LayoutPreference.shared.mode(for: folderKey) }
            .onChange(of: activeKind) { _, _ in
                mode = LayoutPreference.shared.mode(for: folderKey)
                Task { await reload() }
            }
            // 新加/切换了服务器：文件页跟着当前激活那套走
            .onChange(of: store.serverKind) { _, newKind in
                guard store.isReady(newKind) else { return }
                activeKind = newKind
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
                Text(sourceTitle(activeKind))
            } footer: {
                if !loader.isLoading && loader.errorMessage == nil {
                    Text("长按任意条目可以加入书架 · \(store.baseURL(for: activeKind)?.host ?? "")")
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
                    Text(sourceTitle(activeKind))
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
        guard let root = store.rootURL(for: activeKind) else { return }
        await loader.load(url: root, client: store.client(for: activeKind))
    }
}
