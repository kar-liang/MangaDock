import SwiftUI
import UniformTypeIdentifiers

/// Local comics imported from the Files app — no WebDAV needed.
struct LocalLibraryView: View {
    @EnvironmentObject private var store: AppStore

    @State private var items: [WebDAVItem] = []
    @State private var showImporter = false
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("导入漫画", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("支持 CBZ / ZIP / PDF，导入后存在本机，不依赖 WebDAV 服务器。")
            }

            Section {
                if items.isEmpty {
                    Text("还没有本地漫画，点上面导入")
                        .foregroundColor(.secondary)
                }
                ForEach(items) { item in
                    NavigationLink(value: NavTarget.comic(item)) {
                        HStack(spacing: 12) {
                            Image(systemName: item.isPDF ? "doc.richtext" : "book.closed")
                                .foregroundColor(.secondary)
                                .frame(width: 22)
                            Text(item.displayName)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    .contextMenu {
                        Button("删除", role: .destructive) {
                            LocalLibrary.remove(item)
                            refresh()
                        }
                    }
                }
            } header: {
                Text("本地（\(items.count)）")
            }
        }
        .navigationTitle("本地文件")
        .navigationBarTitleDisplayMode(.inline)
        // No .libraryNavigation(): FilesView already registered the NavTarget
        // destinations; a duplicate registration broke pushes from here.
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                var imported = 0
                var skipped = 0
                for url in urls {
                    if LocalLibrary.importFile(from: url) { imported += 1 } else { skipped += 1 }
                }
                refresh()
                showToast(imported > 0
                          ? "已导入 \(imported) 本\(skipped > 0 ? "，跳过 \(skipped) 个不支持的文件" : "")"
                          : "没有可导入的漫画（只支持 CBZ / ZIP / PDF）")
            case .failure:
                showToast("导入取消")
            }
        }
        .overlay(alignment: .top) { toastView }
        .onAppear { refresh() }
    }

    private func refresh() {
        items = LocalLibrary.items()
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassPanel(cornerRadius: 16)
                .padding(.top, 6)
                .transition(.opacity)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}
