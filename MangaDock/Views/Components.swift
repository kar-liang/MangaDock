import SwiftUI

struct ItemRow: View {
    let item: WebDAVItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 17))
                .foregroundColor(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                if !item.isDirectory {
                    Text(sizeText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    private var iconName: String {
        if item.isDirectory { return "folder.fill" }
        if item.isArchive { return "book.closed.fill" }
        if item.isPDF { return "doc.richtext.fill" }
        if item.isImage { return "photo" }
        return "doc"
    }

    private var iconColor: Color {
        if item.isDirectory { return .accentColor }
        if item.isArchive { return .orange }
        if item.isPDF { return .red }
        return .secondary
    }

    private var sizeText: String {
        guard item.size > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: item.size)
    }
}

enum ItemTile {
    /// Directories navigate; archives, PDFs and image folders open the reader.
    static func target(for item: WebDAVItem) -> NavTarget? {
        if item.isDirectory { return .folder(item) }
        if item.isArchive || item.isPDF { return .comic(item) }
        return nil
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(.orange)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
