import PhotosUI
import SwiftUI
import UIKit

/// Image-only cover box (2:3). Used by the grid and by list rows.
/// Long-press to swap in your own cover from the photo library.
struct CoverBox: View {
    let item: WebDAVItem
    var width: CGFloat? = nil

    @EnvironmentObject private var store: AppStore
    @State private var image: UIImage?
    @State private var attempted = false
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(width: width)
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
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contextMenu { coverMenu }
            .photosPicker(isPresented: $showPhotoPicker,
                          selection: $pickedPhoto,
                          matching: .images)
            .onChange(of: pickedPhoto) { newValue in
                guard let newValue else { return }
                Task { await applyCustomCover(newValue) }
            }
            .task(id: item.id) {
                await loadCover()
            }
    }

    @ViewBuilder
    private var coverMenu: some View {
        Button {
            showPhotoPicker = true
        } label: {
            Label("设置自定义封面", systemImage: "photo.on.rectangle")
        }

        if CoverStore.shared.hasCustomCover(for: item) {
            Button(role: .destructive) {
                CoverStore.shared.removeCustomCover(for: item)
                image = nil
                attempted = false
                Task { await loadCover() }
            } label: {
                Label("恢复默认封面", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: width == nil ? 26 : 16, weight: .light))
                    .foregroundColor(.white.opacity(0.55))
                if width == nil {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    private var iconName: String {
        if item.isDirectory { return "folder" }
        if item.isArchive { return "book.closed" }
        if item.isPDF { return "doc.richtext" }
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

    private func applyCustomCover(_ pick: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        guard let data = try? await pick.loadTransferable(type: Data.self),
              let picked = UIImage(data: data),
              let prepared = CoverStore.shared.setCustomCover(picked, for: item) else { return }
        image = prepared
    }
}

/// Grid cell: cover + title underneath.
struct CoverTile: View {
    let item: WebDAVItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverBox(item: item)
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(.primary)
        }
    }
}

enum LibraryGrid {
    static let columns = [GridItem(.adaptive(minimum: 104, maximum: 168), spacing: 14)]
}
