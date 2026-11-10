import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Local image enhancement for low-resolution scans.
///
/// Two engines, picked automatically:
/// - `AIEnhancer` (Real-ESRGAN, Core ML) when the model is bundled — real detail
///   reconstruction, slow (seconds per page).
/// - A GPU pipeline (Lanczos upscale + unsharp mask) as the always-on fallback —
///   instant, but it cannot invent detail.
enum ImageEnhancer {
    static let maxOutputPixel: CGFloat = 3_000

    private static let context: CIContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Whether the Real-ESRGAN Core ML model is bundled.
    static var hasAIModel: Bool { AIEnhancer.isAvailable }

    static var engineDescription: String { AIEnhancer.engineDescription }

    /// Preferred AI scale, persisted in settings.
    static var aiScale: AIEnhancer.Scale {
        get {
            let raw = UserDefaults.standard.integer(forKey: "mangadock.aiScale")
            return AIEnhancer.Scale(rawValue: raw == 4 ? 4 : 2) ?? .two
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mangadock.aiScale") }
    }

    /// Async AI path; the caller decides whether to use it and at what scale.
    static func enhanceAI(_ image: UIImage, scale: AIEnhancer.Scale? = nil) async -> UIImage? {
        await AIEnhancer.enhance(image, scale: scale ?? aiScale)
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
