import Compression
import Foundation

/// Минимальное чтение ZIP (хватает для .xlsx): центральный каталог, методы stored и deflate.
/// Без Zip64, без шифрования; размеры ограничены, чтобы «бомба» не съела память.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    static let maxEntrySize = 128 << 20
    static let maxEntries = 10_000

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init(data: Data) throws {
        self.data = data
        guard let eocd = Self.findEndOfDirectory(data) else { throw ConnectionsError.corrupt("Не ZIP-архив") }
        let count = Int(try Self.u16(data, eocd + 10))
        let dirOffset = Int(try Self.u32(data, eocd + 16))
        guard count <= Self.maxEntries else { throw ConnectionsError.corrupt("Слишком много файлов в архиве") }
        if count == 0xFFFF || dirOffset == 0xFFFF_FFFF { throw ConnectionsError.corrupt("Zip64 не поддерживается") }
        var pos = dirOffset
        for _ in 0..<count {
            guard try Self.u32(data, pos) == 0x0201_4b50 else { throw ConnectionsError.corrupt("Повреждён каталог архива") }
            let flags = try Self.u16(data, pos + 8)
            let method = try Self.u16(data, pos + 10)
            let csize = Int(try Self.u32(data, pos + 20))
            let usize = Int(try Self.u32(data, pos + 24))
            let nameLen = Int(try Self.u16(data, pos + 28))
            let extraLen = Int(try Self.u16(data, pos + 30))
            let commentLen = Int(try Self.u16(data, pos + 32))
            let local = Int(try Self.u32(data, pos + 42))
            guard pos + 46 + nameLen <= data.count else { throw ConnectionsError.corrupt("Повреждён каталог архива") }
            let nameData = data.subdata(in: data.startIndex + pos + 46 ..< data.startIndex + pos + 46 + nameLen)
            let name = String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, flags: flags, compressedSize: csize,
                                  uncompressedSize: usize, localOffset: local)
            pos += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Содержимое файла архива; nil — такого файла нет.
    func contents(of name: String) throws -> Data? {
        guard let e = entries[name] else { return nil }
        if e.flags & 1 != 0 { throw ConnectionsError.corrupt("Файл защищён паролем") }
        guard e.uncompressedSize <= Self.maxEntrySize else { throw ConnectionsError.tooLarge }
        guard try Self.u32(data, e.localOffset) == 0x0403_4b50 else { throw ConnectionsError.corrupt("Повреждён заголовок файла в архиве") }
        let start = e.localOffset + 30 + Int(try Self.u16(data, e.localOffset + 26)) + Int(try Self.u16(data, e.localOffset + 28))
        guard start >= 0, e.compressedSize >= 0, start + e.compressedSize <= data.count else {
            throw ConnectionsError.corrupt("Архив обрезан")
        }
        let packed = data.subdata(in: data.startIndex + start ..< data.startIndex + start + e.compressedSize)
        switch e.method {
        case 0:
            return packed
        case 8:
            return try Self.inflate(packed, size: e.uncompressedSize)
        default:
            throw ConnectionsError.corrupt("Метод сжатия \(e.method) не поддерживается")
        }
    }

    private static func inflate(_ packed: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { out.deallocate() }
        let written = packed.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(out, size, base, packed.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw ConnectionsError.corrupt("Не удалось распаковать данные") }
        return Data(bytes: out, count: size)
    }

    private static func findEndOfDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var i = data.count - 22
        while i >= lowest {
            if let sig = try? u32(data, i), sig == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ d: Data, _ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= d.count else { throw ConnectionsError.corrupt("Архив обрезан") }
        let i = d.startIndex + at
        return UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }

    private static func u32(_ d: Data, _ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= d.count else { throw ConnectionsError.corrupt("Архив обрезан") }
        let i = d.startIndex + at
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}
