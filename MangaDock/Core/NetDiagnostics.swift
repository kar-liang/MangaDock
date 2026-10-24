import Foundation

/// Tries the same host three ways and reports the raw result of each, so TLS
/// problems can be diagnosed on the phone instead of guessed at.
enum NetDiagnostics {
    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let ok: Bool
    }

    final class Delegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
        private let forceAllow: Bool?

        init(forceAllow: Bool?) {
            self.forceAllow = forceAllow
        }

        private var allows: Bool {
            forceAllow ?? TrustPolicy.allowsSelfSigned
        }

        private func handle(_ challenge: URLAuthenticationChallenge,
                            _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if allows {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            handle(challenge, completionHandler)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            handle(challenge, completionHandler)
        }
    }

    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") && text.count > 8 { text.removeLast() }
        return URL(string: text)
    }

    static func run(_ rawURL: String) async -> [Result] {
        guard let base = normalize(rawURL) else {
            return [Result(title: "地址", detail: "地址为空或格式不对", ok: false)]
        }

        var results: [Result] = []

        // 1) Same rules as the app right now.
        results.append(await probe(base, label: "HTTPS · 按当前设置", forceAllow: nil))

        // 2) Ignore certificate validation entirely — proves whether the cert
        //    is the blocker or the handshake fails for another reason.
        results.append(await probe(base, label: "HTTPS · 强制忽略证书", forceAllow: true))

        // 3) Plain HTTP on the same host/port.
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        if let httpURL = components?.url {
            results.append(await probe(httpURL, label: "HTTP · 同端口", forceAllow: nil))
        }

        return results
    }

    private static func probe(_ url: URL, label: String, forceAllow: Bool?) async -> Result {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        let delegate = Delegate(forceAllow: forceAllow)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Result(title: label, detail: "通，HTTP \(code)", ok: true)
        } catch {
            return Result(title: label, detail: NetErrorText.friendly(error), ok: false)
        }
    }
}
