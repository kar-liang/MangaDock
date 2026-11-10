import Foundation
import Security
import SwiftUI
import UIKit

/// Standard TLS validation for all requests. Servers with self-signed
/// certificates are rejected by design — the WebDAV endpoint (fnconnect) and
/// public comic sites all use properly signed certificates.
final class TLSTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    /// Session-level challenge.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        TLSTrustDelegate.handle(challenge, completionHandler)
    }

    /// Task-level challenge. A delegate that declares `URLSessionTaskDelegate`
    /// gets this one *instead* of the session-level method — implementing only
    /// one of the two silently falls back to system validation.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        TLSTrustDelegate.handle(challenge, completionHandler)
    }

    static func handle(_ challenge: URLAuthenticationChallenge,
                       _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Shared session for WebDAV / online-comic fetches — `URLSession.shared` can't
/// opt into self-signed trust, and AsyncImage can't either, hence `RemoteImage`.
enum ABSSession {
    private static let delegate = TLSTrustDelegate()

    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
}

/// Turns raw URLSession errors into something actionable, especially TLS ones.
enum NetErrorText {
    static func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError {
            let code = "URLError \(urlError.code.rawValue)"
            switch urlError.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "TLS 握手失败（\(code)）。若「信任自签名证书」已开仍失败，多半是服务器 TLS 版本/加密套件过旧，或者这个端口不是 HTTPS。"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "连不上服务器（\(code)）。核对地址和端口；域名解析是否只有 IPv6、当前网络是否支持。"
            case .timedOut:
                return "连接超时（\(code)）。服务器没响应，或者端口不通。"
            case .networkConnectionLost:
                return "连接被中断（\(code)），重试一次。"
            case .appTransportSecurityRequiresSecureConnection:
                return "被 ATS 拦了（\(code)），换 https 或检查反代。"
            default:
                return "\(code)：\(urlError.localizedDescription)"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Cover loading that respects the self-signed trust switch (AsyncImage can't).
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL?,
         contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url?.absoluteString) {
            await load()
        }
    }

    private func load() async {
        guard let url else { return }
        guard let (data, _) = try? await ABSSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return }
        image = decoded
    }
}
