import Foundation
import UIKit

/// Builds and caches grid thumbnails. Covers come from three places, cheapest first:
/// a locally cached archive, the first image of a folder, or a byte-range read of
/// the remote CBZ (no full download just to show a cover).
enum CoverBuilder {
    static let maxPixel: CGFloat = 640

    static func make(for item: WebDAVItem, client: WebDAVClient) async -> UIImage? {
        if item.isImage {
            let data = CacheManager.pageData(for: item.url) ?? (try? await client.data(for: item.url))
            guard let data else { return nil }
            return decode(data)
        }

        if item.isArchive {
            if CacheManager.hasArchive(for: item.url) {
                let local = CacheManager.archiveURL(for: item.url)
                return await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let archive = try? ZipArchive(fileURL: local) else { return nil }
                    let pages = archive.entries
                        .filter { PageFiles.isPageFile($0.name) }
                        .sorted { NaturalSort.less($0.name, $1.name) }
                    guard let first = pages.first,
                          let data = try? archive.data(for: first) else { return nil }
                    return ImageDecoder.downsample(data, maxPixelSize: CoverBuilder.maxPixel)
                }.value
            }
            return await RemoteZip.cover(for: item.url, client: client, maxPixel: maxPixel)
        }

        if item.isDirectory {
            guard let children = try? await client.list(item.requestURL) else { return nil }
            if let firstImage = children.first(where: { !$0.isDirectory && $0.isImage }) {
                guard let data = try? await client.data(for: firstImage.url) else { return nil }
                return decode(data)
            }
            if let firstArchive = children.first(where: { !$0.isDirectory && $0.isArchive }) {
                return await make(for: firstArchive, client: client)
            }
        }
        return nil
    }

    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) {
            ImageDecoder.downsample(data, maxPixelSize: CoverBuilder.maxPixel)
        }.value
    }
}

@MainActor
final class CoverStore {
    static let shared = CoverStore()

    private var images: [String: UIImage] = [:]
    private var inFlight: Set<String> = []

    func image(for item: WebDAVItem) -> UIImage? {
        images[item.id]
    }

    func load(_ item: WebDAVItem, client: WebDAVClient) async {
        let key = item.id
        if images[key] != nil || inFlight.contains(key) { return }

        // Nothing to cover for unsupported files.
        guard item.isImage || item.isArchive || item.isDirectory else { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        if let cached = CacheManager.coverData(key: key), let image = UIImage(data: cached) {
            images[key] = image
            return
        }

        guard let image = await CoverBuilder.make(for: item, client: client) else { return }
        images[key] = image
        if let data = image.jpegData(compressionQuality: 0.82) {
            CacheManager.storeCover(data, key: key)
        }
    }

    func clearMemory() {
        images.removeAll()
    }
}
