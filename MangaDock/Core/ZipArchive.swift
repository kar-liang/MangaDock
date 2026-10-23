import Foundation
import Compression

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    let flagBits: UInt16
}

enum ZipError: LocalizedError {
    case notAZip
    case corrupt
    case encrypted
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "这不是一个有效的 CBZ / ZIP 文件"
        case .corrupt: return "压缩包内容损坏"
        case .encrypted: return "压缩包加了密，先解密再放进服务器"
        case .unsupported(let reason): return reason
        }
    }
}

/// Minimal read-only ZIP reader. Only what a comic archive needs:
/// stored (0) and deflate (8) entries, no encryption, no ZIP64.
final class ZipArchive {
    private let data: Data
    let entries: [ZipEntry]

    init(fileURL: URL) throws {
        let raw = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        self.data = raw
        self.entries = try Self.readEntries(raw)
    }

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readEntries(data)
    }

    func data(for entry: ZipEntry) throws -> Data {
        guard entry.flagBits & 0x0001 == 0 else { throw ZipError.encrypted }

        let base = entry.localHeaderOffset
        let total = data.count
        return try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Data in
            guard base + 30 <= total, Self.u32(buffer, base) == 0x04034b50 else {
                throw ZipError.corrupt
            }
            let nameLength = Int(Self.u16(buffer, base + 26))
            let extraLength = Int(Self.u16(buffer, base + 28))
            let start = base + 30 + nameLength + extraLength
            let end = start + entry.compressedSize
            guard start >= 0, end <= total else { throw ZipError.corrupt }

            let payload = Data(bytes: buffer.baseAddress!.advanced(by: start),
                               count: entry.compressedSize)
            switch entry.method {
            case 0:
                return payload
            case 8:
                return try Inflate.raw(payload, expectedSize: entry.uncompressedSize)
            default:
                throw ZipError.unsupported("不支持的压缩方式（\(entry.method)）")
            }
        }
    }

    // MARK: - Central directory

    private static func readEntries(_ data: Data) throws -> [ZipEntry] {
        let total = data.count
        guard total > 22 else { throw ZipError.notAZip }

        var result: [ZipEntry] = []
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var search = total - 22
            let lowerBound = max(0, total - 66_000)
            var eocd = -1
            while search >= lowerBound {
                if u32(buffer, search) == 0x06054b50 {
                    eocd = search
                    break
                }
                search -= 1
            }
            guard eocd >= 0 else { throw ZipError.notAZip }

            let entryCount = Int(u16(buffer, eocd + 10))
            let directorySize = Int(u32(buffer, eocd + 12))
            let directoryOffset = Int(u32(buffer, eocd + 16))

            if entryCount == 0xFFFF || directoryOffset == 0xFFFFFFFF || directorySize == 0xFFFFFFFF {
                throw ZipError.unsupported("暂不支持 ZIP64 格式的压缩包")
            }
            guard directoryOffset >= 0, directoryOffset + directorySize <= total else {
                throw ZipError.corrupt
            }

            var cursor = directoryOffset
            for _ in 0..<entryCount {
                guard cursor + 46 <= total, u32(buffer, cursor) == 0x02014b50 else {
                    throw ZipError.corrupt
                }
                let flagBits = u16(buffer, cursor + 8)
                let method = u16(buffer, cursor + 10)
                let compressedSize = Int(u32(buffer, cursor + 20))
                let uncompressedSize = Int(u32(buffer, cursor + 24))
                let nameLength = Int(u16(buffer, cursor + 28))
                let extraLength = Int(u16(buffer, cursor + 30))
                let commentLength = Int(u16(buffer, cursor + 32))
                let localOffset = Int(u32(buffer, cursor + 42))

                guard cursor + 46 + nameLength <= total else { throw ZipError.corrupt }
                let nameData = Data(bytes: buffer.baseAddress!.advanced(by: cursor + 46),
                                    count: nameLength)
                var name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1)
                    ?? ""
                name = name.replacingOccurrences(of: "\\", with: "/")

                let isJunk = name.hasSuffix("/")
                    || name.hasPrefix("__MACOSX/")
                    || name.contains("/.")
                    || name.hasPrefix(".")
                if !isJunk {
                    result.append(ZipEntry(name: name,
                                           method: method,
                                           compressedSize: compressedSize,
                                           uncompressedSize: uncompressedSize,
                                           localHeaderOffset: localOffset,
                                           flagBits: flagBits))
                }

                cursor += 46 + nameLength + extraLength + commentLength
            }
        }
        return result
    }

    private static func u16(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= buffer.count else { return 0 }
        return UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
    }

    private static func u32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= buffer.count else { return 0 }
        return UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }
}

enum Inflate {
    /// Inflates a raw DEFLATE stream (the payload format used inside ZIP entries).
    static func raw(_ input: Data, expectedSize: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }

        var output = Data()
        if expectedSize > 0 { output.reserveCapacity(expectedSize) }

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt
        }
        defer { compression_stream_destroy(&stream) }

        let chunk = 256 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }

        try input.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw ZipError.corrupt
            }
            stream.src_ptr = source
            stream.src_size = input.count

            // COMPRESSION_STREAM_FINALIZE == 1
            let finalizeFlag = Int32(1)

            while true {
                stream.dst_ptr = destination
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, finalizeFlag)
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    output.append(destination, count: produced)
                }
                if status == COMPRESSION_STATUS_END { return }
                if status == COMPRESSION_STATUS_ERROR { throw ZipError.corrupt }
                if produced == 0 { throw ZipError.corrupt }
            }
        }
        return output
    }
}
