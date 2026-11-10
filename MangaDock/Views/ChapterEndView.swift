import SwiftUI

/// Virtual last page: shows up when the folder has a next chapter.
struct ChapterEndView: View {
    @ObservedObject var model: ReaderModel
    /// 分页模式用：滑到这一页就等于「我要看下一话」，自动翻过去，
    /// 不用再点按钮。条漫模式传 false（列表末尾常驻，不能自动跳）。
    var autoAdvance: Bool = false

    @State private var didAutoAdvance = false

    var body: some View {
        ZStack {
            Color(.systemBackground)

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(.secondary.opacity(0.6))

                Text("本话看完")
                    .font(.headline)
                    .foregroundColor(.primary)

                if let next = model.nextItem {
                    VStack(spacing: 4) {
                        Text("下一话")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(next.displayName)
                            .font(.subheadline)
                            .foregroundColor(.primary.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 24)

                    Button {
                        Task { await model.advanceChapter(direction: 1) }
                    } label: {
                        Label("继续阅读", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Text("这是最后一话")
                        .font(.footnote)
                        .foregroundColor(.secondary.opacity(0.6))
                }

                if let error = model.chapterError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                if let previous = model.previousItem {
                    Button {
                        Task { await model.advanceChapter(direction: -1) }
                    } label: {
                        Label("回到上一话（\(previous.displayName)）", systemImage: "arrow.left")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary.opacity(0.7))
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .onAppear {
            guard autoAdvance, !didAutoAdvance, model.nextItem != nil else { return }
            didAutoAdvance = true
            Task { await model.advanceChapter(direction: 1) }
        }
    }
}
