import Foundation

/// 后端服务器的统一接口。
///
/// 目前两种实现：
/// - `WebDAVClient` —— 目录树 + PROPFIND，地址是真实的 http(s) URL
/// - `KomgaClient`  —— REST API，地址是虚拟的 `komga://` 空间
///
/// 上层的书架、系列页、阅读器只认这五个方法，不关心下面是什么服务器。
protocol RemoteClient: AnyObject {
    /// 列目录。Komga 的实现会把 library / series 映射成"目录"。
    func list(_ url: URL) async throws -> [WebDAVItem]

    /// 连通性探测。
    func ping() async throws

    /// 取整块数据（页面图、封面、同步文件）。
    func data(for url: URL) async throws -> Data

    /// 按字节范围读。Komga 不支持，返回 nil 让调用方回退。
    func data(_ url: URL, byteRange: ClosedRange<Int64>) async throws -> Data?

    /// 资源长度。Komga 不支持，返回 nil。
    func contentLength(_ url: URL) async throws -> Int64?
}

extension WebDAVClient: RemoteClient {}
