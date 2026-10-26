import SwiftUI

/// Chapter picker shown from inside the reader, so you can jump to any chapter
/// of the series without backing out to the shelf.
struct ReaderChapterListView: View {
    let chapters: [WebDAVItem]
    let currentIndex: Int
    let progress: (WebDAVItem) -> RecentEntry?
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reads = ReadStateStore.shared
    @State private var query = ""

    private struct Row: Identifiable {
        let index: Int
        let item: WebDAVItem
        var id: String { item.id }
    }

    private var rows: [Row] {
        let all = chapters.enumerated().map { Row(index: $0.offset, item: $0.element) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        // Typing "770" should find 第770话 even though the name has other words.
        return all.filter { $0.item.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text("没有匹配的章节").foregroundColor(.secondary)
                } else {
                    ForEach(rows) { row in
                        Button {
                            onPick(row.index)
                        } label: {
                            chapterRow(row)
                        }
                        .tint(.primary)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "输入话号或标题")
            .navigationTitle("章节（\(chapters.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func chapterRow(_ row: Row) -> some View {
        let entry = progress(row.item)
        let isCurrent = row.index == currentIndex
        let isRead = reads.isRead(row.item.url, progress: entry)

        return HStack(spacing: 10) {
            Text("\(row.index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.displayName)
                    .lineLimit(1)
                    .foregroundColor(isCurrent ? .accentColor : (isRead ? .secondary : .primary))
                if let entry {
                    Text(entry.progressText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            } else if isRead {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
