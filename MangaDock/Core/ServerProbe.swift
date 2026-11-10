import Foundation

/// 服务器连通性测试。设置页和导入向导共用 —— 之前两处各写一套，
/// 结果设置页那套**无论选什么类型都用 WebDAVClient**，拿 Komga 地址发
/// PROPFIND 会一直挂到 120 秒超时，看起来就是「一直显示连接中」。
enum ServerProbe {
    /// 单个地址的探测超时。探测只是「通不通」，不通就该几秒内给答案，
    /// 别让人对着转圈等两分钟。真正的请求另有更长的超时。
    static let probeTimeout: TimeInterval = 8

    struct Outcome {
        /// 连得上的地址（原样保留用户填的写法）
        var reachable: [String] = []
        /// 连不上的，带原因
        var failures: [String] = []

        var isOK: Bool { !reachable.isEmpty }

        /// 一行给 UI 显示的结果
        var summary: String {
            if reachable.isEmpty {
                return failures.isEmpty ? "没有可测试的地址"
                                         : "连不上：\(failures.joined(separator: "；"))"
            }
            let suffix = failures.isEmpty ? "" : "（\(failures.count) 个连不上：\(failures.joined(separator: "；"))）"
            return "\(reachable.count) 个地址可用\(suffix)"
        }
    }

    /// 并行测所有地址（多行），谁通算谁。
    static func test(kind: ServerKind, address: String,
                     username: String, password: String) async -> Outcome {
        let lines = address
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return Outcome(failures: ["先把服务器地址填上"])
        }

        // 先在主线程把文本解析成 URL，Task 里只做网络请求
        let parsed: [(raw: String, url: URL?)] = lines.map { line in
            (line, AppStore.normalizedURL(line))
        }

        var result = Outcome()
        await withTaskGroup(of: (String, URL?, String?).self) { group in
            for entry in parsed {
                guard let url = entry.url, url.host != nil else {
                    result.failures.append("\(entry.raw)：格式不对")
                    continue
                }
                group.addTask {
                    do {
                        switch kind {
                        case .webdav:
                            let client = WebDAVClient(username: username, password: password,
                                                      baseURL: url, timeout: probeTimeout)
                            _ = try await client.ping()
                        case .komga:
                            let client = KomgaClient(baseURL: url, username: username,
                                                     password: password, timeout: probeTimeout)
                            try await client.ping()
                        }
                        return (entry.raw, url, nil)
                    } catch {
                        return (entry.raw, url, NetErrorText.friendly(error))
                    }
                }
            }

            for await (raw, url, error) in group {
                if let error {
                    result.failures.append("\(url?.host ?? raw)：\(error)")
                } else {
                    result.reachable.append(raw)
                }
            }
        }
        return result
    }
}
