import SwiftUI

/// Chapter list for one series. Reached by tapping a shelf entry; reading from
/// here still gets continuous chapter switching, because the reader rebuilds its
/// series from this folder's children.
struct SeriesView: View {
    let folder: WebDAVItem

    @EnvironmentObject private var store: AppStore
    @StateObject private var loader = FolderLoader()
    @State private var descending = false

    private var chapters: [WebDAVItem] {
        let items = loader.items.filter { $0.isDirectory || $0.isArchive || $0.isPDF }
        return descending ? items.reversed() : items
    }

    private var imageCount: Int {
        loader.items.filter { !$0.isDirectory && $0.isImage }.count
    }

    /// Most recently read chapter of this series, if any.
    private var resumeItem: (item: WebDAVItem, entry: RecentEntry)? {
        for entry in store.recent {
            if let item = chapters.first(where: { $0.url.absoluteString == entry.urlString }) {
                return (item, entry)
            }
        }
        return nil
    }

    var body: some View {
        List {
            if loader.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取章节…").foregroundColor(.secondary)
                }
            } else if let error = loader.errorMessage {
                ErrorStateView(message: error) {
                    Task { await reload() }
                }
            } else {
                if let resume = resumeItem {
                    Section {
                        NavigationLink(value: NavTarget.comic(resume.item)) {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("继续阅读")
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(resume.item.displayName) · \(resume.entry.progressText)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                if !chapters.isEmpty {
                    Section {
                        ForEach(chapters) { chapter in
                            NavigationLink(value: NavTarget.comic(chapter)) {
                                ChapterRow(item: chapter,
                                           progress: store.recentEntry(for: chapter.url))
                            }
                        }
                    } header: {
                        Text("章节（\(chapters.count)）")
                    }
                }

                if chapters.isEmpty && imageCount > 0 {
                    Section {
                        NavigationLink(value: NavTarget.comic(folder)) {
                            Label("阅读这个文件夹（\(imageCount) 张图片）", systemImage: "book")
                        }
                    }
                }

                if chapters.isEmpty && imageCount == 0 {
                    Section {
                        Text("这个目录里没有可读的章节").foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle(folder.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    descending.toggle()
                    PerComicPrefs.setChapterOrder(descending, for: folder.url)
                } label: {
                    Image(systemName: descending ? "arrow.up" : "arrow.down")
                }
                .accessibilityLabel(descending ? "切换到正序" : "切换到倒序")
            }
        }
        .onAppear {
            descending = PerComicPrefs.chapterOrderDescending(for: folder.url)
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await loader.load(url: folder.requestURL, client: store.makeClient())
    }
}

private struct ChapterRow: View {
    let item: WebDAVItem
    let progress: RecentEntry?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(2)
                if let progress {
                    Text(progress.progressText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if item.isDirectory { return "folder" }
        if item.isPDF { return "doc.richtext" }
        return "book.closed"
    }

    private var iconColor: Color {
        if item.isDirectory { return .accentColor }
        if item.isPDF { return .red }
        return .secondary
    }
}
