import SwiftUI

/// WebDAV connection: address, credentials, connection test, network diagnostics.
///
/// Also serves as the first-run setup screen (`initialSetup: true`), which is
/// why the diagnostics block is hidden until the app is actually configured.
struct ServerSettingsView: View {
    let initialSetup: Bool

    @EnvironmentObject private var store: AppStore

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var message: String?
    @State private var isError = false
    @State private var loaded = false
    @State private var diagResults: [NetDiagnostics.Result] = []
    @State private var diagRunning = false
    @State private var confirmClearServer = false

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.2.144:5005/dav/Comics", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            } header: {
                Text("WebDAV 服务器")
            } footer: {
                Text("地址直接填漫画所在的目录，例如 http://主机:端口/dav/Comics。不写 http:// 也能识别，局域网服务用 http 就行。")
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

                Button("清除 WebDAV 配置", role: .destructive) {
                    confirmClearServer = true
                }
            }

            if !initialSetup {
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
        .navigationTitle(initialSetup ? "连接 WebDAV" : "WebDAV 服务器")
        .navigationBarTitleDisplayMode(initialSetup ? .large : .inline)
        // No .libraryNavigation() here: this screen is pushed from
        // SettingsHomeView, and registering the same destinations twice breaks
        // pushes (see the 1.7.1 fix).
        .onAppear(perform: loadExisting)
        .confirmationDialog("清除 WebDAV 配置？", isPresented: $confirmClearServer, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                store.clearConfiguration()
                serverURL = ""
                username = ""
                password = ""
                message = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后回到首次连接页面，本地缓存和阅读记录不受影响。")
        }
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        serverURL = store.serverURL
        username = store.username
        password = store.password
    }

    private func runDiagnostics() async {
        diagRunning = true
        diagResults = []
        diagResults = await NetDiagnostics.run(store.serverURL)
        diagRunning = false
    }

    private func testAndSave() async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "先把服务器地址填上"
            isError = true
            return
        }

        isTesting = true
        message = nil

        var text = trimmed
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") && text.count > 8 {
            text.removeLast()
        }

        guard let url = URL(string: text), url.host != nil else {
            message = "地址格式不对，示例：http://192.168.2.144:5005/dav/Comics"
            isError = true
            isTesting = false
            return
        }

        let client = WebDAVClient(username: username, password: password, baseURL: url)
        do {
            let items = try await client.list(url)
            let comicCount = items.filter { $0.isDirectory || $0.isArchive }.count
            store.save(serverURL: text, username: username, password: password)
            message = "连接成功，找到 \(items.count) 项（其中 \(comicCount) 个目录/压缩包）"
            isError = false
        } catch {
            message = NetErrorText.friendly(error)
            isError = true
        }
        isTesting = false
    }
}
