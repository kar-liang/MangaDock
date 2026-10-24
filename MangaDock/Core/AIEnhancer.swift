import Foundation
import UIKit
import CoreML
import CoreImage

/// Real-ESRGAN x4plus anime (6B) super-resolution, running locally via Core ML.
///
/// The model takes a fixed 512×512 RGB tile and returns a 2048×2048 (4x) tile.
/// Larger images are split into overlapping tiles, upscaled independently, and
/// stitched back together. Output can be clamped to 2x so a full page doesn't
/// balloon to 4x the pixel count on the phone.
enum AIEnhancer {
    enum Scale: Int, CaseIterable {
        case two = 2
        case four = 4

        var title: String { self == .two ? "2 倍" : "4 倍" }
    }

    /// Xcode compiles `.mlpackage` sources into `.mlmodelc` inside the bundle,
    /// so the compiled artifact is what ships. Fall back to the raw package
    /// (loaded + compiled at runtime) just in case.
    static let modelURL: URL? =
        Bundle.main.url(forResource: "SuperResolution", withExtension: "mlmodelc")
        ?? Bundle.main.url(forResource: "SuperResolution", withExtension: "mlpackage")

    static var isAvailable: Bool { modelURL != nil }

    static var engineDescription: String {
        isAvailable ? "Real-ESRGAN 动漫超分（Core ML，已安装）" : "GPU 增强（Lanczos 2x + 锐化），未安装 AI 模型"
    }

    private static let tileSize = 512
    private static let overlap = 32

    /// Loaded once; ML Program packages compile on first load and the compiled
    /// artifact is cached in memory so subsequent pages don't recompile.
    private static var cachedModel: MLModel?
    private static func model() -> MLModel? {
        if let cachedModel { return cachedModel }
        guard let url = modelURL else { return nil }
        cachedModel = try? MLModel(contentsOf: url)
        return cachedModel
    }

    /// Run super-resolution. Returns nil if the model is missing or inference fails.
    static func enhance(_ image: UIImage, scale: Scale = .two) async -> UIImage? {
        guard modelURL != nil else { return nil }
        guard let cgImage = image.cgImage else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            run(cgImage: cgImage, scale: scale)
        }.value
    }

    // MARK: - Inference

    private static func run(cgImage: CGImage, scale: Scale) -> UIImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        guard let model = model() else { return nil }

        // Output canvas at the target scale.
        let outW = width * scale.rawValue
        let outH = height * scale.rawValue

        guard let context = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high

        // Slide a 512px window across the image. Each tile overlaps its neighbors by
        // `overlap` px; the overlap is discarded after upscaling so seams don't show.
        let step = tileSize - overlap * 2

        var oy = 0
        while oy < height {
            var ox = 0
            while ox < width {
                let tileW = min(tileSize, width - ox)
                let tileH = min(tileSize, height - oy)
                let rect = CGRect(x: ox, y: oy, width: tileW, height: tileH)

                if let tileCG = cgImage.cropping(to: rect),
                   let up = upscaleTile(tileCG, model: model),
                   let final = trimAndScale(up,
                                            tileX: ox, tileY: oy,
                                            tileW: tileW, tileH: tileH,
                                            imageW: width, imageH: height,
                                            scale: scale) {
                    // final already positioned to the correct output rect.
                    let dstX = (ox + (ox > 0 ? overlap : 0)) * scale.rawValue
                    let dstY = (oy + (oy > 0 ? overlap : 0)) * scale.rawValue
                    context.draw(final, in: CGRect(x: dstX, y: dstY,
                                                   width: final.width, height: final.height))
                }

                ox += step
            }
            oy += step
        }

        guard let result = context.makeImage() else { return nil }
        return UIImage(cgImage: result)
    }

    /// Crops the overlap off an upscaled tile and (optionally) halves it for 2x.
    private static func trimAndScale(_ up: CGImage,
                                     tileX: Int, tileY: Int,
                                     tileW: Int, tileH: Int,
                                     imageW: Int, imageH: Int,
                                     scale: Scale) -> CGImage? {
        // In input space, how much to trim from each side (0 at image edges).
        let trimLeft = tileX > 0 ? overlap : 0
        let trimTop = tileY > 0 ? overlap : 0
        let trimRight = (tileX + tileW < imageW) ? overlap : 0
        let trimBottom = (tileY + tileH < imageH) ? overlap : 0

        // In upscaled (4x) space.
        let sx = trimLeft * 4
        let sy = trimTop * 4
        let sw = (tileW - trimLeft - trimRight) * 4
        let sh = (tileH - trimTop - trimBottom) * 4
        guard sw > 0, sh > 0 else { return nil }

        guard let cropped = up.cropping(to: CGRect(x: sx, y: sy, width: sw, height: sh)) else {
            return nil
        }
        if scale == .two {
            return resize(cropped, to: CGSize(width: sw / 2, height: sh / 2))
        }
        return cropped
    }

    /// Runs one tile through the model. Input is expected to be 512×512 RGB.
    private static func upscaleTile(_ tile: CGImage, model: MLModel) -> CGImage? {
        // Resize to exactly 512×512 if the edge tile is smaller.
        let resized: CGImage
        if tile.width != tileSize || tile.height != tileSize {
            resized = padToTile(tile) ?? tile
        } else {
            resized = tile
        }

        guard let input = pixelBuffer(from: resized) else { return nil }

        do {
            let inputValue = MLFeatureValue(pixelBuffer: input)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(
                dictionary: ["input": inputValue]
            ))

            guard let outValue = output.featureValue(for: "output"),
                  let outBuffer = outValue.imageBufferValue else { return nil }

            let ci = CIImage(cvPixelBuffer: outBuffer)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
            return cg
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Pads an edge tile to a full 512×512 so the model accepts it.
    private static func padToTile(_ tile: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: tileSize, height: tileSize,
            bitsPerComponent: 8, bytesPerRow: tileSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        return context.makeImage()
    }

    /// Converts a CGImage to a 512×512 BGRA CVPixelBuffer (Core ML image input).
    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// Downscales a CGImage to the given size (for 2x output from a 4x tile).
    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }
}
