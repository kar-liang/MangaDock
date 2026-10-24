import Foundation
import SwiftUI

@MainActor
final class FolderLoader: ObservableObject {
    @Published var items: [WebDAVItem] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    var imageCount: Int {
        items.filter { !$0.isDirectory && $0.isImage }.count
    }

    func load(url: URL?, client: WebDAVClient?) async {
        guard let url, let client else {
            isLoading = false
            errorMessage = "还没有配置服务器"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            items = try await client.list(url)
            isLoading = false
        } catch {
            errorMessage = NetErrorText.friendly(error)
            isLoading = false
        }
    }
}
