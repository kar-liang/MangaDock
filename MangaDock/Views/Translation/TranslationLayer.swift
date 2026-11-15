import SwiftUI

/// 把 `TranslationCanvasView` 包成 SwiftUI 视图。
///
/// `blocks` 里的 rect 是归一化的，这里按画布实际尺寸换算成 point。
struct TranslationLayer: UIViewRepresentable {
    var blocks: [TextBlock]
    /// 画布尺寸（= 图片在屏幕上的显示尺寸）。
    var size: CGSize
    var zoomScale: CGFloat = 1
    var fontSize: CGFloat = 14

    func makeUIView(context: Context) -> TranslationCanvasView {
        let view = TranslationCanvasView()
        view.baseFontSize = fontSize
        view.zoomScale = zoomScale
        return view
    }

    func updateUIView(_ view: TranslationCanvasView, context: Context) {
        view.baseFontSize = fontSize
        view.zoomScale = zoomScale
        guard size.width > 1, size.height > 1 else {
            view.placed = []
            return
        }
        // 只画已翻出来的。没翻的留在原样 —— 原文本来就在图上，盖一层反而是干扰。
        let placed = blocks.compactMap { block -> TranslationCanvasView.Placed? in
            guard block.isTranslated else { return nil }
            return TranslationCanvasView.Placed(
                rect: block.rect.scaled(to: size),
                text: block.display,
                vertical: block.vertical
            )
        }
        view.placed = placed
    }
}

/// 阅读器里翻译状态的小角标：识别中 / 翻译中 / 失败原因。
///
/// 跑过 2 秒之后会带上已耗秒数。这个数字不只是装饰：之前一直显示
/// 「识别文字…」的时候，用户根本分不清是在跑还是已经卡死了 ——
/// 秒数在跳至少说明还活着。
struct TranslationStatusBadge: View {
    var phase: TranslationPhase

    @State private var startedAt = Date()

    var body: some View {
        Group {
            if phase.isBusy || isFailure {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 5) {
                        if phase.isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.75)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                        Text(label(at: context.date))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary.opacity(0.8))
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.92), in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                }
            }
        }
        .onChange(of: phase) { _ in
            startedAt = Date()
        }
    }

    private func label(at date: Date) -> String {
        guard phase.isBusy else { return phase.label }
        let elapsed = Int(date.timeIntervalSince(startedAt))
        return elapsed >= 2 ? "\(phase.label) \(elapsed)s" : phase.label
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }
}
