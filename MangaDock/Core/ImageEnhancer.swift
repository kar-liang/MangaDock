import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Local image enhancement for low-resolution scans.
///
/// This is a GPU pipeline (Lanczos upscale + unsharp mask), not a learned model —
/// it sharpens line art and hides upscaling blur, but it cannot invent detail the
/// way a super-resolution network can. `ImageEnhancer.coreMLModelURL` is where a
/// drop-in Core ML super-resolution model would be picked up.
enum ImageEnhancer {
    static let maxOutputPixel: CGFloat = 3_000

    private static let context: CIContext = CIContext(options: [.useSoftwareRenderer: false])

    /// A compiled Core ML model named `SuperResolution.mlmodelc` inside the bundle
    /// would light this up. Nil means we fall back to the GPU pipeline.
    static var coreMLModelURL: URL? {
        Bundle.main.url(forResource: "SuperResolution", withExtension: "mlmodelc")
    }

    static var engineDescription: String {
        if coreMLModelURL != nil {
            return "Core ML 超分模型（已安装）"
        }
        return "GPU 增强（Lanczos 2x + 锐化），未安装 AI 模型"
    }

    static func enhance(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let source = CIImage(cgImage: cgImage)
        let width = source.extent.width
        guard width > 0 else { return nil }

        // Cap the output so a 2200 px page doesn't balloon to 100 MB of pixels.
        let scale = min(2.0, max(1.0, maxOutputPixel / width))
        guard scale > 1.05 else { return image }

        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = source
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1
        guard let scaled = lanczos.outputImage else { return nil }

        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = scaled
        sharpen.radius = 2.2
        sharpen.intensity = 0.55
        let output = sharpen.outputImage ?? scaled

        guard let result = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }
}
