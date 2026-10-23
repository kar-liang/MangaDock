import Foundation
import UIKit

/// Reads the cover page of a remote CBZ without downloading the whole file:
/// 1) tail bytes -> EOCD -> central directory -> first image entry
/// 2) the entry's local header (30 bytes + name/extra)
/// 3) the compressed page payload, then inflate.
/// Any step failing (server ignores Range, ZIP64, RAR-in-disguise) just returns nil
/// so the grid falls back to a placeholder tile.
enum RemoteZip {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int64
        let uncompressedSize: Int
        let localOffset: Int64
        let name: String
    }

    static func cover(for url: URL, client: WebDAVClient, maxPixel: CGFloat) async -> UIImage? {
        do {
            guard let length = try await client.contentLength(url), length > 2_048 else { return nil }

            let window = min(length, 256 * 1024)
            let tailStart = length - window
            guard let tail = try await client.data(url, byteRange: tailStart...(length - 1)),
                  Int64(tail.count) == window else { return nil }

            guard let entry = firstPage(in: tail, tailStart: tailStart, fileLength: length) else {
                return nil
            }

            guard let header = try await client.data(url, byteRange: entry.localOffset...(entry.localOffset + 1_024)),
                  header.count >= 30 else { return nil }
            let nameLength = Int(headReading(header, 26))
            let extraLength = Int(headReading(header, 28))
            let dataStart = entry.localOffset + 30 + Int64(nameLength) + Int64(extraLength)
            guard dataStart < length, entry.compressedSize > 0,
                  dataStart + entry.compressedSize <= length else { return nil }

            guard let payload = try await client.data(url, byteRange: dataStart...(dataStart + entry.compressedSize - 1)),
                  Int64(payload.count) == entry.compressedSize else { return nil }

            let pageData: Data
            switch entry.method {
            case 0:
                pageData = payload
            case 8:
                pageData = try Inflate.raw(payload, expectedSize: entry.uncompressedSize)
            default:
                return nil
            }

            return await Task.detached(priority: .utility) {
                ImageDecoder.downsample(pageData, maxPixelSize: maxPixel)
            }.value
        } catch {
            return nil
        }
    }

    // MARK: - Central directory in the tail window

    private static func firstPage(in tail: Data, tailStart: Int64, fileLength: Int64) -> Entry? {
        let bytes = [UInt8](tail)
        let count = bytes.count
        guard count > 22 else { return nil }

        var eocd = -1
        var cursor = count - 22
        while cursor >= 0 {
            if readU32(bytes, cursor) == 0x06054b50 {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard eocd >= 0 else { return nil }

        let entryCount = Int(readU16(bytes, eocd + 10))
        let directorySize = Int64(readU32(bytes, eocd + 12))
        let directoryOffset = Int64(readU32(bytes, eocd + 16))

        guard entryCount > 0, entryCount != 0xFFFF,
              directoryOffset != 0xFFFFFFFF, directorySize != 0xFFFFFFFF else { return nil }
        guard directoryOffset >= tailStart else { return nil }   // directory outside window

        var position = Int(directoryOffset - tailStart)
        var candidates: [Entry] = []

        for _ in 0..<entryCount {
            guard position + 46 <= count, readU32(bytes, position) == 0x02014b50 else { return nil }
            let flags = readU16(bytes, position + 8)
            let method = readU16(bytes, position + 10)
            let compressedSize = Int64(readU32(bytes, position + 20))
            let uncompressedSize = Int(readU32(bytes, position + 24))
            let nameLength = Int(readU16(bytes, position + 28))
            let extraLength = Int(readU16(bytes, position + 30))
            let commentLength = Int(readU16(bytes, position + 32))
            let localOffset = Int64(readU32(bytes, position + 42))

            guard position + 46 + nameLength <= count else { return nil }
            let nameBytes = Array(bytes[(position + 46)..<(position + 46 + nameLength)])
            let name = String(decoding: nameBytes, as: UTF8.self)

            let usable = flags & 0x0001 == 0
                && (method == 0 || method == 8)
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

        return candidates.sorted { NaturalSort.less($0.name, $1.name) }.first
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
