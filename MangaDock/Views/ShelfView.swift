import SwiftUI

/// 书架 tab: only what you explicitly added (WebDAV items) plus any online
/// comic pages added by URL.
struct ShelfView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var webComics = WebComicStore.shared

    @State private var mode: LayoutMode = .grid
    @State private var showAddWebComic = false
    @State private var reading: WebComicSource?
    @State private var showingChapters: WebComicSource?

    private var isTotallyEmpty: Bool {
        shelf.entries.isEmpty && webComics.sources.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isTotallyEmpty {
                    emptyState
                } else if mode == .grid {
                    gridContent
                } else {
                    listContent
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: NavTarget.privateShelf) {
                        Image(systemName: "lock")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddWebComic = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .libraryNavigation()
            .onAppear { mode = LayoutPreference.shared.shelfMode }
            .sheet(isPresented: $showAddWebComic) {
                WebComicAddView()
            }
            .fullScreenCover(item: $reading) { source in
                WebComicReaderView(source: source)
            }
            .navigationDestination(item: $showingChapters) { source in
                WebComicChapterListView(source: source)
            }
        }
    }

    private func open(_ source: WebComicSource) {
        if source.isSeries {
            showingChapters = source
        } else {
            reading = source
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundColor(.secondary)
            Text("书架还是空的")
                .font(.headline)
            Text("去「文件」标签找到漫画，长按选「加入书架」。\n也可以点右上角 ＋ 粘贴一个漫画网页地址，在线解析阅读。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Button("添加在线漫画") { showAddWebComic = true }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var gridContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !webComics.sources.isEmpty {
                    Text("在线漫画")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: LibraryGrid.columns, spacing: 16) {
                        ForEach(webComics.sources) { source in
                            Button {
                                open(source)
                            } label: {
                                webComicTile(source)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    webComics.remove(source)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !shelf.entries.isEmpty {
                    if !webComics.sources.isEmpty {
                        Text("WebDAV")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                    }

                    LazyVGrid(columns: LibraryGrid.columns, spacing: 16) {
                        ForEach(shelf.entries) { entry in
                            if let item = entry.item, let target = target(for: item) {
                                NavigationLink(value: target) {
                                    CoverTile(item: item, shelfAction: .toggle)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func webComicTile(_ source: WebComicSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(0.72, contentMode: .fit)
                .overlay {
                    if let cover = source.cover, let base = source.url {
                        WebComicImage(url: cover, referer: base, aspect: 0.72)
                    } else {
                        ZStack {
                            Color(white: 0.22)
                            Image(systemName: "globe")
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if source.hasProgress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.black.opacity(0.5)
                                Color.orange
                                    .frame(width: geo.size.width * progressFraction(source))
                            }
                        }
                        .frame(height: 3)
                        .clipShape(Capsule())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(source.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)
            Text(source.hasProgress ? source.progressText : (source.url?.host ?? ""))
                .font(.caption2)
                .foregroundColor(source.hasProgress ? .orange : .secondary)
                .lineLimit(1)
        }
    }

    private func progressFraction(_ source: WebComicSource) -> CGFloat {
        guard source.pageCount > 0 else { return 0 }
        return min(1, max(0, CGFloat(source.lastPage + 1) / CGFloat(source.pageCount)))
    }

    // MARK: - List

    private var listContent: some View {
        List {
            if !webComics.sources.isEmpty {
                Section("在线漫画") {
                    ForEach(webComics.sources) { source in
                        Button {
                            open(source)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: source.isSeries ? "books.vertical" : "globe")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title).lineLimit(2)
                                    Text(source.isSeries ? "\(source.chapters.count) 话" : (source.url?.host ?? ""))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) where index < webComics.sources.count {
                            webComics.remove(webComics.sources[index])
                        }
                    }
                }
            }

            Section {
                ForEach(shelf.entries) { entry in
                    if let item = entry.item, let target = target(for: item) {
                        NavigationLink(value: target) {
                            ItemRow(item: item)
                        }
                        .contextMenu { ShelfMenu(item: item) }
                    }
                }
                .onDelete { shelf.remove(at: $0) }
            }
        }
    }

    /// A folder opens the chapter list; a single file goes straight to the reader.
    private func target(for item: WebDAVItem) -> NavTarget? {
        if item.isDirectory { return .series(item) }
        if item.isArchive || item.isPDF { return .comic(item) }
        return nil
    }
}
