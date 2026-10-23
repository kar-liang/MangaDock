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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content

            if showBars, !model.isLoading, model.errorMessage == nil {
                bars
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!showBars)
        .task {
            await reload()
        }
        .onChange(of: model.index) { newValue in
            guard model.pageCount > 0 else { return }
            store.recordPage(url: item.url, name: item.name,
                             page: newValue, pageCount: model.pageCount)
        }
        .onDisappear {
            guard model.pageCount > 0 else { return }
            store.recordPage(url: item.url, name: item.name,
                             page: model.index, pageCount: model.pageCount)
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
            ZStack {
                PagePager(model: model, index: $model.index)
                    .ignoresSafeArea()
                tapZones
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            if let progress = model.downloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                    .tint(.white)
                Text("下载中 \(Int(progress * 100))%")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
                Text(model.statusText)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
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
                    ComicPageView(model: model, index: position)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color.black)
    }

    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.step(-1) }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showBars.toggle()
                    }
                }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.step(1) }
        }
    }

    // MARK: - Bars

    private var bars: some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("第 \(model.index + 1) / \(model.pageCount) 页")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.65))
                }

                Spacer()

                Button {
                    verticalMode.toggle()
                } label: {
                    Image(systemName: verticalMode ? "rectangle.grid.1x2" : "scroll")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .background(
                LinearGradient(colors: [Color.black.opacity(0.8), Color.black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            )

            Spacer()

            HStack(spacing: 24) {
                Button { model.step(-10) } label: {
                    Image(systemName: "gobackward.10").foregroundColor(.white)
                }
                Button { model.step(-1) } label: {
                    Image(systemName: "chevron.left.circle").foregroundColor(.white)
                }
                Button {
                    withAnimation { showBars = false }
                } label: {
                    Image(systemName: "eye.slash").foregroundColor(.white)
                }
                Button { model.step(1) } label: {
                    Image(systemName: "chevron.right.circle").foregroundColor(.white)
                }
                Button { model.step(10) } label: {
                    Image(systemName: "goforward.10").foregroundColor(.white)
                }
            }
            .font(.system(size: 22))
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .transition(.opacity)
    }

    private func reload() async {
        guard let client = store.makeClient() else {
            model.errorMessage = "还没有配置服务器"
            model.isLoading = false
            return
        }
        await model.load(client: client, startPage: store.recentPage(for: item.url))
    }
}
