import Foundation
import UIKit
import ImageIO

enum ImageDecoder {
    /// Decodes at display resolution instead of full resolution — a 3000x4000
    /// manga scan would otherwise eat 48 MB of RAM per page.
    static func downsample(_ data: Data, maxPixelSize: CGFloat = 2200) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

enum ComicPageSource {
    static func isPageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ComicFileTypes.imageExtensions.contains(ext)
    }
}
