import Foundation
import UIKit

extension Notification.Name {
    /// Posted when a user-chosen cover is added, removed or pulled from sync,
    /// so visible grid cells reload their image.
    static let coversDidChange = Notification.Name("mangadock.coversDidChange")
}

/// Builds and caches grid thumbnails. Covers come from three places, cheapest first:
/// a locally cached archive, the first image of a folder, or a byte-range read of
/// the remote CBZ (no full download just to show a cover).
enum CoverBuilder {
    static let maxPixel: CGFloat = 640

    static func make(for item: WebDAVItem, client: WebDAVClient) async -> UIImage? {
        if item.isImage {
            var data = CacheManager.pageData(for: item.url)
            if data == nil {
                data = try? await client.data(for: item.url)
            }
            guard let data else { return nil }
            return await decode(data)
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

        if item.isPDF {
            // No byte-range trick for PDF — only a locally cached copy can be rendered.
            guard CacheManager.hasArchive(for: item.url) else { return nil }
            let local = CacheManager.archiveURL(for: item.url)
            return await Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = try? PDFComicSource(fileURL: local),
                      let data = try? await source.pageData(at: 0) else { return nil }
                return ImageDecoder.downsample(data, maxPixelSize: CoverBuilder.maxPixel)
            }.value
        }

        if item.isDirectory {
            guard let children = try? await client.list(item.requestURL) else { return nil }
            if let firstImage = children.first(where: { !$0.isDirectory && $0.isImage }) {
                guard let data = try? await client.data(for: firstImage.url) else { return nil }
                return await decode(data)
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

    // MARK: - Custom covers

    /// Covers the user picked themselves, as recorded on disk.
    var customCovers: [CustomCoverEntry] {
        CacheManager.loadCustomCoverManifest()
    }

    func hasCustomCover(for item: WebDAVItem) -> Bool {
        CacheManager.hasManualCover(key: item.id)
    }

    @discardableResult
    func setCustomCover(_ image: UIImage, for item: WebDAVItem) -> UIImage? {
        guard let prepared = Self.normalized(image),
              let data = prepared.jpegData(compressionQuality: 0.86) else { return nil }
        CacheManager.storeCover(data, key: item.id)
        CacheManager.markManualCover(key: item.id)
        recordManifest(itemID: item.id, updatedAt: Date())
        images[item.id] = prepared
        NotificationCenter.default.post(name: .coversDidChange, object: nil)
        return prepared
    }

    func removeCustomCover(for item: WebDAVItem) {
        CacheManager.deleteCover(key: item.id)
        images[item.id] = nil
        dropManifest(itemID: item.id)
        NotificationCenter.default.post(name: .coversDidChange, object: nil)
    }

    /// Stores a cover that arrived from another device. Returns false when the
    /// bytes aren't a usable image.
    @discardableResult
    func adoptSyncedCover(_ data: Data, itemID: String, updatedAt: Date) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        CacheManager.storeCover(data, key: itemID)
        CacheManager.markManualCover(key: itemID)
        recordManifest(itemID: itemID, updatedAt: updatedAt)
        images[itemID] = image
        NotificationCenter.default.post(name: .coversDidChange, object: nil)
        return true
    }

    private func recordManifest(itemID: String, updatedAt: Date) {
        var list = CacheManager.loadCustomCoverManifest()
        list.removeAll { $0.itemID == itemID }
        list.append(CustomCoverEntry(itemID: itemID,
                                     hash: CacheManager.hash(itemID),
                                     updatedAt: updatedAt))
        CacheManager.saveCustomCoverManifest(list)
    }

    private func dropManifest(itemID: String) {
        var list = CacheManager.loadCustomCoverManifest()
        let before = list.count
        list.removeAll { $0.itemID == itemID }
        guard list.count != before else { return }
        CacheManager.saveCustomCoverManifest(list)
    }

    /// Center-crop to 2:3 and shrink to 600×900 so every card lines up.
    private static func normalized(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        guard width > 0, height > 0 else { return nil }

        let target: CGFloat = 2.0 / 3.0
        let rect: CGRect
        if width / height > target {
            let newWidth = height * target
            rect = CGRect(x: (width - newWidth) / 2, y: 0, width: newWidth, height: height)
        } else {
            let newHeight = width / target
            rect = CGRect(x: 0, y: (height - newHeight) / 2, width: width, height: newHeight)
        }
        guard let cropped = cg.cropping(to: rect) else { return nil }

        let canvas = CGSize(width: 600, height: 900)
        let source = UIImage(cgImage: cropped)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            source.draw(in: CGRect(origin: .zero, size: canvas))
        }
    }
}
