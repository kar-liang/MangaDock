import SwiftUI

/// 阅读记录 tab.
struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if store.recent.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 30, weight: .light))
                                .foregroundColor(.secondary)
                            Text("还没有阅读记录")
                                .foregroundColor(.secondary)
                            Text("打开一本漫画就会记在这里，连页码一起")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                } else {
                    Section {
                        ForEach(store.recent) { entry in
                            if let item = entry.item {
                                NavigationLink(value: NavTarget.comic(item)) {
                                    row(entry: entry, item: item)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let snapshot = store.recent
                            for offset in offsets where offset < snapshot.count {
                                store.removeRecent(snapshot[offset])
                            }
                        }
                    } footer: {
                        Text("左滑删除单条记录。清除记录不会删除缓存和服务器上的文件。")
                    }
                }
            }
            .navigationTitle("阅读记录")
            .toolbar {
                if !store.recent.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("清空", role: .destructive) { showClearConfirm = true }
                    }
                }
            }
            .navigationDestination(for: NavTarget.self) { target in
                switch target {
                case .folder(let item):
                    BrowserView(folder: item)
                case .comic(let item):
                    ReaderView(item: item)
                }
            }
            .confirmationDialog("清空全部阅读记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { store.clearRecent() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func row(entry: RecentEntry, item: WebDAVItem) -> some View {
        HStack(spacing: 12) {
            CoverBox(item: item, width: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName).lineLimit(1)
                Text(entry.progressText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                ProgressView(value: progress(entry))
                    .tint(.orange)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func progress(_ entry: RecentEntry) -> Double {
        guard entry.pageCount > 0 else { return 0 }
        return min(1, Double(entry.page + 1) / Double(entry.pageCount))
    }
}
