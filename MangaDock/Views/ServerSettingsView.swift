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
    @AppStorage(ImageEnhancer.lineDarkenKey) private var lineDarken = 0.18
    @AppStorage(ImageEnhancer.lineThinKey) private var lineThin = 0.45

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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前引擎").font(.subheadline)
                        Text(ImageEnhancer.engineDescription)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Toggle("默认开启画质增强", isOn: $enhanceDefault)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("线条加黑")
                            Spacer()
                            Text(String(format: "%.2f", lineDarken))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $lineDarken, in: 0...0.6, step: 0.02)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("细化线条")
                            Spacer()
                            Text(String(format: "%.2f", lineThin))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $lineThin, in: 0...1, step: 0.05)
                    }
                } header: {
                    Text("图像增强")
                } footer: {
                    Text("Metal 边缘导向放大：沿边缘方向重采样，跨边缘方向保持原样，所以 1 像素的线条放大后还是 1 像素，不会糊成灰边。\n线条加黑按梯度识别线稿单独加深（整图无差别锐化会出光晕）；细化线条把描边的灰色过渡压向黑白两端，小字更利落。\n两个滑块改完，重新打开漫画生效。\n真·AI 超分需要模型本体：把 SuperResolution.mlmodelc 丢进 target 就会自动接管，没有就不假装有。")
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
                    LabeledContent("版本", value: "1.3")
                    LabeledContent("支持格式", value: "CBZ / ZIP / 图片文件夹")
                    Text("不支持 CBR（RAR）和 PDF。CBR 可以先转成 CBZ。")
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
