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
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        guard let model = model() else { return nil }

        // 2x mode: downscale the source to half FIRST, then run the native 4x.
        // The output then equals the original at 2x — with 4x fewer tiles, so
        // roughly 4x faster than upscaling everything and halving afterwards.
        // Input caps keep the output bitmap within memory-friendly bounds
        // (2x ≤ 3200px, 4x ≤ 4096px long edge).
        let src: CGImage
        switch scale {
        case .two:
            let half = resize(cgImage, to: CGSize(width: cgImage.width / 2, height: cgImage.height / 2)) ?? cgImage
            src = clampLongEdge(half, to: 1600)
        case .four:
            src = clampLongEdge(cgImage, to: 1024)
        }

        let width = src.width
        let height = src.height
        let outW = width * 4
        let outH = height * 4

        guard let context = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high

        // Tiny dimension: pad that axis once so the window math always has 512.
        let pw = max(width, tileSize)
        let ph = max(height, tileSize)
        let padded: CGImage
        if width < tileSize || height < tileSize {
            padded = padToSize(src, width: pw, height: ph) ?? src
        } else {
            padded = src
        }

        // Window origins. The last tile is right/bottom-aligned so it is always a
        // full 512×512 — no per-tile padding needed, and coverage is exact.
        var origins: [Int] = []
        var o = 0
        while o + tileSize < pw {
            origins.append(o)
            o += tileSize - overlap * 2
        }
        origins.append(max(0, pw - tileSize))
        let xs = origins
        let ys = origins

        for oy in ys {
            for ox in xs {
                guard let tile = padded.cropping(to: CGRect(x: ox, y: oy, width: tileSize, height: tileSize)),
                      let up = upscaleTile(tile, model: model) else { continue }

                // Region this tile is responsible for, in source coordinates.
                // Clamped to the REAL image size — the padded area is black fill
                // and its model output must not leak into the result.
                let keepX = ox > 0 ? ox + overlap : ox
                let keepY = oy > 0 ? oy + overlap : oy
                let keepRight = min(ox + tileSize, width) - (ox + tileSize < width ? overlap : 0)
                let keepBottom = min(oy + tileSize, height) - (oy + tileSize < height ? overlap : 0)
                let keepW = keepRight - keepX
                let keepH = keepBottom - keepY
                guard keepW > 0, keepH > 0 else { continue }

                // Same region inside the 4x upscaled tile.
                let sx = (keepX - ox) * 4
                let sy = (keepY - oy) * 4
                guard let piece = up.cropping(to: CGRect(x: sx, y: sy,
                                                         width: keepW * 4, height: keepH * 4)) else { continue }

                // CGContext origin is bottom-left; the tile math above is top-left.
                let dstX = keepX * 4
                let dstY = outH - (keepY + keepH) * 4
                context.draw(piece, in: CGRect(x: dstX, y: dstY, width: keepW * 4, height: keepH * 4))
            }
        }

        // For 2x mode the canvas is already at original-size × 2 — ship as-is.
        guard let result = context.makeImage() else { return nil }
        return UIImage(cgImage: result)
    }

    /// Runs one 512×512 tile through the model, returns the 2048×2048 result.
    private static func upscaleTile(_ tile: CGImage, model: MLModel) -> CGImage? {
        guard let input = pixelBuffer(from: tile) else { return nil }

        do {
            let inputValue = MLFeatureValue(pixelBuffer: input)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(
                dictionary: ["input": inputValue]
            ))

            guard let outValue = output.featureValue(for: "output"),
                  let outBuffer = outValue.imageBufferValue else { return nil }

            let ci = CIImage(cvPixelBuffer: outBuffer)
            guard let cg = sharedCIContext.createCGImage(ci, from: ci.extent) else { return nil }
            return cg
        } catch {
            return nil
        }
    }

    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Helpers

    /// Pads an image so both axes are at least 512, anchored top-left, with
    /// black fill for the empty region (black blends into manga gutters).
    private static func padToSize(_ tile: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // CGContext origin is bottom-left — anchor the image to the TOP-left.
        context.draw(tile, in: CGRect(x: 0, y: CGFloat(height - tile.height),
                                      width: tile.width, height: tile.height))
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

    /// Caps the long edge so a page never produces an oversized output bitmap.
    private static func clampLongEdge(_ image: CGImage, to limit: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > limit else { return image }
        let factor = CGFloat(limit) / CGFloat(longEdge)
        return resize(image, to: CGSize(width: CGFloat(image.width) * factor,
                                        height: CGFloat(image.height) * factor)) ?? image
    }
}
