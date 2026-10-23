import SwiftUI

/// Virtual last page: shows up when the folder has a next chapter.
struct ChapterEndView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(.white.opacity(0.45))

                Text("本话看完")
                    .font(.headline)
                    .foregroundColor(.white)

                if let next = model.nextItem {
                    VStack(spacing: 4) {
                        Text("下一话")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                        Text(next.displayName)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.85))
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
                        .foregroundColor(.white.opacity(0.45))
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
                    .tint(.white.opacity(0.8))
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
    }
}
