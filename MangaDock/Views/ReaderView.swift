import SwiftUI

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var showBars = true
    @State private var verticalOverride: Bool? = nil
    /// Chapter picker sheet (jump anywhere in the series without leaving).
    @State private var showChapterList = false
    /// Guards the "pull past bottom → next chapter" jump against re-firing.
    @State private var chapterJumpArmed = false
    /// Stops two chapter advances from overlapping (they'd fight over `index`).
    @State private var isAdvancing = false
    /// Chapter jumps stay disabled until the reader has settled after opening —
    /// the first layout pass is exactly when the bogus overshoot shows up.
    @State private var jumpAllowedAfter = Date.distantFuture
    /// 条漫模式可用宽度，量一次传给每页算原始高度。
    @State private var pageWidth: CGFloat = 0
    /// 分页模式当前页是否处于放大状态（放大时左右点击不翻页）。
    @State private var isPageZoomed = false
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

            if showBars {
                if readerReady {
                    bars
                } else {
                    // Loading (or failed) still needs a way out — the reader used
                    // to hide every control until the chapter finished loading.
                    loadingBar
                }
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
        .sheet(isPresented: $showChapterList) {
            ReaderChapterListView(chapters: model.series,
                                  currentIndex: model.seriesIndex,
                                  progress: { store.recentEntry(for: $0.url) },
                                  onPick: { index in
                                      showChapterList = false
                                      Task { await jumpToChapter(index) }
                                  })
        }
        .onChange(of: model.index) { newValue in
            guard model.pageCount > 0 else { return }
            // 翻页后新页是 fit 状态，重置放大标志（避免残留导致新页左右点击失效）。
            isPageZoomed = false
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
                      onTapRight: handleTapRight,
                      onZoomChanged: { zoomed in
                          isPageZoomed = zoomed
                      },
                      isPageZoomed: isPageZoomed)
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
        WebtoonReaderView(model: model,
                          pageWidth: pageWidth,
                          onTap: toggleBars,
                          onPageChange: { page in
                              guard page != model.index else { return }
                              model.index = page
                              saveProgress(page: page)
                          },
                          onNextChapter: {
                              // 底部 overshoot 换章，带防抖避免重复触发。
                              guard model.nextItem != nil, !chapterJumpArmed else { return }
                              chapterJumpArmed = true
                              Task { await goNextChapter() }
                          })
            .background(Color.black)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { pageWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in pageWidth = w }
                }
            )
            .id(model.currentItem.url)
            .ignoresSafeArea()
            .onAppear {
                diag("webtoon", "appear chapter=\(model.currentItem.displayName) index=\(model.index) pages=\(model.pageCount)")
                chapterJumpArmed = false
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
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        diag("reader", "next chapter from=\(model.currentItem.displayName) index=\(model.index + 1)/\(model.pageCount)")
        saveProgress(page: max(0, model.pageCount - 1))
        resetVerticalScroll()
        _ = await model.advanceChapter(direction: 1)
    }

    /// Jumps straight to a chapter picked from the list, keeping its own saved
    /// page so "jump back to chapter 12" resumes where you stopped.
    private func jumpToChapter(_ index: Int) async {
        guard index >= 0, index < model.series.count, index != model.seriesIndex else { return }
        let target = model.series[index]
        saveProgress(page: max(0, model.index))
        chapterJumpArmed = false
        jumpAllowedAfter = Date().addingTimeInterval(0.8)

        let saved = store.recentPage(for: target.url)
        resetVerticalScroll()
        guard await model.jump(to: index, startPage: saved) else { return }
    }

    /// 换章前复位换章防抖标志。UIKit 方案里换章由 `.id(item.url)` 触发
    /// WebtoonReaderView 重建，滚动/缩放自动归零，无需手动处理。
    private func resetVerticalScroll() {
        chapterJumpArmed = false
    }

    private func goPreviousChapter() async {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        diag("reader", "prev chapter from=\(model.currentItem.displayName) index=\(model.index + 1)/\(model.pageCount)")
        saveProgress(page: max(0, model.index))
        resetVerticalScroll()
        _ = await model.advanceChapter(direction: -1)
    }

    // MARK: - Chrome (Liquid Glass on iOS 26)

    /// Minimal chrome while a chapter is loading or has failed.
    ///
    /// The back button has to work at all times — this reader hides the
    /// navigation bar, so before this existed a slow chapter download left you
    /// staring at a spinner with no way out.
    private var loadingBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                iconButton("chevron.left") { dismiss() }

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.currentItem.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(model.errorMessage == nil ? "正在加载…" : "加载失败")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer(minLength: 4)

                if model.errorMessage == nil {
                    ProgressView().tint(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()
        }
    }

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

            iconButton("list.bullet") { showChapterList = true }
                .accessibilityLabel("章节列表")
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
        jumpAllowedAfter = Date().addingTimeInterval(0.8)
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
