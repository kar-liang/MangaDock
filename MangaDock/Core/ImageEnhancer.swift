import SwiftUI
import UIKit
import CoreImage
import CoreML
import Metal

/// Local image enhancement for low-resolution scans.
///
/// Two engines, in priority order:
///
/// 1. **Core ML** — if a compiled `SuperResolution.mlmodelc` is in the bundle it is
///    picked up automatically. A real super-resolution network can invent detail;
///    nothing here pretends to.
/// 2. **Metal shader** — edge-directed upscaling in the spirit of Anime4K, plus line
///    enhancement. No model, no bundle weight, one page in tens of milliseconds.
///
/// Why the shader beats plain Lanczos + unsharp:
///
/// * Lanczos blends *across* an edge, so every 1 px ink line comes out 1.5 px and grey.
///   This samples **along** the edge (direction taken from the Sobel gradient) and keeps
///   the crossing direction nearest-neighbour, so strokes stay one pixel wide.
/// * Unsharp mask fires on every gradient and haloes the line art. Here the boost is
///   gated by gradient magnitude and only darkens pixels that are already dark.
enum ImageEnhancer {

    // MARK: - Tuning

    struct Tuning {
        /// How much detected line art gets darkened. Clamped to 0…0.6.
        var lineDarken: Float = 0.18
        /// Contrast squeeze on line art — turns fuzzy grey strokes into solid ink. 0…1.
        var lineThin: Float = 0.45
        /// Extra local contrast. Off by default: the directional resample already
        /// sharpens, and stacking unsharp on top of it haloes.
        var sharpen: Float = 0.0
    }

    static let lineDarkenKey = "mangadock.lineDarken"
    static let lineThinKey = "mangadock.lineThin"

    /// Read from defaults on every call so the settings sliders take effect without
    /// threading an observable object through the reader.
    static var tuning: Tuning {
        let defaults = UserDefaults.standard
        var value = Tuning()
        if defaults.object(forKey: lineDarkenKey) != nil {
            value.lineDarken = Float(defaults.double(forKey: lineDarkenKey))
        }
        if defaults.object(forKey: lineThinKey) != nil {
            value.lineThin = Float(defaults.double(forKey: lineThinKey))
        }
        return value
    }

    /// Long-edge ceiling for the output. A 2200 px page upscales ~1.36× to reach this.
    static let maxOutputPixel: CGFloat = 3_000
    /// Hard area ceiling — 14 Mpx ≈ 56 MB as RGBA8. Larger pages are left alone.
    private static let maxOutputArea: CGFloat = 14_000_000

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Engine probe

    /// A compiled Core ML model named `SuperResolution.mlmodelc` inside the bundle
    /// lights this up. Nil means we use the Metal shader.
    static var coreMLModelURL: URL? {
        Bundle.main.url(forResource: "SuperResolution", withExtension: "mlmodelc")
    }

    static var isUsingCoreML: Bool { coreMLModelURL != nil }

    static var engineDescription: String {
        if coreMLModelURL != nil {
            return "Core ML 超分模型（已安装）"
        }
        if MetalEnhancer.gpuPresent {
            return "Metal 边缘导向放大 + 线条增强"
        }
        return "Lanczos 2x + 锐化（无可用 GPU，已降级）"
    }

    // MARK: - Entry point

    static func enhance(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        guard let scale = outputScale(width: cgImage.width, height: cgImage.height) else {
            return image
        }

        var result: CGImage?
        if let modelURL = coreMLModelURL {
            result = CoreMLSuperResolution.upscale(cgImage, modelURL: modelURL)
        }
        if result == nil {
            result = MetalEnhancer.shared.enhance(cgImage, scale: scale, tuning: tuning)
        }
        if result == nil {
            result = lanczosFallback(cgImage, scale: scale)
        }

        guard let result else { return nil }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Sizing

    private static func outputScale(width: Int, height: Int) -> CGFloat? {
        let w = CGFloat(width)
        let h = CGFloat(height)
        guard w > 1, h > 1 else { return nil }
        guard w * h >= 4_000, w * h <= maxOutputArea else { return nil }

        var scale = min(2.0, maxOutputPixel / w)
        scale = min(scale, (maxOutputArea / (w * h)).squareRoot())
        // Never shrink. At 1.0 the resample is a no-op and only line enhancement lands,
        // which is still worth it on pages that are already large enough.
        return max(1.0, scale)
    }

    // MARK: - Fallback

    private static func lanczosFallback(_ cgImage: CGImage, scale: CGFloat) -> CGImage? {
        let source = CIImage(cgImage: cgImage)

        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = source
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1
        guard let scaled = lanczos.outputImage else { return nil }

        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = scaled
        sharpen.radius = 2.0
        sharpen.intensity = 0.5
        let output = sharpen.outputImage ?? scaled

        return ciContext.createCGImage(output, from: output.extent)
    }
}

// MARK: - Metal pipeline

private struct EnhancerParams {
    var srcSize: SIMD2<Float>
    var ratio: SIMD2<Float>
    var lineDarken: Float
    var lineThin: Float
    var sharpen: Float
    var padding: Float = 0
}

/// Compiled once at runtime, so there is no `.metal` file to wire into the Xcode
/// target — the project builds through XcodeGen with zero extra build settings, and
/// a shader typo can never break the build.
private final class MetalEnhancer {

    static let shared = MetalEnhancer()

    /// Cheap probe for UI: does this device have a Metal GPU? Does not compile anything.
    static let gpuPresent = MTLCreateSystemDefaultDevice() != nil

    private let lock = NSLock()
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var built = false

    @discardableResult
    private func prepare() -> MTLRenderPipelineState? {
        lock.lock()
        defer { lock.unlock() }
        if built { return pipeline }
        built = true

        guard let dev = MTLCreateSystemDefaultDevice(),
              let commandQueue = dev.makeCommandQueue() else { return nil }

        do {
            let library = try dev.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "enhance_vertex"),
                  let fragmentFunction = library.makeFunction(name: "enhance_fragment") else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm

            let state = try dev.makeRenderPipelineState(descriptor: descriptor)
            device = dev
            queue = commandQueue
            pipeline = state
            return state
        } catch {
            #if DEBUG
            print("ImageEnhancer: Metal pipeline unavailable — \(error)")
            #endif
            return nil
        }
    }

    func enhance(_ source: CGImage, scale: CGFloat, tuning: ImageEnhancer.Tuning) -> CGImage? {
        _ = prepare()
        guard let device, let queue, let pipeline else { return nil }

        let srcW = source.width
        let srcH = source.height
        guard srcW > 0, srcH > 0 else { return nil }

        let dstW = max(1, Int((CGFloat(srcW) * scale).rounded()))
        let dstH = max(1, Int((CGFloat(srcH) * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ciContext = CIContext(
            mtlDevice: device,
            options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace]
        )

        // Upload through Core Image so its row-order convention matches the way we
        // read the result back. Both sides go through CI, so no hand-rolled flip.
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: srcW, height: srcH, mipmapped: false
        )
        srcDesc.usage = [.shaderRead]
        srcDesc.storageMode = .private
        guard let srcTexture = device.makeTexture(descriptor: srcDesc) else { return nil }
        ciContext.render(
            CIImage(cgImage: source),
            to: srcTexture,
            bounds: CGRect(x: 0, y: 0, width: srcW, height: srcH),
            colorSpace: colorSpace
        )

        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: dstW, height: dstH, mipmapped: false
        )
        dstDesc.usage = [.renderTarget, .shaderRead]
        dstDesc.storageMode = .private
        guard let dstTexture = device.makeTexture(descriptor: dstDesc) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dstTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        var params = EnhancerParams(
            srcSize: SIMD2<Float>(Float(srcW), Float(srcH)),
            ratio: SIMD2<Float>(Float(srcW) / Float(dstW), Float(srcH) / Float(dstH)),
            lineDarken: tuning.lineDarken,
            lineThin: tuning.lineThin,
            sharpen: tuning.sharpen
        )

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(srcTexture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<EnhancerParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard let output = CIImage(mtlTexture: dstTexture, options: [.colorSpace: colorSpace]) else {
            return nil
        }
        return ciContext.createCGImage(output, from: output.extent)
    }

    // MARK: - Shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Params {
        float2 srcSize;
        float2 ratio;
        float lineDarken;
        float lineThin;
        float sharpen;
        float padding;
    };

    vertex VSOut enhance_vertex(uint vid [[vertex_id]]) {
        float2 pos;
        float2 uv;
        switch (vid) {
            case 0: pos = float2(-1.0, -1.0); uv = float2(0.0, 1.0); break;
            case 1: pos = float2( 1.0, -1.0); uv = float2(1.0, 1.0); break;
            case 2: pos = float2(-1.0,  1.0); uv = float2(0.0, 0.0); break;
            default: pos = float2( 1.0,  1.0); uv = float2(1.0, 0.0); break;
        }
        VSOut out;
        out.position = float4(pos, 0.0, 1.0);
        out.uv = uv;
        return out;
    }

    #define MDX_LUMA(q) dot(src.sample(smp, (q)).rgb, float3(0.299, 0.587, 0.114))

    fragment float4 enhance_fragment(VSOut in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     constant Params &p [[buffer(0)]]) {
        constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);

        float2 s = in.uv * p.srcSize - 0.5;
        float2 center = floor(s + 0.5);

        float l00 = MDX_LUMA(center + float2(-1.0, -1.0));
        float l10 = MDX_LUMA(center + float2( 0.0, -1.0));
        float l20 = MDX_LUMA(center + float2( 1.0, -1.0));
        float l01 = MDX_LUMA(center + float2(-1.0,  0.0));
        float l21 = MDX_LUMA(center + float2( 1.0,  0.0));
        float l02 = MDX_LUMA(center + float2(-1.0,  1.0));
        float l12 = MDX_LUMA(center + float2( 0.0,  1.0));
        float l22 = MDX_LUMA(center + float2( 1.0,  1.0));

        float gx = (l20 + 2.0 * l21 + l22) - (l00 + 2.0 * l01 + l02);
        float gy = (l02 + 2.0 * l12 + l22) - (l00 + 2.0 * l10 + l20);

        float magnitude = sqrt(gx * gx + gy * gy);
        float ax = abs(gx);
        float ay = abs(gy);

        // A large ay means the gradient points vertically, so the edge itself runs
        // horizontally and we should interpolate along x, not across y.
        float alongHorizontal = ay / (ax + ay + 0.0001);

        float3 plain = src.sample(smp, s).rgb;
        float3 horizontal = src.sample(smp, float2(s.x, center.y)).rgb;
        float3 vertical = src.sample(smp, float2(center.x, s.y)).rgb;

        float edgeMix = smoothstep(0.02, 0.30, magnitude);
        float3 directional = mix(vertical, horizontal, alongHorizontal);
        float3 color = mix(plain, directional, edgeMix);

        float lineMask = smoothstep(0.08, 0.42, magnitude);

        // Squeeze the anti-aliased shoulder of each stroke toward black or white so it
        // reads as solid ink instead of grey fuzz.
        float3 squeezed = color * color * (3.0 - 2.0 * color);
        color = mix(color, squeezed, clamp(p.lineThin, 0.0, 1.0) * lineMask);

        color *= (1.0 - clamp(p.lineDarken, 0.0, 0.6) * lineMask);

        if (p.sharpen > 0.001) {
            float3 neighbours = 0.25 * (
                src.sample(smp, center + float2(-1.0,  0.0)).rgb +
                src.sample(smp, center + float2( 1.0,  0.0)).rgb +
                src.sample(smp, center + float2( 0.0, -1.0)).rgb +
                src.sample(smp, center + float2( 0.0,  1.0)).rgb
            );
            color = clamp(color + (color - neighbours) * p.sharpen, 0.0, 1.0);
        }

        return float4(clamp(color, 0.0, 1.0), 1.0);
    }
    """
}

// MARK: - Core ML hook

/// Runs a drop-in Core ML super-resolution model.
///
/// The model is probed instead of hard-coded: the first image-typed input gets the
/// page, the first image-typed output comes back. That way whatever waifu2x /
/// Real-ESRGAN conversion gets dropped in works without binding to one exporter's
/// tensor names. Models that only expose multi-array tensors are ignored and the
/// Metal path takes over.
enum CoreMLSuperResolution {

    static func upscale(_ cgImage: CGImage, modelURL: URL) -> CGImage? {
        let configuration = MLModelConfiguration()
        // ANE first, GPU second, CPU last. A 2× model page lands in a few hundred ms
        // on ANE versus seconds on CPU.
        configuration.computeUnits = .all

        guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration) else {
            return nil
        }

        let description = model.modelDescription
        guard let inputName = firstImageKey(in: description.inputDescriptionsByName),
              let outputName = firstImageKey(in: description.outputDescriptionsByName) else {
            return nil
        }

        guard let buffer = pixelBuffer(from: cgImage) else { return nil }

        let input = try? MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(pixelBuffer: buffer)
        ])
        guard let input else { return nil }

        guard let result = try? model.prediction(from: input),
              let output = result.featureValue(for: outputName)?.imageValue else {
            return nil
        }

        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        guard width > 0, height > 0 else { return nil }
        // A 4× model can overshoot the memory budget; refuse rather than blow up.
        guard CGFloat(width) <= ImageEnhancer.maxOutputPixel * 2 else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return CIContext().createCGImage(CIImage(cvPixelBuffer: output), from: bounds)
    }

    private static func firstImageKey(in descriptions: [String: MLFeatureDescription]) -> String? {
        for (name, feature) in descriptions where feature.type == .image {
            return name
        }
        return nil
    }

    private static func pixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
