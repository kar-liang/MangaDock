import SwiftUI

struct ServerSettingsView: View {
    let initialSetup: Bool

    @EnvironmentObject private var store: AppStore

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var message: String?
    @State private var isError = false
    @State private var cacheSize = ""
    @State private var loaded = false
    @AppStorage("mangadock.enhance") private var enhanceDefault = false
    @AppStorage("mangadock.appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("mangadock.defaultLayout") private var defaultLayoutRaw = LayoutMode.grid.rawValue
    @AppStorage("mangadock.readerMode") private var defaultReaderMode = ReaderMode.paged.rawValue

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
                    Picker("外观", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    Picker("新目录默认视图", selection: $defaultLayoutRaw) {
                        Text("网格").tag(LayoutMode.grid.rawValue)
                        Text("列表").tag(LayoutMode.list.rawValue)
                    }
                } header: {
                    Text("显示")
                } footer: {
                    Text("每个目录的列表/网格是分开记的：书架设成网格，二级目录设成列表，互不影响。这里只决定第一次进入某个目录时用哪种。")
                }

                Section {
                    Picker("默认翻页方式", selection: $defaultReaderMode) {
                        ForEach(ReaderMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                } header: {
                    Text("阅读")
                } footer: {
                    Text("打开漫画时默认用哪种方式：左右翻页，或者像条漫一样上下滚动。阅读器右上角的按钮可以临时切换，不改这里的默认值。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前引擎").font(.subheadline)
                        Text(ImageEnhancer.engineDescription)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Toggle("默认开启画质增强", isOn: $enhanceDefault)
                } header: {
                    Text("图像增强")
                } footer: {
                    Text("增强在本地 GPU 上跑：2 倍 Lanczos 上采样 + 锐化，对低分辨率扫描件效果明显。\n真·AI 超分 / 上色需要模型本体（Core ML 或云端接口），App 里没有内置模型时不会假装有。")
                }

                Section {
                    HStack {
                        Text("缓存占用")
                        Spacer()
                        Text(cacheSize).foregroundColor(.secondary)
                    }
                    Button("清除漫画缓存", role: .destructive) {
                        CacheManager.clear()
                        CoverStore.shared.clearMemory()
                        refreshCacheSize()
                    }
                    Button("清空阅读记录", role: .destructive) {
                        store.clearRecent()
                    }
                } header: {
                    Text("本地数据")
                } footer: {
                    Text("缓存的是下载过的 CBZ、看过的散图和网格封面，清掉不影响服务器上的文件。")
                }

                Section("关于") {
                    LabeledContent("版本", value: Self.appVersion)
                    LabeledContent("支持格式", value: "CBZ / ZIP / PDF / 图片文件夹")
                    Text("不支持 CBR（RAR），CBR 可以先转成 CBZ。PDF 会整本下载后逐页渲染。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(initialSetup ? "连接 WebDAV" : "设置")
        .navigationBarTitleDisplayMode(initialSetup ? .large : .inline)
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

    /// Read straight from the bundle so the label can never desync from the build.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
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
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isError = true
        }
        isTesting = false
    }
}
