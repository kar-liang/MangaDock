import CryptoKit
import Foundation
import SwiftUI

/// 应用内更新（iOS）。
///
/// 和 Android 那边是同一套思路，只是**最后一步不同**：
/// - Android：下载 APK → 交给系统安装器，用户点「安装」；
/// - iOS：**没有开发者账号，装不了**。这里只负责把 IPA 抓到本机，
///   剩下的签名/安装交给 SideStore / AltStore / 自签工具。
///   所以「完成」状态是「文件已就位 + 拉起分享面板」，不是「安装」。
///
/// 清单是一份 JSON，放在 WebDAV 上（和 Android 的 `latest-android.json` 并列）：
///
/// ```json
/// {
///   "versionName": "2.6",
///   "build": 132,
///   "ipa": "MangaDock-2.6.ipa",
///   "sha256": "…（可选，填了就校验）",
///   "size": 18974898,
///   "notes": "这版改了什么"
/// }
/// ```
///
/// 地址默认推导成 `scheme://主机/Document/Mangadock/updates/latest-ios.json`
/// —— 就是 Android 那个 updates 目录，同一台 NAS、同一套账号密码，
/// 不用再让用户记第二个地址。推导不对时设置页里可以手改。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// 清单地址的手改入口。空 = 用推导出来的默认地址。
    static let manifestKey = "mangadock.update.manifest"
    static let manifestFileName = "latest-ios.json"
    static let updatesPath = "/Document/Mangadock/updates"

    enum Phase: Equatable {
        case idle
        case checking
        /// 已经是最新
        case latest(version: String)
        case found(UpdateInfo)
        /// 0…1，未知总量时给 -1
        case downloading(progress: Double)
        /// IPA 已落到沙盒，带上本地路径
        case ready(path: String)
        case failed(String)
    }

    struct UpdateInfo: Equatable {
        var versionName: String
        var build: Int
        var path: String
        var sha256: String?
        var size: Int64?
        var notes: String
    }

    @Published private(set) var phase: Phase = .idle
    /// 上次检查完成的时间，界面上显示「上次检查：3 分钟前」
    @Published private(set) var lastChecked: Date?

    // MARK: - 版本

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    static var currentText: String { "\(currentVersion) (\(currentBuild))" }

    // MARK: - 地址

    /// 清单地址。设置里填了就用手填的，否则按「同主机 + NAS 固定目录」推导。
    static func manifestURL(base: URL) -> URL? {
        let custom = (UserDefaults.standard.string(forKey: manifestKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            // 允许两种写法：直接给 .json 的完整地址，或者只给目录（自动补文件名）
            let normalized = AppStore.normalizedURL(custom)
            if custom.lowercased().hasSuffix(".json") { return normalized }
            return normalized?.appendingPathComponent(manifestFileName)
        }
        var comps = URLComponents()
        comps.scheme = base.scheme
        comps.host = base.host
        comps.port = base.port
        comps.path = updatesPath + "/" + manifestFileName
        return comps.url
    }

    /// 设置页里显示的「默认地址」，只用于提示。
    static func suggestedManifestText(base: URL?) -> String {
        guard let base, let url = manifestURL(base: base) else { return "—" }
        return url.absoluteString
    }

    // MARK: - 账号

    /// 更新清单和安装包都走当前 WebDAV 账号的凭据（和同步文件同一套）。
    private func account(_ store: AppStore) -> (base: URL, user: String, pass: String)? {
        let profile = store.savedProfile(.webdav)
        guard let first = profile.lines.first,
              let base = AppStore.normalizedURL(first) else { return nil }
        return (base, profile.username, Keychain.load(account: profile.id) ?? "")
    }

    // MARK: - 检查

    func check(store: AppStore) async {
        guard let account = account(store) else {
            phase = .failed("还没配 WebDAV 服务器。更新清单要放在 WebDAV 上，先配一台再来。")
            return
        }
        guard let url = Self.manifestURL(base: account.base) else {
            phase = .failed("清单地址拼不出来，去「高级」里手填一个。")
            return
        }

        phase = .checking
        let client = WebDAVClient(username: account.user, password: account.pass,
                                  baseURL: account.base, timeout: 20)
        do {
            let data = try await client.data(for: url)
            guard let info = Self.parse(data, manifestURL: url) else {
                phase = .failed("清单格式不对：至少要能读到 build 和 ipa 两个字段。")
                return
            }
            lastChecked = Date()
            if info.build > Self.currentBuild {
                phase = .found(info)
            } else {
                phase = .latest(version: info.versionName)
            }
        } catch {
            phase = .failed(Self.friendly(error, manifestURL: url))
        }
    }

    private static func friendly(_ error: Error, manifestURL: URL) -> String {
        if let dav = error as? WebDAVError {
            if case .badStatus(404) = dav {
                return "服务器上没有更新清单：\n\(manifestURL.path)\n\n把 \(manifestFileName) 和 IPA 一起放进这个目录。"
            }
            return dav.errorDescription ?? "\(dav)"
        }
        return (error as NSError).localizedDescription
    }

    private static func parse(_ data: Data, manifestURL: URL) -> UpdateInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let build = (object["build"] as? Int) ?? Int(object["build"] as? String ?? "") ?? 0
        let ipa = (object["ipa"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard build > 0, !ipa.isEmpty else { return nil }

        let name = (object["versionName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = (object["sha256"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let size = (object["size"] as? Int64) ?? Int64(object["size"] as? Int ?? 0)
        let notes = object["notes"] as? String ?? ""

        return UpdateInfo(versionName: name.isEmpty ? "\(build)" : name,
                          build: build,
                          path: resolve(ipa, manifestURL: manifestURL),
                          sha256: sha.isEmpty ? nil : sha,
                          size: size > 0 ? size : nil,
                          notes: notes)
    }

    /// `ipa` 支持三种写法：完整 URL、以 / 开头的服务器绝对路径、相对清单目录的文件名。
    private static func resolve(_ ipa: String, manifestURL: URL) -> String {
        let lower = ipa.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            if let url = AppStore.normalizedURL(ipa) { return url.absoluteString }
        }
        var comps = URLComponents()
        comps.scheme = manifestURL.scheme
        comps.host = manifestURL.host
        comps.port = manifestURL.port
        if ipa.hasPrefix("/") {
            comps.path = ipa
            return comps.url?.absoluteString ?? ipa
        }
        let dir = manifestURL.deletingLastPathComponent().path
        comps.path = (dir as NSString).appendingPathComponent(ipa)
        return comps.url?.absoluteString ?? ipa
    }

    // MARK: - 下载

    func download(store: AppStore) async {
        guard case .found(let info) = phase else { return }
        guard let account = account(store) else {
            phase = .failed("服务器账号不见了，回设置里看一眼。")
            return
        }
        guard let url = URL(string: info.path) else {
            phase = .failed("安装包地址不对：\(info.path)")
            return
        }

        let dir = Self.updateDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = (info.path as NSString).lastPathComponent.isEmpty
            ? "MangaDock-\(info.build).ipa"
            : (info.path as NSString).lastPathComponent
        let target = dir.appendingPathComponent(fileName)

        phase = .downloading(progress: 0)
        let client = WebDAVClient(username: account.user, password: account.pass,
                                  baseURL: account.base, timeout: 300)
        do {
            try await client.download(url, to: target) { value in
                // 回调在后台线程，状态在主 actor 上。
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(progress: value)
                }
            }
        } catch {
            phase = .failed("下载失败：\((error as NSError).localizedDescription)")
            return
        }

        // 清单给了 sha256 就校验；对不上直接删掉，别把半包递给自签工具
        if let expected = info.sha256 {
            let actual = Self.sha256(of: target)
            if actual != expected.lowercased() {
                try? FileManager.default.removeItem(at: target)
                phase = .failed("校验没通过（sha256 对不上），文件已删掉，重下一遍。")
                return
            }
        }

        phase = .ready(path: target.path)
    }

    /// IPA 落在 App 的 Documents 里 —— Info.plist 开了 UIFileSharingEnabled，
    /// 所以「文件」App 的「我的 iPhone → 漫画坞」里直接能看到，也能再分享出去。
    static var updateDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("updates", isDirectory: true)
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
