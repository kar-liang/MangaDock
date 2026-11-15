import SwiftUI
import Translation

/// 翻译设置。
///
/// 两条腿：
/// - **大模型**（OpenAI 兼容接口）：质量最好，但要填地址/Key/模型名，
///   而且**台词的文字会发到那个接口**（图片永远不会）。
/// - **系统端上翻译**：iOS 18 自带的 Translation 框架，完全离线，质量一般。
///
/// 默认 `auto`：配了接口走大模型，没配退回端上。
struct TranslationSettingsView: View {
    @AppStorage(TranslationPrefs.targetKey) private var targetRaw = TranslationTarget.simplifiedChinese.rawValue
    @AppStorage(TranslationPrefs.sourceKey) private var sourceRaw = TranslationSourceHint.auto.rawValue
    @AppStorage(TranslationPrefs.autoKey) private var autoTranslate = true
    @AppStorage(TranslationPrefs.refineKey) private var refineSmallText = true
    @AppStorage(TranslationPrefs.fontSizeKey) private var fontSize = 14.0
    @AppStorage(TranslationPrefs.prefetchKey) private var prefetchEnabled = true
    @AppStorage(TranslationPrefs.prefetchCountKey) private var prefetchCount = 2

    @AppStorage(TranslationPrefs.engineKey) private var engineRaw = TranslationEngine.auto.rawValue
    @AppStorage(TranslationPrefs.baseURLKey) private var baseURL = ""
    @AppStorage(TranslationPrefs.modelKey) private var model = ""

    /// API Key 只在 Keychain 里，所以不能用 @AppStorage，走 @State 中转。
    @State private var apiKey = ""
    @State private var revealKey = false
    @State private var testing = false
    @State private var testOK: Bool?
    @State private var testMessage: String?

    @State private var cacheSize = TranslationCache.formattedSize()
    @State private var confirmClear = false

    private var engine: TranslationEngine {
        TranslationEngine(rawValue: engineRaw) ?? .auto
    }

    private var currentTarget: TranslationTarget {
        TranslationTarget(rawValue: targetRaw) ?? .simplifiedChinese
    }

    /// `auto` 模式下实际会走哪条腿 —— 用户最想知道的就是这个。
    private var effectiveEngineLabel: String {
        TranslationPrefs.usesLLM ? "大模型" : "系统端上"
    }

    var body: some View {
        Form {
            Section {
                Picker("引擎", selection: $engineRaw) {
                    ForEach(TranslationEngine.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                HStack {
                    Text("当前生效")
                    Spacer()
                    Text(effectiveEngineLabel)
                        .foregroundColor(.secondary)
                }
                Text(engine.detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("引擎")
            } footer: {
                Text("「自动」= 下面填了接口就用大模型，没填就用系统端上模型。这样临时清空 Key 也不会变成点翻译没反应。")
            }

            Section {
                TextField("接口地址", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { saveKey() }

                HStack {
                    if revealKey {
                        TextField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                TextField("模型名", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Text(testing ? "正在测…" : "测试连接")
                        if testing {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(testing || baseURL.isEmpty || apiKey.isEmpty || model.isEmpty)

                if let testMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: testOK == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(testOK == true ? .green : .red)
                        Text(testMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("大模型接口")
            } footer: {
                Text("OpenAI 兼容的 `/chat/completions` 接口，填到 `/v1` 为止就行，剩下的自动拼。\n例如 DeepSeek：`https://api.deepseek.com/v1` + `deepseek-chat`；OpenAI：`https://api.openai.com/v1` + `gpt-4o-mini`；本地 Ollama：`http://192.168.2.144:11434/v1` + 模型名。\n\n⚠️ 走大模型时，识别出的台词**文字**会发到这个接口（图片不会，图片从来不出手机）。不想外发就把引擎切到「系统端上翻译」。")
            }

            Section {
                Picker("翻成", selection: $targetRaw) {
                    ForEach(TranslationTarget.allCases) { target in
                        Text(target.title).tag(target.rawValue)
                    }
                }
                Picker("原文语种", selection: $sourceRaw) {
                    ForEach(TranslationSourceHint.allCases) { hint in
                        Text(hint.title).tag(hint.rawValue)
                    }
                }
            } header: {
                Text("语言")
            } footer: {
                Text("「原文语种」只影响识别，不影响翻译。选「自动识别」时会先按假名/谚文判断，再退回系统语种识别 —— 日漫里汉字多，自动识别偶尔会把日文当成中文，只日漫的话直接选「日文优先」。")
            }

            Section {
                Toggle("翻页自动翻译", isOn: $autoTranslate)
                Toggle("小字二次识别", isOn: $refineSmallText)
            } header: {
                Text("识别")
            } footer: {
                Text("「小字二次识别」会把每个气泡裁出来放大再认一遍。小字识别率明显更高，代价是每页多花一到两秒。关掉会快一倍。")
            }

            Section {
                Toggle("预载翻译", isOn: $prefetchEnabled)
                if prefetchEnabled {
                    Stepper("提前翻 \(prefetchCount) 页", value: $prefetchCount, in: 1...5)
                }
            } header: {
                Text("预载")
            } footer: {
                Text("当前页翻完后，后台接着把后面几页也翻好，翻到那页直接出译文，不用等。一页一页串行推进，不会把机器压死。\n\n⚠️ 预载会提前取后面几页的图片数据（要联网下载），也会把那些台词发给大模型。移动网络下留意流量和调用次数。关掉就只翻当前页。")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("译文卡片字号")
                        Spacer()
                        Text("\(Int(fontSize)) pt")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $fontSize, in: 10...22, step: 1)
                }
            } header: {
                Text("显示")
            } footer: {
                Text("字号是「不缩放时」的大小。放大看画面时卡片会按比例缩，屏幕上的视觉大小保持不变。")
            }

            Section {
                HStack {
                    Text("缓存")
                    Spacer()
                    Text(cacheSize).foregroundColor(.secondary)
                }
                Button("清除翻译缓存", role: .destructive) {
                    confirmClear = true
                }
            } header: {
                Text("存储")
            } footer: {
                Text("识别结果和译文都存在本地，同一页翻第二次是秒开。清除后下次看会重新识别、重新调接口。")
            }
        }
        .navigationTitle("翻译")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = TranslationPrefs.llmAPIKey
            cacheSize = TranslationCache.formattedSize()
        }
        .onChange(of: apiKey) { _ in
            saveKey()
        }
        .confirmationDialog("清除翻译缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                TranslationCache.clear()
                TranslationService.shared.clearState()
                cacheSize = TranslationCache.formattedSize()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删本地缓存的识别结果和译文，不影响漫画文件。")
        }
    }

    private func saveKey() {
        TranslationPrefs.saveAPIKey(apiKey)
    }

    private func runTest() async {
        testing = true
        testMessage = nil
        testOK = nil
        defer { testing = false }

        let config = LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
        do {
            let sample = try await LLMTranslator.test(config: config, target: currentTarget)
            testOK = true
            testMessage = "通了。示例译文：\(sample)"
        } catch {
            testOK = false
            if let llm = error as? LLMTranslateError {
                testMessage = llm.errorDescription
            } else {
                testMessage = error.localizedDescription
            }
        }
    }
}
