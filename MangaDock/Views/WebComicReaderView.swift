import SwiftUI

@MainActor
final class WebImageLoader {
    static let shared = WebImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private init() { cache.countLimit = 12 }

    func image(for url: URL, referer: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let hit = cache.object(forKey: key) { return hit }

        var request = URLRequest(url: url)
        // Many comic CDNs reject requests without a matching Referer.
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25

        guard let (data, _) = try? await ABSSession.shared.data(for: request),
              let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

/// Image view that sends a Referer header and reports its aspect ratio so the
/// scrolling layout keeps a stable height (the "jump to top" bug otherwise).
struct WebComicImage: View {
    let url: URL
    let referer: URL
    var aspect: CGFloat = 0.68
    var onAspect: ((CGFloat) -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                    Text("这张图加载失败")
                        .font(.caption2)
                }
                .foregroundColor(.white.opacity(0.5))
                .frame(height: 160)
            } else {
                ProgressView()
                    .tint(.white.opacity(0.7))
                    .frame(height: 220)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
        .task(id: url.absoluteString) {
            await load()
        }
    }

    private func load() async {
        guard image == nil else { return }
        failed = false
        guard let loaded = await WebImageLoader.shared.image(for: url, referer: referer) else {
            failed = true
            return
        }
        image = loaded
        if loaded.size.height > 0 {
            onAspect?(loaded.size.width / loaded.size.height)
        }
    }
}

// MARK: - Reader

struct WebComicReaderView: View {
    let source: WebComicSource

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var webStore = WebComicStore.shared
    @State private var pages: [URL] = []
    @State private var aspects: [Int: CGFloat] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showBar = true
    /// Highest page index that has scrolled into view this session (progress).
    @State private var furthestPage = 0

    private var base: URL? { source.url }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView("正在解析页面…")
                    .tint(.white)
                    .foregroundColor(.white)
            } else if let errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("重试") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                                WebComicImage(url: page,
                                              referer: base ?? page,
                                              aspect: aspects[index] ?? 0.68) { ratio in
                                    aspects[index] = ratio
                                }
                                .id(index)
                                .frame(maxWidth: .infinity)
                                .onAppear {
                                    if index > furthestPage { furthestPage = index }
                                }
                            }
                        }
                    }
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showBar.toggle() } }
                    .onAppear {
                        let start = min(source.lastPage, max(0, pages.count - 1))
                        proxy.scrollTo(start, anchor: .top)
                    }
                }
            }

            if showBar {
                topBar
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task { await reload() }
        .onDisappear {
            if let url = source.url, !pages.isEmpty {
                webStore.recordProgress(url: url, page: furthestPage, pageCount: pages.count)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                    Text("收起").font(.footnote.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(Color.white.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            VStack(spacing: 1) {
                Text(source.title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                if !isLoading && errorMessage == nil {
                    Text("第 \(furthestPage + 1) / \(pages.count) 页")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: 190)

            Spacer(minLength: 6)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 32)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func reload() async {
        guard let url = source.url else {
            errorMessage = "网址无效"
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        pages = []
        aspects = [:]
        do {
            let result = try await WebComicParser.parse(url)
            pages = result.pages
            isLoading = false
        } catch {
            errorMessage = NetErrorText.friendly(error)
            isLoading = false
        }
    }
}

// MARK: - Add sheet

struct WebComicAddView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WebComicStore.shared

    @State private var urlText = ""
    @State private var busy = false
    @State private var message: String?
    @State private var parsed: WebComicParser.Result?
    @State private var parsedIndex: WebComicParser.IndexResult?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/...", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("漫画网址")
                } footer: {
                    Text("粘贴单话图片页或目录页。\n单话：解析页面里的图片直接读。\n目录页：识别各话链接，生成章节列表。\n受限：JS 动态加载、需登录、Cloudflare 验证的站解析不到。")
                }

                Section {
                    Button {
                        Task { await parseSingle() }
                    } label: {
                        HStack {
                            Text(busy ? "解析中…" : "解析单话图片")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy || urlText.isEmpty)

                    Button {
                        Task { await parseIndex() }
                    } label: {
                        HStack {
                            Text(busy ? "解析中…" : "解析目录（多话）")
                            Spacer()
                        }
                    }
                    .disabled(busy || urlText.isEmpty)

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(parsed == nil && parsedIndex == nil ? .red : .secondary)
                    }

                    if let parsed {
                        Button("加入书架并阅读（\(parsed.pages.count) 张）") {
                            saveSingle(parsed)
                        }
                    }

                    if let parsedIndex {
                        Button("加入书架（\(parsedIndex.chapters.count) 话）") {
                            saveIndex(parsedIndex)
                        }
                    }
                }
            }
            .navigationTitle("添加在线漫画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func parseSingle() async {
        guard let url = WebComicParser.normalize(urlText) else {
            message = "网址格式不对"
            parsed = nil
            parsedIndex = nil
            return
        }
        busy = true
        message = nil
        parsed = nil
        parsedIndex = nil
        do {
            let result = try await WebComicParser.parse(url)
            parsed = result
            message = "解析到 \(result.pages.count) 张图片"
        } catch {
            message = NetErrorText.friendly(error)
        }
        busy = false
    }

    private func parseIndex() async {
        guard let url = WebComicParser.normalize(urlText) else {
            message = "网址格式不对"
            parsed = nil
            parsedIndex = nil
            return
        }
        busy = true
        message = nil
        parsed = nil
        parsedIndex = nil
        do {
            let result = try await WebComicParser.parseIndex(url)
            parsedIndex = result
            message = "解析到 \(result.chapters.count) 话"
        } catch {
            message = NetErrorText.friendly(error)
        }
        busy = false
    }

    private func saveSingle(_ result: WebComicParser.Result) {
        guard let url = WebComicParser.normalize(urlText) else { return }
        store.add(WebComicSource(urlString: url.absoluteString,
                                 title: result.title,
                                 coverString: result.pages.first?.absoluteString,
                                 addedAt: Date()))
        dismiss()
    }

    private func saveIndex(_ result: WebComicParser.IndexResult) {
        guard let url = WebComicParser.normalize(urlText) else { return }
        store.add(WebComicSource(urlString: url.absoluteString,
                                 title: result.title,
                                 coverString: result.cover?.absoluteString,
                                 addedAt: Date(),
                                 chapters: result.chapters))
        dismiss()
    }
}

// MARK: - Chapter list for a multi-chapter online title

struct WebComicChapterListView: View {
    let source: WebComicSource

    @Environment(\.dismiss) private var dismiss
    @State private var reading: WebComicChapter?

    var body: some View {
        List {
            Section {
                ForEach(source.chapters) { chapter in
                    Button {
                        reading = chapter
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed")
                                .foregroundColor(.secondary)
                                .frame(width: 22)
                            Text(chapter.title)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("章节（\(source.chapters.count)）")
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $reading) { chapter in
            WebComicReaderView(source: WebComicSource(
                urlString: chapter.urlString,
                title: chapter.title,
                coverString: nil,
                addedAt: source.addedAt,
                chapters: []))
        }
    }
}
