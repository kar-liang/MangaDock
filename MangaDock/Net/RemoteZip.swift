import Foundation
import UIKit

/// 远程 CBZ 的随机读：不下载整个文件，靠 HTTP Range 只取需要的字节。
///
/// 打开一章要做的：
/// 1) 读文件尾部窗口 → 找 EOCD → 解析中央目录，拿到每个页面的位置
/// 2) 每一页：读该 entry 的 local header（30 字节 + 文件名/扩展字段）
/// 3) Range 读这一页的压缩数据 → inflate
///
/// 任何一步失败（服务器不支持 Range、ZIP64、加密、非 deflate/store）
/// 都会抛错，调用方退回到「下载整包」的老路径。
enum RemoteZip {
    struct Entry {
        let method: UInt16
        let compressedSize: Int64
        let uncompressedSize: Int
        let localOffset: Int64
        let name: String
    }

    /// 尾部窗口大小。普通漫画 CBZ 的中央目录只有几 KB，256KB 很宽松。
    static let tailWindow: Int64 = 256 * 1024

    static func cover(for url: URL, client: WebDAVClient, maxPixel: CGFloat) async -> UIImage? {
        do {
            guard let length = try await client.contentLength(url), length > 2_048 else { return nil }
            let window = min(length, tailWindow)
            let tailStart = length - window
            guard let tail = try await client.data(url, byteRange: tailStart...(length - 1)),
                  Int64(tail.count) == window else { return nil }

            guard let entry = parseEntries(in: tail, tailStart: tailStart, fileLength: length).first else {
                return nil
            }

            let payload = try await payload(for: entry, url: url, client: client, fileLength: length)
            return await Task.detached(priority: .utility) {
                ImageDecoder.downsample(payload, maxPixelSize: maxPixel)
            }.value
        } catch {
            return nil
        }
    }

    /// 解析中央目录，返回所有可用图片条目（已按自然序排好）。
    static func parseEntries(in tail: Data, tailStart: Int64, fileLength: Int64) -> [Entry] {
        let bytes = [UInt8](tail)
        let count = bytes.count
        guard count > 22 else { return [] }

        var eocd = -1
        var cursor = count - 22
        while cursor >= 0 {
            if readU32(bytes, cursor) == 0x0605_4b50 {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard eocd >= 0 else { return [] }

        let entryCount = Int(readU16(bytes, eocd + 10))
        let directorySize = Int64(readU32(bytes, eocd + 12))
        let directoryOffset = Int64(readU32(bytes, eocd + 16))

        guard entryCount > 0, entryCount != 0xFFFF,
              directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else { return [] }
        guard directoryOffset >= tailStart else { return [] }   // 目录在窗口外

        var position = Int(directoryOffset - tailStart)
        var candidates: [Entry] = []

        for _ in 0..<entryCount {
            guard position + 46 <= count, readU32(bytes, position) == 0x0201_4b50 else { return candidates }
            let flags = readU16(bytes, position + 8)
            let method = readU16(bytes, position + 10)
            let compressedSize = Int64(readU32(bytes, position + 20))
            let uncompressedSize = Int(readU32(bytes, position + 24))
            let nameLength = Int(readU16(bytes, position + 28))
            let extraLength = Int(readU16(bytes, position + 30))
            let commentLength = Int(readU16(bytes, position + 32))
            let localOffset = Int64(readU32(bytes, position + 42))

            guard position + 46 + nameLength <= count else { return candidates }
            let nameBytes = Array(bytes[(position + 46)..<(position + 46 + nameLength)])
            let name = String(decoding: nameBytes, as: UTF8.self)

            let usable = flags & 0x0001 == 0          // 未加密
                && (method == 0 || method == 8)       // store / deflate
                && compressedSize > 0
                && localOffset + compressedSize < fileLength
                && PageFiles.isPageFile(name)
            if usable {
                candidates.append(Entry(method: method,
                                        compressedSize: compressedSize,
                                        uncompressedSize: uncompressedSize,
                                        localOffset: localOffset,
                                        name: name))
            }
            position += 46 + nameLength + extraLength + commentLength
        }

        return candidates.sorted { NaturalSort.less($0.name, $1.name) }
    }

    /// 读单页的原始（未解码）字节。
    static func payload(for entry: Entry,
                        url: URL,
                        client: WebDAVClient,
                        fileLength: Int64) async throws -> Data {
        guard let header = try await client.data(url, byteRange: entry.localOffset...(entry.localOffset + 1_024)),
              header.count >= 30 else { throw ZipError.corrupt }
        let nameLength = Int(headReading(header, 26))
        let extraLength = Int(headReading(header, 28))
        let dataStart = entry.localOffset + 30 + Int64(nameLength) + Int64(extraLength)
        guard dataStart < fileLength, entry.compressedSize > 0,
              dataStart + entry.compressedSize <= fileLength else { throw ZipError.corrupt }

        guard let payload = try await client.data(url,
                                                 byteRange: dataStart...(dataStart + entry.compressedSize - 1)),
              Int64(payload.count) == entry.compressedSize else { throw ZipError.corrupt }

        switch entry.method {
        case 0:
            return payload
        case 8:
            return try Inflate.raw(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupported("压缩方式不支持")
        }
    }

    // MARK: - Byte helpers

    private static func headReading(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// 直接读远程 CBZ 的阅读源。打开只要两次 Range 请求，不用等整包下载。
final class RemoteZipComicSource: ComicPageSource {
    let pageCount: Int

    private let entries: [RemoteZip.Entry]
    private let url: URL
    private let client: WebDAVClient
    private let fileLength: Int64

    init(url: URL, client: WebDAVClient) async throws {
        guard let length = try await client.contentLength(url), length > 2_048 else {
            throw ZipError.corrupt
        }
        let window = min(length, RemoteZip.tailWindow)
        let tailStart = length - window
        guard let tail = try await client.data(url, byteRange: tailStart...(length - 1)),
              Int64(tail.count) == window else { throw ZipError.corrupt }

        let parsed = RemoteZip.parseEntries(in: tail, tailStart: tailStart, fileLength: length)
        guard !parsed.isEmpty else {
            throw ZipError.unsupported("远程压缩包读不了目录，可能不支持 Range 或被加密")
        }
        self.entries = parsed
        self.pageCount = parsed.count
        self.url = url
        self.client = client
        self.fileLength = length
    }

    func pageData(at index: Int) async throws -> Data {
        guard index >= 0, index < pageCount else { throw ZipError.corrupt }
        return try await RemoteZip.payload(for: entries[index],
                                           url: url,
                                           client: client,
                                           fileLength: fileLength)
    }
}
