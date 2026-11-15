import Foundation

/// 自定义大模型翻译（OpenAI 兼容的 `/chat/completions`）。
///
/// 只发**文字**，不发图片：OCR 在端上跑完，这里拿到的是一页的台词文本。
/// 这是整个人工智能链路里唯一一次外发，设置页里写明了。
struct LLMConfig {
    var baseURL: String
    var apiKey: String
    var model: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 拼出真正要打的那个地址。
    ///
    /// 用户可能填 `https://api.deepseek.com`、`.../v1`，也可能直接填完整的
    /// `.../v1/chat/completions`。三种都认：
    /// - 已经以 `/chat/completions` 结尾 → 原样用
    /// - 路径里已经带了 `/v1`、`/v1beta`、`/openai`、`/api` → 直接接 `/chat/completions`
    /// - 其它（多半只填了域名）→ 补一个 `/v1`
    ///
    /// ⚠️ 判断「路径里有没有」时必须先把域名切掉：`https://api.deepseek.com`
    /// 的 `//api` 里就含 `/api`，不切的话会误判成「已经有路径了」，
    /// 结果拼出 `https://api.deepseek.com/chat/completions` 直接 404。
    var endpoint: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }

        if text.hasSuffix("/chat/completions") {
            return URL(string: text)
        }

        var path = ""
        if let marker = text.range(of: "://") {
            let afterScheme = text[marker.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                path = String(afterScheme[slash...])
            }
        }

        let knownPrefixes = ["/v1", "/v1beta", "/openai", "/api"]
        if !knownPrefixes.contains(where: { path.hasPrefix($0) || path.contains($0 + "/") }) {
            text += "/v1"
        }
        return URL(string: text + "/chat/completions")
    }
}

enum LLMTranslateError: LocalizedError {
    case notConfigured
    case badURL
    case unauthorized
    case rateLimited
    case server(Int, String)
    case emptyResponse
    case unparsable(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "大模型还没配好，去设置里填地址、Key 和模型名"
        case .badURL:
            return "接口地址不对，检查一下能不能拼成 /chat/completions"
        case .unauthorized:
            return "API Key 被拒了（401/403），检查 Key 和模型权限"
        case .rateLimited:
            return "接口限流了（429），等一下再试"
        case .server(let code, let message):
            return "接口报错 \(code)：\(message)"
        case .emptyResponse:
            return "模型返回了空内容"
        case .unparsable(let raw):
            let preview = raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
            return "模型返回的内容解析不了：\(preview)"
        case .network(let message):
            return "连不上接口：\(message)"
        }
    }
}

enum LLMTranslator {

    /// 一页最长给模型多少条。漫画一页正常 8–20 条，多的也塞得下，
    /// 但超过这个数就拆批，免得输出被截断导致整页解析失败。
    private static let maxBatch = 40

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // 大模型出字慢，30 秒经常不够一页 20 条台词。
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - 对外

    /// 翻一批台词。返回 `blockID → 译文`。
    static func translate(blocks: [TextBlock],
                          config: LLMConfig,
                          target: TranslationTarget) async throws -> [Int: String] {
        guard config.isConfigured else { throw LLMTranslateError.notConfigured }
        guard let endpoint = config.endpoint else { throw LLMTranslateError.badURL }

        var result: [Int: String] = [:]
        var start = 0
        while start < blocks.count {
            let end = min(start + maxBatch, blocks.count)
            let chunk = Array(blocks[start..<end])
            start = end

            let batch = try await request(chunk: chunk,
                                          endpoint: endpoint,
                                          config: config,
                                          target: target)
            result.merge(batch) { _, new in new }
        }
        return result
    }

    /// 设置页的「测试连接」：拿一句话走一遍完整流程，验证地址/Key/模型名都对。
    static func test(config: LLMConfig, target: TranslationTarget) async throws -> String {
        let probe = TextBlock(id: 0,
                              source: "Hello, world. こんにちは。",
                              translated: nil,
                              rect: NormalizedRect(x: 0, y: 0, width: 0, height: 0),
                              vertical: false,
                              language: nil)
        let result = try await translate(blocks: [probe], config: config, target: target)
        guard let text = result[0], !text.isEmpty else {
            throw LLMTranslateError.emptyResponse
        }
        return text
    }

    // MARK: - 单批

    private static func request(chunk: [TextBlock],
                                endpoint: URL,
                                config: LLMConfig,
                                target: TranslationTarget) async throws -> [Int: String] {
        let payload = chunk.map { ["id": String($0.id), "text": $0.source] }
        guard let inputData = try? JSONSerialization.data(withJSONObject: payload),
              let input = String(data: inputData, encoding: .utf8) else {
            throw LLMTranslateError.unparsable("")
        }

        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            // 翻译要稳定，别让它自由发挥。
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt(target: target)],
                ["role": "user", "content": input]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMTranslateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMTranslateError.network("没有拿到 HTTP 响应")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw LLMTranslateError.unauthorized
        case 429:
            throw LLMTranslateError.rateLimited
        default:
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw LLMTranslateError.server(http.statusCode, message)
        }

        guard let content = Self.content(from: data), !content.isEmpty else {
            throw LLMTranslateError.emptyResponse
        }
        let parsed = Self.parseTranslations(content)
        guard !parsed.isEmpty else { throw LLMTranslateError.unparsable(content) }
        return parsed
    }

    // MARK: - Prompt

    /// 这几条约束不是凑数的，每条都对应一类翻车：
    /// 漏条 → 位置对不上；加解释 → 卡片里塞满"注："；书面语 → 漫画读着出戏；
    /// 输出 markdown → 解析直接崩。
    private static func systemPrompt(target: TranslationTarget) -> String {
        """
        你是专业的漫画翻译。用户会给你一页漫画里按阅读顺序排列的台词，JSON 数组格式，\
        每条形如 {"id": "3", "text": "台词原文"}。

        请把它们翻译成\(target.title)。

        要求：
        1. 逐条翻译，id 一一对应。不要合并、不要拆分、不要漏条、不要新增。
        2. 用漫画口语翻译，短句优先。语气词、称呼、口癖按人物口吻处理，不要翻成书面语或新闻腔。
        3. 拟声词翻成对应的中文拟声词（ドキドキ → 怦怦、バン → 砰、ざわざわ → 嘈杂）。
        4. 原文里没说的话不要补，原文有的意思不要省。
        5. 不要加任何解释、注释、罗马音、括号补充说明。
        6. 只输出 JSON 对象，形如 {"0": "译文", "1": "译文"}。不要 markdown 代码块，不要前后废话。
        """
    }

    // MARK: - 解析

    private static func content(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).map { String($0.prefix(120)) }
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = object["message"] as? String { return message }
        return nil
    }

    /// 从模型返回里抠出 `id → 译文`。
    ///
    /// 分三层兜底，因为「只输出 JSON」这条约束模型并不总是听话：
    /// 1. 直接当 JSON 解
    /// 2. 去掉 ```json 围栏后再解
    /// 3. 截取第一个 `{` 到最后一个 `}` 再解
    /// 全失败就返回空，让上层报「解析不了」并显示原文片段。
    static func parseTranslations(_ raw: String) -> [Int: String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let direct = decodeJSONObject(text) { return direct }

        // 去 markdown 围栏
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last, last.hasPrefix("```") { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let fenced = decodeJSONObject(text) { return fenced }
        }

        // 前后有废话：截取最外层花括号
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"), start < end {
            let slice = String(text[start...end])
            if let wrapped = decodeJSONObject(slice) { return wrapped }
        }

        return [:]
    }

    private static func decodeJSONObject(_ text: String) -> [Int: String]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [Int: String] = [:]
        for (key, value) in object {
            guard let id = Int(key) else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[id] = trimmed }
            }
        }
        return result.isEmpty ? nil : result
    }
}
