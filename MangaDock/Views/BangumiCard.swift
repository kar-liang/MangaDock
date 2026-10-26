import SwiftUI

/// 章节列表上方的 Bangumi 元数据卡片：封面、标题、评分、简介、标签。
struct BangumiCard: View {
    let subject: BangumiSubject

    @State private var expanded = false

    private var scoreText: String? {
        guard let score = subject.rating?.score, score > 0 else { return nil }
        return String(format: "%.1f", score)
    }

    private var ratingCount: String? {
        guard let total = subject.rating?.total, total > 0 else { return nil }
        return "\(total) 人评分"
    }

    /// 只留前几个标签，多的没地方放。
    private var topTags: [String] {
        (subject.tags ?? [])
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            .prefix(4)
            .map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                cover

                VStack(alignment: .leading, spacing: 6) {
                    Text(subject.displayTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)

                    if subject.displayTitle != subject.name {
                        Text(subject.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        if let scoreText {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                Text(scoreText)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(.orange)
                            }
                        }
                        if let ratingCount {
                            Text(ratingCount)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let date = subject.date, !date.isEmpty {
                            Text(date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let authors = subject.authors {
                        Text("作者 \(authors)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            if let summary = subject.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
            }

            if !topTags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(topTags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var cover: some View {
        Group {
            if let url = subject.coverURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 80, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            Image(systemName: "book.closed")
                .font(.system(size: 18))
                .foregroundColor(.secondary.opacity(0.5))
        }
    }
}
