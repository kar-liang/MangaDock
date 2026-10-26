import SwiftUI

/// 手动把一本漫画关联到 Bangumi 条目。
/// 自动匹配只在名字对得上时才采用，剩下这些对不上的靠这里补。
struct BangumiLinkView: View {
    let seriesName: String
    let onPick: (BangumiSubject) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [BangumiSubject] = []
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索…").foregroundColor(.secondary)
                    }
                } else if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else if results.isEmpty {
                    Text("没有结果。换个关键词试试，用中文名通常更准。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(results) { subject in
                        Button {
                            onPick(subject)
                            dismiss()
                        } label: {
                            row(subject)
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("关联到 Bangumi")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "输入漫画名")
            .onSubmit(of: .search) {
                Task { await run(keyword: query) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await run(keyword: seriesName) }
        }
    }

    private func row(_ subject: BangumiSubject) -> some View {
        HStack(spacing: 10) {
            Group {
                if let url = subject.coverURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.1)
                        }
                    }
                } else {
                    Color.secondary.opacity(0.1)
                }
            }
            .frame(width: 36, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(subject.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let date = subject.date, !date.isEmpty {
                        Text(date).font(.caption2).foregroundColor(.secondary)
                    }
                    if let score = subject.rating?.score, score > 0 {
                        Text(String(format: "★ %.1f", score))
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            Spacer()
        }
    }

    private func run(keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loading = true
        message = nil
        let found = await BangumiClient.shared.candidates(for: trimmed)
        results = found
        loading = false
        if found.isEmpty {
            message = BangumiClient.shared.shouldSkipForNow()
                ? "连不上 api.bgm.tv。检查网络，或在设置里填一个可用的接口地址。"
                : "没有找到匹配的条目。"
        }
    }
}
