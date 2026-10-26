import SwiftUI

/// Chapter list for one series. Reached by tapping a shelf entry; reading from
/// here still gets continuous chapter switching, because the reader rebuilds its
/// series from this folder's children.
struct SeriesView: View {
    let folder: WebDAVItem

    @EnvironmentObject private var store: AppStore
    @StateObject private var loader = FolderLoader()
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var reads = ReadStateStore.shared
    @State private var descending = false

    // Bangumi 元数据：章节列表上方的卡片
    @State private var bangumi: BangumiSubject?
    @State private var bangumiCharacters: [BangumiCharacter] = []
    @State private var bangumiLoading = false
    @State private var bangumiTried = false
    @State private var showBangumiPicker = false

    private var chapters: [WebDAVItem] {
        let items = loader.items.filter { $0.isDirectory || $0.isArchive || $0.isPDF }
        return descending ? items.reversed() : items
    }

    private var imageCount: Int {
        loader.items.filter { !$0.isDirectory && $0.isImage }.count
    }

    /// Chapters of this series that are already on disk.
    private var downloadedCount: Int {
        chapters.filter { downloads.isDownloaded($0.url) }.count
    }

    private var notDownloaded: [WebDAVItem] {
        chapters.filter { !downloads.isDownloaded($0.url) }
    }

    /// True while any chapter of this series is queued or in flight.
    private var downloadingThisSeries: Bool {
        let keys = Set(chapters.map { $0.url.absoluteString })
        return downloads.queue.contains { keys.contains($0) }
    }

    /// Fraction of the chapter currently in flight.
    private var currentFraction: Double {
        guard let key = downloads.queue.first else { return 0 }
        return downloads.progress[key] ?? 0
    }

    /// How many chapters are finished (manual mark or reached the last page).
    private var readCount: Int {
        chapters.filter { isRead($0) }.count
    }

    /// Manual mark wins; otherwise "read to the last page" counts.
    private func isRead(_ chapter: WebDAVItem) -> Bool {
        reads.isRead(chapter.url, progress: store.recentEntry(for: chapter.url))
    }

    private func toggleRead(_ chapter: WebDAVItem) {
        let now = isRead(chapter)
        reads.setRead(!now, for: chapter.url)
        if now {
            // Marking unread means "I want to start over": drop the saved page
            // too, otherwise the reader would still resume at the old position.
            if let entry = store.recentEntry(for: chapter.url) {
                store.removeRecent(entry)
            }
        }
        diag("read", "mark read=\(!now) name=\(chapter.name)")
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
                offlineSection
            } else {
                bangumiSection
                charactersSection
                downloadStatusSection

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
                            chapterRow(chapter)
                        }
                    } header: {
                        Text("章节（\(chapters.count)）")
                    } footer: {
                        Text("\(readCount)/\(chapters.count) 章已读。右滑左滑都能操作：右滑标已读/未读，左滑下载。")
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                downloadMenu
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
        .task { await loadBangumi() }
        .sheet(isPresented: $showBangumiPicker) {
            BangumiLinkView(seriesName: folder.displayName) { picked in
                BangumiClient.shared.link(seriesURL: folder.url.absoluteString,
                                          subjectID: picked.id)
                bangumi = picked
                bangumiTried = true
                // 换了条目，角色表得跟着换
                bangumiCharacters = []
                Task {
                    bangumiCharacters = await BangumiClient.shared.characters(subjectID: picked.id)
                }
            }
        }
        .refreshable { await reload() }
    }

    /// 章节列表上方的 Bangumi 卡片。匹配不到就静默降级成一个手动关联入口，
    /// 不要挡住阅读。
    @ViewBuilder
    private var bangumiSection: some View {
        if let bangumi {
            Section {
                BangumiCard(subject: bangumi)
            } footer: {
                HStack {
                    Text("元数据来自 Bangumi")
                    Spacer()
                    Button("更换") { showBangumiPicker = true }
                        .font(.footnote)
                }
            }
        } else if bangumiLoading {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在匹配 Bangumi…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } else if bangumiTried && BangumiClient.shared.isEnabled {
            Section {
                Button {
                    showBangumiPicker = true
                } label: {
                    Label("关联 Bangumi 条目", systemImage: "link")
                }
            } footer: {
                Text("没自动对上这本书。可以手动搜一下，不关联也不影响阅读。")
            }
        }
    }

    /// 「角色」一栏。数据来自 /subjects/{id}/characters。
    @ViewBuilder
    private var charactersSection: some View {
        if !bangumiCharacters.isEmpty {
            Section {
                BangumiCharactersRow(characters: bangumiCharacters)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("角色（\(bangumiCharacters.count)）")
            }
        }
    }

    private func loadBangumi() async {
        guard BangumiClient.shared.isEnabled, !bangumiTried else { return }
        // 这条线路连不上时别干等，直接收起
        if BangumiClient.shared.shouldSkipForNow() {
            bangumiTried = true
            return
        }
        bangumiLoading = true
        bangumi = await BangumiClient.shared.subject(
            forSeriesNamed: folder.displayName,
            seriesURL: folder.url.absoluteString
        )
        bangumiLoading = false
        bangumiTried = true

        if let subject = bangumi {
            bangumiCharacters = await BangumiClient.shared.characters(subjectID: subject.id)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func chapterRow(_ chapter: WebDAVItem) -> some View {
        let state = downloads.state(for: chapter.url)
        let read = isRead(chapter)

        NavigationLink(value: NavTarget.comic(chapter)) {
            ChapterRow(item: chapter,
                       progress: store.recentEntry(for: chapter.url),
                       download: state,
                       isRead: read)
        }
        .swipeActions(edge: .leading) {
            Button {
                toggleRead(chapter)
            } label: {
                Label(read ? "标为未读" : "标为已读",
                      systemImage: read ? "circle" : "checkmark.circle")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if state == .done {
                Button(role: .destructive) {
                    downloads.remove(chapter.url)
                } label: {
                    Label("删除下载", systemImage: "trash")
                }
            } else if state == .none {
                Button {
                    enqueue([chapter])
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            } else {
                Button {
                    downloads.cancel(chapter.url)
                } label: {
                    Label("取消下载", systemImage: "xmark.circle")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            Button {
                toggleRead(chapter)
            } label: {
                Label(read ? "标为未读" : "标为已读",
                      systemImage: read ? "circle" : "checkmark.circle")
            }

            if state == .done {
                Button(role: .destructive) {
                    downloads.remove(chapter.url)
                } label: {
                    Label("删除下载", systemImage: "trash")
                }
            } else if state == .none {
                Button {
                    enqueue([chapter])
                } label: {
                    Label("下载这一章", systemImage: "arrow.down.circle")
                }
            } else {
                Button {
                    downloads.cancel(chapter.url)
                } label: {
                    Label("取消下载", systemImage: "xmark.circle")
                }
            }
        }
    }

    // MARK: - Download status

    /// Offline fallback: when the folder can't be listed, still offer whatever
    /// was downloaded from it. Without this a connection failure would lock
    /// you out of chapters that are sitting on the phone.
    @ViewBuilder
    private var offlineSection: some View {
        let saved = downloads.downloadedChapters(inFolder: folder.url)
        if !saved.isEmpty {
            Section {
                ForEach(saved) { rec in
                    if let item = rec.item {
                        NavigationLink(value: NavTarget.comic(item)) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rec.title).lineLimit(2)
                                    Text("\(rec.pageCount) 页 · \(rec.formattedSize)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let url = rec.sourceURL { downloads.remove(url) }
                            } label: {
                                Label("删除下载", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("已下载（\(saved.count)）")
            } footer: {
                Text("连不上服务器时，这些存在手机上的章节照样能看。")
            }
        }
    }

    @ViewBuilder
    private var downloadStatusSection: some View {
        if downloadingThisSeries {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(downloads.activeTitle ?? "准备中…")
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(currentFraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    if downloads.queue.count > 1 {
                        Text("队列还有 \(downloads.queue.count - 1) 章")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: currentFraction)
                        .progressViewStyle(.linear)
                }
                .padding(.vertical, 2)

                Button("取消下载", role: .destructive) {
                    downloads.cancelAll()
                }
            } header: {
                Text("正在下载")
            }
        } else if let error = downloads.lastError {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var downloadMenu: some View {
        Menu {
            Button {
                enqueue(notDownloaded)
            } label: {
                Label("下载全部章节（\(notDownloaded.count)）",
                      systemImage: "arrow.down.circle")
            }
            .disabled(notDownloaded.isEmpty)

            if downloads.isBusy {
                Button(role: .destructive) {
                    downloads.cancelAll()
                } label: {
                    Label("取消下载", systemImage: "xmark.circle")
                }
            }

            if downloadedCount > 0 {
                Button(role: .destructive) {
                    downloadedChapters.forEach { downloads.remove($0.url) }
                } label: {
                    Label("删除已下载（\(downloadedCount) 章）", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: downloadedCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .disabled(chapters.isEmpty)
        .accessibilityLabel("下载")
    }

    private var downloadedChapters: [WebDAVItem] {
        chapters.filter { downloads.isDownloaded($0.url) }
    }

    // MARK: - Actions

    private func enqueue(_ items: [WebDAVItem]) {
        guard !items.isEmpty, let client = store.makeClient() else { return }
        downloads.enqueue(items, client: client)
    }

    private func reload() async {
        await loader.load(url: folder.requestURL, client: store.makeClient())
    }
}

private struct ChapterRow: View {
    let item: WebDAVItem
    let progress: RecentEntry?
    let download: DownloadState
    let isRead: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isRead ? "checkmark.circle" : iconName)
                .foregroundColor(isRead ? Color.secondary : iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(2)
                    .foregroundColor(isRead ? .secondary : .primary)
                if let progress {
                    Text(progress.progressText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            downloadBadge
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var downloadBadge: some View {
        switch download {
        case .none:
            EmptyView()
        case .done:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.green)
                .accessibilityLabel("已下载")
        case .queued:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .accessibilityLabel("等待下载")
        case .downloading(let value):
            Text("\(Int(value * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
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
