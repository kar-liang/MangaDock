import SwiftUI

/// Grid cell: 2:3 cover with title underneath.
struct CoverTile: View {
    let item: WebDAVItem

    @EnvironmentObject private var store: AppStore
    @State private var image: UIImage?
    @State private var attempted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(.primary)
        }
        .task(id: item.id) {
            await loadCover()
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.white.opacity(0.55))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var iconName: String {
        if item.isDirectory { return "folder" }
        if item.isArchive { return "book.closed" }
        if item.isImage { return "photo" }
        return "doc"
    }

    private var subtitle: String {
        if item.isDirectory { return "文件夹" }
        guard item.size > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: item.size)
    }

    private func loadCover() async {
        if let cached = CoverStore.shared.image(for: item) {
            image = cached
            return
        }
        guard !attempted, let client = store.makeClient() else { return }
        attempted = true
        await CoverStore.shared.load(item, client: client)
        image = CoverStore.shared.image(for: item)
    }
}

enum LibraryGrid {
    static let columns = [GridItem(.adaptive(minimum: 104, maximum: 168), spacing: 14)]
}
