import SwiftUI

/// Settings root: a menu of categories instead of one long form.
///
/// Everything that used to live in a single screen is now one level down, so
/// the first thing you see is the eight things you might want — not 40 rows.
struct SettingsHomeView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var diagLog = DiagLog.shared

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ServerSettingsView(initialSetup: false)
                } label: {
                    row(icon: "externaldrive.connected.to.line.below",
                        title: "WebDAV 服务器",
                        detail: serverSummary)
                }
            } footer: {
                Text("服务器地址、账号密码、连接诊断都在这里。")
            }

            Section {
                NavigationLink {
                    ReadingSettingsView()
                } label: {
                    row(icon: "book", title: "阅读与显示", detail: nil)
                }

                NavigationLink {
                    StorageSettingsView()
                } label: {
                    row(icon: "internaldrive", title: "存储与下载", detail: downloadSummary)
                }

                NavigationLink {
                    SyncSettingsView()
                } label: {
                    row(icon: "arrow.triangle.2.circlepath", title: "多设备同步", detail: syncSummary)
                }

                // value-based on purpose: the private shelf pushes the reader
                // with value links, and that only composes from a value push.
                NavigationLink(value: NavTarget.privateShelf) {
                    row(icon: "lock", title: "隐私空间",
                        detail: PrivacyStore.shared.count == 0 ? "空" : "\(PrivacyStore.shared.count) 部")
                }
            } header: {
                Text("使用")
            }

            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    row(icon: "stethoscope", title: "诊断日志",
                        detail: diagLog.isEnabled
                            ? (diagLog.entries.isEmpty ? "记录中" : "记录中 · \(diagLog.entries.count) 条")
                            : "已关闭")
                }

                NavigationLink {
                    AboutSettingsView()
                } label: {
                    row(icon: "info.circle", title: "关于", detail: AppVersion.short)
                }
            } header: {
                Text("其他")
            }
        }
        .navigationTitle("设置")
        .libraryNavigation()
    }

    private var serverSummary: String {
        guard let host = store.baseURL?.host else { return "未配置" }
        return host
    }

    private var downloadSummary: String {
        downloads.records.isEmpty ? "无" : "\(downloads.records.count) 章 · \(downloads.formattedSize)"
    }

    private var syncSummary: String {
        guard SyncService.isEnabled else { return "已关闭" }
        return SyncService.lastSyncDate.map { $0.formatted(date: .omitted, time: .shortened) } ?? "从未"
    }

    private func row(icon: String, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(title)
            Spacer()
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Reading & display

struct ReadingSettingsView: View {
    @AppStorage("mangadock.readerMode") private var defaultReaderMode = ReaderMode.paged.rawValue
    @AppStorage("mangadock.enhance") private var enhanceDefault = false
    @AppStorage("mangadock.appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("mangadock.defaultLayout") private var defaultLayoutRaw = LayoutMode.grid.rawValue
    @AppStorage("mangadock.tab.shelf") private var showShelfTab = true
    @AppStorage("mangadock.tab.files") private var showFilesTab = true
    @AppStorage("mangadock.tab.history") private var showHistoryTab = false
    @AppStorage("mangadock.bangumi.enabled") private var bangumiEnabled = true
    @AppStorage("mangadock.bangumi.base") private var bangumiBase = ""

    var body: some View {
        Form {
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

                if ImageEnhancer.hasAIModel {
                    Picker("AI 超分倍数", selection: Binding(
                        get: { ImageEnhancer.aiScale.rawValue },
                        set: { ImageEnhancer.aiScale = AIEnhancer.Scale(rawValue: $0) ?? .two }
                    )) {
                        ForEach(AIEnhancer.Scale.allCases, id: \.rawValue) { scale in
                            Text(scale.title).tag(scale.rawValue)
                        }
                    }
                }
            } header: {
                Text("图像增强")
            } footer: {
                Text(ImageEnhancer.hasAIModel
                     ? "已内置 Real-ESRGAN 动漫超分模型。开启增强后：先跑 GPU 快速增强，再叠加 AI 超分重建细节，一页约需数秒。4 倍细节更丰富但更慢、更占内存。\n这两个设置是全局默认值，每本漫画在阅读器里单独调过之后，会记住那本的选择。"
                     : "增强在本地 GPU 上跑：2 倍 Lanczos 上采样 + 锐化，对低分辨率扫描件效果明显。未内置 AI 模型。")
            }

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
                Text("已经手动设过视图的目录会保留原来的记忆，新目录跟随「默认视图」。")
            }

            Section {
                Toggle("显示 Bangumi 元数据", isOn: $bangumiEnabled)
                TextField("接口地址（留空用官方）", text: $bangumiBase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("清除元数据缓存") {
                    BangumiClient.shared.clearCache()
                    BangumiImageCache.shared.clear()
                }
            } header: {
                Text("Bangumi 元数据")
            } footer: {
                Text("在章节列表上方显示封面、简介、评分、标签。名字对不上时会给你一个手动关联入口。\n官方地址 api.bgm.tv 在部分网络下连不通（DNS 污染），可以填自建转发地址，形如 https://你的域名/bgm/v0。")
            }

            Section {
                Toggle("书架", isOn: $showShelfTab)
                Toggle("文件", isOn: $showFilesTab)
                Toggle("记录", isOn: $showHistoryTab)
            } header: {
                Text("底栏标签")
            } footer: {
                Text("关掉的标签会从底栏消失，数据不会删。设置页始终显示，免得把自己锁在外面。")
            }
        }
        .navigationTitle("阅读与显示")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage & downloads

struct StorageSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var reads = ReadStateStore.shared

    @State private var cacheSize = ""
    @State private var confirmClearCache = false
    @State private var confirmClearCovers = false
    @State private var customCoverCount = 0

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("缓存占用")
                    Spacer()
                    Text(cacheSize.isEmpty ? "计算中…" : cacheSize).foregroundColor(.secondary)
                }
                Button("清除漫画缓存", role: .destructive) {
                    confirmClearCache = true
                }
            } header: {
                Text("缓存")
            } footer: {
                Text("缓存的是下载过的 CBZ、看过的散图和自动生成的封面，清掉不影响服务器上的文件。你自己设置的自定义封面不算缓存，不会被清掉。")
            }

            Section {
                HStack {
                    Text("自定义封面")
                    Spacer()
                    Text(customCoverCount == 0 ? "无" : "\(customCoverCount) 张")
                        .foregroundColor(.secondary)
                }
                Button("清除所有自定义封面", role: .destructive) {
                    confirmClearCovers = true
                }
                .disabled(customCoverCount == 0)
            } header: {
                Text("封面")
            } footer: {
                Text("自定义封面优先于 Bangumi 封面。清掉后，书架会自动回到 Bangumi 的封面（没有匹配到条目的则回到第一页生成的封面）。")
            }

            Section {
                HStack {
                    Text("已下载章节")
                    Spacer()
                    Text(downloads.records.isEmpty
                         ? "无"
                         : "\(downloads.records.count) 章 · \(downloads.formattedSize)")
                        .foregroundColor(.secondary)
                }
                if downloads.isBusy {
                    Button("取消正在进行的下载", role: .destructive) {
                        downloads.cancelAll()
                    }
                }
                Button("删除所有下载", role: .destructive) {
                    downloads.removeAll()
                }
                .disabled(downloads.records.isEmpty)
            } header: {
                Text("离线下载")
            } footer: {
                Text("在章节列表右上角可以下载整本，左滑单个章节可以只下一章。下载的内容固定在手机上，没网也能看，不占 iCloud 备份空间。")
            }

            Section {
                Button("清空阅读记录", role: .destructive) {
                    store.clearRecent()
                }
                Button("清空已读标记") {
                    ReadStateStore.shared.clearAll()
                }
                .disabled(reads.marks.isEmpty)
            } header: {
                Text("阅读记录")
            } footer: {
                Text("清空阅读记录会同时清掉「继续阅读」的进度；已读标记是按章节单独记的，清空后回到「读到最后一页才算已读」的自动判断。")
            }
        }
        .navigationTitle("存储与下载")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshCacheSize()
            customCoverCount = CoverStore.shared.customCovers.count
        }
        .confirmationDialog("清除漫画缓存？", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                CacheManager.clear()
                CoverStore.shared.clearMemory()
                refreshCacheSize()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清掉缓存和解压出来的图片，下次打开需要重新下载。你设置的自定义封面会保留。")
        }
        .confirmationDialog("清除所有自定义封面？", isPresented: $confirmClearCovers, titleVisibility: .visible) {
            Button("清除 \(customCoverCount) 张", role: .destructive) {
                CoverStore.shared.removeAllCustomCovers()
                customCoverCount = 0
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后不可撤销，书架会回到 Bangumi 封面或自动生成的封面。")
        }
    }

    private func refreshCacheSize() {
        cacheSize = CacheManager.formattedSize()
    }
}

// MARK: - Sync

struct SyncSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("mangadock.syncEnabled") private var syncEnabled = true

    @State private var syncMessage: String?
    @State private var syncBusy: SyncAction?
    @State private var confirmDownload = false

    private enum SyncAction: Equatable {
        case upload
        case download
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用自动同步", isOn: $syncEnabled)

                HStack {
                    Text("上次同步")
                    Spacer()
                    Text(SyncService.lastSyncDate.map { $0.formatted(date: .omitted, time: .shortened) } ?? "从未")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("自动同步")
            } footer: {
                Text("打开后，阅读进度、书架、设置会在变化后自动同步到服务器，最后写入的为准。")
            }

            Section {
                Button {
                    Task { await runSync(.upload) }
                } label: {
                    HStack {
                        Label("上传同步", systemImage: "arrow.up.to.line")
                        Spacer()
                        if syncBusy == .upload { ProgressView() }
                    }
                }
                .disabled(syncBusy != nil)

                Button {
                    confirmDownload = true
                } label: {
                    HStack {
                        Label("下载同步", systemImage: "arrow.down.to.line")
                        Spacer()
                        if syncBusy == .download { ProgressView() }
                    }
                }
                .disabled(syncBusy != nil)

                if let syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("手动同步")
            } footer: {
                Text("进度、书架、设置存到服务器上的隐藏文件（.mangadock-sync.json），你自己设置的封面单独存在 .mangadock-covers 目录。「上传同步」用本机覆盖云端，「下载同步」用云端覆盖本机。密码不会同步，每台设备自己填。")
            }
        }
        .navigationTitle("多设备同步")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("用云端数据覆盖这台设备？",
                            isPresented: $confirmDownload,
                            titleVisibility: .visible) {
            Button("下载并覆盖本机", role: .destructive) {
                Task { await runSync(.download) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机的书架、阅读进度和阅读设置会被服务器上的版本替换。")
        }
    }

    private func runSync(_ action: SyncAction) async {
        syncBusy = action
        syncMessage = nil
        switch action {
        case .upload:
            syncMessage = await store.uploadSync()
        case .download:
            syncMessage = await store.downloadSync()
        }
        syncBusy = nil
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("版本", value: AppVersion.full)
                LabeledContent("支持格式", value: "CBZ / ZIP / PDF / 图片文件夹")
            }
            Section {
                Text("不支持 CBR（RAR），CBR 可以先转成 CBZ。PDF 会整本下载后逐页渲染。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } footer: {
                Text("漫画坞 · 连接你自己的 WebDAV 服务器，不经过任何第三方。")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Single source of truth for the version string, read from the bundle so the
/// label can never desync from the actual build.
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    static var full: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(short) (\(build))"
    }
}
