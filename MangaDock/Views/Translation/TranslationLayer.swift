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
struct TranslationStatusBadge: View {
    var phase: TranslationPhase

    var body: some View {
        if phase.isBusy || isFailure {
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
                Text(phase.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }
}
