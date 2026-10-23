import SwiftUI

struct ReaderView: View {
    let item: WebDAVItem

    @EnvironmentObject private var store: AppStore
    @StateObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    @State private var showBars = true
    @State private var verticalMode = false

    init(item: WebDAVItem) {
        self.item = item
        _model = StateObject(wrappedValue: ReaderModel(item: item))
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
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showBars)
        .task { await reload() }
        .onChange(of: model.index) { newValue in
            guard model.pageCount > 0 else { return }
            saveProgress(page: newValue)
        }
        .onDisappear {
            guard model.pageCount > 0 else { return }
            saveProgress(page: model.index)
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
                    ComicPageView(model: model, index: position, onTap: toggleBars)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color.black)
    }

    // MARK: - Tap handling

    /// While the chrome is hidden, *any* tap brings it back — you can never get
    /// stuck with an invisible toolbar.
    private func handleTapLeft() {
        if showBars { model.step(-1) } else { revealBars() }
    }

    private func handleTapRight() {
        if showBars { model.step(1) } else { revealBars() }
    }

    private func toggleBars() {
        withAnimation(.easeInOut(duration: 0.15)) { showBars.toggle() }
    }

    private func revealBars() {
        withAnimation(.easeInOut(duration: 0.15)) { showBars = true }
    }

    // MARK: - Chrome (Liquid Glass on iOS 26)

    private var bars: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Spacer()

            bottomBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            iconButton("chevron.left") { dismiss() }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(verticalMode
                         ? "共 \(model.pageCount) 页"
                         : "第 \(model.index + 1) / \(model.pageCount) 页")
                        .font(.caption2)
                    if model.enhance {
                        Text("增强")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange, in: Capsule())
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            iconButton("wand.and.stars", active: model.enhance) { model.toggleEnhance() }
            iconButton(verticalMode ? "rectangle.grid.1x2" : "scroll") { verticalMode.toggle() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 22)
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            pagingButton("gobackward.10") { model.step(-10) }
            pagingButton("chevron.left") { model.step(-1) }
            iconButton("eye.slash") {
                withAnimation(.easeInOut(duration: 0.15)) { showBars = false }
            }
            pagingButton("chevron.right") { model.step(1) }
            pagingButton("goforward.10") { model.step(10) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 24)
    }

    private func iconButton(_ name: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 34)
                .foregroundColor(active ? .orange : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pagingButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundColor(.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(verticalMode)
        .opacity(verticalMode ? 0.3 : 1)
    }

    // MARK: - Loading

    private func reload() async {
        guard let client = store.makeClient() else {
            model.errorMessage = "还没有配置服务器"
            model.isLoading = false
            return
        }
        await model.load(client: client, startPage: store.recentPage(for: item.url))
    }

    private func saveProgress(page: Int) {
        store.recordPage(url: item.url,
                         name: item.name,
                         page: page,
                         pageCount: model.pageCount,
                         isFolder: item.isDirectory)
    }
}
