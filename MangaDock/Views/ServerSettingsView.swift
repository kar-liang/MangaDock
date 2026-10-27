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
                TextField("每行一个地址，如 http://192.168.2.144:5005/dav/Comics", text: $serverURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(3...6)
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            } header: {
                Text("WebDAV 服务器")
            } footer: {
                Text("每行填一个地址，启动时自动用能连上的那个（适合同一个库的局域网 IP + 公网域名）。用户名密码对所有地址通用。")
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

        var ok = 0
        var failures: [String] = []
        for line in lines {
            guard let url = AppStore.normalizedURL(line), url.host != nil else {
                failures.append("\(line)：格式不对")
                continue
            }
            let client = WebDAVClient(username: username, password: password, baseURL: url)
            do {
                _ = try await client.ping()
                ok += 1
            } catch {
                failures.append("\(url.host ?? line)：\(NetErrorText.friendly(error))")
            }
        }

        if ok > 0 {
            store.save(serverURL: serverURL, username: username, password: password)
            let suffix = failures.isEmpty ? "" : "（\(failures.count) 个连不上）"
            message = "\(ok) 个地址可用\(suffix)"
            isError = false
        } else {
            message = "全部连不上：\(failures.joined(separator: "；"))"
            isError = true
        }
        isTesting = false
    }
}
