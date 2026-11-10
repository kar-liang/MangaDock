import SwiftUI

/// WebDAV connection: address, credentials, connection test, network diagnostics.
///
/// Also serves as the first-run setup screen (`initialSetup: true`), which is
/// why the diagnostics block is hidden until the app is actually configured.
struct ServerSettingsView: View {
    let initialSetup: Bool

    @EnvironmentObject private var store: AppStore

    @State private var displayName = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    /// 用户点了「还没配过」的类型：不直接切，先带他去填表
    @State private var pendingKind: ServerKind?
    @State private var isTesting = false
    @State private var message: String?
    @State private var isError = false
    @State private var loaded = false
    @State private var diagResults: [NetDiagnostics.Result] = []
    @State private var diagRunning = false
    @State private var confirmClearServer = false

    /// 把 store 当前账号的值刷回输入框（切换账号后调）。
    private func syncFields() {
        displayName = store.serverDisplayName
        serverURL = store.serverURL
        username = store.username
        password = store.password
    }

    var body: some View {
        Form {
            if !initialSetup {
                Section {
                    ForEach(store.profiles(for: store.serverKind)) { profile in
                        Button {
                            store.switchAccount(to: profile.id, kind: store.serverKind)
                            syncFields()
                        } label: {
                            HStack {
                                Text(profile.displayName.isEmpty
                                     ? (profile.lines.first ?? "未命名账号")
                                     : profile.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if profile.id == store.activeAccountID(store.serverKind) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .swipeActions {
                            if store.profiles(for: store.serverKind).count > 1 {
                                Button("删除", role: .destructive) {
                                    store.deleteAccount(profile.id, kind: store.serverKind)
                                    syncFields()
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(store.serverKind.title) 账号")
                } footer: {
                    Text("点一下切换，左滑删除。要再加一台服务器，去「资源库」页右上角 ＋ 选 WebDAV 或 Komga。\n两个账号的地址（域名或 IP）不同时，各自的漫画会自动用各自的凭据。")
                }
            }

            Section {
                Picker("类型", selection: Binding(
                    get: { store.serverKind },
                    set: { kind in
                        guard kind != store.serverKind else { return }
                        if store.hasProfile(kind) {
                            store.serverKind = kind
                        } else {
                            // 这套还没配过。直接切过去会变成空配置，整个 App
                            // 会跳回首次设置页 —— 所以先把人带到填写表单。
                            pendingKind = kind
                        }
                    }
                )) {
                    ForEach(ServerKind.allCases) { kind in
                        Text(store.hasProfile(kind) ? kind.title : "\(kind.title)（未配置）")
                            .tag(kind)
                    }
                }
                TextField("显示名称（选填）", text: $displayName)
                TextField(store.serverKind == .komga
                          ? "如 https://komga.example.com"
                          : "每行一个地址，如 http://192.168.1.10:5005/dav/Comics",
                          text: $serverURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(3...6)
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            } header: {
                Text(store.serverKind == .komga ? "Komga 服务器" : "WebDAV 服务器")
            } footer: {
                Text("每台服务器在「资源库」里是一张卡，点卡片进各自的浏览页；这里的「类型」只决定打开 App 时默认看哪一套。")
                Text(store.serverKind == .komga
                     ? "填 Komga 的访问地址，不带 /api 之类的路径。账号密码用 Komga 网页登录的那套。同样支持每行一个地址（局域网 IP + 公网域名）。"
                     : "每行填一个地址，启动时自动用能连上的那个（适合同一个库的局域网 IP + 公网域名）。用户名密码对所有地址通用。")
            }

            Section {
                Button {
                    Task { await testAndSave() }
                } label: {
                    HStack {
                        Text(isTesting ? "正在连接…" : "测试并保存")
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(isError ? .red : .green)
                }

                Button("清除 \(store.serverKind.title) 配置", role: .destructive) {
                    confirmClearServer = true
                }
            }

            // 诊断走的是 WebDAV 的 PROPFIND / 证书 / 同端口那套，Komga 下没意义
            if !initialSetup && store.serverKind == .webdav {
                Section {
                    Button {
                        Task { await runDiagnostics() }
                    } label: {
                        HStack {
                            Text(diagRunning ? "诊断中…" : "连接诊断")
                            Spacer()
                            if diagRunning { ProgressView() }
                        }
                    }
                    .disabled(diagRunning)

                    ForEach(diagResults) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(result.ok ? .green : .red)
                                Text(result.title).font(.footnote)
                            }
                            Text(result.detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("网络")
                } footer: {
                    Text("诊断会分别用「当前设置」「忽略证书校验」「HTTP 同端口」连一次服务器，直接告诉你卡在哪一层。")
                }
            }
        }
        .navigationTitle(initialSetup ? "连接 \(store.serverKind.title)" : "服务器")
        .navigationBarTitleDisplayMode(initialSetup ? .large : .inline)
        // No .libraryNavigation() here: this screen is pushed from
        // SettingsHomeView, and registering the same destinations twice breaks
        // pushes (see the 1.7.1 fix).
        .onAppear(perform: loadExisting)
        .onChange(of: store.serverKind) { _, _ in syncFromStore() }
        .sheet(item: $pendingKind) { kind in
            KindSetupSheet(kind: kind)
                .environmentObject(store)
        }
        .confirmationDialog("清除 \(store.serverKind.title) 配置？", isPresented: $confirmClearServer, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                store.clearConfiguration()
                displayName = ""
                serverURL = ""
                username = ""
                password = ""
                message = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除 \(store.serverKind.title) 这一套地址和账号，另一套配置、本地缓存和阅读记录都不受影响。")
        }
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        syncFromStore()
    }

    private func syncFromStore() {
        displayName = store.serverDisplayName
        serverURL = store.serverURL
        username = store.username
        password = store.password
        message = nil
    }

    private func runDiagnostics() async {
        diagRunning = true
        diagResults = []
        // 多地址时诊断第一个地址（探测会自动切换，诊断只针对单一地址排查）。
        let raw = store.serverURLs.first?.absoluteString ?? store.serverURL
        diagResults = await NetDiagnostics.run(raw)
        diagRunning = false
    }

    private func testAndSave() async {
        let lines = serverURL
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            message = "先把服务器地址填上（每行一个）"
            isError = true
            return
        }

        isTesting = true
        message = nil

        // 和导入向导走同一套探测：按类型选客户端、并行、8 秒超时。
        // 原来这里写死 WebDAVClient，选 Komga 时会挂到 120 秒超时才失败。
        let outcome = await ServerProbe.test(kind: store.serverKind,
                                             address: serverURL,
                                             username: username,
                                             password: password)
        isTesting = false
        message = outcome.summary
        isError = !outcome.isOK

        guard outcome.isOK else { return }

        // 只存连得上的地址（不可达的留着每次启动都白等一轮超时）
        store.save(serverURL: outcome.reachable.joined(separator: "\n"),
                   username: username,
                   password: password,
                   displayName: displayName)
    }
}

/// 从设置页直接给「还没配过」的类型补配置时用的小弹窗。
private struct KindSetupSheet: View {
    let kind: ServerKind

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AddServerView(kind: kind)
    }
}
