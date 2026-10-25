import SwiftUI

struct ComicPageView: View {
    @ObservedObject var model: ReaderModel
    let index: Int
    /// Vertical (webtoon) mode taps the page itself to toggle the chrome,
    /// because an overlay would block scrolling.
    var onTap: (() -> Void)? = nil
    /// Vertical mode needs a height that doesn't change after the image arrives,
    /// otherwise reflow above the viewport yanks the scroll offset around.
    var stableHeight: Bool = false

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedGeneration = 0

    var body: some View {
        Group {
            if stableHeight {
                Color.clear
                    .aspectRatio(model.aspect(for: index), contentMode: .fit)
                    .overlay { pageContent }
                    .clipped()
            } else {
                ZStack {
                    Color.black
                    pageContent
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .task(id: "\(index)-\(model.enhanceGeneration)") {
            // Only drop the decoded image when the enhance mode actually changed.
            if loadedGeneration != model.enhanceGeneration {
                image = nil
            }
            loadedGeneration = model.enhanceGeneration
            await load()
        }
        .onAppear {
            // Works for both paging and webtoon scrolling: whenever a page becomes
            // visible, start rendering the ones after it in the background.
            model.prewarm(from: index + 1)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.6))
                Text("第 \(index + 1) 页加载失败")
                    .foregroundColor(.white.opacity(0.8))
                Button("重试") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
        }
    }

    private func load() async {
        guard image == nil else { return }
        failed = false
        if let loaded = await model.image(at: index) {
            image = loaded
        } else {
            failed = true
        }
    }
}
