import SwiftUI

struct BrowserView: View {
    let folder: WebDAVItem

    @EnvironmentObject private var store: AppStore
    @State private var items: [WebDAVItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var imageCount: Int {
        items.filter { !$0.isDirectory && $0.isImage }.count
    }

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取…").foregroundColor(.secondary)
                }
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else {
                if imageCount > 0 {
                    Section {
                        NavigationLink(value: NavTarget.comic(folder)) {
                            Label("阅读这个文件夹（\(imageCount) 张图片）", systemImage: "book")
                        }
                    }
                }

                if items.isEmpty {
                    Section {
                        Text("这里没有漫画文件").foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(for item: WebDAVItem) -> some View {
        if let target = ItemTile.target(for: item) {
            NavigationLink(value: target) {
                ItemRow(item: item)
            }
        } else {
            ItemRow(item: item)
                .opacity(0.55)
        }
    }

    private func load() async {
        guard let client = store.makeClient() else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await client.list(folder.requestURL)
            isLoading = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }
}
