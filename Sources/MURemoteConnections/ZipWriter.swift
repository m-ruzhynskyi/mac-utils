import Compression
import Foundation

/// Минимальная запись ZIP (для шаблона .xlsx и фикстур тестов): stored или deflate, CRC-32, без Zip64.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    mutating func add(_ name: String, _ contents: Data, compress: Bool = true) {
        let packed = compress ? Self.deflate(contents) : nil
        let method: UInt16 = packed == nil ? 0 : 8
        let stored = packed ?? contents
        let nameData = Data(name.utf8)
        let crc = Self.crc32(contents)
        let offset = body.count

        var local = Data()
        local.le32(0x0403_4b50); local.le16(20); local.le16(0x0800); local.le16(method)
        local.le16(0); local.le16(0x21) // время и дата: 1980-01-01, архиву дата не нужна
        local.le32(crc); local.le32(UInt32(stored.count)); local.le32(UInt32(contents.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        body += local + nameData + stored

        var central = Data()
        central.le32(0x0201_4b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(method)
        central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(UInt32(stored.count)); central.le32(UInt32(contents.count))
        central.le16(UInt16(nameData.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(0); central.le32(UInt32(offset))
        directory += central + nameData
        count += 1
    }

    func finish() -> Data {
        var end = Data()
        end.le32(0x0605_4b50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(directory.count)); end.le32(UInt32(body.count)); end.le16(0)
        return body + directory + end
    }

    /// Сырой deflate (то, что ZIP ждёт в методе 8). nil — сжатие не дало выигрыша.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 64
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { out.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(out, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written < data.count else { return nil }
        return Data(bytes: out, count: written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
