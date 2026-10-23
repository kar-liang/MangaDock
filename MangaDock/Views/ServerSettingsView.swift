import SwiftUI

struct ServerSettingsView: View {
    let initialSetup: Bool

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var message: String?
    @State private var isError = false
    @State private var cacheSize = ""
    @State private var loaded = false

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
            }

            if !initialSetup {
                Section {
                    HStack {
                        Text("缓存占用")
                        Spacer()
                        Text(cacheSize).foregroundColor(.secondary)
                    }
                    Button("清除漫画缓存", role: .destructive) {
                        CacheManager.clear()
                        refreshCacheSize()
                    }
                    Button("清空阅读记录", role: .destructive) {
                        store.clearRecent()
                    }
                } header: {
                    Text("本地数据")
                } footer: {
                    Text("缓存的是下载过的 CBZ 和看过的散图，清掉不影响服务器上的文件。")
                }

                Section("关于") {
                    LabeledContent("版本", value: "1.1")
                    LabeledContent("支持格式", value: "CBZ / ZIP / 图片文件夹")
                    Text("不支持 CBR（RAR）和 PDF。CBR 可以先转成 CBZ。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(initialSetup ? "连接 WebDAV" : "设置")
        .navigationBarTitleDisplayMode(initialSetup ? .large : .inline)
        .toolbar {
            if !initialSetup {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear(perform: loadExisting)
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        serverURL = store.serverURL
        username = store.username
        password = store.password
        refreshCacheSize()
    }

    private func refreshCacheSize() {
        cacheSize = CacheManager.formattedSize()
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
            if initialSetup {
                // RootView swaps to HomeView automatically once configured.
                dismiss()
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isError = true
        }
        isTesting = false
    }
}
