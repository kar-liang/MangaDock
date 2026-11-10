import SwiftUI

/// 资源库：一台服务器一张卡。
///
/// 从「文件」页改过来的。以前是把当前源的目录直接平铺在这个页面上，多源靠顶部分段控件切；
/// 源一多就切不过来，也看不出「我到底加了几台服务器」。现在页面只负责「有哪些资源」，
/// 点卡片才进到那台服务器自己的浏览页（`AccountBrowserView`）。
struct ResourceLibraryView: View {
    @EnvironmentObject private var store: AppStore

    @State private var query = ""
    /// 弹哪个表单。**两个 sheet 修饰符挂在同一个 View 上时只会有最后一个生效**，
    /// 所以「新增」和「编辑」合并成一个 enum 状态。
    @State private var sheet: SheetTarget?
    /// 等待确认删除的账号
    @State private var pendingDelete: AppStore.AccountRef?
    /// 每台服务器的在线状态。nil = 还没测
    @State private var online: [String: Bool] = [:]
    @State private var toast: String?

    private enum SheetTarget: Identifiable {
        case add(ServerKind)
        case edit(AppStore.AccountRef)

        var id: String {
            switch self {
            case .add(let kind): return "add-\(kind.rawValue)"
            case .edit(let account): return "edit-\(account.id)"
            }
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var all: [AppStore.AccountRef] { store.allAccounts }

    private var filtered: [AppStore.AccountRef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { account in
            account.title.localizedCaseInsensitiveContains(q)
                || account.profile.urls.localizedCaseInsensitiveContains(q)
                || account.profile.note.localizedCaseInsensitiveContains(q)
                || account.kind.title.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if all.isEmpty {
                        emptyState
                    } else if filtered.isEmpty {
                        Text("没有匹配的资源")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filtered) { account in
                                NavigationLink(value: NavTarget.account(account)) {
                                    ResourceCard(account: account,
                                                 online: online[account.id])
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        sheet = .edit(account)
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    Button {
                                        store.activate(account)
                                        showToast("已切到「\(account.title)」")
                                    } label: {
                                        Label("设为当前", systemImage: "checkmark.circle")
                                    }
                                    Button(role: .destructive) {
                                        pendingDelete = account
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    localCard
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .navigationTitle("资源库")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(ServerKind.allCases) { kind in
                            Button {
                                sheet = .add(kind)
                            } label: {
                                Label(kind.title, systemImage: kind.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加服务器")
                }
            }
            .libraryNavigation()
            .overlay(alignment: .top) { toastView }
            .sheet(item: $sheet) { target in
                switch target {
                case .add(let kind):
                    AddServerView(kind: kind) { _ in
                        Task { await probeAll() }
                    }
                case .edit(let account):
                    AddServerView(kind: account.kind, editing: account) { _ in
                        Task { await probeAll() }
                    }
                }
            }
            .confirmationDialog(
                "删除「\(pendingDelete?.title ?? "")」？",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let account = pendingDelete {
                        if !store.removeAccount(id: account.id, kind: account.kind) {
                            showToast("至少要留一台服务器")
                        } else {
                            online[account.id] = nil
                            showToast("已删除「\(account.title)」")
                        }
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("只删配置和密码，服务器上的漫画文件不受影响。")
            }
            .task { await probeAll() }
        }
    }

    // MARK: - 本地文件

    /// 本地导入的漫画（系统「文件」App 里拷进来的）也算一类资源，固定一张卡。
    private var localCard: some View {
        NavigationLink(value: NavTarget.localLibrary) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: "internaldrive")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地文件")
                        .font(.subheadline.weight(.semibold))
                    Text("从「文件」App 导入的漫画")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("还没有添加服务器")
                .font(.headline)
            Text("点右上角 ＋ 选 WebDAV 或 Komga，填好地址就会出现在这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                sheet = .add(.webdav)
            } label: {
                Label("添加服务器", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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

    // MARK: - 探测在线状态

    /// 每台服务器打一次 ping，卡片角上的点据此变色。
    /// 先把 client 在主线程取出来，再把「只发请求」的部分丢进 task group 并行跑。
    @MainActor
    private func probeAll() async {
        let targets: [(String, RemoteClient?)] = all.map { ($0.id, store.client(for: $0)) }
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: (String, Bool).self) { group in
            for (id, client) in targets {
                guard let client else {
                    group.addTask { (id, false) }
                    continue
                }
                group.addTask {
                    (id, (try? await client.ping()) != nil)
                }
            }
            for await (id, ok) in group {
                online[id] = ok
            }
        }
    }
}

// MARK: - 卡片

private struct ResourceCard: View {
    let account: AppStore.AccountRef
    let online: Bool?

    private var accent: Color {
        account.kind == .webdav ? .blue : .green
    }

    private var dotColor: Color {
        switch online {
        case .some(true): return .green
        case .some(false): return .red.opacity(0.7)
        case .none: return Color.secondary.opacity(0.35)
        }
    }

    private var statusText: String {
        switch online {
        case .some(true): return "在线"
        case .some(false): return "连不上"
        case .none: return "未检测"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(account.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: account.kind.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(accent)
                }
            }

            Text(account.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Text(account.kind.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.12),
                                              Color(.secondarySystemGroupedBackground)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
