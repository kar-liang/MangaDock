import SwiftUI

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var showBars = true
    @State private var verticalOverride: Bool? = nil
    /// Guards the "pull past bottom → next chapter" jump against re-firing.
    @State private var chapterJumpArmed = false
    /// Tracks the top visible page in webtoon mode — the real reading progress
    /// there, since `model.index` only moves in paged mode.
    @State private var verticalPageID: Int?
    @AppStorage("mangadock.readerMode") private var defaultReaderMode = ReaderMode.paged.rawValue

    init(item: WebDAVItem) {
        _model = StateObject(wrappedValue: ReaderModel(item: item))
    }

    /// Settings decides the opening mode; the toolbar toggle only overrides it
    /// for the chapter you're currently reading.
    private var verticalMode: Bool {
        verticalOverride ?? (defaultReaderMode == ReaderMode.vertical.rawValue)
    }

    private func toggleVerticalMode() {
        verticalOverride = !verticalMode
    }

    private var readerReady: Bool {
        !model.isLoading && model.errorMessage == nil && model.pageCount > 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content

            if showBars && readerReady {
                bars
            }
        }
        // A comic reader stays dark no matter the app theme — glass and text here
        // must not follow a light color scheme.
        .environment(\.colorScheme, .dark)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showBars)
        .task { await reload() }
        .onChange(of: model.index) { newValue in
            guard model.pageCount > 0 else { return }
            saveProgress(page: min(newValue, model.pageCount - 1))
            model.prewarm(from: newValue + 1)
            model.preloadNextChapterIfNeeded()
        }
        .onDisappear {
            guard model.pageCount > 0 else { return }
            saveProgress(page: min(model.index, model.pageCount - 1))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            loadingView
        } else if let error = model.errorMessage {
            errorView(error)
        } else if model.pageCount == 0 {
            errorView("这个文件里没有可显示的页面")
        } else if verticalMode {
            verticalReader
        } else {
            PagePager(model: model,
                      index: $model.index,
                      onTapLeft: handleTapLeft,
                      onTapCenter: toggleBars,
                      onTapRight: handleTapRight)
                .ignoresSafeArea()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            if let progress = model.downloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text("下载中 \(Int(progress * 100))%")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
            } else {
                ProgressView()
                Text(model.statusText)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .tint(.white)
        .foregroundColor(.white)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(.orange)
            Text("打不开这个文件")
                .font(.headline)
                .foregroundColor(.white)
            Text(message)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("重试") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
                Button("返回") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(.top, 4)
        }
    }

    private var verticalReader: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(0..<model.pageCount, id: \.self) { position in
                    ComicPageView(model: model, index: position,
                                  onTap: toggleBars, stableHeight: true)
                        .id(position)
                        .frame(maxWidth: .infinity)
                }
                if model.nextItem != nil {
                    ChapterEndView(model: model)
                        .frame(minHeight: 300)
                }
            }
            .padding(.vertical, 6)
            .scrollTargetLayout()
        }
        .background(Color.black)
        .scrollPosition(id: $verticalPageID, anchor: .top)
        .onAppear {
            // Jump to the saved page; id-based positioning needs the ID set once.
            if verticalPageID == nil {
                verticalPageID = model.index
            }
        }
        .onChange(of: verticalPageID) { _, newID in
            guard let page = newID, page != model.index else { return }
            model.index = page
            saveProgress(page: page)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // How far past the content bottom the user has dragged (rubber-band
            // overshoot). Negative/zero while inside normal scroll range.
            geometry.contentOffset.y + geometry.containerSize.height
                - geometry.contentInsets.bottom - geometry.contentSize.height
        } action: { _, overshoot in
            handleBottomOvershoot(overshoot)
        }
    }

    /// At the bottom, pulling further down (rubber band) by ~30pt jumps to the
    /// next chapter — no need to aim for the "下一话" button.
    private func handleBottomOvershoot(_ overshoot: CGFloat) {
        guard model.nextItem != nil else { return }
        if overshoot > 30 {
            guard !chapterJumpArmed else { return }
            chapterJumpArmed = true
            Task { await goNextChapter() }
        } else if overshoot < 5 {
            chapterJumpArmed = false  // back inside the list: re-arm
        }
    }

    // MARK: - Tap handling

    /// While the chrome is hidden, *any* tap brings it back — you can never get
    /// stuck with an invisible toolbar.
    private func handleTapLeft() {
        if showBars { step(-1) } else { revealBars() }
    }

    private func handleTapRight() {
        if showBars { step(1) } else { revealBars() }
    }

    private func toggleBars() {
        withAnimation(.easeInOut(duration: 0.15)) { showBars.toggle() }
    }

    private func revealBars() {
        withAnimation(.easeInOut(duration: 0.15)) { showBars = true }
    }

    private func step(_ delta: Int) {
        if model.step(delta) == .loadNextChapter {
            Task { await goNextChapter() }
        }
    }

    private func goNextChapter() async {
        saveProgress(page: max(0, model.pageCount - 1))
        _ = await model.advanceChapter(direction: 1)
    }

    private func goPreviousChapter() async {
        saveProgress(page: max(0, model.index))
        _ = await model.advanceChapter(direction: -1)
    }

    // MARK: - Chrome (Liquid Glass on iOS 26)

    private var bars: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Spacer()

            HStack {
                Spacer()
                bottomBar
                Spacer()
            }
            .padding(.bottom, 10)
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            iconButton("chevron.left") { dismiss() }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.currentItem.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(pageLabel)
                        .font(.caption2)
                    if !model.chapterLabel.isEmpty {
                        Text(model.chapterLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    if model.enhance {
                        Text(enhanceBadgeText)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange, in: Capsule())
                    }
                }
                .foregroundColor(.white.opacity(0.65))
            }

            Spacer(minLength: 4)

            enhanceMenuButton()
            iconButton(verticalMode ? "rectangle.grid.1x2" : "scroll") { toggleVerticalMode() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 22)
    }

    private var pageLabel: String {
        if model.isOnChapterEndCard {
            return "本话看完"
        }
        return "第 \(model.index + 1) / \(model.pageCount) 页"
    }

    /// Paged mode needs five controls; vertical scrolling only ever needs chapter
    /// jumps and a way to hide the chrome. Keep the pill hugging its content.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            if verticalMode {
                chapterButton("chevron.up.2", enabled: model.previousItem != nil) {
                    Task { await goPreviousChapter() }
                }
                iconButton("eye.slash") { hideBars() }
                chapterButton("chevron.down.2", enabled: model.nextItem != nil) {
                    Task { await goNextChapter() }
                }
            } else {
                pagingButton("backward.end") { step(-10) }
                pagingButton("chevron.left") { step(-1) }
                iconButton("eye.slash") { hideBars() }
                pagingButton("chevron.right") { step(1) }
                pagingButton("forward.end") { step(10) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 22)
    }

    private func hideBars() {
        withAnimation(.easeInOut(duration: 0.15)) { showBars = false }
    }

    private func iconButton(_ name: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 34)
                .foregroundColor(active ? .orange : .white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// ✨ button as a three-state menu: off / AI 2x / AI 4x. Falls back to the
    /// plain toggle when no AI model is bundled.
    private func enhanceMenuButton() -> some View {
        let label = Image(systemName: "wand.and.stars")
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 36, height: 34)
            .foregroundColor(model.enhance ? .orange : .white)
            .contentShape(Rectangle())

        return Group {
            if ImageEnhancer.hasAIModel {
                Menu {
                    Button {
                        model.setEnhance(on: false)
                    } label: {
                        Label("关闭增强", systemImage: model.enhance ? "circle" : "checkmark.circle.fill")
                    }
                    Button {
                        model.setEnhance(on: true, scale: .two)
                    } label: {
                        Label("AI 超分 2 倍", systemImage: isEnhance(.two) ? "checkmark.circle.fill" : "circle")
                    }
                    Button {
                        model.setEnhance(on: true, scale: .four)
                    } label: {
                        Label("AI 超分 4 倍", systemImage: isEnhance(.four) ? "checkmark.circle.fill" : "circle")
                    }
                } label: { label }
            } else {
                Button { model.toggleEnhance() } label: { label }
                    .buttonStyle(.plain)
            }
        }
    }

    private func isEnhance(_ scale: AIEnhancer.Scale) -> Bool {
        model.enhance && model.aiScale == scale.rawValue
    }

    private var enhanceBadgeText: String {
        guard ImageEnhancer.hasAIModel else { return "增强" }
        return "AI \(model.aiScale)x"
    }

    private func pagingButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 34)
                .foregroundColor(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chapterButton(_ name: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 34)
                .foregroundColor(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    // MARK: - Loading

    private func reload() async {
        if model.currentItem.url.isFileURL {
            await model.startLocal(startPage: store.recentPage(for: model.currentItem.url))
            return
        }
        guard let client = store.makeClient() else {
            model.errorMessage = "还没有配置服务器"
            model.isLoading = false
            return
        }
        await model.start(client: client, startPage: store.recentPage(for: model.currentItem.url))
    }

    private func saveProgress(page: Int) {
        store.recordPage(url: model.currentItem.url,
                         name: model.currentItem.displayName,
                         page: page,
                         pageCount: model.pageCount,
                         isFolder: model.currentItem.isDirectory)
    }
}
