import Foundation
import UIKit
import ImageIO

enum ImageDecoder {
    /// 短边降采样上限，按设备内存分档：
    /// - ≥6GB → 2200
    /// - 4~6GB（iPad mini 6 等）→ 1800
    /// - <4GB → 1500
    ///
    /// 曾经是 3000（2.0.25 为了修「画质发虚」从 2200 升上去的）。但 3000x4762 的位图
    /// 一张就是 57MB，图片缓存（160MB）只放得下 2.8 张 —— 一话 9 页必然反复淘汰，
    /// 表现为同一页被反复解码、反复下载。2200 大约 30MB/张，能放 5 张，
    /// 解码也快 40%。当年发虚的根因是「按最长边限制」把超长条漫的宽度压扁了，
    /// 后来 2.0.26 改成按短边限制，所以降回 2200 不会重现那个问题。
    static var defaultMaxPixelSize: CGFloat {
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem >= 6 * 1024 * 1024 * 1024 { return 2200 }
        if mem >= 4 * 1024 * 1024 * 1024 { return 1800 }
        return 1500
    }

    /// 单页像素数上限（约 1400 万像素 ≈ 56MB 位图）。
    ///
    /// 条漫的页是「又宽又长」，只卡短边没用：2200 宽能配出 1 万多高的图，
    /// 面积照样爆。这里按总像素再压一道，让「预热 2 页」真的放得进缓存。
    private static let maxPixels: CGFloat = 14_000_000

    /// Decodes at display resolution instead of full resolution — a 3000x4000
    /// manga scan would otherwise eat 48 MB of RAM per page.
    /// 限制「短边」（宽度）到 maxPixelSize，而不是「最长边」。
    /// 超长条漫（高 ≫ 宽）若按最长边限制，宽度会被压到几百 px、糊成一片。
    /// maxPixelSize 传 nil 时按设备内存自适应（封面仍传固定 640）。
    static func downsample(_ data: Data, maxPixelSize: CGFloat? = nil) -> UIImage? {
        let limit = maxPixelSize ?? defaultMaxPixelSize
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        // 按短边算等效的最长边上限，交给 CGImageSource 的 thumbnail 限制。
        var targetMaxPixel = limit
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            let short = min(w, h)
            let long = max(w, h)

            // 第一步：短边超了才缩放（等比压短边）；没超就保持原尺寸，别误缩长边。
            var scale: CGFloat = short > limit ? limit / short : 1

            // 第二步：总像素封顶。
            // 只限制短边挡不住超长条漫 —— 2200x10111 有 2200 万像素 = 89MB，
            // 一张就吃掉半个图片缓存，预热三页直接把第一页挤出去，
            // 表现就是加载提示「1→2→3→1」、第一页要解两次。
            let projected = w * scale * h * scale
            if projected > Self.maxPixels {
                scale *= sqrt(Self.maxPixels / projected)
            }

            targetMaxPixel = long * scale
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

enum PageFiles {
    static func isPageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ComicFileTypes.imageExtensions.contains(ext)
    }
}
