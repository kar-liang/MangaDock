import Foundation

/// Syncs user-chosen book covers as plain files on the WebDAV server:
///
///     <server>/.mangadock-covers/index.json
///     <server>/.mangadock-covers/<sha256(comicURL)>.jpg
///
/// Covers are ~100 KB each, so they deliberately do NOT go inside
/// `.mangadock-sync.json` — that file is rewritten in full on every progress
/// sync, and dragging a few MB of JPEG through it would make every page turn
/// upload megabytes.
///
/// Semantics mirror the two manual buttons: upload pushes this device's covers,
/// download pulls the server's. Files are compared per cover by `updatedAt`, so
/// a repeat sync only moves what actually changed.
@MainActor
enum CoverSyncService {
    static let folderName = ".mangadock-covers"
    static let indexName = "index.json"

    static func folderURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func indexURL(baseURL: URL) -> URL {
        folderURL(baseURL: baseURL).appendingPathComponent(indexName)
    }

    private static func coverURL(baseURL: URL, hash: String) -> URL {
        folderURL(baseURL: baseURL).appendingPathComponent(hash + ".jpg")
    }

    // MARK: - Upload

    /// Pushes local covers. Returns a note for the settings UI, or nil when
    /// there was nothing to do (no custom covers at all).
    static func push(store: AppStore) async -> String? {
        guard let client = store.makeClient(), let base = store.baseURL else { return nil }
        let local = CoverStore.shared.customCovers
        guard !local.isEmpty else { return nil }

        do {
            try await client.makeCollection(folderURL(baseURL: base))
        } catch {
            return "封面没同步：服务器不允许建目录（\(NetErrorText.friendly(error))）"
        }

        let remote = await fetchIndex(client: client, base: base)

        var uploaded = 0
        for entry in local {
            if let existing = remote.first(where: { $0.hash == entry.hash }),
               existing.updatedAt >= entry.updatedAt {
                continue
            }
            guard let data = try? Data(contentsOf: CacheManager.coverURL(key: entry.itemID)) else {
                continue
            }
            do {
                try await client.upload(data,
                                        to: coverURL(baseURL: base, hash: entry.hash),
                                        contentType: "image/jpeg")
                uploaded += 1
            } catch {
                return "封面同步中断（已传 \(uploaded) 张）：\(NetErrorText.friendly(error))"
            }
        }

        // Merge instead of clobber: another device may have covers this one
        // has never seen, and dropping them would silently delete its work.
        let merged = merge(local: local, remote: remote)
        if let data = try? JSONEncoder().encode(merged) {
            try? await client.upload(data, to: indexURL(baseURL: base))
        }

        return uploaded > 0 ? "封面已上传 \(uploaded) 张" : nil
    }

    // MARK: - Download

    /// Pulls covers the server has and this device doesn't (or has an older
    /// copy of). Returns a note for the settings UI.
    static func pull(store: AppStore) async -> String? {
        guard let client = store.makeClient(), let base = store.baseURL else { return nil }
        let remote = await fetchIndex(client: client, base: base)
        guard !remote.isEmpty else { return nil }

        var localByHash: [String: CustomCoverEntry] = [:]
        for entry in CacheManager.loadCustomCoverManifest() {
            localByHash[entry.hash] = entry
        }

        var downloaded = 0
        for entry in remote {
            if let local = localByHash[entry.hash], local.updatedAt >= entry.updatedAt {
                continue
            }
            guard let data = try? await client.data(for: coverURL(baseURL: base, hash: entry.hash)) else {
                continue
            }
            if CoverStore.shared.adoptSyncedCover(data,
                                                 itemID: entry.itemID,
                                                 updatedAt: entry.updatedAt) {
                downloaded += 1
            }
        }

        guard downloaded > 0 else { return nil }
        return "封面已下载 \(downloaded) 张"
    }

    // MARK: - Helpers

    private static func fetchIndex(client: WebDAVClient, base: URL) async -> [CustomCoverEntry] {
        // A missing folder (404) is normal on a first sync — an empty index is
        // the right answer, not an error.
        guard let data = try? await client.data(for: indexURL(baseURL: base)),
              let list = try? JSONDecoder().decode([CustomCoverEntry].self, from: data) else {
            return []
        }
        return list
    }

    private static func merge(local: [CustomCoverEntry],
                              remote: [CustomCoverEntry]) -> [CustomCoverEntry] {
        // uniquingKeysWith, not uniqueKeysWithValues: a hand-edited or
        // half-written remote index could contain duplicates and would crash.
        var byHash = Dictionary(remote.map { ($0.hash, $0) }) { first, second in
            first.updatedAt >= second.updatedAt ? first : second
        }
        for entry in local {
            if let existing = byHash[entry.hash], existing.updatedAt >= entry.updatedAt {
                continue
            }
            byHash[entry.hash] = entry
        }
        return byHash.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}
