import SwiftUI
import UIKit

/// 设置 → 检查更新。
///
/// iOS 装包这件事 App 自己做不了（没有开发者账号，也没有静默安装的口子），
/// 所以这一页只做到「把 IPA 抓到本机 + 拉起分享面板」，签名安装交给
/// SideStore / AltStore / 自签工具。
struct UpdateSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var updater = Updater.shared

    @State private var customManifest = UserDefaults.standard.string(forKey: Updater.manifestKey) ?? ""
    @State private var showAdvanced = false
    @State private var sharing: URL?

    private var base: URL? {
        store.savedProfile(.webdav).lines.first.flatMap { AppStore.normalizedURL($0) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本", value: Updater.currentText)
                if let last = updater.lastChecked {
                    LabeledContent("上次检查", value: last.formatted(date: .omitted, time: .shortened))
                }
                Button {
                    Task { await updater.check(store: store) }
                } label: {
                    HStack {
                        Text("检查更新")
                        Spacer()
                        if case .checking = updater.phase { ProgressView() }
                    }
                }
                .disabled(isBusy)
            } footer: {
                Text("清单和 IPA 放在 WebDAV 服务器上，和 Android 的更新目录共用一套账号。")
            }

            statusSection

            Section {
                DisclosureGroup("更新清单地址", isExpanded: $showAdvanced) {
                    TextField(Updater.suggestedManifestText(base: base), text: $customManifest)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote)
                    Button("恢复默认地址") {
                        customManifest = ""
                        UserDefaults.standard.removeObject(forKey: Updater.manifestKey)
                    }
                    .font(.footnote)
                }
            } footer: {
                Text("留空就用默认地址：和当前 WebDAV 同一台主机下的 \(Updater.updatesPath)/\(Updater.manifestFileName)。改完记得回来点检查。")
            }
        }
        .navigationTitle("检查更新")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: customManifest) { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: Updater.manifestKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Updater.manifestKey)
            }
        }
        .sheet(item: Binding(get: { sharing.map { ShareItem(url: $0) } },
                             set: { if $0 == nil { sharing = nil } })) { item in
            ActivityView(items: [item.url])
        }
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch updater.phase {
        case .idle:
            Section {
                Text("点上面的「检查更新」看看有没有新版。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .checking:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读清单…").font(.footnote).foregroundStyle(.secondary)
                }
            }

        case .latest(let version):
            Section {
                Label("已是最新 · \(version)", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            }

        case .found(let info):
            Section {
                LabeledContent("最新版本", value: "\(info.versionName) (\(info.build))")
                if !info.notes.isEmpty {
                    Text(info.notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await updater.download(store: store) }
                } label: {
                    Label("下载 IPA", systemImage: "arrow.down.circle")
                }
            } header: {
                Text("有新版本")
            } footer: {
                Text("下载完会存到本机，然后拉起分享面板：可以「存储到文件」，再用 SideStore / AltStore 自签安装。")
            }

        case .downloading(let progress):
            Section {
                if progress >= 0 {
                    ProgressView(value: min(max(progress, 0), 1)) {
                        Text("正在下载 \(Int(progress * 100))%")
                            .font(.footnote)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在下载…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

        case .ready(let path):
            Section {
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text((path as NSString).lastPathComponent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    sharing = URL(fileURLWithPath: path)
                } label: {
                    Label("存储到「文件」/ 分享", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { await updater.check(store: store) }
                } label: {
                    Text("重新检查").font(.footnote)
                }
            } footer: {
                Text("文件也在「文件」App → 我的 iPhone → 漫画坞 → updates 里，自签工具可以直接从那儿取。")
            }

        case .failed(let message):
            Section {
                Label("没成功", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await updater.check(store: store) }
                }
            }
        }
    }
}

// MARK: - 分享面板

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
