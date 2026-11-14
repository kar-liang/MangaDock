import SwiftUI
import Translation

/// 翻译设置。
///
/// 全部走 Apple 端上能力：Vision 识别 + Translation 端上翻译。
/// 没有 API key、没有第二台服务器、图片和文字都不出手机 ——
/// 这条线跟 MangaDock「只连你自己的服务器」是一回事。
struct TranslationSettingsView: View {
    @AppStorage(TranslationPrefs.targetKey) private var targetRaw = TranslationTarget.simplifiedChinese.rawValue
    @AppStorage(TranslationPrefs.sourceKey) private var sourceRaw = TranslationSourceHint.auto.rawValue
    @AppStorage(TranslationPrefs.autoKey) private var autoTranslate = true
    @AppStorage(TranslationPrefs.refineKey) private var refineSmallText = true
    @AppStorage(TranslationPrefs.fontSizeKey) private var fontSize = 14.0

    @State private var cacheSize = TranslationCache.formattedSize()
    @State private var confirmClear = false
    @State private var installedPairs: [String] = []

    var body: some View {
        Form {
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
                if !installedPairs.isEmpty {
                    Label("有语言包还没下载，第一次翻译时会提示下载",
                          systemImage: "arrow.down.circle")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("语言")
            } footer: {
                Text("原文语种选「自动识别」时会先按假名/谚文判断，再退回系统语种识别。日漫漫画里汉字多，自动识别偶尔会把日文当成中文 —— 只日漫的话直接选「日文优先」，识别会稳不少。")
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
                Text("识别结果和译文都存在本地，同一页翻第二次是秒开。清除后下次看会重新识别。")
            }

            Section {
                Text("翻译全部在手机本地完成：图片不出设备，文字不外发，不需要任何 API key。第一次翻某个语言对时，iOS 会弹窗让你下载对应的语言包（几十 MB，装一次就行），之后完全离线可用。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("翻译")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { cacheSize = TranslationCache.formattedSize() }
        .task { await checkAvailability() }
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

    /// 顺手把「目标语言的包装没装」查出来，没装就提示一句 ——
    /// 不然用户第一次点翻译会莫名其妙弹一个系统下载框。
    private func checkAvailability() async {
        let target = TranslationTarget(rawValue: targetRaw) ?? .simplifiedChinese
        let availability = LanguageAvailability()
        var missing: [String] = []
        for code in ["ja", "en", "ko", "zh"] where code != target.rawValue {
            let status = await availability.status(from: Locale.Language(identifier: code),
                                                   to: target.language)
            if status == .supported { missing.append(code) }
        }
        installedPairs = missing
    }
}
