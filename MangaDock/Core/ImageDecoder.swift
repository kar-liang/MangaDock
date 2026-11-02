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
            // 短边超了才缩放（等比压短边）；没超就保持原尺寸，别误缩长边。
            targetMaxPixel = short > limit ? long * (limit / short) : long
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
