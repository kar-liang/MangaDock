import Foundation
import UIKit
import ImageIO

enum ImageDecoder {
    /// Decodes at display resolution instead of full resolution — a 3000x4000
    /// manga scan would otherwise eat 48 MB of RAM per page.
    /// 限制「短边」（宽度）到 maxPixelSize，而不是「最长边」。
    /// 超长条漫（高 ≫ 宽）若按最长边限制，宽度会被压到几百 px、糊成一片。
    static func downsample(_ data: Data, maxPixelSize: CGFloat = 3000) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        // 按短边算等效的最长边上限，交给 CGImageSource 的 thumbnail 限制。
        var targetMaxPixel = maxPixelSize
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            let short = min(w, h)
            let long = max(w, h)
            // 短边超了才缩放（等比压短边）；没超就保持原尺寸，别误缩长边。
            targetMaxPixel = short > maxPixelSize ? long * (maxPixelSize / short) : long
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
