import SwiftUI

struct ComicPageView: View {
    @ObservedObject var model: ReaderModel
    let index: Int
    /// Vertical (webtoon) mode taps the page itself to toggle the chrome,
    /// because an overlay would block scrolling. Nil in paged mode, where
    /// PagePager's gesture recogniser handles taps.
    var onTap: (() -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black

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
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .task(id: index) {
            await load()
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
